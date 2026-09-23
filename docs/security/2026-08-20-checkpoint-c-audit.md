# Checkpoint C 安全审计

日期：2026-08-20

## 结论

本次审计没有遗留 Critical 或 High 风险。来源删除使用 SQLite 原子事务写入墓碑并级联删除正文；增量扫描和重建均识别墓碑，旧来源文件仍存在时也不会让已删除聊天复活。所有动态 SQL 参数继续使用绑定变量，重建工具只输出计数和错误类别，不输出来源 ID、正文或路径。

## Critical

无。

## High

无。

## 已修复

1. **损坏墓碑库失败开放**
   - 原始风险：检查 `sqlite_master` 时若 `sqlite3_step` 返回损坏错误，旧逻辑可能把它等同于“表不存在”，随后继续重建并复活已删除来源。
   - 修复：只有 `SQLITE_ROW` 和 `SQLITE_DONE` 是合法结果；其他状态立即停止，且 staging 数据库尚未创建。
   - 证据：非 SQLite 文件作为墓碑来源时返回 `tombstone_source` 失败，目标文件不存在。

2. **墓碑来源符号链接与路径竞态**
   - 原始风险：仅在打开前 `lstat` 会留下最终文件被替换的时间窗口。
   - 修复：先拒绝最终路径本身为符号链接并要求普通文件；再用 `realpath` 规范化 macOS `/var` 等系统父目录链接，最后让 SQLite 以 `SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_READONLY` 打开最终文件。
   - 证据：墓碑来源符号链接夹具失败关闭；合法临时目录中的普通数据库可以继承墓碑。

3. **删除后重新导入复活**
   - 原始风险：只物理删除正文而不保留用户决定，会在下一次增量扫描或导出包重导入时恢复内容。
   - 修复：schema v3 保存不含正文的 `(kind, external_id)` 唯一墓碑；Codex 在解析首行元数据后、读取其余正文前跳过，ChatGPT 导入事务也按会话跳过；重建先复制所有来源类型的墓碑。
   - 证据：Codex、ChatGPT 和重建集成测试的来源、会话及消息计数均未复活。

## Medium

1. **主密钥轮换仍未实现**
   - 影响与后续：与前序审计一致；真实聊天正式导入前仍需设计事务式 rekey 和失败回滚。

2. **表达级删除尚不存在**
   - 影响：当前只能删除整段来源聊天，不能单独屏蔽一条未来抽取出的表达。
   - 后续：阶段 2 必须让表达库成为可重建派生层，并为表达黑名单／墓碑建立独立测试；当前验收不得扩写为表达删除已完成。

## Low

1. **墓碑外部 ID 是 SQLite 明文元数据**
   - 当前 Codex thread ID 和 ChatGPT conversation ID 都是机器标识，不含正文；这样才能在没有解密正文时快速阻止复活。
   - 若未来某来源使用可读标题作为外部 ID，适配器必须先改为稳定的不透明映射。

2. **同 UID 恶意进程仍不属于完整防护范围**
   - `NOFOLLOW`、只读打开、私有目录和文件权限可防普通链接攻击；拥有同一用户权限的恶意进程仍可能修改应用、来源或钥匙串上下文。
   - 若未来威胁模型要求抵御同 UID 进程，需要沙箱容器、受保护 helper 或自定义 SQLite VFS。

## 已执行证据

- `make data-core-test`：所有数据核心、重建和 ChatGPT 导入测试通过。
- `make checkpoint-c-test`：在 `(deny network*)` 沙箱中完成 10 万条导入、幂等重扫、随机读取、删除重扫和数据库明文扫描。
- AddressSanitizer：10 万条探针与 ChatGPT 删除后重导入测试均通过。
- Clang Analyzer：CodexDataCore、ChatGPTImportCore、数据控制器、重建工具和性能测试无诊断。
- 应用边界：plist 和临时签名有效；`otool -L` 无 CFNetwork／Network；`nm -u` 无 socket/connect/send/recv/getaddrinfo 等符号。
- 秘密扫描：源码、测试和文档未检出用户服务地址、旧 Key 或通用长 `sk-` 形态。
