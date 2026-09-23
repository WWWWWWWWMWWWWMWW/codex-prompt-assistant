# WorkBuddy 结构批量读取与模型请求连通验证

2026-09-14，承接 [节点容量修复](2026-09-14-workbuddy-switch-node-limit.md)。上一轮仅放宽容量不够：已取得 PID64229 的新实机证据，B 反复耗尽 500 ms。当前继续修复，未宣布跨对话功能全部通过。

## 现场结果

- B：06:29:30—06:31:03 UTC，连续 `structure_cancelled`，当前扫描次数 69—3047，耗时 500—511 ms；单纯扩大节点上限没有使本次实机 B 成功。
- A：06:31:18 起，多次 ready / 392 结构节点 / 3 个用户正文，耗时 95—303 ms，预算未停止。
- C：06:33:15 起，ready / 1122 节点 / 1 个平铺正文 / 3 个确认工具栏，预算未停止。说明漏读在结构候选识别阶段，不能归因于 3000 字符预算。
- 切换操作期间一次使用旧索引误打开另一条对话，刷新索引后切到 C；未改动任何草稿或发送消息，此段不混作 A/B/C 验收。

## 本轮实现

`GenericAccessibilityService` 用一次 AX 批量调用取得当前节点的类名、孩子、父节点和角色。`WorkBuddyContextReader` 只在单次结构扫描中缓存元数据；正文从原始读取器获取，二次归属校验重新建缓存。未知属性保留不可用状态，批量调用失败回退原接口。

结构遍历不深入 AXStaticText 的字形排版孩子，正文仍按原完整消息读取。维持 0.5 秒时限、600 正文节点、3000 UTF-16 字符与两次归属校验。新增固定计数诊断，区分平铺正文被保留的用户容器阻断；不记录正文、类名原文或任务标题。

## 验证与安装

- 新增实际 WorkBuddy reader → 实际应用生命周期 → 两路假客户端的合成 A→B→空列表→A 回放，逐条比较两路模型请求材料，并检查两路迟到旧结果不可展示、空列表取消两路在途请求。
- `make candidate-lifecycle-test` 连通回放通过；批量读取改动后 `make test` 通过。补充 6001 个字形孩子及批量缓存状态变化回归后，再次公共 candidate-lifecycle-test 通过，C1 failures=0。没有把假客户端称为真实模型服务测试。
- `make app`、验签、备份安装、映射文件、启动身份、事件监听自测通过。当前 PID69802，SHA256 `aa97b77a490b7ddf56c8dc6aae3e72c2ee2e74c02ef96228803555aa3dff4e02`；Git230411e dirty=true、提示 .16 保持。
- 上一版本备份 `/Users/hcm-b0263/Applications/.cpa-workbuddy-metadata-batch-2026-09-14-mupam5e1`。全部偏好和 Codex/模型进程保持，WorkBuddy 未重启。无提交或推送。

## 自动操作边界及尚未完成

窗口 Raise、Cmd+Tab、访达 AX 打开和双击均尝试过。一次从访达打开后出现了系统前台匹配，后续却无法稳定重复；不能确认第一次成功由自动操作导致，也可能是人工切换。后台 UI 的输入框聚焦不等于系统前台变化。现场后来持续在 Chrome、飞书与 Codex 间切换，已保持监听并请求用户停留 WorkBuddy。

CUA Dock 查询超时；访达离屏元素双击无 frame，滚动后坐标双击仍未建立稳定系统前台；清理本次新访达窗口时 native pipe closed，清理结果待回读确认。原用户访达窗口未主动关闭，聊天草稿未改动。

安装后 B 是否在时限内成功、C 的具体保留容器类型、完整 A→B→A、真实正文逐条比对、真实模型在途切换、Tab/Esc 均未完成。下一项依赖：取得批量版前台样本，核对 B 和 C 诊断，再据确定原因继续修复。

[验证元数据](../evaluation/results/workbuddy-metadata-batch-2026-09-14/verification.json)，[安装前实机元数据](../evaluation/results/workbuddy-metadata-batch-2026-09-14/pre-batch-observations.json)。日志仅提取固定结构计数，原聊天未持久化。
