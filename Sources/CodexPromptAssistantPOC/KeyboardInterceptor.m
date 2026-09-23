#import "KeyboardInterceptor.h"

#import <Carbon/Carbon.h>
#import "CodexThreadIDResolver.h"

#import "CandidateWindowClassifier.h"
#import "Diagnostics.h"
#import "InputMethodState.h"

static CGEventRef _Nullable CPAKeyboardEventCallback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *userInfo
);

@interface CPAKeyboardInterceptor ()
@property(nonatomic, weak) id<CPAKeyboardInterceptorDelegate> delegate;
@property(nonatomic, readwrite) BOOL mostRecentTextEditWasDeletion;
@property(nonatomic) CFMachPortRef eventTap;
@property(nonatomic) CFRunLoopSourceRef eventTapSource;
@property(nonatomic) CFTimeInterval lastTextKeyTime;
@property(nonatomic, strong) CPAInputMethodState *inputMethodState;
@property(nonatomic, strong, readwrite) CPAKeyboardShadowBuffer *shadowBuffer;
@property(nonatomic) CGRect fallbackInputFrame;
@property(nonatomic) BOOL fallbackInputFrameAvailable;
@property(nonatomic) CGPoint lastGlobalMouseDownLocation;
@property(nonatomic) CFTimeInterval lastGlobalMouseDownTime;
// TIS must run on the main thread, while CGWindowList can synchronously cross
// into other processes. Keep both results in a short-lived cache so the
// global event-tap callback only performs constant-time reads.
@property(nonatomic) dispatch_queue_t inputMethodProbeQueue;
@property(nonatomic) BOOL inputMethodProbeInProgress;
@property(nonatomic) NSUInteger inputMethodProbeGeneration;
@property(nonatomic) CFTimeInterval lastInputMethodProbeTime;
@property(nonatomic) BOOL cachedInputSourceUsesChinese;
@property(nonatomic) BOOL inputSourceCacheKnown;
@property(nonatomic) BOOL cachedCandidateWindowVisible;
@property(nonatomic) BOOL candidateWindowCacheKnown;
- (void)scheduleInputMethodCacheRefresh:(BOOL)force;
- (BOOL)readInputSourceUsesChineseOnMainThread;
- (BOOL)readVisibleInputMethodCandidateWindowOnProbeQueue;
- (NSString *)currentFrontmostBundleIdentifier;
- (void)notifyDelegateOfObservedInputEvent;
@end

@implementation CPAKeyboardInterceptor

- (instancetype)initWithDelegate:(id<CPAKeyboardInterceptorDelegate>)delegate {
    self = [super init];
    if (self != nil) {
        _delegate = delegate;
        _inputMethodState = [[CPAInputMethodState alloc] init];
        _shadowBuffer = [[CPAKeyboardShadowBuffer alloc] init];
        _inputMethodProbeQueue = dispatch_queue_create(
            "local.codex.prompt-assistant.input-method-probe",
            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning {
    return self.eventTap != NULL;
}

- (BOOL)eventTapEnabled {
    return self.eventTap != NULL && CGEventTapIsEnabled(self.eventTap);
}

- (BOOL)shouldObserveCurrentInput {
    id<CPAKeyboardInterceptorDelegate> delegate = self.delegate;
    return delegate != nil
        && [delegate keyboardInterceptorShouldObserveCurrentInput];
}

- (NSString *)currentFrontmostBundleIdentifier {
    id<CPAKeyboardInterceptorDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(keyboardInterceptorCurrentFrontmostBundleIdentifier)]) {
        NSString *bundleIdentifier = [delegate
            keyboardInterceptorCurrentFrontmostBundleIdentifier];
        if (bundleIdentifier != nil) {
            return bundleIdentifier;
        }
    }
    // Test/degraded delegates may not provide the cache. Keep a conservative
    // fallback, but production always uses the notification-backed value.
    return NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"";
}

- (void)stop {
    BOOL wasRunning = self.eventTap != NULL || self.eventTapSource != NULL;
    if (_eventTapSource != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _eventTapSource, kCFRunLoopCommonModes);
        CFRelease(_eventTapSource);
        _eventTapSource = NULL;
    }
    if (_eventTap != NULL) {
        CFMachPortInvalidate(_eventTap);
        CFRelease(_eventTap);
        _eventTap = NULL;
    }
    if (wasRunning) {
        CPADiagnosticLog(@"event_tap stop=true");
    }
}

