#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/CodexIncrementalImporter.h"
#import "../../Sources/CodexDataCore/CodexMessage.h"
#import "../../Sources/CodexDataCore/CodexRecordParser.h"
#import "../../Sources/CodexDataCore/CodexSourceMetadata.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSData *SyntheticMasterKey(void) {
    NSMutableData *data = [NSMutableData dataWithLength:64];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0, len = data.length; i < len; i++) {
        bytes[i] = (uint8_t)(i + 19);
    }
    return data;
}

static NSData *JSONLine(NSDictionary *object, BOOL newline) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object
        options:NSJSONWritingSortedKeys error:&error];
    Assert(json != nil && error == nil, @"合成 JSON 必须可序列化");
    NSMutableData *line = [json mutableCopy];
    if (newline) {
        const uint8_t byte = (uint8_t)'\n';
        [line appendBytes:&byte length:1];
    }
    return line;
}

static NSDictionary *MetadataRecord(void) {
    return @{
        @"timestamp": @"2026-08-20T00:00:00Z",
        @"type": @"session_meta",
        @"payload": @{
            @"id": @"incremental-thread",
            @"thread_source": @"user",
            @"source": @"vscode",
            @"cli_version": @"test",
            @"timestamp": @"2026-08-20T00:00:00Z",
            @"cwd": @"/private/synthetic/project",
        },
    };
}

static NSDictionary *MessageRecord(NSString *messageID, NSString *text) {
    return @{
        @"timestamp": @"2026-08-20T00:00:01Z",
        @"type": @"response_item",
        @"payload": @{
            @"id": messageID,
            @"type": @"message",
            @"role": @"user",
            @"content": @[@{@"type": @"input_text", @"text": text}],
        },
    };
}

static NSMutableData *FileData(NSArray<NSDictionary *> *records) {
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0, len = records.count; i < len; i++) {
        [data appendData:JSONLine(records[i], YES)];
    }
    return data;
}

