#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/CodexIncrementalImporter.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"

static const NSUInteger CPAMessageCount = 100000;

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSData *SyntheticMasterKey(void) {
    NSMutableData *key = [NSMutableData dataWithLength:64];
    memset(key.mutableBytes, 0xa5, key.length);
    return key;
}

static void WriteAll(NSOutputStream *stream, NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        NSInteger written = [stream write:bytes maxLength:remaining];
        Assert(written > 0, @"应能写入合成 JSONL");
        bytes += written;
        remaining -= (NSUInteger)written;
    }
}

static void GenerateSyntheticHistory(NSURL *url, NSString *privateMarker) {
    NSOutputStream *stream = [NSOutputStream outputStreamWithURL:url append:NO];
    [stream open];
    NSString *metadata = @"{\"type\":\"session_meta\",\"timestamp\":\"2026-08-20T00:00:00Z\",\"payload\":{\"id\":\"checkpoint-c-root\",\"thread_source\":\"user\",\"source\":\"synthetic\",\"cwd\":\"/private/checkpoint-c\",\"cli_version\":\"test\",\"timestamp\":\"2026-08-20T00:00:00Z\"}}\n";
    WriteAll(stream, [metadata dataUsingEncoding:NSUTF8StringEncoding]);
    for (NSUInteger i = 0; i < CPAMessageCount; i++) {
        @autoreleasepool {
            NSString *text = i == 54321
                ? [NSString stringWithFormat:@"synthetic message %lu %@",
                    (unsigned long)i, privateMarker]
                : [NSString stringWithFormat:@"synthetic message %lu",
                    (unsigned long)i];
            NSString *line = [NSString stringWithFormat:
                @"{\"type\":\"response_item\",\"timestamp\":\"2026-08-20T00:00:01Z\",\"payload\":{\"type\":\"message\",\"id\":\"m-%06lu\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"%@\"}]}}\n",
                (unsigned long)i, text];
            WriteAll(stream, [line dataUsingEncoding:NSUTF8StringEncoding]);
        }
    }
    [stream close];
    Assert(stream.streamError == nil, @"合成 JSONL 写入不得失败");
}

static BOOL FileContainsData(NSURL *url, NSData *needle) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path];
    if (handle == nil) {
        return NO;
    }
    NSUInteger overlapLength = needle.length > 0 ? needle.length - 1 : 0;
    NSData *overlap = [NSData data];
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [handle readDataOfLength:1024 * 1024];
            if (chunk.length == 0) {
                break;
            }
            NSMutableData *combined = [NSMutableData dataWithData:overlap];
            [combined appendData:chunk];
            if ([combined rangeOfData:needle options:0
                    range:NSMakeRange(0, combined.length)].location != NSNotFound) {
                [handle closeFile];
                return YES;
            }
            NSUInteger kept = MIN(overlapLength, combined.length);
            overlap = [combined subdataWithRange:
                NSMakeRange(combined.length - kept, kept)];
        }
    }
    [handle closeFile];
    return NO;
}

