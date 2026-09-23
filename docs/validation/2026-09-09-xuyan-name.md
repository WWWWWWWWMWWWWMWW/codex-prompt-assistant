# 正式应用名：续言

用户授权起正式名字并一并修改。选用「续言」，表达接着用户的话继续写，与原版 A 的蓝橙衔接折纸对应。

## 实施与验证

- 对外显示名、菜单退出项及无障碍名称统一为「续言」。zh_CN/en 的 InfoPlist.strings 均提供该正式品牌名。
- 保持包路径、可执行名称、bundle ID、数据目录和 LaunchAgent label 不变。Info.plist 未本地化的 CFBundleName/CFBundleDisplayName 与包文件名对应，实际品牌名由 InfoPlist.strings 提供，以支持 Finder 本地化显示。
- 此方式依据 Apple Core Foundation Keys 的 CFBundleDisplayName 说明：<https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html>。正式命名不构成商标独占性或注册核查。
- 保留已安装的菜单整理和单色图标，在 `.build/icon-refresh` 隔离构建；`make app`、严格签名、`make test`、git diff --check 通过。
- 名称测试最初仍期待旧文案，更新后又发现退出标签多出空格；统一为「退出续言」后重跑完整应用测试通过。Finder 在注册前仍显示文件名，安装并定向 lsregister 后回读为「续言」。
- 安装后 NSFileManager.displayNameAtPath、NSBundle 本地化 CFBundleDisplayName 均为「续言」；启动台 app item 256 的 title 也为「续言」，bundleid 不变。已核实系统条目，不冒充实际截图验收。
- 新助手 PID 80551，启动 2026-09-09 11:06:50；启动日志 ae5fa8e dirty，PromptVersion 2026-09-09.1。安装可执行 SHA256 `65b5173f5d2796da2fbe9ae228d293d4cd7b4de13bf2ebd90905a2e75f76f7b3`。
- 原包保留 `/Users/hcm-b0263/Applications/.cpa-xuyan-pa240upa/previous.app`，同目录 evidence.json 保存进程/开关摘要。
- Codex PID 48607、模型 PID 56047 及启动时间不变；本地、远程 paused 前后均为 0。仅重载助手，未重置设置，未改变补全策略。
- 本轮未复测实机输入或语义质量，无新的截图验收。未提交/推送，保留其他未提交工作。