static void AppendData(NSURL *url, NSData *data) {
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
    Assert(handle != nil, @"应能打开合成来源追加数据");
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
            isDirectory:YES];
        NSURL *active = [base URLByAppendingPathComponent:@"active" isDirectory:YES];
        NSURL *archived = [base URLByAppendingPathComponent:@"archived" isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:active withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建 active 目录");
        Assert([fileManager createDirectoryAtURL:archived withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建 archived 目录");

        NSURL *databaseURL = [base URLByAppendingPathComponent:@"history.sqlite3"];
        NSURL *sourceURL = [active URLByAppendingPathComponent:@"thread.jsonl"];
        NSData *metadataLine = JSONLine(MetadataRecord(), YES);
        NSData *firstLine = JSONLine(MessageRecord(@"m1", @"first"), YES);
        NSString *largeSecondText = [@"x" stringByPaddingToLength:2048
            withString:@"x" startingAtIndex:0];
        NSData *secondWithoutNewline = JSONLine(
            MessageRecord(@"m2", largeSecondText), NO);
        NSUInteger split = secondWithoutNewline.length / 2;
        NSMutableData *initial = [NSMutableData dataWithData:metadataLine];
        [initial appendData:firstLine];
        [initial appendData:[secondWithoutNewline subdataWithRange:NSMakeRange(0, split)]];
        Assert([initial writeToURL:sourceURL options:NSDataWritingAtomic error:&error],
            @"应写入带半行的合成来源");

        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"应打开增量测试数据库");
        CPACodexIncrementalImporter *importer = [[CPACodexIncrementalImporter alloc]
            initWithChunkSize:31];

        CPACodexIncrementalImportResult *result = [importer importFileAtURL:sourceURL
            intoStore:store error:&error];
        Assert(result != nil && error == nil, @"首次半行导入不应失败");
        Assert(result.insertedMessageCount == 1, @"首次只能导入完整的第一条消息");
        Assert(result.trailingByteCount > 0, @"首次应报告未提交半行");
        Assert(result.safeLineNumber == 2, @"游标应停在 metadata 和第一条消息之后");
        uint64_t firstSafeOffset = result.safeOffset;
        Assert(firstSafeOffset == metadataLine.length + firstLine.length,
            @"safeOffset 必须停在最后一个换行之后");

        Assert([store close:&error], @"应模拟进程重启前关闭数据库");
        store = [[CPALocalDataStore alloc] initWithDatabaseURL:databaseURL
            masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"重启后应重新打开数据库");

        NSMutableData *completion = [NSMutableData dataWithData:
            [secondWithoutNewline subdataWithRange:NSMakeRange(split,
                secondWithoutNewline.length - split)]];
        const uint8_t newline = (uint8_t)'\n';
        [completion appendBytes:&newline length:1];
        AppendData(sourceURL, completion);
        result = [importer importFileAtURL:sourceURL intoStore:store error:&error];
        Assert(result != nil && error == nil, @"补齐半行后应可恢复导入");
        Assert(result.insertedMessageCount == 1 && result.safeLineNumber == 3,
            @"重启后只能新增第二条并推进一行");
        Assert(!result.didResetCursor, @"正常追加不得重置游标");

        result = [importer importFileAtURL:sourceURL intoStore:store error:&error];
        Assert(result != nil && result.insertedMessageCount == 0
                && result.existingMessageCount == 0,
            @"没有新字节时重复扫描不得重复读取消息");

        NSMutableData *truncated = FileData(@[
            MetadataRecord(), MessageRecord(@"m1", @"first"),
            MessageRecord(@"m3", @"after truncation"),
        ]);
        Assert([truncated writeToURL:sourceURL options:0 error:&error],
            @"应在同一 inode 上截断并重写来源");
        result = [importer importFileAtURL:sourceURL intoStore:store error:&error];
        Assert(result != nil && result.didResetCursor,
            @"文件截断后必须从头重放");
        Assert(result.insertedMessageCount == 1 && result.existingMessageCount == 1,
            @"截断重放应去重旧消息并新增一条");

        Assert([fileManager removeItemAtURL:sourceURL error:&error], @"应删除旧 inode 来源");
        NSMutableData *replacement = FileData(@[
            MetadataRecord(), MessageRecord(@"m1", @"first"),
            MessageRecord(@"m4", @"after replacement"),
        ]);
        Assert([replacement writeToURL:sourceURL options:0 error:&error],
            @"应以新 inode 重建同一路径来源");
        result = [importer importFileAtURL:sourceURL intoStore:store error:&error];
        Assert(result != nil && result.didResetCursor,
            @"inode 变化后必须从头重放");
        Assert(result.insertedMessageCount == 1 && result.existingMessageCount == 1,
            @"inode 重放应只新增替换文件里的新消息");

        NSURL *archivedURL = [archived URLByAppendingPathComponent:@"thread.jsonl"];
        Assert([fileManager moveItemAtURL:sourceURL toURL:archivedURL error:&error],
            @"应模拟 active 移入 archived");
        AppendData(archivedURL, JSONLine(MessageRecord(@"m5", @"after archive"), YES));
        result = [importer importFileAtURL:archivedURL intoStore:store error:&error];
        Assert(result != nil && !result.didResetCursor,
            @"同 inode 归档迁移不得重置游标");
        Assert(result.insertedMessageCount == 1 && result.safeLineNumber == 4,
            @"归档后追加应从原游标继续");

        CPALocalSourceCursor *beforeFailure = [store codexCursorForThreadID:
            @"incremental-thread" error:&error];
        Assert(beforeFailure != nil, @"事务失败测试前应能读取游标");
        CPACodexRecordParser *parser = [[CPACodexRecordParser alloc] init];
        CPACodexSourceMetadata *metadata = [parser parseMetadataLineData:
            JSONLine(MetadataRecord(), NO) error:&error];
        CPACodexMessage *valid = [[CPACodexMessage alloc] initWithMessageID:@"m6"
            timestamp:@"2026-08-20T00:00:02Z"
            role:CPACodexMessageRoleUser text:@"must roll back"
            sourceLineNumber:5 sourceByteOffset:500];
        CPACodexMessage *invalid = [[CPACodexMessage alloc] initWithMessageID:@"m7"
            timestamp:@"2026-08-20T00:00:03Z"
            role:(CPACodexMessageRole)99 text:@"invalid role"
            sourceLineNumber:6 sourceByteOffset:600];
        CPALocalSourceCursor *advanced = [[CPALocalSourceCursor alloc]
            initWithThreadID:@"incremental-thread"
            deviceID:beforeFailure.deviceID inode:beforeFailure.inode
            safeOffset:beforeFailure.safeOffset + 100
            safeLineNumber:beforeFailure.safeLineNumber + 2
            fileSize:beforeFailure.fileSize + 100 parserVersion:1];
        error = nil;
        CPALocalImportResult *failed = [store importCodexMetadata:metadata
            messages:@[valid, invalid] advancingCursor:advanced error:&error];
        Assert(failed == nil && error != nil, @"非法角色必须让整次事务失败");
        error = nil;
        Assert([store decryptedMessageTextForThreadID:@"incremental-thread"
            messageID:@"m6" error:&error] == nil && error == nil,
            @"事务失败后前一条合法消息也不得残留");
        CPALocalSourceCursor *afterFailure = [store codexCursorForThreadID:
            @"incremental-thread" error:&error];
        Assert(afterFailure.safeOffset == beforeFailure.safeOffset
                && afterFailure.safeLineNumber == beforeFailure.safeLineNumber,
            @"事务失败后游标不得推进");

        CPALocalDataCounts *counts = [store currentCounts:&error];
        Assert(counts.messageCount == 5, @"最终只能有 m1 到 m5 五条消息");

        Assert([store deleteSourceKind:@"codex"
                externalID:@"incremental-thread" error:&error],
            @"增量来源应可删除并建立 tombstone");
        NSMutableData *tombstonedFile = FileData(@[MetadataRecord()]);
        [tombstonedFile appendData:[@"not-json\n" dataUsingEncoding:NSUTF8StringEncoding]];
        Assert([tombstonedFile writeToURL:archivedURL options:0 error:&error],
            @"应把已删除来源改成首行有效、后续损坏的夹具");
        result = [importer importFileAtURL:archivedURL intoStore:store error:&error];
        Assert(result != nil && error == nil && result.skippedDeletedSource,
            @"已删除来源应在读取首行 ID 后快速跳过损坏正文");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 0 && counts.messageCount == 0
                && counts.tombstoneCount == 1,
            @"删除后重扫不得恢复任何来源或消息");
        Assert([store close:&error], @"增量测试数据库应安全关闭");
        [fileManager removeItemAtURL:base error:nil];
        NSLog(@"PASS: CodexIncrementalImporterTests");
    }
    return 0;
}