- (BOOL)start {
    if (self.eventTap != NULL) {
        return YES;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)
        | CGEventMaskBit(kCGEventLeftMouseDown)
        | CGEventMaskBit(kCGEventRightMouseDown)
        | CGEventMaskBit(kCGEventOtherMouseDown);
    self.eventTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        CPAKeyboardEventCallback,
        (__bridge void *)self
    );
    if (self.eventTap == NULL) {
        CPADiagnosticLog(@"event_tap start=false");
        return NO;
    }

    CFRunLoopSourceRef eventTapSource = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault,
        self.eventTap,
        0
    );
    if (eventTapSource == NULL) {
        CFMachPortInvalidate(self.eventTap);
        CFRelease(self.eventTap);
        self.eventTap = NULL;
        CPADiagnosticLog(@"event_tap source=false");
        return NO;
    }
    _eventTapSource = eventTapSource;
    CFRunLoopAddSource(
        CFRunLoopGetMain(),
        _eventTapSource,
        kCFRunLoopCommonModes
    );
    CGEventTapEnable(self.eventTap, true);
    [self scheduleInputMethodCacheRefresh:YES];
    CPADiagnosticLog(@"event_tap start=true");
    return YES;
}

- (CGEventRef _Nullable)handleEventType:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self.eventTap != NULL) {
            CGEventTapEnable(self.eventTap, true);
        }
        return event;
    }
    if (event != NULL && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == CPAThreadIDCopyEventTag)
        return event;
    if (type != kCGEventKeyDown) {
        if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown
            || type == kCGEventOtherMouseDown) {
            CGPoint mouseLocation = CGEventGetLocation(event);
            self.lastGlobalMouseDownLocation = mouseLocation;
            self.lastGlobalMouseDownTime = CACurrentMediaTime();
            [self.inputMethodState noteMouseDown];
            self.mostRecentTextEditWasDeletion = NO;
            NSString *frontmostBundleIdentifier =
                [self currentFrontmostBundleIdentifier];
            BOOL isCodex = [frontmostBundleIdentifier
                isEqualToString:@"com.openai.codex"];
            if (isCodex && [self.delegate respondsToSelector:@selector(keyboardInterceptorDidObservePossibleTaskNavigation)])
                [self.delegate keyboardInterceptorDidObservePossibleTaskNavigation];
            BOOL observesCurrentInput = self.shouldObserveCurrentInput;
            if (observesCurrentInput && isCodex) {
                BOOL insideFallbackInput = self.fallbackInputFrameAvailable
                    && CGRectContainsPoint(self.fallbackInputFrame, mouseLocation);
                [self.shadowBuffer handleMouseDownInsideFallbackInput:
                    insideFallbackInput];
            } else if (!isCodex) {
                [self.shadowBuffer reset];
            }
            if (observesCurrentInput) {
                [self notifyDelegateOfObservedInputEvent];
            }
        }
        return event;
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(
        event,
        kCGKeyboardEventKeycode
    );
    CGEventFlags flags = CGEventGetFlags(event);
    BOOL commandModified = (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) != 0;
    NSString *frontmostBundleIdentifier = [self currentFrontmostBundleIdentifier];
    BOOL isCodex = [frontmostBundleIdentifier isEqualToString:@"com.openai.codex"];
    BOOL ordinaryEditShortcut = (flags & kCGEventFlagMaskCommand) && !(flags & kCGEventFlagMaskControl)
        && !(flags & kCGEventFlagMaskAlternate)
        && (keyCode == kVK_ANSI_A || keyCode == kVK_ANSI_C || keyCode == kVK_ANSI_V
            || keyCode == kVK_ANSI_X || keyCode == kVK_ANSI_Z);
    if (isCodex && commandModified && !ordinaryEditShortcut
        && [self.delegate respondsToSelector:@selector(keyboardInterceptorDidObservePossibleTaskNavigation)])
        [self.delegate keyboardInterceptorDidObservePossibleTaskNavigation];
    BOOL suggestionKey = keyCode == (CGKeyCode)kVK_Tab
        || keyCode == (CGKeyCode)kVK_Escape;
    if (!self.shouldObserveCurrentInput) {
        if (suggestionKey) {
            CPADiagnosticLog(@"shortcut gate=observe_denied keyCode=%u codex=%@",
                keyCode, isCodex ? @"true" : @"false");
        }
        [self.shadowBuffer reset];
        self.mostRecentTextEditWasDeletion = NO;
        [self notifyDelegateOfObservedInputEvent];
        return event;
    }
    BOOL usesChineseInput = [self currentInputSourceUsesChinese];
    [self scheduleInputMethodCacheRefresh:suggestionKey];
    if (keyCode != (CGKeyCode)kVK_Tab && keyCode != (CGKeyCode)kVK_Escape) {
        self.mostRecentTextEditWasDeletion =
            keyCode == (CGKeyCode)kVK_Delete
            || keyCode == (CGKeyCode)kVK_ForwardDelete;
    }
    if (keyCode != (CGKeyCode)kVK_Tab && keyCode != (CGKeyCode)kVK_Escape
        && !commandModified) {
        self.lastTextKeyTime = CACurrentMediaTime();
    }
    if (keyCode != (CGKeyCode)kVK_Tab && keyCode != (CGKeyCode)kVK_Escape) {
        [self.inputMethodState noteKeyCode:keyCode
            commandModified:commandModified
            usesChineseInput:usesChineseInput];
    } else if (!usesChineseInput) {
        [self.inputMethodState noteMouseDown];
    }

    if (isCodex) {
        BOOL selecting = (flags & kCGEventFlagMaskShift) != 0;
        if (commandModified) {
            BOOL commandPressed = (flags & kCGEventFlagMaskCommand) != 0;
            if (commandPressed && keyCode == (CGKeyCode)kVK_ANSI_A) {
                [self.shadowBuffer selectAll];
            } else if (commandPressed) {
                [self.shadowBuffer markUnknown];
            }
        } else {
            switch (keyCode) {
                case kVK_Delete:
                    [self.shadowBuffer applyBackspace];
                    break;
                case kVK_ForwardDelete:
                    [self.shadowBuffer applyDelete];
                    break;
                case kVK_LeftArrow:
                    [self.shadowBuffer moveCursorLeftSelecting:selecting];
                    break;
                case kVK_RightArrow:
                    [self.shadowBuffer moveCursorRightSelecting:selecting];
                    break;
                case kVK_Home:
                    [self.shadowBuffer moveCursorToStartSelecting:selecting];
                    break;
                case kVK_End:
                    [self.shadowBuffer moveCursorToEndSelecting:selecting];
                    break;
                case kVK_Return:
                case kVK_ANSI_KeypadEnter:
                    [self.shadowBuffer clearAfterSubmit];
                    break;
                default: {
                    UniChar characters[128] = {0};
                    UniCharCount length = 0;
                    CGEventKeyboardGetUnicodeString(event, 128, &length, characters);
                    if (length > 0) {
                        NSString *committed = [NSString stringWithCharacters:characters
                            length:length];
                        BOOL likelyPinyin = usesChineseInput
                            && self.inputMethodState.potentialComposition
                            && [committed canBeConvertedToEncoding:NSASCIIStringEncoding];
                        if (likelyPinyin) {
                            [self.shadowBuffer markUnknown];
                        } else if (![committed isEqualToString:@"\n"]
                            && ![committed isEqualToString:@"\r"]
                            && ![committed isEqualToString:@"\t"]) {
                            [self.shadowBuffer applyCommittedText:committed];
                        }
                    }
                    break;
                }
            }
        }
    } else {
        [self.shadowBuffer reset];
    }

    if (!suggestionKey) {
        // AX/model work is deliberately deferred by the delegate. Returning
        // here also avoids querying the candidate-overlay gate for every
        // ordinary character key.
        [self notifyDelegateOfObservedInputEvent];
        return event;
    }

    id<CPAKeyboardInterceptorDelegate> delegate = self.delegate;
    if (delegate == nil || ![delegate keyboardInterceptorShouldHandleSuggestionKeys]) {
        if (suggestionKey) {
            CPADiagnosticLog(@"shortcut gate=handle_denied keyCode=%u codex=%@",
                keyCode, isCodex ? @"true" : @"false");
        }
        return event;
    }
    if (keyCode != (CGKeyCode)kVK_Tab && keyCode != (CGKeyCode)kVK_Escape) {
        return event;
    }
    if ([self chineseCandidateIsProbablyActive]) {
        [self notifyDelegateOfObservedInputEvent];
        CPADiagnosticLog(@"shortcut pass_through=ime keyCode=%u composition=%@",
            keyCode,
            self.inputMethodState.potentialComposition ? @"true" : @"false");
        if (keyCode == (CGKeyCode)kVK_Escape) {
            [self.inputMethodState noteMouseDown];
        }
        return event;
    }

    if (keyCode == (CGKeyCode)kVK_Tab) {
        CPADiagnosticLog(@"shortcut action=accept");
        [delegate keyboardInterceptorDidRequestAccept];
    } else {
        CPADiagnosticLog(@"shortcut action=dismiss");
        [delegate keyboardInterceptorDidRequestDismiss];
    }
    return NULL;
}

