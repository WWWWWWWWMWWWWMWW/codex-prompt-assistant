#import <AppKit/AppKit.h>
#include <stdio.h>
#include <string.h>
#import "CPABuildMetadata.h"
#import "../RemoteCompletionCore/CompletionIdentity.h"

#import "AccessibilityService.h"
#import "AccessibilitySnapshot.h"
#import "AccessibilitySnapshotBroker.h"
#import "CodexThreadIDResolver.h"
#import "ApplicationMenu.h"
#import "SettingsWindowController.h"
#import "ConversationContextProvider.h"
#import "DataFoundationController.h"
#import "Diagnostics.h"
#import "GenericAccessibilityService.h"
#import "KeyboardInterceptor.h"
#import "HealthProbe.h"
#import "LocalSuggestionCoordinator.h"
#import "LocalModelServiceController.h"
#import "OverlayController.h"
#import "RemoteCompletionSettings.h"
#import "SafeInputContextCollector.h"
#import "SuggestionContextIdentity.h"
#import "SuggestionPolicyCoordinator.h"
#import "SuggestionPolicyStore.h"
#import "SuggestionTriggerPolicy.h"
#import "../RemoteCompletionCore/RemoteCompletionClient.h"
#import "../RemoteCompletionCore/RemoteCompletionProtocol.h"
#import "../RemoteCompletionCore/RemoteCompletionSpeculation.h"
#import "../CodexDataCore/MasterKeyFileStore.h"

static NSString *const CPATestSuggestion = @"，这是阶段 0 的测试建议";
static NSString *const CPALocalModelName = @CPA_DEFAULT_LOCAL_MODEL;
static NSString *const CPALocalModelAPIKey = @"local-loopback";
static NSString *const CPALocalModelBaseURL = @"http://127.0.0.1:18921/v1";

// NSTimer scheduled in the default run-loop mode can pause while AppKit is
// tracking a key/menu event. Suggestion timers are short-lived and their
// callbacks still perform the full generation/foreground validation, so
// registering them in common modes removes that avoidable mode-switch stall
// without allowing stale work to reach the host application.
static NSTimer *CPAScheduleOneShotTimer(
    NSTimeInterval interval,
    id target,
    SEL selector,
    id _Nullable userInfo
) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:MAX(0.0, interval)
        target:target selector:selector userInfo:userInfo repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

static NSTimer *CPAScheduleRepeatingTimer(
    NSTimeInterval interval,
    id target,
    SEL selector
) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:MAX(0.01, interval)
        target:target selector:selector userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

static NSUInteger CPAMillisecondsSinceDate(NSDate * _Nullable date) {
    if (date == nil) {
        return 0;
    }
    NSTimeInterval elapsed = -[date timeIntervalSinceNow];
    return elapsed > 0 ? (NSUInteger)llround(elapsed * 1000.0) : 0;
}

@interface CPAAppDelegate : NSObject <NSApplicationDelegate, CPAKeyboardInterceptorDelegate, NSMenuDelegate>
@property(nonatomic, strong) CPAHealthResponder *healthResponder;
@property(nonatomic, strong) CPASettingsWindowController *settingsWindowController;
@property(nonatomic, strong) NSUserDefaults *historyDefaults;
@property(nonatomic) BOOL historyScanUserPaused;
@property(nonatomic) BOOL historyScanPausedByAssistant;
@property(nonatomic, strong) CPAAccessibilityService *accessibilityService;
@property(nonatomic, strong) CPAAccessibilitySnapshotBroker *codexSnapshotBroker;
@property(nonatomic, strong, nullable) CPAAccessibilitySnapshot *cachedCodexSnapshot;
@property(nonatomic, strong) CPAGenericAccessibilityService *genericAccessibilityService;
@property(nonatomic, strong) CPASuggestionPolicyStore *suggestionPolicyStore;
@property(nonatomic, strong) CPASuggestionPolicyCoordinator *policyCoordinator;
@property(nonatomic, strong) CPASafeInputContextCollector *safeInputCollector;
@property(nonatomic, strong) CPASuggestionContextGenerationTracker
    *contextGenerationTracker;
@property(nonatomic, strong, nullable) CPASuggestionDecision *currentPolicyDecision;
@property(nonatomic, copy, nullable) NSString *currentPolicyBundleIdentifier;
@property(nonatomic, strong) NSMenuItem *policyScopeMenuItem;
@property(nonatomic, strong) NSMenuItem *quickScopeMenuItem;
@property(nonatomic, strong) NSArray<NSMenuItem *> *policyModeMenuItems;
@property(nonatomic, strong) NSMenuItem *policySearchMenuItem;
@property(nonatomic, strong) NSMenuItem *policyRemoteMenuItem;
@property(nonatomic, strong) NSMenuItem *policyProviderHintMenuItem;
@property(nonatomic, copy) NSString *policyMenuBundleIdentifier;
@property(nonatomic, copy) NSString *policyMenuHost;
@property(nonatomic) pid_t policyMenuProcessIdentifier;
@property(nonatomic) BOOL policyMenuScopeCaptured;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *statusMenuItem;
@property(nonatomic, strong) NSMenuItem *dataStatusMenuItem;
@property(nonatomic, strong) NSMenuItem *dataScanMenuItem;
@property(nonatomic, strong) NSMenuItem *dataPauseMenuItem;
@property(nonatomic, strong) NSMenuItem *dataDiagnosticsMenuItem;
@property(nonatomic, strong) NSMenuItem *remoteStatusMenuItem;
@property(nonatomic, strong) NSMenuItem *lastLocalCompletionMenuItem;
@property(nonatomic, strong) NSMenuItem *lastRemoteCompletionMenuItem;
@property(nonatomic, strong) NSMenuItem *suggestionPauseMenuItem;
@property(nonatomic, strong) CPADataFoundationController *dataController;
@property(nonatomic, strong) CPAConversationContextProvider *contextProvider;
@property(nonatomic, strong) CPACodexThreadIDResolver *codexIDResolver;
@property(nonatomic, copy) NSString *codexIDSignature;
@property(nonatomic, copy) NSString *codexIDTaskKey;
@property(nonatomic, copy) NSString *observedCodexTaskKey;
@property(nonatomic, copy) NSString *codexIDIdentifier;
@property(nonatomic) NSUInteger codexIDGeneration;
@property(nonatomic, strong) CPAConversationContextSnapshot *workBuddyContextSnapshot;
@property(nonatomic, copy) NSArray *observedWorkBuddyContext;
@property(nonatomic, strong) CPARemoteCompletionSettings *remoteSettings;
@property(nonatomic, strong) CPARemoteCompletionClient *remoteClient;
@property(nonatomic, strong, nullable) CPARemoteCompletionTask *remoteTask;
@property(nonatomic, strong, nullable) NSDate *remoteTaskStartedAt;
@property(nonatomic, copy, nullable) NSString *remoteTaskInput;
@property(nonatomic, copy, nullable) NSString *remoteTaskSignature;
@property(nonatomic) NSUInteger remoteTaskConversationGeneration;
@property(nonatomic, strong) CPARemoteCompletionClient *localModelClient;
@property(nonatomic, strong) CPALocalModelServiceController *localModelServiceController;
@property(nonatomic, strong, nullable) CPARemoteCompletionTask *localModelTask;
@property(nonatomic, strong, nullable) NSDate *localModelTaskStartedAt;
@property(nonatomic, strong, nullable) CPARemoteCompletionTask *localModelWarmupTask;
@property(nonatomic, copy, nullable) NSString *localModelTaskInput;
@property(nonatomic, copy, nullable) NSString *localModelTaskSignature;
@property(nonatomic) NSUInteger localModelTaskConversationGeneration;
@property(nonatomic, copy, nullable) NSString *localModelDisplayedSignature;
@property(nonatomic) BOOL localModelDisplayedPreview;
@property(nonatomic, copy, nullable) NSString *remoteDisplayedSignature;
@property(nonatomic, strong) dispatch_queue_t remotePreparationQueue;
@property(nonatomic, strong, nullable) NSTimer *remotePreparationTimeoutTimer;
@property(nonatomic, strong) CPAOverlayController *overlayController;
@property(nonatomic, strong) CPAKeyboardInterceptor *keyboardInterceptor;
@property(nonatomic, strong) CPALocalSuggestionCoordinator *suggestionCoordinator;
@property(nonatomic, copy) NSString *lastLocalSuggestionSource;
@property(nonatomic, strong, nullable) CPAAccessibilitySnapshot *lastUsableSnapshot;
@property(nonatomic) pid_t lastUsableSnapshotProcessIdentifier;
@property(nonatomic) pid_t lastObservedCodexProcessIdentifier;
// Updated only from launch/activate/terminate notifications (plus one
// startup discovery). The 100ms poll and keyboard event tap read this value
// without asking LaunchServices synchronously.
@property(nonatomic) pid_t cachedCodexProcessIdentifier;
@property(nonatomic) BOOL codexProcessCacheInitialized;
@property(nonatomic) CGRect fallbackInputFrame;
@property(nonatomic) BOOL fallbackInputFrameAvailable;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong, nullable) NSTimer *suggestionTimer;
@property(nonatomic, strong, nullable) NSTimer *localModelSuggestionTimer;
@property(nonatomic, strong, nullable) NSTimer *modelSuggestionTimer;
@property(nonatomic, strong, nullable) NSTimer *focusLossTimer;
@property(nonatomic, strong, nullable) NSTimer *focusRecoveryTimer;
@property(nonatomic, copy, nullable) NSString *lastObservedSignature;
@property(nonatomic, copy, nullable) NSString *lastObservedInputText;
@property(nonatomic, strong, nullable) NSDate *lastObservedInputChangeDate;
@property(nonatomic, strong, nullable) NSDate *lastInputModelCancellationDate;
@property(nonatomic) NSUInteger recentInputModelCancellationCount;
@property(nonatomic, copy, nullable) NSString *dismissedSignature;
@property(nonatomic, copy, nullable) NSString *dismissedInputText;
@property(nonatomic, copy, nullable) NSString *programmaticInsertionExpectedInput;
@property(nonatomic, copy, nullable) NSString *acceptedContinuationSignature;
@property(nonatomic, copy, nullable) NSString *acceptedContinuationInput;
@property(nonatomic) NSUInteger acceptedContinuationContextRevision;
@property(nonatomic, copy, nullable) NSString *displayedSuggestionSignature;
@property(nonatomic, copy, nullable) NSString *displayedSuggestionInputText;
@property(nonatomic) NSUInteger displayedSuggestionConversationGeneration;
@property(nonatomic, strong, nullable) NSDate *lastSuggestionAcceptedDate;
@property(nonatomic, copy, nullable) NSString *cachedAPIKey;
@property(nonatomic, copy, nullable) NSString *pendingRemoteInsertion;
@property(nonatomic, copy, nullable) NSString *pendingRemoteRequestedInput;
@property(nonatomic, strong, nullable) NSDate *pendingRemoteExpiry;
@property(nonatomic) NSUInteger pendingRemoteConversationGeneration;
@property(nonatomic, strong, nullable) NSDate *lastAccessibilityRefreshDate;
@property(nonatomic, copy, nullable) NSString *remotePreparationSignature;
@property(nonatomic, copy, nullable) NSString *remotePreparationInput;
@property(nonatomic) NSUInteger remotePreparationGeneration;
@property(nonatomic) NSUInteger remotePreparationConversationGeneration;
@property(nonatomic) NSUInteger suggestionTimerConversationGeneration;
@property(nonatomic) NSUInteger localModelSuggestionTimerConversationGeneration;
@property(nonatomic) NSUInteger modelSuggestionTimerConversationGeneration;
@property(nonatomic) NSUInteger conversationGeneration;
@property(nonatomic) NSUInteger localModelTaskContextGeneration;
@property(nonatomic) NSUInteger remoteTaskContextGeneration;
@property(nonatomic, strong, nullable) CPAConversationContextSnapshot *localTaskContext;
@property(nonatomic, strong, nullable) CPAConversationContextSnapshot *remoteTaskContext;
@property(nonatomic, strong, nullable) CPAConversationContextSnapshot *remotePreparationContext;
@property(nonatomic, strong, nullable) CPAConversationContextSnapshot *displayedContext;
@property(nonatomic, strong, nullable) CPAConversationContextSnapshot *pendingRemoteContext;
@property(nonatomic, strong, nullable) CPAConversationContextSnapshot *acceptanceContext;
@property(nonatomic, copy, nullable) NSString *pendingRemoteSignature;
@property(nonatomic) NSUInteger observedContextRevision;
@property(nonatomic) NSUInteger contextRetryAttempts;
@property(nonatomic, copy, nullable) NSString *lastComposerIdentifier;
@property(nonatomic, copy, nullable) NSString *lastConversationTitle;
@property(nonatomic, copy, nullable) NSString *lastDiagnostic;
// Frontmost identity is updated from NSWorkspace activation notifications and
// read by the hot keyboard path. Avoid synchronously asking LaunchServices on
// every key event or 100ms poll, which can stall the global event tap.
@property(nonatomic, copy) NSString *cachedFrontmostBundleIdentifier;
@property(nonatomic, copy) NSString *cachedFrontmostApplicationName;
@property(nonatomic) pid_t cachedFrontmostProcessIdentifier;
@property(nonatomic) BOOL frontmostStateInitialized;
@property(nonatomic) BOOL cachedAccessibilityPermissionGranted;
@property(nonatomic) BOOL accessibilityPermissionKnown;
@property(nonatomic, strong, nullable) CPAAccessibilitySnapshot *cachedGenericSnapshot;
@property(nonatomic, strong, nullable) NSDate *lastGenericMetadataProbeDate;
@property(nonatomic, strong) dispatch_queue_t genericAccessibilityQueue;
@property(nonatomic) BOOL genericProbeInProgress;
@property(nonatomic) NSUInteger genericProbeGeneration;
@property(nonatomic, copy, nullable) NSString *genericProbeBundleIdentifier;
@property(nonatomic) pid_t genericProbeProcessIdentifier;
@property(nonatomic) BOOL inputEventRefreshPending;
@property(nonatomic) BOOL processingPublishedCodexSnapshot;
@property(nonatomic) BOOL openRemoteSettingsOnLaunch;
@property(nonatomic) BOOL suggestionsPaused;
@property(nonatomic) NSUInteger acceptanceGeneration;
@property(nonatomic) BOOL acceptancePending;
@property(nonatomic, strong) NSTimer *acceptanceTimeoutTimer;
@property(nonatomic) BOOL latestObservedEditWasDeletion;
- (void)clearPendingRemoteSuggestion;
- (BOOL)displayPendingRemoteSuggestionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature;
- (void)observeConversationIdentityForSnapshot:(CPAAccessibilitySnapshot *)snapshot;
- (void)resetSuggestionStateForConversationBoundaryWithTitle:
    (nullable NSString *)conversationTitle reason:(NSString *)reason;
- (CPAConversationContextSnapshot *)completionContextForSnapshot:(CPAAccessibilitySnapshot *)snapshot;
- (BOOL)contextIsCurrent:(CPAConversationContextSnapshot *)context;
- (void)conversationContextDidChange;
- (void)selectConversationContextWithTitle:(nullable NSString *)conversationTitle;
- (NSString *)codexTaskKeyForSnapshot:(CPAAccessibilitySnapshot *)snapshot;
- (BOOL)ensureCodexIDForSnapshot:(CPAAccessibilitySnapshot *)snapshot signature:(NSString *)signature;
- (void)requestIDVerifiedAcceptanceSnapshotForBundleIdentifier:(NSString *)bundle
    processIdentifier:(pid_t)pid completion:(void (^)(CPAAccessibilitySnapshot *))completion;
- (void)configureLocalModelCompletion;
- (void)warmLocalModel;
- (void)cancelLocalModelWarmupIfPending;
- (void)startLocalModelSuggestionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature;
- (nullable CPAAccessibilitySnapshot *)snapshotByApplyingShadowBufferToSnapshot:
    (CPAAccessibilitySnapshot *)snapshot;
- (CPAAccessibilitySnapshot *)snapshotForSuggestion;
- (CPAAccessibilitySnapshot *)snapshotForStreamingSuggestion;
- (void)scheduleLocalModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature delay:(NSTimeInterval)delay;
- (void)scheduleRemoteModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature delay:(NSTimeInterval)delay;
- (void)startDelayedLocalModelSuggestions:(NSTimer *)timer;
- (void)startDelayedRemoteModelSuggestions:(NSTimer *)timer;
- (nullable CPAAccessibilitySnapshot *)validatedModelSuggestionSnapshotForSignature:
    (NSString *)signature conversationGeneration:(NSUInteger)conversationGeneration;
- (void)scheduleModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature delay:(NSTimeInterval)delay;
- (void)scheduleContextReadyRetryForSignature:(NSString *)signature;
- (void)clearDisplayedSuggestionState;
- (void)invalidateSuggestionTimersAndPreparation;
- (void)cancelPendingSuggestionForReason:(NSString *)reason;
- (void)cancelPendingSuggestionKeepingRemoteTaskForReason:(NSString *)reason;
- (void)recoverSuggestionServiceWithReason:(NSString *)reason
    resumeIfPaused:(BOOL)resumeIfPaused;
- (void)pauseSuggestionsWithReason:(NSString *)reason;
- (void)resumeSuggestions;
- (void)updateSuggestionsPausedUI;
- (CPAAccessibilitySnapshot *)inspectCurrentTarget;
- (void)configureCodexSnapshotBroker;
- (void)requestCodexSnapshotRefresh;
- (void)publishCodexSnapshot:(CPAAccessibilitySnapshot *)snapshot
    processIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier;
- (CPAAccessibilitySnapshot *)decorateCodexSnapshot:(CPAAccessibilitySnapshot *)snapshot;
- (CPAAccessibilitySnapshot *)snapshotForCodexMetadataUnavailable;
- (CPAAccessibilitySnapshot *)updateStatusWithSnapshot:(CPAAccessibilitySnapshot *)snapshot;
- (void)observeRuntimeBoundaryForSnapshot:(CPAAccessibilitySnapshot *)snapshot;
- (void)updateFrontmostApplicationState:(nullable NSRunningApplication *)application;
- (void)refreshCachedCodexProcessIdentifier;
- (void)workspaceCodexProcessLifecycle:(NSNotification *)notification;
- (void)scheduleGenericMetadataProbeForBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier;
- (CPAAccessibilitySnapshot *)snapshotForGenericMetadataUnavailable;
@end

@implementation CPAAppDelegate
@synthesize suggestionsPaused = _suggestionsPaused;

- (void)syncCodexInputReadingState {
    [self invalidatePendingAcceptance];
    self.accessibilityService.inputReadingPaused = self.suggestionsPaused
        || (self.remoteSettings.localPaused && self.remoteSettings.paused);
    [self.codexSnapshotBroker invalidate];
    self.cachedCodexSnapshot = nil;
}

- (void)setSuggestionsPaused:(BOOL)paused {
    _suggestionsPaused = paused;
    [self syncCodexInputReadingState];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.codexIDResolver = [CPACodexThreadIDResolver new];
    self.openRemoteSettingsOnLaunch = [NSProcessInfo.processInfo.arguments
        containsObject:@"--open-remote-settings"];
    [self updateFrontmostApplicationState:
        NSWorkspace.sharedWorkspace.frontmostApplication];
    [self refreshCachedCodexProcessIdentifier];
    self.accessibilityService = [[CPAAccessibilityService alloc] init];
    self.genericAccessibilityService =
        [[CPAGenericAccessibilityService alloc] init];
    __weak CPAAppDelegate *genericContextOwner = self;
    self.genericAccessibilityService.contextReadingPaused = ^BOOL {
        CPAAppDelegate *owner = genericContextOwner;
        return owner == nil || owner.accessibilityService.inputReadingPaused;
    };
    self.suggestionPolicyStore = [[CPASuggestionPolicyStore alloc] init];
    self.policyCoordinator = [[CPASuggestionPolicyCoordinator alloc]
        initWithStore:self.suggestionPolicyStore];
    self.genericAccessibilityService.policyCoordinator = self.policyCoordinator;
    self.safeInputCollector = [[CPASafeInputContextCollector alloc]
        initWithPolicyCoordinator:self.policyCoordinator
        bodyReader:self.genericAccessibilityService];
    [self configureCodexSnapshotBroker];
    self.contextGenerationTracker =
        [[CPASuggestionContextGenerationTracker alloc] init];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
        selector:@selector(workspaceApplicationDidActivate:)
        name:NSWorkspaceDidActivateApplicationNotification
        object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
        selector:@selector(workspaceCodexProcessLifecycle:)
        name:NSWorkspaceDidLaunchApplicationNotification
        object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
        selector:@selector(workspaceCodexProcessLifecycle:)
        name:NSWorkspaceDidTerminateApplicationNotification
        object:nil];
    self.remotePreparationQueue = dispatch_queue_create(
        "local.codex.prompt-assistant.remote-preparation",
        DISPATCH_QUEUE_CONCURRENT);
    self.genericAccessibilityQueue = dispatch_queue_create(
        "local.codex.prompt-assistant.generic-accessibility",
        DISPATCH_QUEUE_SERIAL);
    self.overlayController = [[CPAOverlayController alloc] init];
    self.keyboardInterceptor = [[CPAKeyboardInterceptor alloc] initWithDelegate:self];
    [self configureDataFoundation];
    NSURL *sessionsDirectory = [NSURL fileURLWithPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@".codex/sessions"]
        isDirectory:YES];
    self.contextProvider = [[CPAConversationContextProvider alloc]
        initWithSessionsDirectoryURL:sessionsDirectory];
    __weak CPAAppDelegate *contextOwner = self;
    self.contextProvider.snapshotDidChange = ^{ [contextOwner conversationContextDidChange]; };
    [self.contextProvider start];
    self.remoteSettings = [[CPARemoteCompletionSettings alloc] init];
    CPADiagnosticLog(@"expression library lookup paused=%@", self.remoteSettings.expressionLibraryPaused ? @"true" : @"false");
    [self syncCodexInputReadingState];
    self.localModelServiceController = [[CPALocalModelServiceController alloc] initWithPreservesResidentModel:YES];
    [self configureRemoteCompletion];
    [self configureLocalModelCompletion];
    [self configureStatusItem];
    [self updateDataMenuForSnapshot:self.dataController.currentSnapshot];
    CPADiagnosticLog(@"app launch pid=%d %@", NSProcessInfo.processInfo.processIdentifier,
        @CPA_BUILD_SUMMARY);
    if (!self.remoteSettings.onlineOnly && [self.historyDefaults boolForKey:@"history-import.approved"] && !self.historyScanUserPaused) {
        [self.dataController startScan];
    }
    [self updateStatus];
    [self.keyboardInterceptor start];
    __weak CPAAppDelegate *healthOwner = self;
    self.healthResponder = [[CPAHealthResponder alloc] initWithStateProvider:^NSDictionary *{
        CPAAppDelegate *owner = healthOwner;
        return @{@"eventTapEnabled":@(owner.keyboardInterceptor.eventTapEnabled),
            @"accessibilityGranted":@(AXIsProcessTrusted()),
            @"modelPreserved":@(owner.localModelServiceController.preservesResidentModel)};
    }];
    if (![self.healthResponder start]) CPADiagnosticLog(@"health responder=unavailable");
    if (self.lastObservedCodexProcessIdentifier > 0) {
        [self.keyboardInterceptor prepareShadowBufferForCodexActivation];
    }
    [self performSelector:@selector(warmLocalModel) withObject:nil afterDelay:0.5];
    self.pollTimer = CPAScheduleRepeatingTimer(CPASuggestionPollInterval,
        self, @selector(pollAccessibility:));
}

