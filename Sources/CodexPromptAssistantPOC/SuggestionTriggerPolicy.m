#import "SuggestionTriggerPolicy.h"

NSTimeInterval const CPASuggestionPollInterval = 0.10;
NSTimeInterval const CPASuggestionDebounceInterval = 0.12;
// The local model is already resident and has its own in-flight coalescing;
// start it shortly after the stable trigger so its first stream prefix is not
// hidden behind the remote quality-layer quiet period.
NSTimeInterval const CPALocalModelSuggestionDebounceInterval = 0.04;
// Keep a longer quiet period for the network quality layer. This avoids
// sending a remote request for every brief pause while the local fast path is
// allowed to respond promptly.
NSTimeInterval const CPARemoteModelSuggestionDebounceInterval = 0.16;
NSTimeInterval const CPADeletionSuggestionDebounceInterval = 0.65;
// Backward-compatible name used by the retry path and existing tests.
NSTimeInterval const CPAModelSuggestionDebounceInterval =
    CPARemoteModelSuggestionDebounceInterval;
NSTimeInterval const CPACompositionRetryInterval = 0.12;
NSTimeInterval const CPARemoteFocusLossGraceInterval = 1.50;
NSTimeInterval const CPARemotePreparationTimeoutInterval = 2.50;
NSTimeInterval const CPARemoteRetryDelay = 0.10;
NSTimeInterval const CPAPostAcceptCooldownInterval = 0.60;
NSUInteger const CPARemoteMaximumInputCharacterCount = 2000;
NSUInteger const CPACodexComposerTraversalMaximumDepth = 36;
NSTimeInterval const CPACodexFallbackLookupMinimumInterval = 0.50;
static const NSTimeInterval CPAGenericMetadataProbeMinimumInterval = 0.25;
static const NSTimeInterval CPAInputCancellationStreakLifetime = 2.0;
static const NSTimeInterval CPAInputCancellationDebounceStep = 0.16;
static const NSTimeInterval CPAInputCancellationMaximumDebounce = 0.60;

NSUInteger CPAUpdatedInputCancellationStreak(
    NSUInteger currentStreak,
    NSTimeInterval elapsedSincePreviousCancellation
) {
    if (elapsedSincePreviousCancellation < 0.0
        || elapsedSincePreviousCancellation > CPAInputCancellationStreakLifetime) {
        return 1;
    }
    return MIN(currentStreak + 1, (NSUInteger)3);
}

NSTimeInterval CPAAdaptiveSuggestionDebounceInterval(
    NSUInteger cancellationStreak,
    NSTimeInterval elapsedSinceLastCancellation
) {
    if (cancellationStreak == 0 || elapsedSinceLastCancellation < 0.0
        || elapsedSinceLastCancellation > CPAInputCancellationStreakLifetime) {
        return CPASuggestionDebounceInterval;
    }
    return MIN(CPASuggestionDebounceInterval
        + CPAInputCancellationDebounceStep * cancellationStreak,
        CPAInputCancellationMaximumDebounce);
}

BOOL CPASuggestionOutcomeAllowsInputObservation(
    CPASuggestionPolicyOutcome outcome,
    BOOL frontmostIdentityMatches
) {
    return outcome != CPASuggestionPolicyOutcomeDisabled
        && frontmostIdentityMatches;
}

BOOL CPAInputEventRefreshShouldSchedule(
    BOOL inputObservationAllowed,
    BOOL suggestionsPaused,
    BOOL refreshAlreadyPending
) {
    return inputObservationAllowed && !suggestionsPaused
        && !refreshAlreadyPending;
}

BOOL CPASnapshotCanDriveSuggestions(
    BOOL targetApplicationIsFrontmost,
    CPASuggestionPolicyOutcome outcome,
    BOOL writableTextInput,
    BOOL hasSuggestionAnchor,
    BOOL hasValueCharacterCount,
    BOOL hasSelectedRange,
    NSInteger valueCharacterCount
) {
    return targetApplicationIsFrontmost
        && outcome != CPASuggestionPolicyOutcomeDisabled
        && writableTextInput
        && hasSuggestionAnchor
        && hasValueCharacterCount
        && hasSelectedRange
        && valueCharacterCount > 0;
}

