#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/DataFoundationController.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"

@class CPALocalExpressionRecord;

@interface CPADataFoundationController (ExpressionBuildTesting)
- (nullable NSArray<CPALocalExpressionRecord *> *)buildExpressionRecordsForStore:
    (CPALocalDataStore *)store error:(NSError **)error;
@end

@interface CPAFailingExpressionController : CPADataFoundationController
@property(nonatomic) BOOL failExpressionBuild;
@end

@implementation CPAFailingExpressionController

- (NSArray<CPALocalExpressionRecord *> *)buildExpressionRecordsForStore:
    (CPALocalDataStore *)store error:(NSError **)error {
    if (!self.failExpressionBuild) {
        return [super buildExpressionRecordsForStore:store error:error];
    }
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"SyntheticExpressionBuildError"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"Synthetic expression build failure"}];
    }
    return nil;
}

@end

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
        bytes[i] = (uint8_t)(i + 71);
    }
    return data;
}

static NSData *JSONLine(NSDictionary *object) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object
        options:NSJSONWritingSortedKeys error:&error];
    Assert(json != nil && error == nil, @"合成 JSON 必须可序列化");
    NSMutableData *line = [json mutableCopy];
    const uint8_t newline = (uint8_t)'\n';
    [line appendBytes:&newline length:1];
    return line;
}

