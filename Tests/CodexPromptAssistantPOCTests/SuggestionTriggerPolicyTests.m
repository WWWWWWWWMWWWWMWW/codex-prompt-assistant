#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/SuggestionPolicy.h"
#import "../../Sources/CodexPromptAssistantPOC/SuggestionTriggerPolicy.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Assert(!CPASuggestionOutcomeAllowsInputObservation(
                CPASuggestionPolicyOutcomeDisabled, YES),
            @"disabled policy must not observe or consume keyboard input");
        Assert(!CPASuggestionOutcomeAllowsInputObservation(
                CPASuggestionPolicyOutcomeLocalOnly, NO),
            @"a stale policy identity must not observe the new frontmost app");
        Assert(CPASuggestionOutcomeAllowsInputObservation(
                CPASuggestionPolicyOutcomeLocalOnly, YES),
            @"an allowed and identity-matched input may be observed");
        Assert(CPAInputEventRefreshShouldSchedule(YES, NO, NO),
            @"the first eligible input event should request an immediate refresh");
        Assert(!CPAInputEventRefreshShouldSchedule(YES, NO, YES),
            @"input events in one main-loop turn should coalesce into one refresh");
        Assert(!CPAInputEventRefreshShouldSchedule(NO, NO, NO),
            @"a policy-blocked input event must not request AX work");
        Assert(!CPAInputEventRefreshShouldSchedule(YES, YES, NO),
            @"a paused assistant must not queue a refresh");
        Assert(!CPASnapshotCanDriveSuggestions(NO,
                CPASuggestionPolicyOutcomeLocalOnly, YES, YES, YES, YES, 10),
            @"a background application must not drive candidates");
        Assert(!CPASnapshotCanDriveSuggestions(YES,
                CPASuggestionPolicyOutcomeDisabled, YES, YES, YES, YES, 10),
            @"a disabled policy must not drive candidates even with readable text");
        Assert(CPASnapshotCanDriveSuggestions(YES,
                CPASuggestionPolicyOutcomeLocalOnly, YES, YES, YES, YES, 10),
            @"an allowed complete snapshot should drive local candidates");
        Assert(CPAContextModeUsesCodexHistory(
                CPAContextAccessModeCodexConversation),
            @"Codex context mode should retain conversation history");
        Assert(!CPAContextModeUsesCodexHistory(
                CPAContextAccessModeCurrentInputOnly),
            @"ordinary applications must not inherit Codex history");
        Assert(CPASuggestionOutcomeAllowsRemoteCompletion(
                CPASuggestionPolicyOutcomeLocalAndRemote),
            @"local-and-remote policy should permit the remote quality layer");
        Assert(!CPASuggestionOutcomeAllowsRemoteCompletion(
                CPASuggestionPolicyOutcomeLocalOnly),
            @"local-only policy must suppress remote requests");

        Assert(CPALocalModelWarmupMayStart(NO),
            @"launch warm-up may run while the local model is idle");
        Assert(!CPALocalModelWarmupMayStart(YES),
            @"launch warm-up must not cancel an active user suggestion");
        Assert(CPALocalModelWarmupMayStartWithPendingWork(NO, NO),
            @"warm-up may run only while no request or suggestion is pending");
        Assert(!CPALocalModelWarmupMayStartWithPendingWork(NO, YES),
            @"warm-up must yield when a suggestion is already queued");
        Assert(!CPALocalModelWarmupMayStartWithPendingWork(YES, NO),
            @"warm-up must yield while a real request is active");
        // Once the snapshot has already passed the foreground/policy/input
        // gates, a ready conversation must start the local request directly.
        // Loading/empty context still needs an asynchronous retry so the
        // input path never recurses or spins on the main run loop.
        Assert(CPALocalModelCanStartImmediately(YES),
            @"a ready context should bypass the extra local-model timer");
        Assert(!CPALocalModelCanStartImmediately(NO),
            @"a loading or empty context must retain an asynchronous retry");
        Assert(CPASuggestionPollInterval <= 0.10,
            @"input polling should react within 100 milliseconds");
        Assert(CPASuggestionDebounceInterval <= 0.15,
            @"idle debounce should react within 150 milliseconds");
        Assert(CPAUpdatedInputCancellationStreak(0, -1.0) == 1,
            @"the first cancelled request should begin an adaptive typing streak");
        Assert(CPAUpdatedInputCancellationStreak(2, 0.40) == 3,
            @"nearby cancellations should increase the adaptive typing streak");
        Assert(CPAUpdatedInputCancellationStreak(3, 2.20) == 1,
            @"a stale cancellation must begin a fresh typing streak");
        Assert(fabs(CPAAdaptiveSuggestionDebounceInterval(0, -1.0)
                - CPASuggestionDebounceInterval) < 0.001,
            @"normal input should retain the fast base debounce");
        Assert(fabs(CPAAdaptiveSuggestionDebounceInterval(1, 0.20) - 0.28) < 0.001,
            @"one recent cancellation should modestly coalesce continued typing");
        Assert(fabs(CPAAdaptiveSuggestionDebounceInterval(2, 0.40) - 0.44) < 0.001,
            @"two nearby cancellations should wait for a clearer typing pause");
        Assert(fabs(CPAAdaptiveSuggestionDebounceInterval(8, 0.50) - 0.60) < 0.001,
            @"adaptive debounce must remain bounded at 600 milliseconds");
        Assert(fabs(CPAAdaptiveSuggestionDebounceInterval(3, 2.20)
                - CPASuggestionDebounceInterval) < 0.001,
            @"an expired typing burst should immediately return to the base delay");
        Assert(CPALocalModelSuggestionDebounceInterval >= 0.02
                && CPALocalModelSuggestionDebounceInterval <= 0.08,
            @"local model work should start promptly after the stable trigger");
        Assert(CPARemoteModelSuggestionDebounceInterval >= 0.12
                && CPARemoteModelSuggestionDebounceInterval <= 0.22
                && CPARemoteModelSuggestionDebounceInterval
                    > CPALocalModelSuggestionDebounceInterval + 0.08,
            @"remote quality work should retain a longer coalescing window");
        Assert(CPAModelSuggestionDebounceInterval >= 0.12
                && CPAModelSuggestionDebounceInterval <= 0.22
                && CPAModelSuggestionDebounceInterval
                    > CPASuggestionDebounceInterval,
            @"model work should wait for a short stable pause while local lookup stays fast");
        Assert(CPACodexFallbackLookupMayStart(NO, 42, 42, -1.0),
            @"the first Codex fallback lookup should be allowed");
        Assert(!CPACodexFallbackLookupMayStart(YES, 42, 42, 1.0),
            @"an in-flight fallback lookup must not be duplicated");
        Assert(!CPACodexFallbackLookupMayStart(NO, 42, 42, 0.10),
            @"the same Codex process must not repeat a deep lookup immediately");
        Assert(CPACodexFallbackLookupMayStart(NO, 41, 42, 0.10),
            @"a changed Codex process must be eligible for a fresh lookup");
        Assert(CPACodexFallbackLookupMayStart(NO, 42, 42, 0.60),
            @"a completed lookup may be retried after the throttle interval");
        Assert(!CPAGenericMetadataProbeMayStart(NO, NO, NO, NO, -1.0),
            @"an unknown application must stay pass-through without an explicit enable");
        Assert(CPAGenericMetadataProbeMayStart(YES, NO, NO, NO, -1.0),
            @"a known preset may perform its first metadata probe");
        Assert(CPAGenericMetadataProbeMayStart(NO, YES, NO, NO, -1.0),
            @"an explicitly enabled unknown application may perform a metadata probe");
        Assert(!CPAGenericMetadataProbeMayStart(YES, YES, YES, NO, 1.0),
            @"an explicitly disabled application must never probe metadata");
        Assert(!CPAGenericMetadataProbeMayStart(YES, NO, NO, YES, 1.0),
            @"an in-flight metadata probe must not be duplicated");
        Assert(!CPAGenericMetadataProbeMayStart(YES, NO, NO, NO, 0.10),
            @"metadata probes must be throttled between attempts");
        Assert(CPAGenericMetadataProbeMayStart(YES, NO, NO, NO, 0.30),
            @"metadata probes may resume after the throttle interval");
        Assert(CPACodexProcessCacheShouldAdoptProcess(0, 42),
            @"an initial workspace process notification should seed the cache");
        Assert(CPACodexProcessCacheShouldAdoptProcess(41, 42),
            @"a new Codex process notification should replace the cached PID");
        Assert(!CPACodexProcessCacheShouldAdoptProcess(42, 42),
            @"repeated activation for the same Codex process must not churn state");
        Assert(!CPACodexProcessCacheShouldAdoptProcess(42, 0),
            @"an invalid process identifier must never replace a valid cache");
        Assert(CPACodexProcessCacheShouldClearForTermination(42, 42),
            @"termination of the cached Codex process should clear it");
        Assert(!CPACodexProcessCacheShouldClearForTermination(42, 41),
            @"termination of another process must not clear the Codex cache");
        Assert(CPACompositionRetryInterval <= 0.15,
            @"IME completion should be rechecked promptly without a tight retry loop");
        Assert(CPARemoteFocusLossGraceInterval >= 1.0
                && CPARemoteFocusLossGraceInterval <= 2.0,
            @"remote completion should survive a short AX focus fluctuation");
        Assert(CPARemotePreparationTimeoutInterval >= 2.0
                && CPARemotePreparationTimeoutInterval <= 3.0,
            @"keychain preparation should not wait indefinitely");
        Assert(CPARemoteRetryDelay >= 0.08 && CPARemoteRetryDelay <= 0.20,
            @"remote retry should wait for a short typing pause");
        Assert(CPAPostAcceptCooldownInterval >= 0.45
                && CPAPostAcceptCooldownInterval <= 0.80,
            @"Tab accept should have a short cooldown without making later typing feel slow");
        Assert(CPAShouldSuppressDuringPostAcceptCooldown(0.20),
            @"a programmatic insertion must not immediately launch another suggestion");
        Assert(!CPAShouldSuppressDuringPostAcceptCooldown(0.80),
            @"new input after the accept cooldown must become eligible again");
        Assert(CPAShouldScheduleModelSuggestions(NO, 0),
            @"an insertion with an end caret should become model eligible");
        Assert(!CPAShouldScheduleModelSuggestions(YES, 0),
            @"a deletion-only edit should not immediately launch model work");
        Assert(!CPAShouldScheduleModelSuggestions(NO, 2),
            @"a text selection should never launch model work");
        Assert(CPAInputShrinkIsDeletionEdit(18, 12, YES),
            @"a shrink following an actual deletion key should be a deletion edit");
        Assert(!CPAInputShrinkIsDeletionEdit(18, 12, NO),
            @"an IME replacement shrink without a deletion key must stay eligible");
        Assert(!CPAInputShrinkIsDeletionEdit(12, 18, YES),
            @"an insertion must never be classified as deletion");
        Assert(CPARemoteMaximumInputCharacterCount >= 1500
                && CPARemoteMaximumInputCharacterCount <= 3000,
            @"remote completion should have a bounded input size");
        Assert(CPACodexComposerTraversalMaximumDepth >= 32,
            @"composer discovery must cover the observed Codex depth of 28");
        Assert(CPARemoteInputIsEligible(@"short prompt", 12, 0),
            @"a short end-of-input draft should be eligible for remote completion");
        Assert(!CPARemoteInputIsEligible(@"short prompt", 5, 0),
            @"a middle-cursor draft should stay local");
        NSMutableString *longInput = [NSMutableString stringWithCapacity:
            CPARemoteMaximumInputCharacterCount + 1];
        for (NSUInteger i = 0; i <= CPARemoteMaximumInputCharacterCount; i++) {
            [longInput appendString:@"x"];
        }
        Assert(!CPARemoteInputIsEligible(longInput, (NSInteger)longInput.length, 0),
            @"an oversized draft should stay local");

        Assert(!CPAShouldForgetObservedInput(NO, NO, NO, 0),
            @"switching away from Codex must preserve the observed draft");
        Assert(!CPAShouldForgetObservedInput(YES, YES, YES, 12),
            @"a nonempty Codex draft must remain observed");
        Assert(CPAShouldForgetObservedInput(YES, YES, YES, 0),
            @"an explicitly empty Codex input should reset observation");

        Assert(CPAShouldRetainSuggestionDuringFocusLoss(YES, NO, YES, NO),
            @"a pending request should survive a transient AX focus loss");
        Assert(CPAShouldRetainSuggestionDuringFocusLoss(YES, NO, NO, YES),
            @"a visible candidate should survive a transient AX focus loss");
        Assert(!CPAShouldRetainSuggestionDuringFocusLoss(YES, YES, YES, YES),
            @"an explicitly empty composer must clear immediately");
        Assert(!CPAShouldRetainSuggestionDuringFocusLoss(NO, NO, YES, YES),
            @"switching away from Codex must clear the candidate");
        Assert(!CPAShouldRetainSuggestionDuringFocusLoss(YES, NO, NO, NO),
            @"an idle state must not retain stale UI");

        Assert(CPAComposerIdentityChanged(@"320207", @"363752"),
            @"a different Codex composer node must mark a conversation boundary");
        Assert(!CPAComposerIdentityChanged(@"320207", @"320207"),
            @"a stable composer node must stay in the same conversation");
        Assert(!CPAComposerIdentityChanged(@"", @"363752")
                && !CPAComposerIdentityChanged(@"320207", @""),
            @"an unavailable node identifier must not create a false boundary");
        Assert(CPAConversationIdentityChanged(
                @"366685", @"366685", @"对话 A", @"对话 B"),
            @"a changed selected title must catch a reused composer node");
        Assert(CPAConversationIdentityChanged(
                @"320207", @"363752", @"对话 A", @"对话 A"),
            @"a changed composer node must remain a conversation boundary");
        Assert(!CPAConversationIdentityChanged(
                @"366685", @"366685", @"对话 A", @"对话 A"),
            @"stable composer and title identities must stay in one conversation");

        Assert(CPADisplayedCandidateCanBeDismissed(
                @"5:5:0", @"继续优化", 11, 11),
            @"Esc should bind to the visible candidate even if AX is transiently unavailable");
        Assert(!CPADisplayedCandidateCanBeDismissed(
                @"5:5:0", @"继续优化", 10, 11),
            @"a visible candidate from an old task generation must not dismiss the new task");
        Assert(!CPADisplayedCandidateCanBeDismissed(@"", @"", 11, 11),
            @"missing displayed state must not create a guessed dismissal");

        Assert(CPAClassTokensMarkSelectedConversation(@[
                @"sidebar-item", @"bg-primary-ghost-hover",
            ]),
            @"the concrete selected-row class should identify the visible conversation");
        Assert(!CPAClassTokensMarkSelectedConversation(@[
                @"sidebar-item", @"hover:bg-primary-ghost-hover",
                @"data-[app-action-sidebar-thread-selected=true]:bg-primary-ghost-hover",
            ]),
            @"CSS hover and data variants alone must not look selected");
        Assert(!CPAClassTokensMarkSelectedConversation(@[
                @"bg-primary-ghost-hover",
            ]),
            @"an unrelated highlighted control must not look like a conversation row");

        Assert(CPAURLIsCodexAvatarOverlay(@"app://-/index.html?initialRoute=%2Favatar-overlay"),
            @"recognize the observed floating-window route");
        Assert(!CPAURLIsCodexAvatarOverlay(@"https://example.invalid/index.html?initialRoute=%2Favatar-overlay")
            && !CPAURLIsCodexAvatarOverlay(@"app://-/index.html"),
            @"normal windows and arbitrary websites cannot use close buttons as task identities");
        Assert([CPAConversationTitleFromOverlayCloseDescription(@"关闭“当前任务”") isEqualToString:@"当前任务"],
            @"extract the floating task identity without sidebar state");
        Assert(CPAConversationTitleFromOverlayCloseDescription(@"关闭窗口") == nil
            && CPAConversationTitleFromOverlayCloseDescription(@"关闭“”") == nil,
            @"generic close labels do not identify conversations");

        Assert(CPAAccessibilityDescriptionCanBeConversationTitle(@"当前任务标题"),
            @"the selected row description should be eligible as the task title");
        Assert(!CPAAccessibilityDescriptionCanBeConversationTitle(@"  \n"),
            @"a blank row description must not become a task identity");

        Assert(CPAAccessibilityIsCodexEmptyPlaceholder(@"随心输入\n", 0, 0),
            @"Codex empty placeholder must not be treated as a five-character draft");
        Assert(!CPAAccessibilityIsCodexEmptyPlaceholder(@"随心输入", 4, 0),
            @"the same phrase typed by the author at the end remains real input");
        Assert(!CPAAccessibilityIsCodexEmptyPlaceholder(@"随心输入以下内容", 0, 0),
            @"a longer draft must not match a placeholder prefix");
        Assert(!CPAAccessibilityIsCodexEmptyPlaceholder(@"随心输入\n", 0, 4),
            @"selected author text must not become an empty composer");
        Assert(CPAAccessibilityRoleCanBeCodexComposer(@"AXTextArea", @""),
            @"the Codex ProseMirror text area must remain eligible");
        Assert(CPAAccessibilityRoleCanBeCodexComposer(@"AXTextField", @""),
            @"a generic text field may remain a future composer fallback");
        Assert(!CPAAccessibilityRoleCanBeCodexComposer(
                @"AXTextField", @"AXSearchField"),
            @"the sidebar search field must never be cached as the composer");

        NSLog(@"PASS: SuggestionTriggerPolicyTests");
    }
    return 0;
}
