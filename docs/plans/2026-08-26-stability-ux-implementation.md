# Codex Prompt Assistant Stability and UX Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make suggestion lifecycle, pause/quit cleanup, UI presentation, generation cadence, and resource usage predictable without affecting the Codex process.

**Architecture:** Keep AX as the authoritative input source and the existing window/shadow path as a conservative fallback. Add explicit displayed-candidate and application lifecycle state so Esc, Tab, pause, quit, task changes, and async callbacks all resolve against stable generations rather than a fresh transient AX read. Keep visual rendering inside the non-activating overlay and separate fast local lookup from slower model work.

**Tech Stack:** Objective-C, AppKit, ApplicationServices, Carbon CGEventTap, Foundation command-line unit tests, launchctl-managed local MLX service.

---

### Task 1: Sticky Esc and post-Tab cooldown

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.h/.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Test: `Tests/CodexPromptAssistantPOCTests/SuggestionTriggerPolicyTests.m`

1. Add failing policy tests for a displayed candidate surviving a transient unavailable AX read during Esc, and for a 600ms post-accept cooldown.
2. Run the targeted policy test and confirm failure.
3. Add displayed signature/input/generation state, capture it whenever the overlay is shown, and use that state for Esc.
4. Add an accept cooldown timestamp and suppress scheduling until a genuinely later input change.
5. Run `make test` and confirm all POC tests pass.

### Task 2: Pause/resume lifecycle

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/KeyboardInterceptor.h/.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Tests/CodexPromptAssistantPOCTests/ApplicationMenuTests.m`
- Test: `Tests/CodexPromptAssistantPOCTests/KeyboardShadowBufferTests.m`

1. Add failing tests that the status menu exposes `暂停提示` and that keyboard interception has an idempotent stop path.
2. Add `stop` to the event tap wrapper; invalidate and release its source/tap without relying on `dealloc`.
3. Add `suggestionsPaused`, a status menu toggle, and one cleanup method that hides overlay, cancels model work/timers, pauses scanning, and stops the event tap.
4. Resume by restarting the event tap, poll timer, context provider, and scan without activating Codex.
5. Verify pause/resume logs contain only state and counts.

### Task 3: Full quit and local model ownership

**Files:**
- Create: `Sources/CodexPromptAssistantPOC/LocalModelServiceController.h/.m`
- Create: `Tests/CodexPromptAssistantPOCTests/LocalModelServiceControllerTests.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Makefile`

1. Add failing pure tests for exact `launchctl bootstrap`, `kickstart`, and `bootout` argument construction using the current user UID and fixed service label; assert no Codex bundle/process appears in any command.
2. Implement a small controller around `/bin/launchctl`, with no shell interpolation and count-only diagnostics.
3. On helper launch, ensure the owned local model service is available; on helper termination, perform lifecycle cleanup and boot out only `local.codex.prompt-assistant-model`.
4. Add the new test target to `make test`.
5. Real-verify that helper quit removes helper/model PIDs while Codex PID is unchanged, then reopen the helper and confirm the model returns.

### Task 4: Stable low-interference overlay

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/OverlayController.h/.m`
- Test: `Tests/CodexPromptAssistantPOCTests/OverlayControllerTests.m`

1. Add failing tests for fixed bar width across multiple streamed text lengths, non-activating behavior, compact spacing, and full hide cleanup.
2. Split suggestion and shortcut labels, keep the panel frame stable for the same input anchor, and truncate long suggestions to one line.
3. Add a short initial alpha transition only when hidden-to-visible; streamed updates do not animate size or position.
4. Verify the overlay never becomes key/main and `hide` leaves no visible window.

### Task 5: Model cadence and quality gates

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.h/.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m`
- Modify: `Sources/RemoteCompletionCore/RemoteCompletionProtocol.m`
- Test: `Tests/CodexPromptAssistantPOCTests/SuggestionTriggerPolicyTests.m`
- Test: `Tests/RemoteCompletionCoreTests/RemoteCompletionProtocolTests.m`

1. Add failing tests for fast local lookup, delayed local-model start, later remote start, deletion/selection suppression, duplicate insertion rejection, and bounded output length.
2. Introduce separate timers/generations for local-model and remote-model work; cancel them on every input/task/lifecycle change.
3. Normalize whitespace and reject repeated input tails, boilerplate, overlong completions, and semantically empty results without logging text.
4. Verify rapid edits create one model start per stable draft rather than one per 120ms pause.

### Task 6: Regression, resources, and live acceptance

**Files:**
- Modify: `HANDOFF.md`

1. Run `make test`, `make remote-completion-test`, `make -B app`, signing verification, and `git diff --check`.
2. Sample helper/model CPU and RSS repeatedly in running, paused, and quit states; measure active log growth for at least one summary interval.
3. Real-test Chinese and English input, Esc, Tab, task switch, app switch, pause/resume, and quit/reopen without submitting test drafts.
4. Confirm Codex PID/start time remains unchanged and no helper panel, focus, event tap, timer, or model process remains after full quit.
5. Update the handoff with separate `已验证` / `未验证` entries and no input/model text or credentials.
