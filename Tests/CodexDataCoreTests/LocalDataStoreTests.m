#import <Foundation/Foundation.h>

#import <sqlite3.h>

#import "../../Sources/CodexDataCore/CodexMessage.h"
#import "../../Sources/CodexDataCore/CodexSourceMetadata.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"
#import "../../Sources/CodexDataCore/LocalExpressionRecord.h"
#import "../../Sources/CodexDataCore/LocalUserMessageRecord.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSData *SyntheticMasterKey(void) {
    NSMutableData *data = [NSMutableData dataWithLength:64];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        bytes[i] = (uint8_t)(i + 7);
    }
    return data;
}

static CPACodexMessage *Message(NSString *messageID, CPACodexMessageRole role,
    NSString *text, NSUInteger lineNumber) {
    return [[CPACodexMessage alloc] initWithMessageID:messageID
        timestamp:@"2026-08-20T00:00:00Z"
        role:role
        text:text
        sourceLineNumber:lineNumber
        sourceByteOffset:lineNumber * 100];
}

static BOOL FileContainsData(NSURL *url, NSData *needle) {
    NSData *haystack = [NSData dataWithContentsOfURL:url];
    if (haystack == nil) {
        return NO;
    }
    return [haystack rangeOfData:needle options:0
        range:NSMakeRange(0, haystack.length)].location != NSNotFound;
}