- (void)notifyDelegateOfObservedInputEvent {
    id<CPAKeyboardInterceptorDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(keyboardInterceptorDidObserveInputEvent)]) {
        [delegate keyboardInterceptorDidObserveInputEvent];
    }
}

- (BOOL)chineseCandidateIsProbablyActive {
    BOOL usesChineseInput = [self currentInputSourceUsesChinese];
    // A probe can finish after an English key briefly entered the conservative
    // unknown state. Once the source is known to be non-Chinese, that stale
    // composition flag must not swallow Tab/Esc.
    if (!usesChineseInput) {
        return NO;
    }
    if (self.inputMethodState.potentialComposition) {
        return YES;
    }
    if ([self hasVisibleInputMethodCandidateWindow]) {
        return YES;
    }

    CFTimeInterval elapsed = CACurrentMediaTime() - self.lastTextKeyTime;
    if (self.lastTextKeyTime > 0 && elapsed >= 0 && elapsed < 0.55) {
        return YES;
    }
    return NO;
}

- (BOOL)inputMethodCompositionProbablyActive {
    return [self inputMethodSuggestionDelayRemaining] > 0;
}

- (NSTimeInterval)inputMethodSuggestionDelayRemaining {
    if (![self currentInputSourceUsesChinese]) {
        return 0;
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - self.lastTextKeyTime;
    // Some input methods keep an invisible candidate panel on screen after a
    // commit. An explicit Space/Return/number commit only needs a brief AX
    // settle; an uncommitted pinyin sequence retains the longer safety guard.
    if (self.lastTextKeyTime <= 0 || elapsed < 0) {
        return 0;
    }
    return [self.inputMethodState
        suggestionDelayRemainingForElapsedSinceLastTextKey:elapsed];
}

- (BOOL)currentInputSourceUsesChinese {
    [self scheduleInputMethodCacheRefresh:NO];
    @synchronized (self) {
        // Unknown input-source state is a conservative IME boundary. The
        // background probe normally fills this before the first user key.
        return self.inputSourceCacheKnown ? self.cachedInputSourceUsesChinese : YES;
    }
}

- (BOOL)hasVisibleInputMethodCandidateWindow {
    [self scheduleInputMethodCacheRefresh:NO];
    @synchronized (self) {
        if (!self.candidateWindowCacheKnown) {
            return self.inputSourceCacheKnown && self.cachedInputSourceUsesChinese;
        }
        return self.cachedCandidateWindowVisible;
    }
}

- (void)scheduleInputMethodCacheRefresh:(BOOL)force {
    if (self.inputMethodProbeQueue == nil) {
        return;
    }
    BOOL shouldStart = NO;
    NSUInteger generation = 0;
    CFTimeInterval now = CACurrentMediaTime();
    @synchronized (self) {
        CFTimeInterval elapsed = self.lastInputMethodProbeTime > 0.0
            ? now - self.lastInputMethodProbeTime : DBL_MAX;
        // A suggestion key needs a fresh candidate-window answer, but cap
        // forced probes so a held key cannot turn into a window-scan loop.
        NSTimeInterval minimumInterval = force ? 0.04 : 0.20;
        if (self.inputMethodProbeInProgress || elapsed < minimumInterval) {
            return;
        }
        self.inputMethodProbeInProgress = YES;
        self.lastInputMethodProbeTime = now;
        generation = ++self.inputMethodProbeGeneration;
        shouldStart = YES;
    }
    if (!shouldStart) {
        return;
    }
    __weak CPAKeyboardInterceptor *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CPAKeyboardInterceptor *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        BOOL usesChinese = [strongSelf readInputSourceUsesChineseOnMainThread];
        // Publish the language classification as soon as TIS returns. The
        // candidate-window enumeration below can be comparatively slow; it
        // must not keep an ordinary English key in the conservative IME
        // unknown state (which would add the 550ms composition guard).
        BOOL shouldScanCandidateWindow = NO;
        @synchronized (strongSelf) {
            if (generation != strongSelf.inputMethodProbeGeneration) {
                strongSelf.inputMethodProbeInProgress = NO;
            } else {
                strongSelf.cachedInputSourceUsesChinese = usesChinese;
                strongSelf.inputSourceCacheKnown = YES;
                strongSelf.candidateWindowCacheKnown = NO;
                shouldScanCandidateWindow = YES;
            }
        }
        if (!shouldScanCandidateWindow) {
            return;
        }
        dispatch_async(strongSelf.inputMethodProbeQueue, ^{
            CPAKeyboardInterceptor *candidateSelf = weakSelf;
            if (candidateSelf == nil) {
                return;
            }
            BOOL candidateVisible = usesChinese
                && [candidateSelf readVisibleInputMethodCandidateWindowOnProbeQueue];
            @synchronized (candidateSelf) {
                if (generation != candidateSelf.inputMethodProbeGeneration) {
                    candidateSelf.inputMethodProbeInProgress = NO;
                    return;
                }
                candidateSelf.cachedInputSourceUsesChinese = usesChinese;
                candidateSelf.inputSourceCacheKnown = YES;
                candidateSelf.cachedCandidateWindowVisible = candidateVisible;
                candidateSelf.candidateWindowCacheKnown = YES;
                candidateSelf.inputMethodProbeInProgress = NO;
            }
        });
    });
}

