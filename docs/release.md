# 构建身份与部署边界

## 当前可安装交付

最新：[续言 0.3.1 指定十项范围版](../outputs/续言-0.3.1-macOS-arm64/续言-0.3.1-Apple芯片.dmg)。仅保留用户选择的十个应用，旧版其他范围不再生效；支持当前精确 0.3.0 升级，安装 Key 必填。见 [验收记录](validation/2026-09-17-selected-scopes.md)。

以下为上一版记录：

最新为 [续言 0.3.0 在线精简版](../outputs/续言-0.3.0-macOS-arm64/续言-0.3.0-Apple芯片.dmg)，设置只有在线续写、Key、多选使用范围；安装 Key 必填。先正常退出旧助手再安装；仅支持精确 0.2.0 基线升级及相同新版重装，保留旧包备份。见 [新版验收与限制](validation/2026-09-17-online-simple-edition.md)。未提交工作区保持真实 dirty 元数据，提供源码快照及文件哈希，通用 clean 发布门槛不变；当前旧版仍运行，等待用户在安装器输入 Key。

以下为上一版记录：

2026-09-17 已生成 [续言0.2.0 Apple芯片DMG](../outputs/续言-0.2.0-macOS-arm64/续言-0.2.0-Apple芯片.dmg)，见 [安装包验收](validation/2026-09-17-installable-package.md)。支持macOS15+、arm64；双击原生安装器后点“安装并打开”，当前用户目录安装，同版直接打开、不同版保留。新安装文件流程11项隔离自测、DMG回读验签及本机同版打开已验证。

这是个人本地ad-hoc签名包，未Apple公证，不含模型或在线账号；其他机器须自备补全来源。它不新增LaunchAgent，不执行跨版本更新，不改变下文的通用发布门槛。精确范围与首次打开说明在DMG内“先读我.txt”。

## 助手启动配置准备（2026-09-17）

维护者可先用 `Tools/Release/helper_agent.py` 生成待审查配置。该工具只为目标用户**已放置在约定位置的包**准备配置，不是首次安装器，也不替代下文更新事务。

```sh
python3 Tools/Release/helper_agent.py \
  --home "$HOME" \
  --expected-sha256 <已核对的安装可执行文件SHA256> \
  --name helper-review-01
plutil -lint .build/helper-agent-preparations/helper-review-01/local.codex.prompt-assistant-app.plist
```

尖括号参数须替换为此前核对的真实散列。工具检查目标用户 `Applications/CodexPromptAssistantPOC.app` 的签名、bundle ID、可执行权限、构建元数据和模型保护能力，再于新目录生成 plist 与最后写入的 manifest；已有输出拒绝覆盖，未完成目录保留供核查。退出码 0 只表示准备完成，`installationReady` 始终为 false。dirty 包只可用于本机配置检查，不放宽 `prepare_update.py` 对 clean 包的要求。

生成参数直接指向目标用户助手并附带 `--preserve-resident-model`；含空格、中文或 shell 特殊字符的用户名均按字面保存。沿用已有 label、RunAtLoad、异常退出重试与节流。该参数意味着助手不会启动缺失模型，也不会在退出时停止常驻模型；**新机器仍须另行准备并启动模型，不能宣称本机开箱可用**。

工具不复制/执行 app，不写 `~/Library/LaunchAgents`，不调用 launchctl、不更改偏好。实际替换旧启动配置前仍需审核差异、备份和验证加载/退出/回退，不能直接拿此目录当已安装状态。它位于 `.build`，不是长期备份；清理构建目录前不要依赖其中的唯一证据。

当前生成结果与实际加载的 guarded plist 逐字段相同；磁盘原 LaunchAgent 仍采用 shell 参数且没有模型保护参数，二者差异只有 `ProgramArguments`。本轮保留原服务配置与运行状态，见 [验收记录](validation/2026-09-17-helper-agent-preparation.md)。旧 `prompt-assistant-service-install/start` 仍有覆盖与模型生命周期风险，未因准备工具完成而获准用于当前更新。

## 模型启动配置按用户生成（2026-09-15）

`Resources/local.codex.prompt-assistant-model.plist` 现在是含 `${CPA_USER_HOME}` 的模板，不能直接复制后加载。使用 `Tools/Release/model_agent.py` 替换解码后的路径字段；参数作为独立 plist 字符串保留，含空格或特殊字符的路径不经过 shell 求值。

先准备一个不存在的输出路径供审查：

