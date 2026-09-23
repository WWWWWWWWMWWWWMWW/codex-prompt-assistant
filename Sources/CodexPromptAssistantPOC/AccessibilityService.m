#import "AccessibilityService.h"
#import "InputElementIdentity.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <errno.h>
#import <signal.h>

#import "AccessibilitySnapshot.h"
#import "Diagnostics.h"
#import "SuggestionTriggerPolicy.h"
#import "SuggestionPolicyCoordinator.h"

static NSString *const CPACodexBundleIdentifier = @"com.openai.codex";
static const NSUInteger CPAFallbackMaxNodes = 2500;
static const NSUInteger CPAConversationScanMaxDepth = 32;
static const NSUInteger CPAConversationScanMaxNodes = 6000;
// AX trees exposed by Chromium can be several thousand nodes deep. When a
// selected-row element is temporarily unavailable, do not repeat the same
// expensive traversal on every 100ms input poll.
static const NSTimeInterval CPAConversationScanMinimumInterval = 0.35;
// Chromium may briefly hide the selected sidebar row while rebuilding AX.
// Keep a confirmed title only for this short grace window.
static const NSTimeInterval CPAConversationTitleGraceInterval = 1.5;

static BOOL CPAProcessIdentifierIsAlive(pid_t processIdentifier) {
    if (processIdentifier <= 0) {
        return NO;
    }
    if (kill(processIdentifier, 0) == 0) {
        return YES;
    }
    return errno == EPERM;
}

static BOOL CPAIsComposerRole(NSString *role, NSString *subrole) {
    return CPAAccessibilityRoleCanBeCodexComposer(role ?: @"", subrole ?: @"");
}

static BOOL CPAIsCodexEmptyComposerValue(NSString *value) {
    NSString *normalized = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([normalized isEqualToString:@"使用 ChatGPT Work"]
        || [normalized isEqualToString:@"Use ChatGPT Work"]
        || [normalized isEqualToString:@"使用 ChatGPT"]
        || [normalized isEqualToString:@"Use ChatGPT"]) {
        return YES;
    }
    return [normalized hasPrefix:@"使用 ChatGPT "]
        && normalized.length <= 64;
}

@interface CPAAccessibilityService ()
@property(nonatomic, strong) CPAInputElementIdentity *inputIdentity;
@property(nonatomic, strong) CPAInputElementIdentity *selectionIdentity;
@property(atomic, readwrite) NSUInteger inputReadingGeneration;
@property(nonatomic) AXUIElementRef lastTextInputElement;
@property(nonatomic) AXUIElementRef selectedConversationElement;
@property(nonatomic, strong) id conversationWindow;
@property(nonatomic) BOOL selectedConversationIsOverlay;
@property(nonatomic) pid_t lastTextInputProcessIdentifier;
@property(nonatomic, copy, nullable) NSString *lastComposerIdentifier;
@property(nonatomic) NSUInteger unavailableComposerReadCount;
@property(nonatomic) BOOL runtimeAccessibilityAttempted;
@property(nonatomic, copy, nullable) NSString *cachedConversationTitle;
@property(nonatomic, strong, nullable) NSDate *cachedConversationTitleDate;
@property(nonatomic, strong, nullable) NSDate *conversationScanDate;
@property(nonatomic) pid_t conversationScanProcessIdentifier;
@property(nonatomic) BOOL conversationScanInProgress;
@property(nonatomic) NSUInteger lastConversationScanVisitedNodes;
@property(nonatomic) NSUInteger lastConversationScanDurationMilliseconds;
@property(nonatomic, strong) dispatch_queue_t fallbackLookupQueue;
@property(nonatomic) BOOL fallbackLookupInProgress;
@property(nonatomic) pid_t fallbackLookupProcessIdentifier;
@property(nonatomic) pid_t lastFallbackLookupProcessIdentifier;
@property(nonatomic, strong, nullable) NSDate *lastFallbackLookupDate;
@property(nonatomic) AXUIElementRef completedFallbackTextInputElement;
@property(nonatomic) pid_t completedFallbackProcessIdentifier;
@property(nonatomic) NSUInteger fallbackLookupGeneration;
- (NSRunningApplication *)currentCodexApplication;
- (void)rememberTextInput:(AXUIElementRef)element processIdentifier:(pid_t)processIdentifier;
- (AXUIElementRef)copyLastKnownTextInputForProcess:(pid_t)processIdentifier;
- (AXUIElementRef)copyBottomTextInputForApplication:(pid_t)processIdentifier;
- (void)findBottomTextInputInElement:(AXUIElementRef)element
                         windowFrame:(CGRect)windowFrame
                              depth:(NSUInteger)depth
                            visited:(NSUInteger *)visited
                               best:(AXUIElementRef *)best
                              score:(CGFloat *)bestScore;
- (AXUIElementRef)copyTextInputAtBottomOfWindow:(AXUIElementRef)applicationElement
                                    windowFrame:(CGRect)windowFrame;
- (BOOL)pointAttribute:(CFStringRef)attribute
               element:(AXUIElementRef)element
                output:(CGPoint *)output;
- (BOOL)sizeAttribute:(CFStringRef)attribute
              element:(AXUIElementRef)element
               output:(CGSize *)output;
- (nullable NSString *)stringAttribute:(CFStringRef)attribute
                               element:(AXUIElementRef)element;
- (nullable NSString *)scalarStringAttribute:(CFStringRef)attribute
                                      element:(AXUIElementRef)element;
- (nullable NSArray<NSString *> *)stringArrayAttribute:(CFStringRef)attribute
                                                element:(AXUIElementRef)element;
- (nullable NSString *)selectedConversationTitleForProcess:(pid_t)processIdentifier window:(AXUIElementRef)window;
- (nullable NSString *)conversationTitleFromElement:(AXUIElementRef)element;
- (nullable NSString *)freshCachedConversationTitle;
- (void)findSelectedConversationInElement:(AXUIElementRef)element
                                     depth:(NSUInteger)depth
                                   visited:(NSUInteger *)visited
                                    result:(AXUIElementRef *)result;
- (void)forgetSelectedConversationElement;
- (void)invalidateConversationScanCache;
- (void)scheduleBottomTextInputLookupForProcess:(pid_t)processIdentifier;
- (AXUIElementRef)takeCompletedFallbackTextInputForProcess:(pid_t)processIdentifier;
- (void)invalidateFallbackLookupState;
@end

@implementation CPAAccessibilityService
@synthesize inputReadingPaused = _inputReadingPaused;

- (void)setInputReadingPaused:(BOOL)paused {
    @synchronized (self) {
        if (_inputReadingPaused != paused) {
            _inputReadingPaused = paused;
            self.inputReadingGeneration += 1;
        }
    }
}

- (BOOL)inputReadingPaused {
    @synchronized (self) { return _inputReadingPaused; }
}

- (pid_t)observedFrontmostProcessIdentifier {
    return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
}