- (void)workspaceApplicationDidActivate:(NSNotification *)notification {
    [self invalidatePendingAcceptance];
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    [self updateFrontmostApplicationState:application];
    if (![application.bundleIdentifier isEqualToString:@"com.openai.codex"]) {
        return;
    }
    if (self.suggestionsPaused) {
        return;
    }
    [self updateStatus];
    [self.keyboardInterceptor prepareShadowBufferForCodexActivation];
    [self.focusRecoveryTimer invalidate];
    self.focusRecoveryTimer = CPAScheduleOneShotTimer(
        0.25, self, @selector(recoverCodexFocus:), @(0));
}

- (void)workspaceCodexProcessLifecycle:(NSNotification *)notification {
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    if (![application.bundleIdentifier isEqualToString:@"com.openai.codex"]) {
        return;
    }
    pid_t processIdentifier = application.processIdentifier;
    if ([notification.name isEqualToString:
            NSWorkspaceDidTerminateApplicationNotification]) {
        if (CPACodexProcessCacheShouldClearForTermination(
                self.cachedCodexProcessIdentifier, processIdentifier)) {
            self.cachedCodexProcessIdentifier = 0;
            CPADiagnosticLog(@"codex process_cache=cleared");
        }
        return;
    }
    if (CPACodexProcessCacheShouldAdoptProcess(
            self.cachedCodexProcessIdentifier, processIdentifier)) {
        self.cachedCodexProcessIdentifier = processIdentifier;
        CPADiagnosticLog(@"codex process_cache=adopted");
    }
    // Activation can arrive before the launch notification and may already
    // adopt the new PID. Recovery belongs to the launch event itself rather
    // than to the cache transition, otherwise that notification is skipped.
    // During the narrow initial setup window normal startup owns recovery.
    if (self.keyboardInterceptor != nil && self.contextProvider != nil
        && self.overlayController != nil) {
        [self recoverSuggestionServiceWithReason:@"codex_launch"
            resumeIfPaused:NO];
    }
}

- (void)recoverSuggestionService:(id)sender {
    (void)sender;
    [self recoverSuggestionServiceWithReason:@"manual_recovery"
        resumeIfPaused:YES];
}

- (void)recoverSuggestionServiceWithReason:(NSString *)reason
    resumeIfPaused:(BOOL)resumeIfPaused {
    if (self.suggestionsPaused && !resumeIfPaused) {
        CPADiagnosticLog(@"recovery skipped reason=%@ state=paused", reason);
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(warmLocalModel) object:nil];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.focusRecoveryTimer invalidate];
    self.focusRecoveryTimer = nil;
    [self cancelLocalModelWarmupIfPending];
    [self cancelPendingSuggestionForReason:reason];
    [self.suggestionCoordinator clear];
    [self.overlayController hide];
    [self clearDisplayedSuggestionState];
    [self.keyboardInterceptor stop];
    [self.keyboardInterceptor resetShadowBuffer];
    [self.contextProvider stop];
    [self.contextProvider invalidateCachedContext];
    // The AX service retains process-scoped elements, retry state, and its
    // fallback worker. Invalidating only the broker leaves those internals
    // alive after Codex replaces its renderer. Rebuild both layers so manual
    // recovery has the same clean AX state as a fresh helper launch.
    [self.codexSnapshotBroker stop];
    self.accessibilityService = [[CPAAccessibilityService alloc] init];
    [self configureCodexSnapshotBroker];
    self.cachedCodexSnapshot = nil;
    self.lastUsableSnapshot = nil;
    self.lastUsableSnapshotProcessIdentifier = 0;
    self.lastObservedCodexProcessIdentifier = 0;
    self.cachedCodexProcessIdentifier = 0;
    self.codexProcessCacheInitialized = NO;
    self.contextGenerationTracker =
        [[CPASuggestionContextGenerationTracker alloc] init];
    [self updateFrontmostApplicationState:
        NSWorkspace.sharedWorkspace.frontmostApplication];
    [self refreshCachedCodexProcessIdentifier];
    self.suggestionsPaused = NO;
    [self.contextProvider start];
    BOOL eventTapStarted = [self.keyboardInterceptor start];
    CPAAccessibilitySnapshot *snapshot = [self updateStatus];
    if (self.cachedCodexProcessIdentifier > 0) {
        [self.keyboardInterceptor prepareShadowBufferForCodexActivation];
    }
    if (snapshot.codexIsFrontmost && !snapshot.writableTextInput) {
        self.focusRecoveryTimer = CPAScheduleOneShotTimer(
            0.25, self, @selector(recoverCodexFocus:), @(0));
    }
    self.pollTimer = CPAScheduleRepeatingTimer(CPASuggestionPollInterval,
        self, @selector(pollAccessibility:));
    [self updateSuggestionsPausedUI];
    [self performSelector:@selector(warmLocalModel) withObject:nil afterDelay:0.2];
    CPADiagnosticLog(@"recovery completed reason=%@ eventTap=%@ codexRunning=%@",
        reason,
        eventTapStarted ? @"true" : @"false",
        self.cachedCodexProcessIdentifier > 0 ? @"true" : @"false");
}

- (void)updateFrontmostApplicationState:(NSRunningApplication *)application {
    NSString *bundleIdentifier = application.bundleIdentifier ?: @"";
    pid_t processIdentifier = application.processIdentifier;
    BOOL changed = !self.frontmostStateInitialized
        || self.cachedFrontmostProcessIdentifier != processIdentifier
        || ![self.cachedFrontmostBundleIdentifier isEqualToString:bundleIdentifier];
    self.cachedFrontmostBundleIdentifier = [bundleIdentifier copy];
    self.cachedFrontmostApplicationName = [application.localizedName copy] ?: @"";
    self.cachedFrontmostProcessIdentifier = processIdentifier;
    self.frontmostStateInitialized = YES;
    if ([bundleIdentifier isEqualToString:@"com.openai.codex"]
        && CPACodexProcessCacheShouldAdoptProcess(
            self.cachedCodexProcessIdentifier, processIdentifier)) {
        self.cachedCodexProcessIdentifier = processIdentifier;
        CPADiagnosticLog(@"codex process_cache=adopted");
    }
    if (changed) {
        self.cachedGenericSnapshot = nil;
        self.lastGenericMetadataProbeDate = nil;
        if (![bundleIdentifier isEqualToString:@"com.openai.codex"]
            && self.cachedCodexSnapshot != nil) {
            self.cachedCodexSnapshot = nil;
        }
        // A frontmost-app/PID change is a hard context boundary. Invalidate
        // any in-flight AX result so it cannot be published after the user
        // returns to a different window.
        [self.codexSnapshotBroker invalidate];
        // Invalidate any result already queued for the previous target. The
        // background AX work itself is not cancelled, but its callback will
        // be discarded by the generation check.
        self.genericProbeGeneration++;
        // The old callback is discarded by generation. Release its busy marker
        // here so returning to the same application can start a fresh probe.
        self.genericProbeInProgress = NO;
        self.genericProbeBundleIdentifier = nil;
        self.genericProbeProcessIdentifier = 0;
    }
}

- (NSString *)keyboardInterceptorCurrentFrontmostBundleIdentifier {
    return self.cachedFrontmostBundleIdentifier ?: @"";
}

- (pid_t)keyboardInterceptorCurrentFrontmostProcessIdentifier {
    return self.cachedFrontmostProcessIdentifier;
}

- (void)keyboardInterceptorDidObservePossibleTaskNavigation {
    if (!self.codexIDResolver || ![self.cachedFrontmostBundleIdentifier isEqual:@"com.openai.codex"]) return;
    self.conversationGeneration++;
    [self cancelPendingSuggestionForReason:@"possible_task_navigation"];
    self.lastObservedSignature = nil;
}

- (void)keyboardInterceptorDidObserveInputEvent {
    if (self.codexIDResolver != nil && [self.cachedFrontmostBundleIdentifier isEqual:@"com.openai.codex"]) {
        self.codexIDGeneration++;
        [self.codexIDResolver cancel];
        // The queued authoritative snapshot decides whether selection changed.
        // A keystroke invalidates in-flight acquisition, not a verified task ID.
    }
    [self invalidatePendingAcceptance];
    BOOL observationAllowed = [self keyboardInterceptorShouldObserveCurrentInput];
    if (!CPAInputEventRefreshShouldSchedule(observationAllowed,
            self.suggestionsPaused, self.inputEventRefreshPending)) {
        return;
    }
    // The CGEvent tap runs on the main run loop. Queue the refresh in common
    // modes so the host event is delivered before any AX/suggestion work and
    // multiple edits observed in one turn collapse into one refresh.
    self.inputEventRefreshPending = YES;
    __weak CPAAppDelegate *weakSelf = self;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        CPAAppDelegate *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.inputEventRefreshPending = NO;
        BOOL stillAllowed = [strongSelf keyboardInterceptorShouldObserveCurrentInput];
        if (!CPAInputEventRefreshShouldSchedule(stillAllowed,
                strongSelf.suggestionsPaused, NO)) {
            return;
        }
        [strongSelf pollAccessibility:nil];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)recoverCodexFocus:(NSTimer *)timer {
    self.focusRecoveryTimer = nil;
    if (self.suggestionsPaused) {
        return;
    }
    NSUInteger attempt = [timer.userInfo unsignedIntegerValue];
    [self requestCodexSnapshotRefresh];
    CPAAccessibilitySnapshot *snapshot = [self updateStatus];
    if (!snapshot.codexIsFrontmost || snapshot.writableTextInput) {
        return;
    }
    CPADiagnosticLog(@"focus recovery attempt=%lu refreshed=%@ focused=%@",
        (unsigned long)attempt,
        snapshot.writableTextInput ? @"true" : @"false",
        @"deferred");
    // A freshly restarted Chromium/Codex process may expose its AX tree only
    // after the first attempt. Do not stop merely because there is no
    // last-known element to focus; keep probing the live window for a short,
    // bounded period so Codex restarts recover without requiring another
    // helper restart.
    if (attempt >= 8) {
        CPADiagnosticLog(@"focus recovery exhausted attempts=%lu",
            (unsigned long)(attempt + 1));
        return;
    }
    self.focusRecoveryTimer = CPAScheduleOneShotTimer(
        0.25, self, @selector(recoverCodexFocus:), @(attempt + 1));
}

- (void)configureStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [self assistantStatusImage];
    NSMenu *menu = [NSMenu new]; menu.autoenablesItems = NO; menu.delegate = self;
    self.remoteStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"在线续写" action:nil keyEquivalent:@""];
    self.remoteStatusMenuItem.enabled = NO; [menu addItem:self.remoteStatusMenuItem];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"设置…" action:@selector(showRemoteSettings:) keyEquivalent:@","];
    settings.target = self; [menu addItem:settings];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出续言" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self; [menu addItem:quit]; self.statusItem.menu = menu;
    self.lastRemoteCompletionMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [self updateRemoteStatusMenu];
    if (self.openRemoteSettingsOnLaunch || !self.suggestionPolicyStore.storedApplicationIdentifiers.count)
        [self performSelector:@selector(showRemoteSettings:) withObject:nil afterDelay:0.2];
}

- (void)configureRemoteCompletion {
    [self.remoteClient cancelActiveRequest];
    self.remoteClient = nil;
    if (self.remoteSettings.paused) return;
    NSURLSessionConfiguration *configuration =
        NSURLSessionConfiguration.ephemeralSessionConfiguration;
    self.remoteClient = [[CPARemoteCompletionClient alloc]
        initWithBaseURL:self.remoteSettings.baseURL
        sessionConfiguration:configuration
        callbackQueue:dispatch_get_main_queue()];
    self.remoteClient.requiresFinalValidation = YES;
}

- (void)configureLocalModelCompletion {
    [self.localModelClient cancelActiveRequest];
    self.localModelClient = nil;
    if (self.remoteSettings.localPaused) return;
    [self.localModelServiceController ensureRunning];
    NSURLSessionConfiguration *configuration =
        NSURLSessionConfiguration.ephemeralSessionConfiguration;
    self.localModelClient = [[CPARemoteCompletionClient alloc]
        initWithBaseURL:[NSURL URLWithString:CPALocalModelBaseURL]
        sessionConfiguration:configuration
        callbackQueue:dispatch_get_main_queue()];
    self.localModelClient.progressMinimumCharacterCount = 8;
    self.localModelClient.progressMinimumCharacterDelta = 4;
    self.localModelClient.requiresFinalValidation = YES;
    self.localModelClient.usesLocalPrefixCompletion = YES;
}

- (void)configureCodexSnapshotBroker {
    CPAAccessibilityService *service = self.accessibilityService;
    // Both launch and manual recovery create a new service through this path.
    service.policyCoordinator = self.policyCoordinator;
    service.inputReadingPaused = self.suggestionsPaused
        || (self.remoteSettings.localPaused && self.remoteSettings.paused);
    __weak CPAAppDelegate *weakSelf = self;
    self.codexSnapshotBroker = [[CPAAccessibilitySnapshotBroker alloc]
        initWithProvider:^CPAAccessibilitySnapshot *(
            pid_t processIdentifier, pid_t frontmostProcessIdentifier) {
            // Every potentially blocking AX/CGWindow operation is kept inside
            // the broker's serial worker. The main run loop only receives the
            // finished immutable snapshot.
            CPAAccessibilitySnapshot *snapshot = [service
                inspectFocusedElementForCodexProcessIdentifier:processIdentifier
                frontmostProcessIdentifier:frontmostProcessIdentifier];
            if (snapshot.codexInputDecision != nil
                && snapshot.codexInputDecision.outcome == CPASuggestionPolicyOutcomeDisabled) {
                return snapshot;
            }
            if (snapshot.rendererAccessibilitySuspected) {
                [service tryEnableRuntimeAccessibilityForProcessIdentifier:
                    processIdentifier];
            }
            if (snapshot.codexIsFrontmost && !snapshot.writableTextInput) {
                BOOL refreshed = [service
                    refreshCurrentCodexTextInputForProcessIdentifier:processIdentifier
                    frontmostProcessIdentifier:frontmostProcessIdentifier];
                if (refreshed) {
                    snapshot = [service
                        inspectFocusedElementForCodexProcessIdentifier:processIdentifier
                        frontmostProcessIdentifier:frontmostProcessIdentifier];
                }
            }
            if (snapshot.codexIsFrontmost) {
                CGRect fallbackFrame = CGRectZero;
                BOOL fallbackAvailable = [service
                    currentCodexFallbackInputFrame:&fallbackFrame
                    forProcessIdentifier:processIdentifier
                    frontmostProcessIdentifier:frontmostProcessIdentifier];
                snapshot.hasFallbackInputFrame = fallbackAvailable;
                snapshot.fallbackInputFrame = fallbackFrame;
            }
            return snapshot;
        }
        callbackQueue:dispatch_get_main_queue()
        delivery:^(CPAAccessibilitySnapshot *snapshot,
            pid_t processIdentifier, pid_t frontmostProcessIdentifier,
            NSUInteger generation) {
            (void)generation;
            CPAAppDelegate *strongSelf = weakSelf;
            if (strongSelf == nil
                || ![strongSelf.cachedFrontmostBundleIdentifier
                    isEqualToString:@"com.openai.codex"]
                || strongSelf.cachedFrontmostProcessIdentifier
                    != frontmostProcessIdentifier
                || strongSelf.cachedCodexProcessIdentifier != processIdentifier) {
                return;
            }
            [strongSelf publishCodexSnapshot:snapshot
                processIdentifier:processIdentifier
                frontmostProcessIdentifier:frontmostProcessIdentifier];
        }];
}

- (void)requestCodexSnapshotRefresh {
    if (self.processingPublishedCodexSnapshot
        || self.codexSnapshotBroker == nil
        || ![self.cachedFrontmostBundleIdentifier
            isEqualToString:@"com.openai.codex"]) {
        return;
    }
    pid_t processIdentifier = self.cachedCodexProcessIdentifier;
    pid_t frontmostProcessIdentifier = self.cachedFrontmostProcessIdentifier;
    if (processIdentifier <= 0 || frontmostProcessIdentifier != processIdentifier) {
        return;
    }
    [self.codexSnapshotBroker requestSnapshotForProcessIdentifier:processIdentifier
        frontmostProcessIdentifier:frontmostProcessIdentifier];
}

- (CPAAccessibilitySnapshot *)decorateCodexSnapshot:
    (CPAAccessibilitySnapshot *)snapshot {
    if (snapshot == nil) {
        return [self snapshotForCodexMetadataUnavailable];
    }
    BOOL paused = self.suggestionsPaused
        || (self.remoteSettings.localPaused && self.remoteSettings.paused);
    BOOL currentVerdict = snapshot.codexInputDecision != nil
        && snapshot.codexIsFrontmost
        && snapshot.policyRuleVersion == self.policyCoordinator.ruleVersion
        && snapshot.inputReadingGeneration == self.accessibilityService.inputReadingGeneration;
    CPASuggestionDecision *decision = currentVerdict && !paused
        ? snapshot.codexInputDecision
        : [self.policyCoordinator decisionForBundleIdentifier:@"com.openai.codex"
            role:@"" subrole:@"" semanticMetadata:@[] browserHost:@""
            globallyPaused:paused temporarilyPaused:NO];
    if (decision == nil || decision.outcome == CPASuggestionPolicyOutcomeDisabled) {
        snapshot.codexInputDecision = decision;
        snapshot.inputText = nil;
        snapshot.conversationTitle = nil;
        snapshot.valueCharacterCount = 0;
        snapshot.hasValueCharacterCount = NO;
        snapshot.hasSelectedRange = NO;
        snapshot.writableTextInput = NO;
        snapshot.hasFallbackInputFrame = NO;
        self.lastUsableSnapshot = nil;
        self.lastUsableSnapshotProcessIdentifier = 0;
    }
    snapshot.targetApplicationIsFrontmost = snapshot.codexIsFrontmost;
    snapshot.targetBundleIdentifier = @"com.openai.codex";
    snapshot.targetProcessIdentifier = self.cachedFrontmostProcessIdentifier;
    snapshot.suggestionPolicyOutcome = decision.outcome;
    snapshot.contextAccessMode = decision.contextMode;
    snapshot.suggestionPolicyReason = decision.reason;
    snapshot.policyRuleVersion = self.policyCoordinator.ruleVersion;
    snapshot.policyStatusText = [NSString stringWithFormat:@"Codex · %@",
        decision.statusText];
    self.currentPolicyDecision = decision;
    self.currentPolicyBundleIdentifier = @"com.openai.codex";
    self.cachedAccessibilityPermissionGranted = snapshot.permissionGranted;
    self.accessibilityPermissionKnown = YES;
    return snapshot;
}

- (CPAAccessibilitySnapshot *)snapshotForCodexMetadataUnavailable {
    pid_t processIdentifier = self.cachedCodexProcessIdentifier;
    pid_t frontmostProcessIdentifier = self.cachedFrontmostProcessIdentifier;
    CPAAccessibilitySnapshot *snapshot = [[CPAAccessibilitySnapshot alloc] init];
    snapshot.permissionGranted = self.accessibilityPermissionKnown
        ? self.cachedAccessibilityPermissionGranted : NO;
    snapshot.codexIsRunning = processIdentifier > 0;
    snapshot.codexIsFrontmost = processIdentifier > 0
        && processIdentifier == frontmostProcessIdentifier;
    snapshot.targetApplicationIsFrontmost = snapshot.codexIsFrontmost;
    snapshot.targetBundleIdentifier = @"com.openai.codex";
    snapshot.targetProcessIdentifier = processIdentifier;
    snapshot.focusedRole = nil;
    snapshot.diagnostic = @"snapshot_pending background=true";
    return [self decorateCodexSnapshot:snapshot];
}

- (void)publishCodexSnapshot:(CPAAccessibilitySnapshot *)snapshot
    processIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier {
    if (snapshot == nil
        || processIdentifier != self.cachedCodexProcessIdentifier
        || frontmostProcessIdentifier != self.cachedFrontmostProcessIdentifier
        || ![self.cachedFrontmostBundleIdentifier
            isEqualToString:@"com.openai.codex"]) {
        return;
    }
    CPAAccessibilitySnapshot *decorated = [self decorateCodexSnapshot:snapshot];
    self.cachedCodexSnapshot = decorated;
    [self updateStatusWithSnapshot:decorated];
    // Process the completed snapshot immediately so a 100ms polling tick does
    // not add another full debounce interval before the first model request.
    self.processingPublishedCodexSnapshot = YES;
    [self pollAccessibility:nil];
    self.processingPublishedCodexSnapshot = NO;
}

- (void)warmLocalModel {
    if (self.remoteSettings.localPaused || self.suggestionsPaused) return;
    // Never let launch warm-up cancel a real suggestion that typing already
    // started. That request will warm the same resident model by itself. A
    // debounce timer is also considered pending: starting warm-up beside it
    // makes the one-task client cancel the user's first request.
    BOOL suggestionWorkPending = self.suggestionTimer != nil
        || self.localModelSuggestionTimer != nil
        || self.modelSuggestionTimer != nil
        || (self.lastObservedInputChangeDate != nil
            && self.lastObservedInputText.length > 0);
    if (self.localModelWarmupTask != nil
        || !CPALocalModelWarmupMayStartWithPendingWork(
            self.localModelTask != nil, suggestionWorkPending)) {
        CPADiagnosticLog(@"local_model warmup skipped=pending_work");
        return;
    }
    __weak CPAAppDelegate *weakSelf = self;
    __block CPARemoteCompletionTask *issuedWarmupTask = nil;
    NSDate *startedAt = [NSDate date];
    issuedWarmupTask = [self.localModelClient requestCompletionForInput:@"请继续优化这个方案"
        contextMessages:@[]
        apiKey:CPALocalModelAPIKey
        preferredModel:CPALocalModelName
        progress:nil
        completion:^(CPARemoteCompletionResult *result) {
            CPAAppDelegate *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.localModelWarmupTask != issuedWarmupTask) return;
            strongSelf.localModelWarmupTask = nil;
            // Surface the existing startup request without issuing a new probe,
            // publishing its synthetic text, or mixing it into input-request timing.
            // Cancellation/late replies must not overwrite a newer user result.
            if (result.outcome != CPARemoteCompletionOutcomeCancelled) {
                NSString *status = result.outcome == CPARemoteCompletionOutcomeSuccess
                    ? @"服务曾响应" : CPALastCompletionStatusText(result.outcome, result.phase, NO);
                strongSelf.lastLocalCompletionMenuItem.title =
                    [@"本机启动检查：" stringByAppendingString:status];
            }
            CPADiagnosticLog(@"local_model warmup outcome=%ld phase=%@ durationMs=%lu totalMs=%lu",
                (long)result.outcome,
                result.phase,
                (unsigned long)result.durationMilliseconds,
                (unsigned long)llround(-[startedAt timeIntervalSinceNow] * 1000.0));
        }];
    self.localModelWarmupTask = issuedWarmupTask;
}

