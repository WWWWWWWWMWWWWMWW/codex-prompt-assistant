# WorkBuddy 当前会话上下文接入

## 14:04：联网已触发，短候选过滤与非空会话上下文失败

用户再次提供 5.5.3 有历史的聊天截图并报告无提示。现场设置维持授权结果；日志 13:59:16 / 14:00:02 远程 HTTP 200、phase=no_suggestion_too_short，说明已经发出请求，结果停在长度门。对应 WorkBuddy 输入可读、focusMatched=true，但 contextCount=0 / contextStage=root_missing。此时截图有历史，不能再用“新建任务没有历史”解释，有限上下文实现尚未通过真实 AX 验证。

固定合成原文通过已有远程评测工具调用已配置模型，共 3 次：一个可显示；“请先检查输入框的”得到“内容是否完整”，因不足 10 字被拒绝；另一个输入得到无依据“安排尚未确认”，同样被拒绝。没有记录或回放用户真实草稿。不得只降低所有短句门槛来掩盖语义问题，本轮没有改变长度或质量规则。合成结果位于临时目录 xuyan-wb-remote-synthetic-bfwzh1lc。

为区分祖先层数上限、AX 类属性缺失及应用/网页根结构差异，新增只含计数的祖先诊断；不输出真实 DOM 属性值或正文，不放宽读取范围。构建/签名与 diff 检查通过；该诊断增量未重跑全套测试。仅更新助手 94980 → 95882，SHA256 `60ab59880fac3b2b75435d4365c47758aa8a251b05a8d5ef060ac0dadc22f5aa`，旧包 `.cpa-wb-diagnostic-sk1vhumo/previous.app`，设置及 Codex/模型进程身份保持。

CUA 按绝对应用路径仍解析为旧 bundle 并报未运行，无法代为置前或操作新版界面。已请求用户保持 WorkBuddy 当前输入框焦点，等待新的祖先计数日志；未覆盖或发送草稿。浮窗/Tab 和非空上下文仍未修复验收，不能宣称本轮已解决。


## 13:53：用户授权联网，新版应用标识适配已安装

用户明确回复“授权联网”。现场重新核对已安装 WorkBuddy 为 5.5.3，bundle ID 为 `com.tencent.workbuddy.mac`，旧版本为 `com.workbuddy.workbuddy`。助手本地补全关闭、远程全局开启、表达库关闭；旧应用规则没有远程授权，新标识亦无应用规则。先对旧标识授权，随后发现升级并对当前标识设置普通输入启用和 `remoteAuthorized=true`，搜索例外保持关闭。逐次 defaults 全量内存比较确认除对应应用规则外没有其他配置改变，没有保存或输出全量设置。

补齐新标识的输入分类、Electron AX 启用、有限会话读取、上下文身份与新鲜性检查；旧标识继续兼容。不更改提示词、模型、上下文预算或正文选择逻辑。5.5.3 应用包仍有对应结构类名，但这不证明实际 AX 能读到历史。

- `make test`、`make app`、严格签名、`git diff --check` 通过；C1 replay failures: 0。增加新版默认不自动联网、明确授权后允许远程、编辑器识别和敏感字段保护回归；生命周期回放使用新版标识。
- 限定更新助手 94078 → 94980，GitCommit `230411e3d7517150b5d5f6ed7a82eaae5c7dc232` / dirty=true，SHA256 `15854097ee4184586ebcb9a258b8a3066a03c3228995b1035c9454ee374690b8`。
- 原包保留 `/Users/hcm-b0263/Applications/.cpa-wb-diagnostic-795bdr66/previous.app`，同目录 evidence.json 核对安装前后设置与启动 plist 散列不变，Codex 48607 / 模型 56047 的 PID 和启动时间不变。
- 最终配置回读：新版 WorkBuddy mode=1 / remoteAuthorized=true / searchException=false；local-completion.paused=true、remote-completion.paused=false、expression-library.paused=true。
- CUA 应用清单能列出新标识，但 getApp 新标识返回 Invalid app，按名称解析仍指向旧标识并报未运行。未绕过界面工具进行实机输入，未覆盖或发送用户草稿。浮窗/Tab 和非空上下文仍未实机验收，本轮不能宣称整体已修好。


