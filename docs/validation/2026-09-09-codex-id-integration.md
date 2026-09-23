# 2026-09-09 Codex 自动任务 ID 接入

## 结果

源码接入完成；离线回归通过；实机自动链路尚未通过，未安装或重载助手。
用户选择自动获取，接受已说明的剪贴板非原子边界。本轮没有连接或启动 App Server：
来源读取沿用本地 SQLite/JSONL，但改为按已验证 ID 查询并核对 session_meta.id。

## 实现

- 新增 CodexThreadIDResolver：输入稳定至少 250 ms 后，调用默认 ⌘⌥L；同一输入签名只尝试一次，失败不回退标题匹配。
- 取 ID 前保存剪贴板类型和数据（上限 8 MiB，拒绝文件承诺）；复制后检查版本与严格链接格式，恢复后核对类型和字节。检测到额外写入时不覆盖新内容。
- 短事务期间拦截 Cmd+C/X/V 并取消 ID 发布，清理后仅在原焦点仍在时重放；其他按键、鼠标、滚动及焦点变化取消结果。助手忽略自身取 ID 的标记事件。
- 请求代次、策略、进程、输入副本及新 AX 签名共同校验异步结果；Tab 接受前重新取 ID，比对不一致或失败即拒绝插入。
- ContextProvider 按 ID 选源并核对日志首行；源首次缺失会在刷新中重试。同名任务不再决定来源。

## 验证及失败

- 新增合成 SQLite/JSONL、内存剪贴板事务和候选门禁回放：同名任务、切换后迟到结果、缺失恢复、错误日志头、竞争写入、取消、超时、输入变化和 Tab ID 变化。
- 首次新增测试 2 项失败，原因是测试委托缺少 suggestionCoordinator；补齐夹具，并保存异步请求输入副本后，candidate-lifecycle-test 为 0 failures。
- make test 第一轮通过；最后清除取消后的 ID 缓存后再次执行，最终退出 0，C1 replay failures: 0。
- 生产 resolver 实机探针：两次在复制前因非前台拒绝；将探针激活后的阻塞等待改为运行循环后，前台检查通过，但 825 ms 返回 copy_timeout。
- 对照原始探针也在 1208 ms 超时，clipboardChanged=0、sameFocusWindow=true。因此不能把问题认定为新争用保护导致，也不能宣称宿主快捷键当前稳定。
- CUA 首次按 bundle ID 选择有两个安装包歧义；改为运行包路径后，工具拒绝控制 com.openai.codex（safety reasons）。未绕过该拒绝继续 UI 操作。
- 没有输入、粘贴、发送或清理真实草稿，没有调用模型，没有更改补全设置。

## 剩余边界

macOS 剪贴板没有跨进程原子比较写入：检查和 clear/write 之间仍有很小的竞争窗口，
宿主超时后极迟返回的链接也无法保证清理。剪贴板管理器可能观察到临时链接。
焦点变化后不会把已拦截快捷键重放到新控件；这可能丢失该次用户快捷键。
自动事务的复制/粘贴重放目前只有离线证据，快速 A→B→A、浮窗和完整实机 Tab 未验收。
后续须先复现当前宿主快捷键不响应，再完成这些实机项；本构建不能标记为稳定版。

## 构建与运行身份

make -B app 退出 0，严格签名验证通过。构建 GitCommit 为
230411e3d7517150b5d5f6ed7a82eaae5c7dc232，WorktreeDirty=true；
可执行 SHA256 为 2a4f22e54b061eeb39094350fb63a6755e95b18c74732589bebd416c29ca11c3。
git diff --check 通过。未提交、安装、重载；保留工作区原有改动。

前后进程一致：助手 PID 95882（9/9 14:02:33），Codex PID 48607（9/7 16:56:15），
模型 PID 56047（8/27 20:08:55）。运行助手未包含本轮新增代码。
临时测试输出：/tmp/cpa-id-full-tests-final.log、/tmp/cpa-id-build.log；不作为持久依赖。

## 15:51 手动成功后的投递层检查

用户手动 ⌘⌥L 返回与当前任务一致的 codex://threads/ 链接，证明此普通项目任务支持该命令。
仍不能由此推断自动触发成功。

本机 macOS SDK 的 CGEvent.h（CGEventPostToPSN/CGEventPostToPid 相邻说明）指出，
直接向进程投递的事件进入该进程的事件监听层。原 resolver 仅注册 session 监听，
因而不能保证拦住自身 CGEventPostToPid 发送的已取消快捷键。
新增 CGEventTapCreateForPid，并保留 session 监听处理用户复制/粘贴；任一监听创建失败
均在发送前拒绝。两个监听随事务结束释放，快捷键仍仅发往原 PID。

