static void FocusedIDModelRequestReplays(CPAConversationContextProvider *provider, NSString *a, NSString *b);
static void WriteIDContext(NSURL *file, NSString *identifier, NSString *text) {
    NSArray *records = @[@{@"type": @"session_meta", @"payload": @{@"id": identifier}},
        @{@"type": @"response_item", @"payload": @{@"type": @"message", @"role": @"user",
            @"content": @[@{@"type": @"input_text", @"text": text}]}}];
    NSMutableData *data = [NSMutableData data];
    for (NSDictionary *record in records) {
        [data appendData:[NSJSONSerialization dataWithJSONObject:record options:0 error:nil]];
        [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    Verify([data writeToURL:file atomically:YES], @"write synthetic ID context");
}
static void FocusedIDContextReplays(void) {
    NSString *a = @"00000000-0000-4000-8000-000000000001";
    NSString *b = @"00000000-0000-4000-8000-000000000002";
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"cpa-focused-id-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *fileA = [dir URLByAppendingPathComponent:@"a.jsonl"];
    NSURL *fileB = [dir URLByAppendingPathComponent:@"b.jsonl"];
    NSURL *dbURL = [dir URLByAppendingPathComponent:@"state.sqlite"];
    sqlite3 *db = NULL; sqlite3_open(dbURL.fileSystemRepresentation, &db);
    sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, name TEXT, title TEXT, archived INTEGER, recency_at_ms INTEGER)", NULL, NULL, NULL);
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?, ?, 'same', 'same', 0, 1)", -1, &stmt, NULL);
    for (NSArray *row in @[@[a, fileA.path], @[b, fileB.path]]) {
        sqlite3_reset(stmt); sqlite3_bind_text(stmt, 1, [row[0] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [row[1] UTF8String], -1, SQLITE_TRANSIENT);
        Verify(sqlite3_step(stmt) == SQLITE_DONE, @"insert ID fixture");
    }
    sqlite3_finalize(stmt); sqlite3_close(db);
    CPAConversationContextProvider *provider = [[CPAConversationContextProvider alloc]
        initWithSessionsDirectoryURL:[dir URLByAppendingPathComponent:@"sessions"] stateDatabaseURL:dbURL];
    [provider selectConversationWithIdentifier:a]; Refresh(provider);
    Verify(provider.currentSnapshot.messages.count == 0, @"missing initial file supplies no context");
    WriteIDContext(fileA, a, @"只使用合成对象 A"); Refresh(provider);
    Verify([provider.currentSnapshot.messages.firstObject[@"content"] isEqual:@"只使用合成对象 A"],
        @"initial lookup failure recovers without another explicit selection");
    WriteIDContext(fileB, b, @"只使用合成对象 B");
    [provider selectConversationWithIdentifier:a]; [provider selectConversationWithIdentifier:b];
    Verify(provider.currentSnapshot.messages.count == 0, @"ID switch clears old messages immediately");
    Refresh(provider);
    Verify([provider.currentSnapshot.messages.firstObject[@"content"] isEqual:@"只使用合成对象 B"],
        @"same-title tasks resolve by UUID and late A cannot publish");
    NSUInteger revision = provider.currentSnapshot.revision; Refresh(provider);
    Verify(provider.currentSnapshot.revision == revision, @"unchanged material keeps stable revision");
    WriteIDContext(fileB, a, @"错误归属的合成内容"); Refresh(provider);
    Verify(provider.currentSnapshot.availability == CPAContextAvailabilityError
        && provider.currentSnapshot.messages.count == 0, @"wrong session header is rejected");
    WriteIDContext(fileB, b, @"恢复后的合成对象 B"); Refresh(provider);
    Verify(provider.currentSnapshot.messages.count == 1, @"correct header recovers on refresh");
    [provider selectConversationWithIdentifier:@"same"]; Refresh(provider);
    Verify(provider.currentSnapshot.availability == CPAContextAvailabilityMissing
        && provider.currentSnapshot.messages.count == 0, @"invalid ID never falls back to title");
    [provider selectConversationWithTitle:@"same"]; Refresh(provider);
    Verify(provider.currentSnapshot.availability == CPAContextAvailabilityAmbiguous, @"legacy title ambiguity remains");
    [provider selectConversationWithIdentifier:b]; [provider invalidateCachedContext]; Refresh(provider);
    Verify(provider.currentSnapshot.messages.count == 0, @"invalidation defeats queued ID read");
    FocusedIDModelRequestReplays(provider, a, b);
    [provider stop]; [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
}

@interface CPAIDFixtureIO : NSObject <CPAThreadIDIO>
@property(nonatomic) NSInteger revision;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) BOOL focusMatches;
@property(nonatomic) NSTimeInterval now;
@property(nonatomic) NSUInteger restores;
@property(nonatomic) NSUInteger sends;
@property(nonatomic) BOOL contestCapture;
@property(nonatomic) BOOL contestRestore;
@end
@implementation CPAIDFixtureIO
- (id)capture { if (self.contestCapture) self.revision++; return self.text; }
- (BOOL)sendCopy { self.sends++; return YES; }
- (BOOL)restore:(id)saved expectedRevision:(NSInteger)revision {
    if (self.contestRestore) { self.revision++; self.text = @"new synthetic copy"; }
    if (self.revision != revision) return NO;
    self.restores++; self.revision++; self.text = saved; return YES;
}
@end
@interface CPACodexThreadIDResolver (IDEventTests)
- (CGEventRef)handleType:(CGEventType)type event:(CGEventRef)event;
@end
static void FocusedIDTransactionReplays(void) {
    NSString *link = @"codex://threads/00000000-0000-4000-8000-000000000001";
    Verify(CPAThreadIDFromLink(link) != nil, @"valid local ID link");
    for (NSString *bad in @[@"https://threads/00000000-0000-4000-8000-000000000001",
        @"codex://user@threads/00000000-0000-4000-8000-000000000001",
        [link stringByAppendingString:@"?x=1"], [link stringByAppendingString:@"/extra"], @"codex://threads/not-an-id"])
        Verify(CPAThreadIDFromLink(bad) == nil, @"reject non-exact links");
    for (NSUInteger mode = 0; mode < 8; mode++) {
        CPAIDFixtureIO *io = [CPAIDFixtureIO new]; io.text = @"original synthetic copy";
        io.revision = 20; io.focusMatches = YES;
        io.contestCapture = mode == 4; io.contestRestore = mode == 5;
        CPAThreadIDTransaction *tx = [[CPAThreadIDTransaction alloc] initWithIO:io];
        __block NSString *identifier = nil; __block NSString *reason = nil;
        tx.completion = ^(NSString *value, NSString *why) { identifier = value; reason = why; };
        [tx start];
        if (mode == 4) { Verify(io.sends == 0 && !tx.pending, @"capture contention sends no command"); continue; }
        if (mode == 1) [tx cancel];
        if (mode == 2) io.focusMatches = NO;
        if (mode == 7) { io.now = 1; [tx poll];
            Verify(!tx.pending && identifier == nil && io.restores == 0, @"timeout never accepts preexisting clipboard"); continue; }
        io.revision++; io.text = link;
        if (mode == 3) { io.revision++; io.text = @"new synthetic copy"; }
        if (mode == 6) io.text = @"other clipboard owner";
        [tx poll];
        Verify(!tx.pending && reason != nil, @"copy transaction always settles");
        Verify((identifier != nil) == (mode == 0), @"only current uncontended ID publishes");
        if (mode <= 2) Verify([io.text isEqual:@"original synthetic copy"] && io.restores == 1,
            @"success and cancellation restore only owned response");
        if (mode == 3 || mode == 5) Verify([io.text isEqual:@"new synthetic copy"] && io.restores == 0,
            @"newer external copy is never overwritten");
        if (mode == 6) Verify(io.restores == 0, @"unrelated single clipboard change is preserved");
    }
    CPAIDFixtureIO *io = [CPAIDFixtureIO new]; io.text = @"original"; io.focusMatches = YES;
    CPAThreadIDTransaction *tx = [[CPAThreadIDTransaction alloc] initWithIO:io]; [tx start];
    CPACodexThreadIDResolver *resolver = [CPACodexThreadIDResolver new];
    [resolver setValue:tx forKey:@"transaction"];
    [resolver setValue:[NSMutableArray array] forKey:@"deferredEvents"];
    [resolver setValue:[NSMutableSet set] forKey:@"deferredKeys"];
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, 9, true);
    CGEventSetFlags(event, kCGEventFlagMaskCommand);
    Verify([resolver handleType:kCGEventKeyDown event:event] == NULL && tx.cancelled,
        @"paste is deferred before transient link can reach the editor");
    CGEventSetType(event, kCGEventKeyUp);
    Verify([resolver handleType:kCGEventKeyUp event:event] == NULL, @"paste key-up stays paired");
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, CPAThreadIDCopyEventTag);
    CGEventSetType(event, kCGEventKeyDown);
    Verify([resolver handleType:kCGEventKeyDown event:event] == NULL, @"cancelled queued copy command is suppressed");
    Verify([[resolver valueForKey:@"copyDownObserved"] boolValue]
        && [[resolver valueForKey:@"copyDownBlocked"] boolValue], @"cancelled delivery is recorded distinctly");
    CFRelease(event);
    CPAIDFixtureIO *freshIO = [CPAIDFixtureIO new]; freshIO.text = @"synthetic"; freshIO.focusMatches = YES;
    CPAThreadIDTransaction *freshTx = [[CPAThreadIDTransaction alloc] initWithIO:freshIO]; [freshTx start];
    CPACodexThreadIDResolver *freshResolver = [CPACodexThreadIDResolver new];
    [freshResolver setValue:freshTx forKey:@"transaction"];
    CGEventRef copyEvent = CGEventCreateKeyboardEvent(NULL, 37, true);
    CGEventSetIntegerValueField(copyEvent, kCGEventSourceUserData, CPAThreadIDCopyEventTag);
    Verify([freshResolver handleType:kCGEventKeyDown event:copyEvent] == copyEvent
        && !freshTx.cancelled, @"current tagged command passes without cancelling itself");
    Verify([[freshResolver valueForKey:@"copyDownObserved"] boolValue]
        && ![[freshResolver valueForKey:@"copyDownBlocked"] boolValue], @"observed delivery differs from blocked delivery");
    CFRelease(copyEvent);
}

