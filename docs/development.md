# 开发与验证

面向维护者。命令在仓库根目录运行。依赖 macOS 14+、Xcode Command Line Tools、Python 3，WPS 桩测试另需 Node.js；其他机器的安装尚未产品化。

## 先选择验证层

```sh
git status --short --branch
git diff --check
make help
```

| 改动 / 命令 | 实际覆盖 | 排除与副作用 |
| --- | --- | --- |
| 仅文档 | 本地链接/锚点、源码事实、归档保留、暂存 diff | 不因文档修改重跑模型、UI 或全集；最终构建身份另按 release 复核 |
| `make completion-quality-harness-test` | 评测记录、超时不中断、模型原文/过滤分离、A/B 变量约束、指标与家庭分割 | 网络替身与公开夹具；已并入 make test，不调用模型 |
| `make candidate-lifecycle-test` | Context 修订、任务 ID/剪贴板争用、候选提交与迟到/接受/恢复事件回放，已并入 make test | 合成 SQLite/JSONL 与客户端/浮层/输入替身；禁网，不操作实机 |
| `make test` | 应用策略、恢复、菜单、上下文、输入/浮层相关测试 | 非实机 Tab；公共入口自动隔离诊断日志并禁止联网 |
| `make data-core-test` | 扫描、解析、加密、存储、导入；构建并在合成临时目录执行重建工具 | 只构建 `.build/tests/CodexDataRebuild`，使用临时凭据替身；不覆盖生产重建工具，不验证系统钥匙串授权 |
| `make expression-library-test` | 表达抽取与索引 | 非语义质量评测，不代表模型或当前任务理解 |
| `make remote-completion-test` | 本地/远程协议、HTTP 桩、设置、凭据存储测试 | 不调用真实远程或模型 |
| `make wps-bridge-test` | JS 假宿主 | 不证明 WPS 宿主加载或正文插入 |
| `make build-metadata-test` | 临时 Git 仓库中的构建身份用例 | 不启动助手或模型 |
| `make release-preparation-test` | 更新/回退副本准备的复制、校验、身份变化、损坏和中断故障；真实 ditto 与无签名拒绝 | 合成包/临时目录；多数验签用可注入替身，不调用服务、不安装、不启动包，不证明运行回滚 |
| `make release-transaction-test` | 真实临时文件交换、原包恢复、并发锁及有限失败恢复状态机 | 服务和运行身份为替身；无真实 launchd 操作，不证明真实停止或运行回滚 |
| `make local-model-service-test` | 普通/更新启动参数、模型缺失/查询失败及禁止模型停止 | 服务命令替身，已并入 `make test`；不操作常驻模型 |
| `make model-agent-test` | 按用户目录生成模型启动配置，缺运行程序、已有配置、符号链接与写入失败保护；已纳入 local-model-service-test | 使用临时目录与假运行程序；不加载服务、不下载模型，不代表新机器运行成功 |
| `make local-model-preflight` | 只读检查当前用户模型入口、Python 路径及默认模型缓存；目标用户/JSON 报告见 release | 不执行解释器或服务、不联网、不修复；退出 0 也不代表实际加载或生成通过 |
| `make check-offline` / `make check` | 串行汇总上述构建身份、更新准备与五组核心测试；任一失败返回非零 | 各核心套件分别在 sandbox 内禁网及限制指定写入；隔离验证器含独立沙箱探针，不是全本机资源隔离 |
| `make check-performance` | 合成历史/表达库性能；各测试限制网络 | 不衡量模型或 UI 延迟 |
| `make -B app` | 强制构建、打包、严格签名验证 | 不安装、不启动服务；只是本地 ad-hoc 包 |
| `make local-model-benchmark` / `make completion-quality-benchmark` | 合成输入调用已有本机模型 | 占用模型资源；不等于全面语义验收或使用真实历史 |

`make test` 等公共目标经 `Tools/Testing/run_isolated.py` 分配 0700 临时目录、加测试锁、应用单层 sandbox，再进入 `*-run` 内部目标。编译自动注入独立日志路径；测试凭据用文件替身，生产链接仍用真实 KeychainStore。不要直接运行 `*-run` 或复用 `.build/tests` 中已结束运行的二进制。