超时诊断现分为 copy_dispatch_unobserved、copy_cancelled_before_dispatch、
copy_timeout_after_dispatch；最后一项只证明经过监听，不证明宿主执行了命令。
新增当前标记事件通过、已取消标记事件拦截和两类投递记录回放，candidate-lifecycle-test
退出 0、C1 failures=0；探针 --self-test 为 0 failures。

没有绕过 CUA 对 Codex 的控制拒绝执行自动 UI 复测。进程监听的真实投递及快速任务切换
仍未验收；该实现缺口不等于已证实为先前所有超时的原因。未安装、未重载。

## 16:19 用户启动诊断

结果文件 checkedAt=2026-09-09T08:19:12.335327+00:00，exitCode=2，
error=app_identity_or_ax_permission。此次在复制命令之前退出，没有自动取 ID 的成功证据。
随后只读核对当前 PID 48607 和安装包 bundle ID com.openai.codex 正确；
终端辅助功能权限是优先排查项，历史组合错误码不能单独证明具体失败分支。
探针现拆分 app_identity_mismatch / accessibility_permission_missing，自测和编译通过。
未代替用户更改系统隐私权限、未安装或重载助手。

## 16:22 自动取 ID 单次实机通过

用户从终端运行新版生产 resolver 探针，保存结果 checkedAt=2026-09-09T08:22:58.972242+00:00：
latencyMs=141、success=1、reason=ready、currentTaskMatches=true、
localSourceVerified=true、sourceReason=id_matches_header、exitCode=0。
已回读 .build/focused-id-diagnosis.json，和用户截图一致。

这证明此次自动快捷键、ID 解析、焦点校验、剪贴板恢复读回与按 ID 定位/日志头核对通过。
恢复成功的依据是生产事务只有 restore 成功且焦点/请求有效时才返回 ready。
该探针只核对日志首行，未实机验证聊天正文进入模型的端到端流程。

前一次运行停在身份/权限检查，本次通过；不能由此断言早先所有 copy_timeout
均为权限问题，也不能把一次 141 ms 成功当作稳定性统计。任务切换、浮窗、
实机复制/粘贴争用和 Tab 仍未验收；未安装或重载助手。

## 16:35 六次连续实机诊断

用户报告测试完成；回读 .build/focused-id-diagnoses 中新增六份记录（不计此前 16:22 的 legacy 样本）：

| 本地时间 | 延迟 ms | currentTaskMatches | 结果 |
| --- | --- | --- | --- |
| 16:34:58 | 123 | true | ready / 日志头匹配 |
| 16:35:08 | 95 | true | ready / 日志头匹配 |
| 16:35:21 | 65 | true | ready / 日志头匹配 |
| 16:35:31 | 74 | false | ready / 日志头匹配 |
| 16:35:38 | 72 | true | ready / 日志头匹配 |
| 16:35:47 | 65 | true | ready / 日志头匹配 |

六次 success=1、localSourceVerified=true、exitCode=0，范围 65–123 ms，中位数 73 ms。
true→false→true 证明取得的 ID 从原任务变为其他任务再回到原任务；因未记录第二任务的
预期 ID，不能独立证明 false 对应用户指定的哪一个任务。前三次重复获取一致。

ready 由生产解析器在剪贴板恢复读回、焦点和请求有效性校验后返回，六次均通过该程序校验。
用户粘贴合成文字的目视结果没有单独报告，不能代替其确认。
这些是用户逐次启动的单次诊断，尚非快速切换/同时复制粘贴/浮窗压力测试，
也未验证常驻助手向模型提供正确正文。未安装或重载助手。

## 16:58 ID 到正文的 A→B→A 实机验证

回读逐次诊断记录，以下三次均 success=1、contextReadReady=1、
localSourceVerified=true、contextProbeExitCode=0、exitCode=0：

| 本地时间 | 原任务 ID 匹配 | A 标记 | B 标记 | 上下文消息数 | ID 获取 ms |
| --- | --- | --- | --- | --- | --- |
| 16:52:03 | true | true | false | 8（6 用户 / 2 助手） | 170 |
| 16:56:40 | false | false | true | 5（3 用户 / 2 助手） | 255 |
| 16:58:08 | true | true | false | 8（6 用户 / 2 助手） | 136 |

实机链路为自动取 ID → 按 ID 定位日志并校验首行 → 调用生产
ConversationContextProvider 读取有界正文 → 仅对用户整条合成标记做匹配。
兼容标记下划线的 Markdown 转义；助手引用标记不计入命中。
以上耗时仅为 ID 阶段，不是全部正文读取耗时。记录不保存正文。

