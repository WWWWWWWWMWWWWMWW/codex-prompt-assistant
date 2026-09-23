# Prompt Assistant Self-Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep the prompt assistant available after a normal Codex restart or an assistant crash, while preserving an intentional user quit and never controlling the Codex process.

**Architecture:** A user LaunchAgent supervises only the installed prompt-assistant app and restarts it only after abnormal exit, with a 30-second throttle. Inside the app, Codex launch notifications and a new status-menu action share one bounded recovery routine that rebuilds cached process identity, AX snapshots, input interception, context selection, and polling without quitting, launching, or activating Codex.

**Tech Stack:** Objective-C/AppKit, NSWorkspace notifications, launchd property lists, Make, Foundation regression tests.

---

### Task 1: Specify recovery safety contracts

**Files:**
- Create: `Resources/local.codex.prompt-assistant-app.plist`
- Create: `Tests/CodexPromptAssistantPOCTests/ApplicationRecoveryTests.m`
- Modify: `Makefile`

**Step 1: Write the failing test**

Validate that the LaunchAgent uses label `local.codex.prompt-assistant-app`, launches only the installed assistant, sets `RunAtLoad`, uses `KeepAlive.SuccessfulExit = false`, and throttles relaunches for 30 seconds. Validate that no argument references the ChatGPT executable or Codex bundle identifier.

Validate that the status menu exposes `恢复提示服务` and that Codex launch handling invokes the same recovery routine without process launch or termination APIs.

**Step 2: Run the test to verify it fails**

Run: `make -B application-recovery-test`

Expected: FAIL because the recovery plist, menu item, and shared recovery method do not exist.

### Task 2: Implement in-process recovery

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Test: `Tests/CodexPromptAssistantPOCTests/ApplicationRecoveryTests.m`

**Step 1: Add one shared recovery routine**

The routine must cancel stale suggestion work, invalidate cached AX/context/process identity, rebuild the keyboard event tap and poll timer, and request a fresh snapshot. Manual recovery may resume a paused assistant; automatic Codex-launch recovery must respect an intentional pause.

**Step 2: Wire automatic and manual triggers**

Invoke the routine after adopting a newly launched Codex PID. Add a top-level status-menu item titled `恢复提示服务` that invokes the same routine with the manual-resume option.

**Step 3: Run the targeted test**

Run: `make -B application-recovery-test`

Expected: PASS.

### Task 3: Add assistant-only launchd supervision

**Files:**
- Create: `Resources/local.codex.prompt-assistant-app.plist`
- Modify: `Makefile`

**Step 1: Add installation targets**

Build and copy the signed app to `~/Applications/CodexPromptAssistantPOC.app`, install the LaunchAgent under `~/Library/LaunchAgents`, and provide start/stop/status targets. Starting the service must not invoke, terminate, or modify Codex.

**Step 2: Validate and install**

Run `plutil -lint`, build the app, stop the existing manually launched helper, bootstrap the LaunchAgent, and confirm a single helper process is owned by launchd.

**Step 3: Test abnormal and successful exit behavior**

Terminate the helper abnormally and confirm it returns after the throttle without changing the Codex or local-model PID. Then use the app's normal termination path or `launchctl bootout` during maintenance and confirm no duplicate helper remains.

### Task 4: Full verification and delivery

**Files:**
- Modify only files listed above.

**Step 1: Run regression suites**

Run: `make -B test && make -B remote-completion-test && make -B app`

Expected: all tests PASS; the app builds and passes strict code-sign verification.

**Step 2: Verify the live recovery path**

Confirm the helper is running from the installed path, the LaunchAgent reports active state, and diagnostics record automatic or manual recovery without input text. Confirm Codex and the local model retain their original PIDs.

**Step 3: Commit**

Commit the design, plist, Makefile, implementation, and tests in one scoped Git commit. Do not push.