- (BOOL)readInputSourceUsesChineseOnMainThread {
    if (!NSThread.isMainThread) {
        CPADiagnosticLog(@"input_method source_probe=wrong_thread");
        return YES;
    }
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    if (source == NULL) {
        return NO;
    }
    BOOL usesChinese = NO;
    CFArrayRef languages = TISGetInputSourceProperty(source,
        kTISPropertyInputSourceLanguages);
    if (languages != NULL) {
        NSArray *languageList = (__bridge NSArray *)languages;
        for (NSUInteger i = 0, len = languageList.count; i < len; i++) {
            id value = languageList[i];
            if ([value isKindOfClass:NSString.class]
                && [(NSString *)value hasPrefix:@"zh"]) {
                usesChinese = YES;
                break;
            }
        }
    }
    CFRelease(source);
    return usesChinese;
}

- (BOOL)readVisibleInputMethodCandidateWindowOnProbeQueue {
    CFArrayRef windowInfoRef = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (windowInfoRef == NULL) {
        return NO;
    }
    BOOL found = NO;
    NSArray *windowInfo = CFBridgingRelease(windowInfoRef);
    for (NSUInteger i = 0, len = windowInfo.count; i < len; i++) {
        NSDictionary *item = windowInfo[i];
        NSString *owner = item[(__bridge NSString *)kCGWindowOwnerName];
        NSDictionary *boundsDictionary = item[(__bridge NSString *)kCGWindowBounds];
        NSNumber *alpha = item[(__bridge NSString *)kCGWindowAlpha];
        NSNumber *layer = item[(__bridge NSString *)kCGWindowLayer];
        if (owner.length == 0 || boundsDictionary == nil || alpha.doubleValue <= 0.0) {
            continue;
        }
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)boundsDictionary, &bounds)) {
            continue;
        }
        if (CPAWindowLooksLikeInputMethodCandidate(owner, bounds,
                alpha.doubleValue, layer.integerValue)) {
            found = YES;
            break;
        }
    }
    return found;
}

