#import "../../Sources/CodexDataCore/KeychainStore.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#define main CPAProductionEntryPoint
#include "../../Sources/CodexPromptAssistantPOC/main.m"
#undef main
#pragma clang diagnostic pop
@interface CPASettingsWindowController (FirstUseFixture)
- (void)toggleOnline:(NSButton *)sender;
- (void)saveService:(id)sender;
- (void)discardService:(id)sender;
@end
@interface CPAFirstUsePermission : CPAAccessibilityService
@property(nonatomic) BOOL fixtureTrusted;
@property(nonatomic) NSUInteger promptCount;
@end
@implementation CPAFirstUsePermission
- (BOOL)isTrustedWithPrompt:(BOOL)prompt {
    if (prompt) self.promptCount++;
    return self.fixtureTrusted;
}
@end
@interface CPAFirstUseKeychain : CPAKeychainStore
@property(nonatomic) BOOL rejectSave;
@property(nonatomic, strong) NSData *fixtureKey;
@end
@implementation CPAFirstUseKeychain
- (BOOL)storeKeyData:(NSData *)data service:(NSString *)service account:(NSString *)account error:(NSError **)error {
    (void)service; (void)account; (void)error;
    if (self.rejectSave) return NO;
    self.fixtureKey = data; return YES;
}
- (NSData *)keyDataForService:(NSString *)service account:(NSString *)account error:(NSError **)error {
    (void)service; (void)account; (void)error; return self.fixtureKey;
}
@end
@interface CPAAppDelegate (NetworkingMenuTest)
- (void)toggleCurrentPolicyRemote:(id)sender;
- (void)updateCurrentPolicyControls;
@end
@interface CPALifecycleTestController : CPALocalModelServiceController
@property(nonatomic) NSUInteger stopCount;
@end
@implementation CPALifecycleTestController
- (BOOL)stop { self.stopCount++; return YES; }
@end
@interface CPACancellableTestTask : CPARemoteCompletionTask
@property(nonatomic) NSUInteger cancelCount;
@end
@implementation CPACancellableTestTask
- (void)cancel { self.cancelCount++; }
@end
@interface CPAMenuTestDelegate : CPAAppDelegate
@property(nonatomic) NSUInteger rechecks;
@property(nonatomic, strong) CPAAccessibilitySnapshot *testSnapshot;
@property(nonatomic) NSUInteger suggestionAttempts;
@end
@implementation CPAMenuTestDelegate
- (CPAAccessibilitySnapshot *)updateStatus { self.rechecks++; return self.testSnapshot; }
- (CPAAccessibilitySnapshot *)snapshotForSuggestion { return self.testSnapshot; }
- (void)showSuggestionForSnapshot:(CPAAccessibilitySnapshot *)snapshot automatic:(BOOL)automatic {
    (void)snapshot; (void)automatic; self.suggestionAttempts++;
}
@end
@interface CPARejectionOverlay : CPAOverlayController
@property(nonatomic) BOOL testVisible;
@property(nonatomic) NSUInteger hideCount;
@property(nonatomic) NSUInteger showCount;
@property(nonatomic, copy) NSString *shownText;
@end
@implementation CPARejectionOverlay
- (BOOL)visible { return self.testVisible; }
- (void)hide { self.hideCount++; self.testVisible = NO; }
- (void)showSuggestion:(NSString *)text atAccessibilityBounds:(CGRect)bounds {
    (void)bounds; self.showCount++; self.shownText = text; self.testVisible = YES;
}
@end
@interface CPARejectedStreamClient : CPARemoteCompletionClient
@property(nonatomic, copy) CPARemoteCompletionHandler pendingCompletion;
@end
@implementation CPARejectedStreamClient
- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    contextMessages:(NSArray *)messages apiKey:(NSString *)key preferredModel:(NSString *)model
    progress:(CPARemoteCompletionProgressHandler)progress
    completion:(CPARemoteCompletionHandler)completion {
    (void)input; (void)messages; (void)key; (void)model; (void)progress;
    self.pendingCompletion = completion;
    return [CPARemoteCompletionTask new];
}
@end
@interface CPAOwnershipOverlay : CPAOverlayController
@property(nonatomic) BOOL testVisible;
@end
@implementation CPAOwnershipOverlay
- (BOOL)visible { return self.testVisible; }
- (void)hide { self.testVisible = NO; }
@end
@interface CPAOwnershipKeyboard : CPAKeyboardInterceptor
@property(nonatomic) NSUInteger postedCount;
@property(nonatomic) BOOL rejectDelivery;
@property(nonatomic) BOOL testComposition;
@end
@implementation CPAOwnershipKeyboard
- (BOOL)inputMethodCompositionProbablyActive { return self.testComposition; }
- (void)postText:(NSString *)text { (void)text; self.postedCount++; }
- (BOOL)postText:(NSString *)text toProcessIdentifier:(pid_t)pid {
    (void)pid; if (self.rejectDelivery) return NO; [self postText:text]; return YES;
}
@end
@interface CPAFreshAcceptanceDelegate : CPAMenuTestDelegate
@property(nonatomic) NSTimeInterval testClock;
@property(nonatomic, copy) void (^freshCompletion)(CPAAccessibilitySnapshot *);
@end
@implementation CPAFreshAcceptanceDelegate
- (NSTimeInterval)acceptanceMonotonicTime { return self.testClock; }
- (void)requestAcceptanceSnapshotForBundleIdentifier:(NSString *)bundle
    processIdentifier:(pid_t)pid completion:(void (^)(CPAAccessibilitySnapshot *))completion {
    (void)bundle; (void)pid; self.freshCompletion = completion;
}
@end
@interface CPAScanFixture : NSObject
@property(nonatomic, strong) CPADataFoundationSnapshot *currentSnapshot;
@property(nonatomic) NSUInteger resumes;
@property(nonatomic) BOOL delayedPause;
@property(nonatomic) NSUInteger starts;
@end
@implementation CPAScanFixture
- (void)requestPause { if (!self.delayedPause) [self.currentSnapshot setValue:@(CPADataFoundationStatePaused) forKey:@"state"]; }
- (BOOL)startScan { self.starts++; [self.currentSnapshot setValue:@(CPADataFoundationStateScanning) forKey:@"state"]; return YES; }
- (BOOL)resumeScan { self.resumes++; [self.currentSnapshot setValue:@(CPADataFoundationStateScanning) forKey:@"state"]; return YES; }
@end
#define Check(condition) do { if (!(condition)) { NSLog(@"FAIL: menu integration line %d", __LINE__); exit(1); } } while (0)
int main(void) { @autoreleasepool {
    CPAMenuTestDelegate *scanOwner = [CPAMenuTestDelegate new];
    CPAScanFixture *scan = [CPAScanFixture new];
    scan.currentSnapshot = [CPADataFoundationSnapshot new];
    [scan.currentSnapshot setValue:@(CPADataFoundationStateScanning) forKey:@"state"];
    scanOwner.dataController = (id)scan;
    scanOwner.dataScanMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    scanOwner.dataPauseMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [scanOwner toggleDataPause:nil];
    [scanOwner pauseSuggestionsWithReason:@"fixture"];
    Check(!scanOwner.dataScanMenuItem.enabled && !scanOwner.dataPauseMenuItem.enabled);
    [scanOwner startDataScan:nil];
    Check(scan.starts == 0);
    [scanOwner resumeSuggestions];
    Check(scanOwner.dataScanMenuItem.enabled && scanOwner.dataPauseMenuItem.enabled);
    Check(scan.resumes == 0); // Global resume must preserve an explicit import pause.
    [scanOwner toggleDataPause:nil];
    Check(scan.resumes == 1 && !scanOwner.historyScanUserPaused);
    scan.delayedPause = YES;
    [scanOwner pauseSuggestionsWithReason:@"fixture"];
    [scanOwner resumeSuggestions];
    Check(scan.resumes == 1); // Pause acknowledgement has not arrived.
    [scan.currentSnapshot setValue:@(CPADataFoundationStatePaused) forKey:@"state"];
    [scanOwner reconcileHistoryScanForSnapshot:scan.currentSnapshot];
    Check(scan.resumes == 2); // Late pause is reconciled after global resume.
    [scanOwner reconcileHistoryScanForSnapshot:scan.currentSnapshot];
    Check(scan.resumes == 2);
    [scanOwner pauseSuggestionsWithReason:@"fixture"];
    [scanOwner toggleDataPause:nil]; // User pauses while global pause is pending.
    [scan.currentSnapshot setValue:@(CPADataFoundationStatePaused) forKey:@"state"];
    [scanOwner resumeSuggestions];
    Check(scan.resumes == 2 && scanOwner.historyScanUserPaused);
    [scanOwner.pollTimer invalidate];
    [NSObject cancelPreviousPerformRequestsWithTarget:scanOwner];
    CPAAppDelegate *qualityDelegate = [CPAAppDelegate new];
    qualityDelegate.suggestionCoordinator = [[CPALocalSuggestionCoordinator alloc] initWithLookup:^NSString *(NSString *input, NSUInteger cursor, NSUInteger selection) { (void)input; (void)cursor; (void)selection; return nil; }];
    CPARejectionOverlay *qualityOverlay = [CPARejectionOverlay new];
    qualityDelegate.overlayController = qualityOverlay;
    CPAAccessibilitySnapshot *qualitySnapshot = [CPAAccessibilitySnapshot new];
    qualitySnapshot.inputText = @"只核对字段映射，";
    qualitySnapshot.selectedLocation = (NSInteger)qualitySnapshot.inputText.length;
    qualitySnapshot.hasCaretBounds = YES;
    qualitySnapshot.targetApplicationIsFrontmost = YES;
    qualitySnapshot.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalOnly;
    qualitySnapshot.targetBundleIdentifier = @"com.apple.TextEdit";
    qualitySnapshot.targetProcessIdentifier = 42;
    qualitySnapshot.targetFieldIdentity = @"quality-fixture";
    qualitySnapshot.writableTextInput = YES;
    qualitySnapshot.hasValueCharacterCount = YES;
    qualitySnapshot.hasSelectedRange = YES;
    qualitySnapshot.valueCharacterCount = qualitySnapshot.inputText.length;
    [qualityDelegate displayInsertionText:@"并明确输出格式，我可以根据需求调整细节。"
        snapshot:qualitySnapshot trigger:@"history_fixture"];
    Check(qualityOverlay.showCount == 0 && qualityOverlay.hideCount == 0);
    Check(qualityDelegate.displayedSuggestionSignature == nil);
    NSString *useful = @"将找不到来源的条目保留为待确认。";
    [qualityDelegate displayInsertionText:useful snapshot:qualitySnapshot trigger:@"model_fixture"];
    Check(qualityOverlay.showCount == 1 && [qualityOverlay.shownText isEqualToString:useful]);
    qualitySnapshot.inputText = @"只核对字段 {{mapping_";
    qualitySnapshot.selectedLocation = (NSInteger)qualitySnapshot.inputText.length;
    qualitySnapshot.valueCharacterCount = qualitySnapshot.inputText.length;
    [qualityDelegate displayInsertionText:useful snapshot:qualitySnapshot trigger:@"cache_fixture"];
    Check(qualityOverlay.showCount == 1 && qualityOverlay.hideCount == 1);

    CPAMenuTestDelegate *boundary = [CPAMenuTestDelegate new];
    boundary.accessibilityService = [CPAAccessibilityService new];
    boundary.genericProbeInProgress = YES;
    boundary.genericProbeBundleIdentifier = @"com.apple.TextEdit";
    [boundary updateFrontmostApplicationState:NSRunningApplication.currentApplication];
    Check(!boundary.genericProbeInProgress);
    CPAAccessibilitySnapshot *localOnly = [CPAAccessibilitySnapshot new];
    localOnly.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalOnly;
    [boundary scheduleRemoteModelSuggestionsForSnapshot:localOnly signature:@"test" delay:1];
    Check(boundary.modelSuggestionTimer == nil);
    NSString *pauseSuite = [@"local.codex.pause-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *pauseDefaults = [[NSUserDefaults alloc] initWithSuiteName:pauseSuite];
    [pauseDefaults setBool:YES forKey:@"remote-completion.paused"];
    boundary.remoteSettings = [[CPARemoteCompletionSettings alloc]
        initWithKeychainStore:[CPAKeychainStore new] userDefaults:pauseDefaults];
    [boundary configureRemoteCompletion];
    Check(boundary.remoteClient == nil);
    CPAAccessibilitySnapshot *remoteAllowed = [CPAAccessibilitySnapshot new];
    remoteAllowed.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalAndRemote;
    [boundary scheduleRemoteModelSuggestionsForSnapshot:remoteAllowed signature:@"test" delay:1];
    Check(boundary.modelSuggestionTimer == nil);
    [boundary configureLocalModelCompletion];
    Check(boundary.localModelClient != nil);
    boundary.remoteStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    boundary.suggestionCoordinator = [[CPALocalSuggestionCoordinator alloc]
        initWithLookup:^NSString *(NSString *input, NSUInteger cursor, NSUInteger selected) {
            (void)input; (void)cursor; (void)selected; return nil;
        }];
    CPARejectionOverlay *networkOverlay = [CPARejectionOverlay new];
    boundary.overlayController = networkOverlay;
    CPARemoteCompletionClient *originalLocalClient = boundary.localModelClient;
    [boundary setRemoteNetworkingEnabled:YES];
    Check(!boundary.remoteSettings.paused && boundary.remoteClient != nil);
    Check([boundary.remoteStatusMenuItem.title containsString:@"待配置"]);
    [pauseDefaults setBool:YES forKey:@"remote-completion.configured-v3"];
    [boundary updateRemoteStatusMenu];
    Check([boundary.remoteStatusMenuItem.title containsString:@"本地 + 远程"]);
    CPACancellableTestTask *pendingTask = [CPACancellableTestTask new];
    boundary.remoteTask = pendingTask;
    [boundary.suggestionCoordinator prepareRemoteInsertion:@"固定测试候选，不包含任何真实草稿。" signature:@"fixture"];
    boundary.pendingRemoteInsertion = @"stale";
    boundary.remotePreparationSignature = @"stale";
    boundary.remotePreparationInput = @"stale";
    boundary.lastObservedInputText = @"same draft";
    NSUInteger preparationBefore = boundary.remotePreparationGeneration;
    [boundary scheduleRemoteModelSuggestionsForSnapshot:remoteAllowed signature:@"fixture" delay:10];
    Check(boundary.modelSuggestionTimer != nil);
    NSUInteger rechecksBefore = boundary.rechecks;
    [boundary setRemoteNetworkingEnabled:NO];
    Check(boundary.remoteSettings.paused && boundary.remoteClient == nil);
    Check(pendingTask.cancelCount == 1 && boundary.remoteTask == nil);
    Check(boundary.modelSuggestionTimer == nil && boundary.pendingRemoteInsertion == nil);
    Check(boundary.remotePreparationSignature == nil
        && boundary.remotePreparationGeneration > preparationBefore);
    Check([boundary.suggestionCoordinator consumeInsertionForSignature:@"fixture"] == nil);
    Check(networkOverlay.hideCount > 0 && boundary.lastObservedInputText == nil);
    Check(boundary.rechecks > rechecksBefore && boundary.localModelClient == originalLocalClient);
    [boundary setRemoteNetworkingEnabled:YES];
    Check(boundary.remoteClient != nil && !boundary.remoteSettings.paused);
    Check(boundary.localModelClient == originalLocalClient);
    [boundary scheduleRemoteModelSuggestionsForSnapshot:localOnly signature:@"fixture" delay:10];
    Check(boundary.modelSuggestionTimer == nil); // Global switch never grants per-app permission.
    CPACancellableTestTask *localTask = [CPACancellableTestTask new];
    CPACancellableTestTask *warmupTask = [CPACancellableTestTask new];
    boundary.localModelTask = localTask;
    boundary.localModelWarmupTask = warmupTask;
    [boundary setLocalCompletionEnabled:NO];
    Check(boundary.remoteSettings.localPaused && !boundary.remoteSettings.paused);
    Check(boundary.localModelClient == nil && boundary.remoteClient != nil);
    Check(localTask.cancelCount == 1 && warmupTask.cancelCount == 1);
    Check([boundary.remoteStatusMenuItem.title containsString:@"仅远程"]);
    [boundary warmLocalModel];
    [boundary scheduleLocalModelSuggestionsForSnapshot:remoteAllowed signature:@"fixture" delay:10];
    Check(boundary.localModelWarmupTask == nil && boundary.localModelSuggestionTimer == nil);
    [boundary scheduleRemoteModelSuggestionsForSnapshot:remoteAllowed signature:@"fixture" delay:10];
    Check(boundary.modelSuggestionTimer != nil);
    [boundary setRemoteNetworkingEnabled:NO];
    Check(boundary.remoteSettings.localPaused && boundary.remoteSettings.paused);
    Check(boundary.accessibilityService.inputReadingPaused);
    Check(boundary.localModelClient == nil && boundary.remoteClient == nil);
    Check([boundary.remoteStatusMenuItem.title containsString:@"全部关闭"]);
    NSUInteger disabledRechecks = boundary.rechecks;
    [boundary pollAccessibility:nil];
    Check(boundary.rechecks == disabledRechecks && boundary.suggestionTimer == nil);
    [boundary setLocalCompletionEnabled:YES];
    Check(!boundary.remoteSettings.localPaused && boundary.remoteSettings.paused);
    Check(!boundary.accessibilityService.inputReadingPaused);
    Check(boundary.localModelClient != nil && boundary.remoteClient == nil);
    Check([boundary.remoteStatusMenuItem.title containsString:@"仅本地"]);
    [boundary scheduleLocalModelSuggestionsForSnapshot:localOnly signature:@"fixture" delay:10];
    Check(boundary.localModelSuggestionTimer != nil);
    [boundary setRemoteNetworkingEnabled:YES];
    Check(boundary.localModelClient != nil && boundary.remoteClient != nil);
    Check([boundary.remoteStatusMenuItem.title containsString:@"本地 + 远程"]);
    CPALifecycleTestController *lifecycle = [CPALifecycleTestController new];
    boundary.localModelServiceController = lifecycle;
    boundary.suggestionsPaused = YES;
    [boundary applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:nil]];
    Check(lifecycle.stopCount == 0);
    [pauseDefaults removePersistentDomainForName:pauseSuite];
    CPAMenuTestDelegate *continuation = [CPAMenuTestDelegate new];
    continuation.suggestionCoordinator = [[CPALocalSuggestionCoordinator alloc]
        initWithLookup:^NSString *(NSString *input, NSUInteger cursor, NSUInteger selected) {
            (void)input; (void)cursor; (void)selected; return nil;
        }];
    CPAAccessibilitySnapshot *accepted = [CPAAccessibilitySnapshot new];
    accepted.targetBundleIdentifier = @"com.apple.TextEdit";
    accepted.targetApplicationIsFrontmost = YES;
    accepted.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalOnly;
    accepted.writableTextInput = YES;
    accepted.hasCaretBounds = YES;
    accepted.hasValueCharacterCount = YES;
    accepted.hasSelectedRange = YES;
    accepted.inputText = @"今天先检查输入提示是否正常。";
    accepted.valueCharacterCount = accepted.inputText.length;
    accepted.selectedLocation = accepted.inputText.length;
    continuation.testSnapshot = accepted;
    continuation.programmaticInsertionExpectedInput = accepted.inputText;
    continuation.lastSuggestionAcceptedDate = NSDate.date;
    [continuation pollAccessibility:nil];
    Check(continuation.suggestionTimer != nil);
    Check(continuation.dismissedInputText == nil);
    NSTimer *next = continuation.suggestionTimer;
    [continuation showAutomaticSuggestion:next];
    [next invalidate];
    Check(continuation.suggestionAttempts == 1);
    continuation.lastObservedInputText = @"今天先检查";
    continuation.lastSuggestionAcceptedDate = NSDate.date;
    [continuation pollAccessibility:nil];
    Check(continuation.suggestionTimer != nil);
    accepted.targetApplicationIsFrontmost = NO;
    next = continuation.suggestionTimer;
    [continuation showAutomaticSuggestion:next];
    [next invalidate];
    Check(continuation.suggestionAttempts == 1);
    // A long streamed suggestion is still provisional: final rejection must revoke it.
    accepted.targetApplicationIsFrontmost = YES;
    CPARejectedStreamClient *rejectingClient = [[CPARejectedStreamClient alloc]
        initWithBaseURL:[NSURL URLWithString:@"http://127.0.0.1:18921/v1"]
        sessionConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
        callbackQueue:dispatch_get_main_queue()];
    continuation.localModelClient = rejectingClient;
    accepted.inputText = [accepted.inputText stringByAppendingString:@"仍需核对"];
    accepted.valueCharacterCount = accepted.inputText.length;
    accepted.selectedLocation = (NSInteger)accepted.inputText.length;
    NSString *acceptedSignature = [continuation signatureForSnapshot:accepted];
    CPARejectionOverlay *rejectionOverlay = [CPARejectionOverlay new];
    continuation.overlayController = rejectionOverlay;
    continuation.lastObservedInputText = accepted.inputText;
    [continuation startLocalModelSuggestionForSnapshot:accepted signature:acceptedSignature];
    Check(rejectingClient.pendingCompletion != nil);
    // Production no longer publishes provisional streams. A failed model call
    // must preserve an independently committed candidate with the same binding.
    NSString *committed = @"将找不到来源的条目保留为待确认。";
    [continuation displayInsertionText:committed snapshot:accepted trigger:@"history_fixture"];
    rejectingClient.pendingCompletion([CPARemoteCompletionResult new]);
    Check(continuation.localModelDisplayedSignature == nil);
    Check(rejectionOverlay.showCount == 1 && rejectionOverlay.hideCount == 0);
    Check([[continuation.suggestionCoordinator consumeInsertionForSignature:acceptedSignature] isEqual:committed]);
    Check(!continuation.localModelDisplayedPreview);
    NSString *suite = [@"local.codex.menu-integration." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    CPAMenuTestDelegate *delegate = [CPAMenuTestDelegate new];
    delegate.suggestionPolicyStore = [[CPASuggestionPolicyStore alloc] initWithUserDefaults:defaults];
    // AppKit may request another update while a menu is tracking. Preserve
    // the already displayed target rather than silently rebinding the action.
    NSMenu *trackingMenu = [NSMenu new];
    [delegate menuNeedsUpdate:trackingMenu];
    delegate.policyMenuBundleIdentifier = @"com.example.original-target";
    delegate.policyMenuProcessIdentifier = -42;
    delegate.policyMenuHost = @"original.example.com";
    NSUInteger trackingVersion = delegate.suggestionPolicyStore.ruleVersion;
    [delegate menuNeedsUpdate:trackingMenu];
    Check([delegate.policyMenuBundleIdentifier isEqual:@"com.example.original-target"]);
    Check(delegate.policyMenuProcessIdentifier == -42);
    Check([delegate.policyMenuHost isEqual:@"original.example.com"]);
    [delegate toggleCurrentPolicyRemote:nil];
    Check(delegate.suggestionPolicyStore.ruleVersion == trackingVersion);
    [(id<NSMenuDelegate>)delegate menuDidClose:trackingMenu];
    [delegate menuNeedsUpdate:trackingMenu];
    Check(delegate.policyMenuProcessIdentifier == NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    Check(![delegate.policyMenuBundleIdentifier isEqual:@"com.example.original-target"]);
    [(id<NSMenuDelegate>)delegate menuDidClose:trackingMenu];
    delegate.policyMenuProcessIdentifier = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    delegate.policyMenuBundleIdentifier = @"com.example.editor";
    delegate.policyMenuHost = @"";
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    for (NSInteger mode=0; mode<3; mode++) {
        delegate.lastObservedInputText = @"test";
        delegate.cachedGenericSnapshot = [CPAAccessibilitySnapshot new];
        NSUInteger oldVersion=delegate.suggestionPolicyStore.ruleVersion;
        item.tag=mode;
        [delegate changeCurrentPolicyMode:item];
        Check([delegate currentMenuRule].mode == mode);
        Check(delegate.suggestionPolicyStore.ruleVersion > oldVersion);
        Check(delegate.lastObservedInputText == nil && delegate.cachedGenericSnapshot == nil);
        Check(delegate.rechecks == (NSUInteger)mode+1);
    }
    [delegate toggleCurrentPolicySearch:nil];
    Check([delegate currentMenuRule].searchExceptionEnabled);
    Check([delegate respondsToSelector:NSSelectorFromString(@"toggleCurrentPolicyRemote:")]);
    CPACancellableTestTask *policyRequest = [CPACancellableTestTask new];
    delegate.remoteTask = policyRequest;
    delegate.displayedSuggestionSignature = @"old-policy-candidate";
    delegate.cachedGenericSnapshot = [CPAAccessibilitySnapshot new];
    NSUInteger remoteChecks = delegate.rechecks;
    [delegate toggleCurrentPolicyRemote:nil];
    Check([delegate currentMenuRule].remoteCompletionAuthorized);
    Check([delegate currentMenuRule].searchExceptionEnabled
        && [delegate currentMenuRule].mode == CPAApplicationPolicyModeDisabled);
    Check(delegate.rechecks == remoteChecks+1);
    Check(policyRequest.cancelCount == 1 && delegate.remoteTask == nil
        && delegate.displayedSuggestionSignature == nil && delegate.cachedGenericSnapshot == nil);
    [delegate toggleCurrentPolicyRemote:nil];
    Check(![delegate currentMenuRule].remoteCompletionAuthorized);
    delegate.remoteSettings = [[CPARemoteCompletionSettings alloc]
        initWithKeychainStore:[CPAKeychainStore new] userDefaults:defaults];
    [defaults setBool:YES forKey:@"local-completion.paused"];
    [defaults setBool:NO forKey:@"remote-completion.paused"];
    delegate.policyRemoteMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    delegate.policyProviderHintMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    delegate.policyMenuBundleIdentifier = @"com.apple.TextEdit";
    [delegate updateCurrentPolicyControls];
    Check(delegate.policyRemoteMenuItem.enabled && delegate.policyRemoteMenuItem.state == NSControlStateValueOff);
    Check([delegate.policyProviderHintMenuItem.title containsString:@"本地已关闭，联网未允许"]);
    delegate.policyMenuBundleIdentifier = @"com.google.Chrome";
    [delegate updateCurrentPolicyControls];
    Check(!delegate.policyRemoteMenuItem.enabled);
    NSUInteger oldVersion=delegate.suggestionPolicyStore.ruleVersion;
    item.tag=1;
    [delegate changeCurrentPolicyMode:item];
    Check(delegate.suggestionPolicyStore.ruleVersion == oldVersion);
    [delegate toggleCurrentPolicyRemote:nil];
    Check(delegate.suggestionPolicyStore.ruleVersion == oldVersion);
    delegate.policyMenuHost = @"docs.example.com";
    [delegate changeCurrentPolicyMode:item];
    Check([delegate currentMenuRule].mode == CPAApplicationPolicyModeEnableOrdinaryInputs);
    Check([delegate.suggestionPolicyStore ruleForBrowserHost:@"other.example.com"].mode == CPAApplicationPolicyModeRecommended);
    Check([delegate.suggestionPolicyStore ruleForBundleIdentifier:@"com.google.Chrome"].mode == CPAApplicationPolicyModeRecommended);
    [delegate toggleCurrentPolicyRemote:nil];
    Check([delegate currentMenuRule].remoteCompletionAuthorized);
    [delegate updateCurrentPolicyControls];
    Check(delegate.policyRemoteMenuItem.enabled && delegate.policyRemoteMenuItem.state == NSControlStateValueOn);
    Check([delegate.policyRemoteMenuItem.title isEqual:@"允许此站点联网补全"]);
    Check(![delegate.suggestionPolicyStore ruleForBrowserHost:@"other.example.com"].remoteCompletionAuthorized);
    Check(![delegate.suggestionPolicyStore ruleForBundleIdentifier:@"com.google.Chrome"].remoteCompletionAuthorized);
    delegate.policyMenuProcessIdentifier = -1;
    [delegate toggleCurrentPolicyRemote:nil];
    Check([delegate currentMenuRule].remoteCompletionAuthorized);
    delegate.policyMenuProcessIdentifier = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    delegate.policyMenuBundleIdentifier = @"com.apple.SecurityAgent";
    [delegate updateCurrentPolicyControls];
    Check(!delegate.policyRemoteMenuItem.enabled);
    oldVersion=delegate.suggestionPolicyStore.ruleVersion;
    [delegate changeCurrentPolicyMode:item];
    Check(delegate.suggestionPolicyStore.ruleVersion == oldVersion);
    [delegate toggleCurrentPolicyRemote:nil];
    Check(delegate.suggestionPolicyStore.ruleVersion == oldVersion);
    delegate.policyMenuBundleIdentifier = @"com.openai.codex";
    [delegate updateCurrentPolicyControls];
    Check(!delegate.policyRemoteMenuItem.enabled && [delegate.policyRemoteMenuItem.title containsString:@"全局远程"]);
    [delegate toggleCurrentPolicyRemote:nil];
    Check(delegate.suggestionPolicyStore.ruleVersion == oldVersion);
    // Use the production publication boundary: never reclassify a denied
    // metadata verdict as an allowed composer using only AXTextArea.
    delegate.policyCoordinator = [[CPASuggestionPolicyCoordinator alloc]
        initWithStore:delegate.suggestionPolicyStore];
    delegate.accessibilityService = [CPAAccessibilityService new];
    [delegate configureCodexSnapshotBroker];
    Check(delegate.accessibilityService.policyCoordinator == delegate.policyCoordinator);
    [delegate.codexSnapshotBroker stop];
    CPAAccessibilitySnapshot *(^codexFixture)(NSArray<NSString *> *) = ^(NSArray<NSString *> *metadata) {
        CPAAccessibilitySnapshot *snapshot = [CPAAccessibilitySnapshot new];
        snapshot.codexIsRunning = YES;
        snapshot.codexIsFrontmost = YES;
        snapshot.focusedRole = @"AXTextArea";
        snapshot.inputText = @"synthetic draft";
        snapshot.conversationTitle = @"synthetic task";
        snapshot.writableTextInput = YES;
        snapshot.hasValueCharacterCount = YES;
        snapshot.valueCharacterCount = snapshot.inputText.length;
        snapshot.policyRuleVersion = delegate.policyCoordinator.ruleVersion;
        snapshot.inputReadingGeneration = delegate.accessibilityService.inputReadingGeneration;
        snapshot.codexInputDecision = [delegate.policyCoordinator
            decisionForBundleIdentifier:@"com.openai.codex" role:@"AXTextArea"
            subrole:@"" semanticMetadata:metadata browserHost:@""
            globallyPaused:NO temporarilyPaused:NO];
        return snapshot;
    };
    CPAAccessibilitySnapshot *codex = codexFixture(@[]);
    [delegate decorateCodexSnapshot:codex];
    Check(codex.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
        && codex.inputText.length > 0);
    codex = codexFixture(@[@"verification code"]);
    delegate.lastUsableSnapshot = codexFixture(@[]);
    [delegate decorateCodexSnapshot:codex];
    Check(codex.suggestionPolicyReason == CPASuggestionPolicyReasonHardSensitive);
    Check(codex.inputText == nil && codex.conversationTitle == nil
        && !codex.writableTextInput && delegate.lastUsableSnapshot == nil);
    Check([delegate snapshotByApplyingShadowBufferToSnapshot:codex] == nil);
    codex = codexFixture(@[]);
    [delegate.suggestionPolicyStore setRule:[[CPAApplicationRule alloc]
        initWithMode:CPAApplicationPolicyModeDisabled searchExceptionEnabled:NO
        remoteCompletionAuthorized:NO] forBundleIdentifier:@"com.openai.codex"];
    [delegate decorateCodexSnapshot:codex];
    Check(codex.inputText == nil && codex.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled);
    [delegate.suggestionPolicyStore setRule:[[CPAApplicationRule alloc]
        initWithMode:CPAApplicationPolicyModeRecommended searchExceptionEnabled:NO
        remoteCompletionAuthorized:NO] forBundleIdentifier:@"com.openai.codex"];
    codex = codexFixture(@[]);
    delegate.suggestionsPaused = YES;
    Check(delegate.accessibilityService.inputReadingPaused);
    delegate.suggestionsPaused = NO;
    Check(!delegate.accessibilityService.inputReadingPaused);
    [delegate decorateCodexSnapshot:codex];
    Check(codex.inputText == nil && codex.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled);
    codex = codexFixture(@[]);
    codex.codexInputDecision = nil;
    [delegate decorateCodexSnapshot:codex];
    Check(codex.inputText == nil && codex.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled);
    Check([delegate snapshotForCodexMetadataUnavailable].suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled);
    // Replay Tab against an observed snapshot without generating real key events.
    CPAFreshAcceptanceDelegate *acceptor = [CPAFreshAcceptanceDelegate new];
    acceptor.suggestionCoordinator = [[CPALocalSuggestionCoordinator alloc]
        initWithLookup:^NSString *(NSString *input, NSUInteger cursor, NSUInteger selection) {
            (void)input; (void)cursor; (void)selection; return nil;
        }];
    CPAOwnershipOverlay *ownershipOverlay = [CPAOwnershipOverlay new];
    CPAOwnershipKeyboard *ownershipKeyboard = [[CPAOwnershipKeyboard alloc] initWithDelegate:acceptor];
    acceptor.overlayController = ownershipOverlay;
    acceptor.keyboardInterceptor = ownershipKeyboard;
    for (NSUInteger event = 0; event < 8; event++) {
        CPAAccessibilitySnapshot *current = [CPAAccessibilitySnapshot new];
        current.targetApplicationIsFrontmost = YES;
        current.targetBundleIdentifier = @"com.example.fixture";
        current.targetProcessIdentifier = 123;
        current.targetFieldIdentity = @"window-a/field-a";
        current.suggestionPolicyOutcome = CPASuggestionPolicyOutcomeLocalOnly;
        current.writableTextInput = YES;
        current.hasElementFrame = YES;
        current.hasValueCharacterCount = YES;
        current.hasSelectedRange = YES;
        current.inputText = @"甲乙丙丁";
        current.valueCharacterCount = 4;
        current.selectedLocation = 2;
        acceptor.conversationGeneration = 1;
        NSString *requestSignature = [acceptor signatureForSnapshot:current];
        [acceptor.suggestionCoordinator prepareRemoteInsertion:@"合成后缀" signature:requestSignature];
        acceptor.testSnapshot = current; // The cached snapshot still has the old draft.
        acceptor.cachedFrontmostBundleIdentifier = current.targetBundleIdentifier;
        acceptor.cachedFrontmostProcessIdentifier = current.targetProcessIdentifier;
        acceptor.displayedSuggestionSignature = requestSignature;
        ownershipOverlay.testVisible = YES;
        ownershipKeyboard.postedCount = 0;
        [acceptor keyboardInterceptorDidRequestAccept];
        Check(ownershipKeyboard.postedCount == 0 && acceptor.freshCompletion != nil);
        if (event == 1) current.inputText = @"乙甲丙丁";
        if (event == 2) current.targetFieldIdentity = @"window-b/field-a";
        if (event == 3) current.targetProcessIdentifier++;
        if (event == 4) current.policyRuleVersion++;
        if (event == 5) acceptor.conversationGeneration++;
        if (event == 6) current.browserHost = @"other.example.com";
        if (event == 7) current.inputText = @"甲乙丁丙";
        acceptor.freshCompletion(current);
        Check(ownershipKeyboard.postedCount == (event == 0 ? 1u : 0u));
        [acceptor keyboardInterceptorDidRequestAccept];
        acceptor.freshCompletion(current);
        Check(ownershipKeyboard.postedCount == (event == 0 ? 1u : 0u));
    }
    acceptor.policyCoordinator = delegate.policyCoordinator;
    for (NSUInteger event = 0; event < 11; event++) {
        CPAAccessibilitySnapshot *current = acceptor.testSnapshot;
        current.policyRuleVersion = acceptor.policyCoordinator.ruleVersion;
        acceptor.suggestionsPaused = NO;
        acceptor.cachedFrontmostProcessIdentifier = current.targetProcessIdentifier;
        acceptor.cachedFrontmostBundleIdentifier = current.targetBundleIdentifier;
        acceptor.lastSuggestionAcceptedDate = nil;
        acceptor.programmaticInsertionExpectedInput = nil;
        NSString *signature = [acceptor signatureForSnapshot:current];
        [acceptor.suggestionCoordinator prepareRemoteInsertion:@"合成后缀" signature:signature];
        acceptor.displayedSuggestionSignature = signature;
        ownershipOverlay.testVisible = YES;
        ownershipKeyboard.postedCount = 0;
        ownershipKeyboard.rejectDelivery = NO;
        ownershipKeyboard.testComposition = NO;
        [acceptor keyboardInterceptorDidRequestAccept];
        Check(acceptor.acceptancePending && ownershipKeyboard.postedCount == 0);
        void (^completion)(CPAAccessibilitySnapshot *) = acceptor.freshCompletion;
        if (event == 0) [acceptor keyboardInterceptorDidObserveInputEvent];
        if (event == 1) { acceptor.suggestionsPaused = YES; acceptor.suggestionsPaused = NO; }
        if (event == 2) [acceptor keyboardInterceptorDidRequestDismiss];
        if (event == 3) [acceptor acceptanceTimedOut:acceptor.acceptanceTimeoutTimer];
        if (event == 4) acceptor.cachedFrontmostProcessIdentifier++;
        if (event == 5) ownershipKeyboard.rejectDelivery = YES;
        if (event == 6) {
            [acceptor keyboardInterceptorDidRequestAccept];
            Check(acceptor.freshCompletion == completion); // Repeated Tab never starts a second read.
            [acceptor keyboardInterceptorDidRequestDismiss];
        }
        if (event == 8) ownershipKeyboard.testComposition = YES;
        if (event == 9) [delegate.suggestionPolicyStore setRule:[[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeDisabled searchExceptionEnabled:NO remoteCompletionAuthorized:NO]
            forBundleIdentifier:@"com.example.fixture"];
        if (event == 10) acceptor.testClock += 2.0; // Timer delivery may be delayed by the run loop.
        completion(event == 7 ? nil : current);
        Check(!acceptor.acceptancePending && ownershipKeyboard.postedCount == 0);
        Check(acceptor.lastSuggestionAcceptedDate == nil && acceptor.programmaticInsertionExpectedInput == nil);
    }
    // An old callback must neither insert nor cancel a newer acceptance ticket.
    [delegate.suggestionPolicyStore setRule:[[CPAApplicationRule alloc]
        initWithMode:CPAApplicationPolicyModeRecommended searchExceptionEnabled:NO remoteCompletionAuthorized:NO]
        forBundleIdentifier:@"com.example.fixture"];
    CPAAccessibilitySnapshot *latestInput = acceptor.testSnapshot;
    latestInput.policyRuleVersion = acceptor.policyCoordinator.ruleVersion;
    ownershipKeyboard.rejectDelivery = NO;
    ownershipKeyboard.testComposition = NO;
    ownershipKeyboard.postedCount = 0;
    void (^prepareAcceptance)(void) = ^{
        NSString *signature = [acceptor signatureForSnapshot:latestInput];
        [acceptor.suggestionCoordinator prepareRemoteInsertion:@"合成后缀" signature:signature];
        acceptor.displayedSuggestionSignature = signature;
        ownershipOverlay.testVisible = YES;
        [acceptor keyboardInterceptorDidRequestAccept];
    };
    prepareAcceptance();
    void (^oldCompletion)(CPAAccessibilitySnapshot *) = acceptor.freshCompletion;
    [acceptor keyboardInterceptorDidObserveInputEvent];
    prepareAcceptance();
    oldCompletion(latestInput);
    Check(acceptor.acceptancePending && ownershipKeyboard.postedCount == 0);
    acceptor.freshCompletion(latestInput);
    Check(!acceptor.acceptancePending && ownershipKeyboard.postedCount == 1);
    CPAMenuTestDelegate *settingsOwner = [CPAMenuTestDelegate new];
    settingsOwner.suggestionPolicyStore = [[CPASuggestionPolicyStore alloc] initWithUserDefaults:defaults];
    settingsOwner.remoteSettings = boundary.remoteSettings;
    settingsOwner.suggestionPolicyStore.onlineScopesOnly = YES;
    NSDictionary *targetRule = @{@"bundle":@"com.apple.TextEdit", @"host":@"", @"enabled":@YES};
    Check([settingsOwner applySettingsAction:@"scope" values:targetRule] == nil);
    Check([settingsOwner.suggestionPolicyStore ruleForBundleIdentifier:@"com.apple.TextEdit"].remoteCompletionAuthorized);
    Check(settingsOwner.rechecks == 1);
    NSMutableDictionary *protectedRule = [targetRule mutableCopy];
    protectedRule[@"bundle"] = @"com.apple.SecurityAgent";
    Check([settingsOwner applySettingsAction:@"scope" values:protectedRule] != nil);
    protectedRule[@"bundle"] = @"com.google.Chrome";
    Check([settingsOwner applySettingsAction:@"scope" values:protectedRule] != nil);
    protectedRule[@"host"] = @"https://docs.example.com/private?fixture=secret";
    Check([settingsOwner applySettingsAction:@"scope" values:protectedRule] != nil);
    protectedRule[@"host"] = @"docs.example.com";
    Check([settingsOwner applySettingsAction:@"scope" values:protectedRule] != nil);
    Check(settingsOwner.suggestionPolicyStore.storedBrowserHosts.count == 0);
    Check([settingsOwner settingsRuleTargets].count == 10);
    for (NSString *removed in @[@"local",@"expression",@"rule",@"scan",@"recover",@"pause"])
        Check([settingsOwner applySettingsAction:removed values:@{}] != nil);
    // Revoking a scope invalidates a real pending acceptance ticket and its late callback.
    acceptor.suggestionPolicyStore = settingsOwner.suggestionPolicyStore;
    acceptor.policyCoordinator = [[CPASuggestionPolicyCoordinator alloc] initWithStore:acceptor.suggestionPolicyStore];
    latestInput.policyRuleVersion = acceptor.policyCoordinator.ruleVersion;
    ownershipKeyboard.postedCount = 0;
    acceptor.lastSuggestionAcceptedDate = nil; acceptor.programmaticInsertionExpectedInput = nil;
    prepareAcceptance();
    void (^revokedCompletion)(CPAAccessibilitySnapshot *) = acceptor.freshCompletion;
    Check(acceptor.acceptancePending);
    Check(([acceptor applySettingsAction:@"scope" values:@{@"bundle":@"com.apple.TextEdit",@"host":@"",@"enabled":@NO}] == nil));
    revokedCompletion(latestInput);
    Check(!acceptor.acceptancePending && ownershipKeyboard.postedCount == 0);
    // The same Feishu selection also revokes a browser candidate in flight.
    latestInput.targetBundleIdentifier = @"com.google.Chrome";
    latestInput.browserHost = @"tenant.feishu.cn";
    acceptor.cachedFrontmostBundleIdentifier = latestInput.targetBundleIdentifier;
    [acceptor.suggestionPolicyStore setOnlineScopeSelected:YES bundleIdentifier:@"com.electron.lark" host:@""];
    latestInput.policyRuleVersion = acceptor.policyCoordinator.ruleVersion;
    prepareAcceptance();
    void (^webRevokedCompletion)(CPAAccessibilitySnapshot *) = acceptor.freshCompletion;
    Check(acceptor.acceptancePending);
    Check(([acceptor applySettingsAction:@"scope" values:@{@"bundle":@"com.electron.lark",@"host":@"",@"enabled":@NO}] == nil));
    webRevokedCompletion(latestInput);
    Check(!acceptor.acceptancePending && ownershipKeyboard.postedCount == 0);
    NSString *historySuite = [@"local.codex.history-intent." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *historyDefaults = [[NSUserDefaults alloc] initWithSuiteName:historySuite];
    [scanOwner configureHistoryImportPreferences:historyDefaults existingDatabase:NO];
    Check(![historyDefaults boolForKey:@"history-import.approved"]);
    [scanOwner configureHistoryImportPreferences:historyDefaults existingDatabase:YES];
    Check(![historyDefaults boolForKey:@"history-import.approved"]); // An explicit decline is not overridden by a later database.
    [historyDefaults removePersistentDomainForName:historySuite];
    [scanOwner configureHistoryImportPreferences:historyDefaults existingDatabase:YES];
    Check([historyDefaults boolForKey:@"history-import.approved"]);
    Check([[historyDefaults stringForKey:@"history-import.origin"] isEqual:@"legacy-database"]);
    scanOwner.historyDefaults = historyDefaults;
    scanOwner.historyScanUserPaused = YES;
    Check([[[NSUserDefaults alloc] initWithSuiteName:historySuite] boolForKey:@"history-import.user-paused"]);
    [historyDefaults removePersistentDomainForName:historySuite];
    // First-use UI -> real settings action -> isolated preferences, with OS/provider boundaries faked.
    [NSApplication sharedApplication];
    NSString *firstSuite = [@"local.codex.first-use." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *firstDefaults = [[NSUserDefaults alloc] initWithSuiteName:firstSuite];
    CPAMenuTestDelegate *firstOwner = [CPAMenuTestDelegate new];
    CPAFirstUseKeychain *firstKeychain = [CPAFirstUseKeychain new];
    firstOwner.remoteSettings = [[CPARemoteCompletionSettings alloc]
        initWithKeychainStore:firstKeychain userDefaults:firstDefaults];
    firstOwner.remoteSettings.onlineOnly = YES;
    [firstOwner configureHistoryImportPreferences:firstDefaults existingDatabase:NO];
    CPAFirstUsePermission *firstPermission = [CPAFirstUsePermission new];
    firstOwner.accessibilityService = firstPermission;
    firstOwner.suggestionPolicyStore = [[CPASuggestionPolicyStore alloc] initWithUserDefaults:firstDefaults];
    CPAScanFixture *firstScan = [CPAScanFixture new];
    firstOwner.dataController = (id)firstScan;
    CPASettingsWindowController *firstWindow = [[CPASettingsWindowController alloc]
        initWithStateProvider:^NSDictionary *{ return [firstOwner settingsState]; }
        actionHandler:^NSString *(NSString *action, NSDictionary *values) {
            return [firstOwner applySettingsAction:action values:values];
        } ruleProvider:^NSDictionary *(NSDictionary *target) { (void)target; return @{}; }];
    NSDictionary *firstState = [firstOwner settingsState];
    Check(![firstState[@"local"] boolValue] && ![firstState[@"remote"] boolValue]);
    Check(![firstState[@"configured"] boolValue] && ![firstState[@"permission"] boolValue]);
    Check(![[firstWindow valueForKey:@"permissionButton"] isHidden]);
    Check(firstPermission.promptCount == 0); // Merely opening settings never prompts.
    Check([firstOwner applySettingsAction:@"permission" values:@{}] == nil);
    [firstWindow refreshState];
    Check(firstPermission.promptCount == 1 && ![[firstOwner settingsState][@"permission"] boolValue]);
    firstPermission.fixtureTrusted = YES; [firstWindow refreshState];
    Check([[firstWindow valueForKey:@"permissionButton"] isHidden]);
    NSButton *firstOnline = [firstWindow valueForKey:@"onlineSwitch"];
    firstOnline.state = NSControlStateValueOn; [firstWindow toggleOnline:firstOnline];
    Check(firstOwner.remoteSettings.paused);
    Check(firstOwner.remoteSettings.paused && !firstOwner.remoteSettings.configured);
    firstOnline.state = NSControlStateValueOn; [firstWindow toggleOnline:firstOnline];
    NSSecureTextField *firstKeyField = [firstWindow valueForKey:@"keyField"];
    firstKeyField.stringValue = @"synthetic-first-use-key";
    firstKeychain.rejectSave = YES; [firstWindow saveService:nil];
    Check(firstOwner.remoteSettings.paused && !firstOwner.remoteSettings.configured && firstKeyField.stringValue.length > 0);
    firstKeychain.rejectSave = NO; [firstWindow saveService:nil];
    Check(firstOwner.remoteSettings.paused && firstOwner.remoteSettings.configured && firstOwner.remoteSettings.localPaused);
    firstOnline.state = NSControlStateValueOn; [firstWindow toggleOnline:firstOnline];
    Check(!firstOwner.remoteSettings.paused);
    Check(firstKeyField.stringValue.length == 0);
    Check(![firstDefaults boolForKey:@"history-import.approved"] && firstScan.starts == 0);
    CPARemoteCompletionSettings *firstReload = [[CPARemoteCompletionSettings alloc]
        initWithKeychainStore:firstKeychain userDefaults:firstDefaults];
    Check(!firstReload.paused && firstReload.configured); // Explicit successful enable survives reopening.
    [firstWindow.window close];
    [firstOwner.remoteClient cancelActiveRequest]; [firstOwner.localModelClient cancelActiveRequest];
    [firstDefaults removePersistentDomainForName:firstSuite];
    // The quick entry changes only this scope; it never grants online permission.
    delegate.policyMenuBundleIdentifier = @"com.example.quick";
    delegate.policyMenuHost = @"";
    delegate.policyMenuProcessIdentifier = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    [delegate toggleCurrentScopeCompletion:nil];
    Check([delegate currentMenuRule].mode == CPAApplicationPolicyModeDisabled);
    [delegate toggleCurrentScopeCompletion:nil];
    Check([delegate currentMenuRule].mode == CPAApplicationPolicyModeEnableOrdinaryInputs);
    Check(![delegate currentMenuRule].remoteCompletionAuthorized);
    delegate.policyMenuBundleIdentifier = @"com.google.Chrome";
    delegate.policyMenuHost = @"fresh.example.com";
    [delegate toggleCurrentScopeCompletion:nil];
    Check([delegate currentMenuRule].mode == CPAApplicationPolicyModeEnableOrdinaryInputs);
    Check(![delegate currentMenuRule].remoteCompletionAuthorized);
    delegate.policyMenuBundleIdentifier = @"com.apple.Terminal";
    delegate.policyMenuHost = @"";
    [delegate toggleCurrentScopeCompletion:nil];
    Check([delegate currentMenuRule].mode == CPAApplicationPolicyModeEnableOrdinaryInputs);
    Check(![delegate currentMenuRule].remoteCompletionAuthorized);
    delegate.policyMenuBundleIdentifier = @"com.google.Chrome";
    delegate.policyMenuHost = @"fresh.example.com";
    NSUInteger quickVersion = delegate.suggestionPolicyStore.ruleVersion;
    delegate.policyMenuProcessIdentifier = -42;
    [delegate toggleCurrentScopeCompletion:nil];
    Check(delegate.suggestionPolicyStore.ruleVersion == quickVersion);
    delegate.policyMenuProcessIdentifier = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    delegate.policyMenuHost = @"";
    [delegate toggleCurrentScopeCompletion:nil];
    Check(delegate.suggestionPolicyStore.ruleVersion == quickVersion);
    [defaults removePersistentDomainForName:suite];
    puts("PASS: actual main.m menu actions, three modes, search, exact site, guards, invalidation and immediate recheck");
} }
