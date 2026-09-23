# 0.3.3 安装默认选择 Codex 与 WorkBuddy

2026-09-17，用户要求安装时默认选择列表中的 Codex 与 WorkBuddy。

## 已完成

- 在固定目录恢复 `com.tencent.workbuddy.mac` → WorkBuddy，范围共十项，App Store 仍删除且旧选择仍拒绝。
- 安装器在安装和 Key 加密保存成功后，向助手偏好域写入 `OnlineCompletionScopes.v1`。首次仅 Codex 与 WorkBuddy 为 true；升级只填缺失值，显式 false、其他应用及其他范围字段保持。默认合并幂等，不会因重装重新启用已取消项。
- 默认配置只由安装器应用，不在每次启动时重置。仍允许设置里随时取消、全部取消；其余设置结构及 Key 必填不变。
- WorkBuddy 复用现有输入/当前任务上下文适配；敏感输入保护保持。安装器明确显示两个默认范围及输入/可用任务上下文用于在线续写。

## 验证

- `make online-scopes-test settings-window-test application-policy-menu-test test` 通过。覆盖十项精确目录、WorkBuddy 启用/取消/上下文模式/敏感拒绝、App Store 拒绝及现有生命周期回归。
- 安装器自测 26 项通过：新增首次仅两项、升级保留选择、重装保持取消、幂等合并；原有加密 Key、精确旧版升级/备份、签名/损坏拒绝检查保持。
- CUA 原生设置预览使用真实 SettingsWindowController 与安装默认合并函数、合成状态；AX 和截图均确认 Codex、WorkBuddy 为勾选，其余八项不勾选，无 App Store，十项一屏无截断。已关闭窗口和精确预览进程。此结果不是当前安装应用 UI 的验收。
- 构建及安装器/嵌套应用严格验签通过；只读挂载 DMG 验证完整新旧载荷清单、安装说明、源码快照 222 文件及当前源码哈希，测试卷已卸载。
- 当前安装已由用户升至 0.3.2，精确载荷与新版升级清单一致；当前助手 PID1291，Codex1809/模型819。本轮未修改真实 Key、偏好、运行应用或启动服务。

## 交付与边界

[0.3.3 DMG](../../outputs/续言-0.3.3-macOS-arm64/续言-0.3.3-Apple芯片.dmg)，支持已交付的精确 0.3.2 升级、同包重装及全新安装。Apple Silicon / macOS15+；个人 ad-hoc 未公证包，真实 dirty 元数据与源码快照，不放宽通用 clean 更新门槛，无提交/推送/外部发布。详细证据见 [结果目录](../evaluation/results/default-scopes-2026-09-17/)。

退出旧续言，打开新安装器并填写 Key 后安装；已有范围选择保留，未配置的 Codex/WorkBuddy 自动勾选。0.3.3 未安装到当前用户；全新 macOS 用户权限、真实 Key 安装写入和最终包在 Codex/WorkBuddy 的联网与实体 Tab/Esc 未验证，S1 阶段保持。

DMG SHA256：`9a44675b3482de9100b09584f284059521f41cce6ad83614437fdfeed788ac62`。
