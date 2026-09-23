# 实时健康回执与停止确认验收

2026-09-17。完成 C23 的实时健康和停止确认子项，并安装同一候选验证；发布阶段仍 S1。

## 实现

新增 `HealthProbe` 本机 CFMessagePort 协议和 `--health-probe <pid>` 调用。助手启动后在主线程注册按 PID/UID 命名的 responder，退出时注销。请求带随机 nonce，回执校验 schema、nonce、UID、PID、实例 UUID、构建身份和四个布尔状态；超时、旧回执、协议不符、进程/包变化均拒绝。`helper_health.py` 在此前运行身份检查基础上调用一次回执，并在前后重新检查运行状态。

停止确认不复用日志或进程目录：固定 label 必须明确不存在，且精确旧 PID signal 0 返回 ESRCH；其他结果为未知。

## 隔离验证

- `make health-probe-test` 通过：nonce、私有字段排除、主线程 IPC、主线程阻塞时有界超时、重复 start/stop、端点注销均通过。
- `make release-preparation-test`：59 项通过，新增实时健康/停止场景；包括回执身份/协议/状态不符、进程变化、超时、错误输出脱敏、服务错误与权限未知。
- `make test`：完整应用回归通过；`make app` 严格验签通过。
- 更新事务回归保持 21 项通过；事务仍未接入真实 launchd 适配器。

## 当前安装实测

使用当前助手安装包执行只读健康 CLI：

| 项目 | 结果 |
| --- | --- |
| `runtimeIdentityVerified` | true |
| `modelProtectionVerified` | true |
| `healthVerified` | true |
| 主线程 / event tap / 辅助功能 / 模型保护 | 全部 true |
| 回执耗时 | 23 ms |
| 自动更新资格 | false；dirty 包、停止后真实回退仍是阻断项 |

安装更新时先确认旧服务 label 不存在且旧 PID43524 已退出；新助手 PID75626 启动并完成上述回执。Codex1809、模型819、偏好摘要、加载服务配置及安装包身份保持。新备份位于 `/Users/hcm-b0263/Applications/.cpa-live-health-2026-09-17-37aq_any/`。

证据：[verification.json](../evaluation/results/live-health-2026-09-17/verification.json)，同目录保存测试日志、实时回执、停止确认、安装状态与实现补丁。报告不写入输入正文、草稿、密钥或完整偏好值。

## 边界与后续

健康回执只证明当次主线程可响应和四项运行状态，不能证明模型实际生成质量、候选显示、实体 Tab/Esc、中文输入或宿主插入。停止确认只在本次限定安装更新中实测，通用失败回退仍未注入验证；事务服务适配器仍需接入 `helper_health` 的 stopped/health 证据后再放行。

下一步是整合 clean 发布包的真实服务适配器和一次失败回退演练，再进行干净用户安装与首次授权；不增加首页设置，不扩大试用范围，未提交、推送或恢复自动化。
