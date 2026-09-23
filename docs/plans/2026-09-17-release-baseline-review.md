# 发布源码基线：已批准并提交

2026-09-17。用户已批准；独立副本本地提交 `64d9475` 已完成，提交后 clean 构建和应用测试通过。[执行记录](../validation/2026-09-17-clean-baseline.md)。未安装、未推送或发布，仍为 S1。下文保留批准时的提案与精确文件范围。

## 本次具体操作建议

在独立源码副本建立本地分支 `codex/release-baseline-20260917`，将下方列出的 90 个文件保存为一个“当前已安装功能源码基线”提交，建议标题 `Establish tested prompt assistant source baseline`。基于原 HEAD `230411e3d7517150b5d5f6ed7a82eaae5c7dc232`，不切换或提交原工作区；原工作区已有修改、文档、证据和输出继续保留。此处是本地版本保存申请，不是对外发布申请。

这些文件共同覆盖已安装版本的简化设置/练习、任务上下文与输入保护、续写策略、图标/本地化、健康探测及发布工具与测试。多轮改动已交叉接入同一 main/Makefile/测试入口，因此本次以可复现的完整源码基线为审查单位；后续功能再按独立工作包提交。这不是 90 项新的功能修改，也不宣称做完全部逐行安全审计。

## 已完成的核对

- 来源清单：Makefile 1、资源 10、生产源码 35、测试 25、工具 18、诊断启动入口 1，共 90 文件；完整补丁包含新增文件和二进制资源。
- 独立副本从原 HEAD 克隆，仅覆盖列出的文件；逐文件 SHA256 和权限与原文件匹配，原暂存区保持空。
- 独立副本 `make check-offline` 完整通过，随后 `make -B app` 构建及严格验签通过；测试使用原有隔离入口，不操作真实服务。
- 构建的执行文件 SHA256 与当前安装包一致：`e7d91a4faf197e4cd3f843deaf3d31106c8c1c345476e5520cd98243cebd1028`。
- 整包摘要也一致：`569fe7d240741f0cce27cffa121277ac7e75c4f14241523dee61e66e76af0539`，绑定内容、相对文件名、类型与权限。此证据说明源码清单足以复现当前安装包。
- 构建仍如实标记 dirty=true；未伪造 GitCommit 或绕过门槛。提交后元数据改变，必须重新构建验签和运行验收，不能把本次包称作 clean 候选。
- 核对已知 `.cpa-*` 备份中的 113 个助手包元数据，没有同时满足 clean、整数生命周期协议 1、整数健康协议 1 的包。仅元数据盘点，不代表逐包验签或运行验证。
- 本轮前后助手75626、Codex1809、模型819的 PID/启动时间/执行路径保持，运行包与启动配置摘要保持，两次实时健康通过。

## 审查产物

- [完整补丁](/Users/hcm-b0263/Desktop/Codex智能提示助手/.build/release-baseline-review-2026-09-17/proposal.patch)
- [改动统计](/Users/hcm-b0263/Desktop/Codex智能提示助手/.build/release-baseline-review-2026-09-17/proposal-stat.txt)
- [文件摘要清单](/Users/hcm-b0263/Desktop/Codex智能提示助手/.build/release-baseline-review-2026-09-17/manifest.json)
- [验证摘要](../evaluation/results/release-baseline-2026-09-17/summary.json)

拟提交 Git tree：`726653338290e48a25f29899a76f4c7b2d943102`。补丁 SHA256：`89fd9962c7d30643aaee1bb3a297dd043a1162d7477dcc9b4f6d2626e387739b`。执行前复核摘要；若源码发生变化，更新清单后再验证。

## 后续依赖

本地基线提交 → 从干净源码重新构建验签 → 准备并核对 clean 安装基线与独立回退包 → 准备另一候选包 → 真实更新/失败回退验收。

当前 dirty 安装不能直接通过通用更新事务；不能仅提交源码后就认为旧安装自动变成 clean。首次迁移到 clean 基线仍须单独核对可恢复方案，保留当前已知可用包和保护进程证据。没有真实执行前仍标记未验证。

来源供给、凭据费用和签名分发身份仍待决定；最终包真实按键/宿主和干净用户验收仍是独立门槛，不因这次构建复现成功而通过。

## 精确文件范围