- (BOOL)elementIsCurrentlyFocused:(AXUIElementRef)element processIdentifier:(pid_t)pid {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    CFTypeRef current = NULL;
    AXError error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute, &current);
    CFRelease(system);
    if (error != kAXErrorSuccess || current == NULL) {
        if (current != NULL) CFRelease(current);
        current = NULL;
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &current);
        CFRelease(app);
    }
    BOOL matches = error == kAXErrorSuccess && current != NULL
        && CFGetTypeID(current) == AXUIElementGetTypeID() && CFEqual(current, element);
    if (current != NULL) CFRelease(current);
    return matches;
}

- (CPASuggestionDecision *)readDecisionForRole:(NSString *)role
    subrole:(NSString *)subrole metadata:(NSArray<NSString *> *)metadata {
    return [self.policyCoordinator decisionForBundleIdentifier:CPACodexBundleIdentifier
        role:role ?: @"" subrole:subrole ?: @"" semanticMetadata:metadata
        browserHost:@"" globallyPaused:self.inputReadingPaused temporarilyPaused:NO];
}

// Only metadata is fetched here. A real, currently focused composer must be
// identified; a remembered or geometrically plausible input is not permission.
- (BOOL)authorizeElement:(AXUIElementRef)element
    processIdentifier:(pid_t)processIdentifier snapshot:(CPAAccessibilitySnapshot *)snapshot {
    pid_t owner = 0;
    BOOL identityMatches = AXUIElementGetPid(element, &owner) == kAXErrorSuccess
        && owner == processIdentifier
        && [self observedFrontmostProcessIdentifier] == processIdentifier
        && [self elementIsCurrentlyFocused:element processIdentifier:processIdentifier];
    NSString *role = identityMatches
        ? [self stringAttribute:kAXRoleAttribute element:element] : @"";
    NSString *subrole = identityMatches
        ? [self stringAttribute:kAXSubroleAttribute element:element] : @"";
    NSMutableArray<NSString *> *metadata = [NSMutableArray array];
    if (identityMatches) {
        for (NSString *attribute in @[@"AXPlaceholderValue", @"AXDescription", @"AXIdentifier", @"AXHelp"]) {
            NSString *value = [self stringAttribute:(__bridge CFStringRef)attribute element:element];
            if (value.length > 0) [metadata addObject:value];
        }
    }
    NSUInteger version = self.policyCoordinator.ruleVersion;
    CPASuggestionDecision *decision = [self readDecisionForRole:role subrole:subrole metadata:metadata];
    if (!identityMatches || !CPAIsComposerRole(role, subrole)
        || snapshot.inputReadingGeneration != self.inputReadingGeneration
        || version != self.policyCoordinator.ruleVersion) {
        // Keep sensitive/search reasons when possible, otherwise fail closed.
        if (decision == nil || decision.outcome != CPASuggestionPolicyOutcomeDisabled) {
            decision = [self readDecisionForRole:@"" subrole:@"" metadata:@[]];
        }
    }
    snapshot.codexInputDecision = decision;
    snapshot.policyRuleVersion = version;
    snapshot.focusedRole = role;
    snapshot.focusedSubrole = subrole;
    BOOL allowed = identityMatches && CPAIsComposerRole(role, subrole)
        && decision != nil && decision.outcome != CPASuggestionPolicyOutcomeDisabled
        && snapshot.inputReadingGeneration == self.inputReadingGeneration
        && version == self.policyCoordinator.ruleVersion;
    if (!allowed) snapshot.diagnostic = @"codex_read_denied";
    return allowed;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _fallbackLookupQueue = dispatch_queue_create(
            "local.codex.prompt-assistant.ax-fallback", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_lastTextInputElement != NULL) {
        CFRelease(_lastTextInputElement);
    }
    if (_selectedConversationElement != NULL) {
        CFRelease(_selectedConversationElement);
    }
    if (_completedFallbackTextInputElement != NULL) {
        CFRelease(_completedFallbackTextInputElement);
    }
}

- (BOOL)isTrustedWithPrompt:(BOOL)prompt {
    NSDictionary *options = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt),
    };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (CPAAccessibilitySnapshot *)inspectFocusedElement {
    NSRunningApplication *codexApplication = [self currentCodexApplication];
    pid_t processIdentifier = codexApplication != nil
        ? codexApplication.processIdentifier : 0;
    NSRunningApplication *frontmostApplication = NSWorkspace.sharedWorkspace
        .frontmostApplication;
    pid_t frontmostProcessIdentifier = frontmostApplication != nil
        ? frontmostApplication.processIdentifier : 0;
    return [self inspectFocusedElementForCodexProcessIdentifier:processIdentifier
        frontmostProcessIdentifier:frontmostProcessIdentifier];
}

