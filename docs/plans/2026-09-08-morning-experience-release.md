# 明早体验版 Implementation Plan

> **执行方式：**按 writing-plans / executing-plans 分包执行。用户已明确授权继续完成并安装体验；不重复等待每包批准。现有分支直接继续，保留改动，不另迁工作树。

**Goal:** 交付可启动、可回退、通过限定无发送实测的本机助手体验版；不把开发实验或未验收兼容项称为最终正式产品。

**Architecture:** 沿用 Objective-C/AppKit、当前本地/远程生成客户端和 C1 不可变上下文与候选提交。此次不采用 G1/context-v1/C3 未通过的模型模板或增加审核调用；只修复有确切反例的最终片段校验，再验证从此前安装版到当前源码的运行变化。

**Tech Stack:** Objective-C、Foundation/AppKit、Python、Make、macOS AX、launchd（仅助手）。

**执行结果（2026-09-08 21:31）：**Task 1/2 固定回放与有界修复已提交；Task 3 完整离线、后续菜单修复回归、强制构建/签名及合成性能检查通过；Task 4 仅助手更新至 clean `49cff39`，Codex/模型未重启；Task 5 TextEdit 与 Chrome 固定夹具取得逐项证据并恢复原配置。实机发现的菜单目标重绑已补失败测试、修复并重新验收。飞书/WorkBuddy 当前版复验、WPS 宿主桥接及跨任务/IME/多屏未完成，独立语义精准性仍未通过。完整事实见[验收记录](../validation/2026-09-08-morning-experience.md)，不把本计划执行结果当作全产品正式验收。

## 范围与验收

已确认授权：本地分包提交、不推送；仅安装和重载助手，保留现有开关、数据、bundle ID 与签名身份；Codex/模型禁止重启。读取/测试使用可识别合成草稿，不发送消息、不覆盖用户文稿。

体验版必须具备：非空合成输入可生成并 Tab 插入；空输入不提示；Esc 撤销；关闭清候选、重新启用无需重启；受保护输入与未授权站点不提示；插入后按新正文重新观察；已有完整句允许停笔。代码、链接、占位符内部与中部光标保持保守边界。

语义限制：局部规则不是通用语义证明；缺少上下文仍可能猜测、范围扩展与同义复述尚有残余。只有回放证明新放行候选符合既定契约，且没有破坏原拒绝回归，才保留本轮放宽。无法获得可用前台/权限等实机证据时标明阻断，不宣称已交付完全验收的最终软件。

## Task 1：固定回放入口与基线

Files: `Tools/CompletionQualityBenchmark/main.m`、`Tests/RemoteCompletionCoreTests/CompletionQualityHarnessTests.m`、`docs/evaluation/results/morning-experience/`。

1. 新增工具专用原始候选离线回放模式；必须在远程配置读取前分支返回，不发送请求、不读取用户凭据。
2. 从旧 C2/context-v1 原始合成记录构造候选＋原草稿回放；保存完整来源、SHA、原失败/无输出，不将无输出重新算成功。
3. 修改生产规则前构建基线工具并记录身份/二进制 SHA，保存基线过滤结果。

## Task 2：局部片段校验修复

Files: `Sources/RemoteCompletionCore/RemoteCompletionProtocol.m`、`.h`、`CompletionIdentity.h`、`Tests/RemoteCompletionCoreTests/RemoteCompletionProtocolTests.m`。

1. 先补失败回归：`译文。`自然短闭合；长对象名在明确`对象为/名称是`关系中必要重复；重复完整命题、客服回复、未闭合结构仍拒绝。
2. `make remote-completion-test` 确认预期失败，再实现最小修复。长度不是强制凑字指标，保留未完成短片段门；重复豁免仅针对明确名称关系中的原文对象，不豁免回应、结构、数字与其他安全门。
3. 更新提示/规则身份版本，模型/system 模板及上下文预算不改。
4. 同一原始候选回放比较新放行/新拒绝；逐个审阅差异。若出现不可控制误放，撤回该局部实现并保留测试/证据，不降低金标。
5. 针对运行版本做固定合成输入的两路模型冒烟，失败、候选与耗时分开；不称独立盲测。
6. 审阅并提交独立代码包。

## Task 3：完整离线与构建检查