## 13:34 后：合成测试无候选原因已确认

用户再次反馈没有浮层。对应日志确认 WorkBuddy 88062 的 AXTextArea 可写、bodyRead=true、focusMatched=true；本地请求 HTTP 200 / phase=no_suggestion，远程没有调度（推荐应用规则未授权远程）。CUA 现场是新建任务页，因此该页 contextCount=0 正常，不是非空会话上下文失败证据。

对固定合成原文作独立本地复测：“请把正文翻译成英文，只输出”、带“续言合成测试”前缀、以及用户在测试句末加逗号的版本，原始模型文本均为空（model_abstention），并非本次测试被浮层隐藏。“请先检查输入框的”得到可显示候选，已将独立测试草稿改为该句并把光标置末；没有发送。另一个无依据“三个”用例生成了 A/B/C，不能称本地语义质量已解决。合成结果保存于系统临时目录 xuyan-wb-synthetic-th6hr1yv；未使用真实聊天进行模型评测。

进一步诊断增加 contextStage / 节点数等无正文信息；`make app` 和签名通过。最新助手 PID 91310，SHA256 `e930ddf9a17b43adbdeed6100d8d747a1d801b07742a9f52610b326e47eb93e0`，前包 `.cpa-wb-diagnostic-m7fzdi0q/previous.app`；更新脚本核对 Codex/模型进程与 defaults 不变。只增加诊断，没有更改模型、提示词或联网授权。替换后的合成句尚未取得 WorkBuddy 实机浮层/Tab 证据，非空会话的上下文验收仍未完成。

## 12:01 无候选问题：诊断进行中

用户截图为 WorkBuddy 5.3.14，并报告没有续写浮层。只读核对确认助手运行、本地/远程补全双开、WorkBuddy 为推荐规则。5.3.14 的已安装渲染源码仍包含读取器使用的 cbChat / userMessageText / chatMessageContainer / assistantTextContent 类前缀，不能仅凭升级断言结构失效。旧日志出现 generic_metadata_unavailable，但未带应用标识，不能归因为 WorkBuddy。

本轮补充通用读取诊断：bundle、目标 PID、系统/应用 AX 错误码、焦点归属 PID、上下文条数，均不含输入/聊天正文。`make app`、严格签名和 `git diff --check` 通过；只添加诊断，未修复未定位的行为问题。诊断候选已限定安装，PID 89369，SHA256 `8586f3c4b72b12a15d6db7cd03b182f3bcc7f670807d3ad16cd1e53caadd1cb5`；前包保留 `/Users/hcm-b0263/Applications/.cpa-wb-diagnostic-8pce150r/previous.app`，同目录 evidence.json 核对 Codex 48607、模型 56047 启动时间与 defaults 散列不变。

在 WorkBuddy 新建任务页设置独立合成草稿，未发送；原聊天草稿未覆盖。CUA 的 Raise/点击未使助手观察到 WorkBuddy 成为前台，Dock 访问超时（-10005）；已请用户手动置前停留后反馈。新诊断期间前台日志仍为 Codex，因此尚未取得 WorkBuddy 实际输入读取/上下文/Tab 证据，也未确认根因。不得将诊断安装称为修复完成。

## 11:47 用户授权后安装

