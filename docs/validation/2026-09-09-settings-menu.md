# 设置菜单整理

## 范围

根据用户菜单截图，保留 AppKit 原生菜单，将应用规则、历史数据和技术诊断分层。只修改 main.m 的 configureStatusItem；保留开始时已有的图标、构建资源和其他文档改动。本轮没有提交、安装或重载，也没有修改补全设置、模型或提示词。

主菜单顺序：智能补全状态、设置智能补全、暂停/继续提示、当前应用/站点、历史数据、高级、退出。当前范围子菜单保留三态规则、搜索例外、联网授权和保护说明；历史子菜单保留扫描、暂停/继续扫描和数据诊断；高级收纳输入框技术状态、恢复服务与原有工具。

规则子菜单不设置 delegate，继续由主菜单一次捕获应用/站点，保存时保留原 PID 校验。各子菜单关闭自动启用，保留策略显式控制的禁用状态。文案改为“使用推荐规则”“启用普通输入补全”“关闭此处补全”“允许搜索框补全”。

## 实际验证

- `make application-policy-menu-test`：通过，覆盖生产动作、三态、搜索、精确站点、保护、失效及即时复检。
- `make application-recovery-test`：通过，恢复入口仍连接原处理逻辑。
- `make app`：通过，包括严格签名验证。
- `make build-info`：磁盘包 GitCommit `ae5fa8e1bdbbd7f6564180522e5102d518a69598`，WorktreeDirty=true，产品 0.2.0/2，PromptVersion 2026-09-09.1。
- `git diff --check`：初检发现新增空行尾部空格，清理后通过。

## 未验证

没有安装或启动新包，因此新菜单的实机视觉、子菜单鼠标/键盘跟踪和真实输入 Tab 未验收。未运行完整测试全集；本次仅菜单结构与文案变化，使用相关现有套件和构建检查。磁盘构建不代表运行版本已更新。

## 用户反馈后安装更新（10:58）

用户反馈菜单未变化，补齐本机助手更新。现场安装包为图标工作包，SHA256 `39e01d555fc7f3d0d8ef56b3d5dbac3c6488117b98faab5560473b1621d12b85`；菜单候选包为上文已验证的 `eab71d1db9e46ac73cbb66c80fc065252fc8b04820ef26cc98e6e49cf254e480`。二者 GitCommit 相同但 dirty 内容不同。

- 沿用现有 guarded-helper.plist 与 `--preserve-resident-model`，仅精确 bootout/bootstrap 助手 label，未修改 LaunchAgent。先同卷暂存验签，再保留原包并替换安装路径。
- 助手 PID 76383（10:54:36）→77132（10:58:11）；启动身份日志与 lsof 可执行映射对应安装路径；安装可执行文件 SHA256 与候选一致。
- Codex PID 48607（9/7 16:56:15）、模型 PID 56047（8/27 20:08:55）前后保持；全量助手 defaults 规范化散列一致。
- 旧包与进程/设置摘要保存在 `/Users/hcm-b0263/Applications/.cpa-menu-sya897hl/previous.app` 及同目录 evidence.json。没有提交或推送。
- 初次预检使用了错误的 launchd label，改用 Makefile 中的实际 label 成功。签名附加 requirement 的两次手写语法失败，均发生在停止/替换之前；改用项目 prepare_update.verify_signature 后通过，未跳过签名检查。
- CUA bundle ID 因多副本歧义失败，按安装路径读取助手超时；Codex 界面访问被工具安全限制拒绝，系统菜单栏读取也超时。没有通过其他 UI 技术绕过限制。新菜单实机视觉及子菜单跟踪仍未验证；安装/启动已完成，不能将界面读取失败表述为未安装。