本轮证明这三个单次诊断分别读取了预期标记所在的任务正文。每次诊断新建读取器，
因此不等价于常驻读取器缓存切换、模型请求上下文、快速并发切换或实机 Tab 验收。
没有安装、重载、调用模型或由助手发送测试消息；合成标记由用户发送。

## 17:00 常驻调用结构到模型请求体的离线验证

新增 FocusedIDModelRequestReplays：复用同一个生产 ConversationContextProvider 和
同一个测试助手委托，以合成 SQLite/JSONL 执行 A→B→A→ID 获取失败。
ID 解析返回和 AX 使用替身，读取器、ID 绑定门、本地/远程请求发起方法使用生产实现；
模型客户端为记录参数的替身，委托的调度器为手动驱动，未联网或操作实机。

检查通过：
- ID 完成前没有模型请求；新 ID 绑定后，两路请求参数只含当前任务正文。
- 将两路捕获参数交给生产 RemoteCompletionProtocol，分别检查本地前缀与远程格式
  的最终 JSON 请求体：包含当前正文、不包含另一任务正文。
- ID 获取失败时上下文为空，请求体不带旧的 conversation_context 段。
- 在新请求已发起后回放旧任务的迟到回调，浮层不显示旧结果。

make candidate-lifecycle-test 两轮退出 0，加入序列化断言后最终 C1 replay failures=0；
git diff --check 通过。此轮只增加测试和记录，不改生产实现，不需要重装或重新打包。

这些证据证明当前源码的受测调用链和序列化，而非已安装助手的运行状态，
也没有覆盖真实 HTTP 发送、模型理解或实机 Tab。常驻安装版的 ID 获取仍待更新后验收。

## 17:11 用户授权安装上下文候选

用户明确同意更新常驻助手。为遵守先推进上下文、暂缓续写过滤的要求，
从当前工作区创建独立候选快照：/var/folders/mm/v1q1xw4s3gz7h4hq2ntn6t340000gn/T/cpa-id-release-uiub66xv/source。
候选恢复原有 2026-09-09.2 质量契约及对应测试，协议源 SHA256 与已安装包
完全一致（ebca3e707d0e39cb93c0f69c30ac1f01ce57d43d313518fae18099e9305aef48）；
主工作区的 2026-09-09.3 改动保留，未被覆盖。候选加入 model_context 的来源、
消息数量、修订和 ID 绑定布尔日志，不记录正文、草稿或实际 ID。

候选 make test 退出 0；make -B app 和严格签名验证通过。未提交或推送。
构建仍为 230411e dirty；可执行 SHA256：c7d63934a4ac2e1da59bcdb1a1ba8f263b9e25fd2aecd9aaa9d40b50ba2a6622。

原包已复制并验签备份，随后仅 bootout 助手，确认旧 PID 退出后交换安装包，
通过原有带 --preserve-resident-model 参数的 plist 启动。
助手 95882 → 10060，新启动时间 17:11:46。lsof 核对安装路径映射；
17:11:47 启动日志确认 2026-09-09.2 及上述协议哈希，event_tap start=true。

前后完整设置比较一致、服务 plist 哈希一致；模型 PID 2353（15:23:05）与
Codex PID 48607（9/7 16:56:15）的 PID/启动时间保持。
原包和证据保留：/Users/hcm-b0263/Applications/.cpa-id-update-lkoej6xc，包含 backup.app、previous.app、evidence.json。
主仓 build 可能仍为另一个候选，不可用其直接覆盖本安装。

已完成安装和运行身份验收；尚未从真实输入触发后确认 codex_id ready 和
model_context count/绑定状态，也未验收实机 Tab。新源码进程不能替代这部分实机证据。

## 17:12 常驻助手实际输入触发通过

用户按要求输入合成草稿停留后报告已测试。读取运行日志的结构化字段确认：
- 17:12:49：codex_id resolved=true、reason=ready。
- 同时 model_context source=local、count=8、codexIDBound=true。
- 17:12:52：本地结果 HTTP 200、phase=completion，3214 ms，inputLength=17、outputLength=21。
- 17:12:53：local_model_show，mode=input_bar，证明执行了显示调用；未读取浮层正文或取得用户视觉确认。
- 后续输入变化有一次 cancelled 后重新 ready；17:13:04 远程请求边界同样 count=8、codexIDBound=true。
  远程此次尚无终态证据，不将请求发起写成远程成功返回。

结合此前独立 A→B→A 正文验证和合成请求体回归，第一步的基本读取与请求传递闭环
已有证据。此轮常驻日志只证明 ID 绑定及消息数量，不能独立证明每条正文语义正确。
快速切换/剪贴板竞争压力、浮窗、实机 Tab 均未因此获得验收。
