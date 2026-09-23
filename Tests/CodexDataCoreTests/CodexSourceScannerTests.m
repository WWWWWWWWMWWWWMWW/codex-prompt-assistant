#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/CodexSourceScanner.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void CopyFixture(NSString *name, NSURL *destination) {
    NSString *sourcePath = [@"Tests/Fixtures/Codex" stringByAppendingPathComponent:name];
    NSError *error = nil;
    Assert([[NSFileManager defaultManager] copyItemAtPath:sourcePath
        toPath:destination.path
        error:&error], [NSString stringWithFormat:@"复制夹具失败：%@", error]);
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
            isDirectory:YES];
        NSURL *active = [base URLByAppendingPathComponent:@"sessions" isDirectory:YES];
        NSURL *archived = [base URLByAppendingPathComponent:@"archived_sessions" isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:active
            withIntermediateDirectories:YES attributes:nil error:&error], @"应创建 active 目录");
        Assert([fileManager createDirectoryAtURL:archived
            withIntermediateDirectories:YES attributes:nil error:&error], @"应创建 archived 目录");

        NSURL *nested = [active URLByAppendingPathComponent:@"2026/08/20" isDirectory:YES];
        Assert([fileManager createDirectoryAtURL:nested
            withIntermediateDirectories:YES attributes:nil error:&error], @"应创建嵌套目录");
        CopyFixture(@"root-task.jsonl", [nested URLByAppendingPathComponent:@"root.jsonl"]);
        NSURL *subagentURL = [active URLByAppendingPathComponent:@"subagent.jsonl"];
        CopyFixture(@"subagent-task.jsonl", subagentURL);
        NSFileHandle *subagentHandle = [NSFileHandle fileHandleForWritingToURL:subagentURL error:&error];
        unsigned long long subagentEndOffset = 0;
        Assert([subagentHandle seekToEndReturningOffset:&subagentEndOffset error:&error]
                && subagentEndOffset > 0 && error == nil,
            @"应定位子代理夹具末尾");
        NSMutableData *irrelevantSubagentTail = [NSMutableData dataWithLength:1024 * 1024];
        [subagentHandle writeData:irrelevantSubagentTail error:&error];
        [subagentHandle closeFile];
        Assert(error == nil, @"应追加无需读取的子代理内容");

        NSURL *archivedRoot = [archived URLByAppendingPathComponent:@"root-archived.jsonl"];
        CopyFixture(@"root-task.jsonl", archivedRoot);
        NSFileHandle *appendHandle = [NSFileHandle fileHandleForWritingToURL:archivedRoot error:&error];
        Assert(appendHandle != nil, @"应打开归档夹具");
        unsigned long long endOffset = 0;
        Assert([appendHandle seekToEndReturningOffset:&endOffset error:&error]
                && endOffset > 0 && error == nil,
            @"应定位归档夹具末尾");
        NSData *extra = [@"{\"type\":\"response_item\",\"timestamp\":\"2026-08-20T00:00:07Z\",\"payload\":{\"type\":\"message\",\"id\":\"a2\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"archived reply\"}]}}\n{\"incomplete\""
            dataUsingEncoding:NSUTF8StringEncoding];
        [appendHandle writeData:extra error:&error];
        [appendHandle closeFile];
        Assert(error == nil, @"应追加归档消息与半行");

        [@"broken metadata\n" writeToURL:[archived URLByAppendingPathComponent:@"broken.jsonl"]
            atomically:YES encoding:NSUTF8StringEncoding error:&error];
        Assert(error == nil, @"应写入损坏夹具");
        [@"ignored" writeToURL:[active URLByAppendingPathComponent:@"notes.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:&error];

        CPACodexSourceScanner *scanner = [[CPACodexSourceScanner alloc] init];
        CPACodexScanReport *report = [scanner scanActiveDirectory:active
            archivedDirectory:archived
            error:&error];
        Assert(report != nil && error == nil, @"来源扫描不应整体失败");
        Assert(report.discoveredJSONLCount == 4, @"只应发现四个 JSONL 文件");
        Assert(report.rootThreadCount == 1, @"同一根任务 active/archived 只计一次");
        Assert(report.subagentThreadCount == 1, @"应排除并统计一个子代理");
        Assert(report.unsupportedSourceCount == 1, @"损坏首行应计入 unsupported");
        Assert(report.duplicateThreadCount == 1, @"应识别 active/archived 重复 thread ID");
        Assert(report.visibleMessageCount == 5, @"应优先采用归档副本的五条可见消息");
        Assert(report.trailingPartialFileCount == 1, @"末尾半行应报告但不解析");
        Assert(report.messageParseErrorCount == 0, @"半行不应成为解析错误");
        Assert(report.inspectedByteCount < 128 * 1024,
            @"识别为子代理后不得继续检查其大体积余下内容");

        [fileManager removeItemAtURL:base error:nil];
        NSLog(@"PASS: CodexSourceScannerTests");
    }
    return 0;
}
