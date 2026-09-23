# 限定助手迁移与运行身份复核

日期：2026-09-08。起因是[运行映射与安装包不一致](2026-09-08-runtime-mapping.md)。按用户此前仅更新助手、禁止重启 Codex/模型的授权执行限定迁移；不是通用事务适配器验收。

## 迁移前提与实际操作

候选为 clean `21733bbaca7cffba0f6876384d27806762e3c5b2`，已通过完整离线检查覆盖的应用实现、后续映射回归、强制构建及严格 codesign。迁移前再核对嵌入/包内构建身份一致、HEAD clean、当前安装哈希、三进程身份及映射文件哈希。`git diff e1b4154 55acacb -- Sources Makefile Resources` 为空，两旧身份对应的退出逻辑均已移除模型 stop；没有执行未知旧包的 `--build-info`。

先在同卷私有目录创建并复验新旧包副本，再仅 bootout 固定助手服务，确认没有助手进程，保留原安装目录并换入候选。由保留原 LaunchAgent 配置、仅将 ProgramArguments 换成安装可执行文件及 `--preserve-resident-model` 的私有 plist bootstrap 同一助手 label。未重写 `~/Library/LaunchAgents/local.codex.prompt-assistant-app.plist`，未运行旧 Makefile service-start/install，未操作模型或 Codex 服务。

脚本限定为此次记录的旧 PID、旧包和映射哈希。任一步异常写现场并停止，没有反复重启或自动启动不支持保护的旧包；因此不把此次成功称为已验证自动运行回滚。

## 已确认运行结果

| 对象 | 迁移前 | 迁移后 |
| --- | --- | --- |
| 助手 PID / 启动时间 | 4085 / 2026-09-08 11:52:44 | 21889 / 2026-09-08 15:19:27 |
| Codex PID / 启动时间 | 48607 / 2026-09-07 16:56:15 | 相同 |
| MLX PID / 启动时间 | 56047 / 2026-08-27 20:08:55 | 相同 |
| 本地/远程 paused | 0 / 0 | 0 / 0 |
| 助手映射与安装包 | 不同 inode | 路径/device/inode 一致，inode 177532168 |

新助手启动日志为 PID 21889、commit `21733bb…`、dirty=0；进程参数明确含 `--preserve-resident-model`。安装包严格验签通过，可执行文件 SHA256 为 `c2b86ad006f20e8cdb33d6128d3399097d04108b7b68d988e1526484ff8fc910`。这恢复了此次新启动的磁盘、启动声明与映射对象一致性；不代表读取了进程全部内存或证明 UI 全场景正确。

运行必需目录：`~/Applications/.cpa-limited-migration-ex6xnryo/`。其中 `guarded-helper.plist` 是本次已加载服务的来源，`original.app`/`prepared/rollback.app` 是原安装备份，`original-helper.plist` 是原服务配置。**不能作为临时缓存删除该目录。** 原规范 LaunchAgent 文件 SHA256 仍为 `deb44cbaffc747965de5984232539b463ddecf027f610ccfd5fed121623b95f2`。本次会话重载使用私有 plist；未来普通登录/手动走原启动入口不自动保证传入保护参数，须另验收持久部署流程。

本机操作证据：`/tmp/cpa-limited-migration.py`、`/tmp/cpa-limited-migration.log`、`/tmp/cpa-limited-migration-result.json`，目录内 `migration.json` 保留前后身份。未提交真实诊断日志或用户输入。

最终文档提交后的构建身份检查曾因工具导入生成的 `Tools/Release/__pycache__` 未忽略而失败（dirty=true）；补充 Python 字节码目录忽略规则后重新构建复核。该失败只涉及仓库构建产物，已安装 `21733bb` 的哈希与映射未改变。

## TextEdit 无发送实测

新建独立空白文稿，初始仅有本次文稿且为空；未打开或改写用户旧草稿。固定输入：`请整理项目复盘的核查步骤，并将已验证结果与待确认事项分开`。

| 项目 | 本次结果 |
| --- | --- |
| 推荐模式显示候选 | 通过；规则为 mode=0、searchException=false、remoteAuthorized=false |
| Tab 实际插入 | 通过；浮层候选 `，确保每项任务有明确归属和跟进责任。` 插入到固定原文末尾，读回内容一致 |
| 关闭后无候选 | 切换 TextEdit 关闭后，返回测试文稿观察 2 秒，助手浮层窗口为 0；尚不据此宣称完整即时隐藏延迟指标 |
| 同一非空文本重新启用 | 已恢复推荐规则，但连续观察被前台切换中断，未验证恢复候选 |
| 空输入、Esc、浏览器/敏感矩阵 | 本记录阶段未完成 |

一次菜单点击在目标已变更时被预检中止，没有误改其他应用规则。测试结束前已回读 TextEdit 的完整原规则恢复。实机前台被切换，多次观察中断，已询问可占用前台的时间；没有为绕过焦点验证取消保护。

## 剩余边界

一般服务适配器、失败后的真实恢复启动、模型服务缺失故障、旧包自动回滚、全量无发送矩阵未完成。B-02/B-04 现在已安装；TextEdit 只证明所测通用输入与接受路径，不能证明 Codex 的读前门禁、多任务窗口竞态或 WPS 支持。B-01 和 M0 整体门禁继续按状态页跟踪。
