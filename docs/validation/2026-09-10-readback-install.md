# 2026-09-10 回读诊断安装与验收边界

## 目的与准备

用户要求继续显示、Tab 链路验证。安装上轮已通过候选生命周期回归、构建和严格签名的无正文诊断，语义及日志限制见 [回读记录](2026-09-09-insertion-readback.md)。本轮未改生产源码，不重复已通过且未变的测试。

开始执行 `git status --short --branch`、`git diff --check`，保留所有已有修改。运行助手 PID27763（9月9日19:53:28），Codex13565（9月9日17:43:10）、模型2353（9月9日15:23:05）；当日诊断日志仍更新。

CUA 可看到 TextEdit 打开面板截图，但 AX 仅暴露窗口，Raise 后不变；重置工具后坐标点击“新建文稿”返回 `elementPresumedOOPAndNotFound`（-10005）。未取得新文稿或输入框确认，没有输入测试文字或 Tab，也没有改用其他技术绕过 UI 工具限制。该结果是自动化控制阻断，不能归因为助手补全故障。

## 10:02 限定更新

继续沿用既有带 `--preserve-resident-model` 的助手服务，只 bootout/bootstrap 精确助手 label；不使用会重新构建或覆盖回退包的 service-start 目标。核对新旧包的保护版本为 1、严格签名及指定散列；在同卷复制并校验新旧副本后停止旧助手，等待其退出，再交换安装路径。

- 旧可执行 SHA256：`020eb986cec9c28b6f4e2feb0dba1e478625e5b483373ed51521dcc31a6afc1f`。
- 新可执行 SHA256：`7f8be89b65a3c7f884b9e37d7172121742688962be1f21040c4798b2f1f394de`。
- 新助手 PID42880，2026-09-10 10:02:04 启动；启动日志 10:02:05 确认 .6、230411e3d7517150b5d5f6ed7a82eaae5c7dc232 dirty、`event_tap start=true`。
- `lsof` 进程可执行路径、设备号、inode 与已安装文件一致，安装文件散列及签名通过。
- Codex13565/模型2353 的 PID、启动时间与可执行路径保持。服务 plist 散列保持 `58e48877f3cfda7c8ee797bbcd156c6b56443d7f4dc385415edf50fe6c4f5bf1`。
- 偏好在内存中逐项比对一致，没有写设置或记录完整偏好。本地/远程暂停位均 false，远程 `gpt-5.6-terra`，表达库暂停 true。

新旧均为 dirty 构建，以独立可执行散列及保留副本识别；没有把本次限定更新当成 clean-only 通用发布流程通过。未提交、推送或执行实际失败回滚。

回退副本与证据：`/Users/hcm-b0263/Applications/.cpa-readback-dol5d78q/`，`previous.app` 与 `backup.app` 均保留此前已安装包，`evidence.json` 保存无正文元数据。工作区指针 `.build/readback-evidence-path.txt`。本轮实际更新成功，恢复分支没有执行，不称回滚已验收。

## 仍待验证

诊断已进入运行版本，但安装、事件监听启动不证明浮层可见或宿主插入成功。需要独立合成输入、可见后缀、Tab 后全文一致三项证据；只有 `source=accessibility` 的 matched 支持宿主 AX 回读，shadow 匹配不能替代。第二步生成原意保持、第三步语义过滤仍按既有记录保留缺口。第一步用户报告的打字/切换平稳不外推为全部任务布局与压力条件通过。