BOOL CPAContextModeUsesCodexHistory(CPAContextAccessMode contextMode) {
    return contextMode == CPAContextAccessModeCodexConversation;
}

BOOL CPASuggestionOutcomeAllowsRemoteCompletion(
    CPASuggestionPolicyOutcome outcome
) {
    return outcome == CPASuggestionPolicyOutcomeLocalAndRemote;
}

BOOL CPARemoteInputIsEligible(
    NSString *inputBeforeCursor,
    NSInteger selectedLocation,
    NSInteger selectedLength
) {
    if (inputBeforeCursor.length == 0 || selectedLength != 0
        || selectedLocation < 0
        || (NSUInteger)selectedLocation != inputBeforeCursor.length) {
        return NO;
    }
    return inputBeforeCursor.length <= CPARemoteMaximumInputCharacterCount;
}

BOOL CPAShouldForgetObservedInput(
    BOOL codexIsFrontmost,
    BOOL writableTextInput,
    BOOL hasValueCharacterCount,
    NSInteger valueCharacterCount
) {
    return codexIsFrontmost
        && writableTextInput
        && hasValueCharacterCount
        && valueCharacterCount == 0;
}

BOOL CPAShouldRetainSuggestionDuringFocusLoss(
    BOOL codexIsFrontmost,
    BOOL definitelyEmpty,
    BOOL hasPendingSuggestion,
    BOOL hasDisplayedSuggestion
) {
    return codexIsFrontmost && !definitelyEmpty
        && (hasPendingSuggestion || hasDisplayedSuggestion);
}

BOOL CPAShouldSuppressDuringPostAcceptCooldown(
    NSTimeInterval elapsedSinceAccept
) {
    return elapsedSinceAccept >= 0.0
        && elapsedSinceAccept < CPAPostAcceptCooldownInterval;
}

BOOL CPAShouldScheduleModelSuggestions(
    BOOL inputShrank,
    NSInteger selectedLength
) {
    return !inputShrank && selectedLength == 0;
}

BOOL CPAInputShrinkIsDeletionEdit(
    NSUInteger previousLength,
    NSUInteger currentLength,
    BOOL deletionKeyObserved
) {
    return currentLength < previousLength && deletionKeyObserved;
}

BOOL CPADisplayedCandidateCanBeDismissed(
    NSString *displayedSignature,
    NSString *displayedInputText,
    NSUInteger displayedConversationGeneration,
    NSUInteger currentConversationGeneration
) {
    return displayedSignature.length > 0 && displayedInputText.length > 0
        && displayedConversationGeneration == currentConversationGeneration;
}

BOOL CPAComposerIdentityChanged(
    NSString *previousIdentity,
    NSString *currentIdentity
) {
    return previousIdentity.length > 0 && currentIdentity.length > 0
        && ![previousIdentity isEqualToString:currentIdentity];
}

BOOL CPAConversationIdentityChanged(
    NSString *previousComposerIdentity,
    NSString *currentComposerIdentity,
    NSString *previousConversationTitle,
    NSString *currentConversationTitle
) {
    BOOL titleChanged = previousConversationTitle.length > 0
        && currentConversationTitle.length > 0
        && ![previousConversationTitle isEqualToString:currentConversationTitle];
    return CPAComposerIdentityChanged(previousComposerIdentity,
        currentComposerIdentity) || titleChanged;
}

BOOL CPAClassTokensMarkSelectedConversation(
    NSArray<NSString *> *classTokens
) {
    BOOL hasSidebarItem = NO;
    BOOL hasSelectedBackground = NO;
    for (NSUInteger i = 0, count = classTokens.count; i < count; i++) {
        NSString *token = classTokens[i];
        if ([token isEqualToString:@"sidebar-item"]) {
            hasSidebarItem = YES;
        } else if ([token isEqualToString:@"bg-primary-ghost-hover"]) {
            hasSelectedBackground = YES;
        }
    }
    return hasSidebarItem && hasSelectedBackground;
}

