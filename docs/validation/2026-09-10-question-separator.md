# 完整问句末尾分隔符导致回答被放行

2026-09-10，用户截图确认：输入区是带末尾逗号的完整疑问句，提示浮层给出结论和核查建议，违反只续写、不回答的契约。已查看原图；未把真实输入/截图复制到评测仓库。以下均为改写后的固定合成材料。

## 根因与修复

`.14` 的 `CPACompletionCanContinueAtCursor` 按标点分句后直接取最后一项。问句以逗号、冒号、分号等结束时，最后一项为空，疑问判断因此失效。共同显示门同样调用该函数，所以即使末尾带空分句的完整问句不应继续，回答仍可进入浮层/Tab 候选。

旧协议测试还将“这个开关有什么作用，”显式列为允许；这条预期与当前产品契约冲突，是验收缺口。本轮将它移到停止组，不删断言来隐藏失败。

`.15` 检查最后一个非空白分句；分句包含完整 newline 字符集，覆盖 CR/LF/U+2028/U+2029。末尾纯标点/空格/换行不能抹掉前面的完整问句；真正输入了新的非空分句时仍只判断新分句。原列表、未闭合结构、右侧文本和句末规则保持。没有通过禁用模型或新增某条回答黑名单处理症状，也未宣称有限疑问规则能识别所有语言结构。

## 证据

| 验证 | 结果 | 限制 |
| --- | --- | --- |
| `.14` 合成固定回答回放 | 36/36 个完整问句分隔符变体被放行为候选；8 个正常对照也通过 | 回放合成输出，不请求模型，不判断截图候选来自哪一路 |
| 原版失败复现 | 协议断言失败；应用层两路各出现显示拒绝/Tab 目标断言失败，共 4 项 | 原版 `make remote-completion-test` / `make candidate-lifecycle-test` 均退出 2 |
| `.15` 44 条同组回放 | 36 条完整问句全部 boundary_rejection；8 条对照仍 candidate | 对照包含普通逗号、实际新分句、未完如何/为什么及显式列表 |
| `.15` 生产客户端 | 36 条 × 2 次=72 次，全部 no_suggestion_boundary，HTTP=0，raw=null | 本地配置、sandbox 禁网；不是实际远程模型调用 |
| 两路客户端和显示门 | 核心两路无 HTTP/冷却状态保护通过；应用显示门两路拒绝固定回答，无可见候选或 Tab 目标 | 使用网络/浮层/输入替身，非实机 |
| 完整回归 | `make remote-completion-test`、`make test` 退出 0；C1 replay failures=0 | 相关日志在 `/tmp/cpa-question-separator-after.log`、`/tmp/cpa-question-separator-app.log` |
| 固定旧回归 | 133 条协议及 90 次禁网客户端全部保持 | 原有限字面路径期望未改 |
| 构建/安装/部署自测 | `make app build/CompletionQualityBenchmark`、严格签名、包散列、启动身份、event tap、运行映射通过 | 实机输入/Tab/Esc 未复测；上轮自动测试前台不一致仍是独立阻断 |

首次合成夹具准备因临时 Python 括号错误退出 1，未创建夹具即已修正。第一次修复后测试暴露上述旧预期冲突，随后更正这一个预期并重跑。第一次客户端回放构造缺少必填 `family_id`，benchmark 因 nil 字典值 SIGABRT；补齐合成元数据后 72 次完整回放通过，已经成功的 44 条回放按内容相同保留。上述失败记录在 [failure-records.json](../evaluation/results/question-separator-2026-09-10/failure-records.json)，不是生产模型失败。

## 安装对象与恢复

- 助手 PID67402，2026-09-10 14:34:24 启动，旧 PID65953 已退出。
- 契约 `2026-09-10.15`；产品 0.2.0 / build 2；Git `230411e3d7517150b5d5f6ed7a82eaae5c7dc232`，dirty=true。未提交或推送。
- 协议 SHA256 `cec3e0337f2f4eedf249e5f9d6aae2180f870f35980b02d35ebd5543b534381b`。
- 新可执行 SHA256 `da1cc97e29e8cff86b5d6905633e55fb01d3395dc78e3bc81ad24dacf8046139`；旧 `.14` 为 `92a6d84c8168193f08bc8259b6d92664f2e517a6aa7806cdcde931237a4fd75e`。
- 原包及副本：`/Users/hcm-b0263/Applications/.cpa-question-separator-2026-09-10-hc4u53m8/`。沿用原 guarded plist 及 `--preserve-resident-model`，bundle ID、designated requirement、目录和 label 不变。
- 安装前后全部偏好相等，双开 / Terra、表达库暂停。Codex PID13565 / 09-09 17:43:10、模型 PID2353 / 09-09 15:23:05 未重启。

部署后的运行映射、进程与设置核对见 [数据说明](../evaluation/results/question-separator-2026-09-10/README.md)。截图本身是用户实机失败证据；不能把修复后离线通过写成用户实机已确认。

## 后续优先级

当前自动优化任务继续优先检查“问句被接成回答”的其他已证实边界，再处理上下文确认/修订链。只有有新证据时扩大规则，不用局部字面续写成功率代替此核心契约的验收。前台归属恢复后，补齐真实浮层与 Tab/Esc 复测。
