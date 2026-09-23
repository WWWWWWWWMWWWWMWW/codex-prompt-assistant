# 决策索引

ADR 保留当时的背景与决策，部分被后续实现替代时只加状态说明和后继链接，不重写原历史。当前运行状态见 [status](../status.md)，实现边界见 [architecture](../architecture.md)。

| ADR | 继续适用 | 被替代或验证边界 |
| --- | --- | --- |
| [0001 聊天来源](0001-chat-source-boundary.md) | Codex 本地来源、ChatGPT 导出导入、无静默 OCR 冒充 | 原“需要全部聊天”是阶段背景；当前实时历史有预算，见 0007 |
| [0002 本地学习与远程补全](0002-local-learning-and-remote-completion.md) | 原始数据/派生表达分离，本地处理 | 不引入本地大模型、远程唯一最终续写已由 0007 记录的实现替代 |
| [0003 实时建议接入](0003-codex-inline-suggestion.md) | AX、独立浮层、不修改 Codex、输入法保护目标 | 实机记录有版本/场景限制；Apple 开发者签名要求尚未实现，当前为固定 identifier 的 ad-hoc 签名 |
| [0004 消息加密](0004-local-message-encryption.md) | 加密信封与消息/派生数据保护原则 | 主密钥只存 Keychain 部分由 0006 替代；不是本轮全存储安全审计 |
| [0005 内存表达索引](0005-encrypted-expressions-in-memory-index.md) | 加密持久化、内存前缀检索 | 索引不含当前任务身份；共同显示门后续已进入源码，语义依据仍有缺口，现状见 architecture，目标见 0008 |
| [0006 本地主密钥文件](0006-local-master-key-file-for-background-scan.md) | 后台扫描使用本地主密钥文件 | 远程 API Key 仍在 Keychain 的描述由 0007 替代 |
| [0007 M0 现行实现基线](0007-m0-current-baseline.md) | 汇总当前生成、数据与操作边界 | 追认已有实现；保留明确缺口，不新增功能或发布授权 |
| [0008 有依据的续写与稳定候选](0008-grounded-continuation-contract.md) | 核心体验的目标语义、快照/候选契约及独立评测原则 | C1 已有源码/离线证据，候选固定未实机确认；G1 和审核净收益未验证 |