- (CPAAccessibilitySnapshot *)
    inspectFocusedElementForCodexProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier {
    CFAbsoluteTime inspectionStartedAt = CFAbsoluteTimeGetCurrent();
    CPAAccessibilitySnapshot *snapshot = [[CPAAccessibilitySnapshot alloc] init];
    snapshot.permissionGranted = [self isTrustedWithPrompt:NO];

    snapshot.codexIsRunning = CPAProcessIdentifierIsAlive(processIdentifier);
    snapshot.codexIsFrontmost = snapshot.codexIsRunning
        && frontmostProcessIdentifier == processIdentifier;
    snapshot.targetApplicationIsFrontmost = snapshot.codexIsFrontmost;
    snapshot.targetBundleIdentifier = CPACodexBundleIdentifier;
    snapshot.targetProcessIdentifier = processIdentifier;

    if (!snapshot.permissionGranted || !snapshot.codexIsRunning || !snapshot.codexIsFrontmost) {
        snapshot.diagnostic = @"precondition_failed";
        return snapshot;
    }

    snapshot.inputReadingGeneration = self.inputReadingGeneration;
    // Application/global switch preflight is deny-only, never field authorization.
    NSUInteger preflightVersion = self.policyCoordinator.ruleVersion;
    CPASuggestionDecision *preflight = [self readDecisionForRole:@"AXTextArea"
        subrole:@"" metadata:@[]];
    if (preflight == nil || preflight.outcome == CPASuggestionPolicyOutcomeDisabled
        || [self observedFrontmostProcessIdentifier] != processIdentifier) {
        snapshot.codexInputDecision = preflight.outcome == CPASuggestionPolicyOutcomeDisabled
            ? preflight : [self readDecisionForRole:@"" subrole:@"" metadata:@[]];
        snapshot.policyRuleVersion = preflightVersion;
        snapshot.diagnostic = @"codex_read_preflight_denied";
        return snapshot;
    }

    if (self.lastTextInputProcessIdentifier != processIdentifier) {
        if (self.lastTextInputElement != NULL) {
            CFRelease(self.lastTextInputElement);
            self.lastTextInputElement = NULL;
        }
        [self forgetSelectedConversationElement];
        [self invalidateConversationScanCache];
        self.lastComposerIdentifier = nil;
        self.runtimeAccessibilityAttempted = NO;
        [self invalidateFallbackLookupState];
    }
    self.lastTextInputProcessIdentifier = processIdentifier;

    AXUIElementRef systemWideElement = AXUIElementCreateSystemWide();
    CFTypeRef focusedValue = NULL;
    AXError focusedError = AXUIElementCopyAttributeValue(
        systemWideElement,
        kAXFocusedUIElementAttribute,
        &focusedValue
    );
    CFRelease(systemWideElement);

    NSString *focusSource = @"system";
    if (focusedError != kAXErrorSuccess || focusedValue == NULL
        || CFGetTypeID(focusedValue) != AXUIElementGetTypeID()) {
        if (focusedValue != NULL) {
            CFRelease(focusedValue);
            focusedValue = NULL;
        }
        AXUIElementRef applicationElement = AXUIElementCreateApplication(
            processIdentifier);
        focusedError = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute,
            &focusedValue
        );
        CFRelease(applicationElement);
        focusSource = @"application";
    }

    AXUIElementRef focusedElement = NULL;
    if (focusedError == kAXErrorSuccess && focusedValue != NULL
        && CFGetTypeID(focusedValue) == AXUIElementGetTypeID()) {
        focusedElement = (AXUIElementRef)focusedValue;
    } else {
        if (focusedValue != NULL) {
            CFRelease(focusedValue);
        }
        focusedValue = NULL;
        // Metadata recovery can prepare a later poll, but cannot establish
        // the focused field or authorize reading a previous composer.
        [self scheduleBottomTextInputLookupForProcess:processIdentifier];
        self.unavailableComposerReadCount += 1;
        snapshot.rendererAccessibilitySuspected = self.unavailableComposerReadCount >= 3;
        snapshot.diagnostic = @"focused_element_unavailable fallback_lookup=metadata_only";
        return snapshot;
    }
    if (![self authorizeElement:focusedElement processIdentifier:processIdentifier snapshot:snapshot]) {
        CFRelease(focusedElement);
        return snapshot;
    }
    self.unavailableComposerReadCount = 0;
    NSString *composerIdentifier = [self scalarStringAttribute:CFSTR("ChromeAXNodeId")
        element:focusedElement];
    if (CPAComposerIdentityChanged(self.lastComposerIdentifier ?: @"",
            composerIdentifier ?: @"")) {
        // Chromium can keep returning a retained sidebar AX node briefly after
        // navigation. A new composer node is the strongest switch signal we
        // have, so force a fresh selected-row scan before resolving the title.
        [self forgetSelectedConversationElement];
        [self invalidateConversationScanCache];
    }
    if (composerIdentifier.length > 0) {
        self.lastComposerIdentifier = [composerIdentifier copy];
    }
    snapshot.composerIdentifier = composerIdentifier;
    CFTypeRef composerWindow = NULL;
    AXUIElementCopyAttributeValue(focusedElement, kAXWindowAttribute, &composerWindow);
    if (composerWindow != NULL && CFGetTypeID(composerWindow) != AXUIElementGetTypeID()) {
        CFRelease(composerWindow); composerWindow = NULL;
    }
    if (self.inputIdentity == nil) self.inputIdentity = [CPAInputElementIdentity new];
    snapshot.targetFieldIdentity = [self.inputIdentity tokenForElement:(__bridge id)focusedElement
        window:(__bridge id)composerWindow rendererIdentifier:composerIdentifier ?: @""];
    snapshot.conversationTitle = [self selectedConversationTitleForProcess:
        processIdentifier window:(AXUIElementRef)composerWindow];
    snapshot.conversationSelectionIdentity = [self liveConversationSelectionIdentityForWindow:(AXUIElementRef)composerWindow];
    if (composerWindow != NULL) CFRelease(composerWindow);
    NSUInteger conversationScanDurationMilliseconds =
        self.lastConversationScanDurationMilliseconds;
    NSUInteger conversationScanVisitedNodes = self.lastConversationScanVisitedNodes;

    CGPoint elementPosition = CGPointZero;
    CGSize elementSize = CGSizeZero;
    BOOL hasPosition = [self pointAttribute:kAXPositionAttribute
        element:focusedElement
        output:&elementPosition];
    BOOL hasSize = [self sizeAttribute:kAXSizeAttribute
        element:focusedElement
        output:&elementSize];
    if (hasPosition && hasSize && elementSize.width > 0.0 && elementSize.height > 0.0) {
        snapshot.hasElementFrame = YES;
        snapshot.elementFrame = CGRectMake(
            elementPosition.x,
            elementPosition.y,
            elementSize.width,
            elementSize.height
        );
    }

    // Metadata/title traversal can be slow. Recheck current policy and owner
    // immediately before the only body read in this service.
    if (![self authorizeElement:focusedElement processIdentifier:processIdentifier snapshot:snapshot]) {
        snapshot.conversationTitle = nil;
        snapshot.conversationSelectionIdentity = nil;
        CFRelease(focusedElement);
        return snapshot;
    }
    NSString *value = [self stringAttribute:kAXValueAttribute element:focusedElement];
    NSString *placeholder = [self stringAttribute:kAXPlaceholderValueAttribute
        element:focusedElement];
    BOOL valueIsPlaceholder = (value.length > 0 && placeholder.length > 0
        && [value isEqualToString:placeholder])
        || CPAIsCodexEmptyComposerValue(value);
    if (valueIsPlaceholder) {
        value = @"";
    }
    if (value != nil) {
        snapshot.inputText = value;
        snapshot.hasValueCharacterCount = YES;
        snapshot.valueCharacterCount = value.length;
    }

    CFTypeRef selectedRangeValue = NULL;
    AXError rangeError = AXUIElementCopyAttributeValue(
        focusedElement,
        kAXSelectedTextRangeAttribute,
        &selectedRangeValue
    );
    if (rangeError == kAXErrorSuccess && selectedRangeValue != NULL
        && CFGetTypeID(selectedRangeValue) == AXValueGetTypeID()
        && AXValueGetType((AXValueRef)selectedRangeValue) == kAXValueCFRangeType) {
        CFRange selectedRange = CFRangeMake(0, 0);
        if (AXValueGetValue((AXValueRef)selectedRangeValue, kAXValueCFRangeType, &selectedRange)) {
            snapshot.hasSelectedRange = YES;
            snapshot.selectedLocation = selectedRange.location;
            snapshot.selectedLength = selectedRange.length;
        }

        CFTypeRef boundsValue = NULL;
        AXError boundsError = AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute,
            selectedRangeValue,
            &boundsValue
        );
        if (boundsError == kAXErrorSuccess && boundsValue != NULL
            && CFGetTypeID(boundsValue) == AXValueGetTypeID()
            && AXValueGetType((AXValueRef)boundsValue) == kAXValueCGRectType) {
            CGRect caretBounds = CGRectZero;
            if (AXValueGetValue((AXValueRef)boundsValue, kAXValueCGRectType, &caretBounds)
                && [CPAAccessibilitySnapshot isUsableCaretBounds:caretBounds]) {
                snapshot.hasCaretBounds = YES;
                snapshot.caretBounds = caretBounds;
            }
        }
        if (boundsValue != NULL) {
            CFRelease(boundsValue);
        }
    }
    if (selectedRangeValue != NULL) {
        CFRelease(selectedRangeValue);
    }

    NSInteger reportedSelectedLocation = snapshot.selectedLocation;
    // Recent Codex builds expose their empty-composer label as AXValue without
    // AXPlaceholderValue. Recognize it before the end-of-value range fallback.
    if (snapshot.hasSelectedRange && CPAAccessibilityIsCodexEmptyPlaceholder(
            value, snapshot.selectedLocation, snapshot.selectedLength)) {
        valueIsPlaceholder = YES;
        snapshot.inputText = @"";
        snapshot.valueCharacterCount = 0;
    }
    if (snapshot.hasSelectedRange && snapshot.hasValueCharacterCount) {
        snapshot.selectedLocation = [CPAAccessibilitySnapshot
            effectiveSelectedLocationForReportedLocation:snapshot.selectedLocation
            selectedLength:snapshot.selectedLength
            valueLength:snapshot.valueCharacterCount
            hasUsableCaretBounds:snapshot.hasCaretBounds];
    }
    BOOL usedEndRangeFallback = snapshot.hasSelectedRange
        && snapshot.selectedLocation != reportedSelectedLocation;

    Boolean valueSettable = false;
    AXError settableError = AXUIElementIsAttributeSettable(
        focusedElement,
        kAXValueAttribute,
        &valueSettable
    );
    BOOL isTextRole = CPAIsComposerRole(snapshot.focusedRole, snapshot.focusedSubrole);
    snapshot.writableTextInput = isTextRole
        && ((settableError == kAXErrorSuccess && valueSettable) || snapshot.hasSelectedRange);
    if (snapshot.writableTextInput) {
        [self rememberTextInput:focusedElement
            processIdentifier:processIdentifier];
    }

    NSString *rangeText = snapshot.hasSelectedRange
        ? [NSString stringWithFormat:@"%ld:%ld%@",
            (long)snapshot.selectedLocation,
            (long)snapshot.selectedLength,
            usedEndRangeFallback ? @"(end_fallback)" : @""]
        : @"nil";
    NSString *lengthText = snapshot.hasValueCharacterCount
        ? [NSString stringWithFormat:@"%ld", (long)snapshot.valueCharacterCount]
        : @"nil";
    NSString *boundsText = snapshot.hasCaretBounds
        ? NSStringFromRect(NSRectFromCGRect(snapshot.caretBounds))
        : @"nil";
    NSString *elementFrameText = snapshot.hasElementFrame
        ? NSStringFromRect(NSRectFromCGRect(snapshot.elementFrame))
        : @"nil";
    NSUInteger inspectionDurationMilliseconds = (NSUInteger)llround(
        (CFAbsoluteTimeGetCurrent() - inspectionStartedAt) * 1000.0);
    snapshot.diagnostic = [NSString stringWithFormat:
        @"focusSource=%@, role=%@, subrole=%@, range=%@, bounds=%@, elementFrame=%@, valueLength=%@, valueSettable=%@, placeholder=%@, conversationScanMs=%lu, conversationScanNodes=%lu, inspectMs=%lu",
        focusSource,
        snapshot.focusedRole ?: @"nil",
        snapshot.focusedSubrole ?: @"nil",
        rangeText,
        boundsText,
        elementFrameText,
        lengthText,
        valueSettable ? @"true" : @"false",
        valueIsPlaceholder ? @"true" : @"false",
        (unsigned long)conversationScanDurationMilliseconds,
        (unsigned long)conversationScanVisitedNodes,
        (unsigned long)inspectionDurationMilliseconds];

    CFRelease(focusedElement);
    return snapshot;
}

