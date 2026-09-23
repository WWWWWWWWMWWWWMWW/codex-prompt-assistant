# ADR-0007：M0 现行实现与证据边界

## 状态与范围

2026-09-08 圆桌评审确认的现行实现记录，代码核对基线 `d5c79dc`。本记录不变更行为；逐项更新旧 ADR 的适用范围，并保留未满足的产品契约。评审与裁决见 [圆桌记录](../validation/2026-09-08-m0-roundtable.md)。

后继说明：源码 `8d8c0e5` 已增加共同显示质量门，以下“尚无共同质量入口”保留为原基线记录；后续现状见 [architecture](../architecture.md)。新的语义与候选生命周期设计见 [0008](0008-grounded-continuation-contract.md)，尚未实施，不反写本记录的历史事实。

部分替代 [0002](0002-local-learning-and-remote-completion.md) 的生成职责、[0006](0006-local-master-key-file-for-background-scan.md) 的远程凭据位置；[0004](0004-local-message-encryption.md) 的主密钥保管此前已由 0006 替代。其余条款不因本记录自动失效。

## 当前事实

- 本地历史表达检索与本地模型是两个候选来源，可选远程仍保留。远程暂停是用户配置，当前值只由 [status](../status.md) 与带日期证据记录；不能把默认值说成仅本地。
- 支持的本地 Qwen 模型采用原文预填续写；普通模型/远程仍使用相应聊天协议。表达命中可先显示，模型结果经过最终校验，两者尚无共同质量入口。代码在 `main.m` 的装配/显示方法和 `RemoteCompletionProtocol.m`。
- Codex 实时上下文限定于明确归属的当前任务、有限预算；离线表达索引可以从活动/归档历史构建并跨任务匹配。ChatGPT 导出导入不是实时页面读取。
- `configureDataFoundation` 实际使用 `history-v3.sqlite3` 和 `master-key-v3.bin`，根目录为用户 Application Support 下的 CodexPromptAssistant。`RemoteCompletionSettings` 默认构造器使用 `RemoteAPIKeyFileStore`，旧注入构造器保留 Keychain 路径；不能再把远程凭据一概写为 Keychain。
- 当前包仍是原 bundle ID、固定 designated requirement 的 ad-hoc 签名；有 Git/提示词/模型构建身份不等于已具备正式分发或 Apple 开发者签名。

## 本次文档治理决策

采用局部校订和双向替代链接，保留原 ADR 与验收记录。产品契约写“要求”，架构写“实现与差距”，status 写“当前状态”，validation 写“带对象/日期的证据”。其余文档引用这些入口，不各自维护一份当前完成结论。

备选“直接改写旧 ADR”为现状会抹平演进证据；“完全不标注历史”会误导后续开发，因此不采用。代价是需要维护少量替代链接，避免用更多重复文档填补一致性问题。

## 已知后果与未闭环项

本地处理增加了驻留模型与历史库的维护职责；更多上下文可能增加首次生成等待，历史表达匹配并不保证任务相关。保留远程不代表可在未授权场景发送。

Codex 读前策略门禁、候选身份/共同质量、助手与模型生命周期、测试本机资源隔离仍存在差距，详见 [架构](../architecture.md) 和 [当前缺口](../status.md)。这些静态发现不自动证明发生过错插、泄漏或模型重启，也不能被离线测试通过覆盖。部署/回滚按 [release](../release.md) 的阻断条件处理。
