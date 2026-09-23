# Phase 3 Remote Completion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 本地表达无匹配时，通过用户指定的 OpenAI 兼容接口生成单行续写后缀，并沿用现有候选条和 Tab／Esc 交互。

**Architecture:** 保持“本地优先、远程兜底”。当前输入在发送前二次脱敏，API Key 只从 macOS Keychain 读取；请求携带输入版本，新输入会取消旧请求，乱序回包不得显示。首版只发送光标前当前输入，不猜测当前任务，不上传历史正文。

**Tech Stack:** Objective-C, AppKit, Foundation `NSURLSession`, Security/Keychain, 现有 `CPASensitiveTextRedactor`, Clang/Make.

---

### Task 1: 请求和响应纯函数

**Files:**
- Create: `Sources/RemoteCompletionCore/RemoteCompletionProtocol.h`
- Create: `Sources/RemoteCompletionCore/RemoteCompletionProtocol.m`
- Create: `Tests/RemoteCompletionCoreTests/RemoteCompletionProtocolTests.m`
- Modify: `Makefile`

**Steps:**
1. 先写失败测试：脱敏后的当前输入是请求中唯一用户正文，日志不需求原文。
2. 覆盖 `/models` 的候选筛选，排除 embedding/rerank/image/audio/moderation 类模型，保留用户手动模型优先级。
3. 覆盖 `choices[0].message.content` 和 `choices[0].text` 解析；去掉引号、标签、换行和已输入前缀，过长结果截断为单行。
4. 运行 `make remote-completion-test`，预期所有合成测试 `PASS`。
5. 提交 `test/feat: add remote completion protocol` 对应改动。

### Task 2: 可取消网络客户端

**Files:**
- Create: `Sources/RemoteCompletionCore/RemoteCompletionClient.h`
- Create: `Sources/RemoteCompletionCore/RemoteCompletionClient.m`
- Create: `Tests/RemoteCompletionCoreTests/RemoteCompletionClientTests.m`
- Modify: `Makefile`

**Steps:**
1. 用自定义 `NSURLProtocol` 先写失败测试：Authorization 存在但不进日志，请求体只含白名单字段。
2. 测试自动请求 `/models` 并缓存选中模型；手动模型存在时不请求模型列表。
3. 测试取消、5 秒请求／6 秒资源超时、401/429/5xx 和连续失败短暂熔断；失败都返回枚举和计数，不返回请求正文。
4. 实现单个活跃 `NSURLSessionDataTask`，新请求取消旧请求。
5. 运行 `make remote-completion-test`，预期 `PASS`后提交。

### Task 3: 钥匙串设置入口

**Files:**
- Create: `Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.h`
- Create: `Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.m`
- Create: `Tests/CodexPromptAssistantPOCTests/RemoteCompletionSettingsTests.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Makefile`

**Steps:**
1. 先测试固定 base URL 只接受 HTTPS，模型字符串做空白归一，不保存 Key 副本。
2. 实现菜单“设置智能补全…”：显示固定服务地址、`NSSecureTextField` 和可留空模型字段。
3. Key 使用独立 service/account 写入 Keychain；旧 Key 不写入源码、UserDefaults、数据库或日志。
4. 未配置时菜单显示“智能补全：未配置”，但不影响本地建议。
5. 运行测试和构建，预期 `PASS`。

### Task 4: 本地优先、远程兜底集成

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Sources/CodexPromptAssistantPOC/LocalSuggestionCoordinator.h`
- Modify: `Sources/CodexPromptAssistantPOC/LocalSuggestionCoordinator.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/LocalSuggestionCoordinatorTests.m`

**Steps:**
1. 先写失败测试：本地命中不发网络；本地未命中才发起远程；新签名、Esc、选区和输入法组词都取消远程。
2. 只取光标前文本，经 `CPASensitiveTextRedactor` 后发送；完成块回主线程时重新校验签名和当前文本。
3. 远程建议仍使用现有候选条、Tab 接受和 Esc 取消；日志只记本地/远程、状态、耗时和字符数。
4. 运行 `make test remote-completion-test app`，预期 `PASS`。

### Task 5: 安全与实机验收

**Files:**
- Modify: `HANDOFF.md`
- Modify: `REFLECTION.md`
- Create: `docs/security/2026-08-21-phase3-remote-completion-audit.md`

**Steps:**
1. 运行全量回归、Clang Analyzer、plist 和 `codesign --verify --deep --strict`。
2. 用合成 Key/token/邮箱/电话夹具截获请求体，验证敏感明文泄漏为 0；扫描源码和应用包，验证旧 Key 和接口密钥明文为 0。
3. 启动应用，验证未配置时本地建议不受影响，配置后才能请求远程。
4. 实机验证需要用户在设置页输入 Key；若用户明确要求使用聊天中已暴露的 Key，只能用于当前联调并记录轮换风险，正式使用前必须替换。
5. 更新交接和复盘，提交最终改动。