- (BOOL)focusLastKnownTextInput {
    NSRunningApplication *codexApplication = [self currentCodexApplication];
    pid_t processIdentifier = codexApplication != nil
        ? codexApplication.processIdentifier : 0;
    NSRunningApplication *frontmostApplication = NSWorkspace.sharedWorkspace
        .frontmostApplication;
    pid_t frontmostProcessIdentifier = frontmostApplication != nil
        ? frontmostApplication.processIdentifier : 0;
    return [self focusLastKnownTextInputForProcessIdentifier:processIdentifier
        frontmostProcessIdentifier:frontmostProcessIdentifier];
}

- (BOOL)focusLastKnownTextInputForProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier {
    if (processIdentifier <= 0 || frontmostProcessIdentifier != processIdentifier
        || !CPAProcessIdentifierIsAlive(processIdentifier)) {
        return NO;
    }
    if (self.lastTextInputElement == NULL) {
        [self refreshCurrentCodexTextInputForProcessIdentifier:processIdentifier
            frontmostProcessIdentifier:frontmostProcessIdentifier];
    }
    if (self.lastTextInputElement == NULL
        || self.lastTextInputProcessIdentifier != processIdentifier) {
        return NO;
    }
    AXError error = AXUIElementSetAttributeValue(
        self.lastTextInputElement,
        kAXFocusedAttribute,
        kCFBooleanTrue
    );
    return error == kAXErrorSuccess;
}

- (BOOL)refreshCurrentCodexTextInput {
    NSRunningApplication *codexApplication = [self currentCodexApplication];
    pid_t processIdentifier = codexApplication != nil
        ? codexApplication.processIdentifier : 0;
    NSRunningApplication *frontmostApplication = NSWorkspace.sharedWorkspace
        .frontmostApplication;
    pid_t frontmostProcessIdentifier = frontmostApplication != nil
        ? frontmostApplication.processIdentifier : 0;
    return [self refreshCurrentCodexTextInputForProcessIdentifier:processIdentifier
        frontmostProcessIdentifier:frontmostProcessIdentifier];
}

- (BOOL)refreshCurrentCodexTextInputForProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier {
    CPASuggestionDecision *preflight = [self readDecisionForRole:@"AXTextArea" subrole:@"" metadata:@[]];
    if (preflight == nil || preflight.outcome == CPASuggestionPolicyOutcomeDisabled
        || [self observedFrontmostProcessIdentifier] != processIdentifier) return NO;
    if (![self isTrustedWithPrompt:NO]) {
        return NO;
    }
    if (processIdentifier <= 0 || frontmostProcessIdentifier != processIdentifier
        || !CPAProcessIdentifierIsAlive(processIdentifier)) {
        return NO;
    }
    if (self.lastTextInputProcessIdentifier != processIdentifier) {
        if (self.lastTextInputElement != NULL) {
            CFRelease(self.lastTextInputElement);
            self.lastTextInputElement = NULL;
        }
        [self forgetSelectedConversationElement];
        [self invalidateConversationScanCache];
        self.lastComposerIdentifier = nil;
        [self invalidateFallbackLookupState];
    }
    self.lastTextInputProcessIdentifier = processIdentifier;
    AXUIElementRef element = [self takeCompletedFallbackTextInputForProcess:
        processIdentifier];
    if (element == NULL) {
        [self scheduleBottomTextInputLookupForProcess:processIdentifier];
        return NO;
    }
    [self rememberTextInput:element processIdentifier:processIdentifier];
    CFRelease(element);
    return YES;
}

