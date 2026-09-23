# 0.3.16：空返回诊断分层

2026-09-23，用户授权补齐空返回原因诊断。只增加无正文元数据与请求关联日志；不修改提示词、候选放行、重试策略或用户开关。旧noSuggestionReason保留，避免用字段形态推断模型语义。

## 日志如何阅读

同一requestID关联以下记录：

- `finish`：HTTP状态、结果阶段、输入/输出长度、耗时、缓存来源。
- `response_meta`：原有解析正文长度、finishReason、过滤/截断/空内容原因。
- `response_shape`：响应格式、字节数、事件数、第一choice出现次数、字符串正文字段次数、finishObserved、doneSeen、拒绝/推理/工具调用/空值/不支持类型/异常事件标志或计数。
- 远程有效完成回调另有 `request_context`：绑定请求ID的触发类型（deletion/after_acceptance/edit_or_refresh）、文档模式、右侧正文长度、上下文条数/角色数/字符数/修订号、是否绑定Codex任务ID。均捕获于请求发起时；不输出任务ID、正文或哈希。

bodyState取固定枚举：text、whitespace_only、explicit_empty、missing_content、null_content、unsupported_content、refusal_without_text、reasoning_without_text、tool_calls_without_text。多个字段共存时独立标志仍保留。正文字符串计数描述响应中观察到的字段，与解析器最终选用的正文长度分开；可帮助识别响应形态不匹配。

finishObserved和doneSeen只证明观察到结束标记，不保证传输或服务语义完整。空字符串也不能证明模型按哪条规则停笔；没有正文字段也不等于网络异常。解析错误保留能取得的形态元数据，不将其转成正常候选。取消或已过期回调仍按原有身份规则丢弃，非完整请求审计。

## 验证

- 先加入JSON/SSE形态分类回归，旧代码在分类断言失败。
- `make remote-completion-test`通过；覆盖空串、缺字段、null、不支持类型、纯空白、仅推理/拒绝/工具调用、仅DONE、无choice、缺结束标记和坏事件；隐私断言确保合成正文不进入诊断字段，已有候选结果不变。
- 完整`make test`初次和复跑均在原有浮层屏幕断言失败。诊断实际screen={{-1470,124},{1470,956}}、panel={{512,386},{450,40}}：测试错误地用用户当前mainScreen验证另一屏幕的固定合成锚点。仅修正测试选择锚点所在屏幕及检查panel.screen，生产浮层未修改；完整套件随后通过，C1回放0失败。
- `make app`与严格验签通过，0.3.16/build19，GitCommit ae199633ee83ac352b77b642a7537036aa865ea5，WorktreeDirty=true。PromptVersion保持2026-09-22.24；Protocol文件含诊断代码，因此源码指纹变化但提示词文本未变。
- 两条合成生产客户端联网探针通过。开放请求HTTP200并返回22字；封闭要求HTTP200，stop和DONE均有，contentStringCount=0、bodyState=missing_content，无拒绝/推理/工具调用字段。该样本证明服务可能用省略正文表示无续写，不可仅因missing_content自动重试。结果见`docs/evaluation/results/empty-diagnostics-2026-09-23/synthetic-provider.jsonl`。

## 安装与边界

助手81804停止后安装，新助手85672于2026-09-23 17:06:10启动；主线程、事件监听、辅助功能、模型保护均为true。安装包哈希/构建身份与候选一致；偏好哈希、Codex60352和Ollama992/1012的PID与启动时间保持。只操作助手，复用已加载的guarded-helper配置。

旧包和机器核验记录保留于`/Users/hcm-b0263/Applications/.cpa-empty-diagnostics-20260923-wtxczmsc/`。保留既有工作区改动，未提交或推送。

安装后用户处于WPS窗口，未向真实文稿写入或强行切换前台。因此已验证客户端真实响应的新元数据和安装健康，尚未取得新版助手对用户真实空返回的response_shape/request_context日志；不宣称空返回语义问题已解决。下一步按新日志区分响应形态，再决定协议适配、异常恢复或提示词停笔条件，保持短候选门槛不变。
