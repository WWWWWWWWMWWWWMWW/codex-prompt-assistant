# WorkBuddy 5.5.3 新会话结构适配

## 根因与边界

用户授权修复，并沿用关联测试、备份安装及实机验证约定。初始助手 PID72315 / 提示契约 2026-09-10.16；本地与远程均开启、Terra、表达库暂停。

已确认输入框可读、策略允许、远程可返回候选；现有对话持续 `contextStage=root_missing`。两个临时诊断构建仅输出来自安装资源的固定结构白名单，不输出运行时任意类名、DOM ID、标题、输入或正文。实机最终识别到 `conversation-input → conversation-shell__main → conversation-shell`。旧实现仅接受 `_cbChat_`，并继续走到网页/窗口，增加深度不能解决。

与当前安装的 `/Applications/WorkBuddy.app` 5.5.3 静态资源交叉核对：`ConversationShell` 将 `ConversationTimeline` 和 `ConversationInputArea` 放在同一个 shell；新时间线使用 TaskChatList 与 `cr-self-message / cr-user-content / cr-agent / cr-markdown`。旧 cbChat 组件仍存在于安装资源，但不能代表当前界面正在使用它。app.asar SHA256：`c3c8e497693b33753fdbc127219bbca4037589de4275f44a971498400b113111`。

## 修改

- 保留旧读取路径；增加仅限聚焦 `conversation-input` 所属 shell 的新版路径，不扫描整窗、不按标题查找。
- 正文读取前要求唯一时间线、唯一消息列表和可用用户正文节点；仅采集用户正文及已完成助手正文。排除工具、嵌套工具内助手、废弃/未发送消息、历史编辑输入和未知助手块。
- 新界面的消息 ID 位于 `data-*` 属性，不能把它们假定成可用的 AXDOMIdentifier。采用聚焦 shell、输入框及已确认消息/正文 AX 节点的内存身份，读取后重查结构与归属；节点更换即改变材料身份。只证明当前渲染内容的归属，不声称取得持久任务 ID 或全部历史。
- 保持最多 6 条用户/2 段助手、3000 UTF-16 单元、完整消息与 0.5 秒期限；新路径两次结构扫描各限 1800 节点、正文限 600 节点。未知/超时返回无上下文。
- 到 AXWebArea/AXWindow 停止查找根，避免把越界循环误报成应扩大搜索深度。
- 正式构建移除临时白名单诊断，不依赖 `.build` 生成源文件。未改提示契约、模型、过滤、开关或发送行为。

## 验证过程

- 新 shell 合成夹具在旧实现上明确失败：`5.5.3 shell reads user and finished assistant only`。修复后基础应用套件通过。
- 补充未知输入、双时间线、嵌套会话、流式/废弃/未发送、工具内嵌助手、超预算、同文节点替换、读取时消息/输入框脱离等回归。
- 自动 CUA 粘贴超时，Raise/typeText 没有建立系统前台；setValue 可回读独立合成草稿，但助手仍见 Codex，不能据此报显示通过。用户手动置前后取得真实运行样本。
- 诊断阶段新建页合成输入实机链路：远程两次候选耗时 1968 / 1870 ms；日志有浮层显示、接受投递及 AX 全文匹配，长度 48 / 68；接受后下一轮分别接收完整草稿。第二次含人工增加的一个字，不能写成全程无人操作。最终合成草稿已核对清空，原对话草稿保留，未发送消息。
- 临时诊断安装记录：`docs/evaluation/results/workbuddy-structure-diagnostic-2026-09-11/install.json` 与 `workbuddy-structure-diagnostic2-2026-09-11/install.json`。两次安装均保留所有偏好、Codex13565/模型2353 PID和启动时间；原包有独立备份。

## 实机发现的第二层差异

第一次兼容构建（PID36458）已识别唯一 shell/时间线/列表，但 392 节点中用户/正文计数仍为 0，不能计为上下文通过。追加两个临时诊断构建（PID37223、37987），白名单只含安装静态资源中的常量结构名；产品源码最终移除该诊断枚举。

