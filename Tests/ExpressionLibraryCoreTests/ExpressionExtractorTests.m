#import <Foundation/Foundation.h>

#import "../../Sources/ExpressionLibraryCore/ExpressionExtractor.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSArray<NSString *> *Texts(NSArray<CPAExtractedExpression *> *expressions) {
    return [expressions valueForKey:@"normalizedText"];
}

int main(void) {
    @autoreleasepool {
        CPAExpressionExtractor *extractor = [[CPAExpressionExtractor alloc] init];

        NSArray<NSString *> *natural = Texts([extractor expressionsFromText:
            @" 先别急着做，先把方案梳理清楚。\nPlease   review\tthis plan!\n好的 "
            containsSensitiveData:NO]);
        Assert([natural isEqualToArray:@[
            @"先别急着做，先把方案梳理清楚。",
            @"Please review this plan!",
        ]], @"应按句末和换行切分，并规范连续空白和长度");

        NSString *exactly159 = [@"甲" stringByPaddingToLength:159
            withString:@"甲" startingAtIndex:0];
        NSString *tooLong = [@"乙" stringByPaddingToLength:160
            withString:@"乙" startingAtIndex:0];
        NSString *lengthText = [NSString stringWithFormat:
            @"四字符。%@。%@。", exactly159, tooLong];
        NSArray<NSString *> *lengths = Texts([extractor expressionsFromText:lengthText
            containsSensitiveData:NO]);
        Assert(lengths.count == 2 && [lengths[0] isEqualToString:@"四字符。"]
                && [lengths[1] hasPrefix:exactly159],
            @"应保留 4～160 字符边界并排除超长句子");

        NSString *mixed = @"这是正常的自然语言。\n"
            "```objective-c\nNSString *value = @\"secret\";\n```\n"
            "请继续评估这个方案。\n"
            "访问 https://example.test/path 获取内容。\n"
            "/Users/demo/project/file.m\n"
            "{\"type\":\"message\",\"value\":1}\n"
            "2026-08-20 12:00:00 ERROR failed request\n"
            "const value = function(input);";
        NSArray<NSString *> *filtered = Texts([extractor expressionsFromText:mixed
            containsSensitiveData:NO]);
        Assert([filtered isEqualToArray:@[
            @"这是正常的自然语言。",
            @"请继续评估这个方案。",
        ]], @"代码、URL、路径、JSON 和日志不得进入表达候选");

        NSArray<CPAExtractedExpression *> *sensitive = [extractor expressionsFromText:
            @"这是一条看似正常但包含秘密的消息。" containsSensitiveData:YES];
        Assert(sensitive.count == 0, @"命中过敏感信息的整条消息必须排除");

        NSArray<NSString *> *deduplicated = Texts([extractor expressionsFromText:
            @"请先检查这个方案。请先检查这个方案。" containsSensitiveData:NO]);
        Assert([deduplicated isEqualToArray:@[@"请先检查这个方案。"]],
            @"同一消息中的完全相同句子只返回一次");

        NSLog(@"PASS: ExpressionExtractorTests");
    }
    return 0;
}