```sh
python3 Tools/Release/model_agent.py prepare --home "$HOME" --output .build/model-agent-review.plist
plutil -lint .build/model-agent-review.plist
```

此命令检查该用户目录下 `Library/Application Support/CodexPromptAssistant/mlx-runtime/bin/mlx_lm.server` 是可执行文件，然后生成配置；不执行运行程序、不调用 launchctl、不下载权重。缺运行程序时不创建目标目录或写启动项。生成成功不证明模型缓存、端口、加载和生成能力可用。

安装前可先运行 `make local-model-preflight`，或用 `python3 Tools/Release/model_preflight.py --home <目标用户绝对目录> --json` 查看结构化报告。它只读检查已知 pip 启动脚本是否引用目标目录的 Python、解释器是否存在，以及默认模型 main 缓存的配置/tokenizer/权重分片是否齐全。当前支持标准 Hugging Face 缓存布局；未知启动包装或缓存结构不会推测通过。退出码 0 仅表示文件检查通过，2 表示发现缺失/不匹配，1 表示无法完成目标检查；`runtimeVerified` 始终为 false。

该检查不执行解释器或服务、不联网、无安装和修复副作用，不能证明 Python 依赖/原生库加载、权重校验和、端口归属或生成可用。返回缺失项后先补齐对应安装材料，再进入实际运行验证。2026-09-15 的本机记录确认 Python 来自 `/opt/homebrew/Cellar/python@3.12/3.12.13/…`，复制开发机虚拟环境并不构成另一台 Mac 的安装方案；详情见 [启动前检查验收](validation/2026-09-15-model-preflight.md)。

`make local-model-service-install` 使用同一工具，仅针对当前用户：没有旧配置时以 0600 写入，语义相同则保持原文件，已有不同配置、损坏文件或符号链接则拒绝覆盖。需要修改既有自定义服务时先单独准备、审查和备份，不通过重复 install 覆盖。缓存/日志路径随用户生成；服务 label、模型参数及数据目录的相对布局保持。

`local-model-service-start/stop` 仍会停止或启动模型，**本任务禁止用它们更新助手**；本轮只验收配置准备和隔离测试，未执行这些命令。工具不是模型安装器，也不是通用发布/更新事务。普通用户安装包、模型供给与真实失败回退仍待独立完成。

以下历史部署说明保留原观察时点，当前运行身份以 status 为准。

面向维护者。当前运行版本以 [status](status.md) 为准。历史 clean `49cff39` 已完成[带模型保护参数的限定更新和实机验收](validation/2026-09-08-morning-experience.md)。此前 `21733bb` 的[限定迁移](validation/2026-09-08-guarded-migration.md)解决了旧进程映射与安装包不一致。此前 `e1b4154` 的[开关验收](validation/2026-09-08-provider-switches.md)保留为历史证据。**B-01 一般失败/运行回滚尚未闭合**；具体状态统一见 [status](status.md)。

## 身份分别对应什么

| 字段 / 对象 | 来源 | 能证明什么 / 不能证明什么 |
| --- | --- | --- |
| 产品版本 / BuildNumber | `Resources/Info.plist` | 当前 0.2.0 / 2；不是新的正式分发声明 |
| PromptVersion / 默认本地模型 | `CompletionIdentity.h` | 模板、例子、规则调整需更新契约版本；模型名不是权重校验值，也不代表运行服务实际加载模型已核对 |
| PromptSourceSHA256 | `RemoteCompletionProtocol.m` 自动指纹 | 含同文件提示词及过滤代码；不覆盖所有 Context/Client 行为，不能作完整语义管线版本 |
| GitCommit / WorktreeDirty | 构建时完整 HEAD、暂存/未暂存/未跟踪状态 | dirty 包不能仅靠提交复现；clean SHA 也不能单独保证二进制逐字节可复现，还依赖工具链与配置 |
| 磁盘包 / 可执行文件哈希 | 只读 inspect | 识别查到的包，不是运行中进程；旧包未知身份必须保留 unknown |
| 运行身份 | 对应 PID 与启动时间的嵌入版本启动日志 | 日志缺失或轮转时标未知，不能由安装目录或历史行为基线反推 |

生成器将同一身份放进生成头文件和包内 Info.plist，不改源 Info.plist。运行程序使用编译时身份；每次 `make app` 重核元数据，无变化保留头文件 mtime，有新 HEAD/dirty 状态则重新编译。构建期间不要编辑源码/切分支或并行进行同目录构建。现有生成过程不构成跨多个独立 make 的原子快照保证。