@interface CPAIDFixtureResolver : CPACodexThreadIDResolver
@property(nonatomic, copy) void (^done)(NSString *, NSString *);
@property(nonatomic) NSUInteger calls;
@end
@implementation CPAIDFixtureResolver
- (void)resolveProcessIdentifier:(pid_t)pid validate:(BOOL (^)(void))validate
    completion:(void (^)(NSString *, NSString *))completion {
    (void)pid; Verify(validate(), @"ID gate validates before native request"); self.calls++; self.done = completion;
}
- (void)cancel {}
@end
@interface CPAIDGateDelegate : CPALifecycleDelegate
@property(nonatomic) NSUInteger scheduled;
@end
@implementation CPAIDGateDelegate
- (void)scheduleModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature delay:(NSTimeInterval)delay {
    (void)snapshot; (void)signature; (void)delay; self.scheduled++;
}
@end
static void FocusedIDGateReplays(void) {
    for (NSUInteger mode = 0; mode < 9; mode++) {
        CPALifecycleDelegate *base = Delegate(); CPAIDGateDelegate *app = [CPAIDGateDelegate new];
        app.fixture = base.fixture; app.fixture.targetBundleIdentifier = @"com.openai.codex";
        app.fixture.contextAccessMode = CPAContextAccessModeCodexConversation;
    app.fixture.conversationSelectionIdentity = @"selected-node-A";
        app.cachedFrontmostBundleIdentifier = @"com.openai.codex"; app.cachedFrontmostProcessIdentifier = 42;
        app.keyboardInterceptor = base.keyboardInterceptor;
        app.suggestionCoordinator = base.suggestionCoordinator;
        CPAIDFixtureResolver *resolver = [CPAIDFixtureResolver new]; app.codexIDResolver = resolver;
        NSString *signature = [app signatureForSnapshot:app.fixture];
        Verify(![app ensureCodexIDForSnapshot:app.fixture signature:signature] && resolver.calls == 1,
            @"model waits for current ID before dispatch");
        if (mode == 1) app.codexIDGeneration++;
        resolver.done(@"00000000-0000-4000-8000-000000000001", @"ready");
        if (mode == 1) { Verify(app.freshCompletion == nil && app.codexIDIdentifier == nil,
            @"late ID after cancellation cannot bind"); continue; }
        if (mode == 2) app.fixture.inputText = @"different synthetic draft";
        if (mode == 3) app.fixture.conversationSelectionIdentity = @"other selected task";
        if (mode == 4) app.fixture.targetFieldIdentity = @"other-window-field";
        if (mode == 5) app.fixture.targetProcessIdentifier = 43;
        if (mode == 6) app.fixture.contextAccessMode = CPAContextAccessModeCurrentInputOnly;
        if (mode == 7) app.fixture.conversationSelectionIdentity = nil;
        if (mode == 8) app.fixture.targetApplicationIsFrontmost = NO;
        app.freshCompletion(app.fixture);
        Verify((app.codexIDIdentifier != nil) == (mode == 0),
            ([NSString stringWithFormat:@"fresh snapshot rejects changed boundary mode=%lu", (unsigned long)mode]));
        if (mode == 0) {
            Verify(app.scheduled == 1 && [app ensureCodexIDForSnapshot:app.fixture signature:signature]
                && resolver.calls == 1, @"same draft reuses verified ID without polling clipboard");
            [app keyboardInterceptorDidObserveInputEvent];
            Verify(app.codexIDIdentifier != nil, @"actual input event retains the verified task binding");
            [app cancelPendingSuggestionForReason:@"input_changed"];
            app.fixture.inputText = @"synthetic draft extended";
            app.fixture.valueCharacterCount = app.fixture.inputText.length;
            app.fixture.selectedLocation = app.fixture.inputText.length;
            NSString *editedSignature = [app signatureForSnapshot:app.fixture];
            Verify([app ensureCodexIDForSnapshot:app.fixture signature:editedSignature] && resolver.calls == 1,
                @"typing in the same selected task reuses ID; no copy shortcut");
            Verify(app.codexIDIdentifier != nil, @"input cancellation preserves task binding");
            for (NSUInteger edit=0; edit<20; edit++) {
                [app keyboardInterceptorDidObserveInputEvent];
                [app cancelPendingSuggestionForReason:@"input_changed"];
                app.fixture.inputText = [NSString stringWithFormat:@"synthetic draft revision %lu",(unsigned long)edit];
                app.fixture.valueCharacterCount = app.fixture.inputText.length;
                app.fixture.selectedLocation = app.fixture.inputText.length;
                Verify([app ensureCodexIDForSnapshot:app.fixture signature:[app signatureForSnapshot:app.fixture]]
                    && resolver.calls == 1, @"twenty consecutive edits send no extra copy shortcut");
            }
            editedSignature = [app signatureForSnapshot:app.fixture];

            app.acceptancePending = YES;
            app.acceptanceContext = [[CPAConversationContextSnapshot alloc] initWithSelectionGeneration:1 revision:1
                availability:CPAContextAvailabilityReady messages:@[] sourceURL:nil
                truncatedMessageIndexes:NSIndexSet.indexSet tailTruncated:NO];
            __block BOOL rejected = NO;
            [app requestIDVerifiedAcceptanceSnapshotForBundleIdentifier:@"com.openai.codex" processIdentifier:42
                completion:^(CPAAccessibilitySnapshot *snapshot) { rejected = snapshot == nil; }];
            resolver.done(@"00000000-0000-4000-8000-000000000002", @"ready");
            Verify(rejected, @"Tab rejects a different ID even if the AX field was reused");
            app.acceptancePending = NO;
            NSUInteger beforeNavigation = app.conversationGeneration;
            [app keyboardInterceptorDidObservePossibleTaskNavigation];
            Verify(app.codexIDIdentifier == nil && app.conversationGeneration > beforeNavigation,
                @"navigation clears binding even if renderer reuses every metadata field");
            app.fixture.conversationSelectionIdentity = @"selected-node-B-same-title";
            NSString *switchedSignature = [app signatureForSnapshot:app.fixture];
            Verify(![switchedSignature isEqual:editedSignature], @"same-title row switch changes candidate signature");
            Verify(![app ensureCodexIDForSnapshot:app.fixture signature:switchedSignature] && resolver.calls == 3
                && app.codexIDIdentifier == nil, @"selected row switch must reacquire; no stale ID");
            app.fixture.conversationSelectionIdentity = nil;
            Verify([app ensureCodexIDForSnapshot:app.fixture signature:[app signatureForSnapshot:app.fixture]]
                && app.codexIDIdentifier == nil && resolver.calls == 3,
                @"unknown selection clears history without sending shortcut per keystroke");

        }
    }
}

