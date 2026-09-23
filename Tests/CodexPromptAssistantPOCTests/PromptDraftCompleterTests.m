#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/PromptDraftCompleter.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        CPAPromptDraftCompleter *completer = [[CPAPromptDraftCompleter alloc] init];

        NSString *input = @"现在出现的速度还是太慢了，能做到1秒以内吗";
        NSString *suggestion = [completer suggestionForInput:input
            cursorLocation:input.length selectedLength:0];
        Assert([suggestion containsString:@"量化各阶段耗时"]
                && [suggestion containsString:@"验收数据"],
            @"性能请求应即时补充定位方法和量化验收要求");

        input = @"还是3s啊";
        suggestion = [completer suggestionForInput:input
            cursorLocation:input.length selectedLength:0];
        Assert([suggestion containsString:@"量化各阶段耗时"],
            @"包含任意秒数的短性能反馈也应进入亚秒快速通道");

        input = @"提示的内容不是续写我的话";
        suggestion = [completer suggestionForInput:input
            cursorLocation:input.length selectedLength:0];
        Assert([suggestion containsString:@"当前对话上下文"]
                && [suggestion containsString:@"AI 指令"],
            @"补全质量请求应使用 AI 提示词语言继续约束结果");

        input = @"这个错误为什么一直出现？";
        suggestion = [completer suggestionForInput:input
            cursorLocation:input.length selectedLength:0];
        Assert([suggestion hasPrefix:@"同时，"]
                && [suggestion containsString:@"定位根因"],
            @"完整问句后应以新句承接诊断要求而不是错误拼接逗号");

        input = @"请设计一个新的活动方案";
        suggestion = [completer suggestionForInput:input
            cursorLocation:input.length selectedLength:0];
        Assert([suggestion containsString:@"目标、范围、关键流程"]
                && [suggestion containsString:@"验收标准"],
            @"设计请求应即时补充可执行方案结构");

        input = @"今天下午去开会";
        Assert([completer suggestionForInput:input cursorLocation:input.length
                    selectedLength:0] == nil,
            @"普通陈述不应触发通用模板造成无关提示");

        input = @"请继续优化，并给出验收数据";
        Assert([completer suggestionForInput:input cursorLocation:input.length
                    selectedLength:0] == nil,
            @"已经包含模板验收要求时不应循环追加同类内容");

        input = @"请优化这个方案";
        Assert([completer suggestionForInput:input cursorLocation:2 selectedLength:0]
                    == nil
                && [completer suggestionForInput:input cursorLocation:input.length
                    selectedLength:1] == nil,
            @"本地预补全只允许光标位于末尾且没有选区");

        NSDate *started = [NSDate date];
        for (NSUInteger index = 0; index < 1000; index++) {
            input = @"继续优化响应速度";
            (void)[completer suggestionForInput:input
                cursorLocation:input.length selectedLength:0];
        }
        NSTimeInterval elapsed = -[started timeIntervalSinceNow];
        Assert(elapsed < 0.1, @"本地预补全一千次应在 100ms 内完成");

        NSLog(@"PASS: PromptDraftCompleterTests");
    }
    return 0;
}