- (void)cancelLocalModelWarmupIfPending {
    CPARemoteCompletionTask *warmupTask = self.localModelWarmupTask;
    if (warmupTask == nil) {
        return;
    }
    self.localModelWarmupTask = nil;
    [warmupTask cancel];
    CPADiagnosticLog(@"local_model warmup cancelled=real_input");
}

// Freeze the exact scope when opening the menu; never derive it from a
// cache after invalidation or from the helper's own focused menu item.
- (CPAApplicationRule *)currentMenuRule {
    return CPASuggestionPolicyApplicationIsBrowser(self.policyMenuBundleIdentifier)
        ? [self.suggestionPolicyStore ruleForBrowserHost:self.policyMenuHost]
        : [self.suggestionPolicyStore ruleForBundleIdentifier:self.policyMenuBundleIdentifier];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    // AppKit can call this repeatedly during one tracking session. Keep the
    // displayed scope immutable; applyCurrentMenuRule rejects a changed PID.
    if (self.policyMenuScopeCaptured) {
        [self updateCurrentPolicyControls];
        return;
    }
    self.policyMenuScopeCaptured = YES;
    NSRunningApplication *application = NSWorkspace.sharedWorkspace.frontmostApplication;
    self.policyMenuBundleIdentifier = application.bundleIdentifier ?: @"";
    self.policyMenuProcessIdentifier = application.processIdentifier;
    CPAAccessibilitySnapshot *snapshot = self.cachedGenericSnapshot;
    self.policyMenuHost = snapshot.targetProcessIdentifier == application.processIdentifier
        && [snapshot.targetBundleIdentifier isEqualToString:self.policyMenuBundleIdentifier]
        ? (snapshot.browserHost ?: @"") : @"";
    self.policyScopeMenuItem.title = CPAApplicationPolicyScopeTitle(
        application.localizedName ?: @"", self.policyMenuBundleIdentifier, self.policyMenuHost);
    [self updateCurrentPolicyControls];
}

- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    // Preserve captured fields for the selected action (which may be delivered
    // after menuDidClose), but allow the next opening to capture a new scope.
    self.policyMenuScopeCaptured = NO;
}

