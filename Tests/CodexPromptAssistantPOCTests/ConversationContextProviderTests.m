#import <Foundation/Foundation.h>
#import <sqlite3.h>

#import "../../Sources/CodexPromptAssistantPOC/ConversationContextProvider.h"

@interface CPAConversationContextProvider (TestReader)
- (NSArray *)readRecentMessagesFromURL:(NSURL *)url;
@end

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void WriteConversation(NSURL *file, NSString *threadID,
    NSString *userText, NSString *assistantText) {
    NSArray *records = @[
        @{ @"type": @"session_meta", @"payload": @{
            @"id": threadID, @"thread_source": @"user",
        } },
        @{ @"type": @"response_item", @"payload": @{
            @"type": @"message", @"role": @"user",
            @"content": @[ @{ @"type": @"input_text", @"text": userText } ],
        } },
        @{ @"type": @"response_item", @"payload": @{
            @"type": @"message", @"role": @"assistant",
            @"content": @[ @{ @"type": @"output_text", @"text": assistantText } ],
        } },
    ];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0, count = records.count; i < count; i++) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:records[i]
            options:0 error:nil];
        [lines addObject:[[NSString alloc] initWithData:data
            encoding:NSUTF8StringEncoding]];
    }
    NSError *writeError = nil;
    Assert([[lines componentsJoinedByString:@"\n"] writeToURL:file atomically:YES
        encoding:NSUTF8StringEncoding error:&writeError] && writeError == nil,
        @"conversation fixture should be written");
}

static void CreateStateDatabase(NSURL *databaseURL, NSURL *olderFile,
    NSURL *newerFile) {
    sqlite3 *database = NULL;
    Assert(sqlite3_open(databaseURL.fileSystemRepresentation, &database) == SQLITE_OK,
        @"state fixture should open");
    const char *schema = "CREATE TABLE threads ("
        "id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, name TEXT, title TEXT, "
        "archived INTEGER NOT NULL, recency_at_ms INTEGER NOT NULL);";
    Assert(sqlite3_exec(database, schema, NULL, NULL, NULL) == SQLITE_OK,
        @"state fixture schema should be created");
    sqlite3_stmt *statement = NULL;
    const char *insert = "INSERT INTO threads "
        "(id, rollout_path, title, archived, recency_at_ms) VALUES (?, ?, ?, 0, ?);";
    Assert(sqlite3_prepare_v2(database, insert, -1, &statement, NULL) == SQLITE_OK,
        @"state fixture insert should prepare");
    NSArray<NSArray<NSString *> *> *rows = @[
        @[ @"thread-a", olderFile.path, @"这是对话 A 的完整首条消息，不是侧边栏短标题", @"100" ],
        @[ @"thread-b", newerFile.path, @"这是对话 B 的完整首条消息，不是侧边栏短标题", @"200" ],
    ];
    for (NSUInteger rowIndex = 0, rowCount = rows.count;
        rowIndex < rowCount; rowIndex++) {
        NSArray<NSString *> *row = rows[rowIndex];
        sqlite3_reset(statement);
        for (NSUInteger column = 0; column < 3; column++) {
            sqlite3_bind_text(statement, (int)column + 1,
                row[column].UTF8String, -1, SQLITE_TRANSIENT);
        }
        sqlite3_bind_int64(statement, 4, row[3].longLongValue);
        Assert(sqlite3_step(statement) == SQLITE_DONE,
            @"state fixture row should insert");
    }
    sqlite3_finalize(statement);
    Assert(sqlite3_exec(database,
        "UPDATE threads SET archived = 1 WHERE id = 'thread-a';",
        NULL, NULL, NULL) == SQLITE_OK,
        @"selected archived thread fixture should be updated");
    sqlite3_close(database);
}

static void WriteSessionIndex(NSURL *fileURL, NSArray<NSDictionary *> *entries) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
        [lines addObject:[[NSString alloc] initWithData:data
            encoding:NSUTF8StringEncoding]];
    }
    Assert([[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]
        writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:nil],
        @"session index fixture should be written");
}