- (BOOL)tryEnableRuntimeAccessibility {
    NSRunningApplication *codexApplication = [self currentCodexApplication];
    pid_t processIdentifier = codexApplication != nil
        ? codexApplication.processIdentifier : 0;
    return [self tryEnableRuntimeAccessibilityForProcessIdentifier:processIdentifier];
}

- (BOOL)tryEnableRuntimeAccessibilityForProcessIdentifier:(pid_t)processIdentifier {
    if (self.runtimeAccessibilityAttempted || ![self isTrustedWithPrompt:NO]) {
        return NO;
    }
    self.runtimeAccessibilityAttempted = YES;
    if (processIdentifier <= 0 || !CPAProcessIdentifierIsAlive(processIdentifier)) {
        return NO;
    }
    AXUIElementRef applicationElement = AXUIElementCreateApplication(
        processIdentifier);
    if (applicationElement == NULL) {
        return NO;
    }
    AXError error = AXUIElementSetAttributeValue(
        applicationElement,
        CFSTR("AXEnhancedUserInterface"),
        kCFBooleanTrue
    );
    CFRelease(applicationElement);
    CPADiagnosticLog(@"runtime_ax_enhancement attempted=true success=%@ error=%d",
        error == kAXErrorSuccess ? @"true" : @"false",
        (int)error);
    return error == kAXErrorSuccess;
}

- (BOOL)currentCodexFallbackInputFrame:(CGRect *)inputFrame {
    NSRunningApplication *codexApplication = [self currentCodexApplication];
    pid_t processIdentifier = codexApplication != nil
        ? codexApplication.processIdentifier : 0;
    NSRunningApplication *frontmostApplication = NSWorkspace.sharedWorkspace
        .frontmostApplication;
    pid_t frontmostProcessIdentifier = frontmostApplication != nil
        ? frontmostApplication.processIdentifier : 0;
    return [self currentCodexFallbackInputFrame:inputFrame
        forProcessIdentifier:processIdentifier
        frontmostProcessIdentifier:frontmostProcessIdentifier];
}

- (BOOL)currentCodexFallbackInputFrame:(CGRect *)inputFrame
    forProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier {
    if (inputFrame == NULL) {
        return NO;
    }
    *inputFrame = CGRectZero;
    if (processIdentifier <= 0 || frontmostProcessIdentifier != processIdentifier
        || !CPAProcessIdentifierIsAlive(processIdentifier)) {
        return NO;
    }

    CFArrayRef windowInfoRef = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID
    );
    if (windowInfoRef == NULL) {
        return NO;
    }
    NSArray *windowInfo = CFBridgingRelease(windowInfoRef);
    CGRect bestWindowFrame = CGRectZero;
    CGFloat bestArea = 0.0;
    for (NSUInteger index = 0, count = windowInfo.count; index < count; index++) {
        NSDictionary *item = windowInfo[index];
        NSNumber *ownerPID = item[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *layer = item[(__bridge NSString *)kCGWindowLayer];
        NSNumber *alpha = item[(__bridge NSString *)kCGWindowAlpha];
        NSDictionary *boundsDictionary = item[(__bridge NSString *)kCGWindowBounds];
        if (ownerPID.intValue != processIdentifier
            || layer.integerValue != 0 || alpha.doubleValue <= 0.0
            || boundsDictionary == nil) {
            continue;
        }
        CGRect frame = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)boundsDictionary, &frame)
            || frame.size.width < 320.0 || frame.size.height < 240.0) {
            continue;
        }
        CGFloat area = frame.size.width * frame.size.height;
        if (area > bestArea) {
            bestArea = area;
            bestWindowFrame = frame;
        }
    }
    if (bestArea <= 0.0) {
        return NO;
    }
    CGRect fallbackFrame = [CPAAccessibilitySnapshot
        conservativeInputFrameForWindowFrame:bestWindowFrame];
    if (![CPAAccessibilitySnapshot isUsableCaretBounds:fallbackFrame]) {
        return NO;
    }
    *inputFrame = fallbackFrame;
    return YES;
}

- (NSRunningApplication *)currentCodexApplication {
    NSArray<NSRunningApplication *> *applications =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:CPACodexBundleIdentifier];
    for (NSUInteger i = 0, count = applications.count; i < count; i++) {
        NSRunningApplication *application = applications[i];
        if (!application.terminated) {
            return application;
        }
    }
    return nil;
}

- (void)invalidateFallbackLookupState {
    @synchronized (self) {
        self.fallbackLookupGeneration++;
        self.fallbackLookupInProgress = NO;
        self.fallbackLookupProcessIdentifier = 0;
        self.lastFallbackLookupProcessIdentifier = 0;
        self.lastFallbackLookupDate = nil;
        self.completedFallbackProcessIdentifier = 0;
        if (self.completedFallbackTextInputElement != NULL) {
            CFRelease(self.completedFallbackTextInputElement);
            self.completedFallbackTextInputElement = NULL;
        }
    }
}

- (AXUIElementRef)takeCompletedFallbackTextInputForProcess:
    (pid_t)processIdentifier {
    if (processIdentifier <= 0) {
        return NULL;
    }
    AXUIElementRef element = NULL;
    @synchronized (self) {
        if (self.completedFallbackProcessIdentifier == processIdentifier
            && self.completedFallbackTextInputElement != NULL) {
            element = self.completedFallbackTextInputElement;
            self.completedFallbackTextInputElement = NULL;
            self.completedFallbackProcessIdentifier = 0;
        }
    }
    return element;
}

- (void)scheduleBottomTextInputLookupForProcess:(pid_t)processIdentifier {
    if (processIdentifier <= 0) {
        return;
    }
    NSDate *now = [NSDate date];
    NSUInteger generation = 0;
    @synchronized (self) {
        NSTimeInterval elapsed = self.lastFallbackLookupDate == nil
            ? -1.0 : -[self.lastFallbackLookupDate timeIntervalSinceNow];
        if (!CPACodexFallbackLookupMayStart(
                self.fallbackLookupInProgress,
                self.lastFallbackLookupProcessIdentifier,
                processIdentifier,
                elapsed)) {
            return;
        }
        self.fallbackLookupInProgress = YES;
        self.fallbackLookupProcessIdentifier = processIdentifier;
        self.lastFallbackLookupProcessIdentifier = processIdentifier;
        self.lastFallbackLookupDate = now;
        generation = ++self.fallbackLookupGeneration;
    }
    CPADiagnosticLog(@"ax fallback_lookup scheduled=true");
    __weak CPAAccessibilityService *weakSelf = self;
    dispatch_async(self.fallbackLookupQueue, ^{
        CPAAccessibilityService *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // This call may wait on a Chromium AX server. It deliberately runs on
        // a private serial queue so the main run loop and global event tap stay
        // responsive while the fallback tree is inspected.
        AXUIElementRef element = [strongSelf
            copyBottomTextInputForApplication:processIdentifier];
        BOOL found = element != NULL;
        @synchronized (strongSelf) {
            BOOL current = generation == strongSelf.fallbackLookupGeneration
                && strongSelf.fallbackLookupProcessIdentifier == processIdentifier;
            if (current) {
                strongSelf.fallbackLookupInProgress = NO;
                strongSelf.fallbackLookupProcessIdentifier = 0;
                if (strongSelf.completedFallbackTextInputElement != NULL) {
                    CFRelease(strongSelf.completedFallbackTextInputElement);
                }
                strongSelf.completedFallbackTextInputElement = element;
                strongSelf.completedFallbackProcessIdentifier =
                    element != NULL ? processIdentifier : 0;
                element = NULL;
            }
        }
        if (element != NULL) {
            CFRelease(element);
        }
        CPADiagnosticLog(@"ax fallback_lookup finished=true found=%@",
            found ? @"true" : @"false");
    });
}

