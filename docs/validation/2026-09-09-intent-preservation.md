# 2026-09-09 第二步：保留原意实验

对 .5 请求系统指令追加对象、现象、否定关系、范围保持约束；生产实现不变。
[完整合成实验与判读](../evaluation/results/intent-preservation-2026-09-09/README.md)。

24 次尝试无系统失败，部分样本改善，但本地关键 user_why 仍改写现象，scope 仍扩展范围。
本轮方案不采用，第二步未整体通过。

工具新增实验专用系统后缀，默认关闭；网络桩核对本地 prefix 与远程 chat 两种请求，
移除追加后缀后完整请求与基线相等，证明没有悄然替换历史、示例或预算。
make completion-quality-harness-test 和 make build/CompletionQualityBenchmark 退出 0；
git diff --check 通过。仅改实验工具、工具测试和文档，因此没有重跑应用构建或实机 Tab。
未安装/重载，未更改用户开关，未重启 Codex 或模型。

下一步检查请求中草稿焦点提取是否扭曲用户现象，以及现有示例/指令的冲突；
先做单变量实验，不将更多过滤当作语义修复。
