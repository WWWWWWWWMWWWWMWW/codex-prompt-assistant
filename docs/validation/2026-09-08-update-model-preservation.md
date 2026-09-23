# B-01 更新启动保护与只读预检

日期：2026-09-08。承接事务核心 `e96d3ea`。本包没有安装或重载，不更改用户本地/远程开关。

## 新版启动契约

新增 `--preserve-resident-model` 参数。`CPALocalModelServiceController` 的生产初始化从本进程参数读取，保护状态仅在本进程存在，不写 defaults。保护状态下：

- `ensureRunning` 只查询现有模型服务，已加载返回 YES；缺失或查询异常返回 NO，不执行 bootstrap。
- `stop` 返回 NO，且不发出 bootout；助手退出既有不停止模型的逻辑保留。
- 没有该参数时维持原行为，普通启动仍可尝试 bootstrap 本地模型；用户的两个补全开关不被重置。

Info.plist 增加 `CPAUpdateLifecycleVersion=1`，表示本构建支持此明确参数。标记会进入签名与整包摘要；它不是“全部更新路径安全”的声明。更新启动必须实际传参才能生效，旧安装 `e1b4154` 没有此能力，不能只给旧包追加未知参数后假定保护成立。

## 只读预检

`Tools/Release/preflight_update.py` 严格校验新旧包；只查询固定助手/模型 LaunchAgent 的 PID，以及指定 Codex/模型与助手的 PID、启动时间、可执行路径。前后取样必须相同，助手路径必须对应指定安装包，模型 PID 必须对应固定模型服务；查询失败保留 unknown，不推定已停或可更新。

结果分别列出新包/回退包是否支持启动保护。当前工具固定保留 `live_health_adapter_not_validated` 阻断项，不把磁盘包匹配、PID 存活或 launchctl print 成功当作运行版本与功能健康确认。没有变更子命令，也不调用 stop/bootstrap。退出码 2 表示得到明确阻断报告，1 表示查询/校验失败或未知。

## 已验证

- `make local-model-service-test`：正常参数和保护参数分别运行测试可执行文件；模型已加载、缺失、查询错误、bootstrap 失败、停止已不存在服务、保护期间禁止停止，以及生产初始化参数解析均通过。命令执行器为替身，没有真正模型服务操作。
- `make release-preparation-test`：原 17 项准备测试和新增 6 项预检测试通过。覆盖旧包阻断、即使两包支持保护仍不跳过运行健康门禁、错误助手路径/模型 PID、嵌套或重复 PID、前后启动身份变化和命令失败。
- `make check-offline` 通过，含事务核心 16 项、应用、数据、表达、远程协议桩和 WPS 桩。日志 `/tmp/cpa-b01-final-offline.log`。
- 回归先验证缺少保护接口/预检模块时失败，再实现；分别见 `/tmp/cpa-b01-model-guard-red.log`、`/tmp/cpa-b01-preflight-red.log`。通过日志为 `/tmp/cpa-b01-model-guard-test.log`、`/tmp/cpa-b01-preflight-test.log`。

真实 launchctl 只读查询确认助手服务 PID 4085、模型服务 PID 56047；未输出服务完整环境或诊断正文。当前安装的既有启动记录仍可定位到 PID 4085、commit `e1b4154`、dirty=0；不据此证明新构建运行。

## 未验证

本包新启动参数尚未用于实际助手运行；没有真实模型缺失故障注入、服务替换或运行回滚。只读预检不是事务核心的服务适配器。实际旧包迁移必须考虑回退包不支持保护：不能在模型状态不明时自动启动旧包。后续先形成能确认停止、运行身份及启动保护的真实适配器和限定迁移路径，再补无发送 UI 验收。B-01 与 M0 运行门禁不变。