- (void)rememberTextInput:(AXUIElementRef)element
    processIdentifier:(pid_t)processIdentifier {
    if (element == NULL) {
        return;
    }
    if (self.lastTextInputElement != NULL) {
        CFRelease(self.lastTextInputElement);
    }
    self.lastTextInputElement = (AXUIElementRef)CFRetain(element);
    self.lastTextInputProcessIdentifier = processIdentifier;
}

- (AXUIElementRef)copyLastKnownTextInputForProcess:(pid_t)processIdentifier {
    if (self.lastTextInputElement == NULL
        || self.lastTextInputProcessIdentifier != processIdentifier) {
        return NULL;
    }
    return (AXUIElementRef)CFRetain(self.lastTextInputElement);
}

- (AXUIElementRef)copyBottomTextInputForApplication:(pid_t)processIdentifier {
    AXUIElementRef applicationElement = AXUIElementCreateApplication(processIdentifier);
    if (applicationElement == NULL) {
        return NULL;
    }

    CFTypeRef windowsValue = NULL;
    AXError windowsError = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXWindowsAttribute,
        &windowsValue
    );
    if (windowsError != kAXErrorSuccess || windowsValue == NULL
        || CFGetTypeID(windowsValue) != CFArrayGetTypeID()) {
        if (windowsValue != NULL) {
            CFRelease(windowsValue);
        }
        CFRelease(applicationElement);
        return NULL;
    }

    NSArray *windows = (__bridge NSArray *)windowsValue;
    AXUIElementRef bestElement = NULL;
    CGFloat bestScore = -CGFLOAT_MAX;
    NSUInteger visitedNodes = 0;
    for (NSUInteger i = 0, len = windows.count; i < len; i++) {
        id windowObject = windows[i];
        if (CFGetTypeID((__bridge CFTypeRef)windowObject) != AXUIElementGetTypeID()) {
            continue;
        }
        AXUIElementRef windowElement = (__bridge AXUIElementRef)windowObject;
        CGPoint position = CGPointZero;
        CGSize size = CGSizeZero;
        if (![self pointAttribute:kAXPositionAttribute element:windowElement output:&position]
            || ![self sizeAttribute:kAXSizeAttribute element:windowElement output:&size]
            || size.width <= 0.0 || size.height <= 0.0) {
            continue;
        }
        CGRect windowFrame = CGRectMake(position.x, position.y, size.width, size.height);
        AXUIElementRef pointElement = [self copyTextInputAtBottomOfWindow:applicationElement
                                                               windowFrame:windowFrame];
        if (pointElement != NULL) {
            if (bestElement != NULL) {
                CFRelease(bestElement);
            }
            bestElement = pointElement;
            bestScore = CGFLOAT_MAX;
            break;
        }
        [self findBottomTextInputInElement:windowElement
                               windowFrame:windowFrame
                                    depth:0
                                   visited:&visitedNodes
                                     best:&bestElement
                                    score:&bestScore];
        if (visitedNodes >= CPAFallbackMaxNodes) {
            break;
        }
    }
    CFRelease(windowsValue);
    CFRelease(applicationElement);
    return bestElement;
}

- (AXUIElementRef)copyTextInputAtBottomOfWindow:(AXUIElementRef)applicationElement
                                    windowFrame:(CGRect)windowFrame {
    CGFloat centerX = CGRectGetMidX(windowFrame);
    CGFloat maxY = CGRectGetMaxY(windowFrame);
    const CGFloat offsets[] = { 24.0, 48.0, 72.0, 100.0, 140.0 };
    for (NSUInteger i = 0, len = sizeof(offsets) / sizeof(offsets[0]); i < len; i++) {
        CGFloat y = maxY - offsets[i];
        if (y < CGRectGetMinY(windowFrame)) {
            continue;
        }
        AXUIElementRef hitElement = NULL;
        AXError hitError = AXUIElementCopyElementAtPosition(
            applicationElement, (float)centerX, (float)y, &hitElement);
        if (hitError != kAXErrorSuccess || hitElement == NULL) {
            if (hitElement != NULL) {
                CFRelease(hitElement);
            }
            continue;
        }
        NSString *role = [self stringAttribute:kAXRoleAttribute element:hitElement];
        NSString *subrole = [self stringAttribute:kAXSubroleAttribute
            element:hitElement];
        if (CPAIsComposerRole(role, subrole)) {
            CFTypeRef rangeValue = NULL;
            AXError rangeError = AXUIElementCopyAttributeValue(
                hitElement, kAXSelectedTextRangeAttribute, &rangeValue);
            BOOL hasRange = rangeError == kAXErrorSuccess && rangeValue != NULL
                && CFGetTypeID(rangeValue) == AXValueGetTypeID();
            if (rangeValue != NULL) {
                CFRelease(rangeValue);
            }
            Boolean settable = false;
            AXError settableError = AXUIElementIsAttributeSettable(
                hitElement, kAXValueAttribute, &settable);
            BOOL writable = (settableError == kAXErrorSuccess && settable) || hasRange;
            if (writable) {
                return hitElement;
            }
        }
        CFRelease(hitElement);
    }
    return NULL;
}

