# B-01 更新与回退副本准备验收

日期：2026-09-08。范围：B-01 第一包，增加实际可使用的包准备/复验工具及隔离故障测试；不安装、不重载、不操作服务。本记录不证明一般更新失败后的运行恢复成功。

## 已确认原因与改动

现有 `prompt-assistant-service-install` 直接 ditto 到安装路径，`prompt-assistant-service-start` 先 bootout 再调用安装；中途失败可留下停止的助手或被覆盖的包。回滚时重跑 start 还会从当前工作树构建覆盖目标，不能作为可靠回滚路径。本轮没有执行或改写这些部署目标。

新增 `Tools/Release/prepare_update.py`：明确候选提交与安装包哈希；严格验签新旧包；在独立私有目录复制 `candidate.app` / `rollback.app`；逐包比较内容/权限和身份并复核源包；最后写清单。准备工具只允许 CLI 写入仓库 `.build/update-preparations`，不执行包，不调用 launchctl，不改配置或 LaunchAgent。`verify` 重新读取固定文件名并验签比对，不采信清单中的任意路径。

准备失败保留本次不完整副本，不写成功清单、不覆盖源包或已有准备目录。一般服务更新仍须后续实现与验收。

## 隔离测试证据

`make release-preparation-test` 已通过 17 项测试，已并入 `make check-offline`。公共目标经既有隔离器断网并拒绝对安装目录、正式数据、LaunchAgent 的写入及 launchctl 执行。

| 场景 | 已检查结果 |
| --- | --- |
| 正常准备、源目录之后不可用 | 两个独立副本仍可复验；rollback 哈希对应旧包，不是候选包 |
| 候选/回退复制失败，复制后损坏 | 无成功清单，源包字节/权限摘要不变 |
| 新旧源包/复制包/最后复核共六处验签失败 | 不产生成功清单，不改变源包 |
| 期望提交或安装哈希错误、dirty/legacy/错 bundle ID/畸形元数据 | 复制前拒绝 |
| 检查期间变更、准备期间源包被并发修改 | 拒绝准备完成，不改旧安装源包 |
| 清单写入失败、复制期间 KeyboardInterrupt | 残留目录无法通过复验，不视为完成 |
| 重用目录、路径越界、符号链接 | 拒绝覆盖/不支持的路径 |
| 回退副本内容/权限变更、清单缺回退记录 | 复验失败 |
| 真正 ditto、真正 codesign 拒绝无签名合成包 | 复制后摘要一致；合成可执行文件从未运行 |

多数故障用例注入验签替身；不将替身断言写成真实签名验证。首轮有一项测试因 `/var` 与 `/private/var` 路径别名没有注入到目标；修正夹具匹配为 resolved path 后，该并发变更用例通过。

## 真实包准备与运行边界

本轮另在隔离器内调用实际准备 CLI，使用原有 clean `1226e5d49c990ddd60e7b7bdf71d9a061fbc56f5` 构建与当前安装 clean `e1b4154fb5a504d9abf2d341202b8ed1d2115df9`。真实 ditto、全部严格 codesign 与副本复验通过，目录 `.build/update-preparations/b01-baseline-1226e5d`。

- 候选可执行文件 SHA256：`47f1d6167a31092da9f892cb278c64f9627ef12f356ad5418ea4dea5663b4bba`。
- 回退/原安装可执行文件 SHA256：`33f6b293456190d16b2c02cdc16dfb45a94e7762327197e1a1b12a2a1233abdc`。
- 准备清单固定状态为 `prepared-artifacts-only`，不包含运行成功或恢复成功声明。

本轮命令日志保存在 `/tmp/cpa-b01-preparation-tests.log`、`/tmp/cpa-b01-isolation.log`、`/tmp/cpa-b01-real-preparation.log`、`/tmp/cpa-b01-real-verify.log`；属于本机临时证据，不是提交产物。

`make check-offline`（含 `make test`、`make remote-completion-test`）、`make -B app` 和严格 codesign 均通过，日志 `/tmp/cpa-b01-offline.log`、`/tmp/cpa-b01-build.log`。提交前 `git diff --check` 通过；最终提交后按 release 流程重新构建并核对 clean HEAD 身份。

准备、测试和构建前后只读复核一致：

| 进程 | 前/后 PID | 前/后启动时间 |
| --- | --- | --- |
| 助手 | 4085 / 4085 | 2026-09-08 11:52:44 |
| Codex | 48607 / 48607 | 2026-09-07 16:56:15 |
| 常驻 MLX | 56047 / 56047 | 2026-08-27 20:08:55 |

原安装哈希仍为上列 `33f6b293…abdc`；本地/远程 paused 回读均为 `0`。这些记录证明本轮未替换运行基线，不证明新构建 UI 已验收。

## 未验证与下一包

未执行真实停止、替换、bootstrap、失败后的恢复启动，也未做新包 UI 验收。B-01 没有整体关闭，M0 运行门禁不变。工具不判断旧包退出是否会停止模型，也不判断模型服务缺失时新包是否会 bootstrap；正式操作前仍必须解决这些生命周期条件。

下一包围绕助手独立生命周期建立有限更新事务和服务故障注入：备份身份复核、停止结果不确定、启动失败、恢复副本失败、恢复启动失败、模型服务缺失时拒绝操作。运行回退必须使用已验证旧副本，禁止调用从当前工作树重建的 start。通过后再选择限定助手安装路径，补 B-02/B-04 的无发送实机矩阵；不得重启 Codex 或模型。