- (void)updateCurrentPolicyControls {
    BOOL configurable = CPAApplicationPolicyScopeCanBeConfigured(
        self.policyMenuBundleIdentifier, self.policyMenuHost);
    CPAApplicationRule *rule = [self currentMenuRule];
    BOOL scopeDisabled = [self currentMenuScopeIsDisabled];
    self.quickScopeMenuItem.enabled = configurable && self.policyMenuBundleIdentifier.length > 0;
    NSString *scope = CPASuggestionPolicyApplicationIsBrowser(self.policyMenuBundleIdentifier) ? @"站点" : @"应用";
    self.quickScopeMenuItem.title = [NSString stringWithFormat:@"在此%@%@提示", scope, scopeDisabled ? @"启用" : @"关闭"];
    for (NSMenuItem *item in self.policyModeMenuItems) {
        item.enabled = configurable;
        item.state = item.tag == rule.mode ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.policySearchMenuItem.enabled = configurable;
    self.policySearchMenuItem.state = rule.searchExceptionEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL codex = [self.policyMenuBundleIdentifier isEqual:@"com.openai.codex"];
    BOOL browser = CPASuggestionPolicyApplicationIsBrowser(self.policyMenuBundleIdentifier);
    self.policyRemoteMenuItem.enabled = configurable && self.policyMenuBundleIdentifier.length>0 && !codex;
    self.policyRemoteMenuItem.title = codex ? @"Codex 联网由全局远程开关控制"
        : (browser ? @"允许此站点联网补全" : @"允许此应用联网补全");
    self.policyRemoteMenuItem.state = (codex ? !self.remoteSettings.paused : rule.remoteCompletionAuthorized)
        ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *hint;
    if (!configurable) hint = @"当前范围不可配置，保持保护";
    else if (rule.mode == CPAApplicationPolicyModeDisabled) hint = @"当前范围已关闭";
    else if (self.remoteSettings.localPaused && self.remoteSettings.paused) hint = @"本地和远程补全均已关闭";
    else if (!codex && !rule.remoteCompletionAuthorized && self.remoteSettings.localPaused)
        hint = @"此处无可用来源：本地已关闭，联网未允许";
    else if (!codex && !rule.remoteCompletionAuthorized) hint = @"此处仅使用本地补全";
    else if (self.remoteSettings.paused) hint = @"联网已允许；全局远程开关已关闭";
    else hint = @"仅在允许的输入框补全；敏感输入始终受保护";
    self.policyProviderHintMenuItem.title = hint;
}

- (void)applyCurrentMenuRule:(CPAApplicationRule *)rule {
    CPADiagnosticLog(@"policy change mode=%ld targetPID=%d frontPID=%d configurable=%@",
        (long)rule.mode, self.policyMenuProcessIdentifier,
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier,
        CPAApplicationPolicyScopeCanBeConfigured(self.policyMenuBundleIdentifier,
            self.policyMenuHost) ? @"true" : @"false");
    if (!CPAApplicationPolicyScopeCanBeConfigured(self.policyMenuBundleIdentifier,
            self.policyMenuHost)
        || NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier
            != self.policyMenuProcessIdentifier) {
        return;
    }
    if (CPASuggestionPolicyApplicationIsBrowser(self.policyMenuBundleIdentifier)) {
        if (![self.suggestionPolicyStore setRule:rule forBrowserHost:self.policyMenuHost]) {
            return;
        }
    } else {
        [self.suggestionPolicyStore setRule:rule
            forBundleIdentifier:self.policyMenuBundleIdentifier];
    }
    [self invalidateSuggestionsAfterRuleChange];
}

- (void)invalidateSuggestionsAfterRuleChange {
    [self resetSuggestionStateForConversationBoundaryWithTitle:nil reason:@"policy_changed"];
    self.currentPolicyDecision = nil;
    self.genericProbeGeneration++;
    self.genericProbeInProgress = NO;
    self.cachedGenericSnapshot = nil;
    self.lastGenericMetadataProbeDate = nil;
    self.cachedCodexSnapshot = nil;
    [self.codexSnapshotBroker invalidate];
    [self updateStatus];
}

- (BOOL)currentMenuScopeIsDisabled {
    CPAApplicationRule *rule = [self currentMenuRule];
    CPAApplicationDefaultPolicyClass policyClass =
        CPASuggestionPolicyDefaultClassForApplication(self.policyMenuBundleIdentifier);
    return rule.mode == CPAApplicationPolicyModeDisabled
        || (rule.mode == CPAApplicationPolicyModeRecommended
            && policyClass != CPAApplicationDefaultPolicyClassStandard
            && policyClass != CPAApplicationDefaultPolicyClassCodex);
}

- (void)toggleCurrentScopeCompletion:(id)sender {
    (void)sender;
    CPAApplicationRule *old = [self currentMenuRule];
    BOOL disabled = [self currentMenuScopeIsDisabled];
    [self applyCurrentMenuRule:[[CPAApplicationRule alloc]
        initWithMode:disabled ? CPAApplicationPolicyModeEnableOrdinaryInputs : CPAApplicationPolicyModeDisabled
        searchExceptionEnabled:old.searchExceptionEnabled
        remoteCompletionAuthorized:old.remoteCompletionAuthorized]];
}

- (void)changeCurrentPolicyMode:(NSMenuItem *)sender {
    CPAApplicationRule *oldRule = [self currentMenuRule];
    [self applyCurrentMenuRule:[[CPAApplicationRule alloc]
        initWithMode:(CPAApplicationPolicyMode)sender.tag
        searchExceptionEnabled:oldRule.searchExceptionEnabled
        remoteCompletionAuthorized:oldRule.remoteCompletionAuthorized]];
}

- (void)toggleCurrentPolicySearch:(id)sender {
    CPAApplicationRule *oldRule = [self currentMenuRule];
    [self applyCurrentMenuRule:[[CPAApplicationRule alloc]
        initWithMode:oldRule.mode
        searchExceptionEnabled:!oldRule.searchExceptionEnabled
        remoteCompletionAuthorized:oldRule.remoteCompletionAuthorized]];
}

- (void)toggleCurrentPolicyRemote:(id)sender {
    (void)sender;
    if (self.policyMenuBundleIdentifier.length == 0
        || [self.policyMenuBundleIdentifier isEqual:@"com.openai.codex"]) return;
    CPAApplicationRule *oldRule = [self currentMenuRule];
    [self applyCurrentMenuRule:[[CPAApplicationRule alloc]
        initWithMode:oldRule.mode searchExceptionEnabled:oldRule.searchExceptionEnabled
        remoteCompletionAuthorized:!oldRule.remoteCompletionAuthorized]];
}

- (void)updateRemoteStatusMenu {
    BOOL local = !self.remoteSettings.localPaused;
    BOOL remote = !self.remoteSettings.paused;
    NSString *mode = local ? (remote ? @"本地 + 远程" : @"仅本地")
        : (remote ? @"仅远程" : @"全部关闭");
    self.remoteStatusMenuItem.title = [@"智能补全：" stringByAppendingString:mode];
    if (remote && !self.remoteSettings.configured) {
        self.remoteStatusMenuItem.title = [self.remoteStatusMenuItem.title
            stringByAppendingString:@"（远程待配置）"];
    }
}

- (void)applyCompletionConfigurationChange {
    [self syncCodexInputReadingState];
    if (self.remoteSettings.onlineOnly) [self selectConversationContextWithTitle:nil];
    // Revoke requests, late key-preparation callbacks and displayed candidates
    // before applying the provider selection. Preserve the enabled local client.
    [self cancelPendingSuggestionForReason:@"settings_changed"];
    [self cancelLocalModelWarmupIfPending];
    [self.suggestionCoordinator clear];
    [self.overlayController hide];
    [self clearDisplayedSuggestionState];
    self.cachedAPIKey = nil;
    self.lastObservedSignature = nil;
    self.lastObservedInputText = nil;
    self.lastObservedInputChangeDate = nil;
    self.dismissedSignature = nil;
    self.dismissedInputText = nil;
    [self configureRemoteCompletion];
    if (self.remoteSettings.localPaused || self.localModelClient == nil) {
        [self configureLocalModelCompletion];
    }
    [self updateRemoteStatusMenu];
    [self updateStatus];
    // The regular poll also observes the unchanged draft when focus returns
    // from the settings panel; no extra keystroke or app restart is required.
}

- (void)setRemoteNetworkingEnabled:(BOOL)enabled {
    if (self.remoteSettings.paused == !enabled) return;
    self.remoteSettings.paused = !enabled;
    [self applyCompletionConfigurationChange];
    CPADiagnosticLog(@"remote networking enabled=%@ configured=%@",
        enabled ? @"true" : @"false", self.remoteSettings.configured ? @"true" : @"false");
}

- (void)setLocalCompletionEnabled:(BOOL)enabled {
    if (self.remoteSettings.localPaused == !enabled) return;
    self.remoteSettings.localPaused = !enabled;
    [self applyCompletionConfigurationChange];
    CPADiagnosticLog(@"local completion enabled=%@", enabled ? @"true" : @"false");
}

- (void)toggleLocalCompletion:(NSButton *)sender {
    [self setLocalCompletionEnabled:sender.state == NSControlStateValueOn];
}

- (void)toggleRemoteNetworking:(NSButton *)sender {
    [self setRemoteNetworkingEnabled:sender.state == NSControlStateValueOn];
}

- (NSButton *)newRemoteNetworkingSwitch {
    NSButton *button = [NSButton checkboxWithTitle:@"远程补全（联网）"
        target:self action:@selector(toggleRemoteNetworking:)];
    button.state = self.remoteSettings.paused ? NSControlStateValueOff : NSControlStateValueOn;
    return button;
}

- (NSButton *)newLocalCompletionSwitch {
    NSButton *button = [NSButton checkboxWithTitle:@"本地补全"
        target:self action:@selector(toggleLocalCompletion:)];
    button.state = self.remoteSettings.localPaused ? NSControlStateValueOff : NSControlStateValueOn;
    return button;
}

- (NSDictionary *)settingsState {
    CPADataFoundationSnapshot *data = self.dataController.currentSnapshot;
    NSString *history = data.statusTitle ?: @"历史尚未导入";
    if (self.historyScanUserPaused) history = @"历史导入已手动暂停";
    else if (self.historyScanPausedByAssistant) history = @"历史导入随提示暂时暂停";
    else if (![self.historyDefaults boolForKey:@"history-import.approved"]) history = @"尚未允许历史导入（可选）";
    return @{
        @"paused": @(self.suggestionsPaused),
        @"local": @(!self.remoteSettings.localPaused),
        @"remote": @(!self.remoteSettings.paused),
        @"expression": @(!self.remoteSettings.expressionLibraryPaused),
        @"configured": @(self.remoteSettings.configured),
        @"endpoint": self.remoteSettings.baseURL.absoluteString ?: @"",
        @"model": self.remoteSettings.preferredModel ?: @"",
        @"localResult": self.lastLocalCompletionMenuItem.title ?: @"本地：尚无请求结果",
        @"remoteResult": self.lastRemoteCompletionMenuItem.title ?: @"远程：尚无请求结果",
        @"permission": @([self.accessibilityService isTrustedWithPrompt:NO]),
        @"history": history,
        @"historyState": @(data.state),
        @"historyUserPaused": @(self.historyScanUserPaused),
        @"historyOrigin": [self.historyDefaults stringForKey:@"history-import.origin"] ?: @"awaiting-user",
        @"ruleVersion": @(self.suggestionPolicyStore.ruleVersion),
        @"build": @CPA_BUILD_SUMMARY,
    };
}

- (NSArray<NSDictionary *> *)settingsRuleTargets {
    return CPASuggestionPolicyStore.onlineScopeTargets;
}

- (NSDictionary *)settingsRuleForTarget:(NSDictionary *)target {
    NSString *bundle = target[@"bundle"];
    NSString *host = target[@"host"];
    CPAApplicationRule *rule = host.length
        ? [self.suggestionPolicyStore ruleForBrowserHost:host]
        : [self.suggestionPolicyStore ruleForBundleIdentifier:bundle];
    return @{@"mode":@(rule.mode), @"search":@(rule.searchExceptionEnabled),
        @"remote":@(rule.remoteCompletionAuthorized), @"version":@(self.suggestionPolicyStore.ruleVersion)};
}

- (NSString *)applySettingsAction:(NSString *)action values:(NSDictionary *)values {
    if ([action isEqual:@"remote"]) {
        if ([values[@"enabled"] boolValue] && !self.remoteSettings.configured) return @"请先填写并保存 API Key。";
        [self setRemoteNetworkingEnabled:[values[@"enabled"] boolValue]];
    } else if ([action isEqual:@"permission"]) {
        [self requestAccessibilityPermission:nil];
    } else if ([action isEqual:@"service"]) {
        NSString *key = [values[@"key"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!key.length) return @"请输入 API Key。";
        if (![self.remoteSettings saveAPIKey:key preferredModel:self.remoteSettings.preferredModel error:NULL])
            return @"API Key 未保存，请重试。";
        [self applyCompletionConfigurationChange];
    } else if ([action isEqual:@"scope"]) {
        NSString *bundle = values[@"bundle"] ?: @"", *host = values[@"host"] ?: @"";
        if (host.length || ![CPASuggestionPolicyStore allowsOnlineScopeBundleIdentifier:bundle]
            || !CPAApplicationPolicyScopeCanBeConfigured(bundle, host))
            return @"此范围不可选择，保护规则仍然生效。";
        NSUInteger before = self.suggestionPolicyStore.ruleVersion;
        [self.suggestionPolicyStore setOnlineScopeSelected:[values[@"enabled"] boolValue] bundleIdentifier:bundle host:host];
        if (before == self.suggestionPolicyStore.ruleVersion) return @"范围未保存。";
        [self invalidateSuggestionsAfterRuleChange];
    } else return @"不支持的设置。";
    return nil;
}

- (void)showRemoteSettings:(id)sender {
    (void)sender;
    if (self.settingsWindowController == nil) {
        __weak CPAAppDelegate *owner = self;
        self.settingsWindowController = [[CPASettingsWindowController alloc]
            initWithStateProvider:^NSDictionary *{ return [owner settingsState]; }
            actionHandler:^NSString *(NSString *action, NSDictionary *values) {
                return [owner applySettingsAction:action values:values];
            }
            ruleProvider:^NSDictionary *(NSDictionary *target) { return [owner settingsRuleForTarget:target]; }];
    }
    [self.settingsWindowController presentWithRuleTargets:[self settingsRuleTargets]];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    (void)application; (void)visible;
    [self showRemoteSettings:nil];
    return YES;
}

- (void)configureHistoryImportPreferences:(NSUserDefaults *)defaults existingDatabase:(BOOL)existingDatabase {
    self.historyDefaults = defaults;
    self.historyScanUserPaused = [self.historyDefaults boolForKey:@"history-import.user-paused"];
    // Preserve established import behavior without presenting migration as consent.
    if ([self.historyDefaults objectForKey:@"history-import.approved"] == nil) {
        BOOL legacy = existingDatabase;
        [self.historyDefaults setBool:legacy forKey:@"history-import.approved"];
        [self.historyDefaults setObject:legacy ? @"legacy-database" : @"awaiting-user"
            forKey:@"history-import.origin"];
    }
}

- (void)configureDataFoundation {
    NSString *home = NSHomeDirectory();
    NSURL *activeDirectory = [NSURL fileURLWithPath:
        [home stringByAppendingPathComponent:@".codex/sessions"]
        isDirectory:YES];
    NSURL *archivedDirectory = [NSURL fileURLWithPath:
        [home stringByAppendingPathComponent:@".codex/archived_sessions"]
        isDirectory:YES];
    NSURL *applicationSupport = [NSURL fileURLWithPath:
        [home stringByAppendingPathComponent:@"Library/Application Support"]
        isDirectory:YES];
    NSURL *dataDirectory = [applicationSupport
        URLByAppendingPathComponent:@"CodexPromptAssistant" isDirectory:YES];
    NSURL *databaseURL = [dataDirectory URLByAppendingPathComponent:@"history-v3.sqlite3"];
    NSURL *masterKeyURL = [dataDirectory URLByAppendingPathComponent:@"master-key-v3.bin"];
    [self configureHistoryImportPreferences:NSUserDefaults.standardUserDefaults
        existingDatabase:[NSFileManager.defaultManager fileExistsAtPath:databaseURL.path]];
    CPAMasterKeyFileStore *masterKeyStore = [[CPAMasterKeyFileStore alloc]
        initWithURL:masterKeyURL];
    self.dataController = [[CPADataFoundationController alloc]
        initWithActiveDirectory:activeDirectory
        archivedDirectory:archivedDirectory
        databaseURL:databaseURL
        masterKeyProvider:^NSData *(NSError **error) {
            return [masterKeyStore keyData:error];
        }
        callbackQueue:dispatch_get_main_queue()];
    __weak CPAAppDelegate *weakSelf = self;
    self.suggestionCoordinator = [[CPALocalSuggestionCoordinator alloc]
        initWithLookup:^NSString *(NSString *input, NSUInteger cursorLocation,
            NSUInteger selectedLength) {
            if (weakSelf.remoteSettings.expressionLibraryPaused) {
                weakSelf.lastLocalSuggestionSource = @"history_paused";
                return nil;
            }
            NSString *historySuggestion = [weakSelf.dataController suggestionForInput:input
                cursorLocation:cursorLocation selectedLength:selectedLength];
            weakSelf.lastLocalSuggestionSource = historySuggestion.length > 0
                ? @"history" : @"none";
            return historySuggestion;
        }];
    self.dataController.updateHandler = ^(CPADataFoundationSnapshot *snapshot) {
        [weakSelf reconcileHistoryScanForSnapshot:snapshot];
        [weakSelf updateDataMenuForSnapshot:snapshot];
    };
}

- (void)updateDataMenuForSnapshot:(CPADataFoundationSnapshot *)snapshot {
    self.dataStatusMenuItem.title = snapshot.statusTitle;
    BOOL scanning = snapshot.state == CPADataFoundationStateScanning;
    BOOL paused = snapshot.state == CPADataFoundationStatePaused;
    self.dataScanMenuItem.enabled = !scanning && !self.suggestionsPaused;
    self.dataScanMenuItem.title = snapshot.state == CPADataFoundationStateNotScanned
        ? @"扫描并导入 Codex 历史"
        : @"重新扫描 Codex 历史";
    self.dataPauseMenuItem.hidden = !(scanning || paused);
    self.dataPauseMenuItem.enabled = !self.suggestionsPaused;
    self.dataPauseMenuItem.title = paused ? @"继续扫描" : @"暂停扫描";
    self.dataDiagnosticsMenuItem.enabled = YES;
}

- (void)startDataScan:(id)sender {
    (void)sender;
    if (self.suggestionsPaused) return;
    if (![self.historyDefaults boolForKey:@"history-import.approved"]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"扫描并导入 Codex 历史？";
        alert.informativeText = @"只读取本机 Codex 用户任务，并将正文加密保存在本机。"
            @"不会读取隐藏推理、工具输出或子代理，也不会访问网络。";
        [alert addButtonWithTitle:@"开始扫描"];
        [alert addButtonWithTitle:@"取消"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] != NSAlertFirstButtonReturn) {
            return;
        }
    }
    [self.historyDefaults setBool:YES forKey:@"history-import.approved"];
    [self.historyDefaults setObject:@"user" forKey:@"history-import.origin"];
    [self setHistoryScanUserPaused:NO];
    [self.dataController startScan];
}

- (void)setHistoryScanUserPaused:(BOOL)paused {
    _historyScanUserPaused = paused;
    [self.historyDefaults setBool:paused forKey:@"history-import.user-paused"];
}

- (void)reconcileHistoryScanForSnapshot:(CPADataFoundationSnapshot *)snapshot {
    if (snapshot.state == CPADataFoundationStateSynced
        || snapshot.state == CPADataFoundationStatePartialFailure) {
        self.historyScanPausedByAssistant = NO;
    }
    if (self.suggestionsPaused || self.historyScanUserPaused
        || !self.historyScanPausedByAssistant) return;
    if (snapshot.state == CPADataFoundationStatePaused) {
        self.historyScanPausedByAssistant = NO;
        [self.dataController resumeScan];
    }
}

- (void)toggleDataPause:(id)sender {
    (void)sender;
    CPADataFoundationSnapshot *snapshot = self.dataController.currentSnapshot;
    if (snapshot.state == CPADataFoundationStateScanning) {
        self.historyScanUserPaused = YES;
        self.historyScanPausedByAssistant = NO;
        [self.dataController requestPause];
        self.dataPauseMenuItem.enabled = NO;
        self.dataPauseMenuItem.title = @"正在暂停…";
    } else if (snapshot.state == CPADataFoundationStatePaused) {
        self.historyScanUserPaused = NO;
        self.historyScanPausedByAssistant = YES;
        [self reconcileHistoryScanForSnapshot:snapshot];
    }
}

- (void)showDataDiagnostics:(id)sender {
    (void)sender;
    CPADataFoundationSnapshot *snapshot = self.dataController.currentSnapshot;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"本地数据诊断";
    alert.informativeText = [snapshot.diagnosticSummary stringByAppendingString:
        @"\n\n诊断只包含计数，不包含聊天正文、文件名或本地路径。"];
    [alert addButtonWithTitle:@"知道了"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

// Nil means no history was supplied. Never infer dependencies from generated text.
- (CPAConversationContextSnapshot *)completionContextForSnapshot:(CPAAccessibilitySnapshot *)snapshot {
    if (snapshot.contextAccessMode == CPAContextAccessModeWorkBuddyConversation
        && CPASuggestionPolicyApplicationIsWorkBuddy(snapshot.targetBundleIdentifier)
        && snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled) {
        [self observeWorkBuddyContext:snapshot];
        return self.workBuddyContextSnapshot.messages.count > 0 ? self.workBuddyContextSnapshot : nil;
    }
    if (snapshot.contextAccessMode != CPAContextAccessModeCodexConversation) return nil;
    if (self.codexIDResolver && (!self.codexIDIdentifier.length
        || ![[self codexTaskKeyForSnapshot:snapshot] isEqual:self.codexIDTaskKey])) return nil;
    CPAConversationContextSnapshot *context = self.contextProvider.currentSnapshot;
    return context.messages.count > 0 || context.availability == CPAContextAvailabilityLoading ? context : nil;
}

- (BOOL)contextIsCurrent:(CPAConversationContextSnapshot *)context {
    return context == nil || context == self.contextProvider.currentSnapshot
        || (context == self.workBuddyContextSnapshot
            && CPASuggestionPolicyApplicationIsWorkBuddy(self.cachedFrontmostBundleIdentifier));
}

- (void)observeWorkBuddyContext:(CPAAccessibilitySnapshot *)snapshot {
    NSArray *material = CPASuggestionPolicyApplicationIsWorkBuddy(snapshot.targetBundleIdentifier)
        && snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
        && snapshot.contextAccessMode == CPAContextAccessModeWorkBuddyConversation
        && !snapshot.workBuddyContextReadPending
        ? snapshot.workBuddyContext : nil;
    if (material == self.observedWorkBuddyContext || [material isEqual:self.observedWorkBuddyContext]) return;
    self.observedWorkBuddyContext = material;
    NSUInteger revision = self.workBuddyContextSnapshot.revision + 1;
    self.workBuddyContextSnapshot = material.count == 2
        ? [[CPAConversationContextSnapshot alloc] initWithSelectionGeneration:revision revision:revision
            availability:[material[1] count] > 0 ? CPAContextAvailabilityReady : CPAContextAvailabilityReadyEmpty
            messages:material[1] sourceURL:nil truncatedMessageIndexes:[NSIndexSet indexSet] tailTruncated:NO] : nil;
    [self.localModelClient invalidateCompletionCache];
    [self.remoteClient invalidateCompletionCache];
    [self conversationContextDidChange];
}

- (void)conversationContextDidChange {
    CPAConversationContextSnapshot *current = self.contextProvider.currentSnapshot;
    if (current.revision != self.observedContextRevision) {
        self.observedContextRevision = current.revision;
        [self.localModelClient invalidateCompletionCache];
        [self.remoteClient invalidateCompletionCache];
    }
    BOOL invalidated = NO;
    if (![self contextIsCurrent:self.localTaskContext]) {
        CPARemoteCompletionTask *task = self.localModelTask; self.localModelTask = nil;
        self.localTaskContext = nil; self.localModelTaskSignature = nil; self.localModelTaskInput = nil;
        self.localModelTaskStartedAt = nil; self.localModelTaskContextGeneration = 0;
        [task cancel]; invalidated = YES;
    }
    if (![self contextIsCurrent:self.remoteTaskContext]) {
        CPARemoteCompletionTask *task = self.remoteTask; self.remoteTask = nil;
        self.remoteTaskContext = nil; self.remoteTaskSignature = nil; self.remoteTaskInput = nil;
        self.remoteTaskStartedAt = nil; self.remoteTaskContextGeneration = 0;
        [task cancel]; invalidated = YES;
    }
    if (![self contextIsCurrent:self.remotePreparationContext]) {
        [self invalidateSuggestionTimersAndPreparation]; invalidated = YES;
    }
    if (![self contextIsCurrent:self.pendingRemoteContext]) {
        [self clearPendingRemoteSuggestion]; invalidated = YES;
    }
    if (![self contextIsCurrent:self.displayedContext]) {
        [self.overlayController hide]; [self.suggestionCoordinator clear];
        [self clearDisplayedSuggestionState]; invalidated = YES;
    }
    if (![self contextIsCurrent:self.acceptanceContext]) {
        [self invalidatePendingAcceptance]; invalidated = YES;
    }
    if (invalidated && self.displayedSuggestionSignature.length == 0 && !self.acceptancePending)
        self.lastObservedSignature = nil; // do not indirectly erase an independent draft-only candidate
}

- (void)recheckAfterUnavailableResultForSignature:(NSString *)signature {
    if ([self.lastObservedSignature isEqual:signature]
        && self.displayedSuggestionSignature.length == 0 && !self.acceptancePending
        && ![self.dismissedSignature isEqual:signature]) self.lastObservedSignature = nil;
}

- (void)recordCompletionResult:(CPARemoteCompletionResult *)result source:(NSString *)source
    observedAt:(NSDate *)observedAt {
    NSString *status = CPALastCompletionStatusText(result.outcome, result.phase, result.insertionText.length > 0);
    if ([source isEqual:@"local_model"]) {
        self.lastLocalCompletionMenuItem.title = [@"上次本地请求：" stringByAppendingString:status];
    } else if ([source isEqual:@"remote"]) {
        self.lastRemoteCompletionMenuItem.title = [@"上次远程请求：" stringByAppendingString:status];
    }
    CPADiagnosticLog(@"%@ finish requestID=%@ phase=%@ generationSource=%@ outcome=%ld status=%ld durationMs=%lu observedToFinishMs=%lu inputLength=%lu outputLength=%lu cacheHit=%@ errorDomain=%@ errorCode=%ld",
        source, result.requestID, result.phase, result.generationSource, (long)result.outcome, (long)result.statusCode,
        (unsigned long)result.durationMilliseconds, (unsigned long)CPAMillisecondsSinceDate(observedAt),
        (unsigned long)result.inputCharacterCount, (unsigned long)result.outputCharacterCount,
        result.isCacheHit ? @"true" : @"false", result.errorDomain, (long)result.errorCode);
    NSDictionary *diagnostics = result.responseDiagnostics;
    CPADiagnosticLog(@"%@ response_meta requestID=%@ dispatchMs=%@ firstDataMs=%@ validationMs=%@ rawOutputLength=%@ finishReason=%@ noSuggestionReason=%@",
        source, result.requestID, result.completionDispatchMilliseconds ?: @(-1),
        result.firstDataMilliseconds ?: @(-1), result.validationMilliseconds ?: @(-1),
        diagnostics[@"rawOutputCharacterCount"] ?: @(-1),
        diagnostics[@"finishReason"] ?: @"unknown", diagnostics[@"noSuggestionReason"] ?: @"unknown");
    CPADiagnosticLog(@"%@ response_shape requestID=%@ format=%@ bodyState=%@ responseBytes=%@ events=%@ choiceEvents=%@ contentStrings=%@ finishObserved=%@ doneSeen=%@ refusalPresent=%@ reasoningPresent=%@ toolCallsPresent=%@ nullContent=%@ unsupportedContent=%@ invalidEvents=%@",
        source, result.requestID, diagnostics[@"responseFormat"] ?: @"unknown",
        diagnostics[@"bodyState"] ?: @"unknown", diagnostics[@"responseBytes"] ?: @(-1),
        diagnostics[@"eventCount"] ?: @(-1), diagnostics[@"choiceEventCount"] ?: @(-1),
        diagnostics[@"contentStringCount"] ?: @(-1), diagnostics[@"finishObserved"] ?: @(-1),
        diagnostics[@"doneSeen"] ?: @(-1), diagnostics[@"refusalPresent"] ?: @(-1),
        diagnostics[@"reasoningPresent"] ?: @(-1), diagnostics[@"toolCallsPresent"] ?: @(-1),
        diagnostics[@"nullContentPresent"] ?: @(-1), diagnostics[@"unsupportedContentPresent"] ?: @(-1),
        diagnostics[@"invalidEventCount"] ?: @(-1));
}

- (void)selectConversationContextWithTitle:(nullable NSString *)conversationTitle {
    if (self.codexIDResolver != nil) {
        self.codexIDGeneration++; [self.codexIDResolver cancel];
        self.codexIDSignature = nil; self.codexIDIdentifier = nil; self.codexIDTaskKey = nil;
        [self.contextProvider invalidateCachedContext];
        return; // A missing ID must never silently borrow title-matched history.
    }
    NSString *normalized = [conversationTitle stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (normalized.length > 0) {
        [self.contextProvider selectConversationWithTitle:normalized];
    } else {
        [self.contextProvider invalidateCachedContext];
    }
}

- (NSString *)codexTaskKeyForSnapshot:(CPAAccessibilitySnapshot *)snapshot {
    if (![snapshot.targetBundleIdentifier isEqual:@"com.openai.codex"]
        || snapshot.contextAccessMode != CPAContextAccessModeCodexConversation
        || !snapshot.conversationSelectionIdentity.length || !snapshot.targetFieldIdentity.length
        || snapshot.targetProcessIdentifier <= 0) return nil;
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:
        @[@(snapshot.targetProcessIdentifier), snapshot.targetFieldIdentity,
          snapshot.conversationSelectionIdentity] options:0 error:nil] encoding:NSUTF8StringEncoding];
}

- (BOOL)ensureCodexIDForSnapshot:(CPAAccessibilitySnapshot *)snapshot signature:(NSString *)signature {
    if (self.codexIDResolver == nil || snapshot.contextAccessMode != CPAContextAccessModeCodexConversation
        || ![snapshot.targetBundleIdentifier isEqual:@"com.openai.codex"]) return YES;
    NSString *taskKey = [self codexTaskKeyForSnapshot:snapshot];
    if (!taskKey.length) {
        if (self.codexIDTaskKey || self.codexIDIdentifier || self.codexIDResolver.pending) {
            self.codexIDGeneration++; [self.codexIDResolver cancel];
            self.codexIDTaskKey = nil; self.codexIDIdentifier = nil; self.codexIDSignature = nil;
            [self.contextProvider invalidateCachedContext];
        }
        return YES; // Draft-only, no repeated shortcut on an unidentifiable surface.
    }
    if ([self.codexIDTaskKey isEqual:taskKey]) return YES;
    if (self.codexIDTaskKey) {
        self.codexIDGeneration++; [self.codexIDResolver cancel];
        self.codexIDTaskKey = nil; self.codexIDIdentifier = nil; self.codexIDSignature = nil;
        [self.contextProvider invalidateCachedContext];
    }
    if (self.codexIDResolver.pending) return NO;
    if (self.suggestionsPaused || self.acceptancePending || !snapshot.targetApplicationIsFrontmost
        || snapshot.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled
        || !snapshot.writableTextInput || snapshot.inputText.length == 0
        || !snapshot.hasSelectedRange || snapshot.selectedLength != 0
        || [self.keyboardInterceptor inputMethodCompositionProbablyActive]) return NO;
    if (self.lastObservedInputChangeDate != nil && CPAMillisecondsSinceDate(self.lastObservedInputChangeDate) < 250) {
        [self scheduleLocalModelSuggestionsForSnapshot:snapshot signature:signature delay:0.25];
        [self scheduleRemoteModelSuggestionsForSnapshot:snapshot signature:signature delay:0.25];
        return NO;
    }
    NSString *requestedInput = [snapshot.inputText copy];
    NSUInteger ticket = ++self.codexIDGeneration;
    NSUInteger generation = self.conversationGeneration;
    NSUInteger rule = self.policyCoordinator.ruleVersion;
    pid_t pid = snapshot.targetProcessIdentifier;
    [self.contextProvider invalidateCachedContext];
    self.codexIDIdentifier = nil;
    __weak CPAAppDelegate *weakSelf = self;
    BOOL (^valid)(void) = ^BOOL {
        CPAAppDelegate *owner = weakSelf;
        return owner != nil && ticket == owner.codexIDGeneration && generation == owner.conversationGeneration
            && !owner.suggestionsPaused && !owner.acceptancePending
            && !(owner.remoteSettings.localPaused && owner.remoteSettings.paused)
            && rule == owner.policyCoordinator.ruleVersion
            && pid == owner.cachedFrontmostProcessIdentifier
            && [owner.cachedFrontmostBundleIdentifier isEqual:@"com.openai.codex"];
    };
    [self.codexIDResolver resolveProcessIdentifier:pid validate:valid completion:^(NSString *identifier, NSString *reason) {
        CPAAppDelegate *owner = weakSelf;
        CPADiagnosticLog(@"codex_id resolved=%@ reason=%@", identifier != nil ? @"true" : @"false", reason);
        if (!valid()) { owner.lastObservedSignature = nil; return; }
        [owner requestAcceptanceSnapshotForBundleIdentifier:@"com.openai.codex" processIdentifier:pid
            completion:^(CPAAccessibilitySnapshot *fresh) {
            CPAAppDelegate *app = weakSelf;
            if (!valid()) { app.lastObservedSignature = nil; return; }
            if (fresh != nil) fresh = [app decorateCodexSnapshot:fresh];
            if (!valid() || fresh == nil || !fresh.targetApplicationIsFrontmost
                || fresh.targetProcessIdentifier != pid
                || ![signature isEqual:[app signatureForSnapshot:fresh]]
                || ![fresh.inputText isEqual:requestedInput]
                || ![[app codexTaskKeyForSnapshot:fresh] isEqual:taskKey]
                || fresh.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled) {
                app.lastObservedSignature = nil; return;
            }
            // Bind the attempt to task selection, never to mutable draft contents.
            app.codexIDTaskKey = taskKey;
            app.codexIDSignature = signature;
            app.codexIDIdentifier = identifier;
            if (identifier != nil) [app.contextProvider selectConversationWithIdentifier:identifier];
            [app scheduleModelSuggestionsForSnapshot:fresh signature:signature delay:0.08];
        }];
    }];
    return NO;
}

- (pid_t)currentCodexProcessIdentifier {
    if (!self.codexProcessCacheInitialized) {
        [self refreshCachedCodexProcessIdentifier];
    }
    return self.cachedCodexProcessIdentifier;
}

- (void)refreshCachedCodexProcessIdentifier {
    if (self.codexProcessCacheInitialized) {
        return;
    }
    pid_t processIdentifier = 0;
    NSArray<NSRunningApplication *> *applications =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.openai.codex"];
    for (NSRunningApplication *application in applications) {
        if (application.processIdentifier > 0) {
            processIdentifier = application.processIdentifier;
            break;
        }
    }
    self.cachedCodexProcessIdentifier = processIdentifier;
    self.codexProcessCacheInitialized = YES;
    if (processIdentifier > 0) {
        CPADiagnosticLog(@"codex process_cache=initialized");
    }
}

- (void)resetSuggestionStateForConversationBoundaryWithTitle:
    (nullable NSString *)conversationTitle reason:(NSString *)reason {
    self.conversationGeneration = MAX((NSUInteger)1,
        self.conversationGeneration + 1);
    [self cancelPendingSuggestionForReason:@"conversation_boundary"];
    self.lastInputModelCancellationDate = nil;
    self.recentInputModelCancellationCount = 0;
    [self.suggestionCoordinator clear];
    [self.overlayController hide];
    self.lastObservedSignature = nil;
    self.lastObservedInputText = nil;
    self.lastObservedInputChangeDate = nil;
    self.dismissedSignature = nil;
    self.dismissedInputText = nil;
    self.programmaticInsertionExpectedInput = nil;
    self.lastSuggestionAcceptedDate = nil;
    self.acceptedContinuationSignature = nil; self.acceptedContinuationInput = nil;
    [self clearDisplayedSuggestionState];
    self.contextRetryAttempts = 0;
    self.lastUsableSnapshot = nil;
    self.lastUsableSnapshotProcessIdentifier = 0;
    [self.keyboardInterceptor resetShadowBuffer];
    [self.remoteClient invalidateCompletionCache];
    [self.localModelClient invalidateCompletionCache];
    [self selectConversationContextWithTitle:conversationTitle];
    [self observeWorkBuddyContext:nil];
    CPADiagnosticLog(@"conversation boundary=%@ generation=%lu titleAvailable=%@",
        reason,
        (unsigned long)self.conversationGeneration,
        conversationTitle.length > 0 ? @"true" : @"false");
}

- (void)observeConversationIdentityForSnapshot:(CPAAccessibilitySnapshot *)snapshot {
    if (self.codexIDResolver) {
        NSString *key = [self codexTaskKeyForSnapshot:snapshot];
        if ((key || self.observedCodexTaskKey) && ![key isEqual:self.observedCodexTaskKey]) {
            self.observedCodexTaskKey = key;
            [self resetSuggestionStateForConversationBoundaryWithTitle:nil reason:@"selected_node_changed"];
        }
    }
    NSString *composerIdentifier = snapshot.composerIdentifier;
    NSString *conversationTitle = snapshot.conversationTitle;
    BOOL hasPreviousIdentity = self.lastComposerIdentifier.length > 0
        || self.lastConversationTitle.length > 0;
    BOOL hasCurrentIdentity = composerIdentifier.length > 0
        || conversationTitle.length > 0;
    if (!hasPreviousIdentity) {
        if (!hasCurrentIdentity) {
            return;
        }
        self.lastComposerIdentifier = [composerIdentifier copy];
        self.lastConversationTitle = [conversationTitle copy];
        [self resetSuggestionStateForConversationBoundaryWithTitle:conversationTitle
            reason:@"identity_initialized"];
        return;
    }

    if (CPAConversationIdentityChanged(
            self.lastComposerIdentifier ?: @"",
            composerIdentifier ?: @"",
            self.lastConversationTitle ?: @"",
            conversationTitle ?: @""
        )) {
        BOOL composerChanged = CPAComposerIdentityChanged(
            self.lastComposerIdentifier ?: @"", composerIdentifier ?: @"");
        self.lastComposerIdentifier = [composerIdentifier copy];
        self.lastConversationTitle = [conversationTitle copy];
        [self resetSuggestionStateForConversationBoundaryWithTitle:conversationTitle
            reason:composerChanged ? @"composer_changed" : @"selected_title_changed"];
        return;
    }

    if (self.lastComposerIdentifier.length == 0 && composerIdentifier.length > 0) {
        self.lastComposerIdentifier = [composerIdentifier copy];
    }
    if (self.lastConversationTitle.length == 0 && conversationTitle.length > 0) {
        self.lastConversationTitle = [conversationTitle copy];
        [self selectConversationContextWithTitle:conversationTitle];
    }
}

- (CPAAccessibilitySnapshot *)inspectCurrentTarget {
    if (!self.frontmostStateInitialized) {
        [self updateFrontmostApplicationState:
            NSWorkspace.sharedWorkspace.frontmostApplication];
    }
    NSString *bundleIdentifier = self.cachedFrontmostBundleIdentifier ?: @"";
    pid_t frontmostProcessIdentifier = self.cachedFrontmostProcessIdentifier;
    BOOL isCodex = [bundleIdentifier isEqualToString:@"com.openai.codex"];
    if (isCodex) {
        pid_t processIdentifier = self.cachedCodexProcessIdentifier;
        [self requestCodexSnapshotRefresh];
        CPAAccessibilitySnapshot *cached = self.cachedCodexSnapshot;
        if (cached != nil
            && cached.targetProcessIdentifier == processIdentifier
            && cached.targetApplicationIsFrontmost
            && frontmostProcessIdentifier == processIdentifier) {
            return [self decorateCodexSnapshot:cached];
        }
        // Until the background broker publishes a matching snapshot, return a
        // cheap conservative state. This keeps the poll and event tap from
        // waiting on a Chromium AX server.
        return [self snapshotForCodexMetadataUnavailable];
    }

    // Unknown/explicitly disabled applications are pass-through by policy.
    // Do not ask their AX server for a focused element just to rediscover a
    // disabled decision; those synchronous calls can block the event tap.
    if (![self.policyCoordinator shouldProbeMetadataForBundleIdentifier:
            bundleIdentifier]) {
        CPAAccessibilitySnapshot *snapshot =
            [self snapshotForGenericMetadataUnavailable];
        self.cachedGenericSnapshot = snapshot;
        self.lastGenericMetadataProbeDate = NSDate.date;
        return snapshot;
    }

    CPAAccessibilitySnapshot *cachedGeneric = self.cachedGenericSnapshot;
    BOOL sameGenericTarget = cachedGeneric != nil
        && cachedGeneric.targetProcessIdentifier == frontmostProcessIdentifier
        && [cachedGeneric.targetBundleIdentifier isEqualToString:bundleIdentifier];
    NSTimeInterval genericProbeElapsed = self.lastGenericMetadataProbeDate == nil
        ? -1.0 : -[self.lastGenericMetadataProbeDate timeIntervalSinceNow];
    BOOL shouldStartProbe = !self.genericProbeInProgress
        || ![self.genericProbeBundleIdentifier isEqualToString:bundleIdentifier]
        || self.genericProbeProcessIdentifier != frontmostProcessIdentifier;
    if (!shouldStartProbe) {
        shouldStartProbe = !sameGenericTarget
            || CPAGenericMetadataProbeMayStart(
                YES, NO, NO, NO, genericProbeElapsed);
    }
    if (shouldStartProbe) {
        [self scheduleGenericMetadataProbeForBundleIdentifier:bundleIdentifier
            processIdentifier:frontmostProcessIdentifier];
    }
    if (sameGenericTarget) {
        return cachedGeneric;
    }
    return [self snapshotForGenericMetadataUnavailable];
}

- (CPAAccessibilitySnapshot *)snapshotForGenericMetadataUnavailable {
    NSString *bundleIdentifier = self.cachedFrontmostBundleIdentifier ?: @"";
    CPAAccessibilitySnapshot *snapshot = [[CPAAccessibilitySnapshot alloc] init];
    if (!self.accessibilityPermissionKnown) {
        self.cachedAccessibilityPermissionGranted =
            [self.accessibilityService isTrustedWithPrompt:NO];
        self.accessibilityPermissionKnown = YES;
    }
    snapshot.permissionGranted = self.cachedAccessibilityPermissionGranted;
    snapshot.codexIsRunning = self.lastObservedCodexProcessIdentifier > 0;
    snapshot.targetApplicationIsFrontmost =
        self.cachedFrontmostProcessIdentifier > 0;
    snapshot.targetBundleIdentifier = bundleIdentifier;
    snapshot.targetProcessIdentifier = self.cachedFrontmostProcessIdentifier;
    snapshot.policyRuleVersion = self.policyCoordinator.ruleVersion;
    CPASuggestionDecision *decision = [self.policyCoordinator
        decisionForBundleIdentifier:bundleIdentifier
        role:@""
        subrole:@""
        semanticMetadata:@[]
        browserHost:@""
        globallyPaused:self.suggestionsPaused
        temporarilyPaused:NO];
    snapshot.suggestionPolicyOutcome = decision.outcome;
    snapshot.contextAccessMode = decision.contextMode;
    snapshot.suggestionPolicyReason = decision.reason;
    snapshot.policyStatusText = [NSString stringWithFormat:@"%@ · %@",
        self.cachedFrontmostApplicationName.length > 0
            ? self.cachedFrontmostApplicationName : @"当前应用", decision.statusText];
    snapshot.diagnostic = @"generic_metadata_skipped policy_gate=true";
    self.currentPolicyDecision = decision;
    self.currentPolicyBundleIdentifier = bundleIdentifier.length > 0
        ? [bundleIdentifier copy] : nil;
    return snapshot;
}

- (void)scheduleGenericMetadataProbeForBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier {
    if (bundleIdentifier.length == 0 || processIdentifier <= 0
        || self.genericAccessibilityQueue == nil) {
        return;
    }
    BOOL sameProbe = self.genericProbeInProgress
        && [self.genericProbeBundleIdentifier isEqualToString:bundleIdentifier]
        && self.genericProbeProcessIdentifier == processIdentifier;
    if (sameProbe) {
        return;
    }

    NSUInteger generation = ++self.genericProbeGeneration;
    self.genericProbeInProgress = YES;
    self.genericProbeBundleIdentifier = [bundleIdentifier copy];
    self.genericProbeProcessIdentifier = processIdentifier;
    self.lastGenericMetadataProbeDate = NSDate.date;

    CPAGenericAccessibilityService *service = self.genericAccessibilityService;
    CPASafeInputContextCollector *collector = self.safeInputCollector;
    CPASuggestionPolicyCoordinator *coordinator = self.policyCoordinator;
    NSString *applicationName = [self.cachedFrontmostApplicationName copy];
    BOOL globallyPaused = self.suggestionsPaused;
    BOOL codexRunning = self.cachedCodexProcessIdentifier > 0;
    dispatch_async(self.genericAccessibilityQueue, ^{
        CPAFocusedInputMetadata *metadata =
            [service inspectFocusedInputMetadataForBundleIdentifier:bundleIdentifier
                processIdentifier:processIdentifier];
        CPASuggestionDecision *decision = nil;
        CPAGenericInputBody *body = nil;
        if (metadata != nil) {
            CPASafeInputContextCollection *collection = [collector
                collectContextForMetadata:metadata
                globallyPaused:globallyPaused
                temporarilyPaused:NO];
            decision = collection.decision;
            body = [collection.inputBody isKindOfClass:CPAGenericInputBody.class]
                ? collection.inputBody : nil;
        }

        NSString *inspectionDiagnostic = [service.lastInspectionDiagnostic copy] ?: @"focus_probe_not_reached";
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL stillCurrent = generation == self.genericProbeGeneration
                && [self.cachedFrontmostBundleIdentifier
                    isEqualToString:bundleIdentifier]
                && self.cachedFrontmostProcessIdentifier == processIdentifier
                && [self.genericProbeBundleIdentifier
                    isEqualToString:bundleIdentifier]
                && self.genericProbeProcessIdentifier == processIdentifier;
            if (!stillCurrent) {
                return;
            }
            self.genericProbeInProgress = NO;
            self.lastGenericMetadataProbeDate = NSDate.date;
            if (metadata == nil || decision == nil) {
                CPAAccessibilitySnapshot *unavailable =
                    [self snapshotForGenericMetadataUnavailable];
                unavailable.diagnostic = [NSString stringWithFormat:@"generic_metadata_unavailable bundle=%@ targetPID=%d %@", bundleIdentifier, processIdentifier, inspectionDiagnostic];
                self.cachedGenericSnapshot = unavailable;
                [self observeWorkBuddyContext:unavailable];
                return;
            }

            CPAAccessibilitySnapshot *snapshot = [[CPAAccessibilitySnapshot alloc]
                init];
            snapshot.permissionGranted = YES;
            snapshot.codexIsRunning = codexRunning;
            snapshot.targetApplicationIsFrontmost = YES;
            snapshot.targetBundleIdentifier = metadata.bundleIdentifier;
            snapshot.targetProcessIdentifier = metadata.processIdentifier;
            snapshot.targetFieldIdentity = metadata.fieldIdentity;
            snapshot.browserHost = metadata.browserHost;
            snapshot.documentContinuation = metadata.documentContinuation;
            snapshot.policyRuleVersion = coordinator.ruleVersion;
            snapshot.focusedRole = metadata.role;
            snapshot.focusedSubrole = metadata.subrole;
            snapshot.suggestionPolicyOutcome = decision.outcome;
            snapshot.contextAccessMode = decision.contextMode;
            snapshot.suggestionPolicyReason = decision.reason;
            snapshot.policyStatusText = [NSString stringWithFormat:@"%@ · %@",
                applicationName.length > 0 ? applicationName : @"当前应用",
                decision.statusText];
            if (body != nil) {
                snapshot.inputText = body.inputText;
                snapshot.workBuddyContext = body.workBuddyContext;
                snapshot.workBuddyContextReadPending = body.workBuddyContextReadPending;
                snapshot.hasValueCharacterCount = YES;
                snapshot.valueCharacterCount = body.inputText.length;
                snapshot.hasSelectedRange = body.hasSelectedRange;
                snapshot.selectedLocation = body.selectedLocation;
                snapshot.selectedLength = body.selectedLength;
                snapshot.writableTextInput = body.writableTextInput;
                snapshot.hasCaretBounds = body.hasCaretBounds;
                snapshot.caretBounds = body.caretBounds;
                snapshot.hasElementFrame = body.hasElementFrame;
                snapshot.elementFrame = body.elementFrame;
            }
            snapshot.diagnostic = [NSString stringWithFormat:
                @"generic role=%@ subrole=%@ policy=%ld bodyRead=%@ bundle=%@ targetPID=%d contextCount=%lu %@",
                metadata.role.length > 0 ? metadata.role : @"nil",
                metadata.subrole.length > 0 ? metadata.subrole : @"nil",
                (long)decision.reason,
                body != nil ? @"true" : @"false", bundleIdentifier, processIdentifier,
                (unsigned long)(body.workBuddyContext.count == 2 ? [body.workBuddyContext[1] count] : 0), inspectionDiagnostic];
            self.currentPolicyDecision = decision;
            self.currentPolicyBundleIdentifier = [metadata.bundleIdentifier copy];
            self.cachedGenericSnapshot = snapshot;
            [self observeWorkBuddyContext:snapshot];
        });
    });
}

