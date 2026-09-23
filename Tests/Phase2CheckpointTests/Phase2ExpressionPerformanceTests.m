#import <Foundation/Foundation.h>

#import <mach/mach.h>

#import "../../Sources/CodexDataCore/CodexMessage.h"
#import "../../Sources/CodexDataCore/CodexSourceMetadata.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"
#import "../../Sources/CodexDataCore/LocalExpressionRecord.h"
#import "../../Sources/ExpressionLibraryCore/ExpressionLibraryBuilder.h"
#import "../../Sources/ExpressionLibraryCore/ExpressionSuggestionIndex.h"

static const NSUInteger CPAExpressionCount = 50000;
static const NSUInteger CPAMessageCount = CPAExpressionCount * 2;

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
        bytes[i] = (uint8_t)(i + 101);
    }
    return data;
}

static NSString *ExpressionText(NSUInteger index) {
    return [NSString stringWithFormat:
        @"checkpoint expression %05lu please continue.", (unsigned long)index];
}

static CPACodexSourceMetadata *Metadata(NSString *threadID, NSString *timestamp) {
    return [[CPACodexSourceMetadata alloc] initWithThreadID:threadID
        threadSource:@"user"
        source:@"synthetic-checkpoint"
        cliVersion:@"test-version"
        timestamp:timestamp
        workingDirectory:@""];
}

static uint64_t ResidentBytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
        (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? info.resident_size : 0;
}

static BOOL FileContainsData(NSURL *url, NSData *needle) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe
        error:NULL];
    if (data == nil) {
        return NO;
    }
    return [data rangeOfData:needle options:0
        range:NSMakeRange(0, data.length)].location != NSNotFound;
}

