#import <Foundation/Foundation.h>

#import "SuggestionPolicy.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSTimeInterval const CPASuggestionPollInterval;
FOUNDATION_EXPORT NSTimeInterval const CPASuggestionDebounceInterval;
FOUNDATION_EXPORT NSTimeInterval const CPALocalModelSuggestionDebounceInterval;
FOUNDATION_EXPORT NSTimeInterval const CPARemoteModelSuggestionDebounceInterval;
/// Stable pause required before resuming model work after deletion.
FOUNDATION_EXPORT NSTimeInterval const CPADeletionSuggestionDebounceInterval;
FOUNDATION_EXPORT NSTimeInterval const CPAModelSuggestionDebounceInterval;
FOUNDATION_EXPORT NSTimeInterval const CPACompositionRetryInterval;
FOUNDATION_EXPORT NSTimeInterval const CPARemoteFocusLossGraceInterval;
FOUNDATION_EXPORT NSTimeInterval const CPARemotePreparationTimeoutInterval;
FOUNDATION_EXPORT NSTimeInterval const CPARemoteRetryDelay;
FOUNDATION_EXPORT NSTimeInterval const CPAPostAcceptCooldownInterval;
FOUNDATION_EXPORT NSUInteger const CPARemoteMaximumInputCharacterCount;
FOUNDATION_EXPORT NSUInteger const CPACodexComposerTraversalMaximumDepth;
FOUNDATION_EXPORT NSTimeInterval const CPACodexFallbackLookupMinimumInterval;

/// Consecutive local-model cancellations caused by new input briefly increase
/// the quiet period before the next suggestion request. The streak expires
/// after two seconds so normal one-shot input keeps the base debounce.
FOUNDATION_EXPORT NSUInteger CPAUpdatedInputCancellationStreak(
    NSUInteger currentStreak,
    NSTimeInterval elapsedSincePreviousCancellation
);

FOUNDATION_EXPORT NSTimeInterval CPAAdaptiveSuggestionDebounceInterval(
    NSUInteger cancellationStreak,
    NSTimeInterval elapsedSinceLastCancellation
);

FOUNDATION_EXPORT BOOL CPASuggestionOutcomeAllowsInputObservation(
    CPASuggestionPolicyOutcome outcome,
    BOOL frontmostIdentityMatches
);

/// Coalesces input-event refreshes without changing the normal polling safety
/// net. A paused/disabled target never schedules work, and a pending main-loop
/// refresh absorbs later key events in the same turn.
FOUNDATION_EXPORT BOOL CPAInputEventRefreshShouldSchedule(
    BOOL inputObservationAllowed,
    BOOL suggestionsPaused,
    BOOL refreshAlreadyPending
);

FOUNDATION_EXPORT BOOL CPASnapshotCanDriveSuggestions(
    BOOL targetApplicationIsFrontmost,
    CPASuggestionPolicyOutcome outcome,
    BOOL writableTextInput,
    BOOL hasSuggestionAnchor,
    BOOL hasValueCharacterCount,
    BOOL hasSelectedRange,
    NSInteger valueCharacterCount
);

FOUNDATION_EXPORT BOOL CPAContextModeUsesCodexHistory(
    CPAContextAccessMode contextMode
);

FOUNDATION_EXPORT BOOL CPASuggestionOutcomeAllowsRemoteCompletion(
    CPASuggestionPolicyOutcome outcome
);

FOUNDATION_EXPORT BOOL CPARemoteInputIsEligible(
    NSString *inputBeforeCursor,
    NSInteger selectedLocation,
    NSInteger selectedLength
);

FOUNDATION_EXPORT BOOL CPAShouldForgetObservedInput(
    BOOL codexIsFrontmost,
    BOOL writableTextInput,
    BOOL hasValueCharacterCount,
    NSInteger valueCharacterCount
);

/// Keep an already visible candidate during a transient frontmost AX loss.
/// An explicitly empty composer, a background Codex window, or an idle state
/// must still clear immediately.
FOUNDATION_EXPORT BOOL CPAShouldRetainSuggestionDuringFocusLoss(
    BOOL codexIsFrontmost,
    BOOL definitelyEmpty,
    BOOL hasPendingSuggestion,
    BOOL hasDisplayedSuggestion
);

FOUNDATION_EXPORT BOOL CPAShouldSuppressDuringPostAcceptCooldown(
    NSTimeInterval elapsedSinceAccept
);

/// Expensive model work waits for a stable insertion. Selection changes and
/// deletion-only edits remain eligible for local history matching but do not
/// immediately launch model requests.
FOUNDATION_EXPORT BOOL CPAShouldScheduleModelSuggestions(
    BOOL inputShrank,
    NSInteger selectedLength
);