- (void)observeRuntimeBoundaryForSnapshot:(CPAAccessibilitySnapshot *)snapshot {
    if (!snapshot.targetApplicationIsFrontmost
        || snapshot.targetBundleIdentifier.length == 0) {
        if ([self.contextGenerationTracker clear]) {
            self.lastUsableSnapshot = nil;
            [self resetSuggestionStateForConversationBoundaryWithTitle:nil
                reason:@"target_focus_lost"];
        }
        return;
    }
    CPASuggestionContextIdentity *identity = [[CPASuggestionContextIdentity alloc]
        initWithBundleIdentifier:snapshot.targetBundleIdentifier
        processIdentifier:snapshot.targetProcessIdentifier
        windowIdentifier:0
        fieldIdentity:snapshot.targetFieldIdentity
        browserHost:snapshot.browserHost
        ruleVersion:snapshot.policyRuleVersion];
    BOOL hadIdentity = self.contextGenerationTracker.currentIdentity != nil;
    if ([self.contextGenerationTracker observeIdentity:identity] && hadIdentity) {
        self.lastUsableSnapshot = nil;
        self.lastUsableSnapshotProcessIdentifier = 0;
        [self.keyboardInterceptor resetShadowBuffer];
        [self resetSuggestionStateForConversationBoundaryWithTitle:nil
            reason:@"runtime_context_changed"];
    }
}

- (CPAAccessibilitySnapshot *)updateStatus {
    return [self updateStatusWithSnapshot:[self inspectCurrentTarget]];
}

- (CPAAccessibilitySnapshot *)updateStatusWithSnapshot:
    (CPAAccessibilitySnapshot *)snapshot {
    if (snapshot == nil) {
        snapshot = [self inspectCurrentTarget];
    }
    if (snapshot.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled) {
        // A policy transition must revoke any in-flight work immediately;
        // otherwise a late model callback could resurrect a hidden candidate.
        [self cancelPendingSuggestionForReason:@"policy_disabled"];
        [self.suggestionCoordinator clear];
        [self.overlayController hide];
        [self clearDisplayedSuggestionState];
        [self.keyboardInterceptor resetShadowBuffer];
    }
    pid_t codexProcessIdentifier = [self currentCodexProcessIdentifier];
    if (codexProcessIdentifier != self.lastObservedCodexProcessIdentifier) {
        BOOL hadPreviousProcess = self.lastObservedCodexProcessIdentifier != 0;
        self.lastObservedCodexProcessIdentifier = codexProcessIdentifier;
        self.lastUsableSnapshot = nil;
        self.lastUsableSnapshotProcessIdentifier = 0;
        self.fallbackInputFrame = CGRectZero;
        self.fallbackInputFrameAvailable = NO;
        [self.keyboardInterceptor updateFallbackInputFrame:CGRectZero available:NO];
        [self.keyboardInterceptor resetShadowBuffer];
        if (hadPreviousProcess) {
            // Do not let a new process with a reused composer node/title inherit
            // the previous process identity. The next authoritative AX read
            // must initialize and select its context afresh.
            self.lastComposerIdentifier = nil;
            self.lastConversationTitle = nil;
            [self resetSuggestionStateForConversationBoundaryWithTitle:nil
                reason:codexProcessIdentifier > 0
                    ? @"codex_process_changed" : @"codex_process_ended"];
        }
    }
    if (snapshot.codexIsFrontmost && snapshot.hasFallbackInputFrame) {
        if (snapshot.fallbackInputFrame.size.width > 0.0) {
            self.fallbackInputFrame = snapshot.fallbackInputFrame;
            self.fallbackInputFrameAvailable = YES;
            [self.keyboardInterceptor updateFallbackInputFrame:snapshot.fallbackInputFrame
                available:YES];
        }
    } else if (!snapshot.codexIsRunning) {
        self.fallbackInputFrame = CGRectZero;
        self.fallbackInputFrameAvailable = NO;
        [self.keyboardInterceptor updateFallbackInputFrame:CGRectZero available:NO];
    }
    [self observeRuntimeBoundaryForSnapshot:snapshot];
    if ([snapshot.targetBundleIdentifier isEqualToString:@"com.openai.codex"]) {
        [self observeConversationIdentityForSnapshot:snapshot];
    }
    BOOL showPolicyStatus = ![snapshot.targetBundleIdentifier
        isEqualToString:@"com.openai.codex"]
        || snapshot.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled;
    self.statusMenuItem.title = showPolicyStatus
        ? snapshot.policyStatusText : snapshot.summary;
    NSString *diagnostic = [NSString stringWithFormat:
        @"permission=%@ running=%@ frontmost=%@ targetFrontmost=%@ policy=%ld writable=%@ caret=%@ elementFrame=%@ %@",
        snapshot.permissionGranted ? @"true" : @"false",
        snapshot.codexIsRunning ? @"true" : @"false",
        snapshot.codexIsFrontmost ? @"true" : @"false",
        snapshot.targetApplicationIsFrontmost ? @"true" : @"false",
        (long)snapshot.suggestionPolicyReason,
        snapshot.writableTextInput ? @"true" : @"false",
        snapshot.hasCaretBounds ? @"true" : @"false",
        snapshot.hasElementFrame ? @"true" : @"false",
        snapshot.diagnostic];
    self.lastDiagnostic = diagnostic;
    NSString *diagnosticCategory = [snapshot.diagnostic
        hasPrefix:@"focused_element_unavailable"]
        ? (snapshot.rendererAccessibilitySuspected
            ? @"focused_unavailable_renderer" : @"focused_unavailable_initial")
        : ([snapshot.diagnostic hasPrefix:@"precondition_failed"]
            ? @"precondition_failed" : @"inspected");
    NSString *diagnosticState = [NSString stringWithFormat:
        @"p=%d:r=%d:f=%d:t=%d:o=%ld:w=%d:c=%d:e=%d:category=%@",
        snapshot.permissionGranted,
        snapshot.codexIsRunning,
        snapshot.codexIsFrontmost,
        snapshot.targetApplicationIsFrontmost,
        (long)snapshot.suggestionPolicyOutcome,
        snapshot.writableTextInput,
        snapshot.hasCaretBounds,
        snapshot.hasElementFrame,
        diagnosticCategory];
    CPADiagnosticLogState(CPADiagnosticStateWithTarget(diagnosticState,
        snapshot.targetBundleIdentifier ?: @"", snapshot.targetProcessIdentifier),
        @"snapshot %@ targetBundle=%@ targetProcess=%d", diagnostic,
        snapshot.targetBundleIdentifier ?: @"", snapshot.targetProcessIdentifier);
    if (snapshot.writableTextInput && snapshot.hasSuggestionAnchor) {
        self.lastUsableSnapshot = snapshot;
        self.lastUsableSnapshotProcessIdentifier = snapshot.targetProcessIdentifier;
        if ([snapshot.targetBundleIdentifier isEqualToString:@"com.openai.codex"]
            && snapshot.inputText != nil && snapshot.hasSelectedRange) {
            [self.keyboardInterceptor synchronizeShadowBufferWithText:snapshot.inputText
                cursorLocation:(NSUInteger)MAX(0, snapshot.selectedLocation)
                selectedLength:(NSUInteger)MAX(0, snapshot.selectedLength)];
        }
    }
    return snapshot;
}

- (nullable CPAAccessibilitySnapshot *)snapshotByApplyingShadowBufferToSnapshot:
    (CPAAccessibilitySnapshot *)snapshot {
    if (!snapshot.codexIsRunning || !snapshot.codexIsFrontmost
        || snapshot.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeDisabled
        || snapshot.writableTextInput) {
        return nil;
    }
    CPAKeyboardShadowBuffer *buffer = self.keyboardInterceptor.shadowBuffer;
    if (!buffer.valid || buffer.text.length == 0) {
        return nil;
    }
    pid_t currentProcessIdentifier = [self currentCodexProcessIdentifier];
    BOOL hasCurrentHistoricalAnchor = self.lastUsableSnapshot != nil
        && self.lastUsableSnapshot.hasSuggestionAnchor
        && self.lastUsableSnapshotProcessIdentifier != 0
        && self.lastUsableSnapshotProcessIdentifier == currentProcessIdentifier;
    if (!hasCurrentHistoricalAnchor) {
        if (!self.fallbackInputFrameAvailable) {
            return nil;
        }
        return [CPAAccessibilitySnapshot shadowSnapshotFromInspection:snapshot
            shadowText:buffer.text
            cursorLocation:buffer.cursorLocation
            selectedLength:buffer.selectedLength
            fallbackInputFrame:self.fallbackInputFrame];
    }
    CPAAccessibilitySnapshot *shadow = [[CPAAccessibilitySnapshot alloc] init];
    shadow.permissionGranted = snapshot.permissionGranted;
    shadow.codexIsRunning = snapshot.codexIsRunning;
    shadow.codexIsFrontmost = snapshot.codexIsFrontmost;
    shadow.targetApplicationIsFrontmost = snapshot.targetApplicationIsFrontmost;
    shadow.targetBundleIdentifier = snapshot.targetBundleIdentifier;
    shadow.targetProcessIdentifier = snapshot.targetProcessIdentifier;
    shadow.suggestionPolicyOutcome = snapshot.suggestionPolicyOutcome;
    shadow.contextAccessMode = snapshot.contextAccessMode;
    shadow.suggestionPolicyReason = snapshot.suggestionPolicyReason;
    shadow.targetFieldIdentity = snapshot.targetFieldIdentity;
    shadow.browserHost = snapshot.browserHost;
    shadow.documentContinuation = snapshot.documentContinuation;
    shadow.policyRuleVersion = snapshot.policyRuleVersion;
    shadow.codexInputDecision = snapshot.codexInputDecision;
    shadow.inputReadingGeneration = snapshot.inputReadingGeneration;
    shadow.candidateContextGeneration = snapshot.candidateContextGeneration;
    shadow.policyStatusText = snapshot.policyStatusText;
    shadow.focusedRole = @"AXTextArea";
    shadow.writableTextInput = YES;
    shadow.inputText = buffer.text;
    shadow.hasValueCharacterCount = YES;
    shadow.valueCharacterCount = buffer.text.length;
    shadow.hasSelectedRange = YES;
    shadow.selectedLocation = (NSInteger)buffer.cursorLocation;
    shadow.selectedLength = (NSInteger)buffer.selectedLength;
    shadow.hasElementFrame = self.lastUsableSnapshot.hasElementFrame;
    shadow.elementFrame = self.lastUsableSnapshot.elementFrame;
    shadow.hasCaretBounds = self.lastUsableSnapshot.hasCaretBounds;
    shadow.caretBounds = self.lastUsableSnapshot.caretBounds;
    shadow.composerIdentifier = self.lastUsableSnapshot.composerIdentifier;
    shadow.conversationTitle = self.lastUsableSnapshot.conversationTitle;
    shadow.diagnostic = @"shadow_input active=true";
    return shadow;
}

- (CPAAccessibilitySnapshot *)snapshotForSuggestion {
    CPAAccessibilitySnapshot *snapshot = [self updateStatus];
    CPAAccessibilitySnapshot *shadowSnapshot =
        [self snapshotByApplyingShadowBufferToSnapshot:snapshot];
    return shadowSnapshot ?: snapshot;
}

- (CPAAccessibilitySnapshot *)snapshotForStreamingSuggestion {
    NSString *frontmostBundleIdentifier =
        self.cachedFrontmostBundleIdentifier ?: @"";
    pid_t frontmostPID = self.cachedFrontmostProcessIdentifier;
    CPAAccessibilitySnapshot *cached = self.lastUsableSnapshot;
    if ([frontmostBundleIdentifier isEqualToString:@"com.openai.codex"]
        && cached != nil
        && !self.suggestionsPaused
        && !(self.remoteSettings.localPaused && self.remoteSettings.paused)
        && cached.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
        && cached.policyRuleVersion == self.policyCoordinator.ruleVersion
        && cached.inputReadingGeneration == self.accessibilityService.inputReadingGeneration
        && cached.targetApplicationIsFrontmost
        && cached.targetProcessIdentifier == frontmostPID
        && cached.hasSuggestionAnchor
        && cached.hasSelectedRange) {
        // The 100ms accessibility poll remains the authority. Stream chunks
        // reuse its latest snapshot instead of synchronously rescanning AX on
        // the main callback queue for every token.
        return cached;
    }
    return [self snapshotForSuggestion];
}

