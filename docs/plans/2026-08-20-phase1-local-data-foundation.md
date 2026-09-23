# 阶段 1 本地数据底座实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task.

**Goal:** 只读、流式、可恢复地采集 Codex 根用户任务和 ChatGPT 导出历史，经过脱敏后幂等写入本地资料库，并支持对账与重建。

**Architecture:** Codex JSONL 和 ChatGPT 导出分别由来源适配器规范化为统一消息；原始来源永不回写。采集先通过敏感信息扫描，再进入 SQLite；游标只提交到最后一条完整记录，派生索引可清空重建。首批只做内存解析和计数，不在加密方案落定前持久化聊天正文。

**Tech Stack:** Objective-C、Foundation、SQLite3、CommonCrypto／macOS Keychain（加密方案需在持久化前单独验证）、Clang Makefile。

---

## 批次 A：Codex 只读采集核心

### Task 1：流式 JSONL 行读取器

**Files:**
- Create: `Sources/CodexDataCore/JSONLLineReader.h`
- Create: `Sources/CodexDataCore/JSONLLineReader.m`
- Create: `Tests/CodexDataCoreTests/JSONLLineReaderTests.m`
- Modify: `Makefile`

**Step 1: 写失败测试**

测试覆盖：64KB 以上长行、CRLF、末尾半行、从已确认字节偏移继续读取；断点必须停在最后一个换行符之后。

**Step 2: 运行测试确认失败**

Run: `make data-core-test`

Expected: 编译失败，提示 `CPAJSONLLineReader` 未定义。

**Step 3: 最小实现**

使用 `NSFileHandle` 分块读取；缓冲区只保留尚未形成完整行的字节。回调只收到换行终止的完整记录，并返回 `safeOffset` 与 `trailingByteCount`。

**Step 4: 运行测试确认通过**

Run: `make data-core-test`

Expected: `PASS: JSONLLineReaderTests`。

### Task 2：Codex 规范记录解析器

**Files:**
- Create: `Sources/CodexDataCore/CodexSourceMetadata.h`
- Create: `Sources/CodexDataCore/CodexSourceMetadata.m`
- Create: `Sources/CodexDataCore/CodexMessage.h`
- Create: `Sources/CodexDataCore/CodexMessage.m`
- Create: `Sources/CodexDataCore/CodexRecordParser.h`
- Create: `Sources/CodexDataCore/CodexRecordParser.m`
- Create: `Tests/CodexDataCoreTests/CodexRecordParserTests.m`
- Create: `Tests/Fixtures/Codex/root-task.jsonl`
- Create: `Tests/Fixtures/Codex/subagent-task.jsonl`

**Step 1: 写失败测试**

测试要求：

- 只接受首条 `session_meta.payload.thread_source=user` 的文件。
- `subagent` 必须整体排除。
- 只读取 `response_item/payload.type=message` 中 role 为 `user` 或 `assistant` 的消息。
- user 只收 `input_text`，assistant 只收 `output_text`；developer、reasoning、tool call/output、图片二进制全部排除。
- `event_msg/user_message` 与 `event_msg/agent_message` 不作为第二份消息，避免重复。
- 有 `## My request:` 包装时只保留其后的用户请求；独立 `<image ...>` 标记不进入正文。
- 使用 `payload.id` 作为稳定消息 ID，保留来源行号和时间。

**Step 2: 运行测试确认失败**

Run: `make data-core-test`

Expected: 编译失败，提示解析器未定义。

**Step 3: 最小实现**

用 `NSJSONSerialization` 逐行解析；未知顶层事件计数但不失败，元数据结构不支持时将整个来源标为 unsupported。解析器不打印正文，不访问网络。

**Step 4: 运行测试确认通过**

Run: `make data-core-test`

Expected: `PASS: CodexRecordParserTests`。

### Task 3：active／archived 来源发现与对账

**Files:**
- Create: `Sources/CodexDataCore/CodexSourceScanner.h`
- Create: `Sources/CodexDataCore/CodexSourceScanner.m`
- Create: `Tests/CodexDataCoreTests/CodexSourceScannerTests.m`
- Create: `Tools/CodexHistoryProbe/main.m`
- Modify: `Makefile`

**Step 1: 写失败测试**

临时目录中放置 root、subagent、损坏首行、非 JSONL 和 active→archived 重名样本；测试 root/subagent/unsupported 数量与按 thread ID 去重。

