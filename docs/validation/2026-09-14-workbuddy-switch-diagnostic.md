# WorkBuddy 跨对话读取：诊断修正，主故障待实机定位

2026-09-14，承接 [跨对话验证](2026-09-14-workbuddy-switch.md)。本轮未完成 B 读取失败及 C 完整性修复，不得将诊断部署当作功能验收通过。

## 已修改

`WorkBuddyContextReader.m` 的 shell 扫描早退原先继承 `root_missing`。现在分别报告输入归属检查、结构节点上限、取消、嵌套容器、正文节点上限和读取后归属变化。成功结果附带可用正文数及预算停止标志，只记录固定原因和数量，不记录正文、标题或身份。

读取策略、1800 结构节点 / 600 正文节点 / 3000 UTF-16 预算及 0.5 秒时限保持。未根据误导性诊断扩大根搜索或放宽正文归属规则。

## 验证

- 两次公共 `make test` 均退出 0，含候选生命周期回放 0 failures。第二次新增真实 reader 的合成 A→B→A 精确消息比较、复用输入框、切换空列表不复用旧材料，以及 1801 子节点的扫描上限诊断回归。所有正文均为合成。
- `make app`、严格签名和 designated requirement 核对通过。
- 备份安装成功，当前助手 PID53307，SHA256 `162582669362be584eb3965e90441e8d445478d29d74f50bbf0cbcef6f2e007b`；Git `230411e` / dirty=true，提示契约仍 .16。
- 原 PID39405 / a43dcbad… 包保存在 `/Users/hcm-b0263/Applications/.cpa-workbuddy-switch-diagnostic-2026-09-14-gkz83oht`。安装映射、启动身份、事件监听均核对通过。
- 全部偏好和 LaunchAgent 保持，Codex13565、模型2353 的 PID 与启动时间保持，WorkBuddy93314 未重启。未提交或推送。

## 实机阻断与下一步

CUA 已切到 B 并定位/点击输入框；Raise、元素点击、坐标点击未让助手所见系统前台从 Codex 切为 WorkBuddy。一次错误参数调用未执行；随后按 API 修正。已请求用户手动保持 WorkBuddy 前台，目前无诊断版 WorkBuddy 上下文样本。

B 的节点上限只是可复现的候选原因，尚未证明是实机根因；C 需要新日志区分预算停止与结构筛选。下一步取得前台样本后按确定原因修复，再运行 A→B→A / C 并安装自测。未复测浮层或物理 Tab，不把离线回归当实机通过。

证据：[安装与验证元数据](../evaluation/results/workbuddy-switch-diagnostic-2026-09-14/verification.json)。忽略目录中的本轮测试日志：`.build/workbuddy-switch-fix-diagnostic-tests.log`、`.build/workbuddy-switch-fix-regression.log`。