- (void)findBottomTextInputInElement:(AXUIElementRef)element
                         windowFrame:(CGRect)windowFrame
                              depth:(NSUInteger)depth
                            visited:(NSUInteger *)visited
                               best:(AXUIElementRef *)best
                              score:(CGFloat *)bestScore {
    if (element == NULL || depth > CPACodexComposerTraversalMaximumDepth
        || *visited >= CPAFallbackMaxNodes) {
        return;
    }
    *visited += 1;

    NSString *role = [self stringAttribute:kAXRoleAttribute element:element];
    if ([role isEqualToString:(__bridge NSString *)kAXTextAreaRole]
        || [role isEqualToString:@"AXTextView"]) {
        CGPoint position = CGPointZero;
        CGSize size = CGSizeZero;
        BOOL hasFrame = [self pointAttribute:kAXPositionAttribute
            element:element output:&position]
            && [self sizeAttribute:kAXSizeAttribute element:element output:&size];
        if (hasFrame && size.width >= 280.0 && size.height > 0.0) {
            CGRect frame = CGRectMake(position.x, position.y, size.width, size.height);
            CGFloat bottomDistance = CGRectGetMaxY(windowFrame) - CGRectGetMaxY(frame);
            CFTypeRef rangeValue = NULL;
            AXError rangeError = AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute, &rangeValue);
            BOOL hasRange = rangeError == kAXErrorSuccess && rangeValue != NULL
                && CFGetTypeID(rangeValue) == AXValueGetTypeID()
                && AXValueGetType((AXValueRef)rangeValue) == kAXValueCFRangeType;
            if (rangeValue != NULL) {
                CFRelease(rangeValue);
            }
            Boolean settable = false;
            AXError settableError = AXUIElementIsAttributeSettable(
                element, kAXValueAttribute, &settable);
            BOOL writable = (settableError == kAXErrorSuccess && settable) || hasRange;
            if (writable && bottomDistance >= -20.0 && bottomDistance <= 260.0) {
                CGFloat score = size.width * 0.01 - MAX(bottomDistance, 0.0) * 2.0;
                if (*best == NULL || score > *bestScore) {
                    if (*best != NULL) {
                        CFRelease(*best);
                    }
                    *best = (AXUIElementRef)CFRetain(element);
                    *bestScore = score;
                }
            }
        }
    }

    CFTypeRef childrenValue = NULL;
    AXError childrenError = AXUIElementCopyAttributeValue(
        element, kAXChildrenAttribute, &childrenValue);
    if (childrenError != kAXErrorSuccess || childrenValue == NULL
        || CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        if (childrenValue != NULL) {
            CFRelease(childrenValue);
        }
        return;
    }
    NSArray *children = (__bridge NSArray *)childrenValue;
    for (NSUInteger i = 0, len = children.count; i < len; i++) {
        id childObject = children[i];
        if (CFGetTypeID((__bridge CFTypeRef)childObject) != AXUIElementGetTypeID()) {
            continue;
        }
        [self findBottomTextInputInElement:(__bridge AXUIElementRef)childObject
                               windowFrame:windowFrame
                                    depth:depth + 1
                                   visited:visited
                                     best:best
                                    score:bestScore];
        if (*visited >= CPAFallbackMaxNodes) {
            break;
        }
    }
    CFRelease(childrenValue);
}

- (BOOL)pointAttribute:(CFStringRef)attribute
               element:(AXUIElementRef)element
                output:(CGPoint *)output {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL
        || CFGetTypeID(value) != AXValueGetTypeID()
        || AXValueGetType((AXValueRef)value) != kAXValueCGPointType) {
        if (value != NULL) {
            CFRelease(value);
        }
        return NO;
    }
    BOOL success = AXValueGetValue((AXValueRef)value, kAXValueCGPointType, output);
    CFRelease(value);
    return success;
}

- (BOOL)sizeAttribute:(CFStringRef)attribute
              element:(AXUIElementRef)element
               output:(CGSize *)output {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL
        || CFGetTypeID(value) != AXValueGetTypeID()
        || AXValueGetType((AXValueRef)value) != kAXValueCGSizeType) {
        if (value != NULL) {
            CFRelease(value);
        }
        return NO;
    }
    BOOL success = AXValueGetValue((AXValueRef)value, kAXValueCGSizeType, output);
    CFRelease(value);
    return success;
}

- (nullable NSString *)stringAttribute:(CFStringRef)attribute
                                element:(AXUIElementRef)element {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL) {
        return nil;
    }

    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value copy];
    }
    CFRelease(value);
    return result;
}

- (nullable NSString *)scalarStringAttribute:(CFStringRef)attribute
                                      element:(AXUIElementRef)element {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL) {
        if (value != NULL) {
            CFRelease(value);
        }
        return nil;
    }
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value copy];
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        result = [[(__bridge NSNumber *)value stringValue] copy];
    }
    CFRelease(value);
    return result;
}

- (nullable NSArray<NSString *> *)stringArrayAttribute:(CFStringRef)attribute
                                                element:(AXUIElementRef)element {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL
        || CFGetTypeID(value) != CFArrayGetTypeID()) {
        if (value != NULL) {
            CFRelease(value);
        }
        return nil;
    }
    NSArray *values = (__bridge NSArray *)value;
    NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:values.count];
    for (NSUInteger i = 0, count = values.count; i < count; i++) {
        id candidate = values[i];
        if ([candidate isKindOfClass:NSString.class]) {
            [strings addObject:candidate];
        }
    }
    CFRelease(value);
    return [strings copy];
}

- (nullable NSString *)selectedConversationTitleForProcess:(pid_t)processIdentifier window:(AXUIElementRef)window {
    if (window == NULL || CFGetTypeID(window) != AXUIElementGetTypeID()) {
        [self forgetSelectedConversationElement];
        [self invalidateConversationScanCache];
        self.conversationWindow = nil;
        return nil;
    }
    if (![self.conversationWindow isEqual:(__bridge id)window]) {
        [self forgetSelectedConversationElement];
        [self invalidateConversationScanCache];
        self.conversationWindow = (__bridge id)window;
    }
    if (self.selectedConversationElement != NULL) {
        NSArray<NSString *> *classTokens = [self stringArrayAttribute:
            CFSTR("AXDOMClassList") element:self.selectedConversationElement];
        if (self.selectedConversationIsOverlay || CPAClassTokensMarkSelectedConversation(classTokens ?: @[])) {
            NSString *title = [self conversationTitleFromElement:
                self.selectedConversationElement];
            if (title.length > 0) {
                self.cachedConversationTitle = title;
                self.cachedConversationTitleDate = NSDate.date;
                return title;
            }
        }
        [self forgetSelectedConversationElement];
    }

    NSDate *now = [NSDate date];
    @synchronized (self) {
        if (self.conversationScanInProgress) {
            return [self freshCachedConversationTitle];
        }
        if (self.conversationScanDate != nil
            && self.conversationScanProcessIdentifier == processIdentifier
            && -[self.conversationScanDate timeIntervalSinceNow]
                < CPAConversationScanMinimumInterval) {
            return [self freshCachedConversationTitle];
        }
        self.conversationScanInProgress = YES;
        self.conversationScanDate = now;
        self.conversationScanProcessIdentifier = processIdentifier;
    }

    CFAbsoluteTime scanStartedAt = CFAbsoluteTimeGetCurrent();
    NSUInteger visited = 0;
    @try {
        AXUIElementRef selectedElement = NULL;
        [self findSelectedConversationInElement:window
            depth:0 visited:&visited result:&selectedElement];
        if (selectedElement == NULL) {
            return nil;
        }
        self.selectedConversationElement = (AXUIElementRef)CFRetain(selectedElement);
        NSString *title = [self conversationTitleFromElement:selectedElement];
        CFRelease(selectedElement);
        if (title.length == 0) {
            [self forgetSelectedConversationElement];
            return nil;
        }
        self.cachedConversationTitle = title;
        self.cachedConversationTitleDate = NSDate.date;
        return title;
    } @finally {
        NSUInteger durationMilliseconds = (NSUInteger)llround(
            (CFAbsoluteTimeGetCurrent() - scanStartedAt) * 1000.0);
        @synchronized (self) {
            self.conversationScanInProgress = NO;
            self.lastConversationScanVisitedNodes = visited;
            self.lastConversationScanDurationMilliseconds = durationMilliseconds;
        }
    }
}