实机 AX 投影为 `文本 → _editable_ → cr-frame__content → cr-frame--right → cr-document__virtual-item → cr-message-list`；网页源码中的 `cr-self-message/cr-user-content/cr-agent/cr-markdown` 多层 div 在 AX 中不存在。不能用完整 DOM 夹具替代真实 AX 夹具。

最终增加针对这份投影的用户正文路径：同一右侧 frame 必须恰有一个只读 `_editable_` 和一个 `AXToolbar`，工具栏必须存在“编辑 / Edit”按钮。源码 ToolbarRenderer 在废弃或编辑态直接返回 null，未发送态使用“重新编辑 / Edit again”；缺失或歧义全部跳过，读取后重查。工具栏按钮只读取标题/描述元数据，不读取历史正文作结构判断。实际 CUA 也确认到“编辑／复制”控件。新的 AX 投影用例先在原兼容实现上失败，再补修；中英文未发送、工具嵌套、多输入体、状态变化等均有拒绝用例。

**能力限制**：真实 AX 缺失助手完成状态与正文边界时，该投影只带入已确认的用户前文，不猜测助手正文。完整结构可见时仍保留原本的完成助手读取路径。未扩大 6/2/3000 的预算，不把只读可见用户片段说成完整历史。

## 最终安装与实机结果

- 最终完整 `make test` 通过；`make app` 与严格验签通过，产品源码没有临时枚举或 `.build` include。未改协议，因此未另跑远程核心套件或语义基准。未提交、推送。
- 2026-09-11 19:45:55 安装并运行 PID39405，契约仍 `2026-09-10.16`，Git `230411e3d7517150b5d5f6ed7a82eaae5c7dc232`、WorktreeDirty=true。二进制 SHA256 `a43dcbad125e6e2b540f6c09bc2956803a75d42637add882ab4180cad0b46eed`，安装包/运行映射/启动身份/事件监听已核对。
- 回退副本：`/Users/hcm-b0263/Applications/.cpa-workbuddy-flat-2026-09-11-rtx03456`。初始 .16 原包还保存在首次诊断备份中，未删除。全部偏好、Codex13565/模型2353、WorkBuddy93314 PID与启动时间保持，未更新或重启宿主。
- 已有对话真实 AX 返回 `contextStage=ready contextLayout=shell contextMessages=3`，一次读取 36 ms；观察窗口材料修订稳定。合成草稿全文 23 字、光标置末后，本地/远程客户端均记录 `count=3 revision=1`。本地按既有 .16 只做字面路径；Terra HTTP200，2654 ms（从观测输入到完成 3000 ms），输出 27 字并执行 `overlay remote_show`。
- **未通过/未验证**：应用截图未包含独立助手浮层，不能声称最终版截图验证浮层；自动 CUA Tab 将焦点移到“更多操作”，无 `shortcut action=accept` 或接受回读事件，自动接受未通过。诊断阶段用户真实按键的两次接受仍是先前证据，不替代最终兼容版 Tab 验收。真实快速 A→B→A、中文输入压力与大历史性能未跑；未知语言工具栏会保守返回无用户上下文。
- 最后一次实机输入前 CUA 显示空输入框，仅写入固定合成句；结束再次核对仍为该句后清空并回读为空。未按发送键。新建页早期合成草稿也已清空，未写入聊天记录。
- 结构与预算变化的独立记录即本文件；安装及仅元数据证据见 `docs/evaluation/results/workbuddy-flat-2026-09-11/{install,verification}.json`。中间 root-only 构建有历史仍为 0 的失败已保留，不能覆盖成通过。

## 下一步

优先验证最终版物理 Tab/Esc 和已有对话 A→B→A，确认接受时归属检查不影响正常输入。助手历史应在有可靠完成状态与正文边界后单独适配，禁止按左侧整块文本直接采集。