## 只读查询与构建复核

```sh
make build-info
make installed-build-info
codesign --verify --deep --strict --verbose=2 build/CodexPromptAssistantPOC.app
```

inspect 只读磁盘、不启动 App；包不存在会失败，旧包返回 legacy unknown。**仅已确认支持此参数的新构建**可以查询嵌入身份：

```sh
build/CodexPromptAssistantPOC.app/Contents/MacOS/CodexPromptAssistantPOC --build-info
```

该分支在 NSApplication 创建前返回。不得对未知旧安装包使用该参数，否则旧程序可能忽略参数并启动服务。

## Git 交付流程

1. 查看工作区和已有修改，按可独立审查/回退的范围提交；审阅暂存 diff，不提交密钥、真实正文、日志或构建产物。
2. 按 [development](development.md) 选择验证层；纯文档检查不冒充代码全集回归。失败和跳过项保留，既有历史证据带原日期和版本引用。
3. 最终提交后 `make app`，核对包内 GitCommit 等于 `git rev-parse HEAD`、WorktreeDirty=false、嵌入 JSON 与包内元数据相等，再严格验证签名。产品功能/构建改动按范围额外 `make -B app`。
4. 用交付消息记录最终提交及产物身份；仓内验收固定它所测的既有对象，避免为了写入自己的最终 SHA 反复产生 dirty 提交。用户已授权本地分包提交，推送仍需明确范围。

现有 bundle ID、designated requirement、数据路径及服务 label 保留。签名为固定 identifier 的 ad-hoc，不能声称完成公证、开发者分发或跨机器权限迁移。

## 更新与回退副本准备（不安装）

`Tools/Release/prepare_update.py` 只读取指定的新旧包，在仓库 `.build/update-preparations/<name>/` 写独立副本；没有安装、停止、启动、回滚到安装目录的子命令。先查询身份，明确候选完整提交和当前安装可执行文件 SHA256，再执行：

```sh
python3 Tools/Release/prepare_update.py prepare \
  --candidate build/CodexPromptAssistantPOC.app \
  --installed "$HOME/Applications/CodexPromptAssistantPOC.app" \
  --expected-commit <候选包完整GitCommit> \
  --expected-installed-sha256 <已核对的安装可执行文件SHA256> \
  --name <本次唯一名称>
python3 Tools/Release/prepare_update.py verify .build/update-preparations/<本次唯一名称>
```

尖括号参数须替换为真实值。构建、准备与安装不得并发；准备工具不执行任何被检查的可执行文件，包括 `--build-info`。

- 新旧包都必须为当前 bundle ID、clean 的可追踪构建，并通过严格 codesign 验证及 identifier requirement 检查；旧包缺元数据、dirty、符号链接/特殊文件暂不支持，须单独迁移，不能绕过校验。
- 复制后核对新旧包的元数据、可执行文件 SHA256、整包相对路径/类型/权限/内容摘要，再重新检查源包。回退副本固定为 `rollback.app`，不会由当前工作树重建。
- 全部成功后才写 `manifest.json`；状态仅为 `prepared-artifacts-only`。已有同名目录一律拒绝覆盖，复制/校验/中断失败保留不完整目录，供检查；没有清单的目录不可作为成功准备使用。后续应重新选名执行，不合并残留目录。
- 使用副本前必须再次 `verify`。清单是本机一致性记录，不是签名发布凭证；ad-hoc 签名不证明外部来源可信。摘要不单独覆盖全部扩展属性，真实签名校验仍必需。
- 准备副本只在构建目录中保存，`make clean` 会删除；尚不适合作为长期或正在执行部署的唯一备份。断电持久性、恶意并发替换、manifest 写完后的源包变化，以及真实服务停止/启动/回滚均不在准备工具的保证范围内。正式更新前仍须重新核对安装身份与运行条件。

离线故障用例与真实包复制证据见 [B-01 准备验收](validation/2026-09-08-update-preparation.md)。这一步没有替代下面的部署命令，也没有放行这些命令。

## 现有部署目标的实际副作用

### 当前运行身份与参数的只读检查（2026-09-17）

`Tools/Release/helper_runtime.py` 可读取当前助手的实际运行身份，不要求先制作 clean 更新候选：

```sh
python3 Tools/Release/helper_runtime.py \
  --installed "$HOME/Applications/CodexPromptAssistantPOC.app" \
  --expected-sha256 <已核对的安装可执行文件SHA256> \
  --codex-pid <已确认的CodexPID> \
  --model-pid <已确认的模型PID>
```