/// IME composition may temporarily replace a longer phonetic buffer with a
/// shorter committed value. That transition is not a deletion-only edit.
FOUNDATION_EXPORT BOOL CPAInputShrinkIsDeletionEdit(
    NSUInteger previousLength,
    NSUInteger currentLength,
    BOOL deletionKeyObserved
);

FOUNDATION_EXPORT BOOL CPADisplayedCandidateCanBeDismissed(
    NSString *displayedSignature,
    NSString *displayedInputText,
    NSUInteger displayedConversationGeneration,
    NSUInteger currentConversationGeneration
);

/// Returns YES only when both opaque composer identifiers are available and differ.
FOUNDATION_EXPORT BOOL CPAComposerIdentityChanged(
    NSString *previousIdentity,
    NSString *currentIdentity
);

/// Treats either a changed composer node or a changed visible selected title as
/// a conversation boundary. The title comparison covers Chromium reusing the
/// same composer node after a fast task switch.
FOUNDATION_EXPORT BOOL CPAConversationIdentityChanged(
    NSString *previousComposerIdentity,
    NSString *currentComposerIdentity,
    NSString *previousConversationTitle,
    NSString *currentConversationTitle
);

/// Recognizes the concrete class token applied by Codex to the selected sidebar row.
/// Variant tokens such as `hover:...` are intentionally insufficient.
FOUNDATION_EXPORT BOOL CPAClassTokensMarkSelectedConversation(
    NSArray<NSString *> *classTokens
);

/// Codex exposes the visible task name through the selected sidebar row's own
/// accessibility description. Descendant static text is shared UI chrome and
/// must not be used as a task identity.
FOUNDATION_EXPORT BOOL CPAAccessibilityDescriptionCanBeConversationTitle(
    NSString *description
);

/// Returns YES for accessibility roles that may represent the Codex message
/// composer. Search fields are explicitly excluded so a stale sidebar search
/// control can never replace the message composer.
FOUNDATION_EXPORT BOOL CPAAccessibilityIsCodexEmptyPlaceholder(
    NSString *value, NSInteger selectedLocation, NSInteger selectedLength);

FOUNDATION_EXPORT BOOL CPAAccessibilityRoleCanBeCodexComposer(
    NSString *role,
    NSString *subrole
);

/// Launch warm-up must yield to a real local-model request so it cannot cancel
/// the user's first suggestion.
FOUNDATION_EXPORT BOOL CPALocalModelWarmupMayStart(BOOL suggestionRequestActive);
FOUNDATION_EXPORT BOOL CPALocalModelWarmupMayStartWithPendingWork(
    BOOL suggestionRequestActive,
    BOOL suggestionWorkPending
);

/// A snapshot reaching the model scheduler has already passed the foreground,
/// policy, caret and IME gates.  When its conversation context is ready, the
/// local request can start in the same run-loop turn; loading/empty contexts
/// must continue through an asynchronous retry so we never recurse on input.
FOUNDATION_EXPORT BOOL CPALocalModelCanStartImmediately(BOOL contextReady);

/// A deep AX tree traversal is performed off the main event path. Allow only
/// one lookup at a time, retry immediately for a different process, and
/// throttle repeated attempts for the same process.
FOUNDATION_EXPORT BOOL CPACodexFallbackLookupMayStart(
    BOOL lookupInProgress,
    pid_t lastLookupProcessIdentifier,
    pid_t currentProcessIdentifier,
    NSTimeInterval elapsedSinceLastLookup
);

/// Generic AX metadata is only probed for a known preset or an explicitly
/// enabled application.  Unknown/disabled applications stay pass-through,
/// and repeated probes are throttled so the global event tap is not blocked.
FOUNDATION_EXPORT BOOL CPAGenericMetadataProbeMayStart(
    BOOL applicationIsKnown,
    BOOL applicationExplicitlyEnabled,
    BOOL applicationExplicitlyDisabled,
    BOOL probeInProgress,
    NSTimeInterval elapsedSinceLastProbe
);

/// Workspace notifications are the only hot-path-safe source for refreshing
/// the cached Codex process identity. A repeated PID must not churn state;
/// termination only clears the matching cached process.
FOUNDATION_EXPORT BOOL CPACodexProcessCacheShouldAdoptProcess(
    pid_t cachedProcessIdentifier,
    pid_t candidateProcessIdentifier
);

FOUNDATION_EXPORT BOOL CPACodexProcessCacheShouldClearForTermination(
    pid_t cachedProcessIdentifier,
    pid_t terminatedProcessIdentifier
);

NS_ASSUME_NONNULL_END

/// Only the app's own avatar overlay route may supply a floating task title.
FOUNDATION_EXPORT BOOL CPAURLIsCodexAvatarOverlay(NSString * _Nonnull url);
FOUNDATION_EXPORT NSString * _Nullable CPAConversationTitleFromOverlayCloseDescription(NSString * _Nonnull description);