// Never use the title grace cache as evidence of selection. An overlay close
// button also does not establish a task-row identity, so it cannot reuse an ID.
- (nullable NSString *)liveConversationSelectionIdentityForWindow:(AXUIElementRef)window {
    AXUIElementRef row = self.selectedConversationElement;
    if (window == NULL || row == NULL || self.selectedConversationIsOverlay
        || ![self.conversationWindow isEqual:(__bridge id)window]) {
        self.selectionIdentity = nil; return nil;
    }
    NSArray *classes = [self stringArrayAttribute:CFSTR("AXDOMClassList") element:row];
    NSString *node = [self scalarStringAttribute:CFSTR("ChromeAXNodeId") element:row];
    NSString *title = [self conversationTitleFromElement:row];
    if (!CPAClassTokensMarkSelectedConversation(classes ?: @[]) || !node.length || !title.length) {
        self.selectionIdentity = nil; return nil;
    }
    // Include metadata that changes when a virtualized row is rebound, even
    // when its AX object and renderer node are reused. No draft or history here.
    NSString *dom = [self scalarStringAttribute:CFSTR("AXIdentifier") element:row] ?: @"";
    NSString *url = [self stringAttribute:kAXURLAttribute element:row] ?: @"";
    NSString *identity = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:
        @[node, title, dom, url] options:0 error:nil] encoding:NSUTF8StringEncoding];
    if (!CPAClassTokensMarkSelectedConversation([self stringArrayAttribute:CFSTR("AXDOMClassList") element:row] ?: @[])) {
        self.selectionIdentity = nil; return nil;
    }
    if (!self.selectionIdentity) self.selectionIdentity = [CPAInputElementIdentity new];
    return [self.selectionIdentity tokenForElement:(__bridge id)row window:(__bridge id)window rendererIdentifier:identity];
}

- (nullable NSString *)conversationTitleFromElement:(AXUIElementRef)element {
    NSString *description = [self stringAttribute:kAXDescriptionAttribute
        element:element];
    if (self.selectedConversationIsOverlay) {
        return CPAConversationTitleFromOverlayCloseDescription(description ?: @"");
    }
    if (!CPAAccessibilityDescriptionCanBeConversationTitle(description ?: @"")) {
        return nil;
    }
    return [description stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)findSelectedConversationInElement:(AXUIElementRef)element
                                     depth:(NSUInteger)depth
                                   visited:(NSUInteger *)visited
                                    result:(AXUIElementRef *)result {
    if (element == NULL || *result != NULL || depth > CPAConversationScanMaxDepth
        || *visited >= CPAConversationScanMaxNodes) {
        return;
    }
    *visited += 1;
    NSString *role = [self stringAttribute:kAXRoleAttribute element:element];
    if ([role isEqualToString:@"AXWebArea"]) {
        CFTypeRef urlValue = NULL;
        AXUIElementCopyAttributeValue(element, kAXURLAttribute, &urlValue);
        NSString *url = [(__bridge id)urlValue description];
        BOOL overlay = CPAURLIsCodexAvatarOverlay(url ?: @"");
        if (urlValue != NULL) CFRelease(urlValue);
        if (overlay) {
            NSMutableArray *matches = [NSMutableArray array];
            [self collectOverlayTitleElements:element depth:depth visited:visited matches:matches];
            // Multiple floating cards are ambiguous; never pick the first one.
            if (matches.count == 1) {
                self.selectedConversationIsOverlay = YES;
                *result = (AXUIElementRef)CFRetain((__bridge AXUIElementRef)matches.firstObject);
            }
            return;
        }
    }
    NSArray<NSString *> *classTokens = [self stringArrayAttribute:
        CFSTR("AXDOMClassList") element:element];
    if (CPAClassTokensMarkSelectedConversation(classTokens ?: @[])
        && [self conversationTitleFromElement:element].length > 0) {
        *result = (AXUIElementRef)CFRetain(element);
        return;
    }
    CFTypeRef childrenValue = NULL;
    AXError childrenError = AXUIElementCopyAttributeValue(
        element, kAXChildrenAttribute, &childrenValue);
    if (childrenError != kAXErrorSuccess || childrenValue == NULL
        || CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        if (childrenValue != NULL) {
            CFRelease(childrenValue);
        }
        return;
    }
    NSArray *children = (__bridge NSArray *)childrenValue;
    for (NSUInteger i = 0, count = children.count; i < count; i++) {
        id child = children[i];
        if (CFGetTypeID((__bridge CFTypeRef)child) != AXUIElementGetTypeID()) {
            continue;
        }
        [self findSelectedConversationInElement:(__bridge AXUIElementRef)child
            depth:depth + 1 visited:visited result:result];
        if (*result != NULL || *visited >= CPAConversationScanMaxNodes) {
            break;
        }
    }
    CFRelease(childrenValue);
}

- (void)collectOverlayTitleElements:(AXUIElementRef)element depth:(NSUInteger)depth
    visited:(NSUInteger *)visited matches:(NSMutableArray *)matches {
    if (depth > CPAConversationScanMaxDepth || *visited >= CPAConversationScanMaxNodes || matches.count > 1) return;
    (*visited)++;
    if ([[self stringAttribute:kAXRoleAttribute element:element] isEqualToString:@"AXButton"]
        && CPAConversationTitleFromOverlayCloseDescription([self stringAttribute:kAXDescriptionAttribute element:element] ?: @"") != nil) {
        [matches addObject:(__bridge id)element];
    }
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess
        && children != NULL && CFGetTypeID(children) == CFArrayGetTypeID()) {
        for (id child in (__bridge NSArray *)children) {
            [self collectOverlayTitleElements:(__bridge AXUIElementRef)child depth:depth+1 visited:visited matches:matches];
        }
    }
    if (children != NULL) CFRelease(children);
}

- (void)forgetSelectedConversationElement {
    self.selectedConversationIsOverlay = NO;
    if (self.selectedConversationElement != NULL) {
        CFRelease(self.selectedConversationElement);
        self.selectedConversationElement = NULL;
    }
}

- (nullable NSString *)freshCachedConversationTitle {
    if (self.cachedConversationTitle.length == 0
        || self.cachedConversationTitleDate == nil
        || -[self.cachedConversationTitleDate timeIntervalSinceNow]
            > CPAConversationTitleGraceInterval) {
        return nil;
    }
    return self.cachedConversationTitle;
}

- (void)invalidateConversationScanCache {
    @synchronized (self) {
        self.cachedConversationTitle = nil;
        self.cachedConversationTitleDate = nil;
        self.conversationScanDate = nil;
        self.conversationScanProcessIdentifier = 0;
        self.lastConversationScanVisitedNodes = 0;
        self.lastConversationScanDurationMilliseconds = 0;
    }
}

@end