**现场新增、仍属核心体验范围（20:55）：**本机 localPaused=true、remotePaused=false；TextEdit 的既有 remoteAuthorized=false，但菜单没有授权入口。按此前“独立联网开关、支持常用应用”要求，新增下述有界子包后再执行全集。采用当前应用/精确站点 checkbox，复用已有存储与即时失效；全局自动授权会改变已有边界，未采用；只补状态文案不能让用户自行配置，故同时提供入口。Codex 固有联网能力仍由全局远程开关控制，该作用域不创建无效的独立开关；未知主机和永久保护应用禁配。

Files: `Sources/CodexPromptAssistantPOC/main.m`、`Tests/CodexPromptAssistantPOCTests/ApplicationPolicyMenuIntegrationTests.m`、`Sources/RemoteCompletionCore/RemoteCompletionClient.m`、`Tests/RemoteCompletionCoreTests/RemoteCompletionClientTests.m`。

1. 先证明确切应用规则与当前来源开关的组合无可用来源；补菜单动作缺失、同站点持久化、其他位保持、换焦点拒绝、敏感仍拒绝的回归。
2. 复用 `applyCurrentMenuRule:`；新勾选项明确“允许此应用/站点联网补全”，并显示本地关闭/联网未授权的原因，不自动改任何授权。
3. 固定两路冒烟中远程“继续支持吧”无上下文编造反例；将已有纯继续短语门应用到远程，保留提供了上下文时的路径。不是按所有指代词一律拒绝。
4. 独立测试和提交此子包，之后再完整检查、安装及实机。

Files: `docs/validation/2026-09-08-morning-experience.md`、`docs/status.md`。

1. 串行执行 `make check-offline`（包括全部公开核心套件）、`make -B app`、`git diff --check`、严格 codesign。
2. 提交后 `make app`；包内/嵌入身份均为 clean HEAD；保存本机候选包与旧包签名/哈希。
3. 所有失败先定位再修；重复测试只针对变更及未解决风险，不能靠重启模型或清数据解决。

## Task 4：仅更新助手

Files: 只使用 `Tools/Release/prepare_update.py` 准备副本；安装操作采用与当前限定迁移匹配的明确步骤，不调用旧 service-start/install 组合目标。

1. 只读核对助手/Codex/模型 PID、启动时间、已安装/运行映射、助手保护参数、加载 plist、完整开关状态。
2. 先准备并复验新旧 clean 包和独立回退副本，明确旧包支持保护启动参数；新包严格签名及模型保护标记必须有效。
3. 只停止精确助手 label；同卷保留旧安装目录、换入已核对候选；按原助手 plist 和保护参数启动。任何异常停止后续操作，最多一次恢复已保存旧包，不循环重启、不触碰 Codex/模型。
4. 核对新助手 PID、启动日志 build identity、安装/映射对象一致；Codex/模型 PID 与启动时间不变。保留回退文件和路径。

## Task 5：无发送实机与最终交付

Files: `Tests/Fixtures/InputSafety/README.md`（沿用夹具）、上述 validation/status、`docs/release.md`（仅更新实际身份指引）。

1. TextEdit 独立文稿：推荐显示、Tab 差量读回、Esc、空输入、关闭/重新启用；前台/文本归属变化时立即停止输入。
2. 浏览器本机合成页：未授权站点、普通输入阳性、敏感输入与搜索例外；先保存精确单站点状态，不能证明原状态恢复则不修改该条。
3. 飞书/WorkBuddy 可用时只在独立可识别草稿测试，不发送。WPS 实际宿主桥接没有证据则保持实验，不声称整款软件支持完成。Codex 只在明确本次测试输入框验证，不改写当前任务用户内容。
4. 恢复本次测试改动的开关/规则，核对三进程连续性、实际运行构建、旧包保留位置；保存已验/未验/失败事实。
5. 分包提交文档，不推送；最终 `make app` 再核对 clean 元数据。明确安装功能提交与最终文档提交的区别，不为写自身 SHA 反复重载。

**退出条件：**上述工作包均有结果记录，实机可验则完成更新和验收；真实阻断保留准确现场与下一步。不得将“明早体验”承诺替代语义验收，也不把仅编译成功当作安装完成。