- (pid_t)observedFrontmostProcessIdentifier {
    return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
}

- (void)postText:(NSString *)text {
    [self postText:text toProcessIdentifier:[self observedFrontmostProcessIdentifier]];
}

- (BOOL)postText:(NSString *)text toProcessIdentifier:(pid_t)processIdentifier {
    if (text.length == 0 || processIdentifier <= 0
        || [self observedFrontmostProcessIdentifier] != processIdentifier) return NO;
    NSUInteger length = text.length;
    UniChar *characters = calloc(length, sizeof(UniChar));
    if (characters == NULL) return NO;
    [text getCharacters:characters range:NSMakeRange(0, length)];
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef keyDown = source != NULL ? CGEventCreateKeyboardEvent(source, 0, true) : NULL;
    CGEventRef keyUp = source != NULL ? CGEventCreateKeyboardEvent(source, 0, false) : NULL;
    BOOL posted = NO;
    if (keyDown != NULL && keyUp != NULL) {
        CGEventSetFlags(keyDown, 0);
        CGEventSetFlags(keyUp, 0);
        CGEventKeyboardSetUnicodeString(keyDown, length, characters);
        CGEventKeyboardSetUnicodeString(keyUp, length, characters);
        if ([self observedFrontmostProcessIdentifier] == processIdentifier) {
            // Bind delivery to the validated process, never the global focus.
            CGEventPostToPid(processIdentifier, keyDown);
            CGEventPostToPid(processIdentifier, keyUp);
            posted = YES;
            CPADiagnosticLog(@"post_text characterCount=%lu", (unsigned long)length);
        }
    }
    if (keyDown != NULL) CFRelease(keyDown);
    if (keyUp != NULL) CFRelease(keyUp);
    if (source != NULL) CFRelease(source);
    free(characters);
    return posted;
}