- (void)pollAccessibility:(NSTimer *)timer {
    (void)timer;
    [self conversationContextDidChange];
    if (self.suggestionsPaused || self.acceptancePending
        || (self.remoteSettings.localPaused && self.remoteSettings.paused)) {
        return;
    }
    [self requestCodexSnapshotRefresh];
    CPAAccessibilitySnapshot *snapshot = [self updateStatus];
    CPAAccessibilitySnapshot *shadowSnapshot =
        [self snapshotByApplyingShadowBufferToSnapshot:snapshot];
    if (shadowSnapshot != nil) {
        snapshot = shadowSnapshot;
    }
    BOOL usable = CPASnapshotCanDriveSuggestions(
        snapshot.targetApplicationIsFrontmost,
        snapshot.suggestionPolicyOutcome,
        snapshot.writableTextInput,
        snapshot.hasSuggestionAnchor,
        snapshot.hasValueCharacterCount,
        snapshot.hasSelectedRange,
        snapshot.valueCharacterCount)
        && snapshot.inputText != nil
        ;
    if (!usable) {
        BOOL hasPendingSuggestion = self.remoteTask != nil
            || self.localModelTask != nil
            || self.suggestionTimer != nil || self.localModelSuggestionTimer != nil
            || self.modelSuggestionTimer != nil
            || self.pendingRemoteInsertion.length > 0;
        BOOL definitelyEmpty = snapshot.targetApplicationIsFrontmost
            && snapshot.writableTextInput
            && snapshot.hasValueCharacterCount
            && snapshot.valueCharacterCount == 0;
        BOOL hasDisplayedSuggestion = self.overlayController.visible
            || self.localModelDisplayedSignature.length > 0
            || self.remoteDisplayedSignature.length > 0;
        // A transient AX miss may keep an in-flight request briefly, but an
        // unverifiable/disabled field must never keep a displayed Tab target.
        BOOL transientFrontmostLoss = snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
            && CPAShouldRetainSuggestionDuringFocusLoss(
            snapshot.targetApplicationIsFrontmost,
            definitelyEmpty,
            hasPendingSuggestion,
            hasDisplayedSuggestion);
        if (transientFrontmostLoss) {
            [self.overlayController hide];
            [self.suggestionCoordinator clear];
            [self clearDisplayedSuggestionState];
            [self scheduleFocusLossCancellation];
            CPADiagnosticLog(@"suggestion retain=focus_grace pending=%@ displayed=%@ writable=%@ valueKnown=%@",
                hasPendingSuggestion ? @"true" : @"false",
                hasDisplayedSuggestion ? @"true" : @"false",
                snapshot.writableTextInput ? @"true" : @"false",
                snapshot.hasValueCharacterCount ? @"true" : @"false");
            return;
        }
        [self cancelPendingSuggestionForReason:@"input_unusable"];
        [self.suggestionCoordinator clear];
        [self.overlayController hide];
        [self clearDisplayedSuggestionState];
        BOOL shouldForgetObservedInput = CPAShouldForgetObservedInput(
                snapshot.targetApplicationIsFrontmost,
                snapshot.writableTextInput,
                snapshot.hasValueCharacterCount,
                snapshot.valueCharacterCount
            );
        BOOL hadObservedState = self.lastObservedSignature.length > 0
            || self.lastObservedInputText.length > 0
            || self.dismissedSignature.length > 0
            || self.dismissedInputText.length > 0
            || self.programmaticInsertionExpectedInput.length > 0;
        if (shouldForgetObservedInput && hadObservedState) {
            self.lastObservedSignature = nil;
            self.lastObservedInputText = nil;
            self.lastObservedInputChangeDate = nil;
            self.dismissedSignature = nil;
            self.dismissedInputText = nil;
            self.programmaticInsertionExpectedInput = nil;
            self.acceptedContinuationSignature = nil; self.acceptedContinuationInput = nil;
            [self selectConversationContextWithTitle:
                snapshot.conversationTitle ?: self.lastConversationTitle];
            [self.remoteClient invalidateCompletionCache];
            [self.localModelClient invalidateCompletionCache];
        }
        return;
    }

    [self.focusLossTimer invalidate];
    self.focusLossTimer = nil;

    NSString *signature = [self signatureForSnapshot:snapshot];
    if ([self displayPendingRemoteSuggestionForSnapshot:snapshot signature:signature]) {
        return;
    }
    BOOL changed = ![signature isEqualToString:self.lastObservedSignature]
        || ![snapshot.inputText isEqualToString:self.lastObservedInputText];
    if (!changed) {
        return;
    }

    self.acceptedContinuationSignature = nil; self.acceptedContinuationInput = nil;
    self.latestObservedEditWasDeletion = self.lastObservedInputText != nil
        && CPAInputShrinkIsDeletionEdit(self.lastObservedInputText.length,
            snapshot.inputText.length,
            self.keyboardInterceptor.mostRecentTextEditWasDeletion);
    self.lastObservedSignature = signature;
    self.lastObservedInputText = snapshot.inputText;
    self.lastObservedInputChangeDate = NSDate.date;
    [self.overlayController hide];
    [self clearDisplayedSuggestionState];
    [self.suggestionCoordinator clear];
    // A real edit has priority over launch/resume warm-up. Cancel it before
    // the single-task local client is asked to issue the user's request.
    [self cancelLocalModelWarmupIfPending];
    if ([self canKeepRemoteTaskForSnapshot:snapshot]) {
        [self cancelPendingSuggestionKeepingRemoteTaskForReason:@"input_changed"];
    } else {
        [self cancelPendingSuggestionForReason:@"input_changed"];
    }
    if (self.programmaticInsertionExpectedInput != nil) {
        NSString *expectedInput = self.programmaticInsertionExpectedInput;
        self.programmaticInsertionExpectedInput = nil;
        BOOL readbackMatched = [snapshot.inputText isEqualToString:expectedInput];
        // This is the next changed snapshot, not a delivery acknowledgement:
        // a mismatch may also be an intervening edit. Never log either body.
        CPADiagnosticLog(@"accept readback=%@ source=%@ expectedLength=%lu actualLength=%lu",
            readbackMatched ? @"matched" : @"mismatched",
            shadowSnapshot != nil ? @"shadow" : @"accessibility",
            (unsigned long)expectedInput.length,
            (unsigned long)snapshot.inputText.length);
        if (readbackMatched) {
            // A confirmed Tab insertion is new context, not a dismissal.
            // AX/shadow readback has confirmed the insertion. The ordinary
            // debounce and fresh identity/IME gates are sufficient from here;
            // reserve the longer cooldown for unconfirmed intervening edits.
            self.lastSuggestionAcceptedDate = nil;
            if (snapshot.selectedLocation == (NSInteger)snapshot.inputText.length) {
                self.acceptedContinuationSignature = signature;
                self.acceptedContinuationInput = snapshot.inputText;
                self.acceptedContinuationContextRevision = [self completionContextForSnapshot:snapshot].revision;
            }
            CPADiagnosticLog(@"suggestion next_after_accept mode=verified baseDebounceMs=%lu",
                (unsigned long)llround(CPASuggestionDebounceInterval * 1000.0));
            self.latestObservedEditWasDeletion = NO;
            self.dismissedSignature = nil;
            self.dismissedInputText = nil;
        }
    }
    if ([signature isEqualToString:self.dismissedSignature]
        && [snapshot.inputText isEqualToString:self.dismissedInputText]) {
        return;
    }
    if (self.lastSuggestionAcceptedDate != nil) {
        NSTimeInterval elapsedSinceAccept = -[self.lastSuggestionAcceptedDate
            timeIntervalSinceNow];
        if (CPAShouldSuppressDuringPostAcceptCooldown(elapsedSinceAccept)) {
            NSTimeInterval remaining = MAX(CPASuggestionDebounceInterval,
                CPAPostAcceptCooldownInterval - elapsedSinceAccept);
            self.suggestionTimer = CPAScheduleOneShotTimer(remaining,
                self, @selector(showAutomaticSuggestion:), signature);
            self.suggestionTimerConversationGeneration = self.conversationGeneration;
            CPADiagnosticLog(@"suggestion next_after_accept delayMs=%lu",
                (unsigned long)llround(remaining * 1000.0));
            return;
        }
        self.lastSuggestionAcceptedDate = nil;
    }

    NSTimeInterval elapsedSinceInputCancellation =
        self.lastInputModelCancellationDate == nil ? -1.0
        : -[self.lastInputModelCancellationDate timeIntervalSinceNow];
    NSTimeInterval debounceInterval = CPAAdaptiveSuggestionDebounceInterval(
        self.recentInputModelCancellationCount,
        elapsedSinceInputCancellation);
    if (debounceInterval <= CPASuggestionDebounceInterval) {
        self.lastInputModelCancellationDate = nil;
        self.recentInputModelCancellationCount = 0;
    } else {
        CPADiagnosticLog(@"suggestion debounce=adaptive intervalMs=%lu cancellationStreak=%lu",
            (unsigned long)llround(debounceInterval * 1000.0),
            (unsigned long)self.recentInputModelCancellationCount);
    }
    self.suggestionTimer = CPAScheduleOneShotTimer(
        debounceInterval,
        self,
        @selector(showAutomaticSuggestion:),
        signature);
    self.suggestionTimerConversationGeneration = self.conversationGeneration;
}

- (void)runProbe:(id)sender {
    (void)sender;
    CPAAccessibilitySnapshot *snapshot = [self.accessibilityService
        inspectFocusedElementForCodexProcessIdentifier:
            [self currentCodexProcessIdentifier]
        frontmostProcessIdentifier:self.cachedFrontmostProcessIdentifier];
    self.statusMenuItem.title = snapshot.summary;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = snapshot.summary;
    alert.informativeText = [NSString stringWithFormat:
        @"诊断信息：\n%@\n\n工具不会记录输入框正文，只统计字符数和控件属性。",
        snapshot.diagnostic];
    alert.alertStyle = snapshot.writableTextInput
        ? NSAlertStyleInformational
        : NSAlertStyleWarning;
    [alert addButtonWithTitle:@"知道了"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)requestAccessibilityPermission:(id)sender {
    (void)sender;
    [self.accessibilityService isTrustedWithPrompt:YES];
    [self updateStatus];
}

- (void)showTestOverlay:(id)sender {
    (void)sender;
    [self updateStatus];
    CPAAccessibilitySnapshot *snapshot = self.lastUsableSnapshot;
    if (snapshot == nil || !snapshot.hasSuggestionAnchor) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"暂时没有可用的输入框位置";
        alert.informativeText = @"请先在 Codex 输入框中点一下，然后再次从菜单栏选择“显示测试灰字”。";
        [alert addButtonWithTitle:@"知道了"];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
        return;
    }

    [self showSuggestionForSnapshot:snapshot automatic:NO];
}

- (void)showAutomaticSuggestion:(NSTimer *)timer {
    if (timer != self.suggestionTimer) {
        CPADiagnosticLog(@"suggestion timer_stale ignored=true");
        return;
    }
    self.suggestionTimer = nil;
    NSUInteger expectedConversationGeneration =
        self.suggestionTimerConversationGeneration;
    self.suggestionTimerConversationGeneration = 0;
    NSString *expectedSignature = timer.userInfo;
    CPAAccessibilitySnapshot *snapshot = [self snapshotForSuggestion];
    NSString *currentSignature = [self signatureForSnapshot:snapshot];
    BOOL usable = CPASnapshotCanDriveSuggestions(
        snapshot.targetApplicationIsFrontmost,
        snapshot.suggestionPolicyOutcome,
        snapshot.writableTextInput,
        snapshot.hasSuggestionAnchor,
        snapshot.hasValueCharacterCount,
        snapshot.hasSelectedRange,
        snapshot.valueCharacterCount);
    if (!usable
        || expectedConversationGeneration != self.conversationGeneration
        || ![currentSignature isEqualToString:expectedSignature]
        || ![snapshot.inputText isEqualToString:self.lastObservedInputText]
        || ([currentSignature isEqualToString:self.dismissedSignature]
            && [snapshot.inputText isEqualToString:self.dismissedInputText])) {
        return;
    }
    NSTimeInterval imeDelayRemaining =
        [self.keyboardInterceptor inputMethodSuggestionDelayRemaining];
    NSUInteger inputStableMilliseconds =
        CPAMillisecondsSinceDate(self.lastObservedInputChangeDate);
    if (imeDelayRemaining > 0) {
        CPADiagnosticLog(@"suggestion skip=ime inputLength=%lu inputStableMs=%lu remainingMs=%lu",
            (unsigned long)snapshot.valueCharacterCount,
            (unsigned long)inputStableMilliseconds,
            (unsigned long)llround(imeDelayRemaining * 1000.0));
        NSTimeInterval retryInterval = MIN(CPACompositionRetryInterval,
            MAX((NSTimeInterval)0.02, imeDelayRemaining));
        self.suggestionTimer = CPAScheduleOneShotTimer(
            retryInterval,
            self,
            @selector(showAutomaticSuggestion:),
            expectedSignature);
        self.suggestionTimerConversationGeneration = expectedConversationGeneration;
        return;
    }
    CPADiagnosticLog(@"suggestion trigger inputLength=%lu inputStableMs=%lu",
        (unsigned long)snapshot.valueCharacterCount,
        (unsigned long)inputStableMilliseconds);
    [self showSuggestionForSnapshot:snapshot automatic:YES];
}

- (void)showSuggestionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
                         automatic:(BOOL)automatic {
    if (snapshot.workBuddyContextReadPending) return;
    if (self.remoteSettings.localPaused && self.remoteSettings.paused) return;
    if (self.acceptancePending || [self.displayedSuggestionSignature isEqual:[self signatureForSnapshot:snapshot]]) return;
    if (!CPACompletionCanContinueAtCursor(snapshot.inputText ?: @"",
            (NSUInteger)snapshot.selectedLocation)) {
        [self.overlayController hide];
        [self clearDisplayedSuggestionState];
        return;
    }
    NSString *trigger = automatic ? @"automatic_show" : @"manual_show";
    NSString *signature = [self signatureForSnapshot:snapshot];
    NSString *insertionText = nil;
    if (automatic) {
        if (!self.remoteSettings.localPaused) {
            insertionText = [self.suggestionCoordinator
                automaticInsertionForSnapshot:snapshot signature:signature];
        }
        if (insertionText.length == 0) {
            CPADiagnosticLog(@"suggestion local_no_match inputLength=%lu cursor=%lu",
                (unsigned long)snapshot.valueCharacterCount,
                (unsigned long)snapshot.selectedLocation);
            [self.overlayController hide];
            [self scheduleModelSuggestionsForSnapshot:snapshot
                signature:signature delay:CPARemoteModelSuggestionDebounceInterval];
            return;
        }
    } else {
        insertionText = CPATestSuggestion;
    }
    if (insertionText.length == 0) {
        [self.overlayController hide];
        return;
    }
    if (automatic) {
        CPADiagnosticLog(@"suggestion local_show source=%@ inputLength=%lu outputLength=%lu",
            self.lastLocalSuggestionSource ?: @"unknown",
            (unsigned long)snapshot.valueCharacterCount,
            (unsigned long)insertionText.length);
    }
    [self displayInsertionText:insertionText snapshot:snapshot trigger:trigger];
    if (automatic) {
        // Once a qualified candidate is displayed its Tab target stays fixed.
        [self scheduleModelSuggestionsForSnapshot:snapshot
            signature:signature delay:CPARemoteModelSuggestionDebounceInterval];
    }
}

- (void)scheduleModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature delay:(NSTimeInterval)delay {
    if (self.displayedSuggestionSignature.length > 0 || self.acceptancePending) return;
    if (![self ensureCodexIDForSnapshot:snapshot signature:signature]) return;
    // A deletion pauses expensive work, but must not latch it off forever.
    // Re-enter the ordinary timer path so focus, input, IME and task identity
    // are all freshly checked before a stable deletion can request completion.
    NSTimeInterval deletionRemaining = self.latestObservedEditWasDeletion
        ? MAX(0.0, CPADeletionSuggestionDebounceInterval - CPAMillisecondsSinceDate(self.lastObservedInputChangeDate) / 1000.0)
        : 0.0;
    if (deletionRemaining > 0 && snapshot.selectedLength == 0) {
        [self.suggestionTimer invalidate];
        self.suggestionTimer = CPAScheduleOneShotTimer(deletionRemaining,
            self, @selector(showAutomaticSuggestion:), signature);
        self.suggestionTimerConversationGeneration = self.conversationGeneration;
        CPADiagnosticLog(@"model suggestions defer edit=deletion remainingMs=%lu",
            (unsigned long)ceil(deletionRemaining * 1000.0));
        return;
    }
    if (!CPAShouldScheduleModelSuggestions(
            deletionRemaining > 0, snapshot.selectedLength)) {
        CPADiagnosticLog(@"model suggestions suppress edit=%@ selectedLength=%ld",
            self.latestObservedEditWasDeletion ? @"deletion" : @"selection",
            (long)snapshot.selectedLength);
        return;
    }
    NSTimeInterval localDelay = MIN(MAX(0.0, delay),
        CPALocalModelSuggestionDebounceInterval);
    // `snapshot` has just passed the complete foreground/policy/IME gates.
    // The context provider exposes an immutable in-memory Ready state, so
    // waiting for a second 40ms timer and re-reading AX only adds latency. If
    // the context is still loading/empty, retain the asynchronous retry path
    // below; it avoids recursion and never guesses a conversation.
    BOOL contextReady = [self completionContextForSnapshot:snapshot].availability
        != CPAContextAvailabilityLoading;
    if (!self.remoteSettings.localPaused && CPALocalModelCanStartImmediately(contextReady)) {
        CPADiagnosticLog(@"model suggestions dispatch source=local mode=immediate inputLength=%lu inputStableMs=%lu",
            (unsigned long)snapshot.inputText.length,
            (unsigned long)CPAMillisecondsSinceDate(self.lastObservedInputChangeDate));
        [self startLocalModelSuggestionForSnapshot:snapshot signature:signature];
    } else {
        [self scheduleLocalModelSuggestionsForSnapshot:snapshot
            signature:signature delay:localDelay];
    }
    [self scheduleRemoteModelSuggestionsForSnapshot:snapshot
        signature:signature delay:MAX(0.0, delay)];
}

- (void)scheduleLocalModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature delay:(NSTimeInterval)delay {
    (void)snapshot;
    [self.localModelSuggestionTimer invalidate];
    self.localModelSuggestionTimer = nil;
    if (self.remoteSettings.localPaused) return;
    self.localModelSuggestionTimer = CPAScheduleOneShotTimer(
        MAX(0.0, delay),
        self,
        @selector(startDelayedLocalModelSuggestions:),
        signature);
    self.localModelSuggestionTimerConversationGeneration =
        self.conversationGeneration;
}

- (void)scheduleRemoteModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature delay:(NSTimeInterval)delay {
    [self.modelSuggestionTimer invalidate];
    self.modelSuggestionTimer = nil;
    if (self.remoteSettings.paused || self.acceptancePending
        || self.displayedSuggestionSignature.length > 0) return;
    if (snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeLocalAndRemote) {
        return;
    }
    self.modelSuggestionTimer = CPAScheduleOneShotTimer(
        MAX(0.0, delay),
        self,
        @selector(startDelayedRemoteModelSuggestions:),
        signature);
    self.modelSuggestionTimerConversationGeneration = self.conversationGeneration;
}

- (nullable CPAAccessibilitySnapshot *)validatedModelSuggestionSnapshotForSignature:
    (NSString *)signature conversationGeneration:(NSUInteger)conversationGeneration {
    if (self.suggestionsPaused || conversationGeneration != self.conversationGeneration) {
        return nil;
    }
    CPAAccessibilitySnapshot *snapshot = [self snapshotForSuggestion];
    NSString *currentSignature = [self signatureForSnapshot:snapshot];
    BOOL usable = snapshot.targetApplicationIsFrontmost
        && !snapshot.workBuddyContextReadPending
        && snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
        && snapshot.writableTextInput
        && snapshot.hasSuggestionAnchor && snapshot.hasSelectedRange
        && snapshot.selectedLength == 0 && snapshot.inputText.length > 0
        && snapshot.selectedLocation > 0
        && snapshot.selectedLocation <= (NSInteger)snapshot.inputText.length;
    if (!usable || ![currentSignature isEqualToString:signature]
        || ![snapshot.inputText isEqualToString:self.lastObservedInputText]
        || ([currentSignature isEqualToString:self.dismissedSignature]
            && [snapshot.inputText isEqualToString:self.dismissedInputText])) {
        return nil;
    }
    return snapshot;
}

- (void)startDelayedLocalModelSuggestions:(NSTimer *)timer {
    if (timer != self.localModelSuggestionTimer) {
        return;
    }
    self.localModelSuggestionTimer = nil;
    NSUInteger expectedGeneration =
        self.localModelSuggestionTimerConversationGeneration;
    self.localModelSuggestionTimerConversationGeneration = 0;
    NSString *expectedSignature = timer.userInfo;
    CPAAccessibilitySnapshot *snapshot =
        [self validatedModelSuggestionSnapshotForSignature:expectedSignature
            conversationGeneration:expectedGeneration];
    if (snapshot == nil) {
        return;
    }
    CPADiagnosticLog(@"model suggestions trigger source=local mode=timer inputLength=%lu inputStableMs=%lu",
        (unsigned long)snapshot.inputText.length,
        (unsigned long)CPAMillisecondsSinceDate(self.lastObservedInputChangeDate));
    [self startLocalModelSuggestionForSnapshot:snapshot signature:expectedSignature];
}

- (void)startDelayedRemoteModelSuggestions:(NSTimer *)timer {
    if (timer != self.modelSuggestionTimer) {
        return;
    }
    self.modelSuggestionTimer = nil;
    NSUInteger expectedGeneration = self.modelSuggestionTimerConversationGeneration;
    self.modelSuggestionTimerConversationGeneration = 0;
    NSString *expectedSignature = timer.userInfo;
    // Each enabled provider gets its own deadline. Local decoding is not a
    // prerequisite for remote; publication still fixes the first valid result.
    CPAAccessibilitySnapshot *snapshot =
        [self validatedModelSuggestionSnapshotForSignature:expectedSignature
            conversationGeneration:expectedGeneration];
    if (snapshot == nil) {
        return;
    }
    CPADiagnosticLog(@"model suggestions trigger source=remote inputLength=%lu inputStableMs=%lu",
        (unsigned long)snapshot.inputText.length,
        (unsigned long)CPAMillisecondsSinceDate(self.lastObservedInputChangeDate));
    [self startRemoteSuggestionForSnapshot:snapshot signature:expectedSignature];
}

- (void)scheduleContextReadyRetryForSignature:(NSString *)signature {
    CPAAccessibilitySnapshot *snapshot = [self snapshotForSuggestion];
    [self scheduleModelSuggestionsForSnapshot:snapshot
        signature:signature delay:0.08];
}

- (void)startLocalModelSuggestionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature {
    [self conversationContextDidChange];
    if (self.remoteSettings.localPaused || self.acceptancePending
        || self.displayedSuggestionSignature.length > 0) return;
    if (![self ensureCodexIDForSnapshot:snapshot signature:signature]) return;
    if ([self validatedModelSuggestionSnapshotForSignature:signature
            conversationGeneration:self.conversationGeneration] == nil) return;
    if (!CPACompletionCanContinueAtCursor(snapshot.inputText, (NSUInteger)snapshot.selectedLocation)
        || !CPARemoteInputIsEligible(snapshot.inputText, snapshot.selectedLocation, snapshot.selectedLength)) return;
    if (self.localModelTask != nil && [self.localModelTaskSignature isEqual:signature]) return;
    CPAConversationContextSnapshot *context = [self completionContextForSnapshot:snapshot];
    if (context.availability == CPAContextAvailabilityLoading) {
        [self scheduleContextReadyRetryForSignature:signature]; return;
    }
    [self cancelLocalModelWarmupIfPending];
    NSUInteger conversationGeneration = self.conversationGeneration;
    NSString *requestedInput = [snapshot.inputText copy];
    self.localTaskContext = context;
    self.localModelTaskContextGeneration = context.revision;
    self.localModelTaskConversationGeneration = conversationGeneration;
    self.localModelTaskInput = requestedInput; self.localModelTaskSignature = signature;
    self.localModelTaskStartedAt = NSDate.date;
    NSDate *observedAt = self.lastObservedInputChangeDate;
    __weak CPAAppDelegate *weakSelf = self;
    __block CPARemoteCompletionTask *issuedTask = nil;
    CPADiagnosticLog(@"model_context source=local count=%lu revision=%lu codexIDBound=%@ document=%@",
        (unsigned long)context.messages.count, (unsigned long)context.revision, self.codexIDIdentifier != nil ? @"true" : @"false", snapshot.documentContinuation ? @"true" : @"false");
    // The small model failed author-scope controls. With remote authorized,
    // retain fast verified literal completion locally and route open authoring
    // to remote. Local-only settings/policy keep the established local path.
    self.localModelClient.literalContinuationsOnly = !self.remoteSettings.paused
        && snapshot.suggestionPolicyOutcome == CPASuggestionPolicyOutcomeLocalAndRemote;
    self.localModelClient.documentContinuation = snapshot.documentContinuation;
    self.localModelClient.applicationBundleIdentifier = snapshot.targetBundleIdentifier ?: @"";
    issuedTask = [self.localModelClient requestCompletionForInput:requestedInput
        contextMessages:context.messages ?: @[] apiKey:CPALocalModelAPIKey preferredModel:CPALocalModelName
        progress:nil completion:^(CPARemoteCompletionResult *result) {
        CPAAppDelegate *owner = weakSelf;
        if (owner == nil || owner.localModelTask != issuedTask) return;
        [owner recordCompletionResult:result source:@"local_model" observedAt:observedAt];
        owner.localModelTask = nil; owner.localTaskContext = nil;
        owner.localModelTaskInput = nil; owner.localModelTaskSignature = nil;
        owner.localModelTaskStartedAt = nil; owner.localModelTaskContextGeneration = 0;
        owner.localModelTaskConversationGeneration = 0;
        [owner conversationContextDidChange];
        if (![owner contextIsCurrent:context] || result.outcome != CPARemoteCompletionOutcomeSuccess
            || result.insertionText.length == 0) return;
        CPAAccessibilitySnapshot *current = [owner validatedModelSuggestionSnapshotForSignature:signature
            conversationGeneration:conversationGeneration];
        if (current == nil) { [owner recheckAfterUnavailableResultForSignature:signature]; return; }
        [owner displayInsertionText:result.insertionText snapshot:current trigger:@"local_model_show"
            context:context];

    }];
    self.localModelTask = issuedTask;
}

