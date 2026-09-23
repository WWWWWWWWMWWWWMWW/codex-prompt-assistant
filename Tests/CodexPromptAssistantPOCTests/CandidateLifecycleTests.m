#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#define main CPAProductionEntryPoint
#include "../../Sources/CodexPromptAssistantPOC/main.m"
#undef main
#pragma clang diagnostic pop
#import <sqlite3.h>
#import "../../Sources/CodexDataCore/KeychainStore.h"

static NSUInteger failures;
#define Verify(condition, reason) do { if (!(condition)) { failures++; NSLog(@"FAIL: %@ (line %d)", reason, __LINE__); } } while (0)

@interface CPAConversationContextProvider (LifecycleTest)
- (void)refreshLocked;
- (id)readContextFromURL:(NSURL *)url;
@end
@interface CPALifecycleContextProvider : CPAConversationContextProvider
@property(nonatomic, copy) void (^afterRead)(void);
@end
@implementation CPALifecycleContextProvider
- (id)readContextFromURL:(NSURL *)url {
    id result = [super readContextFromURL:url];
    void (^change)(void) = self.afterRead; self.afterRead = nil;
    if (change) change();
    return result;
}
@end
@interface CPALifecycleOverlay : CPAOverlayController
@property(nonatomic) BOOL testVisible;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) NSUInteger shows;
@property(nonatomic) BOOL cannotFit;
@end
@implementation CPALifecycleOverlay
- (BOOL)visible { return self.testVisible; }
- (void)hide { self.testVisible = NO; }
- (void)showSuggestion:(NSString *)text atAccessibilityBounds:(CGRect)bounds {
    (void)bounds; self.text = text; self.testVisible = !self.cannotFit; self.shows++;
}
@end
@interface CPALifecycleClient : CPARemoteCompletionClient
@property(nonatomic, copy) CPARemoteCompletionHandler finish;
@property(nonatomic, copy) CPARemoteCompletionProgressHandler progress;
@property(nonatomic, copy) NSArray *sentMessages;
@property(nonatomic) NSUInteger clears;
@property(nonatomic) NSUInteger requests;
@property(nonatomic, copy) NSString *sentInput;
@property(nonatomic, copy) NSString *sentRight;
@end
@implementation CPALifecycleClient
- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    contextMessages:(NSArray *)messages apiKey:(NSString *)key preferredModel:(NSString *)model
    progress:(CPARemoteCompletionProgressHandler)progress completion:(CPARemoteCompletionHandler)finish {
    self.requests++; self.sentInput = input; (void)key; (void)model;
    self.finish = finish; self.progress = progress; self.sentMessages = messages;
    return [CPARemoteCompletionTask new];
}
- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input rightContext:(NSString *)rightContext
    contextMessages:(NSArray *)messages apiKey:(NSString *)key preferredModel:(NSString *)model
    progress:(CPARemoteCompletionProgressHandler)progress completion:(CPARemoteCompletionHandler)finish {
    self.sentRight = rightContext;
    return [self requestCompletionForInput:input contextMessages:messages apiKey:key preferredModel:model progress:progress completion:finish];
}
- (void)invalidateCompletionCache { self.clears++; [super invalidateCompletionCache]; }
@end
@interface CPALifecycleDelegate : CPAAppDelegate
@property(nonatomic, strong) CPAAccessibilitySnapshot *fixture;
@property(nonatomic, copy) void (^freshCompletion)(CPAAccessibilitySnapshot *);
@end
@implementation CPALifecycleDelegate
- (CPAAccessibilitySnapshot *)updateStatus { return self.fixture; }
- (CPAAccessibilitySnapshot *)snapshotForSuggestion { return self.fixture; }
- (CPAAccessibilitySnapshot *)snapshotForStreamingSuggestion { return self.fixture; }
- (void)requestCodexSnapshotRefresh {}
- (CPAAccessibilitySnapshot *)decorateCodexSnapshot:(CPAAccessibilitySnapshot *)snapshot { return snapshot; }
- (void)requestAcceptanceSnapshotForBundleIdentifier:(NSString *)bundle
    processIdentifier:(pid_t)pid completion:(void (^)(CPAAccessibilitySnapshot *))completion {
    (void)bundle; (void)pid; self.freshCompletion = completion;
}
@end

@interface CPALifecycleKeyboard : CPAKeyboardInterceptor
@property(nonatomic) NSUInteger posted;
@property(nonatomic, copy) NSString *inserted;
@end
@implementation CPALifecycleKeyboard
- (BOOL)inputMethodCompositionProbablyActive { return NO; }
- (BOOL)postText:(NSString *)text toProcessIdentifier:(pid_t)pid {
    Verify(pid == 42, @"delivery uses the verified target PID");
    self.posted++; self.inserted = text; return YES;
}
@end

@interface CPAExpressionPauseStore : CPADataFoundationController
@property(nonatomic) NSUInteger lookups;
@end
@implementation CPAExpressionPauseStore
- (NSString *)suggestionForInput:(NSString *)input cursorLocation:(NSUInteger)cursor selectedLength:(NSUInteger)selected {
    (void)input; (void)cursor; (void)selected; self.lookups++;
    return @"仅记录可核查的对应关系。";
}
@end

