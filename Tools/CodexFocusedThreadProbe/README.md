# Codex 当前任务 ID 探针

显式、单次调用 Codex 自带的 Copy deeplink（复制深层链接）命令，验证返回
`codex://threads/<UUID>`，核对焦点控件和窗口未变，再恢复原剪贴板。
不读取输入框正文、不粘贴、不发送、不启动或重启应用。

```sh
python3 Tools/CodexFocusedThreadProbe/run.py --self-test
python3 Tools/CodexFocusedThreadProbe/run.py --pid <正在运行的Codex主进程PID> \
  --copy-current-thread-id --verify-local-source
```

默认要求 Codex 的输入框已经聚焦。显式 `--activate` 可短暂置前正在运行的
Codex，并在结束时恢复之前的前台应用（期间用户未自行切走时）。
显式 `--focus-composer` 会在当前焦点窗口仅有一个可用文本编辑框时聚焦它，
不输入、不清空；多个编辑框或查找不完整时拒绝。它不是生产环境的控件策略门。
`--verify-local-source` 只按取得的 ID 查询本机 SQLite 并核对日志首行的
`session_meta.id`，不输出日志路径、标题、聊天正文或剪贴板原文。

## 边界

- 适用于已检查安装包的默认 ⌘⌥L 绑定；自定义快捷键需要另行核对，不能盲调。
- 这是有短暂剪贴板副作用的界面命令，不是官方“当前焦点 ID”查询 API。
- 复制之前保存全部可读取的剪贴板数据（最多 8 MiB）。发生额外写入时拒绝
  返回 ID、不覆盖新剪贴板。读取检查和恢复写入非原子，剪贴板管理器也可能
  观察到临时链接。自动接入实现及实机阻断见 [接入记录](../../docs/validation/2026-09-09-codex-id-integration.md)。
- 同一控件和窗口不变不能证明所有宿主内部路由切换竞态都不存在；主窗口、
  浮窗和两任务快速切换需分别验收。新任务无 ID 时应失败，不回退猜测标题。
- 远程任务可能没有本机日志，`--verify-local-source` 会明确失败。
- 本工具不安装助手、不改变模型/补全开关、不读取真实草稿；运行时请暂停打字
  和复制操作。传入 `--production-resolver` 可单次调用生产解析器，包含输入事件保护；不安装助手。

生产解析器同时使用 session 和进程级监听；创建失败不发送快捷键。超时状态区分
`copy_dispatch_unobserved`（未观察到投递）、`copy_cancelled_before_dispatch`
（投递前取消）和 `copy_timeout_after_dispatch`（已经过监听但没有链接响应）。
观察到投递不代表宿主已执行命令。

## 多次诊断记录

原来的 `运行任务ID诊断.command` 入口不变。每次结果独立保存到
`.build/focused-id-diagnoses/<UTC时间>-<唯一编号>.json`，成功和失败均保留。
`.build/focused-id-diagnosis.json` 继续提供最新一次结果，采用临时文件替换，避免读取半写入数据。
记录仅含原有诊断字段及 runId，不保存输入、剪贴板正文或真实任务 ID。
`currentTaskMatches` 仍指是否匹配本次验收的原任务；false 只表示不同，不能独立证明选中了指定的另一个任务。

已用临时目录验证连续保存两条记录互不覆盖、最新结果指向第二条；未触发实机诊断。

## 正文归属验证

诊断入口现追加 `--verify-context-body`：仅在本次自动取 ID、日志头匹配通过后，
使用生产 ConversationContextProvider 读取有界上下文，不调用模型。结果只含状态、
消息数量和合成标记是否匹配。A/B 标记必须是用户单独发送的一整条消息，
助手引用或正文中的局部提及不会被算作命中。

正文未就绪时返回非零，不能将取 ID 成功当成正文验证通过。原有逐次记录保留。
已用临时 SQLite/JSONL 验证生产读取器 A→B→A 对应各自标记，
对侧标记出现在助手消息时不会误报；没有操作真实任务或安装助手。