替换尖括号参数为现场已核对值。此工具针对当前 GUI 用户的固定助手和模型 label；只支持约定安装位置、直接启动助手并带模型保护参数的配置。它核对已加载 program/arguments、对应磁盘配置、实际助手命令行、进程启动身份、安装包签名/摘要及进程映射的路径/设备/inode，并比较前后快照。未知布局、shell 包装、自定义附加配置、缺失参数或状态变化时退出 1，不推断停止或健康。

退出 0 仅表示运行身份和模型保护检查完成：`runtimeIdentityVerified=true`、`modelProtectionVerified=true`。`healthVerified=false` 和 `automaticUpdateReady=false` 始终保留；存在 PID、匹配包、旧日志中的启动/监听成功，都不证明此刻输入监听或主线程响应。无服务修改、应用执行、模型请求、日志读取、偏好或权限修改。dirty 安装可被只读核对，但仍不是 clean 发布候选。

实际当前包检查通过，见 [运行检查验收](validation/2026-09-17-runtime-inspection.md)。现已由 `helper_launchd_services.py` 复用并连接事务接口；模拟事务、本机只读检查及同版本真实更新/注入验收拒绝后回退均已通过；跨版本与真实应用故障仍待验收，见 [迁移与回退记录](validation/2026-09-17-clean-migration.md)。

### 按需实时健康与停止确认（2026-09-17）

`Tools/Release/helper_health.py` 在运行身份核对后向同一助手发送一次带随机 nonce 的本机探测，等待有界响应。回执只包含协议版本、PID/UID、构建摘要、实例 ID 和四个布尔状态：主线程响应、事件监听启用、辅助功能已授权、模型保护开启。回执不读取或返回输入、草稿、候选、日志或凭据；健康通过也不代表模型生成或宿主插入通过。

停止确认函数只接受两项同时成立：固定助手 label 明确返回 launchd 不存在，且旧 PID 的 signal 0 返回 ESRCH。权限错误、命令失败、仍有进程或任何未知输出均为 unknown；不会发送终止信号，也不会将未知状态当作停止完成。这两个检查已接入服务适配器；实际执行仍须符合下文的 clean 包与真实回退门槛。

当时安装包的实际探测通过：主线程响应、event tap、辅助功能权限、模型保护均为 true，回执耗时 23ms；更新资格仍为 false，因为 dirty 包、真实回退尚未闭合。安装时另有明确停止确认：旧助手 43524 的服务已卸载且 PID 已退出，新助手 75626 启动。Codex1809、模型819和偏好保持。详见 [实时健康验收](validation/2026-09-17-live-health.md)。

新版支持 `--preserve-resident-model`（Info.plist `CPAUpdateLifecycleVersion=1`），只查询/连接现有模型，不 bootstrap/bootout；普通启动维持原行为。旧包没有该标记时不能假定追加参数有效。详见 [启动保护验收](validation/2026-09-08-update-model-preservation.md)。

只读预检可执行 `python3 Tools/Release/preflight_update.py --candidate <新包路径> --installed <安装路径> --codex-pid <已确认CodexPID> --model-pid <已确认模型PID>`。前后检查进程身份和包签名，报告新旧包保护能力；退出码 2 是存在阻断项，1 是失败/未知。此工具仍保留固定的适配器验收阻断字段；本轮同版本实机子项通过尚未开放通用放行，不得拿此工具作为更新放行器。

有限事务核心 `Tools/Release/update_transaction.py` 已提供同卷暂存、原包保留、逐步日志和最多一次恢复，见 [事务核心验收](validation/2026-09-08-update-transaction.md)。它要求注入能核实运行身份和停止/启动结果的服务适配器；已新增真实 launchd 适配器 `Tools/Release/helper_launchd_services.py`，尚无部署 CLI；下面的旧目标仍未替换，不可据离线测试放行。

2026-09-17 已将模型保护检查补到事务执行入口：候选和回退包都必须明确声明整数 `CPAUpdateLifecycleVersion=1`，并重新绑定到已验证包摘要；服务适配器还必须实现 `preserves_resident_model()`，核实当前助手（存在时）及后续新包/回退包启动所用配置均携带保护参数。包支持参数不代表运行时已使用参数。缺失方法、false 或未知值均在停止前拒绝；每次受保护进程检查同时复核该条件，中途失效后不继续替换、启动或自动回退。见 [执行入口保护验收](validation/2026-09-17-update-preservation-gate.md)。这新增了服务适配器契约，旧适配器须补齐真实检查；不能用常量 true 替代运行和配置证据。