- (void)startRemoteSuggestionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature {
    if (snapshot.workBuddyContextReadPending) return;
    [self conversationContextDidChange];
    if (self.remoteSettings.paused || self.acceptancePending
        || self.displayedSuggestionSignature.length > 0) return;
    if (snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeLocalAndRemote) {
        return;
    }
    if (![self ensureCodexIDForSnapshot:snapshot signature:signature]) return;
    CPAConversationContextSnapshot *context = [self completionContextForSnapshot:snapshot];
    if (context.availability == CPAContextAvailabilityLoading) {
        [self scheduleContextReadyRetryForSignature:signature];
        CPADiagnosticLog(@"remote deferred context_loading generation=%lu",
            (unsigned long)self.contextProvider.contextGeneration);
        return;
    }
    if (!snapshot.hasSelectedRange || snapshot.selectedLength != 0
        || snapshot.selectedLocation < 0
        || (NSUInteger)snapshot.selectedLocation > snapshot.inputText.length) {
        CPADiagnosticLog(@"remote skip=selection");
        return;
    }
    if (!CPACompletionCanContinueAtCursor(snapshot.inputText, (NSUInteger)snapshot.selectedLocation)) return;
    NSString *originalInput = [snapshot.inputText copy];
    NSString *inputBeforeCursor = [originalInput substringToIndex:
        (NSUInteger)snapshot.selectedLocation];
    if (!CPARemoteInputIsEligible(inputBeforeCursor,
        snapshot.selectedLocation, snapshot.selectedLength)) {
        NSString *reason = @"input_too_long";
        CPADiagnosticLog(@"remote skip=%@ inputLength=%lu cursor=%ld",
            reason,
            (unsigned long)originalInput.length,
            (long)snapshot.selectedLocation);
        return;
    }
    if (self.remoteTask != nil
        && [self.remoteTaskSignature isEqualToString:signature]
        && [self.remoteTaskInput isEqualToString:inputBeforeCursor]) {
        CPADiagnosticLog(@"remote duplicate_suppressed inputLength=%lu",
            (unsigned long)inputBeforeCursor.length);
        return;
    }
    if ([self canKeepRemoteTaskForSnapshot:snapshot]) {
        CPADiagnosticLog(@"remote speculative_wait inputLength=%lu requestInputLength=%lu",
            (unsigned long)snapshot.inputText.length,
            (unsigned long)self.remoteTaskInput.length);
        return;
    }
    if ([self.remotePreparationSignature isEqualToString:signature]
        && [self.remotePreparationInput isEqualToString:inputBeforeCursor]) {
        return;
    }
    self.remotePreparationSignature = [signature copy];
    self.remotePreparationInput = [inputBeforeCursor copy];
    NSUInteger conversationGeneration = self.conversationGeneration;
    NSUInteger contextGeneration = context.revision;
    self.remotePreparationContext = context;
    self.remotePreparationConversationGeneration = conversationGeneration;
    NSUInteger preparationGeneration = ++self.remotePreparationGeneration;
    NSString *cachedAPIKey = [self.cachedAPIKey copy];
    NSString *preferredModel = [self.remoteSettings.preferredModel copy];
    NSDate *preparationStartedAt = [NSDate date];
    CPADiagnosticLog(@"remote prepare inputLength=%lu model=%@ source=%@",
        (unsigned long)inputBeforeCursor.length,
        preferredModel.length > 0 ? preferredModel : @"auto",
        cachedAPIKey.length > 0 ? @"memory" : @"keychain_background");
    __weak CPAAppDelegate *weakSelf = self;
    if (cachedAPIKey.length == 0) {
        self.remotePreparationTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:
            CPARemotePreparationTimeoutInterval
            target:self
            selector:@selector(remotePreparationTimedOut:)
            userInfo:@(preparationGeneration)
            repeats:NO];
        dispatch_async(self.remotePreparationQueue, ^{
            NSError *keyError = nil;
            NSString *apiKey = [weakSelf.remoteSettings apiKey:&keyError];
            dispatch_async(dispatch_get_main_queue(), ^{
                CPAAppDelegate *strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                CPADiagnosticLog(@"remote prepare_finish generation=%lu durationMs=%lu key=%@ errorDomain=%@ errorCode=%ld",
                    (unsigned long)preparationGeneration,
                    (unsigned long)llround(-[preparationStartedAt timeIntervalSinceNow] * 1000.0),
                    apiKey.length > 0 ? @"loaded" : @"missing",
                    keyError.domain,
                    (long)keyError.code);
                if (apiKey.length > 0 && keyError == nil) {
                    strongSelf.cachedAPIKey = apiKey;
                }
                BOOL stillPreparing = [strongSelf contextIsCurrent:context] && preparationGeneration == strongSelf.remotePreparationGeneration
                    && conversationGeneration == strongSelf.conversationGeneration
                    && conversationGeneration
                        == strongSelf.remotePreparationConversationGeneration
                    && [strongSelf.remotePreparationSignature isEqualToString:signature]
                    && [strongSelf.remotePreparationInput isEqualToString:inputBeforeCursor];
                if (!stillPreparing) {
                    CPADiagnosticLog(@"remote prepare_discard generation=%lu",
                        (unsigned long)preparationGeneration);
                    return;
                }
                [strongSelf.remotePreparationTimeoutTimer invalidate];
                strongSelf.remotePreparationTimeoutTimer = nil;
                strongSelf.remotePreparationSignature = nil;
                strongSelf.remotePreparationInput = nil;
                strongSelf.remotePreparationConversationGeneration = 0;
                if (apiKey.length == 0 || keyError != nil) {
                    CPADiagnosticLog(@"remote skip=not_configured errorDomain=%@ errorCode=%ld",
                        keyError.domain, (long)keyError.code);
                    return;
                }
                strongSelf.cachedAPIKey = apiKey;
                [strongSelf issueRemoteSuggestionForInput:inputBeforeCursor
                    originalInput:originalInput signature:signature apiKey:apiKey
                    preferredModel:preferredModel
                    conversationGeneration:conversationGeneration
                    contextGeneration:contextGeneration];
            });
        });
        return;
    }
    [self.remotePreparationTimeoutTimer invalidate];
    self.remotePreparationTimeoutTimer = nil;
    self.remotePreparationSignature = nil;
    self.remotePreparationInput = nil;
    self.remotePreparationConversationGeneration = 0;
    self.programmaticInsertionExpectedInput = nil;
    [self issueRemoteSuggestionForInput:inputBeforeCursor
        originalInput:originalInput signature:signature apiKey:cachedAPIKey
        preferredModel:preferredModel
        conversationGeneration:conversationGeneration
        contextGeneration:contextGeneration];
}

- (void)issueRemoteSuggestionForInput:(NSString *)inputBeforeCursor
    originalInput:(NSString *)originalInput signature:(NSString *)signature apiKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel conversationGeneration:(NSUInteger)conversationGeneration
    contextGeneration:(NSUInteger)contextGeneration {
    [self conversationContextDidChange];
    CPAAccessibilitySnapshot *snapshot = [self validatedModelSuggestionSnapshotForSignature:signature
        conversationGeneration:conversationGeneration];
    if (![snapshot.inputText isEqual:originalInput] || ![originalInput hasPrefix:inputBeforeCursor]) return;
    if (self.remoteSettings.paused || snapshot == nil || self.acceptancePending
        || self.displayedSuggestionSignature.length > 0
        || snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeLocalAndRemote) return;
    CPAConversationContextSnapshot *context = [self completionContextForSnapshot:snapshot];
    if (context.revision != contextGeneration || context.availability == CPAContextAvailabilityLoading) return;
    self.remotePreparationContext = nil;
    self.remoteTaskContext = context; self.remoteTaskContextGeneration = context.revision;
    self.remoteTaskInput = inputBeforeCursor; self.remoteTaskSignature = signature;
    self.remoteTaskConversationGeneration = conversationGeneration;
    self.remoteTaskStartedAt = NSDate.date;
    NSDate *observedAt = self.lastObservedInputChangeDate;
    __weak CPAAppDelegate *weakSelf = self;
    __block CPARemoteCompletionTask *issuedTask = nil;
    CPADiagnosticLog(@"model_context source=remote count=%lu revision=%lu codexIDBound=%@ document=%@",
        (unsigned long)context.messages.count, (unsigned long)context.revision, self.codexIDIdentifier != nil ? @"true" : @"false", snapshot.documentContinuation ? @"true" : @"false");
    // Capture request-time metadata; never infer it from mutable state at completion.
    BOOL requestAfterAcceptance = [self.acceptedContinuationSignature isEqual:signature]
        && [self.acceptedContinuationInput isEqual:originalInput]
        && self.acceptedContinuationContextRevision == context.revision;
    NSString *requestTrigger = requestAfterAcceptance ? @"after_acceptance"
        : self.latestObservedEditWasDeletion ? @"deletion" : @"edit_or_refresh";
    BOOL requestDocument = snapshot.documentContinuation;
    BOOL requestCodexBound = self.codexIDIdentifier != nil;
    NSUInteger requestRightLength = originalInput.length - inputBeforeCursor.length;
    NSUInteger requestUserCount = 0, requestAssistantCount = 0, requestContextCharacters = 0;
    for (NSDictionary *message in context.messages) {
        if ([message[@"role"] isEqual:@"user"]) requestUserCount++;
        if ([message[@"role"] isEqual:@"assistant"]) requestAssistantCount++;
        if ([message[@"content"] isKindOfClass:NSString.class]) requestContextCharacters += [message[@"content"] length];
    }
    CPARemoteCompletionHandler handler = ^(CPARemoteCompletionResult *result) {
        CPAAppDelegate *owner = weakSelf;
        if (owner == nil || owner.remoteTask != issuedTask) return;
        [owner recordCompletionResult:result source:@"remote" observedAt:observedAt];
        CPADiagnosticLog(@"remote request_context requestID=%@ trigger=%@ document=%@ rightLength=%lu contextCount=%lu userCount=%lu assistantCount=%lu contextCharacters=%lu contextRevision=%lu codexIDBound=%@",
            result.requestID, requestTrigger, requestDocument ? @"true" : @"false",
            (unsigned long)requestRightLength, (unsigned long)context.messages.count,
            (unsigned long)requestUserCount, (unsigned long)requestAssistantCount,
            (unsigned long)requestContextCharacters, (unsigned long)context.revision,
            requestCodexBound ? @"true" : @"false");
        owner.remoteTask = nil; owner.remoteTaskContext = nil;
        owner.remoteTaskInput = nil; owner.remoteTaskSignature = nil;
        owner.remoteTaskStartedAt = nil; owner.remoteTaskContextGeneration = 0;
        owner.remoteTaskConversationGeneration = 0;
        [owner conversationContextDidChange];
        if (![owner contextIsCurrent:context] || conversationGeneration != owner.conversationGeneration
            || result.outcome != CPARemoteCompletionOutcomeSuccess || result.insertionText.length == 0) return;
        CPAAccessibilitySnapshot *current = [owner validatedModelSuggestionSnapshotForSignature:signature
            conversationGeneration:conversationGeneration];
        if (current == nil) { [owner recheckAfterUnavailableResultForSignature:signature]; return; } // A new input revision needs a new request, not an old completion.
        [owner displayInsertionText:result.insertionText snapshot:current trigger:@"remote_show" context:context];

    };
    self.remoteClient.documentContinuation = snapshot.documentContinuation;
    self.remoteClient.applicationBundleIdentifier = snapshot.targetBundleIdentifier ?: @"";
    self.remoteClient.continuationAfterAcceptance = requestAfterAcceptance;
    CPADiagnosticLog(@"remote continuation_stage=%@", self.remoteClient.continuationAfterAcceptance ? @"after_acceptance" : @"ordinary");
    NSString *rightContext = [originalInput substringFromIndex:inputBeforeCursor.length];
    if (rightContext.length) issuedTask = [self.remoteClient requestCompletionForInput:inputBeforeCursor
        rightContext:rightContext contextMessages:context.messages ?: @[] apiKey:apiKey preferredModel:preferredModel
        progress:nil completion:handler];
    else issuedTask = [self.remoteClient requestCompletionForInput:inputBeforeCursor
        contextMessages:context.messages ?: @[] apiKey:apiKey preferredModel:preferredModel progress:nil completion:handler];

    self.remoteTask = issuedTask;
}

- (void)scheduleRemoteRetryForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature {
    if (snapshot.inputText.length == 0 || signature.length == 0) {
        return;
    }
    [self scheduleRemoteModelSuggestionsForSnapshot:snapshot
        signature:signature delay:CPARemoteRetryDelay];
    CPADiagnosticLog(@"remote retry_scheduled delayMs=%lu inputLength=%lu",
        (unsigned long)llround(CPARemoteRetryDelay * 1000.0),
        (unsigned long)snapshot.inputText.length);
}

- (void)remotePreparationTimedOut:(NSTimer *)timer {
    NSNumber *generation = timer.userInfo;
    if (generation.unsignedIntegerValue != self.remotePreparationGeneration) {
        return;
    }
    self.remotePreparationTimeoutTimer = nil;
    self.remotePreparationContext = nil;
    self.remotePreparationGeneration++;
    self.remotePreparationSignature = nil;
    self.remotePreparationInput = nil;
    self.remotePreparationConversationGeneration = 0;
    CPADiagnosticLog(@"remote prepare_timeout generation=%lu durationMs=%lu",
        (unsigned long)generation.unsignedIntegerValue,
        (unsigned long)llround(CPARemotePreparationTimeoutInterval * 1000.0));
}

- (BOOL)displayInsertionText:(NSString *)insertionText snapshot:(CPAAccessibilitySnapshot *)snapshot
    trigger:(NSString *)trigger {
    return [self displayInsertionText:insertionText snapshot:snapshot trigger:trigger context:nil];
}

- (BOOL)displayInsertionText:(NSString *)insertionText snapshot:(CPAAccessibilitySnapshot *)snapshot
    trigger:(NSString *)trigger context:(CPAConversationContextSnapshot *)context {
    NSAssert(NSThread.isMainThread, @"Candidate publication belongs to the main thread");
    NSString *signature = [self signatureForSnapshot:snapshot];
    BOOL usable = !self.suggestionsPaused && !(self.remoteSettings.localPaused && self.remoteSettings.paused)
        && !snapshot.workBuddyContextReadPending
        && snapshot.targetApplicationIsFrontmost
        && snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
        && signature.length > 0 && snapshot.hasSelectedRange && snapshot.selectedLength == 0
        && snapshot.policyRuleVersion == self.policyCoordinator.ruleVersion
        && (self.cachedFrontmostProcessIdentifier <= 0
            || (snapshot.targetProcessIdentifier == self.cachedFrontmostProcessIdentifier
                && [snapshot.targetBundleIdentifier isEqual:self.cachedFrontmostBundleIdentifier]));
    if (self.displayedSuggestionSignature != nil && (!usable
        || ![signature isEqual:self.displayedSuggestionSignature]
        || ![self contextIsCurrent:self.displayedContext])) {
        [self.overlayController hide]; [self.suggestionCoordinator clear]; [self clearDisplayedSuggestionState];
    }
    if (!usable || self.acceptancePending || ![self contextIsCurrent:context]
        || ([trigger hasPrefix:@"remote_"] && (self.remoteSettings.paused
            || snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeLocalAndRemote))
        || [signature isEqual:self.dismissedSignature]) return NO;
    // No mutation until the exact candidate passes the common gate. An existing
    // qualified display has priority over every late proposal, regardless of provider.
    if (self.displayedSuggestionSignature.length > 0) return NO;
    CPARemoteCompletionProtocol *quality = [CPARemoteCompletionProtocol new];
    if (snapshot.selectedLocation < 0 || (NSUInteger)snapshot.selectedLocation > snapshot.inputText.length) return NO;
    NSString *left = [snapshot.inputText substringToIndex:(NSUInteger)snapshot.selectedLocation];
    NSString *right = [snapshot.inputText substringFromIndex:(NSUInteger)snapshot.selectedLocation];
    NSString *validated = [quality normalizedCompletion:insertionText sentInput:left contextMessages:context.messages ?: @[]];
    if (!CPACompletionCanContinueAtCursor(snapshot.inputText ?: @"", (NSUInteger)snapshot.selectedLocation)
        || ![validated isEqualToString:insertionText] || !CPAInsertionFitsRightContext(validated, right)
        || (right.length == 0 && ![quality completionMeetsMinimumLength:validated sentInput:left contextMessages:context.messages ?: @[]])) return NO;
    if (![self contextIsCurrent:context]) return NO;
    [self.suggestionCoordinator prepareRemoteInsertion:insertionText signature:signature];
    self.displayedSuggestionSignature = signature;
    self.displayedSuggestionInputText = [snapshot.inputText copy];
    self.displayedSuggestionConversationGeneration = self.conversationGeneration;
    self.displayedContext = context;
    self.remoteDisplayedSignature = [trigger hasPrefix:@"remote_"] ? signature : nil;
    self.localModelDisplayedSignature = [trigger hasPrefix:@"local_model_"] ? signature : nil;
    self.localModelDisplayedPreview = NO;
    if (snapshot.hasCaretBounds) {
        [self.overlayController showSuggestion:insertionText
            atAccessibilityBounds:snapshot.caretBounds];
        CPADiagnosticLog(@"overlay %@ mode=caret bounds=%@",
            trigger,
            NSStringFromRect(NSRectFromCGRect(snapshot.caretBounds)));
    } else if (snapshot.hasElementFrame) {
        [self.overlayController showSuggestionBar:insertionText
            atAccessibilityInputFrame:snapshot.elementFrame];
        CPADiagnosticLog(@"overlay %@ mode=input_bar frame=%@",
            trigger,
            NSStringFromRect(NSRectFromCGRect(snapshot.elementFrame)));
    }
    if (!self.overlayController.visible) {
        [self.suggestionCoordinator clear];
        [self clearDisplayedSuggestionState];
        return NO;
    }
    return YES;
}

- (void)clearDisplayedSuggestionState {
    self.displayedContext = nil;
    self.remoteDisplayedSignature = nil; self.localModelDisplayedSignature = nil;
    self.displayedSuggestionSignature = nil;
    self.displayedSuggestionInputText = nil;
    self.displayedSuggestionConversationGeneration = 0;
    self.localModelDisplayedPreview = NO;
}

- (NSString *)signatureForSnapshot:(CPAAccessibilitySnapshot *)snapshot {
    snapshot.candidateContextGeneration = self.conversationGeneration;
    return [self.suggestionCoordinator inputSignatureForSnapshot:snapshot];
}

- (void)invalidateSuggestionTimersAndPreparation {
    self.remotePreparationGeneration++;
    self.remotePreparationContext = nil;
    [self.remotePreparationTimeoutTimer invalidate];
    self.remotePreparationTimeoutTimer = nil;
    self.remotePreparationSignature = nil;
    self.remotePreparationInput = nil;
    self.remotePreparationConversationGeneration = 0;
    [self.focusLossTimer invalidate];
    self.focusLossTimer = nil;
    [self.suggestionTimer invalidate];
    self.suggestionTimer = nil;
    self.suggestionTimerConversationGeneration = 0;
    [self.localModelSuggestionTimer invalidate];
    self.localModelSuggestionTimer = nil;
    self.localModelSuggestionTimerConversationGeneration = 0;
    [self.modelSuggestionTimer invalidate];
    self.modelSuggestionTimer = nil;
    self.modelSuggestionTimerConversationGeneration = 0;
}

- (void)recordModelCancellationForReason:(NSString *)reason
    keepingRemoteTask:(BOOL)keepingRemoteTask {
    BOOL cancelsLocalTask = self.localModelTask != nil;
    BOOL cancelsRemoteTask = self.remoteTask != nil && !keepingRemoteTask;
    if (!cancelsLocalTask && !cancelsRemoteTask) {
        return;
    }
    if (cancelsLocalTask && [reason isEqualToString:@"input_changed"]) {
        NSTimeInterval elapsedSincePreviousCancellation =
            self.lastInputModelCancellationDate == nil ? -1.0
            : -[self.lastInputModelCancellationDate timeIntervalSinceNow];
        self.recentInputModelCancellationCount =
            CPAUpdatedInputCancellationStreak(
                self.recentInputModelCancellationCount,
                elapsedSincePreviousCancellation);
        self.lastInputModelCancellationDate = NSDate.date;
    }
    CPADiagnosticLog(@"model cancel reason=%@ local=%@ localAgeMs=%lu remote=%@ remoteAgeMs=%lu keepRemote=%@ cancellationStreak=%lu",
        reason,
        cancelsLocalTask ? @"true" : @"false",
        (unsigned long)(cancelsLocalTask
            ? CPAMillisecondsSinceDate(self.localModelTaskStartedAt) : 0),
        cancelsRemoteTask ? @"true" : @"false",
        (unsigned long)(cancelsRemoteTask
            ? CPAMillisecondsSinceDate(self.remoteTaskStartedAt) : 0),
        keepingRemoteTask ? @"true" : @"false",
        (unsigned long)self.recentInputModelCancellationCount);
}

- (void)cancelPendingSuggestionForReason:(NSString *)reason {
    self.codexIDGeneration++; [self.codexIDResolver cancel];
    if (self.codexIDResolver != nil && ![reason isEqual:@"accept_validation"]
        && ![reason isEqual:@"input_changed"]) {
        self.codexIDSignature = nil; self.codexIDIdentifier = nil; self.codexIDTaskKey = nil;
        [self.contextProvider invalidateCachedContext];
    }
    [self invalidatePendingAcceptance];
    [self recordModelCancellationForReason:reason keepingRemoteTask:NO];
    [self invalidateSuggestionTimersAndPreparation];
    CPARemoteCompletionTask *remoteTask = self.remoteTask;
    self.remoteTaskContext = nil;
    self.remoteTask = nil;
    self.remoteTaskStartedAt = nil;
    self.remoteTaskInput = nil;
    self.remoteTaskSignature = nil;
    self.remoteTaskConversationGeneration = 0;
    self.remoteTaskContextGeneration = 0;
    [remoteTask cancel];
    CPARemoteCompletionTask *localModelTask = self.localModelTask;
    self.localTaskContext = nil;
    self.localModelTask = nil;
    self.localModelTaskStartedAt = nil;
    self.localModelTaskInput = nil;
    self.localModelTaskSignature = nil;
    self.localModelTaskConversationGeneration = 0;
    self.localModelTaskContextGeneration = 0;
    [localModelTask cancel];
    self.localModelDisplayedSignature = nil;
    self.localModelDisplayedPreview = NO;
    self.remoteDisplayedSignature = nil;
    [self clearPendingRemoteSuggestion];
}