用户明确要求“直接安装”。候选已安装并启动，助手从 PID 85217 切换为 87492（启动 11:47:56）；启动日志确认 `230411e` dirty / PromptVersion 2026-09-09.2，lsof 确认映射为当前安装可执行文件。安装 SHA256 与下述已测候选一致。Codex 48607、模型 56047 的 PID 和启动时间保持；助手 defaults 导出散列和既有保护启动 plist 散列保持。旧包保留 `/Users/hcm-b0263/Applications/.cpa-workbuddy-f2gb8sce/previous.app`，同目录 `evidence.json` 记录前后身份与散列。未执行实机输入、发送或语义质量测试。以下“未安装”描述是安装前的开发验收状态，本节更新安装结论。

## 安装前开发记录

日期：2026-09-09。开始时工作树存在菜单、图标、远程过滤和评测等未提交修改，全部保留。本轮未提交、安装或重载，也未写入应用开关或调用真实模型。

## 已确认

- WorkBuddy 当前界面版本 5.2.5。只读检查已安装 `app.asar` 的 `src-CMgU1OQk.js` / `connector-CvFT3fv6.js`，确认 `cbChat`、消息容器、用户 request ID、用户正文和助手正文类，以及虚拟列表只挂载部分消息的实现。没有读取其本地历史数据库。
- 独立 `WorkBuddyContextReader` 读取已授权输入所属的最近 `cb-chat` 根；要求唯一消息容器和用户 request ID，限定正文区域，禁止回退到整窗文本或 Codex 历史。
- 预算为最近最多 6 条用户正文、2 段助手正文、总计 3000 个 UTF-16 单元；只保留完整选中正文块。超过遍历节点/500ms 检查预算、未知结构、焦点或规则变化、原消息节点脱离时不提供上下文。单次 AX 调用仍可能超时，500ms 不是硬实时保证。
- 5.2.5 流式助手行引用未导出的 CSS 属性，渲染为 `undefined` 类；该类及 `_streamingMessage_` 都保守排除。后续版本结构变化需要复验。
- 两路补全复用同一不可变上下文；WorkBuddy 默认仍只允许本地，远程需原有应用授权。插入 HMAC 包含完整材料，JSON 键排序保证同材料签名稳定。

## 验证结果

- `git diff --check`：通过。
- `make test`：最终通过，包含新增树夹具和生产候选生命周期替身回放，`C1 replay failures: 0`。
- 新增用例覆盖角色和顺序、只读已识别正文、拒绝时零正文读取、未知结构、历史消息编辑区、同文异 request ID、两类流式标志、超预算完整块舍弃、读取期间节点脱离、本地/远程材料一致、迟到旧结果拒绝、Tab 在下一次轮询前发现上下文变更并拒绝。
- 首次测试在夹具编译阶段触发 `-Warc-retain-cycles`，已将回调改为弱引用；后续完整 `make test` 通过。未删除或跳过失败用例。
- `make -B app` 及严格签名：通过。`make build-info` 回读 GitCommit=`230411e3d7517150b5d5f6ed7a82eaae5c7dc232`、WorktreeDirty=true；可执行文件 SHA256=`e7de33e0eb972b86d4716363a187d25819cb35df83be49dfe6794f0c9902bc32`。共享工作树期间有其他任务的文档提交推进 HEAD；本轮没有执行 Git 提交，产物仍包含开始时已有的未提交功能修改。

## 未验证与交付边界

- 尚未安装到常驻助手；当前运行版本不会因本轮源码修改获得此功能。
- 已安装 WorkBuddy 的 DOM 源码结构不证明实际 AX 会暴露全部属性；非空会话的 AX 读取、真实切换、中文输入法和 Tab 实机闭环未完成，不标为已实测支持。
- 不保证完整历史；虚拟列表未挂载、折叠消息、超长正文或新界面结构可能降级为仅当前草稿。没有做新模型语义质量评测。
- AX 多次读取与宿主更新不是原子操作；身份/焦点复核和 Tab 新读取缩小竞态窗口，不声明彻底消除所有窗口级竞态。

下一步是在明确更新助手的范围内安装候选，用可识别的合成会话完成实机读取、切换和无发送 Tab 验收。