static NSDictionary *MetadataRecord(NSString *threadID, NSString *threadSource) {
    return @{
        @"timestamp": @"2026-08-20T00:00:00Z",
        @"type": @"session_meta",
        @"payload": @{
            @"id": threadID,
            @"thread_source": threadSource,
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

static void WriteThread(NSURL *url, NSString *threadID,
    NSString *threadSource, NSString *messageID, NSString *text) {
    NSMutableData *data = [NSMutableData data];
    [data appendData:JSONLine(MetadataRecord(threadID, threadSource))];
    [data appendData:JSONLine(MessageRecord(messageID, text))];
    NSError *error = nil;
    Assert([data writeToURL:url options:NSDataWritingAtomic error:&error],
        @"应写入合成 Codex 来源");
}

static BOOL StateIsTerminal(CPADataFoundationState state) {
    return state == CPADataFoundationStateSynced
        || state == CPADataFoundationStatePartialFailure
        || state == CPADataFoundationStatePaused;
}

static CPADataFoundationSnapshot *WaitForTerminal(CPADataFoundationController *controller,
    NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        CPADataFoundationSnapshot *snapshot = controller.currentSnapshot;
        if (StateIsTerminal(snapshot.state)) {
            return snapshot;
        }
        [NSThread sleepForTimeInterval:0.01];
    }
    return controller.currentSnapshot;
}

static CPADataFoundationController *Controller(NSURL *active, NSURL *archived,
    NSURL *databaseURL) {
    return [[CPADataFoundationController alloc]
        initWithActiveDirectory:active
        archivedDirectory:archived
        databaseURL:databaseURL
        masterKeyProvider:^NSData *(NSError **error) {
            if (error != NULL) {
                *error = nil;
            }
            return SyntheticMasterKey();
        }
        callbackQueue:dispatch_get_main_queue()];
}

static CPAFailingExpressionController *FailingController(NSURL *active,
    NSURL *archived, NSURL *databaseURL) {
    return [[CPAFailingExpressionController alloc]
        initWithActiveDirectory:active
        archivedDirectory:archived
        databaseURL:databaseURL
        masterKeyProvider:^NSData *(NSError **error) {
            if (error != NULL) {
                *error = nil;
            }
            return SyntheticMasterKey();
        }
        callbackQueue:dispatch_get_main_queue()];
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

        WriteThread([active URLByAppendingPathComponent:@"root.jsonl"],
            @"root-thread", @"user", @"root-message", @"private-root-body");
        WriteThread([active URLByAppendingPathComponent:@"subagent.jsonl"],
            @"subagent-thread", @"subagent", @"subagent-message", @"ignored-body");
        WriteThread([active URLByAppendingPathComponent:@"unknown.jsonl"],
            @"unknown-thread", @"future-source", @"unknown-message", @"ignored-body");
        Assert([@"not-json\n" writeToURL:[active URLByAppendingPathComponent:@"broken.jsonl"]
            atomically:YES encoding:NSUTF8StringEncoding error:&error],
            @"应写入损坏来源");
        WriteThread([archived URLByAppendingPathComponent:@"archived.jsonl"],
            @"archived-thread", @"user", @"archived-message", @"private-archive-body");
        WriteThread([archived URLByAppendingPathComponent:@"root-duplicate.jsonl"],
            @"root-thread", @"user", @"root-message", @"archive-preferred-body");

        NSURL *databaseURL = [[base URLByAppendingPathComponent:@"database" isDirectory:YES]
            URLByAppendingPathComponent:@"history.sqlite3"];
        CPADataFoundationController *controller = Controller(active, archived, databaseURL);
        Assert(controller.currentSnapshot.state == CPADataFoundationStateNotScanned,
            @"控制器初始状态应为未扫描");
        Assert(![fileManager fileExistsAtPath:databaseURL.path],
            @"创建控制器不得自动创建数据库或读取正文");

        Assert([controller startScan], @"首次扫描应成功排队");
        CPADataFoundationSnapshot *snapshot = WaitForTerminal(controller, 10.0);
        Assert(snapshot.state == CPADataFoundationStatePartialFailure,
            @"单个损坏文件应隔离并显示部分失败");
        Assert(snapshot.discoveredFileCount == 6 && snapshot.processedFileCount == 6,
            @"应对账六个合成来源");
        Assert(snapshot.succeededFileCount == 2 && snapshot.skippedFileCount == 2
                && snapshot.failedFileCount == 2,
            @"subagent 与重复来源应跳过，损坏和未知来源应失败");
        Assert(snapshot.insertedMessageCount == 2 && snapshot.storedMessageCount == 2,
            @"只应保存两个 root 用户任务的可见消息");
        CPALocalDataStore *verificationStore = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        NSString *preferredText = [verificationStore decryptedMessageTextForThreadID:
            @"root-thread" messageID:@"root-message" error:&error];
        Assert([preferredText isEqualToString:@"archive-preferred-body"],
            @"同一 thread ID 同时存在时必须只采用 archived 来源");
        Assert([verificationStore close:&error], @"归档优先验证数据库应安全关闭");
        NSString *diagnostic = snapshot.diagnosticSummary;
        Assert([diagnostic rangeOfString:@"private-root-body"].location == NSNotFound
                && [diagnostic rangeOfString:@"root.jsonl"].location == NSNotFound
                && [diagnostic rangeOfString:base.path].location == NSNotFound,
            @"诊断不得包含正文、文件名或本地路径");

        Assert([controller startScan], @"部分失败后应允许重扫");
        snapshot = WaitForTerminal(controller, 10.0);
        Assert(snapshot.state == CPADataFoundationStatePartialFailure
                && snapshot.insertedMessageCount == 0
                && snapshot.storedMessageCount == 2,
            @"重复扫描不得重复写入消息");

        NSURL *victimURL = [base URLByAppendingPathComponent:@"must-not-change.txt"];
        NSData *victimData = [@"unchanged" dataUsingEncoding:NSUTF8StringEncoding];
        Assert([victimData writeToURL:victimURL options:NSDataWritingAtomic error:&error],
            @"应写入符号链接防护夹具");
        NSURL *linkedDatabase = [base URLByAppendingPathComponent:@"linked.sqlite3"];
        Assert([fileManager createSymbolicLinkAtURL:linkedDatabase
            withDestinationURL:victimURL error:&error], @"应创建数据库符号链接夹具");
        CPADataFoundationController *linkedController = Controller(
            active, archived, linkedDatabase);
        Assert([linkedController startScan], @"符号链接防护扫描应成功排队");
        CPADataFoundationSnapshot *linkedSnapshot = WaitForTerminal(linkedController, 10.0);
        Assert(linkedSnapshot.state == CPADataFoundationStatePartialFailure
                && linkedSnapshot.succeededFileCount == 0
                && linkedSnapshot.insertedMessageCount == 0,
            @"数据库符号链接必须在读取正文前失败");
        Assert([[[NSData alloc] initWithContentsOfURL:victimURL]
                isEqualToData:victimData], @"数据库符号链接目标不得被改写");

        NSURL *expressionBase = [base URLByAppendingPathComponent:@"expressions"
            isDirectory:YES];
        NSURL *expressionActive = [expressionBase URLByAppendingPathComponent:@"active"
            isDirectory:YES];
        NSURL *expressionArchived = [expressionBase URLByAppendingPathComponent:@"archived"
            isDirectory:YES];
        Assert([fileManager createDirectoryAtURL:expressionActive
                withIntermediateDirectories:YES attributes:nil error:&error],
            @"应创建表达控制器 active 目录");
        Assert([fileManager createDirectoryAtURL:expressionArchived
                withIntermediateDirectories:YES attributes:nil error:&error],
            @"应创建表达控制器 archived 目录");
        NSString *learnedExpression = @"请先把方案梳理清楚。";
        WriteThread([expressionActive URLByAppendingPathComponent:@"first.jsonl"],
            @"expression-thread-1", @"user", @"expression-message-1",
            learnedExpression);
        WriteThread([expressionActive URLByAppendingPathComponent:@"second.jsonl"],
            @"expression-thread-2", @"user", @"expression-message-2",
            learnedExpression);
        NSURL *expressionDatabase = [expressionBase
            URLByAppendingPathComponent:@"history.sqlite3"];
        CPAFailingExpressionController *expressionController = FailingController(
            expressionActive, expressionArchived, expressionDatabase);
        Assert([expressionController startScan], @"表达学习扫描应成功排队");
        CPADataFoundationSnapshot *expressionSnapshot = WaitForTerminal(
            expressionController, 10.0);
        Assert(expressionSnapshot.state == CPADataFoundationStateSynced
                && expressionSnapshot.storedExpressionCount == 1
                && [expressionSnapshot.expressionBuildStatus isEqualToString:@"success"],
            @"全部来源成功后应自动构建一条表达");
        NSString *suffix = [expressionController suggestionForInput:@"请先把"
            cursorLocation:3 selectedLength:0];
        Assert([suffix isEqualToString:@"方案梳理清楚。"],
            @"控制器应从已发布内存索引返回本地后缀");
        NSString *expressionDiagnostic = expressionSnapshot.diagnosticSummary;
        Assert([expressionDiagnostic rangeOfString:learnedExpression].location == NSNotFound
                && [expressionDiagnostic rangeOfString:@"把方案梳理清楚。"]
                    .location == NSNotFound,
            @"表达诊断只能包含计数和构建状态");

        Assert([@"not-json\n" writeToURL:[expressionActive
                    URLByAppendingPathComponent:@"broken.jsonl"]
                atomically:YES encoding:NSUTF8StringEncoding error:&error],
            @"应写入部分失败表达夹具");
        Assert([expressionController startScan], @"部分失败重扫应成功排队");
        expressionSnapshot = WaitForTerminal(expressionController, 10.0);
        suffix = [expressionController suggestionForInput:@"请先把"
            cursorLocation:3 selectedLength:0];
        Assert(expressionSnapshot.state == CPADataFoundationStatePartialFailure
                && [expressionSnapshot.expressionBuildStatus
                    isEqualToString:@"skipped_partial"]
                && [suffix isEqualToString:@"方案梳理清楚。"],
            @"来源部分失败时必须保留上一个完整索引");
        [fileManager removeItemAtURL:[expressionActive
            URLByAppendingPathComponent:@"broken.jsonl"] error:&error];

        expressionController.failExpressionBuild = YES;
        Assert([expressionController startScan], @"构建失败重扫应成功排队");
        expressionSnapshot = WaitForTerminal(expressionController, 10.0);
        suffix = [expressionController suggestionForInput:@"请先把"
            cursorLocation:3 selectedLength:0];
        Assert(expressionSnapshot.state == CPADataFoundationStatePartialFailure
                && [expressionSnapshot.expressionBuildStatus isEqualToString:@"failed"]
                && [suffix isEqualToString:@"方案梳理清楚。"],
            @"表达构建失败时必须保留上一个完整索引");

        NSURL *pauseBase = [base URLByAppendingPathComponent:@"pause" isDirectory:YES];
        NSURL *pauseActive = [pauseBase URLByAppendingPathComponent:@"active" isDirectory:YES];
        NSURL *pauseArchived = [pauseBase URLByAppendingPathComponent:@"archived" isDirectory:YES];
        Assert([fileManager createDirectoryAtURL:pauseActive withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建暂停测试 active 目录");
        Assert([fileManager createDirectoryAtURL:pauseArchived withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建暂停测试 archived 目录");
        for (NSUInteger i = 0; i < 200; i++) {
            NSString *threadID = [NSString stringWithFormat:@"pause-thread-%lu",
                (unsigned long)i];
            NSString *filename = [NSString stringWithFormat:@"%04lu.jsonl",
                (unsigned long)i];
            WriteThread([pauseActive URLByAppendingPathComponent:filename],
                threadID, @"user", [@"message-" stringByAppendingString:threadID], @"body");
        }
        NSURL *pauseDatabase = [pauseBase URLByAppendingPathComponent:@"history.sqlite3"];
        CPADataFoundationController *pauseController = Controller(
            pauseActive, pauseArchived, pauseDatabase);
        Assert([pauseController startScan], @"暂停测试扫描应成功排队");
        [pauseController requestPause];
        CPADataFoundationSnapshot *paused = WaitForTerminal(pauseController, 10.0);
        Assert(paused.state == CPADataFoundationStatePaused,
            @"请求暂停后应在文件边界进入已暂停");
        Assert([pauseController resumeScan], @"已暂停扫描应可继续");
        CPADataFoundationSnapshot *resumed = WaitForTerminal(pauseController, 20.0);
        Assert(resumed.state == CPADataFoundationStateSynced
                && resumed.storedMessageCount == 200,
            @"继续后应幂等完成全部来源");

        [fileManager removeItemAtURL:base error:nil];
        NSLog(@"PASS: DataFoundationControllerTests");
    }
    return 0;
}