static CPALifecycleClient *Client(void) {
    return [[CPALifecycleClient alloc] initWithBaseURL:[NSURL URLWithString:@"http://127.0.0.1:1"]
        sessionConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
        callbackQueue:dispatch_get_main_queue()];
}
static CPARemoteCompletionResult *Result(NSString *text) {
    CPARemoteCompletionResult *result = [CPARemoteCompletionResult new];
    [result setValue:text forKey:@"insertionText"];
    return result;
}
static CPALifecycleDelegate *Delegate(void) {
    CPALifecycleDelegate *app = [CPALifecycleDelegate new];
    app.suggestionCoordinator = [[CPALocalSuggestionCoordinator alloc] initWithLookup:
        ^NSString *(NSString *text, NSUInteger cursor, NSUInteger selection) {
            (void)text; (void)cursor; (void)selection; return nil;
        }];
    app.overlayController = [CPALifecycleOverlay new];
    app.keyboardInterceptor = [CPALifecycleKeyboard new];
    app.localModelClient = Client(); app.remoteClient = Client();
    CPAAccessibilitySnapshot *s = [CPAAccessibilitySnapshot new];
    s.inputText = @"请核对当前输入字段的映射，";
    s.targetBundleIdentifier = @"com.apple.TextEdit";
    s.targetProcessIdentifier = 42; s.targetFieldIdentity = @"synthetic-field";
    s.targetApplicationIsFrontmost = YES; s.writableTextInput = YES;
    s.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalAndRemote;
    s.hasSelectedRange = YES; s.hasValueCharacterCount = YES;
    s.valueCharacterCount = s.inputText.length; s.selectedLocation = s.inputText.length;
    s.hasCaretBounds = YES; s.caretBounds = CGRectMake(10, 10, 1, 20);
    app.fixture = s; app.lastObservedInputText = s.inputText;
    app.cachedFrontmostBundleIdentifier = s.targetBundleIdentifier;
    app.cachedFrontmostProcessIdentifier = 42;
    app.lastObservedSignature = [app signatureForSnapshot:s];
    return app;
}
static void StartBoth(CPALifecycleDelegate *app) {
    NSString *signature = [app signatureForSnapshot:app.fixture];
    app.lastObservedSignature = signature;
    [app startLocalModelSuggestionForSnapshot:app.fixture signature:signature];
    [app issueRemoteSuggestionForInput:app.fixture.inputText originalInput:app.fixture.inputText
        signature:signature apiKey:@"synthetic-key" preferredModel:@"fixture"
        conversationGeneration:app.conversationGeneration
        contextGeneration:[app completionContextForSnapshot:app.fixture].revision];
}
static void DeletionPauseReplay(void) {
    for (NSString *mode in @[@"stable", @"edited", @"focus", @"selection", @"conversation"]) {
        CPALifecycleDelegate *app = Delegate();
        NSString *suite = [@"cpa-deletion-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        app.remoteSettings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:[CPAKeychainStore new] userDefaults:defaults];
        app.remoteSettings.onlineOnly = YES; app.remoteSettings.paused = NO;
        app.cachedAPIKey = @"synthetic-key";
        app.latestObservedEditWasDeletion = YES;
        app.lastObservedInputChangeDate = NSDate.date;
        [app scheduleModelSuggestionsForSnapshot:app.fixture signature:app.lastObservedSignature delay:0];
        Verify(app.suggestionTimer != nil && app.modelSuggestionTimer == nil,
            @"deletion schedules a bounded retry without immediately requesting a model");
        NSTimer *retry = app.suggestionTimer;
        app.lastObservedInputChangeDate = [NSDate dateWithTimeIntervalSinceNow:-1];
        if ([mode isEqual:@"edited"]) app.fixture.inputText = @"新的合成草稿";
        if ([mode isEqual:@"focus"]) app.fixture.targetApplicationIsFrontmost = NO;
        if ([mode isEqual:@"selection"]) app.fixture.selectedLength = 2;
        if ([mode isEqual:@"conversation"]) app.conversationGeneration++;
        if (retry) [app showAutomaticSuggestion:retry];
        if (app.modelSuggestionTimer) [app startDelayedRemoteModelSuggestions:app.modelSuggestionTimer];
        Verify(((CPALifecycleClient *)app.remoteClient).requests == ([mode isEqual:@"stable"] ? 1 : 0),
            @"stable deletion resumes once; edits, focus loss, selection and conversation changes cannot dispatch stale work");
        [app cancelPendingSuggestionForReason:@"test_end"];
        [defaults removePersistentDomainForName:suite];
    }
}

static void IndependentProviderReplay(void) {
    for (NSString *mode in @[@"valid", @"stale", @"policy", @"paused"]) {
        CPALifecycleDelegate *app = Delegate();
        NSString *suite = [@"cpa-independent-providers-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        app.remoteSettings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:[CPAKeychainStore new] userDefaults:defaults];
        app.remoteSettings.paused = NO; // This fixture explicitly exercises authorized dual sources.
        app.cachedAPIKey = @"synthetic-key";
        NSString *signature = [app signatureForSnapshot:app.fixture];
        [app startLocalModelSuggestionForSnapshot:app.fixture signature:signature];
        Verify(app.localModelTask != nil, @"local is still decoding at the remote deadline");
        if ([mode isEqual:@"stale"]) app.fixture.targetFieldIdentity = @"another-field";
        if ([mode isEqual:@"policy"]) app.fixture.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalOnly;
        if ([mode isEqual:@"paused"]) app.remoteSettings.paused = YES;
        app.modelSuggestionTimer = [NSTimer timerWithTimeInterval:1 target:app
            selector:@selector(startDelayedRemoteModelSuggestions:) userInfo:signature repeats:NO];
        app.modelSuggestionTimerConversationGeneration = app.conversationGeneration;
        [app startDelayedRemoteModelSuggestions:app.modelSuggestionTimer];
        Verify((app.remoteTask != nil) == [mode isEqual:@"valid"],
            @"remote starts independently of local, subject to current identity, policy and toggle");
        Verify(app.modelSuggestionTimer == nil, @"remote must not poll local completion");
        if ([mode isEqual:@"valid"] && app.remoteTask != nil) {
            ((CPALifecycleClient *)app.remoteClient).finish(Result(@"将找不到来源的条目保留为待确认。"));
            NSString *shown = [((CPALifecycleOverlay *)app.overlayController).text copy];
            Verify(shown.length > 0, @"remote can publish before local finishes");
            ((CPALifecycleClient *)app.localModelClient).finish(Result(@"请标明需要进一步核实的对应关系。"));
            Verify([shown isEqual:((CPALifecycleOverlay *)app.overlayController).text], @"late local result cannot replace the visible remote candidate");
        }
        [app cancelPendingSuggestionForReason:@"test_end"];
        [defaults removePersistentDomainForName:suite];
    }
}

// Production acceptance/readback/debounce/dispatch with synthetic chat/document snapshots.
static void RepeatedContinuationReplay(BOOL document) {
    CPALifecycleDelegate *app = Delegate();
    NSString *suite = [@"cpa-repeat-continuation-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    app.remoteSettings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:[CPAKeychainStore new] userDefaults:defaults];
    app.remoteSettings.onlineOnly = YES; app.remoteSettings.paused = NO;
    app.cachedAPIKey = @"synthetic-key";
    app.fixture.targetBundleIdentifier = document ? @"com.electron.lark" : @"com.openai.codex";
    app.fixture.documentContinuation = document;
    app.cachedFrontmostBundleIdentifier = app.fixture.targetBundleIdentifier;
    app.lastObservedSignature = [app signatureForSnapshot:app.fixture];
    CPALifecycleClient *client = (id)app.remoteClient;
    [app startRemoteSuggestionForSnapshot:app.fixture signature:app.lastObservedSignature];
    Verify(client.requests == 1 && client.finish != nil, @"first Codex request reaches the provider");
    Verify(!client.continuationAfterAcceptance, @"first request must not claim an accepted continuation");
    if (client.finish) client.finish(Result(@"将找不到来源的条目保留为待确认。"));
    Verify(app.overlayController.visible, @"first candidate is visible");
    [app keyboardInterceptorDidRequestAccept];
    if (app.freshCompletion) app.freshCompletion(app.fixture);
    CPALifecycleKeyboard *keyboard = (id)app.keyboardInterceptor;
    Verify(keyboard.posted == 1, @"first candidate is accepted once");
    app.fixture.inputText = [app.fixture.inputText stringByAppendingString:keyboard.inserted ?: @""];
    app.fixture.valueCharacterCount = app.fixture.inputText.length;
    app.fixture.selectedLocation = app.fixture.inputText.length;
    [app pollAccessibility:nil];
    Verify(app.programmaticInsertionExpectedInput == nil && app.suggestionTimer != nil,
        @"matched readback schedules the next candidate");
    Verify(app.suggestionTimer.fireDate.timeIntervalSinceNow <= 0.20,
        @"verified insertion should use ordinary debounce instead of the full accept cooldown");
    if (app.suggestionTimer) [app.suggestionTimer fire];
    if (app.modelSuggestionTimer) [app.modelSuggestionTimer fire];
    Verify(client.requests == 2 && [client.sentInput isEqual:app.fixture.inputText],
        @"accepted sentence ending in punctuation reaches the provider again");
    Verify(client.continuationAfterAcceptance, @"matched acceptance must reach the provider as a next continuation, not an ordinary first completion");
    if (client.requests == 2 && client.finish) client.finish(Result(@"请说明字段映射的核对依据。"));
    Verify(app.overlayController.visible, @"second eligible candidate can display after Tab");
    [app keyboardInterceptorDidRequestAccept];
    if (app.freshCompletion) app.freshCompletion(app.fixture);
    app.fixture.inputText = [app.fixture.inputText stringByAppendingString:keyboard.inserted ?: @""];
    app.fixture.valueCharacterCount = app.fixture.inputText.length;
    app.fixture.selectedLocation = app.fixture.inputText.length;
    [app pollAccessibility:nil];
    if (app.suggestionTimer) [app.suggestionTimer fire];
    if (app.modelSuggestionTimer) [app.modelSuggestionTimer fire];
    Verify(keyboard.posted == 2 && client.requests == 3 && client.continuationAfterAcceptance,
        @"a second accepted sentence also requests the next continuation");
    if (client.finish) client.finish(Result(@""));
    [app pollAccessibility:nil];
    Verify(client.requests == 3 && !app.overlayController.visible,
        @"empty continuation does not insert filler or spin requests on unchanged input");
    CPALifecycleDelegate *unconfirmed = Delegate();
    unconfirmed.lastObservedSignature = nil;
    unconfirmed.lastSuggestionAcceptedDate = NSDate.date;
    unconfirmed.programmaticInsertionExpectedInput = @"synthetic expected insertion not observed";
    [unconfirmed pollAccessibility:nil];
    Verify(unconfirmed.lastSuggestionAcceptedDate != nil
        && unconfirmed.suggestionTimer.fireDate.timeIntervalSinceNow > 0.40,
        @"mismatched insertion readback must retain the conservative cooldown");
    [unconfirmed cancelPendingSuggestionForReason:@"fixture_cleanup"];

    app.fixture.inputText = @"需要把appstore去掉，并核实可选列表中不再显示 App Store。还有现在为什么不会接着提示后面的了";
    app.fixture.valueCharacterCount = app.fixture.inputText.length;
    app.fixture.selectedLocation = app.fixture.inputText.length;
    [app pollAccessibility:nil];
    if (app.suggestionTimer) [app.suggestionTimer fire];
    if (app.modelSuggestionTimer) [app.modelSuggestionTimer fire];
    Verify(client.requests == 4 && [client.sentInput isEqual:app.fixture.inputText],
        @"manual second sentence containing why reaches a new provider request");
    Verify(!client.continuationAfterAcceptance, @"manual edits must clear the accepted-continuation mode");
    if (document) {
        app.fixture.inputText = @"页面响应取决于处理时间与展示等待。";
        app.fixture.valueCharacterCount = app.fixture.inputText.length;
        app.fixture.selectedLocation = app.fixture.inputText.length;
        [app pollAccessibility:nil];
        if (app.suggestionTimer) [app.suggestionTimer fire];
        if (app.modelSuggestionTimer) [app.modelSuggestionTimer fire];
        Verify(client.requests == 5 && client.documentContinuation && !client.continuationAfterAcceptance,
            @"manually typed full stop dispatches ordinary document continuation without pretending acceptance");
        if (client.finish) client.finish(Result(@"两个环节共同影响用户感受到的等待时间。"));
        Verify(app.overlayController.visible, @"eligible ordinary document sentence can display after punctuation");
    }

    [app resetSuggestionStateForConversationBoundaryWithTitle:nil reason:@"fixture"];
    Verify(app.acceptedContinuationSignature == nil && app.acceptedContinuationInput == nil,
        @"conversation boundary must discard accepted-stage identity");
    [app cancelPendingSuggestionForReason:@"test_end"];
    [defaults removePersistentDomainForName:suite];
}

static void MiddleInsertionReplay(void) {
    for (NSString *bundle in @[@"com.electron.lark", @"com.google.Chrome"])
    for (NSString *mode in @[@"accept", @"right_changed", @"cursor_changed", @"late_right_changed", @"document_changed", @"host_changed"]) {
        CPALifecycleDelegate *app = Delegate();
        NSString *suite = [@"cpa-middle-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        app.remoteSettings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:[CPAKeychainStore new] userDefaults:defaults];
        app.remoteSettings.onlineOnly = YES; app.remoteSettings.paused = NO; app.cachedAPIKey = @"synthetic-key";
        app.fixture.targetBundleIdentifier = bundle; app.cachedFrontmostBundleIdentifier = bundle;
        app.fixture.browserHost = [bundle isEqual:@"com.google.Chrome"] ? @"tenant.feishu.cn" : @"";
        app.fixture.inputText = @"请说明的原因。后续段落保持原样。";
        app.fixture.selectedLocation = 3; app.fixture.valueCharacterCount = app.fixture.inputText.length;
        app.lastObservedInputText = app.fixture.inputText; app.lastObservedSignature = [app signatureForSnapshot:app.fixture];
        [app showSuggestionForSnapshot:app.fixture automatic:YES];
        if (app.modelSuggestionTimer) [app.modelSuggestionTimer fire];
        CPALifecycleClient *client = (id)app.remoteClient;
        Verify(client.requests == 1 && [client.sentInput isEqual:@"请说明"] && [client.sentRight isEqual:@"的原因。后续段落保持原样。"],
            @"Feishu middle insertion dispatches both cursor sides");
        if ([mode isEqual:@"late_right_changed"]) app.fixture.inputText = @"请说明的原因。后续段落已经更改。";
        if (client.finish) client.finish(Result(@"接口超时"));
        if ([mode isEqual:@"late_right_changed"]) Verify(!app.overlayController.visible, @"right edits invalidate late model output");
        else {
            Verify(app.overlayController.visible, @"short connecting insertion is shown in the middle");
            [app keyboardInterceptorDidRequestAccept];
            if ([mode isEqual:@"right_changed"]) app.fixture.inputText = @"请说明的原因。后续段落已经更改。";
            if ([mode isEqual:@"cursor_changed"]) app.fixture.selectedLocation++;
            if ([mode isEqual:@"document_changed"]) app.fixture.targetFieldIdentity = @"other-document-token";
            if ([mode isEqual:@"host_changed"]) app.fixture.browserHost = @"unselected.example.com";
            if (app.freshCompletion) app.freshCompletion(app.fixture);
            CPALifecycleKeyboard *keyboard = (id)app.keyboardInterceptor;
            Verify(keyboard.posted == ([mode isEqual:@"accept"] ? 1 : 0), @"fresh acceptance validates right context and cursor");
            if ([mode isEqual:@"accept"]) Verify([app.programmaticInsertionExpectedInput isEqual:@"请说明接口超时的原因。后续段落保持原样。"],
                @"insertion preserves all existing right-hand text");
        }
        [app cancelPendingSuggestionForReason:@"test_end"]; [defaults removePersistentDomainForName:suite];
    }
}

static void UnreadableCandidateReplay(void) {
    CPALifecycleDelegate *app = Delegate();
    CPALifecycleOverlay *overlay = (id)app.overlayController;
    overlay.cannotFit = YES;
    NSString *candidate = @"将找不到来源的条目保留为待确认。";
    Verify(![app displayInsertionText:candidate snapshot:app.fixture trigger:@"remote_show"],
        @"a candidate that cannot fit must not report successful publication");
    Verify(!overlay.visible && app.displayedSuggestionSignature == nil,
        @"layout refusal must release the candidate identity");
    Verify([app.suggestionCoordinator consumeInsertionForSignature:
        [app signatureForSnapshot:app.fixture]].length == 0,
        @"unreadable text must not remain a Tab insertion target");
    Verify(![app keyboardInterceptorShouldHandleSuggestionKeys],
        @"hidden candidate leaves the host Tab key untouched");
    overlay.cannotFit = NO;
    Verify([app displayInsertionText:candidate snapshot:app.fixture trigger:@"remote_show"],
        @"a later readable candidate can publish without editing or restarting");
    [app cancelPendingSuggestionForReason:@"test_end"];
}

static void LocalStartupStatusReplay(void) {
    CPALifecycleDelegate *app = Delegate();
    app.lastLocalCompletionMenuItem = [[NSMenuItem alloc] initWithTitle:@"暂无请求"
        action:nil keyEquivalent:@""];
    CPALifecycleClient *client = (id)app.localModelClient;
    [app warmLocalModel];
    Verify(app.localModelWarmupTask != nil, @"existing startup request is exercised without real networking");
    CPARemoteCompletionResult *failure = Result(@"");
    [failure setValue:@(CPARemoteCompletionOutcomeTransportError) forKey:@"outcome"];
    [failure setValue:@"synthetic-private-error-not-for-ui" forKey:@"errorMessage"];
    client.finish(failure);
    Verify([app.lastLocalCompletionMenuItem.title isEqual:@"本机启动检查：无法连接服务"],
        @"startup connection failure must reach the existing settings status, without raw error text");
    Verify([[[app settingsState] objectForKey:@"localResult"] isEqual:app.lastLocalCompletionMenuItem.title],
        @"the production state provider forwards startup failure to settings");

    [app warmLocalModel];
    CPARemoteCompletionHandler stale = client.finish;
    [app cancelLocalModelWarmupIfPending];
    app.lastLocalCompletionMenuItem.title = @"上次本地请求：新的输入结果";
    stale(failure);
    Verify([app.lastLocalCompletionMenuItem.title isEqual:@"上次本地请求：新的输入结果"],
        @"cancelled startup reply cannot overwrite a newer user request status");

    [app warmLocalModel];
    CPARemoteCompletionResult *cancelled = Result(@"");
    [cancelled setValue:@(CPARemoteCompletionOutcomeCancelled) forKey:@"outcome"];
    client.finish(cancelled);
    Verify([app.lastLocalCompletionMenuItem.title isEqual:@"上次本地请求：新的输入结果"],
        @"startup cancellation must not be reported as a service problem");

    [app warmLocalModel];
    client.finish(Result(@"合成预热内容不可作为用户候选"));
    Verify([app.lastLocalCompletionMenuItem.title isEqual:@"本机启动检查：服务曾响应"],
        @"startup success records only a response, not user-facing candidate acceptance");
    Verify(!app.overlayController.visible && app.displayedSuggestionSignature == nil,
        @"startup replies never publish a candidate or reserve Tab");
    [app cancelPendingSuggestionForReason:@"test_end"];
}
static void AuthorRoutingReplay(void) {
    for (NSNumber *remoteAllowed in @[@NO, @YES]) {
        for (NSNumber *remotePaused in @[@NO, @YES]) {
            CPALifecycleDelegate *app = Delegate();
            NSString *suite = [@"cpa-author-routing-" stringByAppendingString:NSUUID.UUID.UUIDString];
            NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
            app.remoteSettings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:[CPAKeychainStore new] userDefaults:defaults];
            app.remoteSettings.paused = remotePaused.boolValue;
            app.fixture.suggestionPolicyOutcome = remoteAllowed.boolValue
                ? CPASuggestionPolicyOutcomeLocalAndRemote : CPASuggestionPolicyOutcomeLocalOnly;
            NSString *signature = [app signatureForSnapshot:app.fixture];
            app.lastObservedSignature = signature;
            [app startLocalModelSuggestionForSnapshot:app.fixture signature:signature];
            Verify(app.localModelTask != nil, @"enabled local path remains available");
            Verify(app.localModelClient.literalContinuationsOnly == (remoteAllowed.boolValue && !remotePaused.boolValue),
                @"only authorized dual mode delegates open authoring to remote");
            Verify(app.remoteSettings.paused == remotePaused.boolValue && !app.remoteSettings.localPaused,
                @"routing must not change either user toggle");
            [app cancelPendingSuggestionForReason:@"test_end"];
            [defaults removePersistentDomainForName:suite];
        }
    }
}
static void ExpressionPauseReplay(void) {
    CPALifecycleDelegate *app = Delegate();
    NSString *suite = [@"cpa-expression-pause-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    app.remoteSettings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:[CPAKeychainStore new] userDefaults:defaults];
    [app configureDataFoundation];
    NSURL *fixtureURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:suite]];
    CPAExpressionPauseStore *store = [[CPAExpressionPauseStore alloc] initWithActiveDirectory:fixtureURL
        archivedDirectory:fixtureURL databaseURL:[fixtureURL URLByAppendingPathComponent:@"synthetic.sqlite"]
        masterKeyProvider:^NSData *(NSError **error) { (void)error; return nil; }
        callbackQueue:dispatch_get_main_queue()];
    app.dataController = store;
    NSString *signature = [app signatureForSnapshot:app.fixture];
    app.remoteSettings.paused = NO; // Both providers are explicitly enabled for this independence replay.
    app.remoteSettings.expressionLibraryPaused = YES;
    NSString *value = [app.suggestionCoordinator automaticInsertionForSnapshot:app.fixture signature:signature];
    Verify(value == nil && store.lookups == 0, @"paused expression library must not be queried");
    StartBoth(app);
    Verify(((CPALifecycleClient *)app.localModelClient).finish != nil && ((CPALifecycleClient *)app.remoteClient).finish != nil,
        @"expression pause keeps both model request paths available");
    [app cancelPendingSuggestionForReason:@"test_end"];
    app.remoteSettings.expressionLibraryPaused = NO;
    value = [app.suggestionCoordinator automaticInsertionForSnapshot:app.fixture signature:signature];
    Verify(value.length > 0 && store.lookups == 1, @"resuming expression lookup keeps stored expressions available");
    [defaults removePersistentDomainForName:suite];
}

static void CandidateReplays(void) {
    for (NSNumber *changed in @[@NO, @YES]) {
        CPALifecycleDelegate *app = Delegate();
        app.fixture.inputText = @"我希望先了解如何";
        app.fixture.valueCharacterCount = app.fixture.inputText.length;
        app.fixture.selectedLocation = app.fixture.inputText.length;
        app.lastObservedInputText = app.fixture.inputText;
        NSArray *h = @[@{@"role":@"user", @"content":@"取消之前方案，改为只改颜色，不动布局。"}];
        NSString *literal = CPAExplicitUserScopeContinuation(app.fixture.inputText, h);
        Verify([app displayInsertionText:literal snapshot:app.fixture trigger:@"local_model_show"],
            @"explicit user scope passes normal publication checks");
        [app keyboardInterceptorDidRequestAccept];
        if (changed.boolValue) app.fixture.targetFieldIdentity = @"another-field";
        app.freshCompletion(app.fixture);
        CPALifecycleKeyboard *keyboard = (id)app.keyboardInterceptor;
        Verify(keyboard.posted == (changed.boolValue ? 0 : 1), @"user scope cannot bypass final field ownership checks");
        if (!changed.boolValue) Verify([keyboard.inserted isEqual:@"只改颜色，不动布局。"],
            @"Tab preserves the user's action and exclusion without the cancelled plan");
        [app cancelPendingSuggestionForReason:@"test_end"];
    }
    for (NSNumber *changed in @[@NO, @YES]) {
        CPALifecycleDelegate *app = Delegate();
        app.fixture.inputText = @"我希望先了解如何";
        app.fixture.valueCharacterCount = app.fixture.inputText.length;
        app.fixture.selectedLocation = app.fixture.inputText.length;
        app.lastObservedInputText = app.fixture.inputText;
        NSArray *h = @[@{@"role":@"assistant", @"content":@"第一项是修改颜色，第二项是保留草稿。"},
            @{@"role":@"user", @"content":@"只做你提到的第二项。"}];
        NSString *literal = CPAExplicitOptionContinuation(app.fixture.inputText, h);
        Verify([app displayInsertionText:literal snapshot:app.fixture trigger:@"local_model_show"],
            @"literal selected option still passes normal publication checks");
        [app keyboardInterceptorDidRequestAccept];
        if (changed.boolValue) app.fixture.targetFieldIdentity = @"another-field";
        app.freshCompletion(app.fixture);
        CPALifecycleKeyboard *keyboard = (id)app.keyboardInterceptor;
        Verify(keyboard.posted == (changed.boolValue ? 0 : 1), @"literal option cannot bypass final input ownership checks");
        if (!changed.boolValue) Verify([keyboard.inserted isEqual:@"保留草稿。"], @"Tab inserts the exact chosen action without expansion");
        [app cancelPendingSuggestionForReason:@"test_end"];
    }
    // A rejected proposal must not reserve the display or Tab target. Exercise
    // both provider orders; this tests publication, not semantic entailment.
    for (NSString *trigger in @[@"local_model_show", @"remote_show"]) {
        CPALifecycleDelegate *app = Delegate();
        app.fixture.inputText = @"为什么测试任务停止了，";
        app.fixture.valueCharacterCount = app.fixture.inputText.length;
        app.fixture.selectedLocation = app.fixture.inputText.length;
        app.lastObservedInputText = app.fixture.inputText;
        Verify(![app displayInsertionText:@"暂无明确结论，需结合模拟日志与操作记录进一步核查。"
            snapshot:app.fixture trigger:trigger],
            @"an answer to a separator-terminated question is rejected at publication for either provider");
        Verify(!app.overlayController.visible && app.displayedSuggestionSignature == nil,
            @"rejected question answer never becomes a visible candidate or Tab target");
        [app cancelPendingSuggestionForReason:@"test_end"];
    }
    for (NSNumber *localFirst in @[@YES, @NO]) {
        CPALifecycleDelegate *app = Delegate();
        app.fixture.inputText = @"我希望先了解";
        app.fixture.valueCharacterCount = app.fixture.inputText.length;
        app.fixture.selectedLocation = app.fixture.inputText.length;
        app.lastObservedInputText = app.fixture.inputText;
        StartBoth(app);
        CPALifecycleClient *first = localFirst.boolValue ? (id)app.localModelClient : (id)app.remoteClient;
        CPALifecycleClient *second = localFirst.boolValue ? (id)app.remoteClient : (id)app.localModelClient;
        first.finish(Result(@"由于旧回调未移除所以需要检查是否重复注册。"));
        Verify(!app.overlayController.visible && app.displayedSuggestionSignature == nil,
            @"causal answer rejected without claiming the display slot");
        NSString *valid = @"是否因为旧回调未移除而导致重复。";
        second.finish(Result(valid));
        Verify(app.overlayController.visible
            && [[app.suggestionCoordinator consumeInsertionForSignature:[app signatureForSnapshot:app.fixture]] isEqual:valid],
            @"either provider can supply the first qualified candidate after the other is rejected");
        [app cancelPendingSuggestionForReason:@"test_end"];
    }
    for (NSString *late in @[@"并明确输出格式，我可以根据需求调整细节。",
            @"仅记录能定位到来源的对应关系。", @""]) {
        CPALifecycleDelegate *app = Delegate(); StartBoth(app);
        CPALifecycleClient *local = (id)app.localModelClient, *remote = (id)app.remoteClient;
        Verify(local.finish != nil && remote.finish != nil, @"both synthetic requests issued");
        NSString *first = @"将找不到来源的条目保留为待确认。";
        local.finish(Result(first));
        CPALifecycleOverlay *overlay = (id)app.overlayController;
        Verify(overlay.visible, @"first qualified candidate displayed");
        remote.finish(Result(late));
        Verify(overlay.visible && overlay.shows == 1 && [overlay.text isEqual:first],
            @"late reject, better result or empty result preserves first qualified display");
        Verify([[app.suggestionCoordinator consumeInsertionForSignature:
            [app signatureForSnapshot:app.fixture]] isEqual:first], @"Tab target remains first candidate");
        [app cancelPendingSuggestionForReason:@"test_end"];
    }

    for (NSUInteger event = 0; event < 6; event++) {
        CPALifecycleDelegate *app = Delegate(); StartBoth(app);
        CPALifecycleClient *local = (id)app.localModelClient, *remote = (id)app.remoteClient;
        NSString *first = @"将找不到来源的条目保留为待确认。";
        if (event < 3) local.finish(Result(first));
        if (event == 0) [app keyboardInterceptorDidRequestDismiss];
        if (event == 1) [app keyboardInterceptorDidRequestAccept];
        if (event == 2) {
            [app keyboardInterceptorDidRequestAccept];
            [app keyboardInterceptorDidRequestDismiss];
        }
        if (event == 3) {
            app.fixture.inputText = @"请核对当前输入字段的别名，"; // same UTF-16 length
            app.lastObservedInputText = app.fixture.inputText;
        }
        if (event == 4) app.fixture.targetFieldIdentity = @"other-field";
        if (event == 5) app.conversationGeneration++;
        remote.finish(Result(@"仅记录能定位到来源的对应关系。"));
        if (event >= 3) local.finish(Result(first));
        Verify(!app.overlayController.visible, @"late completion cannot publish after Esc/Tab/edit/field/task change");
        if (app.freshCompletion != nil) app.freshCompletion(app.fixture);
        CPALifecycleKeyboard *keyboard = (id)app.keyboardInterceptor;
        Verify(keyboard.posted == (event == 1 ? 1 : 0), @"Tab ticket accepts once; Esc cancels its pending read");
        if (event == 1) Verify([keyboard.inserted isEqual:first], @"late candidate cannot replace the accepted text");
        [app cancelPendingSuggestionForReason:@"test_end"];
    }

    for (NSUInteger boundary = 0; boundary < 7; boundary++) {
        CPALifecycleDelegate *app = Delegate(); StartBoth(app);
        ((CPALifecycleClient *)app.localModelClient).finish(Result(@"将找不到来源的条目保留为待确认。"));
        if (boundary == 0) app.fixture.selectedLocation--;
        if (boundary == 1) app.fixture.selectedLength = 1;
        if (boundary == 2) app.fixture.targetApplicationIsFrontmost = NO;
        if (boundary == 3) app.fixture.policyRuleVersion++;
        if (boundary == 4) app.fixture.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeDisabled;
        if (boundary == 5) app.fixture.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalOnly;
        if (boundary == 6) app.fixture.contextAccessMode = CPAContextAccessModeCurrentInputOnly;
        [app pollAccessibility:nil];
        Verify(!app.overlayController.visible, @"cursor, selection, focus and rule boundaries revoke display");
        [app cancelPendingSuggestionForReason:@"test_end"];
    }

    CPALifecycleDelegate *recover = Delegate(); StartBoth(recover);
    recover.fixture.writableTextInput = NO;
    [recover pollAccessibility:nil];
    ((CPALifecycleClient *)recover.localModelClient).finish(Result(@"将找不到来源的条目保留为待确认。"));
    ((CPALifecycleClient *)recover.remoteClient).finish(Result(@"仅记录能定位到来源的对应关系。"));
    recover.fixture.writableTextInput = YES;
    [recover pollAccessibility:nil];
    Verify(recover.suggestionTimer != nil, @"AX focus recovery rechecks after an undisplayable final result without another edit");
    [recover cancelPendingSuggestionForReason:@"test_end"];
}

static void WriteContext(NSURL *file, NSString *text) {
    NSDictionary *record = @{@"type":@"response_item", @"payload":@{
        @"type":@"message", @"role":@"user", @"content":@[@{@"type":@"input_text", @"text":text}]}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    [data writeToURL:file atomically:YES];
}
static void Refresh(CPAConversationContextProvider *provider) {
    dispatch_queue_t queue = [provider valueForKey:@"queue"];
    dispatch_sync(queue, ^{ [provider refreshLocked]; });
}
static void DrainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    while (!drained) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static void ContextDependentReplays(CPAConversationContextProvider *provider, NSURL *file) {
    for (NSNumber *useRemote in @[@NO, @YES]) {
        for (NSArray *item in @[
                @[@"请将刚才提到的颜色填入配置，颜色为", @"刚才指定的颜色是浅蓝色。", @"浅蓝色"],
                @[@"这次段落改写的", @"我观察到这次段落改写把疑问句误写成了结论。", @"问题在于把疑问句误写成了结论。"],
                @[@"我观察到离线补全的文字前后意思接不上，只是在记录这一现象。\n离线补全生成的", @"合成上下文。", @"文字前后意思接不上。"]]) {
            WriteContext(file, item[1]); Refresh(provider); DrainMainQueue();
            CPALifecycleDelegate *app = Delegate(); app.contextProvider = provider;
            app.fixture.inputText = item[0]; app.lastObservedInputText = item[0];
            app.fixture.selectedLocation = [item[0] length];
            app.fixture.valueCharacterCount = [item[0] length];
            app.fixture.contextAccessMode = CPAContextAccessModeCodexConversation;
            app.fixture.targetBundleIdentifier = @"com.openai.codex";
            app.cachedFrontmostBundleIdentifier = @"com.openai.codex";
            __weak CPALifecycleDelegate *weak = app;
            provider.snapshotDidChange = ^{ [weak conversationContextDidChange]; };
            StartBoth(app);
            CPALifecycleClient *client = useRemote.boolValue ? (id)app.remoteClient : (id)app.localModelClient;
            Verify(client.finish != nil, @"grounded synthetic request starts");
            if (client.finish) client.finish(Result(item[2]));
            Verify(app.overlayController.visible && [((CPALifecycleOverlay *)app.overlayController).text isEqual:item[2]],
                @"shared display gate preserves the exact grounded suffix");
            WriteContext(file, @"当前材料已经变更。" ); Refresh(provider); DrainMainQueue();
            Verify(!app.overlayController.visible, @"grounded exception does not bypass context revision invalidation");
            [app cancelPendingSuggestionForReason:@"test_end"];
        }
    }
    for (NSUInteger scenario = 0; scenario < 5; scenario++) {
        CPALifecycleDelegate *app = Delegate(); app.contextProvider = provider;
        if (scenario != 0) {
            app.fixture.contextAccessMode = CPAContextAccessModeCodexConversation;
            app.fixture.targetBundleIdentifier = @"com.openai.codex";
            app.cachedFrontmostBundleIdentifier = @"com.openai.codex";
        }
        __weak CPALifecycleDelegate *weak = app;
        provider.snapshotDidChange = ^{ [weak conversationContextDidChange]; };
        StartBoth(app);
        CPALifecycleClient *local = (id)app.localModelClient, *remote = (id)app.remoteClient;
        Verify(local.sentMessages.count == (scenario == 0 ? 0 : 1), @"request dependency follows actual supplied history");
        if (scenario == 4) [app displayInsertionText:@"将找不到来源的条目保留为待确认。"
            snapshot:app.fixture trigger:@"history_fixture"];
        else if (scenario != 1) local.finish(Result(@"将找不到来源的条目保留为待确认。"));
        if (scenario == 3) [app keyboardInterceptorDidRequestAccept];
        WriteContext(file, [NSString stringWithFormat:@"合成上下文修订 %lu", (unsigned long)scenario]);
        Refresh(provider); DrainMainQueue();
        if (scenario == 1) local.finish(Result(@"将找不到来源的条目保留为待确认。"));
        remote.finish(Result(@"仅记录能定位到来源的对应关系。"));
        if (scenario == 4) [app pollAccessibility:nil];
        Verify(app.overlayController.visible == (scenario == 0 || scenario == 4), @"history update revokes dependent requests/display but preserves draft-only candidate, including next poll");
        if (scenario == 3 && app.freshCompletion) app.freshCompletion(app.fixture);
        Verify(((CPALifecycleKeyboard *)app.keyboardInterceptor).posted == 0, @"changed context cannot pass a pending Tab read");
        [app cancelPendingSuggestionForReason:@"test_end"];
        provider.snapshotDidChange = nil;
    }
}
static void ContextReplays(void) {
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"c1-context-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file = [dir URLByAppendingPathComponent:@"thread.jsonl"];
    NSURL *dbURL = [dir URLByAppendingPathComponent:@"state.sqlite"];
    WriteContext(file, @"只检查字段 A");
    sqlite3 *db = NULL; sqlite3_open(dbURL.fileSystemRepresentation, &db);
    sqlite3_exec(db, "CREATE TABLE threads (id TEXT, rollout_path TEXT, name TEXT, title TEXT, archived INTEGER, recency_at_ms INTEGER)", NULL, NULL, NULL);
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(db, "INSERT INTO threads VALUES ('a', ?, 'test', 'test', 0, 1)", -1, &stmt, NULL);
    sqlite3_bind_text(stmt, 1, file.path.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt); sqlite3_finalize(stmt); sqlite3_close(db);
    CPALifecycleContextProvider *p = [[CPALifecycleContextProvider alloc] initWithSessionsDirectoryURL:dir stateDatabaseURL:dbURL];
    [p selectConversationWithTitle:@"test"]; Refresh(p);
    Verify(p.cachedContextMessages.count == 1, @"initial selected context loaded");
    NSUInteger version = p.contextGeneration;
    WriteContext(file, @"只检查字段 B，新增合成要求"); Refresh(p);
    Verify([p.cachedContextMessages.firstObject[@"content"] containsString:@"字段 B"], @"same task refresh reads new content");
    Verify(p.contextGeneration > version, @"same task content change invalidates old revision");
    version = p.contextGeneration;
    Refresh(p);
    Verify(p.contextGeneration == version, @"unchanged refresh does not churn revision");
    CPAConversationContextSnapshot *fixed = p.currentSnapshot;
    WriteContext(file, @"只检查字段 B，新增合成要求"); Refresh(p);
    Verify(p.currentSnapshot == fixed, @"rewritten identical content retains the immutable publication");
    WriteContext(file, @"只检查字段 C，新增合成要求"); Refresh(p);
    Verify(p.currentSnapshot.revision > fixed.revision
        && p.currentSnapshot.selectionGeneration == fixed.selectionGeneration,
        @"same-length selected content edit advances content revision only");
    Verify([fixed.messages.firstObject[@"content"] containsString:@"字段 B"], @"retained snapshots cannot change under an active request");
    ContextDependentReplays(p, file);
    NSString *longMessage = [@"原始目标" stringByPaddingToLength:700 withString:@"合成材料" startingAtIndex:0];
    WriteContext(file, longMessage); Refresh(p);
    Verify([p.currentSnapshot.truncatedMessageIndexes containsIndex:0]
        && p.currentSnapshot.messages.firstObject[@"content"].length <= 400, @"snapshot records truncation without changing the budget");
    [NSFileManager.defaultManager removeItemAtURL:file error:nil]; Refresh(p);
    Verify(p.currentSnapshot.availability == CPAContextAvailabilityError
        && p.currentSnapshot.messages.count == 0, @"read failure is not a successful empty context");
    [@"[]" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]; Refresh(p);
    Verify(p.currentSnapshot.availability == CPAContextAvailabilityError, @"malformed record is unavailable without an exception");
    [@"" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]; Refresh(p);
    Verify(p.currentSnapshot.availability == CPAContextAvailabilityReadyEmpty, @"valid empty context is distinct from read failure");
    WriteContext(file, @"恢复后的合成输入"); Refresh(p);
    Verify(p.currentSnapshot.availability == CPAContextAvailabilityReady, @"next refresh recovers without restarting services");
    WriteContext(file, @"读取之前的合成材料");
    p.afterRead = ^{ WriteContext(file, @"读取中途替换的新材料"); };
    Refresh(p);
    Verify(p.currentSnapshot.availability == CPAContextAvailabilityError && p.currentSnapshot.messages.count == 0,
        @"file replacement during reading cannot publish a torn snapshot");
    Refresh(p);
    Verify([p.currentSnapshot.messages.firstObject[@"content"] isEqual:@"读取中途替换的新材料"],
        @"a later coherent read recovers after replacement");
    sqlite3_open(dbURL.fileSystemRepresentation, &db);
    sqlite3_exec(db, "INSERT INTO threads SELECT 'b', rollout_path, name, title, archived, recency_at_ms FROM threads", NULL, NULL, NULL);
    sqlite3_close(db);
    [p selectConversationWithTitle:@"test"]; Refresh(p);
    Verify(p.currentSnapshot.availability == CPAContextAvailabilityAmbiguous && p.currentSnapshot.messages.count == 0,
        @"same-title tasks publish ambiguity instead of guessing an owner");
    [p selectConversationWithTitle:@"missing"]; Refresh(p);
    Verify(p.currentSnapshot.availability == CPAContextAvailabilityMissing, @"missing source is distinct from valid empty history");
    CPAConversationContextProvider *missingDB = [[CPAConversationContextProvider alloc]
        initWithSessionsDirectoryURL:dir stateDatabaseURL:[dir URLByAppendingPathComponent:@"missing.sqlite"]];
    [missingDB selectConversationWithTitle:@"test"]; Refresh(missingDB);
    Verify(missingDB.currentSnapshot.availability == CPAContextAvailabilityError, @"database read failure is not a missing task");
    [p stop]; [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
}
// Use the actual reader fixtures to exercise the reader-to-request boundary.
static void Assert(BOOL condition, NSString *reason) { Verify(condition, reason); }
#include "WorkBuddyContextReaderTests.inc"
static void WorkBuddyReaderToRequestReplay(void) {
    CPAWorkBuddyContextReader *reader = [CPAWorkBuddyContextReader new];
    CPAWBFixture *a = WorkBuddyFlattenedFixture(), *b = WorkBuddyFlattenedFixture();
    b.nodes[@116][@"AXValue"] = @"合成任务乙只核对日期，不处理甲任务。";
    b.nodes[@125][@"AXValue"] = @"乙任务合成对照。";
    CPALifecycleDelegate *app = Delegate();
    app.fixture.targetBundleIdentifier = @"com.tencent.workbuddy.mac";
    app.cachedFrontmostBundleIdentifier = app.fixture.targetBundleIdentifier;
    app.fixture.contextAccessMode = CPAContextAccessModeWorkBuddyConversation;
    app.fixture.workBuddyContext = [reader readComposer:@103 tree:a stillCurrent:^{return YES;}];
    NSArray *aMessages = app.fixture.workBuddyContext[1];
    StartBoth(app);
    Verify([((CPALifecycleClient *)app.localModelClient).sentMessages isEqual:aMessages]
        && [((CPALifecycleClient *)app.remoteClient).sentMessages isEqual:aMessages], @"real reader A material reaches both request paths exactly");
    CPARemoteCompletionHandler lateLocal = ((CPALifecycleClient *)app.localModelClient).finish;
    CPARemoteCompletionHandler lateRemote = ((CPALifecycleClient *)app.remoteClient).finish;
    app.fixture.workBuddyContext = [reader readComposer:@103 tree:b stillCurrent:^{return YES;}];
    [app observeWorkBuddyContext:app.fixture];
    StartBoth(app);
    NSArray *bMessages = @[@{@"role":@"user",@"content":@"合成任务乙只核对日期，不处理甲任务。"},
        @{@"role":@"assistant",@"content":@"乙任务合成对照。"}];
    Verify([((CPALifecycleClient *)app.localModelClient).sentMessages isEqual:bMessages]
        && [((CPALifecycleClient *)app.remoteClient).sentMessages isEqual:bMessages], @"same editor with B history sends exact B and no A text to both clients");
    lateLocal(Result(@"将找不到来源的条目保留为待确认。"));
    lateRemote(Result(@"将找不到来源的条目保留为待确认。"));
    Verify(!app.overlayController.visible, @"both late A results cannot display over current B requests");
    b.nodes[@111][@"AXChildren"] = @[];
    app.fixture.workBuddyContext = [reader readComposer:@103 tree:b stillCurrent:^{return YES;}];
    [app observeWorkBuddyContext:app.fixture];
    Verify([app completionContextForSnapshot:app.fixture] == nil && app.localModelTask == nil && app.remoteTask == nil,
        @"real reader loading transition clears context and both in-flight requests");
    app.fixture.workBuddyContextReadPending = reader.readPending;
    CPARemoteCompletionHandler previous = ((CPALifecycleClient *)app.remoteClient).finish;
    StartBoth(app);
    Verify(app.localModelTask == nil && app.remoteTask == nil
        && ((CPALifecycleClient *)app.remoteClient).finish == previous,
        @"real reader loading state blocks a fresh draft-only request after switching");
    app.fixture.workBuddyContext = [reader readComposer:@103 tree:a stillCurrent:^{return YES;}];
    app.fixture.workBuddyContextReadPending = reader.readPending;
    [app observeWorkBuddyContext:app.fixture];
    StartBoth(app);
    Verify([((CPALifecycleClient *)app.localModelClient).sentMessages isEqual:aMessages]
        && [((CPALifecycleClient *)app.remoteClient).sentMessages isEqual:aMessages], @"return to A restores exact reader history for both clients");
    [app cancelPendingSuggestionForReason:@"test_end"];
}
static void WorkBuddyLifecycleReplays(void) {
    CPALifecycleDelegate *app = Delegate();
    app.fixture.targetBundleIdentifier = @"com.tencent.workbuddy.mac";
    app.cachedFrontmostBundleIdentifier = app.fixture.targetBundleIdentifier;
    app.fixture.contextAccessMode = CPAContextAccessModeWorkBuddyConversation;
    NSArray *messages = @[@{@"role":@"user", @"content":@"只检查合成项目甲的输入映射。"}];
    app.fixture.workBuddyContext = @[@[@"root-a", @[@"request-a"]], messages];
    CPAConversationContextSnapshot *first = [app completionContextForSnapshot:app.fixture];
    Verify(first.messages.count == 1, @"WorkBuddy receives its own rendered conversation");
    Verify(first == [app completionContextForSnapshot:app.fixture], @"same material keeps the same context publication");
    NSString *oldSignature = [app signatureForSnapshot:app.fixture];
    StartBoth(app);
    Verify([((CPALifecycleClient *)app.localModelClient).sentMessages isEqual:messages]
        && [((CPALifecycleClient *)app.remoteClient).sentMessages isEqual:messages], @"both authorized model paths receive WorkBuddy history");
    CPARemoteCompletionHandler late = ((CPALifecycleClient *)app.localModelClient).finish;
    app.fixture.workBuddyContext = @[@[@"root-a", @[@"request-b"]], messages];
    [app observeWorkBuddyContext:app.fixture];
    Verify(![app contextIsCurrent:first] && app.localModelTask == nil, @"switching request with same composer and content cancels old context");
    Verify(![oldSignature isEqual:[app signatureForSnapshot:app.fixture]], @"fresh Tab signature includes conversation ownership");
    late(Result(@"将找不到来源的条目保留为待确认。"));
    Verify(!app.overlayController.visible, @"late result from prior WorkBuddy conversation cannot display");
    StartBoth(app);
    ((CPALifecycleClient *)app.localModelClient).finish(Result(@"将找不到来源的条目保留为待确认。"));
    [app keyboardInterceptorDidRequestAccept];
    Verify(app.freshCompletion != nil, @"WorkBuddy Tab requests a fresh read");
    // Change only the freshly read material, without delivering a poll first.
    app.fixture.workBuddyContext = @[@[@"root-a", @[@"request-c"]], messages];
    if (app.freshCompletion) app.freshCompletion(app.fixture);
    Verify(((CPALifecycleKeyboard *)app.keyboardInterceptor).posted == 0, @"fresh Tab rejects changed history even before polling publishes it");
    app.fixture.workBuddyContext = nil;
    [app observeWorkBuddyContext:app.fixture];
    Verify([app completionContextForSnapshot:app.fixture] == nil, @"missing WorkBuddy history does not borrow Codex context");
    [app cancelPendingSuggestionForReason:@"test_end"];
}
static void WorkBuddyInterruptedReadReplay(void) {
    CPALifecycleDelegate *app = Delegate();
    app.fixture.targetBundleIdentifier = @"com.tencent.workbuddy.mac";
    app.cachedFrontmostBundleIdentifier = app.fixture.targetBundleIdentifier;
    app.fixture.contextAccessMode = CPAContextAccessModeWorkBuddyConversation;
    app.fixture.workBuddyContextReadPending = YES;
    StartBoth(app);
    Verify(((CPALifecycleClient *)app.localModelClient).finish == nil
        && ((CPALifecycleClient *)app.remoteClient).finish == nil,
        @"interrupted WorkBuddy read must not dispatch either provider with empty history");
    [app cancelPendingSuggestionForReason:@"test_reset"];
    app.fixture.workBuddyContextReadPending = NO;
    app.fixture.workBuddyContext = @[@[@"synthetic-recovered"], @[@{@"role":@"user", @"content":@"合成恢复前文"}]];
    StartBoth(app);
    Verify([((CPALifecycleClient *)app.remoteClient).sentMessages isEqual:app.fixture.workBuddyContext[1]],
        @"fresh WorkBuddy read resumes completion with recovered history");
    CPARemoteCompletionHandler late = ((CPALifecycleClient *)app.remoteClient).finish;
    app.fixture.workBuddyContextReadPending = YES;
    app.fixture.workBuddyContext = nil;
    if (late) late(Result(@"请标注待确认事项。"));
    Verify(!app.overlayController.visible, @"fresh interrupted read blocks a previously issued result before the next context poll");
    [app cancelPendingSuggestionForReason:@"test_end"];
    app = Delegate();
    app.fixture.targetBundleIdentifier = @"com.tencent.workbuddy.mac";
    app.cachedFrontmostBundleIdentifier = app.fixture.targetBundleIdentifier;
    app.fixture.contextAccessMode = CPAContextAccessModeWorkBuddyConversation;
    StartBoth(app);
    Verify(((CPALifecycleClient *)app.remoteClient).finish != nil,
        @"new WorkBuddy composer without a conversation root keeps existing draft-only behavior");
    [app cancelPendingSuggestionForReason:@"test_end"];
}
#include "FocusedIDContextTests.inc"
int main(void) { @autoreleasepool {
    DeletionPauseReplay();
    MiddleInsertionReplay();
    RepeatedContinuationReplay(NO);
    RepeatedContinuationReplay(YES);
    IndependentProviderReplay();
    UnreadableCandidateReplay();
    LocalStartupStatusReplay();
    AuthorRoutingReplay();
    WorkBuddyReaderTests();
    WorkBuddyReaderToRequestReplay();
    WorkBuddyLifecycleReplays();
    WorkBuddyInterruptedReadReplay();
    ExpressionPauseReplay(); CandidateReplays(); ContextReplays();
    FocusedIDContextReplays(); FocusedIDTransactionReplays(); FocusedIDGateReplays();
    NSLog(@"C1 replay failures: %lu", (unsigned long)failures);
    return failures ? 1 : 0;
} }