- (void)resetShadowBuffer {
    [self.shadowBuffer reset];
}

- (void)updateFallbackInputFrame:(CGRect)inputFrame available:(BOOL)available {
    self.fallbackInputFrame = available ? inputFrame : CGRectZero;
    self.fallbackInputFrameAvailable = available;
}

- (void)prepareShadowBufferForCodexActivation {
    [self.shadowBuffer reset];
    CFTimeInterval elapsed = CACurrentMediaTime() - self.lastGlobalMouseDownTime;
    if (self.lastGlobalMouseDownTime <= 0.0 || elapsed < 0.0 || elapsed > 0.75) {
        return;
    }
    BOOL insideFallbackInput = self.fallbackInputFrameAvailable
        && CGRectContainsPoint(self.fallbackInputFrame,
            self.lastGlobalMouseDownLocation);
    [self.shadowBuffer handleMouseDownInsideFallbackInput:insideFallbackInput];
}

- (void)synchronizeShadowBufferWithText:(NSString *)text
                        cursorLocation:(NSUInteger)cursorLocation
                        selectedLength:(NSUInteger)selectedLength {
    [self.shadowBuffer replaceWithAuthoritativeText:text
        cursorLocation:cursorLocation
        selectedLength:selectedLength];
}

@end

static CGEventRef _Nullable CPAKeyboardEventCallback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *userInfo
) {
    (void)proxy;
    CPAKeyboardInterceptor *interceptor = (__bridge CPAKeyboardInterceptor *)userInfo;
    return [interceptor handleEventType:type event:event];
}