static void ImportConversation(CPALocalDataStore *store,
    CPACodexSourceMetadata *metadata, NSString *messagePrefix,
    NSString *timestamp, NSError **error) {
    const NSUInteger batchSize = 1000;
    for (NSUInteger batchStart = 0; batchStart < CPAExpressionCount;
            batchStart += batchSize) {
        @autoreleasepool {
            NSMutableArray<CPACodexMessage *> *messages =
                [NSMutableArray arrayWithCapacity:batchSize];
            NSUInteger batchEnd = MIN(batchStart + batchSize, CPAExpressionCount);
            for (NSUInteger i = batchStart; i < batchEnd; i++) {
                NSString *messageID = [NSString stringWithFormat:@"%@-%05lu",
                    messagePrefix, (unsigned long)i];
                CPACodexMessage *message = [[CPACodexMessage alloc]
                    initWithMessageID:messageID
                    timestamp:timestamp
                    role:CPACodexMessageRoleUser
                    text:ExpressionText(i)
                    sourceLineNumber:i + 1
                    sourceByteOffset:(i + 1) * 100];
                [messages addObject:message];
            }
            CPALocalImportResult *result = [store importCodexMetadata:metadata
                messages:messages error:error];
            Assert(result != nil && (error == NULL || *error == nil),
                @"10 万条合成消息应分批导入成功");
        }
    }
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
            isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:base withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建阶段 2 验收目录");
        NSURL *databaseURL = [base URLByAppendingPathComponent:@"phase2.sqlite3"];
        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"应创建阶段 2 验收数据库");

        ImportConversation(store, Metadata(@"checkpoint-thread-1",
            @"2026-08-21T01:00:00Z"), @"a", @"2026-08-21T01:00:01Z", &error);
        ImportConversation(store, Metadata(@"checkpoint-thread-2",
            @"2026-08-21T02:00:00Z"), @"b", @"2026-08-21T02:00:01Z", &error);
        CPALocalDataCounts *counts = [store currentCounts:&error];
        Assert(counts != nil && error == nil && counts.messageCount == CPAMessageCount,
            @"表达验收必须实际使用 10 万条消息");

        uint64_t memoryBefore = ResidentBytes();
        __block CPALocalExpressionBuildResult *buildResult = nil;
        CFAbsoluteTime rebuildStarted = CFAbsoluteTimeGetCurrent();
        @autoreleasepool {
            CPAExpressionLibraryBuilder *builder = [[CPAExpressionLibraryBuilder alloc] init];
            buildResult = [builder rebuildStore:store error:&error];
        }
        NSTimeInterval rebuildSeconds = CFAbsoluteTimeGetCurrent() - rebuildStarted;
        Assert(buildResult != nil && error == nil
                && buildResult.activeExpressionCount == CPAExpressionCount,
            @"10 万条消息应构建 5 万条不重复表达");
        Assert(rebuildSeconds < 30.0, @"表达重建必须小于 30 秒");

        __block CPAExpressionSuggestionIndex *index = nil;
        __block NSUInteger duplicateCount = 0;
        CFAbsoluteTime loadStarted = CFAbsoluteTimeGetCurrent();
        @autoreleasepool {
            NSArray<CPALocalExpressionRecord *> *records =
                [store loadActiveExpressions:&error];
            Assert(records.count == CPAExpressionCount && error == nil,
                @"应加载全部加密表达");
            NSMutableSet<NSString *> *uniqueTexts = [NSMutableSet
                setWithCapacity:records.count];
            for (NSUInteger i = 0, len = records.count; i < len; i++) {
                [uniqueTexts addObject:records[i].normalizedText];
            }
            duplicateCount = records.count - uniqueTexts.count;
            index = [[CPAExpressionSuggestionIndex alloc] initWithExpressions:records];
        }
        NSTimeInterval loadSeconds = CFAbsoluteTimeGetCurrent() - loadStarted;
        uint64_t memoryAfter = ResidentBytes();
        uint64_t memoryDelta = memoryAfter > memoryBefore
            ? memoryAfter - memoryBefore : 0;
        Assert(duplicateCount == 0, @"活跃表达不得重复");
        Assert(memoryBefore == 0 || memoryAfter == 0
                || memoryDelta < 50ULL * 1024ULL * 1024ULL,
            @"表达重建与内存索引增量必须小于 50MB");

        NSMutableArray<NSNumber *> *queryDurations =
            [NSMutableArray arrayWithCapacity:1000];
        for (NSUInteger i = 0; i < 1000; i++) {
            NSUInteger expressionIndex = (i * 47) % CPAExpressionCount;
            NSString *input = [NSString stringWithFormat:
                @"checkpoint expression %05lu", (unsigned long)expressionIndex];
            CFAbsoluteTime queryStarted = CFAbsoluteTimeGetCurrent();
            CPAExpressionSuggestion *suggestion = [index suggestionForInput:input
                cursorLocation:input.length selectedLength:0];
            NSTimeInterval queryMilliseconds =
                (CFAbsoluteTimeGetCurrent() - queryStarted) * 1000.0;
            [queryDurations addObject:@(queryMilliseconds)];
            Assert(suggestion != nil && suggestion.insertionText.length > 0,
                @"1000 次确定性前缀查询必须全部命中");
        }
        [queryDurations sortUsingSelector:@selector(compare:)];
        double queryP95Milliseconds = queryDurations[949].doubleValue;
        Assert(queryP95Milliseconds < 10.0, @"前缀查询 p95 必须小于 10ms");
        index = nil;

        NSString *deletedText = ExpressionText(12345);
        Assert([store deleteExpressionText:deletedText error:&error] && error == nil,
            @"应删除一条规模夹具表达");
        @autoreleasepool {
            CPAExpressionLibraryBuilder *builder = [[CPAExpressionLibraryBuilder alloc] init];
            buildResult = [builder rebuildStore:store error:&error];
        }
        Assert(buildResult != nil && error == nil
                && buildResult.activeExpressionCount == CPAExpressionCount - 1
                && buildResult.skippedTombstoneCount == 1,
            @"删除表达重建后不得复活");
        @autoreleasepool {
            NSArray<CPALocalExpressionRecord *> *records =
                [store loadActiveExpressions:&error];
            BOOL revived = NO;
            for (NSUInteger i = 0, len = records.count; i < len; i++) {
                if ([records[i].normalizedText isEqualToString:deletedText]) {
                    revived = YES;
                    break;
                }
            }
            Assert(records.count == CPAExpressionCount - 1 && !revived,
                @"表达墓碑必须在完整重建后仍生效");
        }

        Assert([store close:&error] && error == nil, @"验收数据库应安全关闭");
        NSData *plaintextMarker = [@"checkpoint expression "
            dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger plaintextLeakCount = 0;
        NSArray<NSURL *> *artifacts = [fileManager contentsOfDirectoryAtURL:base
            includingPropertiesForKeys:nil options:0 error:&error];
        for (NSUInteger i = 0, len = artifacts.count; i < len; i++) {
            NSURL *url = artifacts[i];
            if ([url.lastPathComponent hasPrefix:databaseURL.lastPathComponent]
                && FileContainsData(url, plaintextMarker)) {
                plaintextLeakCount++;
            }
        }
        Assert(plaintextLeakCount == 0, @"SQLite 产物不得出现表达或消息明文");

        NSLog(@"phase2_message_count=%lu", (unsigned long)CPAMessageCount);
        NSLog(@"phase2_expression_count=%lu", (unsigned long)CPAExpressionCount);
        NSLog(@"phase2_rebuild_seconds=%.3f", rebuildSeconds);
        NSLog(@"phase2_index_load_seconds=%.3f", loadSeconds);
        NSLog(@"phase2_query_p95_ms=%.3f", queryP95Milliseconds);
        NSLog(@"phase2_memory_delta_bytes=%llu", (unsigned long long)memoryDelta);
        NSLog(@"phase2_plaintext_leaks=%lu", (unsigned long)plaintextLeakCount);
        NSLog(@"phase2_duplicate_expressions=%lu", (unsigned long)duplicateCount);
        NSLog(@"phase2_deleted_expression_revival=0");
        NSLog(@"phase2_checkpoint_complete=true");

        [fileManager removeItemAtURL:base error:nil];
    }
    return 0;
}
