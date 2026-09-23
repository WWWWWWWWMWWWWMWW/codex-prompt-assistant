#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/JSONLLineReader.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSURL *CreateTemporaryFile(NSData *data) {
    NSString *name = [NSString stringWithFormat:@"cpa-jsonl-%@.jsonl", NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    Assert([data writeToURL:url atomically:YES], @"应能创建 JSONL 测试文件");
    return url;
}

int main(void) {
    @autoreleasepool {
        NSMutableString *longLine = [NSMutableString stringWithCapacity:70 * 1024];
        for (NSUInteger i = 0; i < 70 * 1024; i++) {
            [longLine appendString:@"x"];
        }
        NSString *initialText = [NSString stringWithFormat:
            @"first\r\n%@\nthird-without-newline", longLine];
        NSData *initialData = [initialText dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *url = CreateTemporaryFile(initialData);

        CPAJSONLLineReader *reader = [[CPAJSONLLineReader alloc] initWithChunkSize:1024];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSError *error = nil;
        CPAJSONLReadResult *result = [reader readURL:url
            startingAtOffset:0
            lineHandler:^BOOL(NSData *lineData, uint64_t lineStartOffset, NSUInteger lineNumber,
                NSError **handlerError) {
                (void)lineStartOffset;
                (void)lineNumber;
                (void)handlerError;
                NSString *line = [[NSString alloc] initWithData:lineData
                    encoding:NSUTF8StringEncoding];
                [lines addObject:line];
                return YES;
            }
            error:&error];

        Assert(result != nil && error == nil, @"首次读取不应失败");
        Assert(lines.count == 2, @"末尾半行不得交给解析器");
        Assert([lines[0] isEqualToString:@"first"], @"应去除 CRLF 的回车字符");
        Assert([lines[1] isEqualToString:longLine], @"跨多个 chunk 的长行必须完整");
        Assert(result.trailingByteCount == [@"third-without-newline"
            lengthOfBytesUsingEncoding:NSUTF8StringEncoding], @"应报告半行字节数");
        Assert(result.inspectedByteCount == initialData.length,
            @"流式扫描必须保证每个输入字节最多检查一次");

        NSMutableData *completedData = [initialData mutableCopy];
        [completedData appendData:[@"\nfourth\n" dataUsingEncoding:NSUTF8StringEncoding]];
        Assert([completedData writeToURL:url atomically:YES], @"应能补全测试文件");

        [lines removeAllObjects];
        CPAJSONLReadResult *resumed = [reader readURL:url
            startingAtOffset:result.safeOffset
            lineHandler:^BOOL(NSData *lineData, uint64_t lineStartOffset, NSUInteger lineNumber,
                NSError **handlerError) {
                (void)lineStartOffset;
                (void)lineNumber;
                (void)handlerError;
                NSString *line = [[NSString alloc] initWithData:lineData
                    encoding:NSUTF8StringEncoding];
                [lines addObject:line];
                return YES;
            }
            error:&error];

        Assert(resumed != nil && error == nil, @"断点续读不应失败");
        Assert([lines isEqualToArray:@[@"third-without-newline", @"fourth"]],
            @"续读应从最后一个安全偏移重新处理半行");
        Assert(resumed.trailingByteCount == 0, @"补全后不应剩余半行");
        Assert(resumed.safeOffset == completedData.length, @"安全偏移应到达文件末尾");

        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        NSLog(@"PASS: JSONLLineReaderTests");
    }
    return 0;
}
