# Safe Global Input Suggestions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让提示助手在普通 macOS 输入框中默认提供本地提示，并为浏览器、终端、代码编辑器和搜索框提供安全的手动开启入口。

**Architecture:** 由策略层统一判断应用默认风险、输入场景和用户规则；Accessibility 层只采集元数据并把浏览器 URL 立即缩减为主机名；运行层在策略允许后读取当前输入正文；状态栏菜单写入按应用或按站点规则并触发即时复检。

**Tech Stack:** Objective-C、AppKit、macOS Accessibility API、NSUserDefaults、Make、LaunchAgent

---

### Task 1: 固化新的默认应用策略

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/SuggestionPolicy.h`
- Modify: `Sources/CodexPromptAssistantPOC/SuggestionPolicy.m`
- Test: `Tests/CodexPromptAssistantPOCTests/SuggestionPolicyTests.m`

1. 写入普通未知应用推荐模式下本地启用的失败测试。
2. 写入浏览器、终端、代码编辑器和系统安全应用默认关闭的失败测试。
3. 实现可复用的应用类别与推荐策略函数。
4. 运行 `make test` 中的策略测试并提交。

### Task 2: 扩大安全元数据探测范围

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/SuggestionPolicyCoordinator.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/SuggestionPolicyCoordinatorTests.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/SafeInputContextCollectorTests.m`

1. 写入普通应用推荐模式允许元数据探测、风险应用保持静默的失败测试。
2. 写入普通输入允许正文读取、敏感输入零正文读取的回归测试。
3. 让普通应用在推荐模式下允许普通文本角色推断。
4. 运行协调器与安全采集测试并提交。

### Task 3: 识别浏览器精确站点

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/GenericAccessibilityService.m`
- Test: `Tests/CodexPromptAssistantPOCTests/GenericAccessibilityServiceTests.m`
- Modify: `Makefile`

1. 抽取可测试的 URL 到主机名归一化逻辑。
2. 写入 HTTP、HTTPS、无效 URL 和非网页文档的测试。
3. 从聚焦元素祖先的 `AXURL`/`AXDocument` 读取 URL，只保留归一化主机名。
4. 确认完整 URL 不进入快照、设置和日志。

### Task 4: 增加当前应用与站点控制菜单

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Sources/CodexPromptAssistantPOC/ApplicationMenu.h`
- Modify: `Sources/CodexPromptAssistantPOC/ApplicationMenu.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/ApplicationMenuTests.m`

1. 写入菜单标题、三态规则和站点作用域的测试。
2. 添加“当前应用”状态、推荐、启用普通输入、关闭与搜索例外菜单项。
3. 浏览器仅在识别到当前主机名时写入站点规则。
4. 规则变更后清空旧提示并立即复检当前输入。

### Task 5: 回归验证与安装

**Files:**
- Verify: `Sources/CodexPromptAssistantPOC/*.m`
- Verify: `Tests/CodexPromptAssistantPOCTests/*.m`

1. 运行 `make test`。
2. 运行 `make app` 并验证 codesign。
3. 检查已安装 LaunchAgent、助手 PID 和本地模型 PID，记录基线。
4. 安装并只重载提示助手，确认 PID 更新且 Codex PID 未变化。
5. 在无发送型普通编辑器输入框验证提示显示、Tab 接受与菜单即时开关。
6. 在安全输入框验证无提示；无法安全实测的应用明确列为未验证。

### Task 6: 提交与交付

**Files:**
- Review: `git diff --check`
- Review: `git status --short`

1. 复核改动不包含正文、URL、凭据或无关文件。
2. 提交功能实现与验证记录，不推送远端。
3. 交付提交号、已验证范围、负责人/待验证项和可复现步骤。