**Step 2: 运行测试确认失败**

Run: `make data-core-test`

Expected: 编译失败，提示 scanner 未定义。

**Step 3: 最小实现**

扫描两个明确目录，不跟随未知符号链接；只读取每个 `.jsonl` 第一条完整记录进行分类。若同一 thread ID 同时在 active 和 archived 出现，优先 archived 路径但只计一次。

命令行探针只输出来源数、消息数、排除数、unsupported 数、半行数和耗时；绝不输出正文、cwd 或文件名。

**Step 4: 自动与实机验证**

Run:

```bash
make data-core-test
make history-probe
build/CodexHistoryProbe ~/.codex/sessions ~/.codex/archived_sessions
```

Expected: 数量会随任务新增而增长，但 root + subagent + unsupported + duplicate 必须与磁盘来源对账。2026-08-20 首次通过记录：113 个文件、92 个 root、21 个 subagent、0 个 unsupported、0 个 duplicate、6069 条可见消息、0 个解析错误，耗时约 8.1 秒。

**Checkpoint A:** 评审真实扫描结果与抽样结构报告，确认后才允许持久化正文。

---

## 批次 B：脱敏、SQLite 与增量恢复

### Task 4：敏感信息脱敏器

**Files:**
- Create: `Sources/CodexDataCore/SensitiveTextRedactor.h`
- Create: `Sources/CodexDataCore/SensitiveTextRedactor.m`
- Create: `Tests/CodexDataCoreTests/SensitiveTextRedactorTests.m`

**Steps:** 先用合成测试覆盖 API Key、Bearer/JWT、私钥、密码字段、带 token URL、邮箱和手机号；确认失败后实现占位符替换。日志只允许字符数、类型与哈希，不允许原文。

### Task 5：加密持久化技术门槛

**Files:**
- Create: `docs/adr/0004-local-message-encryption.md`
- Create: `Tools/CryptoProbe/main.m`
- Create: `Tests/CodexDataCoreTests/CryptoEnvelopeTests.m`

**Steps:** 在 SQLCipher、应用层 encrypt-then-MAC、仅依赖 FileVault 三条路线中做现场验证。没有通过篡改检测、错误密钥、随机 nonce、重启解密和钥匙串读取测试前，不得建立真实聊天库；不得把 Key 写进测试夹具。

### Task 6：SQLite 原始层与幂等导入

**Files:**
- Create: `Sources/CodexDataCore/LocalDataStore.h`
- Create: `Sources/CodexDataCore/LocalDataStore.m`
- Create: `Sources/CodexDataCore/Schema.sql`
- Create: `Tests/CodexDataCoreTests/LocalDataStoreTests.m`

**Steps:** 先测试同一来源导入 3 次消息数不增长，再建立 `sources`、`source_cursors`、`conversations`、`messages`、`import_runs`。唯一键使用 source kind + thread ID + message ID；正文按 Task 5 的已接受方案保存。

**2026-08-20 检查点记录：** Task 4～6 已完成。8 类合成秘密脱敏、加密信封、跨进程钥匙串、三次幂等导入、参数化 SQL、数据库明文扫描和 `0600` 权限均通过；尚未导入真实历史，下一步执行 Task 7。

### Task 7：增量游标、崩溃恢复与重建

**Files:**
- Create: `Sources/CodexDataCore/CodexIncrementalImporter.h`
- Create: `Sources/CodexDataCore/CodexIncrementalImporter.m`
- Create: `Tests/CodexDataCoreTests/CodexIncrementalImporterTests.m`
- Create: `Tools/CodexDataRebuild/main.m`

**Steps:** 模拟半行、追加完成、截断、inode 变化、active→archived 和中途崩溃。只有事务提交后才推进 safeOffset；重建清空可派生数据但不修改源文件。

**2026-08-20 检查点记录：** Task 7 已完成。游标保存 device、inode、safeOffset、绝对行号、文件大小和解析器版本；消息、导入运行记录与游标在同一 SQLite 事务提交。合成测试已覆盖半行补齐、重启、重复扫描、截断、inode 更换、active→archived、失败回滚和 v1→v2 schema 迁移。重建工具只允许新建 `.staging.sqlite3`，使用独占创建并拒绝覆盖；集成测试只使用合成来源与临时钥匙串项。

