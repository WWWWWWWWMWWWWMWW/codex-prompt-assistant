# 表达库独立暂停与安装

2026-09-09 13:46。用户明确要求先安装表达库独立暂停，双路候选替换规则保持原实现。

## 已确认

- 新增持久化偏好 `expression-library.paused`，本次置为 true。查询表达库之前返回空候选，继续走既有模型调度；默认值 false 保持其他安装兼容，可逆恢复，不清空/重建数据库。
- 设置与本地、远端开关独立；本次安装前后 `local-completion.paused=1`、`remote-completion.paused=0`，保持用户当前的本地关闭、远端开启。
- 数据库只读复核，安装前后均为 1,003 条表达。扫描、导入及实时上下文逻辑未因本轮修改。
- 公共 `make test remote-completion-test app` 退出 0，含暂停前不查询、恢复可查询、模型请求路径仍可用以及偏好独立持久化回归。随后仅调整启动状态日志到 settings 初始化后，再次 `make app` 退出 0 并严格验签。
- 初始测试夹具因前置声明及不可用默认初始化方法编译失败，修正测试初始化后复现暂停查询失败；加入入口开关后全部通过。原先“后到候选不覆盖”的生命周期测试保持并通过，本轮没有落实远端覆盖方案。

## 安装证据

只停止/启动精确助手 label，使用既有 `guarded-helper.plist` 与 `--preserve-resident-model`。同卷暂存和签名核验后替换，旧包保留 `/Users/hcm-b0263/Applications/.cpa-expression-pause-okgy949z/previous.app`、`original.app`，同目录 `evidence.json` 保存过程摘要。

助手 PID 91310 → **94078**，新启动时间 13:46:51。运行日志确认 `expression library lookup paused=true`，以及 commit `230411e3d7517150b5d5f6ed7a82eaae5c7dc232`、dirty=1、契约 `2026-09-09.2`、协议 SHA256 `ebca3e707d0e39cb93c0f69c30ac1f01ce57d43d313518fae18099e9305aef48`。可执行 SHA256 `fc80efa8f52debbc4befccea2e3b90fdd80f2ccb88c9d18154465d3eb32646f3` 与候选包一致。

Codex PID 48607（9/7 16:56:15）、模型 PID 56047（8/27 20:08:55）及启动时间保持。设置已回读，库数据保留。没有提交/推送，没有修改或覆盖用户草稿。

## 验证边界

已验证源码入口、隔离桩、构建签名、安装/启动身份及实际持久化设置；没有做新的实机输入/Tab 或语义质量评测。暂停表达库不等于停止读取已授权的当前会话上下文，也不等于暂停历史扫描。重启后该偏好继续生效；本轮不新增菜单入口。
