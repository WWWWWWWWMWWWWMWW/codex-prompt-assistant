#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/LocalExpressionRecord.h"
#import "../../Sources/ExpressionLibraryCore/ExpressionSuggestionIndex.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPALocalExpressionRecord *Record(NSString *text, NSUInteger occurrenceCount,
    NSUInteger conversationCount, NSString *timestamp) {
    return [[CPALocalExpressionRecord alloc] initWithNormalizedText:text
        occurrenceCount:occurrenceCount
        conversationCount:conversationCount
        lastSourceTimestamp:timestamp
        extractorVersion:1];
}

int main(void) {
    @autoreleasepool {
        CPALocalExpressionRecord *frequent = Record(@"方案先整理清楚。", 5, 2,
            @"2026-08-20T01:00:00Z");
        CPALocalExpressionRecord *lessFrequent = Record(@"方案先继续讨论。", 2, 2,
            @"2026-08-21T09:00:00Z");
        CPALocalExpressionRecord *recent = Record(@"请继续确认新方案。", 3, 2,
            @"2026-08-21T09:00:00Z");
        CPALocalExpressionRecord *older = Record(@"请继续检查旧方案。", 3, 2,
            @"2026-08-20T09:00:00Z");
        CPALocalExpressionRecord *genericBut = Record(@"但是玩游戏的时候注意是在上面。", 9, 4,
            @"2026-08-21T09:00:00Z");
        CPALocalExpressionRecord *english = Record(@"Please review this plan.", 4, 3,
            @"2026-08-21T08:00:00Z");
        NSMutableArray<CPALocalExpressionRecord *> *source = [@[
            lessFrequent, older, english, frequent, recent, genericBut,
        ] mutableCopy];
        CPAExpressionSuggestionIndex *index = [[CPAExpressionSuggestionIndex alloc]
            initWithExpressions:source];

        Assert([index suggestionForInput:@"请" cursorLocation:1 selectedLength:0] == nil,
            @"中文不足两字时不应提示");
        Assert([index suggestionForInput:@"请继" cursorLocation:2 selectedLength:0] == nil,
            @"只有两个中文字符时不应把低信息前缀当成可靠候选");
        CPAExpressionSuggestion *suggestion = [index suggestionForInput:@"请继续"
            cursorLocation:3 selectedLength:0];
        Assert([suggestion.fullText isEqualToString:@"请继续确认新方案。"]
                && [suggestion.insertionText isEqualToString:@"确认新方案。"],
            @"相同频次时应选最近使用表达并只返回后缀");

        suggestion = [index suggestionForInput:@"方案先"
            cursorLocation:3 selectedLength:0];
        Assert([suggestion.fullText isEqualToString:@"方案先整理清楚。"],
            @"同前缀表达应先按真实出现频次排序");

        Assert([index suggestionForInput:@"但是" cursorLocation:2 selectedLength:0] == nil,
            @"通用转折词不足上下文时不得显示无关的本地历史表达");

        Assert([index suggestionForInput:@"Pl" cursorLocation:2 selectedLength:0] == nil,
            @"ASCII 不足三字符时不应提示");
        Assert([index suggestionForInput:@"Ple " cursorLocation:4 selectedLength:0] == nil,
            @"用户已输入的末尾空格不得被静默删除后再匹配");
        suggestion = [index suggestionForInput:@"Please trailing text"
            cursorLocation:3 selectedLength:0];
        Assert([suggestion.fullText isEqualToString:@"Please review this plan."]
                && [suggestion.insertionText isEqualToString:@"ase review this plan."],
            @"查询必须只读取光标前文本");

        Assert([index suggestionForInput:@"方案先" cursorLocation:3 selectedLength:1]
                == nil,
            @"存在选中文本时不应提示");
        suggestion = [index suggestionForInput:@"前文。  请继续"
            cursorLocation:8 selectedLength:0];
        Assert([suggestion.fullText isEqualToString:@"请继续确认新方案。"],
            @"句末标点后应只用当前句前缀匹配");
        Assert([index suggestionForInput:frequent.normalizedText
                    cursorLocation:frequent.normalizedText.length selectedLength:0] == nil,
            @"输入已是完整表达时不应返回空后缀");
        NSString *noMatch = @"完全不匹配";
        Assert([index suggestionForInput:noMatch
                    cursorLocation:noMatch.length selectedLength:0] == nil,
            @"没有匹配时不应生成任何提示");
        Assert([index suggestionForInput:@"请继" cursorLocation:99 selectedLength:0]
                == nil,
            @"越界光标位置必须安全失败");

        [source removeAllObjects];
        [source addObject:Record(@"请继续改成另一条。", 99, 9,
            @"2026-08-21T10:00:00Z")];
        suggestion = [index suggestionForInput:@"请继续"
            cursorLocation:3 selectedLength:0];
        Assert([suggestion.fullText isEqualToString:@"请继续确认新方案。"],
            @"索引发布后不得被外部可变数组篡改");
        CPAExpressionSuggestionIndex *replacement = [[CPAExpressionSuggestionIndex alloc]
            initWithExpressions:source];
        suggestion = [replacement suggestionForInput:@"请继续"
            cursorLocation:3 selectedLength:0];
        Assert([suggestion.fullText isEqualToString:@"请继续改成另一条。"],
            @"新快照应通过创建新的不可变索引发布");

        NSLog(@"PASS: ExpressionSuggestionIndexTests");
    }
    return 0;
}