macOS 拒绝嵌套 sandbox-exec，因此聚合器串行调用各自受保护的核心套件；隔离验证器自身在外层执行，子进程专门验证拒绝路径。核心套件不能联网、执行 `/bin/launchctl`，也不能写指定安装目录、正式数据目录、助手/模型 LaunchAgent 和运行日志。这里不是全文件系统或 IPC 隔离。公共套件间用文件锁串行化；生产构建和测试仍不应同时编译。

## 已知本机写入与测试失败

| 来源 | 资源与清理现状 | 使用边界 |
| --- | --- | --- |
| `DiagnosticsTests` 及部分集成调用 | 公共测试自动写本次 `/tmp/cpa-tests-*/diagnostic.log`，运行日志写入额外被 sandbox 拒绝 | 结束/失败/SIGTERM 清理本次目录；默认生产日志路径未改变 |
| `CryptoEnvelopeTests` / `CodexDataRebuildTests` | 默认链接 `Tests/Support/FixtureKeychainStore.m`，只接受测试 service，把合成密钥存到同一私有临时目录 | 不调用真实 SecItem API；跨进程重建测试复用同一临时凭据。系统钥匙串访问/授权不在此覆盖范围内 |
| 数据/表达/构建身份测试 | 临时合成数据目录、测试 Git 仓库，以及 `.build/` / `build/` 产物 | 重建测试确实执行工具；不把“合成输入”写成“无写入”。异常残留只处理已确认测试归属 |

B-03 的已知运行日志/真实测试钥匙串污染路径已在默认入口隔离，见 [验收](validation/2026-09-08-test-isolation.md)。其余临时数据、UUID defaults、编译缓存及 `.build/` 仍有本机写入，不能称完全无副作用。SIGKILL/掉电无法保证 finally 清理，可能留合成临时文件，但没有真实测试钥匙串项；只处理已知测试目录，不扫描清理用户钥匙串。

命令失败先保留退出码、失败测试/阶段及合成复现条件，判断是实现、权限还是环境问题。任一失败、跳过或未运行项都单列；不能把退出 0 的最后一条命令当作前面所有命令成功。不要通过删除用户数据、重置全量 defaults 或重启 Codex/模型来让测试通过。

## 只读定位与证据

先核对应用/窗口/控件、策略原因、上下文状态与数量，再定位模型和插入。Ready 不保证非空历史，详情见 [架构](architecture.md)。日志不是完整审计轨迹，可能混入测试项并轮转；只提取经检查的状态/长度/耗时，不能整份提交或宣称所有历史日志已经无敏感内容。

验收使用 [记录模板](validation/TEMPLATE.md)，区分静态、离线、构建、磁盘安装包、运行身份、实机与语义层。签名验证不证明候选质量；无候选不证明零读取；输入“够长”不保证模型一定给建议。

实机用 [无发送夹具](../Tests/Fixtures/InputSafety/README.md)，先检查 [当前阻断](status.md)。模型基准、UI、安装与重载都是独立操作；不因执行测试命令而顺带进行。版本查询与部署限制见 [release](release.md)。

C2 开发实验通过工具专用 G1 模板，不改生产协议；benchmark 现在逐例输出 JSONL，原始输出、拒绝与失败分开。固定配对随机顺序、只读现有模型配置的复跑方式及未验证项见 [C2 记录](validation/2026-09-08-c2-g1-experiment.md)和[数据说明](evaluation/results/c2-g1/README.md)。公开合成集不是独立盲测，模型调用不属于断网核心测试。

`run.py --candidate context-v1` 可复跑上下文状态实验；baseline 不附加状态，候选臂追加状态与使用规则，来源仍是固定合成夹具。未接入运行快照，不代表对象依据问题已修复，详见[该轮验证](validation/2026-09-08-context-grounding-experiment.md)。

`audit_run.py` 单独进行 C3 固定候选的只判不改回放，不运行生成＋审核的在线链路；`audit_report.py` 校验精确候选和全部分母。两版均未接入产品，复跑及实际请求/等待成本见[审核数据说明](evaluation/results/object-audit/README.md)。解析、超时、请求白名单和报告失败计数回归已纳入 `make completion-quality-harness-test` / `make test`，离线测试不调用真实模型。
