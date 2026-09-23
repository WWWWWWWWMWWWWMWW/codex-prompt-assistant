# 2026-09-09 远程稳定性与候选发布

## 生成证据

[16 次合成远程测试](../evaluation/results/remote-stability-2026-09-09/README.md)：9 次候选保持原意，1 次拼接不自然，4 次留空，2 次约 5.12 秒请求超时。
只有两个场景两轮均产出合格候选。未重试覆盖失败，不认定第二步通过。

## 发布证据

main.m startDelayedRemoteModelSuggestions 在 localModelTask 存在时以 0.25 秒计时重试，推迟远程发起。
displayInsertionText 在 displayedSuggestionSignature 非空时直接拒绝后续候选，与候选来源无关。
CandidateLifecycleTests 的 CandidateReplays 明确断言：本地先展示后，迟到的较好结果、空结果或被拒结果都不替换；Tab 保持第一个候选。
本轮 make candidate-lifecycle-test 退出 0，C1 replay failures: 0。
因此“先到者固定”是已确认行为；尚未实机复现某一条错误本地结果阻挡正确远程结果。

## 判断与后续方案

不能只让远程替换本地：来源不等于正确性，且用户按 Tab 前自动换字有交互风险。
建议下一工作包先给候选增加可复核的原意保持验收，并在首次展示前选择候选；已展示候选继续固定。
验证用例必须同时包含：本地错误/远程正确、远程错误/本地正确、双方错误、留空、超时，以及输入变化/任务切换/Tab 接受。
语义判断方案本身需用保存的正反例验证，不能把新增审核模型视为可靠性保证。
本轮没有修改发布策略或任何用户开关；没有安装/重载或实机 Tab 操作。

## 实际验证范围

新增实验数据条数、阶段和人工标注已核对；候选生命周期回归及 git diff --check 通过。
未执行应用全量构建/签名，因为仅新增实验与文档。
