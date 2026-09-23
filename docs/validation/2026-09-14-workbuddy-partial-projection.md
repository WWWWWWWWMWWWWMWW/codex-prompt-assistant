# WorkBuddy 部分容器投影漏读修复

2026-09-14，承接[批量读取](2026-09-14-workbuddy-metadata-batch.md)。最后收到的 06:45:10 UTC 实机 C 样本为 1 正文、3 确认工具栏、2 个已知用户容器阻断，字符预算未停，393 ms。由此确认两条正文被部分保留的用户容器拦截。该证据来自5.5.3，不外推所有5.5.6会话。

## 实现与回归

平铺路径现在允许明确的用户气泡、用户消息及正文容器继续追溯到同一个右侧消息框；仍要求唯一只读正文及唯一已发送编辑工具栏，拒绝编辑中、废弃、工具及未知容器。完整结构链仍优先走原结构路径，不重复加入同一条正文。读取后重新核对状态和归属。

新增4种部分容器组合先在旧版稳定失败（C1 failures=4）；修复后 `make test` 退出0。额外覆盖完整结构/平铺路径不重复、编辑/废弃/工具拒绝、读取中状态变化拒绝；最终公共 `make candidate-lifecycle-test` 退出0。已有实际reader到两路请求精确 A→B→空→A 回放及迟到拒绝保留。没有实际模型调用或草稿输入。

`make app`、严格签名、备份、安装后映射/启动身份/事件监听核对通过。当前 PID5187，SHA256 `9250cdd8e77a7930a3328b2686c55f121bb1dda0f26e888f05e59efc5bc31776`，提示仍 .16 / Git230411e dirty=true。上一包保存在 `/Users/hcm-b0263/Applications/.cpa-workbuddy-partial-projection-2026-09-14-s8nfyspo`，更早备份均保留。

## 现场环境变化

线程中断期间进程已整体重新启动，WorkBuddy 更新为5.5.6。恢复后核对：助手810、Codex1809、模型819，WorkBuddy主进程2042；本轮只更新助手810→5187，当前Codex1809/模型819的PID与启动时间保持。5.5.6的已安装UserContentRenderer仍为只读Input，FrameRenderer及SelfBubble/ToolbarRenderer仍存在；asar SHA256 `e75c09407fefbd96f59625355d328908631458224b7fb5bcded4c0c87375c9bb`。源码存在不等于实机投影相同。

重启后实际加载的是 `~/Library/LaunchAgents/local.codex.prompt-assistant-app.plist`，没有模型保留参数。安装使用此前已有的 `~/Applications/.cpa-morning-qzte1kx9/guarded-helper.plist`（同一个label、同一应用路径，带 `--preserve-resident-model`）重载助手，避免干扰现有模型。磁盘原LaunchAgent未修改；必须区分“plist内容保持”与“当前加载路径发生变化”，不能宣称加载配置完全未变。所有本地/远端及其他偏好保持。

## 未验证与继续项

当前5.5.6已通过CUA打开C并定位输入框，但系统前台仍为飞书，已请求保持WorkBuddy前台并继续监听。最终C是否恢复3条、B批量读取后是否在500ms内完成、最终A→B→A实机矩阵、真实正文逐条对应、物理Tab/Esc尚未验证。不得把本轮合成回归与安装身份核对当作实机完成。

后续先取最终版C样本，再切A→B→A，按最新失败继续处理。无提交、推送、自动发送或用户草稿修改。

[验证元数据](../evaluation/results/workbuddy-partial-projection-2026-09-14/verification.json)。保留失败日志 `.build/workbuddy-partial-before.log`，通过记录 `.build/workbuddy-partial-after.log` / `.build/workbuddy-partial-final.log`。

## 最终未发送边界修正与安装

复核新增部分容器路径时发现：正文快照以frame为归属，显式未发送标记却只排除内部owner；工具栏仍显示“编辑”的过渡状态可能放过未发送正文。合成回归先失败1条，再同时排除owner及其frame。完整 `make test` 通过、C1 failures=0，构建/验签通过。

最终当前助手 PID6133，SHA256 `b73d0f8fd23924fef43bf54675ace0be9b2e5d80a5a188b80df4f4276b364689`；提示 .16 / Git230411e dirty=true 保持。已安装并核对运行映射、启动身份和事件监听；上一包在 `/Users/hcm-b0263/Applications/.cpa-workbuddy-partial-final-2026-09-14-vrhzcspg`。当前Codex1809/模型819及全部偏好保持，此次仍用同一guarded服务路径。

保持180秒监听后依然没有新WorkBuddy上下文样本，系统前台持续为飞书相关进程。最终C恢复、B时延和跨对话实机验收未完成；不是等待安装授权，而是后台UI聚焦不能替代真正的系统前台。新增失败/通过日志 `.build/workbuddy-partial-unsent-before.log` / `.build/workbuddy-partial-unsent-after.log`，最新[验证元数据](../evaluation/results/workbuddy-partial-final-2026-09-14/verification.json)。