- (void)clearPendingRemoteSuggestion {
    self.pendingRemoteContext = nil; self.pendingRemoteSignature = nil;
    self.pendingRemoteInsertion = nil;
    self.pendingRemoteRequestedInput = nil;
    self.pendingRemoteExpiry = nil;
    self.pendingRemoteConversationGeneration = 0;
}

- (BOOL)displayPendingRemoteSuggestionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature {
    if (self.pendingRemoteInsertion.length == 0
        || self.pendingRemoteRequestedInput.length == 0
        || self.pendingRemoteExpiry == nil) {
        return NO;
    }
    if (self.remoteSettings.paused || snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeLocalAndRemote
        || ![self contextIsCurrent:self.pendingRemoteContext]
        || ![signature isEqual:self.pendingRemoteSignature]
        || self.pendingRemoteConversationGeneration != self.conversationGeneration) {
        CPADiagnosticLog(@"remote pending_discard reason=conversation_changed");
        [self clearPendingRemoteSuggestion];
        return NO;
    }
    if ([self.pendingRemoteExpiry timeIntervalSinceNow] <= 0.0) {
        CPADiagnosticLog(@"remote pending_expired");
        [self clearPendingRemoteSuggestion];
        return NO;
    }
    BOOL usable = snapshot.targetApplicationIsFrontmost
        && snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
        && snapshot.writableTextInput
        && snapshot.hasSuggestionAnchor
        && snapshot.hasSelectedRange
        && snapshot.selectedLength == 0
        && snapshot.inputText.length > 0
        && snapshot.selectedLocation == (NSInteger)snapshot.inputText.length;
    if (!usable) {
        return NO;
    }
    NSString *inputBeforeCursor = [snapshot.inputText substringToIndex:
        (NSUInteger)snapshot.selectedLocation];
    NSString *rebasedInsertion = CPARemoteRebaseInsertion(
        self.pendingRemoteInsertion,
        self.pendingRemoteRequestedInput,
        inputBeforeCursor);
    if (rebasedInsertion.length == 0) {
        CPADiagnosticLog(@"remote pending_discard inputLength=%lu",
            (unsigned long)inputBeforeCursor.length);
        [self clearPendingRemoteSuggestion];
        return NO;
    }
    if ([signature isEqualToString:self.dismissedSignature]
        && [snapshot.inputText isEqualToString:self.dismissedInputText]) {
        [self clearPendingRemoteSuggestion];
        return NO;
    }
    BOOL committed = [self displayInsertionText:rebasedInsertion snapshot:snapshot
        trigger:@"remote_show_deferred" context:self.pendingRemoteContext];
    if (!committed) { [self clearPendingRemoteSuggestion]; return NO; }
    self.lastObservedSignature = [signature copy];
    self.lastObservedInputText = [snapshot.inputText copy];
    CPADiagnosticLog(@"remote pending_show inputLength=%lu outputLength=%lu",
        (unsigned long)inputBeforeCursor.length,
        (unsigned long)rebasedInsertion.length);
    [self clearPendingRemoteSuggestion];
    return YES;
}

- (BOOL)canKeepRemoteTaskForSnapshot:(CPAAccessibilitySnapshot *)snapshot {
    if (![self.remoteTaskSignature isEqual:[self signatureForSnapshot:snapshot]]
        || ![self contextIsCurrent:self.remoteTaskContext]
        || self.remoteTask == nil || self.remoteTaskInput.length == 0
        || self.remoteTaskSignature.length == 0
        || self.remoteTaskConversationGeneration != self.conversationGeneration
        || snapshot.inputText == nil || !snapshot.hasSelectedRange) {
        return NO;
    }
    return CPARemoteCanReusePrefixRequest(
        self.remoteTaskInput,
        snapshot.inputText,
        snapshot.selectedLocation,
        snapshot.selectedLength);
}

- (void)cancelPendingSuggestionKeepingRemoteTaskForReason:(NSString *)reason {
    [self recordModelCancellationForReason:reason keepingRemoteTask:YES];
    [self invalidateSuggestionTimersAndPreparation];
    CPARemoteCompletionTask *localModelTask = self.localModelTask;
    self.localTaskContext = nil;
    self.localModelTask = nil;
    self.localModelTaskStartedAt = nil;
    self.localModelTaskInput = nil;
    self.localModelTaskSignature = nil;
    self.localModelTaskConversationGeneration = 0;
    self.localModelTaskContextGeneration = 0;
    [localModelTask cancel];
    self.localModelDisplayedSignature = nil;
}

- (void)scheduleFocusLossCancellation {
    if (self.focusLossTimer != nil) {
        return;
    }
    self.focusLossTimer = CPAScheduleOneShotTimer(
        CPARemoteFocusLossGraceInterval,
        self,
        @selector(cancelAfterFocusLossGrace:),
        nil);
}

- (void)cancelAfterFocusLossGrace:(NSTimer *)timer {
    if (timer != self.focusLossTimer) {
        return;
    }
    self.focusLossTimer = nil;
    CPAAccessibilitySnapshot *snapshot = [self snapshotForSuggestion];
    BOOL usable = CPASnapshotCanDriveSuggestions(
        snapshot.targetApplicationIsFrontmost,
        snapshot.suggestionPolicyOutcome,
        snapshot.writableTextInput,
        snapshot.hasSuggestionAnchor,
        snapshot.hasValueCharacterCount,
        snapshot.hasSelectedRange,
        snapshot.valueCharacterCount)
        && snapshot.inputText != nil
        ;
    if (!usable) {
        CPADiagnosticLog(@"suggestion cancel=focus_grace_expired");
        [self cancelPendingSuggestionForReason:@"focus_grace_expired"];
        [self.overlayController hide];
        [self clearDisplayedSuggestionState];
    }
}

- (BOOL)keyboardInterceptorShouldHandleSuggestionKeys {
    if (self.acceptancePending && !self.suggestionsPaused) return YES;
    if (self.suggestionsPaused || !self.overlayController.visible) {
        return NO;
    }
    // The overlay itself is the authoritative indication that a suggestion
    // is actionable. During Chromium AX churn, requiring a fresh focused
    // element here lets Tab fall through to Codex's model-picker focus ring.
    NSString *frontmostBundleIdentifier =
        self.cachedFrontmostBundleIdentifier ?: @"";
    if ([frontmostBundleIdentifier isEqualToString:@"com.openai.codex"]
        && self.currentPolicyDecision != nil
        && self.currentPolicyDecision.outcome != CPASuggestionPolicyOutcomeDisabled) {
        return YES;
    }
    CPAAccessibilitySnapshot *cached = [frontmostBundleIdentifier
        isEqualToString:@"com.openai.codex"] ? self.cachedCodexSnapshot
        : self.cachedGenericSnapshot;
    if (cached.targetApplicationIsFrontmost
        && cached.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
        && cached.hasSuggestionAnchor) {
        return YES;
    }
    // Chromium can briefly lose AX focus while the candidate is visible. A
    // same-process usable anchor is sufficient to route Tab/Esc during this
    // narrow window; the accept path revalidates policy and frontmost state.
    pid_t currentPID = [self currentCodexProcessIdentifier];
    return [frontmostBundleIdentifier isEqualToString:@"com.openai.codex"]
        && self.lastUsableSnapshot != nil
        && self.lastUsableSnapshot.hasSuggestionAnchor
        && self.lastUsableSnapshotProcessIdentifier == currentPID;
}

- (BOOL)keyboardInterceptorShouldObserveCurrentInput {
    if (self.suggestionsPaused || self.currentPolicyDecision == nil) {
        return NO;
    }
    NSString *bundleIdentifier = self.cachedFrontmostBundleIdentifier ?: @"";
    if (self.currentPolicyBundleIdentifier.length == 0
        || ![self.currentPolicyBundleIdentifier isEqualToString:bundleIdentifier]) {
        return NO;
    }
    return CPASuggestionOutcomeAllowsInputObservation(
        self.currentPolicyDecision.outcome, YES);
}

- (void)invalidatePendingAcceptance {
    self.acceptanceGeneration++;
    self.acceptanceContext = nil;
    self.acceptancePending = NO;
    [self.acceptanceTimeoutTimer invalidate];
    self.acceptanceTimeoutTimer = nil;
}

- (NSTimeInterval)acceptanceMonotonicTime {
    return NSProcessInfo.processInfo.systemUptime;
}

- (void)acceptanceTimedOut:(NSTimer *)timer {
    if (timer != self.acceptanceTimeoutTimer) return;
    [self invalidatePendingAcceptance];
    CPADiagnosticLog(@"accept rejected=timeout");
}

- (void)requestAcceptanceSnapshotForBundleIdentifier:(NSString *)bundle
    processIdentifier:(pid_t)pid completion:(void (^)(CPAAccessibilitySnapshot *))completion {
    if ([bundle isEqualToString:@"com.openai.codex"]) {
        if (self.codexSnapshotBroker == nil) { completion(nil); return; }
        [self.codexSnapshotBroker requestFreshSnapshotForProcessIdentifier:pid completion:completion];
        return;
    }
    if (self.genericAccessibilityQueue == nil
        || ![self.policyCoordinator shouldProbeMetadataForBundleIdentifier:bundle]) {
        completion(nil); return;
    }
    CPAGenericAccessibilityService *reader = self.genericAccessibilityService;
    CPASafeInputContextCollector *collector = self.safeInputCollector;
    CPASuggestionPolicyCoordinator *coordinator = self.policyCoordinator;
    CPAAccessibilityService *pauseState = self.accessibilityService;
    dispatch_async(self.genericAccessibilityQueue, ^{
        NSUInteger version = coordinator.ruleVersion;
        CPAFocusedInputMetadata *metadata = pauseState.inputReadingPaused ? nil
            : [reader inspectFocusedInputMetadataForBundleIdentifier:bundle processIdentifier:pid];
        CPASafeInputContextCollection *collection = metadata != nil
            ? [collector collectContextForMetadata:metadata globallyPaused:pauseState.inputReadingPaused
                temporarilyPaused:NO] : nil;
        CPAGenericInputBody *body = [collection.inputBody isKindOfClass:CPAGenericInputBody.class]
            ? collection.inputBody : nil;
        CPAAccessibilitySnapshot *snapshot = nil;
        if (body != nil && collection.decision.outcome != CPASuggestionPolicyOutcomeDisabled
            && version == coordinator.ruleVersion && !pauseState.inputReadingPaused) {
            snapshot = [CPAAccessibilitySnapshot new];
            snapshot.targetBundleIdentifier = metadata.bundleIdentifier;
            snapshot.targetProcessIdentifier = metadata.processIdentifier;
            snapshot.targetFieldIdentity = metadata.fieldIdentity;
            snapshot.browserHost = metadata.browserHost;
            snapshot.documentContinuation = metadata.documentContinuation;
            snapshot.policyRuleVersion = version;
            snapshot.targetApplicationIsFrontmost = YES;
            snapshot.suggestionPolicyOutcome = collection.decision.outcome;
            snapshot.contextAccessMode = collection.decision.contextMode;
            snapshot.inputText = body.inputText;
            snapshot.workBuddyContext = body.workBuddyContext;
            snapshot.workBuddyContextReadPending = body.workBuddyContextReadPending;
            snapshot.hasValueCharacterCount = YES;
            snapshot.valueCharacterCount = body.inputText.length;
            snapshot.hasSelectedRange = body.hasSelectedRange;
            snapshot.selectedLocation = body.selectedLocation;
            snapshot.selectedLength = body.selectedLength;
            snapshot.writableTextInput = body.writableTextInput;
            snapshot.hasCaretBounds = body.hasCaretBounds;
            snapshot.caretBounds = body.caretBounds;
            snapshot.hasElementFrame = body.hasElementFrame;
            snapshot.elementFrame = body.elementFrame;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(snapshot); });
    });
}

- (void)requestIDVerifiedAcceptanceSnapshotForBundleIdentifier:(NSString *)bundle
    processIdentifier:(pid_t)pid completion:(void (^)(CPAAccessibilitySnapshot *))completion {
    if (self.codexIDResolver == nil || ![bundle isEqual:@"com.openai.codex"] || self.acceptanceContext == nil) {
        [self requestAcceptanceSnapshotForBundleIdentifier:bundle processIdentifier:pid completion:completion];
        return;
    }
    NSString *expectedID = self.codexIDIdentifier;
    NSUInteger ticket = self.acceptanceGeneration;
    __weak CPAAppDelegate *weakSelf = self;
    [self.codexIDResolver resolveProcessIdentifier:pid validate:^BOOL {
        CPAAppDelegate *owner = weakSelf;
        return owner != nil && owner.acceptancePending && ticket == owner.acceptanceGeneration
            && !owner.suggestionsPaused && owner.cachedFrontmostProcessIdentifier == pid;
    } completion:^(NSString *identifier, NSString *reason) {
        (void)reason;
        CPAAppDelegate *owner = weakSelf;
        if (owner == nil || !owner.acceptancePending || ticket != owner.acceptanceGeneration) return;
        if (expectedID.length == 0 || ![identifier isEqual:expectedID]) {
            [owner.contextProvider invalidateCachedContext]; completion(nil); return;
        }
        [owner requestAcceptanceSnapshotForBundleIdentifier:bundle processIdentifier:pid completion:completion];
    }];
}

- (void)keyboardInterceptorDidRequestAccept {
    if (self.acceptancePending) return;
    [self conversationContextDidChange];
    CPAConversationContextSnapshot *acceptedContext = self.displayedContext;
    NSString *signature = [self.displayedSuggestionSignature copy];
    NSString *bundle = [self.cachedFrontmostBundleIdentifier copy];
    pid_t pid = self.cachedFrontmostProcessIdentifier;
    if (self.suggestionsPaused || (self.remoteSettings.localPaused && self.remoteSettings.paused)
        || !self.overlayController.visible || signature.length == 0 || bundle.length == 0 || pid <= 0) {
        [self.overlayController hide];
        return;
    }
    [self cancelPendingSuggestionForReason:@"accept_validation"];
    NSString *insertion = [self.suggestionCoordinator consumeInsertionForSignature:signature];
    [self.overlayController hide];
    [self clearDisplayedSuggestionState];
    if (insertion.length == 0) return;
    self.programmaticInsertionExpectedInput = nil;
    self.acceptancePending = YES;
    self.acceptanceContext = acceptedContext;
    NSUInteger ticket = self.acceptanceGeneration;
    NSUInteger ruleVersion = self.policyCoordinator.ruleVersion;
    NSUInteger contextGeneration = self.conversationGeneration;
    NSTimeInterval deadline = [self acceptanceMonotonicTime] + 1.0;
    self.acceptanceTimeoutTimer = CPAScheduleOneShotTimer(1.0, self,
        @selector(acceptanceTimedOut:), nil);
    __weak CPAAppDelegate *weakSelf = self;
    [self requestIDVerifiedAcceptanceSnapshotForBundleIdentifier:bundle processIdentifier:pid
        completion:^(CPAAccessibilitySnapshot *snapshot) {
        CPAAppDelegate *owner = weakSelf;
        if (owner == nil || !owner.acceptancePending || ticket != owner.acceptanceGeneration) return;
        BOOL current = [owner contextIsCurrent:acceptedContext]
            && [owner acceptanceMonotonicTime] <= deadline
            && !owner.suggestionsPaused
            && !(owner.remoteSettings.localPaused && owner.remoteSettings.paused)
            && ruleVersion == owner.policyCoordinator.ruleVersion
            && contextGeneration == owner.conversationGeneration
            && pid == owner.cachedFrontmostProcessIdentifier
            && [bundle isEqualToString:owner.cachedFrontmostBundleIdentifier];
        if (current && [bundle isEqualToString:@"com.openai.codex"] && snapshot != nil) {
            snapshot = [owner decorateCodexSnapshot:snapshot];
        }
        BOOL matches = current && snapshot != nil
            && ![owner.keyboardInterceptor inputMethodCompositionProbablyActive]
            && snapshot.targetApplicationIsFrontmost && snapshot.targetProcessIdentifier == pid
            && [snapshot.targetBundleIdentifier isEqualToString:bundle]
            && snapshot.suggestionPolicyOutcome != CPASuggestionPolicyOutcomeDisabled
            && [signature isEqualToString:[owner signatureForSnapshot:snapshot]];
        [owner invalidatePendingAcceptance];
        if (!matches) { CPADiagnosticLog(@"accept rejected=fresh_snapshot"); return; }
        BOOL posted = [owner.keyboardInterceptor postText:insertion toProcessIdentifier:pid];
        if (!posted) { CPADiagnosticLog(@"accept rejected=delivery"); return; }
        NSUInteger location = (NSUInteger)snapshot.selectedLocation;
        NSUInteger selectedLength = (NSUInteger)snapshot.selectedLength;
        owner.programmaticInsertionExpectedInput = [snapshot.inputText stringByReplacingCharactersInRange:
            NSMakeRange(location, selectedLength) withString:insertion];
        CPADiagnosticLog(@"accept delivery=posted insertionLength=%lu expectedLength=%lu",
            (unsigned long)insertion.length,
            (unsigned long)owner.programmaticInsertionExpectedInput.length);
        owner.lastSuggestionAcceptedDate = NSDate.date;
    }];
}

- (void)keyboardInterceptorDidRequestDismiss {
    NSString *displayedSignature = self.displayedSuggestionSignature;
    NSString *displayedInputText = self.displayedSuggestionInputText;
    NSUInteger displayedGeneration = self.displayedSuggestionConversationGeneration;
    [self cancelPendingSuggestionForReason:@"dismissed"];
    [self.overlayController hide];
    [self.suggestionCoordinator clear];
    self.programmaticInsertionExpectedInput = nil;
    self.acceptedContinuationSignature = nil; self.acceptedContinuationInput = nil;
    [self clearDisplayedSuggestionState];
    if (CPADisplayedCandidateCanBeDismissed(
            displayedSignature ?: @"",
            displayedInputText ?: @"",
            displayedGeneration,
            self.conversationGeneration)) {
        self.dismissedSignature = displayedSignature;
        self.dismissedInputText = displayedInputText;
    }
}

- (NSImage *)assistantStatusImage {
    NSImage *image = [NSImage imageNamed:@"StatusIcon"];
    if (!image) {
        return [NSImage imageWithSystemSymbolName:@"text.cursor"
            accessibilityDescription:@"续言"];
    }
    image.size = NSMakeSize(18, 18);
    image.template = YES;
    image.accessibilityDescription = @"续言";
    return image;
}

- (void)updateSuggestionsPausedUI {
    if (self.dataController) [self updateDataMenuForSnapshot:self.dataController.currentSnapshot];
    NSString *menuTitle = self.suggestionsPaused ? @"继续提示" : @"暂停提示（本次运行）";
    self.suggestionPauseMenuItem.title = menuTitle;
    NSMenuItem *applicationRoot = [NSApp.mainMenu itemWithTitle:@"应用"];
    NSMenuItem *applicationPauseItem = [applicationRoot.submenu itemAtIndex:0];
    if (applicationPauseItem.action == @selector(toggleSuggestionsPaused:)) {
        applicationPauseItem.title = menuTitle;
    }
    self.statusItem.button.image = self.suggestionsPaused
        ? [NSImage imageWithSystemSymbolName:@"pause.circle"
            accessibilityDescription:@"续言已暂停"]
        : [self assistantStatusImage];
    if (self.suggestionsPaused) {
        self.statusMenuItem.title = @"提示：本次运行已暂停";
    }
}

- (void)pauseSuggestionsWithReason:(NSString *)reason {
    if (self.suggestionsPaused) {
        return;
    }
    self.suggestionsPaused = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(warmLocalModel) object:nil];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.focusRecoveryTimer invalidate];
    self.focusRecoveryTimer = nil;
    [self cancelLocalModelWarmupIfPending];
    [self cancelPendingSuggestionForReason:@"lifecycle_pause"];
    [self.suggestionCoordinator clear];
    [self.overlayController hide];
    [self clearDisplayedSuggestionState];
    [self.keyboardInterceptor stop];
    [self.contextProvider stop];
    if (self.dataController.currentSnapshot.state == CPADataFoundationStateScanning
        && !self.historyScanUserPaused) {
        self.historyScanPausedByAssistant = YES;
        [self.dataController requestPause];
    }
    [self updateSuggestionsPausedUI];
    CPADiagnosticLog(@"lifecycle state=paused reason=%@", reason);
}

- (void)resumeSuggestions {
    if (!self.suggestionsPaused) {
        return;
    }
    self.suggestionsPaused = NO;
    [self.contextProvider start];
    [self.keyboardInterceptor start];
    [self reconcileHistoryScanForSnapshot:self.dataController.currentSnapshot];
    if (self.pollTimer == nil) {
        self.pollTimer = CPAScheduleRepeatingTimer(CPASuggestionPollInterval,
            self, @selector(pollAccessibility:));
    }
    [self updateStatus];
    [self updateSuggestionsPausedUI];
    [self performSelector:@selector(warmLocalModel) withObject:nil afterDelay:0.2];
    CPADiagnosticLog(@"lifecycle state=running reason=user_resume");
}

- (void)toggleSuggestionsPaused:(id)sender {
    (void)sender;
    if (self.suggestionsPaused) {
        [self resumeSuggestions];
    } else {
        [self pauseSuggestionsWithReason:@"user_pause"];
    }
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.healthResponder stop];
    if (!self.suggestionsPaused) {
        [self pauseSuggestionsWithReason:@"termination"];
    }
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self.contextProvider stop];
    [self cancelLocalModelWarmupIfPending];
    [self.remoteClient cancelActiveRequest];
    [self.localModelClient cancelActiveRequest];
    // The resident model has an independent lifecycle. Closing/updating the
    // assistant must not boot out the model (or interrupt other local clients).
    CPADiagnosticLog(@"lifecycle state=terminated modelService=preserved");
    CPADiagnosticLogFlush();
}

@end

int main(int argc, const char *argv[]) {
    if (argc >= 2 && strcmp(argv[1], "--health-probe") == 0) {
        if (argc != 3) return 2;
        char *end = NULL;
        long pid = strtol(argv[2], &end, 10);
        if (!end || *end || pid <= 0 || pid > INT_MAX) return 2;
        @autoreleasepool { return CPARunHealthProbe((pid_t)pid); }
    }
    // Inspect this executable without constructing NSApplication or starting
    // services, scans, model warmup, event taps, or accessibility requests.
    if (argc == 2 && strcmp(argv[1], "--build-info") == 0) {
        puts(CPA_BUILD_METADATA_JSON);
        return 0;
    }
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        application.mainMenu = CPACreateApplicationMainMenu();
        CPAAppDelegate *delegate = [[CPAAppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return 0;
}
