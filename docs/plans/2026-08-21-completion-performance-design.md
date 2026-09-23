# Completion Performance and Diagnostics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 降低输入到候选条出现的本地等待，并让远程补全的阶段耗时、取消原因和错误可以被安全追踪。

**Architecture:** 保持单个在途远程请求和本地优先策略，避免并发多个模型请求造成重复消耗或乱序结果。将诊断写入移到串行后台队列；远程客户端继续使用 `NSURLSession` 异步网络，在结果对象中返回请求 ID、阶段、错误摘要和缓存命中信息；增加小容量、短 TTL 的内存结果缓存，仅用于相同草稿再次出现。

**Tech Stack:** Objective-C, AppKit, Foundation `NSURLSession`, GCD, CommonCrypto/Security-compatible hashing, Clang/Make.

---

## 已确认的瓶颈

- 最近现场日志中，`remote outcome=0` 的网络耗时约 1.2～1.5 秒；这比本地索引和 AX 读取大一个数量级。
- 当前 `NSURLSession` 已经是异步的，因此“多线程”不能让同一个模型请求的服务器计算变快；并发发多个模型会增加费用、429 和乱序风险。
- AX 状态变化会在主线程同步追加诊断文件，连续输入时会产生大量写盘操作，应改为后台串行写入并保留顺序。
- 读取远程 API Key 原本发生在主线程；现场一次请求在 Keychain 访问期间延迟约 10 秒，必须移到后台并在内存短暂复用。
- 远程结果目前只有 outcome/status/duration，缺少请求 ID、阶段和错误摘要，失败时难以判断是超时、取消、鉴权还是响应格式错误。

## 实施任务

### Task 1: 先写诊断字段测试

**Files:**
- Modify: `Sources/RemoteCompletionCore/RemoteCompletionClient.h`
- Modify: `Tests/RemoteCompletionCoreTests/RemoteCompletionClientTests.m`

**Steps:**
1. 增加请求 ID、阶段、错误域／错误码／安全错误摘要和缓存命中字段的断言。
2. 覆盖取消、超时、401、429、5xx、无效 JSON，每类错误都必须返回稳定 outcome 且不包含输入正文或 API Key。
3. 运行 `make remote-completion-test`，确认新增断言在实现前失败。

### Task 2: 异步诊断与远程错误闭环

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/Diagnostics.m`
- Modify: `Sources/CodexPromptAssistantPOC/Diagnostics.h`
- Modify: `Sources/RemoteCompletionCore/RemoteCompletionClient.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`

**Steps:**
1. 用串行 GCD 队列异步写诊断文件，增加显式 flush，避免主线程同步文件 I/O。
2. 给每次请求生成不含秘密的短请求 ID，记录 start -> model_discovery/completion -> finish 阶段。
3. 错误只记录 outcome、HTTP 状态、错误域／码、截断后的单行错误摘要、输入／输出字符数、脱敏命中数和耗时；不记录输入正文、响应正文、Authorization 或 Key。
4. 将 API Key 的首次读取放到独立后台队列，设置 2.5 秒准备超时；成功后仅在进程内短暂缓存，输入变化或取消时丢弃过期的准备结果。
5. 让 UI 回调仍回主线程，解析和文件写入不阻塞输入监听。

### Task 3: 低风险延迟优化

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/SuggestionTriggerPolicyTests.m`
- Modify: `Sources/RemoteCompletionCore/RemoteCompletionClient.m`
- Modify: `Tests/RemoteCompletionCoreTests/RemoteCompletionClientTests.m`

**Steps:**
1. 将普通输入防抖从 180ms 调到 120ms，IME 复查从 120ms 调到 80ms，并保留上限测试，避免输入未稳定时过度发请求。
2. 增加最多 8 条、15 秒 TTL 的进程内结果缓存；缓存键使用输入与模型的摘要，不落盘、不写日志，命中仍通过异步回调返回。
3. 新输入、显式取消和缓存过期都必须清除或跳过旧结果；继续保持单一 active task。
4. 运行远程客户端和策略测试，确认缓存命中不会发送第二个网络请求。

### Task 4: 回归与现场指标

**Files:**
- Modify: `HANDOFF.md`
- Modify: `REFLECTION.md`

**Steps:**
1. 运行 `make test remote-completion-test app`、逐文件 Clang Analyzer、`git diff --check`、plist 和 codesign 校验。
2. 用合成输入检查日志中只出现请求 ID、阶段、耗时和错误摘要，不出现正文、Key 或 Authorization。
3. 现场记录从 `suggestion local_no_match` 到 `remote start`、`remote finish`、`overlay remote_show` 的时间差。
4. 若典型总等待仍超过 1.3 秒，再单独评估 SSE 流式补全；本轮不引入多模型并发。
