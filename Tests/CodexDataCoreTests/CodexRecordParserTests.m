#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/CodexMessage.h"
#import "../../Sources/CodexDataCore/CodexRecordParser.h"
#import "../../Sources/CodexDataCore/CodexSourceMetadata.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSArray<NSData *> *LinesAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray<NSData *> *lines = [NSMutableArray array];
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0, len = parts.count; i < len; i++) {
        NSString *part = parts[i];
        if (part.length > 0) {
            [lines addObject:[part dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
    return lines;
}

int main(void) {
    @autoreleasepool {
        CPACodexRecordParser *parser = [[CPACodexRecordParser alloc] init];
        NSArray<NSData *> *rootLines = LinesAtPath(@"Tests/Fixtures/Codex/root-task.jsonl");
        NSError *error = nil;
        CPACodexSourceMetadata *metadata = [parser parseMetadataLineData:rootLines[0]
            error:&error];
        Assert(metadata != nil && error == nil, @"根任务元数据应可解析");
        Assert(metadata.isRootUserThread, @"thread_source=user 应识别为根任务");
        Assert([metadata.threadID isEqualToString:@"root-1"], @"应保留稳定 thread ID");

        NSMutableArray<CPACodexMessage *> *messages = [NSMutableArray array];
        for (NSUInteger i = 1, len = rootLines.count; i < len; i++) {
            CPACodexMessage *message = [parser parseMessageLineData:rootLines[i]
                lineNumber:i + 1
                lineStartOffset:i * 100
                error:&error];
            Assert(error == nil, @"已知或可忽略记录不应报错");
            if (message != nil) {
                [messages addObject:message];
            }
        }

        Assert(messages.count == 4, @"只应得到两条用户消息和两条助手消息");
        Assert([messages[0].messageID isEqualToString:@"u1"], @"应使用 payload.id");
        Assert(messages[0].role == CPACodexMessageRoleUser, @"首条消息应为用户角色");
        Assert([messages[0].text isEqualToString:@"hello"], @"用户正文应正确保留");
        Assert(messages[1].role == CPACodexMessageRoleAssistant, @"第二条应为助手角色");
        Assert([messages[1].text isEqualToString:@"reply"], @"助手正文应正确保留");
        Assert([messages[2].text isEqualToString:@"真正请求"],
            @"附件包装消息只应保留 My request 后的正文");
        Assert(messages[2].sourceLineNumber == 9, @"应保留来源行号");
        Assert(messages[2].sourceByteOffset == 800, @"应保留来源字节偏移");
        Assert([messages[3].messageID
                isEqualToString:@"legacy:2026-08-20T00:00:07Z:assistant:10"],
            @"旧格式缺少 payload.id 时应生成确定性后备 ID");
        Assert([messages[3].text isEqualToString:@"legacy reply"],
            @"旧格式可见消息正文仍应保留");

        NSArray<NSData *> *subagentLines = LinesAtPath(@"Tests/Fixtures/Codex/subagent-task.jsonl");
        CPACodexSourceMetadata *subagent = [parser parseMetadataLineData:subagentLines[0]
            error:&error];
        Assert(subagent != nil && !subagent.isRootUserThread,
            @"thread_source=subagent 必须被标记为非根任务");

        NSData *invalid = [@"not-json" dataUsingEncoding:NSUTF8StringEncoding];
        Assert([parser parseMetadataLineData:invalid error:&error] == nil && error != nil,
            @"损坏的元数据必须明确失败");

        NSLog(@"PASS: CodexRecordParserTests");
    }
    return 0;
}
