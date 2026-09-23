# 0.3.11：接受后的聊天续写阶段

2026-09-22。用户反馈0.3.10仍没有连续续写后，重新按本次运行日志排查；保留既有UI和所有未提交改动。本轮没有提交或推送。

## 现场证据与问题边界

安装运行的是0.3.10/PID8388。当地时间11:24:58，首次请求42字输入得到29字候选；11:25:00收到实体接受事件，插入后71字回读完全匹配。下一轮记录`mode=verified baseDebounceMs=120`，请求观察总时间3016ms、请求本身2735ms，差281ms，证明上轮调度缩短已经生效。11:25:03服务返回HTTP200、`finishReason=stop`、`rawOutputLength=0`、`noSuggestionReason=empty_content`。

因此本次无后续候选的直接原因已确认是服务返回空内容，并非未发请求、超时或本地把非空内容过滤掉。首次和接受后的生成契约此前完全相同，模型没有接受阶段信息；“停笔判断是否过早”是本轮验证的可干预因素，不能把实验推断写成已知模型内部推理。

[现场元数据](../evaluation/results/accepted-continuation-2026-09-22/runtime-empty-result.log)仅含耗时、长度、固定状态和请求ID。旧日志已轮转，从当前log及轮转文件按时间窗口提取；未保存真实草稿、历史正文或凭据。

## 实现范围

- 聊天末尾的插入回读匹配后，绑定完整输入、候选签名（含任务/控件/光标信息）和上下文修订；下一轮请求明确携带“刚接受上一条建议，继续推进当前主题”的系统指令。连续多次接受会重新建立当前阶段。
- 手动编辑、任务边界、清空和Esc忽略清除阶段；发送前再比对签名、输入、上下文。客户端在入口同步采样，阶段加入缓存和在途请求身份，不能复用首次补全的候选或在途请求。
- 继续沿用120ms基础防抖、160ms远程调度和自适应防抖；保留最终输出过滤、焦点/身份校验、不自动发送。空结果不会无限重试，也不会用固定句子填充。
- 初始输入的生成契约保持。PromptVersion升级`2026-09-22.20`，应用0.3.11/build14。
- **仅聊天末尾接入新阶段指令。**文档、中间插入和小型本地模型路径不应用它；不是全部宿主/场景的连续续写已验收。

设计取舍见[阶段设计](../plans/2026-09-22-accepted-continuation-design.md)。

## 提示词实验与否决项

先做7组同输入旧/新配对，共14次实际联网，读取已有配置，只有合成文本：

| 组别 | 普通请求 | 加接受阶段指令 | 判断 |
| --- | --- | --- | --- |
| 完整字段核对请求 | 空 | 30字同主题续句 | 此例改善 |
| 完整续写时延排查请求 | 空 | 24字同主题续句 | 此例改善 |
| 完整UI调整请求 | 32字 | 32字 | 两者都有续句，存在近义重复风险 |
| 只列名称 | 空 | 空 | 封闭范围保持 |
| 只输出译文 | 空 | 空 | 封闭范围保持 |
| 文档奖励数值待确认 | 空 | 新增发放方式/条件待确认 | 超出原文明确对象，未采用 |
| 文档仅补发未领奖励 | 18字近义重复 | 新增失效/删除等奖励排除规则 | 新规则无依据，拒绝接入文档 |

由此采用聊天阶段，并在协议与客户端双重限制文档/中间插入；没有通过增加输出率宣称语义全面改善。实验不是随机大样本评测，且模型输出有波动。

[实验元数据及合成输出](../evaluation/results/accepted-continuation-2026-09-22/probe.jsonl) · [实验源码](../evaluation/results/accepted-continuation-2026-09-22/probe.m) · [受测阶段指令](../evaluation/results/accepted-continuation-2026-09-22/prompt.txt)。这里保存的输出仅来自固定公开合成草稿，未读取真实用户正文。

## 最终生产代码验证

1. 新生命周期断言在实现前失败：已匹配接受未作为“下一段续写”传入客户端。实现后完整`make test`退出0、30个PASS标记，0个FAIL；覆盖首次、两次接受→第二/第三轮、手动编辑、任务边界，以及空结果不循环请求。
2. `make remote-completion-test`退出0、5个PASS标记，0个FAIL。覆盖真实HTTP负载的阶段指令、在途属性变化后的快照、首次/连续缓存隔离、阶段在途合并隔离，以及文档/中间/本地模式不带新指令。
3. 最终生产客户端做三轮连续联网（上一轮合成候选在内存拼入下一轮输入，后续启用接受阶段），两组均三轮成功：字段组37→30→28字，等待环节组35→20→17字；续句继续提出同主题核对/比较要求，未变成助手回答。两组已完整的封闭范围，即使显式启用阶段仍返回空。
4. 最终8次请求耗时2036–3725ms、HTTP200；未改变等待预算，不宣称生成速度提升。探针不执行宿主插入，不能替代真实Tab验收。
5. `make app`、严格签名、designated requirement与安装前后身份核对通过。

[修改前失败](../evaluation/results/accepted-continuation-2026-09-22/before-tests.log) · [应用测试](../evaluation/results/accepted-continuation-2026-09-22/app-tests.log) · [远程测试](../evaluation/results/accepted-continuation-2026-09-22/remote-tests.log) · [三轮生产探针](../evaluation/results/accepted-continuation-2026-09-22/production-probe.jsonl) · [探针源码](../evaluation/results/accepted-continuation-2026-09-22/production-probe.m) · [增量补丁](../evaluation/results/accepted-continuation-2026-09-22/changes.patch)。

## 已安装与未验证

- 助手8388已正常退出，新助手10498于2026-09-22 11:34:55启动；当前0.3.11/build14、提示词`.20`。
- 二进制SHA256 `03b26c91ca8073859496a02454118695c0d643ec9e60f50aa1f10c9d72100c99`；PromptSourceSHA256 `838f1768009d486fd28c5d347cb0fd0bee7a366119bbe9cefb249b1e78d1a4bf`。
- GitCommit `8f54aa72f03cbd553b6b970126c2d092384425c2`，WorktreeDirty=true；源码指纹与本轮增量补丁单独保存，不是clean发行包。
- 同卷备份`/Users/hcm-b0263/Applications/.cpa-accepted-continuation-20260922-w2l0jco4`，原包previous.app及独立backup.app均保留。运行映射inode/device与安装包匹配，健康四项（主线程、event tap、辅助功能、模型保护）均true。
- 12项偏好整体散列、LaunchAgent文件、Codex36688及Ollama992/1012 PID和启动时间保持。没有重启Codex或模型。

[构建日志](../evaluation/results/accepted-continuation-2026-09-22/build.log) · [安装与健康记录](../evaluation/results/accepted-continuation-2026-09-22/install.json) · [源码指纹](../evaluation/results/accepted-continuation-2026-09-22/source-sha256.json)。

**未验证：**新版真实宿主实体Tab→阶段指令→新候选显示全过程；截至安装后检查没有新的接受样本。本会话此前CUA虽能编辑TextEdit测试窗口，却未建立系统前台，本轮没有再把后台窗口操作当作实机验证。文档语义、中文组合输入、多宿主和故障回退未新增验收；S1/S2原门槛保持。

下一步：优先核对真实使用中的`accept readback=matched`→`continuation_stage=after_acceptance`→`response_meta`→实际显示链路；若仍空则用对应场景的合成复现评估停笔边界，若已有内容却无显示则查身份/上下文拒绝。不要再把这一问题仅当作延迟调参。
