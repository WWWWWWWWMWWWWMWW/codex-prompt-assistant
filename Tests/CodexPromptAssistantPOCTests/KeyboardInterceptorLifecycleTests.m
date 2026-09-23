#import <AppKit/AppKit.h>

#import "../../Sources/CodexPromptAssistantPOC/KeyboardInterceptor.h"

static NSUInteger targetedPosts, globalPosts;
static BOOL failKeyUp;
static void FakeTargetPost(pid_t pid, CGEventRef event) {
    if (pid != 123 || CGEventGetFlags(event) != 0) abort();
    UniChar chars[64]; UniCharCount length = 0;
    CGEventKeyboardGetUnicodeString(event, 64, &length, chars);
    if (![[NSString stringWithCharacters:chars length:length] isEqualToString:@"合成文本"]) abort();
    targetedPosts++;
}
static void __attribute__((unused)) FakeGlobalPost(CGEventTapLocation location, CGEventRef event) {
    (void)location; (void)event; globalPosts++;
}
static CGEventRef FakeCreateKey(CGEventSourceRef source, CGKeyCode code, bool down) {
    return failKeyUp && !down ? NULL : CGEventCreateKeyboardEvent(source, code, down);
}
#define CGEventPostToPid FakeTargetPost
#define CGEventPost FakeGlobalPost
#define CGEventCreateKeyboardEvent FakeCreateKey
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../../Sources/CodexPromptAssistantPOC/KeyboardInterceptor.m"
#pragma clang diagnostic pop
#undef CGEventPostToPid
#undef CGEventPost
#undef CGEventCreateKeyboardEvent

@interface DeliveryInterceptor : CPAKeyboardInterceptor
@property(nonatomic) pid_t testPID;
@property(nonatomic) NSUInteger foregroundChecks;
@property(nonatomic) BOOL switchesBeforePost;
@end
@implementation DeliveryInterceptor
- (pid_t)observedFrontmostProcessIdentifier {
    self.foregroundChecks++;
    return self.switchesBeforePost && self.foregroundChecks > 1 ? 456 : self.testPID;
}
@end

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSString *MethodBody(NSString *source, NSString *signature) {
    NSRange start = [source rangeOfString:signature];
    Assert(start.location != NSNotFound,
        [NSString stringWithFormat:@"missing method signature: %@", signature]);
    NSRange nextMethod = [source rangeOfString:@"\n- ("
        options:0
        range:NSMakeRange(NSMaxRange(start), source.length - NSMaxRange(start))];
    NSUInteger end = nextMethod.location == NSNotFound
        ? source.length : nextMethod.location;
    return [source substringWithRange:NSMakeRange(start.location, end - start.location)];
}

@interface LifecycleDelegate : NSObject <CPAKeyboardInterceptorDelegate>
@property(nonatomic) BOOL observationAllowed;
@property(nonatomic) NSUInteger observedInputEventCount;
@property(nonatomic) NSUInteger navigationCount;
@end

@implementation LifecycleDelegate
- (BOOL)keyboardInterceptorShouldObserveCurrentInput {
    return self.observationAllowed;
}
- (NSString *)keyboardInterceptorCurrentFrontmostBundleIdentifier { return @"com.openai.codex"; }
- (void)keyboardInterceptorDidObservePossibleTaskNavigation { self.navigationCount++; }
- (BOOL)keyboardInterceptorShouldHandleSuggestionKeys { return NO; }
- (void)keyboardInterceptorDidRequestAccept {}
- (void)keyboardInterceptorDidRequestDismiss {}
- (void)keyboardInterceptorDidObserveInputEvent {
    self.observedInputEventCount++;
}
@end

@interface CPAKeyboardInterceptor (LifecycleTesting)
- (void)notifyDelegateOfObservedInputEvent;
@end