| 路径 | 字节数 | SHA256 前 12 位 |
| --- | ---: | --- |
| `Makefile` | 27029 | `d39caad87512` |
| `Resources/AppIcon.icns` | 1845386 | `b295049d7e4a` |
| `Resources/Artwork/AppIcon-master.png` | 1501080 | `e08cf3fb9410` |
| `Resources/Artwork/AppIcon-preview.png` | 1129459 | `24257248c716` |
| `Resources/Artwork/README.md` | 786 | `d3906cea3e30` |
| `Resources/Info.plist` | 1296 | `095999086ffe` |
| `Resources/StatusIcon.png` | 549 | `224690e92b9c` |
| `Resources/StatusIcon@2x.png` | 1155 | `8db9e5b02b07` |
| `Resources/en.lproj/InfoPlist.strings` | 61 | `5c282ca051e7` |
| `Resources/local.codex.prompt-assistant-model.plist` | 1836 | `6b2555176d77` |
| `Resources/zh_CN.lproj/InfoPlist.strings` | 61 | `5c282ca051e7` |
| `Sources/CodexPromptAssistantPOC/AccessibilityService.m` | 57793 | `94a8b3d82e0c` |
| `Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.h` | 4098 | `196d84d69acf` |
| `Sources/CodexPromptAssistantPOC/ApplicationInputAdapter.m` | 4665 | `eee3e53513bc` |
| `Sources/CodexPromptAssistantPOC/ApplicationMenu.h` | 688 | `ced4b6a260d8` |
| `Sources/CodexPromptAssistantPOC/ApplicationMenu.m` | 5146 | `3828e29b1e1d` |
| `Sources/CodexPromptAssistantPOC/CodexThreadIDResolver.h` | 1535 | `fd4b6f71aba5` |
| `Sources/CodexPromptAssistantPOC/CodexThreadIDResolver.m` | 14537 | `d65aac8fcd04` |
| `Sources/CodexPromptAssistantPOC/ConversationContextProvider.h` | 4373 | `0edac2330458` |
| `Sources/CodexPromptAssistantPOC/ConversationContextProvider.m` | 27352 | `4dc3e4d591e9` |
| `Sources/CodexPromptAssistantPOC/Diagnostics.h` | 1326 | `ef0a4e9562e0` |
| `Sources/CodexPromptAssistantPOC/Diagnostics.m` | 6384 | `82a012a91345` |
| `Sources/CodexPromptAssistantPOC/GenericAccessibilityService.h` | 2088 | `1e8391600ba6` |
| `Sources/CodexPromptAssistantPOC/GenericAccessibilityService.m` | 25918 | `9be55b4e7aca` |
| `Sources/CodexPromptAssistantPOC/HealthProbe.h` | 326 | `601bc8bd3481` |
| `Sources/CodexPromptAssistantPOC/HealthProbe.m` | 4489 | `e65edebdb475` |
| `Sources/CodexPromptAssistantPOC/KeyboardInterceptor.h` | 2223 | `e583d7ae64b6` |
| `Sources/CodexPromptAssistantPOC/KeyboardInterceptor.m` | 24434 | `5123d996f47d` |
| `Sources/CodexPromptAssistantPOC/LocalSuggestionCoordinator.m` | 4517 | `c5a7ae557cee` |
| `Sources/CodexPromptAssistantPOC/OverlayController.m` | 12616 | `3ae18851afe4` |
| `Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.h` | 1066 | `7e130fce3b67` |
| `Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.m` | 6724 | `b50f9286de94` |
| `Sources/CodexPromptAssistantPOC/SettingsWindowController.h` | 791 | `c73f44cacc3d` |
| `Sources/CodexPromptAssistantPOC/SettingsWindowController.m` | 33832 | `edb5938f5778` |
| `Sources/CodexPromptAssistantPOC/SuggestionPolicy.h` | 4473 | `b46bd9943ed6` |
| `Sources/CodexPromptAssistantPOC/SuggestionPolicy.m` | 11267 | `cf0f1d0218ba` |
| `Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.h` | 1240 | `afa44c94d4f7` |
| `Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.m` | 7564 | `a24ba225d361` |
| `Sources/CodexPromptAssistantPOC/WorkBuddyContextReader.h` | 1147 | `109df9248fc6` |
| `Sources/CodexPromptAssistantPOC/WorkBuddyContextReader.m` | 26293 | `7bce7334ddde` |
| `Sources/CodexPromptAssistantPOC/main.m` | 184404 | `f6664cdd32fb` |
| `Sources/RemoteCompletionCore/CompletionIdentity.h` | 296 | `ec2f1798f143` |
| `Sources/RemoteCompletionCore/RemoteCompletionClient.h` | 4076 | `6f5223dbc7e0` |
| `Sources/RemoteCompletionCore/RemoteCompletionClient.m` | 54096 | `b0867f624b59` |
| `Sources/RemoteCompletionCore/RemoteCompletionProtocol.h` | 4331 | `7a40b0b46846` |
| `Sources/RemoteCompletionCore/RemoteCompletionProtocol.m` | 63007 | `75f007d62479` |
| `Tests/CodexPromptAssistantPOCTests/ApplicationInputAdapterTests.m` | 3979 | `b4456f24b629` |
| `Tests/CodexPromptAssistantPOCTests/ApplicationMenuTests.m` | 4932 | `b5e2f29ebd43` |
| `Tests/CodexPromptAssistantPOCTests/ApplicationPolicyMenuIntegrationTests.m` | 47507 | `2d64f92b2713` |
| `Tests/CodexPromptAssistantPOCTests/CandidateLifecycleTests.m` | 45136 | `aeff6e600cc9` |
| `Tests/CodexPromptAssistantPOCTests/CodexReadPolicyTests.m` | 9063 | `51548ac92ff9` |
| `Tests/CodexPromptAssistantPOCTests/DiagnosticsTests.m` | 6120 | `d31156df3ea2` |
| `Tests/CodexPromptAssistantPOCTests/FocusedIDContextTests.inc` | 21491 | `ad477c1c6d43` |
| `Tests/CodexPromptAssistantPOCTests/GenericAccessibilityServiceTests.m` | 3246 | `c9e1c2488044` |
| `Tests/CodexPromptAssistantPOCTests/HealthProbeTests.m` | 3075 | `aeef5500839d` |
| `Tests/CodexPromptAssistantPOCTests/KeyboardInterceptorLifecycleTests.m` | 10589 | `95a218d97231` |
| `Tests/CodexPromptAssistantPOCTests/OverlayControllerTests.m` | 10823 | `50a74c80bf9b` |
| `Tests/CodexPromptAssistantPOCTests/RemoteCompletionSettingsTests.m` | 8296 | `df895acab872` |
| `Tests/CodexPromptAssistantPOCTests/SettingsWindowTests.m` | 15068 | `d0e9c21ea77d` |
| `Tests/CodexPromptAssistantPOCTests/SuggestionPolicyTests.m` | 10495 | `fee965c8d934` |
| `Tests/CodexPromptAssistantPOCTests/WorkBuddyContextReaderTests.inc` | 20936 | `031f1c99c351` |
| `Tests/ModelAgentTests/test_model_agent.py` | 6439 | `253ade8199a0` |
| `Tests/ModelAgentTests/test_model_preflight.py` | 6997 | `0023169209d7` |
| `Tests/ReleasePreparationTests/test_helper_agent.py` | 8419 | `4c16723f94fe` |
| `Tests/ReleasePreparationTests/test_helper_health.py` | 4790 | `26255d8b090d` |
| `Tests/ReleasePreparationTests/test_helper_runtime.py` | 8145 | `6b2fcd3b9dab` |
| `Tests/ReleaseTransactionTests/test_helper_launchd_services.py` | 12162 | `c68c68a88d89` |
| `Tests/ReleaseTransactionTests/test_update_transaction.py` | 15625 | `fed0b4dfabbb` |
| `Tests/RemoteCompletionCoreTests/CompletionQualityHarnessTests.m` | 19151 | `f673a0bd536f` |
| `Tests/RemoteCompletionCoreTests/RemoteCompletionClientTests.m` | 64509 | `9f2b18db9bcc` |
| `Tests/RemoteCompletionCoreTests/RemoteCompletionProtocolTests.m` | 55000 | `9ee546accee1` |
| `Tools/CodexFocusedThreadProbe/README.md` | 3892 | `ff5a6a9cde2f` |
| `Tools/CodexFocusedThreadProbe/context.m` | 2503 | `0e6bf945b875` |
| `Tools/CodexFocusedThreadProbe/diagnose.py` | 3314 | `4890d7c8ef85` |
| `Tools/CodexFocusedThreadProbe/main.m` | 12734 | `946844ec3482` |
| `Tools/CodexFocusedThreadProbe/run.py` | 3819 | `a4a046fe1874` |
| `Tools/CompletionQualityBenchmark/AuditSupport.m` | 6667 | `2e6d3144244a` |
| `Tools/CompletionQualityBenchmark/BenchmarkSupport.h` | 1441 | `5a22654e47c3` |
| `Tools/CompletionQualityBenchmark/BenchmarkSupport.m` | 15016 | `9735f374e9cc` |
| `Tools/CompletionQualityBenchmark/audit-v3.txt` | 1896 | `b063cc05eb56` |
| `Tools/CompletionQualityBenchmark/main.m` | 7026 | `78e8af6a9aec` |
| `Tools/Icons/export.m` | 5254 | `c1bbaf38e1d6` |
| `Tools/Release/helper_agent.py` | 6111 | `b37eac2bfbe1` |
| `Tools/Release/helper_health.py` | 4851 | `9ce2312ffed9` |
| `Tools/Release/helper_launchd_services.py` | 7671 | `4952690228fc` |
| `Tools/Release/helper_runtime.py` | 6167 | `963ffed25bfd` |
| `Tools/Release/model_agent.py` | 3743 | `13f1eb7eec8d` |
| `Tools/Release/model_preflight.py` | 7350 | `1ec3ade43f81` |
| `Tools/Release/update_transaction.py` | 8273 | `70a6ed3252de` |
| `运行任务ID诊断.command` | 134 | `196bfff47cef` |
