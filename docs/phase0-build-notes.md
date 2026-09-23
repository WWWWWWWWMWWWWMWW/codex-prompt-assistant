# 阶段 0 构建说明

## Swift 工具链现场结论

本机 Command Line Tools 的 Swift 编译器、SwiftPM Manifest API 和系统模块存在版本不一致：

- `swift test` 在最小 `Package.swift` 链接阶段缺少匹配的 `PackageDescription.Package` 符号。
- 直接使用 `swiftc` 构建 AppKit 时出现重复 `SwiftBridging` 模块和系统框架模块加载失败。
- 问题发生在业务源码类型检查之前，属于本机 Swift 工具链，不是原型代码错误。

阶段 0 不要求 Swift 特性，因此验证工具使用系统 Clang、Objective-C 和 AppKit 构建，避免修改或重装用户的开发环境。正式产品开始前再单独决定是否修复 Swift 工具链或继续沿用 Objective-C 外壳。

## 当前验证状态（2026-08-20）

- 已构建独立菜单栏 App，不修改 Codex 或 `mergeclient`。
- macOS“辅助功能”列表已出现 `CodexPromptAssistantPOC`，并由用户确认后开启。
- 已实现 Codex 前台输入框探测、不抢焦点候选条、650ms 停顿触发、Tab 接受、Esc 取消。
- Codex 返回的光标矩形不可用，阶段 0 已按设计降级为输入框上方候选条，不宣称原生 Ghost Text。
- 已增加中文输入法保护：潜在组词状态以及可信候选窗口可见时，Tab/Esc 原样交给输入法。
- `make test` 三组测试、严格警告构建、Info.plist 检查和临时签名校验均已通过。
- 用户已完成 Codex 实机验证：搜狗候选阶段 Tab 未被截获；空格选词后再次按 Tab，固定建议成功插入且焦点未跳到模型选择器。阶段 0 可行性门槛通过。

阶段 0 固定测试建议是“，这是阶段 0 的测试建议”。当前版本不读取或保存输入正文，不访问网络，也不包含 API 地址或密钥。

### 辅助功能授权与开发签名

首次实机测试没有显示灰字。无正文诊断日志确认应用启动时 `permission=false`、`event_tap start=false`；检查签名发现临时签名的 designated requirement 默认绑定每次构建都会变化的 CDHash。因此系统设置虽然仍显示开关开启，新构建实际上已经失去授权。

构建现已改用固定 designated requirement `identifier "local.codex.prompt-assistant-poc"`。需要对这一稳定身份重新开启一次辅助功能权限；之后还需用“重建—重启—检查权限”验证授权是否能跨构建保留。

### Codex 光标定位降级

Codex 的 `AXTextArea` 可以返回选区索引和输入框整体边界，但 `AXBoundsForRange` 返回的是零尺寸占位矩形 `{{0, 1080}, {0, 0}}`，不能用于贴光标显示。验证版会拒绝这个假坐标，并使用输入框整体边界显示候选条。2026-08-18 实机已确认候选条可见，Esc 可取消，Tab 可一次性插入固定建议。

### 中文输入法保护

首轮搜狗拼音候选测试失败：候选窗可见时 Tab 仍被助手截获。系统没有把该候选窗稳定暴露成可枚举的独立窗口，因此不能只依赖窗口扫描。

修正后使用本地状态判断：中文输入源下输入拼音字母或撇号即进入潜在组词状态；空格、数字选词、回车或鼠标操作后退出。潜在组词状态的 Tab/Esc 原样交给输入法。

第二轮实测发现，搜狗输入法常驻的菜单栏状态项（顶部、`layer 25`、158×24）会被旧窗口规则误判成候选框，导致选词后的第二次 Tab 被放行并把焦点切到 Codex 模型选择器。窗口判断现已排除顶部高层级的菜单栏尺寸窗口，并补充回归测试；正常候选面板仍可识别。

最终实测日志依次出现 `shortcut pass_through=ime ... composition=true`、`shortcut action=accept` 和 `post_text characterCount=13`。用户输入结果为“菜色，这是阶段 0 的测试建议”，确认中文候选保护与选词后接受建议均正常。

### 当前签名限制

本机没有有效的 Apple 代码签名证书。临时签名即使写入固定 designated requirement，仍不能作为正式发布方案；本轮最终重建后授权继续有效，但后续构建若出现 `AXIsProcessTrusted=true` 且焦点读取失败，仍需从辅助功能列表移除并重新添加。正式交付需要 Apple Development/Developer ID 签名。