**Checkpoint B:** 已通过。重复扫描、重启、归档移动和事务失败恢复均已验证；尚未导入真实历史，接入常驻应用仍需单独批次与用户确认。

---

## 批次 C：ChatGPT 导出与应用接入

### Task 8：ChatGPT 导出包事务式导入

**Files:**
- Create: `Sources/ChatGPTImportCore/ChatGPTExportImporter.h`
- Create: `Sources/ChatGPTImportCore/ChatGPTExportImporter.m`
- Create: `Tests/ChatGPTImportCoreTests/ChatGPTExportImporterTests.m`

**Steps:** 使用合成 zip 覆盖正常分支会话、重复导入、未知 schema、路径穿越、zip bomb 尺寸限制和取消回滚。未知版本必须整次失败，数据库保持不变。

**2026-08-20 检查点记录：** Task 8 已完成合成验证。ZIP 只读映射、不解压到磁盘；只接受唯一的根目录 `conversations.json`，按 `current_node` 回溯当前可见分支，并排除 system/tool/developer 与未选分支。顶层数组逐会话拆分，每个会话解析后写入同一个 SQLite 导入事务，未知结构、取消、CRC／deflate 错误或安全限制失败时整包回滚。标准 ZIP 的 stored 与 raw-deflate、重复导入三次、路径穿越、声明尺寸炸弹、正文篡改和取消回滚均通过；ZIP64、加密 ZIP 和真实 ChatGPT 导出包尚未验证，明确失败而不做猜测兼容。

### Task 9：常驻应用状态与进度

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Create: `Sources/CodexPromptAssistantPOC/DataFoundationController.h`
- Create: `Sources/CodexPromptAssistantPOC/DataFoundationController.m`
- Modify: `Resources/Info.plist`

**Steps:** 菜单栏显示“未扫描／扫描中／已同步／部分失败”，允许暂停、重扫和查看仅含计数的诊断。索引期间不得访问网络；解析失败隔离单文件，其余来源继续。

**2026-08-20 检查点记录：** Task 9 已完成代码与合成验证。常驻应用启动时保持“未扫描”，不创建正式数据库；首次点击“扫描并导入 Codex 历史”还会显示本地加密、排除范围和零网络确认。控制器在单串行队列上逐文件提交，支持文件边界暂停、继续时幂等重扫、坏文件隔离和纯计数诊断；同一 thread ID 的 archived 来源优先于 active，未知 `thread_source` 明确失败而不是伪装成 subagent 跳过。正式数据库目录限制为当前用户 `0700`，数据库以 `O_NOFOLLOW` 校验普通文件、所有者与硬链接数。合成测试覆盖 2 个 root、1 个 subagent、1 个 active 重复、1 个坏文件、1 个未知来源、重复扫描、200 文件暂停／继续和数据库符号链接目标不被改写。自动测试、ASan、Clang Analyzer、plist 与签名检查通过；菜单栏视觉因 computer-use 无法附着无主窗口状态栏应用而尚未验证，未点击真实扫描入口。

**2026-08-20 检查点记录：** Checkpoint C 的原始数据层验收已完成。schema v3 新增来源墓碑；删除 Codex 来源或 ChatGPT 会话时，来源、会话、消息和游标在同一事务中级联删除，墓碑保留。后续增量扫描在读取正文前快速跳过墓碑来源；重建工具先从旧库只读继承墓碑，再扫描源文件，已删除来源不会因旧 JSONL 仍在磁盘而复活。损坏墓碑库、最终文件符号链接和已存在 staging 目标均失败关闭。

10 万条纯合成消息在禁网沙箱中的最终普通构建结果为：首次导入 6.763 秒、重复扫描 0.004 秒、1000 次随机解密读取 p95 0.013ms、删除后墓碑跳过 0.098ms，SQLite／WAL／SHM 的合成私密标记明文检出为 0。重复导入、ChatGPT 会话删除后重导入和 Codex 删除后重扫都未新增消息；应用二进制未链接 CFNetwork／Network，也没有 socket 类未定义符号。

**Checkpoint C:** 原始聊天数据层已通过，阶段 1 的技术实现结束。当前项目尚无表达库表，因此这里不宣称“表达删除后重建不复活”；该能力必须在阶段 2 建立表达来源关系、黑名单／墓碑和派生库重建后单独验收。仍未导入任何真实聊天，Task 9 菜单栏视觉也保持“未验证”。
