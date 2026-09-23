# 纯插件输入降级实现计划

> **For Codex:** 按本计划逐项实现并在每项后运行对应测试。

**Goal:** 在不修改 Codex 启动参数、不终止或启动 Codex 的前提下，AX 输入树不可用时仍能为当前输入提供可接受的实时补全。

**Architecture:** 保留现有 AX 路径作为首选；新增键盘影子缓冲状态机，只记录 Codex 前台期间的文本编辑事件，并在 AX 失败时生成最小输入快照。运行时 AX 增强只做一次无副作用探测，失败后直接走影子缓冲；不使用 KeepAlive、自动重启或屏幕截图。

**Tech Stack:** Objective-C/AppKit, Carbon CGEventTap, ApplicationServices AX, Foundation unit tests.

---

### Task 1: 键盘影子缓冲状态机

**Files:**
- Create: `Sources/CodexPromptAssistantPOC/KeyboardShadowBuffer.h/.m`
- Test: `Tests/CodexPromptAssistantPOCTests/KeyboardShadowBufferTests.m`

**Acceptance:** 普通字符追加、退格、删除、回车清空、Cmd/Ctrl 快捷键边界、程序插入抑制均有单测；不记录正文到诊断日志。

### Task 2: 接入键盘拦截器

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/KeyboardInterceptor.h/.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`

**Acceptance:** 仅 Codex 前台更新影子缓冲；Tab/Esc 仍遵循现有中文输入法放行规则；AX 可用时影子状态被真实 AX 文本校准。

### Task 3: AX 失败快照降级

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.h/.m`

**Acceptance:** AX 不可用但影子文本非空时触发本地/远程候选；候选锚点使用最近一次 AX 输入框边界或固定输入栏区域；无法确认文本时保持静默，不误插入。

### Task 4: 运行时 AX 探测

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/AccessibilityService.m`
- Test: `Tests/CodexPromptAssistantPOCTests/AccessibilitySnapshotTests.m`

**Acceptance:** 只尝试读取/设置应用 AX 属性，不调用 `NSRunningApplication terminate`、`openApplicationAtURL` 或 LaunchAgent；失败记录布尔诊断即可。

### Task 5: 回归验收

**Commands:** `make test`, `make remote-completion-test`, `make app`, `codesign --verify --deep --strict`, `git diff --check`

**Acceptance:** 正常重启 Codex 后插件不再二次启动；AX 可用和不可用两条路径均不抢焦点、不显示系统授权弹窗、不记录输入正文。
