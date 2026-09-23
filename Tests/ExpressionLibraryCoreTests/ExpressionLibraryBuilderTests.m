#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/CodexMessage.h"
#import "../../Sources/CodexDataCore/CodexSourceMetadata.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"
#import "../../Sources/CodexDataCore/LocalExpressionRecord.h"
#import "../../Sources/ExpressionLibraryCore/ExpressionLibraryBuilder.h"

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

static CPACodexSourceMetadata *Metadata(NSString *threadID, NSString *timestamp) {
    return [[CPACodexSourceMetadata alloc] initWithThreadID:threadID
        threadSource:@"user"
        source:@"synthetic"
        cliVersion:@"test-version"
        timestamp:timestamp
        workingDirectory:@""];
}

static CPACodexMessage *Message(NSString *messageID, NSString *timestamp,
    CPACodexMessageRole role, NSString *text, NSUInteger lineNumber) {
    return [[CPACodexMessage alloc] initWithMessageID:messageID
        timestamp:timestamp
        role:role
        text:text
        sourceLineNumber:lineNumber
        sourceByteOffset:lineNumber * 100];
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
            isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:base withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建表达聚合测试目录");
        NSURL *databaseURL = [base URLByAppendingPathComponent:@"builder.sqlite3"];
        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"应创建合成表达数据库");

        NSString *repeated = @"请先把方案梳理清楚。";
        NSString *sameConversationOnly = @"这句话只在一个会话里重复。";
        NSString *syntheticSecret = [@"sk" stringByAppendingString:
            @"-demo_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"];
        NSArray<CPACodexMessage *> *firstMessages = @[
            Message(@"t1-u1", @"2026-08-21T01:00:00Z", CPACodexMessageRoleUser,
                repeated, 1),
            Message(@"t1-u2", @"2026-08-21T02:00:00Z", CPACodexMessageRoleUser,
                sameConversationOnly, 2),
            Message(@"t1-u3", @"2026-08-21T03:00:00Z", CPACodexMessageRoleUser,
                sameConversationOnly, 3),
            Message(@"t1-a1", @"2026-08-21T04:00:00Z", CPACodexMessageRoleAssistant,
                repeated, 4),
            Message(@"t1-u4", @"2026-08-21T04:30:00Z", CPACodexMessageRoleUser,
                [NSString stringWithFormat:@"key=%@ 请保存这个敏感表达。",
                    syntheticSecret], 5),
            Message(@"t1-u5", @"2026-08-21T04:40:00Z", CPACodexMessageRoleUser,
                @"const value = function(input);", 6),
        ];
        NSArray<CPACodexMessage *> *secondMessages = @[
            Message(@"t2-u1", @"2026-08-21T05:00:00Z", CPACodexMessageRoleUser,
                repeated, 1),
            Message(@"t2-a1", @"2026-08-21T05:10:00Z", CPACodexMessageRoleAssistant,
                sameConversationOnly, 2),
            Message(@"t2-u2", @"2026-08-21T05:20:00Z", CPACodexMessageRoleUser,
                [NSString stringWithFormat:@"key=%@ 请保存这个敏感表达。",
                    syntheticSecret], 3),
            Message(@"t2-u3", @"2026-08-21T05:30:00Z", CPACodexMessageRoleUser,
                @"const value = function(input);", 4),
        ];
        Assert([store importCodexMetadata:Metadata(@"builder-thread-1",
                    @"2026-08-21T01:00:00Z")
                messages:firstMessages error:&error] != nil,
            @"应导入第一个合成会话");
        Assert([store importCodexMetadata:Metadata(@"builder-thread-2",
                    @"2026-08-21T05:00:00Z")
                messages:secondMessages error:&error] != nil,
            @"应导入第二个合成会话");

        CPAExpressionLibraryBuilder *builder = [[CPAExpressionLibraryBuilder alloc] init];
        for (NSUInteger pass = 0; pass < 3; pass++) {
            CPALocalExpressionBuildResult *result = [builder rebuildStore:store error:&error];
            Assert(result != nil && error == nil
                    && result.activeExpressionCount == 1
                    && result.skippedTombstoneCount == 0,
                @"三次重建都应产生同一条跨会话表达");
            NSArray<CPALocalExpressionRecord *> *records =
                [store loadActiveExpressions:&error];
            Assert(records.count == 1 && error == nil
                    && [records[0].normalizedText isEqualToString:repeated]
                    && records[0].occurrenceCount == 2
                    && records[0].conversationCount == 2
                    && [records[0].lastSourceTimestamp isEqualToString:
                        @"2026-08-21T05:00:00Z"]
                    && records[0].extractorVersion == 1,
                @"只应保留跨会话重复的用户固定句及正确统计");
        }

        Assert([store deleteExpressionText:repeated error:&error] && error == nil,
            @"应能删除已学习的表达");
        NSArray<CPALocalExpressionRecord *> *records =
            [store loadActiveExpressions:&error];
        Assert(records.count == 0 && error == nil,
            @"表达删除后应立即从活跃库消失");
        for (NSUInteger pass = 0; pass < 3; pass++) {
            CPALocalExpressionBuildResult *result = [builder rebuildStore:store error:&error];
            Assert(result != nil && error == nil
                    && result.activeExpressionCount == 0
                    && result.skippedTombstoneCount == 1,
                @"已删衤表达在三次重建后也不得复活");
        }

        NSString *sourceDependent = @"请继续检查这个简单版本。";
        NSArray<CPACodexMessage *> *firstAdditionalMessages = @[
            Message(@"t1-u6", @"2026-08-21T06:00:00Z", CPACodexMessageRoleUser,
                sourceDependent, 7),
        ];
        NSArray<CPACodexMessage *> *secondAdditionalMessages = @[
            Message(@"t2-u4", @"2026-08-21T06:10:00Z", CPACodexMessageRoleUser,
                sourceDependent, 5),
        ];
        Assert([store importCodexMetadata:Metadata(@"builder-thread-1",
                    @"2026-08-21T01:00:00Z")
                messages:firstAdditionalMessages error:&error] != nil,
            @"应向第一会话增补来源删除夹具");
        Assert([store importCodexMetadata:Metadata(@"builder-thread-2",
                    @"2026-08-21T05:00:00Z")
                messages:secondAdditionalMessages error:&error] != nil,
            @"应向第二会话增补来源删除夹具");
        CPALocalExpressionBuildResult *result = [builder rebuildStore:store error:&error];
        records = [store loadActiveExpressions:&error];
        Assert(result != nil && error == nil && result.activeExpressionCount == 1
                && records.count == 1
                && [records[0].normalizedText isEqualToString:sourceDependent],
            @"新的跨会话表达应正常进入活跃库");
        Assert([store deleteSourceKind:@"codex" externalID:@"builder-thread-2"
                error:&error] && error == nil,
            @"应删除一个支持会话");
        result = [builder rebuildStore:store error:&error];
        records = [store loadActiveExpressions:&error];
        Assert(result != nil && error == nil && result.activeExpressionCount == 0
                && records.count == 0,
            @"删除支持会话后仅剩单会话的表达应消失");

        Assert([store close:&error] && error == nil, @"表达聚合数据库应安全关闭");
        [fileManager removeItemAtURL:base error:nil];
        NSLog(@"PASS: ExpressionLibraryBuilderTests");
    }
    return 0;
}