int main(void) {
    @autoreleasepool {
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:
                @"context-test-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *olderFile = [directory URLByAppendingPathComponent:@"older.jsonl"];
        NSURL *newerFile = [directory URLByAppendingPathComponent:@"newer.jsonl"];
        WriteConversation(olderFile, @"thread-a", @"A 的用户目标", @"A 的当前方案");
        WriteConversation(newerFile, @"thread-b", @"B 的用户目标", @"B 的当前方案");
        NSURL *stateDatabase = [directory URLByAppendingPathComponent:@"state.sqlite"];
        CreateStateDatabase(stateDatabase, olderFile, newerFile);
        NSURL *sessionIndex = [directory URLByAppendingPathComponent:
            @"session_index.jsonl"];
        WriteSessionIndex(sessionIndex, @[
            @{ @"id": @"thread-a", @"thread_name": @"对话 A 的旧名称" },
            @{ @"id": @"thread-a", @"thread_name": @"对话 A" },
            @{ @"id": @"thread-b", @"thread_name": @"对话 B" },
        ]);

        CPAConversationContextProvider *provider = [[CPAConversationContextProvider alloc]
            initWithSessionsDirectoryURL:directory stateDatabaseURL:stateDatabase];
        [provider start];
        [provider selectConversationWithTitle:@"对话 A"];
        NSUInteger firstGeneration = provider.contextGeneration;
        Assert(provider.contextState == CPAConversationContextStateLoading,
            @"a newly selected conversation must expose loading instead of ambiguous empty context");
        Assert(firstGeneration > 0, @"conversation selection must advance its generation");
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
        NSArray *messages = @[];
        while (messages.count == 0 && [deadline timeIntervalSinceNow] > 0) {
            messages = provider.cachedContextMessages;
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        Assert(messages.count == 2, @"only visible user and assistant turns should be cached");
        Assert([messages[0][@"role"] isEqualToString:@"user"]
            && [messages[1][@"role"] isEqualToString:@"assistant"],
            @"context turns should keep their roles");
        Assert([messages[0][@"content"] isEqualToString:@"A 的用户目标"],
            @"the selected conversation must win over the globally newest session");
        Assert(provider.contextState == CPAConversationContextStateReady,
            @"a loaded conversation must become ready even when callers read asynchronously");

        [provider selectConversationWithTitle:@"不存在的对话"];
        Assert(provider.contextGeneration != firstGeneration
                && provider.contextState == CPAConversationContextStateLoading,
            @"switching conversations must advance generation before background resolution");
        Assert(provider.cachedContextMessages.count == 0,
            @"switching conversations must clear the previous snapshot immediately");
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
        Assert(provider.cachedContextMessages.count == 0,
            @"an unresolved conversation must never refill from the newest other chat");
        Assert(provider.contextState == CPAConversationContextStateReady,
            @"an unresolved title must settle as an explicit empty context");

        [provider selectConversationWithTitle:@"对话 A 的旧名称"];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        Assert(provider.cachedContextMessages.count == 0,
            @"a superseded session-index name must not resolve after a rename");

        WriteSessionIndex(sessionIndex, @[
            @{ @"id": @"thread-a", @"thread_name": @"重复标题" },
            @{ @"id": @"thread-b", @"thread_name": @"重复标题" },
        ]);
        [provider selectConversationWithTitle:@"重复标题"];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        Assert(provider.cachedContextMessages.count == 2
            && [provider.cachedContextMessages[0][@"content"] isEqualToString:@"B 的用户目标"],
            @"an archived namesake must not hide the unique active conversation");
        sqlite3 *duplicatesDB = NULL;
        sqlite3_open(stateDatabase.fileSystemRepresentation, &duplicatesDB);
        sqlite3_exec(duplicatesDB, "UPDATE threads SET archived = 0", NULL, NULL, NULL);
        sqlite3_close(duplicatesDB);
        [provider selectConversationWithTitle:@"重复标题"];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        Assert(provider.cachedContextMessages.count == 0,
            @"multiple active namesakes must remain ambiguous");
        WriteSessionIndex(sessionIndex, @[
            @{ @"id": @"thread-a", @"thread_name": @"对话 A" },
            @{ @"id": @"thread-b", @"thread_name": @"对话 B" },
        ]);

        [provider selectConversationWithTitle:@"对话 B"];
        deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
        messages = @[];
        while (messages.count == 0 && [deadline timeIntervalSinceNow] > 0) {
            messages = provider.cachedContextMessages;
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        Assert([messages[0][@"content"] isEqualToString:@"B 的用户目标"],
            @"the new conversation should load only its own context");

        [provider selectConversationWithTitle:@"对话 A"];
        [provider selectConversationWithTitle:@"对话 B"];
        deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
        messages = @[];
        while (messages.count == 0 && [deadline timeIntervalSinceNow] > 0) {
            messages = provider.cachedContextMessages;
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        Assert(messages.count == 2
                && [messages[0][@"content"] isEqualToString:@"B 的用户目标"],
            @"a superseded asynchronous selection must never republish the previous chat");

        [provider invalidateCachedContext];
        Assert(provider.cachedContextMessages.count == 0,
            @"a chat switch must immediately drop the previous context snapshot");
        Assert(provider.contextState == CPAConversationContextStateEmpty,
            @"invalidating context must expose the empty state");
        [provider stop];

        NSURL *qualityFile = [directory URLByAppendingPathComponent:@"quality.jsonl"];
        NSMutableString *fixture = [NSMutableString string];
        for (NSUInteger i = 0; i < 12; i++) {
            for (NSString *role in @[@"user", @"assistant"]) {
                NSString *body = [NSString stringWithFormat:@"%@_%lu_目标", role, (unsigned long)i];
                if ([role isEqualToString:@"user"]) body = [[body stringByPaddingToLength:1800
                    withString:@"内容" startingAtIndex:0] stringByAppendingString:@"禁止重启Codex"];
                NSDictionary *record = @{@"type": @"response_item", @"payload": @{
                    @"type": @"message", @"role": role, @"channel": @"final",
                    @"content": @[@{@"type": @"input_text", @"text": body}]}};
                [fixture appendFormat:@"%@\n", [[NSString alloc] initWithData:
                    [NSJSONSerialization dataWithJSONObject:record options:0 error:nil] encoding:NSUTF8StringEncoding]];
            }
        }
        for (NSString *channel in @[@"analysis", @"commentary", @"phase-commentary"]) {
            NSDictionary *record = @{@"type": @"response_item", @"payload": @{
                @"type": @"message", @"role": @"assistant", ([channel hasPrefix:@"phase-"] ? @"phase" : @"channel"): ([channel hasPrefix:@"phase-"] ? @"commentary" : channel),
                @"content": @[@{@"type": @"output_text", @"text": @"不应带入的中间过程"}]}};
            [fixture appendFormat:@"%@\n", [[NSString alloc] initWithData:
                [NSJSONSerialization dataWithJSONObject:record options:0 error:nil] encoding:NSUTF8StringEncoding]];
        }
        [fixture writeToURL:qualityFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSArray *quality = [provider readRecentMessagesFromURL:qualityFile];
        NSUInteger users = 0, assistants = 0, chars = 0;
        for (NSDictionary *message in quality) {
            NSString *body = message[@"content"]; chars += body.length;
            Assert(![body containsString:@"不应带入"], @"intermediate assistant channels must not crowd out requirements");
            if ([message[@"role"] isEqualToString:@"user"]) {
                users++;
                Assert([body containsString:@"目标"] && [body hasSuffix:@"禁止重启Codex"],
                    @"long user messages must retain both opening intent and final constraints");
            } else assistants++;
        }
        Assert(users == 6 && assistants == 2 && chars <= 3000,
            @"bounded history must reserve space for six user requirements and two final replies");
        Assert([quality[0][@"content"] hasPrefix:@"user_6_"], @"retain the newest user requirements in chronological order");
        // Force the 8 MiB byte cut to land inside a multibyte Chinese character.
        NSMutableData *tail = [NSMutableData dataWithLength:8 * 1024 * 1024 + 1];
        uint8_t *bytes = tail.mutableBytes; memset(bytes, 'x', tail.length);
        NSData *last = [fixture dataUsingEncoding:NSUTF8StringEncoding];
        [tail replaceBytesInRange:NSMakeRange(tail.length-last.length, last.length) withBytes:last.bytes];
        bytes = tail.mutableBytes; bytes[0]=0xe4; bytes[1]=0xb8; bytes[2]=0xad; bytes[3]='\n';
        [tail writeToURL:qualityFile atomically:YES];
        Assert([provider readRecentMessagesFromURL:qualityFile].count == 8,
            @"a partial UTF-8 line at the byte boundary must not discard all recent context");
        [[NSFileManager defaultManager] removeItemAtURL:directory error:nil];
        NSLog(@"PASS: ConversationContextProviderTests");
    }
    return 0;
}