BOOL CPAAccessibilityDescriptionCanBeConversationTitle(
    NSString *description
) {
    NSString *normalized = [description stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return normalized.length > 0 && normalized.length <= 500;
}

BOOL CPAAccessibilityIsCodexEmptyPlaceholder(
    NSString *value, NSInteger selectedLocation, NSInteger selectedLength) {
    return selectedLocation == 0 && selectedLength == 0
        && [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            isEqualToString:@"随心输入"];
}

BOOL CPAAccessibilityRoleCanBeCodexComposer(
    NSString *role,
    NSString *subrole
) {
    if ([subrole isEqualToString:@"AXSearchField"]) {
        return NO;
    }
    return [role isEqualToString:@"AXTextArea"]
        || [role isEqualToString:@"AXTextView"]
        || [role isEqualToString:@"AXTextField"];
}

BOOL CPALocalModelWarmupMayStart(BOOL suggestionRequestActive) {
    return !suggestionRequestActive;
}

BOOL CPALocalModelWarmupMayStartWithPendingWork(
    BOOL suggestionRequestActive,
    BOOL suggestionWorkPending
) {
    return !suggestionRequestActive && !suggestionWorkPending;
}

BOOL CPALocalModelCanStartImmediately(BOOL contextReady) {
    return contextReady;
}

BOOL CPACodexFallbackLookupMayStart(
    BOOL lookupInProgress,
    pid_t lastLookupProcessIdentifier,
    pid_t currentProcessIdentifier,
    NSTimeInterval elapsedSinceLastLookup
) {
    if (lookupInProgress || currentProcessIdentifier <= 0) {
        return NO;
    }
    if (lastLookupProcessIdentifier != currentProcessIdentifier
        || elapsedSinceLastLookup < 0.0) {
        return YES;
    }
    return elapsedSinceLastLookup >= CPACodexFallbackLookupMinimumInterval;
}

BOOL CPAGenericMetadataProbeMayStart(
    BOOL applicationIsKnown,
    BOOL applicationExplicitlyEnabled,
    BOOL applicationExplicitlyDisabled,
    BOOL probeInProgress,
    NSTimeInterval elapsedSinceLastProbe
) {
    if (probeInProgress || applicationExplicitlyDisabled) {
        return NO;
    }
    if (!applicationIsKnown && !applicationExplicitlyEnabled) {
        return NO;
    }
    return elapsedSinceLastProbe < 0.0
        || elapsedSinceLastProbe >= CPAGenericMetadataProbeMinimumInterval;
}

BOOL CPACodexProcessCacheShouldAdoptProcess(
    pid_t cachedProcessIdentifier,
    pid_t candidateProcessIdentifier
) {
    return candidateProcessIdentifier > 0
        && candidateProcessIdentifier != cachedProcessIdentifier;
}

BOOL CPACodexProcessCacheShouldClearForTermination(
    pid_t cachedProcessIdentifier,
    pid_t terminatedProcessIdentifier
) {
    return cachedProcessIdentifier > 0
        && terminatedProcessIdentifier > 0
        && cachedProcessIdentifier == terminatedProcessIdentifier;
}

BOOL CPAURLIsCodexAvatarOverlay(NSString *url) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:url];
    if (![parts.scheme isEqualToString:@"app"] || ![parts.host isEqualToString:@"-"]
        || ![parts.path isEqualToString:@"/index.html"]) return NO;
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([item.name isEqualToString:@"initialRoute"]
            && [item.value isEqualToString:@"/avatar-overlay"]) return YES;
    }
    return NO;
}

NSString *CPAConversationTitleFromOverlayCloseDescription(NSString *description) {
    for (NSString *prefix in @[@"关闭“", @"Close “"]) {
        if ([description hasPrefix:prefix] && [description hasSuffix:@"”"]
            && description.length > prefix.length + 1) {
            NSString *title = [description substringWithRange:
                NSMakeRange(prefix.length, description.length - prefix.length - 1)];
            return CPAAccessibilityDescriptionCanBeConversationTitle(title) ? title : nil;
        }
    }
    return nil;
}