static BOOL DatabaseHasColumn(NSURL *databaseURL, NSString *table, NSString *column) {
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(databaseURL.fileSystemRepresentation, &database,
            SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (database != NULL) {
            sqlite3_close_v2(database);
        }
        return NO;
    }
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", table];
    sqlite3_stmt *statement = NULL;
    BOOL found = NO;
    if (sqlite3_prepare_v2(database, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            const char *name = (const char *)sqlite3_column_text(statement, 1);
            if (name != NULL && [column isEqualToString:
                    [NSString stringWithUTF8String:name]]) {
                found = YES;
                break;
            }
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close_v2(database);
    return found;
}

static BOOL DatabaseHasTable(NSURL *databaseURL, NSString *table) {
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(databaseURL.fileSystemRepresentation, &database,
            SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (database != NULL) {
            sqlite3_close_v2(database);
        }
        return NO;
    }
    sqlite3_stmt *statement = NULL;
    BOOL found = sqlite3_prepare_v2(database,
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1,
        &statement, NULL) == SQLITE_OK;
    if (found) {
        sqlite3_bind_text(statement, 1, table.UTF8String, -1, SQLITE_TRANSIENT);
        found = sqlite3_step(statement) == SQLITE_ROW;
    }
    sqlite3_finalize(statement);
    sqlite3_close_v2(database);
    return found;
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
            isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:base withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建临时数据库目录");
        NSURL *databaseURL = [base URLByAppendingPathComponent:@"history.sqlite3"];

        CPALocalDataStore *invalidStore = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:[NSMutableData dataWithLength:8] error:&error];
        Assert(invalidStore == nil && error != nil, @"错误长度主密钥必须拒绝打开数据库");

        error = nil;
        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"合法主密钥应打开数据库");

        NSString *syntheticSecret = [@"sk" stringByAppendingString:
            @"-demo_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"];
        NSString *syntheticEmail = @"person@example.com";
        CPACodexSourceMetadata *metadata = [[CPACodexSourceMetadata alloc]
            initWithThreadID:@"thread-1"
            threadSource:@"user"
            source:@"vscode"
            cliVersion:@"test-version"
            timestamp:@"2026-08-20T00:00:00Z"
            workingDirectory:@"/private/demo/project"];
        NSArray<CPACodexMessage *> *messages = @[
            Message(@"u1", CPACodexMessageRoleUser,
                [NSString stringWithFormat:@"key=%@ email=%@", syntheticSecret, syntheticEmail], 1),
            Message(@"a1", CPACodexMessageRoleAssistant, @"assistant reply", 2),
            Message(@"u2", CPACodexMessageRoleUser, @"second request", 3),
            Message(@"a2", CPACodexMessageRoleAssistant, @"second reply", 4),
        ];

        for (NSUInteger pass = 0; pass < 3; pass++) {
            CPALocalImportResult *result = [store importCodexMetadata:metadata
                messages:messages error:&error];
            Assert(result != nil && error == nil, @"重复导入不应失败");
            Assert(result.insertedMessageCount == (pass == 0 ? 4 : 0),
                @"只有首次导入可以新增消息");
        }

        CPALocalDataCounts *counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 1, @"来源应幂等");
        Assert(counts.conversationCount == 1, @"会话应幂等");
        Assert(counts.messageCount == 4, @"消息重复导入三次仍应只有四条");
        Assert(counts.importRunCount == 3, @"每次成功导入应有独立运行记录");

        NSString *decrypted = [store decryptedMessageTextForThreadID:@"thread-1"
            messageID:@"u1" error:&error];
        Assert([decrypted containsString:syntheticSecret]
                && [decrypted containsString:syntheticEmail],
            @"本地正确密钥应能还原完整原文");

        CPACodexSourceMetadata *injectionMetadata = [[CPACodexSourceMetadata alloc]
            initWithThreadID:@"thread'); DROP TABLE messages;--"
            threadSource:@"user"
            source:@"vscode"
            cliVersion:@"test-version"
            timestamp:@"2026-08-20T00:00:01Z"
            workingDirectory:@"/tmp/injection"];
        NSArray<CPACodexMessage *> *injectionMessages = @[
            Message(@"m'); DROP TABLE sources;--", CPACodexMessageRoleUser,
                @"parameterized query", 1),
        ];
        Assert([store importCodexMetadata:injectionMetadata
                messages:injectionMessages error:&error] != nil,
            @"SQL 元字符必须作为普通参数保存");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 2 && counts.messageCount == 5,
            @"注入样本后数据库表和计数必须完好");

        Assert([store deleteSourceKind:@"codex" externalID:@"thread-1" error:&error],
            @"删除来源应写入 tombstone 并级联删除正文");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 1 && counts.conversationCount == 1
                && counts.messageCount == 1 && counts.tombstoneCount == 1,
            @"删除来源后只应保留注入夹具和一条 tombstone");
        Assert([store isSourceTombstonedForKind:@"codex"
                externalID:@"thread-1" error:&error], @"来源删除决定应可查询");
        CPALocalImportResult *blocked = [store importCodexMetadata:metadata
            messages:messages error:&error];
        Assert(blocked != nil && blocked.skippedTombstonedSource
                && blocked.insertedMessageCount == 0,
            @"已删除来源再次导入必须幂等跳过");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 1 && counts.messageCount == 1
                && counts.tombstoneCount == 1,
            @"重复导入不得让已删除来源复活");

        Assert([store close:&error] && error == nil, @"数据库应安全关闭并 checkpoint");
        NSArray<NSURL *> *databaseFiles = [fileManager contentsOfDirectoryAtURL:base
            includingPropertiesForKeys:nil options:0 error:&error];
        NSData *secretData = [syntheticSecret dataUsingEncoding:NSUTF8StringEncoding];
        NSData *emailData = [syntheticEmail dataUsingEncoding:NSUTF8StringEncoding];
        NSData *workingDirectoryData = [@"/private/demo/project"
            dataUsingEncoding:NSUTF8StringEncoding];
        for (NSUInteger i = 0, len = databaseFiles.count; i < len; i++) {
            NSURL *url = databaseFiles[i];
            Assert(!FileContainsData(url, secretData), @"数据库文件不得出现 API Key 明文");
            Assert(!FileContainsData(url, emailData), @"数据库文件不得出现邮箱明文");
            Assert(!FileContainsData(url, workingDirectoryData), @"数据库文件不得出现工作目录明文");
        }

        NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager
            attributesOfItemAtPath:databaseURL.path error:&error];
        NSNumber *permissions = attributes[NSFilePosixPermissions];
        Assert(permissions != nil && error == nil, @"应能读取数据库文件权限");
        Assert((permissions.unsignedShortValue & 0777) == 0600,
            @"数据库文件权限必须是仅当前用户可读写");

        NSURL *legacyURL = [base URLByAppendingPathComponent:@"legacy.sqlite3"];
        sqlite3 *legacyDatabase = NULL;
        Assert(sqlite3_open_v2(legacyURL.fileSystemRepresentation, &legacyDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) == SQLITE_OK,
            @"应创建 v1 迁移夹具");
        const char *legacySQL =
            "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT);"
            "INSERT INTO schema_migrations(version,applied_at) VALUES(1,'test');"
            "CREATE TABLE source_cursors(source_id INTEGER PRIMARY KEY,"
            "safe_offset INTEGER NOT NULL DEFAULT 0,file_size INTEGER NOT NULL DEFAULT 0,"
            "parser_version INTEGER NOT NULL DEFAULT 1,updated_at TEXT);";
        Assert(sqlite3_exec(legacyDatabase, legacySQL, NULL, NULL, NULL) == SQLITE_OK,
            @"应建立缺少 Task 7 字段的 v1 schema");
        sqlite3_close_v2(legacyDatabase);
        error = nil;
        CPALocalDataStore *migratedStore = [[CPALocalDataStore alloc]
            initWithDatabaseURL:legacyURL masterKey:SyntheticMasterKey() error:&error];
        Assert(migratedStore != nil && error == nil, @"v1 数据库应自动升级到 v2");
        Assert([migratedStore close:&error], @"迁移后的数据库应安全关闭");
        Assert(DatabaseHasColumn(legacyURL, @"source_cursors", @"device_id")
                && DatabaseHasColumn(legacyURL, @"source_cursors", @"inode")
                && DatabaseHasColumn(legacyURL, @"source_cursors", @"safe_line_number"),
            @"v2 迁移必须补齐文件身份和绝对行号字段");
        Assert(DatabaseHasTable(legacyURL, @"source_tombstones"),
            @"v3 迁移必须建立来源删除 tombstone 表");
        Assert(DatabaseHasTable(legacyURL, @"expressions")
                && DatabaseHasTable(legacyURL, @"expression_occurrences")
                && DatabaseHasTable(legacyURL, @"expression_tombstones")
                && DatabaseHasTable(legacyURL, @"expression_builds"),
            @"v4 迁移必须建立加密表达派生表");

        NSURL *enumerationURL = [base URLByAppendingPathComponent:@"enumeration.sqlite3"];
        error = nil;
        CPALocalDataStore *enumerationStore = [[CPALocalDataStore alloc]
            initWithDatabaseURL:enumerationURL masterKey:SyntheticMasterKey() error:&error];
        Assert(enumerationStore != nil && error == nil,
            @"应创建用户消息枚举合成数据库");
        CPACodexSourceMetadata *firstEnumerationMetadata = [[CPACodexSourceMetadata alloc]
            initWithThreadID:@"enumeration-thread-1"
            threadSource:@"user"
            source:@"synthetic"
            cliVersion:@"test-version"
            timestamp:@"2026-08-20T01:00:00Z"
            workingDirectory:@""];
        CPACodexSourceMetadata *secondEnumerationMetadata = [[CPACodexSourceMetadata alloc]
            initWithThreadID:@"enumeration-thread-2"
            threadSource:@"user"
            source:@"synthetic"
            cliVersion:@"test-version"
            timestamp:@"2026-08-20T02:00:00Z"
            workingDirectory:@""];
        NSArray<CPACodexMessage *> *firstEnumerationMessages = @[
            Message(@"enum-u1", CPACodexMessageRoleUser,
                [NSString stringWithFormat:@"key=%@", syntheticSecret], 1),
            Message(@"enum-a1", CPACodexMessageRoleAssistant,
                @"assistant must not be enumerated", 2),
            Message(@"enum-u2", CPACodexMessageRoleUser, @"second user sentence", 3),
        ];
        NSArray<CPACodexMessage *> *secondEnumerationMessages = @[
            Message(@"enum-a2", CPACodexMessageRoleAssistant,
                @"another assistant reply", 1),
            Message(@"enum-u3", CPACodexMessageRoleUser, @"third user sentence", 2),
        ];
        Assert([enumerationStore importCodexMetadata:firstEnumerationMetadata
                messages:firstEnumerationMessages error:&error] != nil,
            @"应导入第一组枚举夹具");
        Assert([enumerationStore importCodexMetadata:secondEnumerationMetadata
                messages:secondEnumerationMessages error:&error] != nil,
            @"应导入第二组枚举夹具");

        NSMutableArray<CPALocalUserMessageRecord *> *records = [NSMutableArray array];
        BOOL enumerated = [enumerationStore enumerateDecryptedUserMessages:
            ^BOOL(CPALocalUserMessageRecord *record, BOOL *stop, NSError **handlerError) {
                (void)stop;
                (void)handlerError;
                [records addObject:record];
                return YES;
            } error:&error];
        Assert(enumerated && error == nil && records.count == 3,
            @"枚举应只返回三个用户消息");
        Assert(records[0].messageRowID < records[1].messageRowID
                && records[1].messageRowID < records[2].messageRowID,
            @"用户消息应按稳定的数据库行号顺序枚举");
        Assert(records[0].conversationRowID == records[1].conversationRowID
                && records[1].conversationRowID != records[2].conversationRowID,
            @"枚举记录应保留会话行号");
        Assert(records[0].containsSensitiveData
                && !records[1].containsSensitiveData
                && !records[2].containsSensitiveData,
            @"枚举记录应只暴露敏感命中布尔值");
        Assert([records[1].text isEqualToString:@"second user sentence"]
                && [records[2].text isEqualToString:@"third user sentence"]
                && [records[0].sourceTimestamp isEqualToString:
                    @"2026-08-20T00:00:00Z"],
            @"枚举应解密用户正文并保留消息时间");
        Assert(![[records valueForKey:@"text"] containsObject:
                @"assistant must not be enumerated"],
            @"助手消息不得进入用户消息枚举");

        __block NSUInteger cancelledCount = 0;
        enumerated = [enumerationStore enumerateDecryptedUserMessages:
            ^BOOL(CPALocalUserMessageRecord *record, BOOL *stop, NSError **handlerError) {
                (void)record;
                (void)handlerError;
                cancelledCount++;
                *stop = YES;
                return YES;
            } error:&error];
        Assert(enumerated && error == nil && cancelledCount == 1,
            @"枚举调用方应能在一条记录后安全停止");

        NSString *firstExpressionText = @"先别急着做，先把方案梳理清楚。";
        NSString *secondExpressionText = @"请继续检查这个简单方案。";
        NSArray<NSNumber *> *supportingMessageIDs = @[
            @(records[1].messageRowID), @(records[2].messageRowID),
        ];
        CPALocalExpressionCandidate *firstCandidate = [[CPALocalExpressionCandidate alloc]
            initWithNormalizedText:firstExpressionText
            occurrenceMessageRowIDs:supportingMessageIDs
            occurrenceCount:2
            conversationCount:2
            lastSourceTimestamp:@"2026-08-20T02:00:00Z"];
        CPALocalExpressionCandidate *secondCandidate = [[CPALocalExpressionCandidate alloc]
            initWithNormalizedText:secondExpressionText
            occurrenceMessageRowIDs:supportingMessageIDs
            occurrenceCount:2
            conversationCount:2
            lastSourceTimestamp:@"2026-08-20T02:00:00Z"];
        CPALocalExpressionBuildResult *buildResult = [enumerationStore
            replaceActiveExpressions:@[firstCandidate, secondCandidate]
            extractorVersion:1 error:&error];
        Assert(buildResult != nil && error == nil
                && buildResult.activeExpressionCount == 2
                && buildResult.skippedTombstoneCount == 0,
            @"应原子写入两条加密表达");
        NSArray<CPALocalExpressionRecord *> *storedExpressions =
            [enumerationStore loadActiveExpressions:&error];
        Assert(storedExpressions.count == 2 && error == nil
                && [storedExpressions[0].normalizedText isEqualToString:firstExpressionText]
                && [storedExpressions[1].normalizedText isEqualToString:secondExpressionText]
                && storedExpressions[0].occurrenceCount == 2
                && storedExpressions[0].conversationCount == 2
                && storedExpressions[0].extractorVersion == 1,
            @"正确密钥应能加载完整表达及计数");
        Assert([enumerationStore close:&error] && error == nil,
            @"用户消息枚举数据库应安全关闭");

        NSArray<NSURL *> *enumerationFiles = [fileManager contentsOfDirectoryAtURL:base
            includingPropertiesForKeys:nil options:0 error:&error];
        NSData *firstExpressionData = [firstExpressionText
            dataUsingEncoding:NSUTF8StringEncoding];
        NSData *secondExpressionData = [secondExpressionText
            dataUsingEncoding:NSUTF8StringEncoding];
        for (NSUInteger i = 0, len = enumerationFiles.count; i < len; i++) {
            NSURL *url = enumerationFiles[i];
            if (![url.lastPathComponent hasPrefix:enumerationURL.lastPathComponent]) {
                continue;
            }
            Assert(!FileContainsData(url, firstExpressionData)
                    && !FileContainsData(url, secondExpressionData),
                @"SQLite、WAL 和 SHM 不得出现表达明文");
        }

        error = nil;
        enumerationStore = [[CPALocalDataStore alloc]
            initWithDatabaseURL:enumerationURL masterKey:SyntheticMasterKey() error:&error];
        Assert(enumerationStore != nil && error == nil,
            @"应重新打开表达测试数据库");
        CPALocalExpressionCandidate *invalidCandidate = [[CPALocalExpressionCandidate alloc]
            initWithNormalizedText:@"这条表达引用不存在的消息。"
            occurrenceMessageRowIDs:@[@999999]
            occurrenceCount:1
            conversationCount:1
            lastSourceTimestamp:@"2026-08-20T03:00:00Z"];
        Assert([enumerationStore replaceActiveExpressions:@[invalidCandidate]
                extractorVersion:2 error:&error] == nil && error != nil,
            @"无效来源关系必须让整批表达替换失败");
        error = nil;
        storedExpressions = [enumerationStore loadActiveExpressions:&error];
        Assert(storedExpressions.count == 2 && error == nil
                && [storedExpressions[0].normalizedText isEqualToString:firstExpressionText]
                && [storedExpressions[1].normalizedText isEqualToString:secondExpressionText],
            @"表达替换失败后必须保留上一批完整快照");
        Assert([enumerationStore deleteExpressionText:firstExpressionText error:&error]
                && error == nil,
            @"删除表达应立即写入墓碑并移除活跃记录");
        storedExpressions = [enumerationStore loadActiveExpressions:&error];
        Assert(storedExpressions.count == 1 && error == nil
                && [storedExpressions[0].normalizedText isEqualToString:
                    secondExpressionText],
            @"删除后应只保留未删除的表达");
        Assert([enumerationStore deleteExpressionText:firstExpressionText error:&error]
                && error == nil,
            @"重复删除同一表达应幂等成功");
        buildResult = [enumerationStore replaceActiveExpressions:
            @[firstCandidate, secondCandidate] extractorVersion:2 error:&error];
        Assert(buildResult != nil && error == nil
                && buildResult.activeExpressionCount == 1
                && buildResult.skippedTombstoneCount == 1,
            @"快照重建必须跳过已删除表达");
        storedExpressions = [enumerationStore loadActiveExpressions:&error];
        Assert(storedExpressions.count == 1 && error == nil
                && [storedExpressions[0].normalizedText isEqualToString:
                    secondExpressionText],
            @"已删除表达不得被原始候选恢复");
        Assert([enumerationStore close:&error] && error == nil,
            @"回滚验证后的表达数据库应安全关闭");

        [fileManager removeItemAtURL:base error:nil];
        NSLog(@"PASS: LocalDataStoreTests");
    }
    return 0;
}
