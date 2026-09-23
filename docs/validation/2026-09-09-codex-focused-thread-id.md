# 2026-09-09 Codex 当前输入任务 ID 通道验证

## 结论与交付

已打通限定的单次链路：聚焦 Codex 输入框 → Codex 自带 Copy deeplink 命令
（默认 ⌘⌥L）→ `codex://threads/<ID>` → SQLite 按 ID 查询 → 日志首行
`session_meta.id` 一致。全程不经过标题匹配。

交付 `Tools/CodexFocusedThreadProbe/`，是独立显式探针，未接入常驻补全，未安装。
这不是官方“当前焦点 ID”读取 API；它借助现有界面命令，短暂写入系统剪贴板。

## 源码与现场证据

- 运行对象为 `/Applications/ChatGPT.next-8109.app`，Codex PID 48607，启动时间
  2026-09-07 16:56:15；收尾保持不变。本地模型 PID 56047，启动时间
  2026-08-27 20:08:55，保持不变；没有更新助手或改补全设置。
- 已安装包 `app-initial-cadb12d4a15e.js` 定义 `copyDeeplink` 默认
  `CmdOrCtrl+Alt+L`；`Nqi(e)` 将 `codex://threads/${e}` 写入剪贴板。
- 直接 AX 属性路线：将扫描深度从 24 扩至 80 后，现场两窗口累计 1014
  个节点，包含实际编辑框，仍未读到 ID。早期 419 节点扫描不是完整树。
- 窗口内存状态虽有活动任务 ID，但未找到外部可用的稳定读取接口。
- 草稿按 ID 保存可以成为线索，但重复草稿和持久化延迟无法证明焦点归属，
  本轮没有以真实草稿匹配来推断任务。

## 本轮实际验证

1. 原型单次复制：102 ms，取得本任务 ID，前后焦点/窗口相同，剪贴板恢复。
2. 独立探针端到端成功：124 ms，`localSourceVerified=true`，ID 与日志头一致。
3. 最终版本加入剪贴板所有类型/字节读回比较后，端到端成功：102 ms，
   `sameFocusWindow=true`、`clipboardRestored=true`、`localSourceVerified=true`。
4. 两次中间运行因焦点条件不满足返回 `focused_codex_composer_required`，
   退出 3，均发生在发送复制命令和改写剪贴板之前。不算成功或性能样本。
5. 最终 `--self-test`：0 failures，严格链接解析及剪贴板版本归属检查通过。
   首次编译有 `ThreadID` 与 macOS typedef 同名冲突，改为
   `CPAThreadIDFromDeeplink` 后修复；最终 `-Wall -Wextra -Werror` 编译通过。
6. `git diff --check` 通过。没有运行全套应用测试/`make app`，因为没有改生产
   路径或安装；未发送、粘贴、修改/清理任何真实草稿。测试只读取焦点元数据，
   原剪贴板仅在内存暂存，不记录正文。源验证仅读取有界日志首行。

本次返回 ID 与当前任务环境 ID 相同；文档不复制真实草稿、标题、日志正文或
剪贴板原文。临时原型原始状态证据位于 `/tmp/cpa-id-probe-x4pvmgn5/`，
可重复入口以仓库工具为准，不依赖临时路径存在。

## 限制与后续集成条件

- 上述耗时是三次成功样本，不是 P95 或稳定性承诺；最终探针默认要求输入框
  已聚焦，`--activate`/`--focus-composer` 只供显式验证，不能当生产策略门。
- 空白新任务、多个任务快速切换、浮窗归属、用户更改快捷键、剪贴板管理器、
  快速复制/粘贴竞争均未验收。
- 剪贴板检查和恢复不是原子事务，即使最终字节读回一致，也不能保证其他
  剪贴板观察者没看到临时链接。事件归属/路由变化尚需额外验证，不能仅凭
  AX 节点相同声明无串任务风险。
- 自动接入前须明确触发频率、输入/焦点/任务切换取消、剪贴板争用处理及
  失败时不附历史的策略；不以“已拿到一次 ID”作为自动轮询上线依据。
- 官方 App Server `thread/read` 是取得 ID 之后可选的数据读取通道；本轮
  没有连接或启动 App Server，使用现有 SQLite + 日志头验证来源。

官方参考：https://learn.chatgpt.com/docs/app-server