// One long-lived delegate and provider: verified IDs must reach both model
// request boundaries without retaining the prior task's material.
static void FocusedIDModelRequestReplays(CPAConversationContextProvider *provider, NSString *a, NSString *b) {
    CPALifecycleDelegate *base = Delegate();
    CPAIDGateDelegate *app = [CPAIDGateDelegate new];
    app.fixture = base.fixture; app.suggestionCoordinator = base.suggestionCoordinator;
    app.keyboardInterceptor = base.keyboardInterceptor; app.overlayController = base.overlayController;
    app.localModelClient = base.localModelClient; app.remoteClient = base.remoteClient;
    app.fixture.targetBundleIdentifier = @"com.openai.codex";
    app.fixture.contextAccessMode = CPAContextAccessModeCodexConversation;
    app.fixture.conversationSelectionIdentity = @"selected-node-A";
    app.cachedFrontmostBundleIdentifier = @"com.openai.codex"; app.cachedFrontmostProcessIdentifier = 42;
    app.lastObservedInputText = app.fixture.inputText;
    app.contextProvider = provider; app.cachedAPIKey = @"synthetic-key";
    CPAIDFixtureResolver *resolver = [CPAIDFixtureResolver new]; app.codexIDResolver = resolver;
    CPALifecycleClient *local = (id)app.localModelClient, *remote = (id)app.remoteClient;
    CPARemoteCompletionHandler lateLocal = nil, lateRemote = nil;
    NSMutableArray *switches = [NSMutableArray array];
    for (NSUInteger cycle = 0; cycle < 16; cycle++) [switches addObjectsFromArray:@[a, b, a, NSNull.null]];
    for (id target in switches) {
        [app cancelPendingSuggestionForReason:@"conversation_boundary"];
        local.sentMessages = nil; remote.sentMessages = nil;
        NSString *signature = [app signatureForSnapshot:app.fixture];
        Verify(![app ensureCodexIDForSnapshot:app.fixture signature:signature], @"request waits for fresh ID binding");
        Verify(local.sentMessages == nil && remote.sentMessages == nil, @"no model receives history before ID completes");
        BOOL hasID = target != NSNull.null;
        resolver.done(hasID ? target : nil, hasID ? @"ready" : @"copy_dispatch_unobserved");
        app.freshCompletion(app.fixture);
        Refresh(provider);
        NSArray *expected = hasID ? provider.currentSnapshot.messages : @[];
        Verify(!hasID || expected.count == 1, @"ID source contains exactly its synthetic message");
        [app startLocalModelSuggestionForSnapshot:app.fixture signature:signature];
        [app startRemoteSuggestionForSnapshot:app.fixture signature:signature];
        Verify([local.sentMessages isEqual:expected], @"local request carries only verified current material");
        Verify([remote.sentMessages isEqual:expected], @"remote request carries only verified current material");
        CPARemoteCompletionProtocol *protocol = [CPARemoteCompletionProtocol new];
        for (NSNumber *prefix in @[@YES, @NO]) {
            NSArray *material = prefix.boolValue ? local.sentMessages : remote.sentMessages;
            CPARemoteCompletionRequest *request = [protocol requestForInput:app.fixture.inputText
                contextMessages:material model:prefix.boolValue ? CPALocalModelName : @"fixture"
                qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
            NSDictionary *body = request.bodyData ? [NSJSONSerialization JSONObjectWithData:request.bodyData options:0 error:nil] : nil;
            NSString *prompt = [body[@"prompt"] isKindOfClass:NSString.class] ? body[@"prompt"] : body[@"messages"][0][@"content"];
            Verify(prompt != nil, @"both final request formats serialize successfully");
            if (hasID) {
                Verify([prompt containsString:expected.firstObject[@"content"]], @"serialized model request contains the selected body");
                NSString *other = [target isEqual:a] ? @"恢复后的合成对象 B" : @"只使用合成对象 A";
                Verify(![prompt containsString:other], @"serialized model request excludes the previous task body");
            } else {
                Verify([prompt rangeOfString:@"<conversation_context untrusted_reference="].location == NSNotFound,
                    @"failed ID does not serialize stale conversation material");
            }
        }
        if (lateLocal) lateLocal(Result(@"将找不到来源的条目保留为待确认。"));
        if (lateRemote) lateRemote(Result(@"将找不到来源的条目保留为待确认。"));
        Verify(!app.overlayController.visible, @"prior-task replies cannot display after a new ID binding");
        lateLocal = local.finish; lateRemote = remote.finish;
    }
    [app cancelPendingSuggestionForReason:@"test_end"];
}
