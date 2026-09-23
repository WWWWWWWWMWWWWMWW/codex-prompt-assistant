# B-03 默认测试资源隔离验收

2026-09-08。继续产品化流程，本包只处理默认测试的运行日志和真实钥匙串污染路径，未修改候选逻辑、提示词、模型、应用授权或本地/远程开关。源码起点 `55acacb`；运行功能基线保持 `e1b4154`。

## 问题与修改

此前 `make test` 默认编译生产诊断路径，`CryptoEnvelopeTests` 和重建子进程会向真实钥匙串写 UUID 测试项，仅成功路径清理；`data-core-test` 还会构建覆盖生产位置的重建工具。

- 公共核心测试入口统一通过 `Tools/Testing/run_isolated.py` 分配 `/tmp/cpa-tests-*` 私有目录（0700），自动注入诊断路径；成功、非零退出及 SIGINT/SIGTERM 都清理本次目录，公共套件使用文件锁避免同时覆盖测试二进制。
- 默认测试链接 `Tests/Support/FixtureKeychainStore.m`，凭据仅为私有目录中的合成文件（0600）；只接受 crypto-test/rebuild-test service。跨进程重建仍能验证持久化和墓碑行为，不访问真实系统钥匙串。
- 测试重建工具位于 `.build/tests/CodexDataRebuild`；`make data-rebuild` 和正式 app 保留原生产位置与真实 KeychainStore。
- 沙箱拒绝网络、`/bin/launchctl`，以及当前用户 Applications、正式助手数据目录、助手/模型 LaunchAgent、运行诊断日志的写入。macOS 不允许嵌套 sandbox-exec，故聚合器串行调用各自使用单层沙箱的核心套件。隔离验证器本身在沙箱外组织独立拒绝探针；不是全文件系统或 IPC 隔离。

## 实际检查

| 检查 | 结果 / 覆盖 |
| --- | --- |
| 新增隔离回归初次运行 | 预期失败：缺少 runner，公共目标未接入；修复后通过 |
| `make test-isolation-test` | 6 项通过：公共目标路由、无安装命令/无生产重建路径、安装写入拒绝、网络/launchctl 拒绝、成功/失败清理、SIGTERM 清理 |
| `make check-offline` | 完整通过：构建身份、应用、数据核心、表达、远程协议桩和 WPS 桩；隔离回归一并执行 |
| 增补诊断路径断言后 `make test` | 通过；在写日志前确认路径属于当前私有测试目录 |
| 测试二进制符号核查 | CryptoEnvelopeTests、CodexDataRebuild、ApplicationPolicyMenuIntegrationTests、RemoteCompletionSettingsTests 均无 SecItemAdd/CopyMatching/Delete/Update 引用 |
| 私有目录清理 | 从完整离线编译命令提取的 4 个日志/凭据目录均已删除；无日志输出路径的其他套件由 runner finally 清理 |
| 安装包哈希 / PID / 开关 | 修复后完整测试结束仍为原安装哈希，三个进程与双开配置保持原状，见下节 |

完整检查后仅增补隔离和诊断回归，分别重跑对应目标；未无条件重复其余数据/协议套件。构建与最终 clean 身份、严格 codesign 按项目交付规则单独核对，不能以此声称实机插入或语义质量复验。

## 过程中一次误安装与恢复

本轮批量编辑 Makefile 时，字符串替换错误匹配 `prompt-assistant-service-install: app`，把安装 recipe 暂时挂到了测试重建目标。首次数据测试实际复制了先前已有的 `55acacb` 构建包及相同内容的 LaunchAgent plist；没有执行 bootout/bootstrap，三个进程未重启。此轮结果不作为隔离验收通过证据。

发现后已告知用户、修复目标关系；从干净 `e1b4154` 临时 worktree 重建原包，确认可执行文件哈希与测试前完全一致，再经同卷暂存/验签/替换恢复安装目录。恢复过程中没有重启助手、Codex 或模型。LaunchAgent plist 内容核对与原跟踪资源相同；文件复制发生过，不能声称磁盘元数据完全未动。

恢复及最终测试后安装 SHA256：`33f6b293456190d16b2c02cdc16dfb45a94e7762327197e1a1b12a2a1233abdc`。误复制的 `55acacb` 包与原 `e1b4154` 仅有上一轮文档/构建身份差异，无候选代码差异。

随后增加两层防回归：测试目标展开不得包含 ditto/install/launchctl/sign 命令，且沙箱实测拒绝安装目录写入。路径别名探针曾发现 `/tmp` 与 `/private/tmp` 差异，规范化后通过。第一次聚合运行暴露嵌套沙箱 `Operation not permitted`，改为各核心套件单层沙箱后全套通过；失败没有被跳过。

| 对象 | 起始 / 最终 |
| --- | --- |
| 助手 | PID 4085，2026-09-08 11:52:44；未重启 |
| Codex | PID 48607，2026-09-07 16:56:15；未重启 |
| 本地 MLX | PID 56047，2026-08-27 20:08:55；未重启 |
| 配置 | `local-completion.paused=0`、`remote-completion.paused=0` |

## 未覆盖与下一步

- 默认凭据替身不证明真实 macOS 钥匙串授权、锁定、交互或 SecItem 错误处理；生产实现没有被替换或称为已复验。
- SIGKILL/掉电可能保留合成临时目录；UUID defaults、其他测试临时数据、编译缓存和 `.build/` 仍有写入，不能称全机器零副作用。不要为清残留扫描或删除用户钥匙串。
- 本轮未运行模型质量基准、性能基准或实机 UI 矩阵。运行包恢复核验不等于一般部署/回滚流程已全部验收。
- B-03 的指定污染路径已修复；下一包处理 B-02 的 Codex 读前策略与正文读取计数回归。M0 完整运行门禁仍未完成。

临时现场记录：`/tmp/cpa-b03-offline.log`、`/tmp/cpa-b03-app-final.log`、`/tmp/cpa-b03-restore.json`。它们可能被系统清理，本文保留关键事实，不把临时日志当长期交付物。
