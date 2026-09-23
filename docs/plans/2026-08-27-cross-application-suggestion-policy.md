# Cross-Application Suggestion Policy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a secure, explainable, maintainable policy layer that decides whether and how the assistant may offer completions in Codex, WorkBuddy, Lark, WeChat, and browser form scenarios.

**Architecture:** Introduce a pure local `SuggestionPolicyEngine` between frontmost input discovery and all text/model work. It evaluates hard-sensitive guards, user overrides, application presets, scene confidence, generation mode, and context mode; application-specific adapters remain isolated behind the policy boundary.

**Tech Stack:** Objective-C, Foundation, AppKit Accessibility, Carbon keyboard event tap, `NSUserDefaults`, AppKit menus/windows, Makefile-based test executables.

---

> This repository contains a large existing dirty workspace that must be preserved. Do not reset, checkout, clean, create a detached worktree that omits the current changes, or commit without explicit user authorization.

### Task 1: Pure policy decision core

**Files:**
- Create: `Sources/CodexPromptAssistantPOC/SuggestionPolicy.h`
- Create: `Sources/CodexPromptAssistantPOC/SuggestionPolicy.m`
- Create: `Tests/CodexPromptAssistantPOCTests/SuggestionPolicyTests.m`
- Modify: `Makefile`

**Steps:**

1. Write failing tests for global pause, hard-sensitive fields, search protection, explicit disable, explicit ordinary-input enable, application presets, unknown applications, remote authorization, and context isolation.
2. Run `make test` and verify the new target fails because the policy types are missing.
3. Implement immutable input/rule/decision objects and a deterministic policy engine. The decision must include outcome, context mode, reason code, and user-facing status without including field text.
4. Run `make test`; expect all policy and existing tests to pass.

### Task 2: Persisted application and site rules

**Files:**
- Create: `Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.h`
- Create: `Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.m`
- Create: `Tests/CodexPromptAssistantPOCTests/SuggestionPolicyStoreTests.m`
- Modify: `Makefile`

**Steps:**

1. Write failing tests for application three-state mode, search exception, remote authorization, normalized browser host allow/deny, schema versioning, corrupt-value fallback, and non-overridable hard guards.
2. Run the targeted test and verify failure.
3. Store only bundle IDs, normalized hosts, enum values, and booleans in `NSUserDefaults`; never store field labels, page paths, titles, or input text.
4. Run the targeted test and full `make test`.

### Task 3: Generic safe input context collection

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.h`
- Modify: `Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.m`
- Refactor: `Sources/CodexPromptAssistantPOC/AccessibilityService.h`
- Refactor: `Sources/CodexPromptAssistantPOC/AccessibilityService.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/AccessibilitySnapshotTests.m`
- Create: `Tests/CodexPromptAssistantPOCTests/InputSceneClassifierTests.m`

**Steps:**

1. Write failing tests proving secure/search/login/OTP/payment decisions can be made before `AXValue` is read.
2. Add frontmost bundle ID, application name, role/subrole, protected-input evidence, browser class, scene, and confidence to the metadata snapshot.
3. Split metadata inspection from text inspection. Only a policy-allowed metadata snapshot may proceed to value/range/frame collection.
4. Keep Codex `-25212` fallback and existing conversation discovery inside the Codex adapter.
5. Run all tests and verify diagnostics still contain counts and roles but no sensitive labels or text.

### Task 4: Application adapters and generation boundaries

**Files:**
- Create: `Sources/CodexPromptAssistantPOC/ApplicationAdapter.h`
- Create: `Sources/CodexPromptAssistantPOC/CodexApplicationAdapter.m`
- Create: `Sources/CodexPromptAssistantPOC/GenericApplicationAdapter.m`
- Create: `Sources/CodexPromptAssistantPOC/BrowserApplicationAdapter.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Sources/CodexPromptAssistantPOC/KeyboardInterceptor.h`
- Modify: `Sources/CodexPromptAssistantPOC/KeyboardInterceptor.m`

**Steps:**

1. Write failing tests that switching bundle, PID, window, site, field identity, or policy version cancels candidates and invalidates requests.
2. Move Codex-only title/context/window-bottom behavior behind `CodexApplicationAdapter` without changing current Codex behavior.
3. Make the keyboard interceptor consult the current policy decision before maintaining shadow text or consuming Tab/Esc.
4. Ensure disabled and hard-protected contexts do zero value reads, zero model requests, and immediately pass through all keys.
5. Run regression tests and real Codex input acceptance before enabling another adapter.

### Task 5: Lightweight settings and status feedback

**Files:**
- Create: `Sources/CodexPromptAssistantPOC/SuggestionPolicySettingsController.h`
- Create: `Sources/CodexPromptAssistantPOC/SuggestionPolicySettingsController.m`
- Modify: `Sources/CodexPromptAssistantPOC/ApplicationMenu.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/ApplicationMenuTests.m`

**Steps:**

1. Write failing tests for current status reason, pause 30 minutes, enable/disable current application or site, and settings entry points.
2. Add the normal three-state application control: Recommended, Enable Ordinary Inputs, Off.
3. Put site lists, scene overrides, search exceptions, remote authorization, and history-learning authorization in an advanced disclosure area.
4. Add concise menu states such as `Lark · Search · Protected`; provide one-click temporary pause and current-app actions.
5. Verify the panel never activates or steals focus when a suggestion appears or disappears.

### Task 6: Preset adapters in evidence-first order

**Files:**
- Create/modify adapter files under `Sources/CodexPromptAssistantPOC/`
- Add focused tests under `Tests/CodexPromptAssistantPOCTests/`

**Steps:**

1. Capture metadata-only AX evidence for WorkBuddy, Lark, WeChat, Safari, and Chrome; do not log input text, labels, titles, contacts, or full URLs.
2. Add WorkBuddy primary-editor preset and complete local-only UI acceptance.
3. Add Lark document/comment preset; keep chat off until separately verified.
4. Keep WeChat off by default; verify explicit local-only enable and sensitive-field protections.
5. Add browser host allowlist using normalized host only; unknown host and private browsing remain off.
6. Do not enable an adapter whose ordinary and protected scenarios have not both been tested.

### Task 7: Performance, privacy, and full acceptance matrix

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/Diagnostics.m`
- Modify: `HANDOFF.md`
- Add focused test fixtures only where they contain no real user text.

**Steps:**

1. Cache decisions by PID, window/field identity, browser host token, and rule version; invalidate on any boundary.
2. Move disabled applications to event-driven or low-frequency metadata checks; prohibit deep AX traversal outside an enabled adapter.
3. Measure helper CPU, RSS, model RSS, decision latency, and log growth across idle, enabled typing, disabled app, and hard-protected field scenarios.
4. Search logs for forbidden categories and verify no input/model body, API key, field label, contact, title, full URL, or site path is present.
5. Run `make test`, `make remote-completion-test`, `make -B app`, `codesign --verify --deep --strict --verbose=2 build/CodexPromptAssistantPOC.app`, and `git diff --check`.
6. Reload only the helper, confirm Codex PID continuity, and execute the real UI matrix. Report each item as verified or unverified.
