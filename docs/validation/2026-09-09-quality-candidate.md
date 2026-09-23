# 2026-09-09 自动推进：质量候选与未通过路线

## 本轮结论

本轮新增 80 次合成尝试：完整语义审核 40 次、替代生成路径 16 次、Sol 新场景复核 24 次。
没有让用户逐轮确认，没有操作真实输入或发送任何消息。

- [语义审核 v3](../evaluation/results/semantic-audit-2026-09-09/README.md)：本地误放 5/10 个反例，远程误放 1/10，且正例各误拒 2/10。关键现象偏移仍漏放，否决接入。
- [替代模型首轮](../evaluation/results/alternative-generators-2026-09-09/README.md)：服务暴露的 qwen3.5-flash 在当前请求边界下 8/8 超时，不采用；不将 HTTP 200 当完成。
- [Sol 新场景复核](../evaluation/results/sol-validation-2026-09-09/README.md)：合并 32 次尝试，17 次严格原意保持、7 次有冗余或泛化、8 次正确停笔，其中 6 次由客户端门禁完成。无系统失败，未观察到这组样本中的关键事实改写。

Sol 只是受控试用候选，7 次残余质量问题必须保留，不能宣布第二步全部完成。
既有基线与替代模型不是同一时刻的独立盲评，服务模型名称不等于上游权重身份证明。

## 已准备的本地包

`.build/release-candidates/quality-v5-sol-20260909/` 保存 candidate.app、rollback.app 和 manifest.json。
候选为已实现的 .5 输入边界/缺少用户依据门禁，Git 230411e dirty。
与当前 .2 安装阶段源快照相比，生产源只差 CompletionIdentity.h、RemoteCompletionClient.m、RemoteCompletionProtocol.m。
未将任何失败的实验提示词、审核调用、格式改动或自动替换显示逻辑放入生产包。

`make app`、嵌入 build-info 与严格签名通过；候选和回退副本复制后均验签、可执行字节与来源一致。
候选可执行 SHA256：d1324f9ec100796d0317cca54667780d676641b1fc3032b14ebae9914dccfb13。
当前安装可执行 SHA256：c7d63934a4ac2e1da59bcdb1a1ba8f263b9e25fd2aecd9aaa9d40b50ba2a6622。
这是明确 dirty 的本地审阅副本，不是 clean-only prepare_update 工具的准备结果，不冒充正式分发包。

## 实际检查

- 本轮工具新增显式模型发现/临时模型覆盖；只对基准请求生效，未修改正式偏好。
- v3 请求金标隔离/封闭响应协议、焦点与指令单变量请求测试均通过 completion-quality-harness-test。
- 新测试首次因在序列化 JSON 中直接匹配未转义斜杠而失败；改为匹配不含转义歧义的契约内容后通过，未修改生产行为掩盖失败。
- 本任务前一轮 candidate-lifecycle-test 已确认先显示候选保持固定，C1 failures=0；.5 核心/应用回归证据沿用 objectless-question 验证记录，本轮未重复全量应用测试。
- git diff --check 通过。实机显示/Tab 未验证，本轮未安装或重载。
- 当前只读核对：助手 10060（17:11:46）、Codex 13565（17:43:10）、模型 2353（15:23:05）；旧 Codex PID 48607 已不存在，不能延续旧的进程连续性声明。本轮没有执行 Codex 或模型重启。

## 待明确启用的方案

安装 .5 候选，只将远程模型从 Terra 改为 Sol，并暂停本地自动补全，防止已知错误的本地候选先占住显示。
表达库继续暂停。仅暂停补全开关，不停止或重启本地模型服务；显示后的候选与 Tab 目标仍保持固定。
当前现场仍为本地/远程双开、Terra，未做上述切换。

项目 AGENTS.md 要求保留当前本地/远程开关，仅按最新明确要求切换。因此在用户明确选择启用方案之前，不执行这些偏好变更或安装。
获准后先重新核对安装包/三进程/服务保护参数，有限更新仅操作助手，回读模型及开关，使用合成草稿验证。CUA 如继续阻止 Codex 操作，不绕过该限制，也不把构建当实机验收。

## 19:13 用户授权试用后已安装

用户明确要求试用并保留回退。已使用冻结 candidate.app 更新，仅 bootout/bootstrap 提示助手。
助手 10060 → 19301（19:13:47）；Codex 13565 与模型 2353 的 PID/启动时间保持不变，服务 plist 散列不变。
安装可执行散列与候选一致；严格签名、lsof 映射及启动日志 prompt=.5、promptSHA256 匹配，event_tap start=true。
偏好回读：local-completion.paused=true，remote-completion.paused=false，preferred-model=gpt-5.6-sol，expression-library.paused=true；其他偏好值保持。
当前启动日志 model 字段是编译默认本地模型，不代表实际选中的远程模型；Sol 以偏好回读为据，本轮尚未验证实机生成结果。

旧包及原设置保留于 /Users/hcm-b0263/Applications/.cpa-sol-trial-gz67dmmp/，evidence.json 记录前后身份及原设置；backup.app / previous.app 均保留。
回退需仅恢复该旧助手包和 previousSettings（本地/远程双开、Terra、表达库暂停），只重载助手，不调用会重新安装当前构建的 service-start。
本轮没有操作用户草稿，未实测浮层生成或 Tab 插入，不将安装成功视为质量验收。

## 19:17 试用反馈后回退

用户反馈每次输入侧栏快捷键闪动且无提示。安装后日志有密集 codex_id ready/copy_timeout_after_dispatch，远程已发送上下文，有 HTTP200/no_suggestion，也有输入变化取消。不能把无提示都归为模型留空。
源码 ensureCodexIDForSnapshot 绑定输入 signature，cancelPendingSuggestion 会清空 ID；native sendCopy 通过 Cmd+Option+L 获取链接，所以输入变化会重复主动快捷键探测。此机制旧 .2 也有，不是 .5 新增。
按用户预先授权恢复原 .2 安装字节与原偏好，助手 PID19526（19:17:27），Codex13565/模型2353 PID与启动时间保持。
备份目录 evidence.json 的 userTrialRollback 保存回退记录，trial-returned.app 保留试用包。
闪动未修复，提示恢复未实机验证。不能用延长 ID 缓存寿命直接修复，因为同窗口任务切换时仍须有可靠身份失效依据；需替换主动快捷键读取路径或获得可验证的被动任务标识。