2026-09-17 适配器已完成 44 项事务测试（23 项使用真实适配器和模拟系统边界）、59 项发布准备回归及本机只读核查，见 [适配器验收](validation/2026-09-17-launchd-adapter.md)。构造时绑定原助手/包、受保护进程、已加载配置路径和字节摘要；停止和启动前重新核对，包暂时缺位时仍检查配置。启动身份明确但健康失败可回退一次；启动身份未知，即使随后服务不存在，也保留现场。操作方法要求 clean、验签通过且生命周期/健康协议均为整数 1 的包。该轮仅只读核对dirty包；后续已安装clean基线并完成同版本真实更新/注入验收拒绝回退。跨版本与真实应用故障仍未通过，预检固定阻断项仍保留。默认最多 20 次观察，每条系统命令另有超时，无自动恢复入口。

| 入口 | 实际动作 | 当前结论 |
| --- | --- | --- |
| `prompt-assistant-service-install` | 依赖 app 构建；覆盖安装助手并写 LaunchAgent，验签和 plist | 不只是复制文件；仍不证明运行的就是新包 |
| `prompt-assistant-service-start` | 先 app，再尝试 bootout 助手（错误被忽略），调用 install，最后 bootstrap | 中途失败可能已停助手；程序退出/启动还可能连带操作模型，不能当安全隔离步骤 |
| 助手退出/启动回调 | 退出不再 stop；保护参数下只查询模型，普通启动仍可能 bootstrap | 2026-09-17 迁移与回退后 PID 88214 明确带保护参数；其他旧版本的退出/启动行为须单独核实 |
| 恢复旧包后调用上述 service-start | 再次把当前 build 安装过去 | **不能用作旧包回滚命令** |

2026-09-17 已取得首个包含当前全部功能的 clean 源码基线 `64d9475`，提交后重新构建验签与应用测试通过，详见 [clean 基线验收](validation/2026-09-17-clean-baseline.md)。源码 Git bundle 和应用包保存于 `outputs/release-baseline-20260917/`；现已完成首次迁移，并通过同版本真实更新和注入验收拒绝后的一次回退，当前运行clean基线可作为后续已知回退起点。实际独立备份及操作范围见 [迁移验收](validation/2026-09-17-clean-migration.md)；仍未验证跨版本与真实应用故障。

## 后续部署/回滚放行条件

先处理或证明所选退出/启动路径的 B-01 隔离，并建立可重复的失败/回退步骤。部署前备份可归属的已安装包及版本证据，记录助手/Codex/模型 PID 与启动时间；不能先停服务再发现没有可用备份。

合格流程应把停止助手、复制指定包、签名核验和 bootstrap 分成可判断成败的步骤，任一步失败即停止后续并记录现场；不能在失败后循环重启或用当前 build 覆盖本想恢复的旧包。回滚只处理助手包/其服务，不更改用户数据、配置、模型或权限身份。此前 `21733bb` 的旧包迁移先在同卷暂存并验签，再保留旧包、切换安装路径，仅 SIGKILL 精确旧助手 PID 以避开旧版模型 stop 回调，由已有 LaunchAgent 拉起新助手；未重写服务 plist。该历史过程的前后证据见原验收记录。此次 `49cff39` 更新则对已知支持保护参数的新旧包使用精确助手 label 的 bootout/bootstrap，没有使用 SIGKILL，也没有停止模型；两次路径均未做失败注入或实际回滚，不提供通用“安全回滚”承诺。

此次 `49cff39` 限定更新已核对安装/映射/启动身份及三进程连续性。当前助手服务从 `~/Applications/.cpa-morning-qzte1kx9/guarded-helper.plist` 加载，目录保留 `5bcad94` 原包及独立回退副本，不能删除；`.cpa-morning-x_gabg8b` 和更早 `.cpa-limited-migration-ex6xnryo` 的旧包也保留；规范 LaunchAgent 文件保持原样，未来普通启动不自动继承本次参数。它不是通用自动部署入口。

B-02/B-04/C1 与本轮质量/菜单修复已安装，TextEdit 与 Chrome [固定无发送矩阵](validation/2026-09-08-morning-experience.md)已实测；Codex 专项门禁/跨任务、WPS 和真实失败回滚仍未完成，不以此次更新放行全部部署路径。