int main(void) {
    @autoreleasepool {
        LifecycleDelegate *delegate = [[LifecycleDelegate alloc] init];
        CPAKeyboardInterceptor *interceptor = [[CPAKeyboardInterceptor alloc]
            initWithDelegate:delegate];
        Assert(!interceptor.running,
            @"a new interceptor should not claim to be running before start");
        Assert(!interceptor.mostRecentTextEditWasDeletion,
            @"a new interceptor must not invent a deletion edit");
        Assert(!interceptor.shouldObserveCurrentInput,
            @"a disabled policy must keep the event tap in pass-through mode");
        // Even with input observation disabled, navigation must revoke task ownership.
        CGEventRef nav = CGEventCreateKeyboardEvent(NULL,kVK_ANSI_1,true);
        CGEventSetFlags(nav,kCGEventFlagMaskCommand);
        [interceptor handleEventType:kCGEventKeyDown event:nav];
        Assert(delegate.navigationCount == 1,@"task navigation shortcut revokes binding");
        CGEventSetIntegerValueField(nav,kCGKeyboardEventKeycode,kVK_ANSI_V);
        [interceptor handleEventType:kCGEventKeyDown event:nav];
        CGEventSetFlags(nav,0);
        [interceptor handleEventType:kCGEventKeyDown event:nav];
        Assert(delegate.navigationCount == 1,@"paste and typing are not task navigation");
        CGEventSetIntegerValueField(nav,kCGEventSourceUserData,CPAThreadIDCopyEventTag);
        CGEventSetFlags(nav,kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate);
        [interceptor handleEventType:kCGEventKeyDown event:nav];
        Assert(delegate.navigationCount == 1,@"our ID probe does not cancel itself");
        CFRelease(nav);delegate.observedInputEventCount=0;
        delegate.observationAllowed = YES;
        Assert(interceptor.shouldObserveCurrentInput,
            @"the current policy may explicitly allow input observation");
        [interceptor notifyDelegateOfObservedInputEvent];
        Assert(delegate.observedInputEventCount == 1,
            @"an observed edit should notify the scheduling delegate exactly once");

        NSString *source = [NSString stringWithContentsOfFile:
            @"Sources/CodexPromptAssistantPOC/KeyboardInterceptor.m"
            encoding:NSUTF8StringEncoding error:nil];
        NSString *inputSourceBody = MethodBody(source,
            @"- (BOOL)currentInputSourceUsesChinese {");
        NSString *candidateWindowBody = MethodBody(source,
            @"- (BOOL)hasVisibleInputMethodCandidateWindow {");
        Assert([inputSourceBody rangeOfString:@"TISCopyCurrentKeyboardInputSource"].location
                == NSNotFound,
            @"the key-event path must read the cached input-source state");
        Assert([candidateWindowBody rangeOfString:@"CGWindowListCopyWindowInfo"].location
                == NSNotFound,
            @"the key-event path must not synchronously scan candidate windows");
        NSString *eventBody = MethodBody(source,
            @"- (CGEventRef _Nullable)handleEventType:(CGEventType)type event:(CGEventRef)event {");
        Assert([eventBody rangeOfString:@"notifyDelegateOfObservedInputEvent"].location
                != NSNotFound,
            @"the event tap should notify the main scheduler after lightweight state changes");
        NSString *probeBody = MethodBody(source,
            @"- (void)scheduleInputMethodCacheRefresh:(BOOL)force {");
        NSString *inputSourceProbeBody = MethodBody(source,
            @"- (BOOL)readInputSourceUsesChineseOnMainThread {");
        Assert([inputSourceProbeBody rangeOfString:@"NSThread.isMainThread"].location
                != NSNotFound,
            @"Carbon input-source APIs must defend their main-thread contract");
        NSRange mainQueueDispatch = [probeBody
            rangeOfString:@"dispatch_async(dispatch_get_main_queue()"];
        NSRange inputSourceRead = [probeBody
            rangeOfString:@"readInputSourceUsesChineseOnMainThread"];
        NSRange candidateQueueDispatch = [probeBody
            rangeOfString:@"dispatch_async(strongSelf.inputMethodProbeQueue"];
        Assert(mainQueueDispatch.location != NSNotFound
                && inputSourceRead.location != NSNotFound
                && candidateQueueDispatch.location != NSNotFound
                && mainQueueDispatch.location < inputSourceRead.location
                && inputSourceRead.location < candidateQueueDispatch.location,
            @"TIS must run asynchronously on main before candidate windows scan in background");
        NSRange sourcePublished = [probeBody
            rangeOfString:@"strongSelf.inputSourceCacheKnown = YES"];
        NSRange candidateScan = [probeBody
            rangeOfString:@"readVisibleInputMethodCandidateWindowOnProbeQueue"];
        Assert(sourcePublished.location != NSNotFound
                && candidateScan.location != NSNotFound
                && sourcePublished.location < candidateScan.location,
            @"the input-source language result must publish before the slower candidate-window scan");
        NSString *candidateBody = MethodBody(source,
            @"- (BOOL)chineseCandidateIsProbablyActive {");
        NSRange languageCheck = [candidateBody
            rangeOfString:@"BOOL usesChineseInput = [self currentInputSourceUsesChinese]"];
        NSRange compositionCheck = [candidateBody
            rangeOfString:@"self.inputMethodState.potentialComposition"];
        Assert(languageCheck.location != NSNotFound
                && compositionCheck.location != NSNotFound
                && languageCheck.location < compositionCheck.location,
            @"a known non-Chinese input source must override stale composition state before Tab routing");
        NSString *mainSource = [NSString stringWithContentsOfFile:
            @"Sources/CodexPromptAssistantPOC/main.m"
            encoding:NSUTF8StringEncoding error:nil];
        Assert([mainSource rangeOfString:@"CPAScheduleRepeatingTimer"].location
                != NSNotFound,
            @"the repeating input poll should be registered in common run-loop modes");
        [interceptor stop];
        [interceptor stop];
        Assert(!interceptor.running,
            @"stop must be idempotent and release all event-tap state");
        DeliveryInterceptor *delivery = [[DeliveryInterceptor alloc] initWithDelegate:delegate];
        delivery.testPID = 123;
        Assert([delivery postText:@"合成文本" toProcessIdentifier:123]
            && targetedPosts == 2 && globalPosts == 0, @"only paired, unmodified Unicode events go to the target PID");
        targetedPosts = 0;
        Assert(![delivery postText:@"合成文本" toProcessIdentifier:456] && targetedPosts == 0,
            @"a non-frontmost target receives no events");
        delivery.foregroundChecks = 0; delivery.switchesBeforePost = YES;
        Assert(![delivery postText:@"合成文本" toProcessIdentifier:123] && targetedPosts == 0,
            @"switching focus during event preparation cancels posting");
        delivery.switchesBeforePost = NO; failKeyUp = YES;
        Assert(![delivery postText:@"合成文本" toProcessIdentifier:123] && targetedPosts == 0 && globalPosts == 0,
            @"partial event allocation must not post an unmatched key-down");
        NSLog(@"PASS: KeyboardInterceptorLifecycleTests");
    }
    return 0;
}