static double MillisecondsSince(NSDate *start) {
    return -[start timeIntervalSinceNow] * 1000.0;
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:base withIntermediateDirectories:YES
            attributes:nil error:&error] && error == nil, @"应创建合成性能测试目录");
        NSURL *sourceURL = [base URLByAppendingPathComponent:@"history.jsonl"];
        NSURL *databaseURL = [base URLByAppendingPathComponent:@"history.sqlite3"];
        NSString *privateMarker = [@"CHECKPOINT_C_PRIVATE_"
            stringByAppendingString:NSUUID.UUID.UUIDString];
        GenerateSyntheticHistory(sourceURL, privateMarker);

        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"应创建性能测试数据库");
        CPACodexIncrementalImporter *importer = [[CPACodexIncrementalImporter alloc]
            initWithChunkSize:64 * 1024];

        NSDate *start = [NSDate date];
        CPACodexIncrementalImportResult *result = [importer importFileAtURL:sourceURL
            intoStore:store error:&error];
        double importMilliseconds = MillisecondsSince(start);
        Assert(result != nil && error == nil
                && result.insertedMessageCount == CPAMessageCount,
            @"首次导入应写入 10 万条合成消息");
        CPALocalDataCounts *counts = [store currentCounts:&error];
        Assert(counts != nil && counts.messageCount == CPAMessageCount,
            @"首次导入后的消息计数应为 10 万");

        start = [NSDate date];
        result = [importer importFileAtURL:sourceURL intoStore:store error:&error];
        double rescanMilliseconds = MillisecondsSince(start);
        Assert(result != nil && error == nil && result.insertedMessageCount == 0,
            @"重复扫描不得新增消息");
        counts = [store currentCounts:&error];
        Assert(counts.messageCount == CPAMessageCount,
            @"重复扫描后的消息计数必须保持 10 万");

        NSMutableArray<NSNumber *> *latencies = [NSMutableArray arrayWithCapacity:1000];
        uint32_t randomState = 0x5eed1234;
        for (NSUInteger i = 0; i < 1000; i++) {
            randomState = randomState * 1664525u + 1013904223u;
            NSUInteger messageIndex = randomState % CPAMessageCount;
            NSString *messageID = [NSString stringWithFormat:@"m-%06lu",
                (unsigned long)messageIndex];
            NSDate *readStart = [NSDate date];
            NSString *text = [store decryptedMessageTextForThreadID:@"checkpoint-c-root"
                messageID:messageID error:&error];
            double latency = MillisecondsSince(readStart);
            Assert(text != nil && error == nil, @"随机读取应能解密合成消息");
            [latencies addObject:@(latency)];
        }
        [latencies sortUsingSelector:@selector(compare:)];
        double readP95 = latencies[949].doubleValue;
        Assert(readP95 < 80.0, @"10 万条规模的随机读取 p95 应低于 80ms");

        Assert([store deleteSourceKind:@"codex"
                externalID:@"checkpoint-c-root" error:&error] && error == nil,
            @"应删除 10 万条合成消息来源");
        counts = [store currentCounts:&error];
        Assert(counts.messageCount == 0 && counts.tombstoneCount == 1,
            @"删除后应无消息且保留一个墓碑");
        start = [NSDate date];
        result = [importer importFileAtURL:sourceURL intoStore:store error:&error];
        double tombstoneSkipMilliseconds = MillisecondsSince(start);
        Assert(result != nil && error == nil && result.skippedDeletedSource
                && result.insertedMessageCount == 0,
            @"删除后的重扫应快速跳过且不得复活来源");
        counts = [store currentCounts:&error];
        Assert(counts.messageCount == 0 && counts.tombstoneCount == 1,
            @"删除后重扫不得改变消息或墓碑计数");
        Assert([store close:&error] && error == nil, @"性能测试数据库应安全关闭");

        NSData *markerData = [privateMarker dataUsingEncoding:NSUTF8StringEncoding];
        NSArray<NSURL *> *files = [fileManager contentsOfDirectoryAtURL:base
            includingPropertiesForKeys:nil options:0 error:&error];
        NSUInteger plaintextLeakCount = 0;
        NSString *databaseName = databaseURL.lastPathComponent;
        for (NSUInteger i = 0, len = files.count; i < len; i++) {
            NSURL *url = files[i];
            if ([url.lastPathComponent hasPrefix:databaseName]
                && FileContainsData(url, markerData)) {
                plaintextLeakCount++;
            }
        }
        Assert(plaintextLeakCount == 0, @"数据库及附属文件不得含合成私密标记明文");

        printf("checkpoint_c_complete=true messages=%lu import_seconds=%.3f "
            "rescan_seconds=%.3f read_p95_ms=%.3f tombstone_skip_ms=%.3f "
            "plaintext_leaks=%lu\n",
            (unsigned long)CPAMessageCount,
            importMilliseconds / 1000.0,
            rescanMilliseconds / 1000.0,
            readP95,
            tombstoneSkipMilliseconds,
            (unsigned long)plaintextLeakCount);
        [fileManager removeItemAtURL:base error:nil];
    }
    return 0;
}
