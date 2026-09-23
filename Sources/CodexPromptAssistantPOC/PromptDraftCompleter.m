#import "PromptDraftCompleter.h"

static const NSUInteger CPAPromptDraftMinimumInputLength = 6;
static const NSUInteger CPAPromptDraftMinimumShortPerformanceInputLength = 3;
static const NSUInteger CPAPromptDraftMaximumTailLength = 160;

@interface CPAPromptDraftCompleter ()
@property(nonatomic, strong) NSCharacterSet *sentenceEndingCharacters;
@property(nonatomic, strong) NSCharacterSet *clauseEndingCharacters;
@property(nonatomic, strong) NSRegularExpression *performanceDurationPattern;
@end

@implementation CPAPromptDraftCompleter

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _sentenceEndingCharacters = [NSCharacterSet
            characterSetWithCharactersInString:@"。！？!?"];
        _clauseEndingCharacters = [NSCharacterSet
            characterSetWithCharactersInString:@"，,、；;：:"];
        NSError *patternError = nil;
        _performanceDurationPattern = [NSRegularExpression
            regularExpressionWithPattern:@"[0-9]+(?:\\.[0-9]+)?\\s*(?:s|秒)"
            options:NSRegularExpressionCaseInsensitive error:&patternError];
        NSCAssert(_performanceDurationPattern != nil && patternError == nil,
            @"Built-in duration pattern must compile");
    }
    return self;
}

- (NSString *)suggestionForInput:(NSString *)input
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength {
    if (selectedLength != 0 || cursorLocation != input.length
        || input.length < CPAPromptDraftMinimumShortPerformanceInputLength) {
        return nil;
    }
    NSUInteger tailStart = input.length > CPAPromptDraftMaximumTailLength
        ? input.length - CPAPromptDraftMaximumTailLength : 0;
    NSString *tail = [input substringFromIndex:tailStart];
    if ([self containsAny:@[
            @"量化各阶段耗时", @"验收数据", @"当前对话上下文",
            @"可直接作为 AI 指令", @"最小修改方案", @"目标、范围、关键流程",
            @"问题、原因、影响、修改建议", @"效果、成本、风险和适用场景",
        ] inText:tail]) {
        return nil;
    }

    BOOL explicitPerformanceIntent = [self containsAny:@[
            @"慢", @"速度", @"响应", @"延迟", @"实时", @"1秒", @"1s",
            @"一秒", @"耗时", @"性能",
        ] inText:tail]
        || [self.performanceDurationPattern firstMatchInString:tail options:0
            range:NSMakeRange(0, tail.length)] != nil;
    if (!explicitPerformanceIntent
        && input.length < CPAPromptDraftMinimumInputLength) {
        return nil;
    }

    NSString *body = nil;
    if (explicitPerformanceIntent) {
        body = @"请量化各阶段耗时，定位主要瓶颈，并给出不降低补全质量的优化方案和验收数据。";
    } else if ([self containsAny:@[
            @"补全", @"续写", @"提示词", @"提示内容", @"灰字",
        ] inText:tail]) {
        body = @"请结合当前对话上下文继续补充具体要求，确保结果可直接作为 AI 指令使用。";
    } else if ([self containsAny:@[
            @"为什么", @"问题", @"错误", @"失败", @"异常", @"不显示",
            @"没有提示", @"不能", @"用不了", @"失效",
        ] inText:tail]) {
        body = @"请先定位根因和复现条件，再给出最小修改方案及验证结果。";
    } else if ([self containsAny:@[
            @"对比", @"比较", @"哪个好", @"区别", @"选择哪",
        ] inText:tail]) {
        body = @"请从效果、成本、风险和适用场景进行对比，并给出明确结论。";
    } else if ([self containsAny:@[
            @"设计", @"方案", @"规划", @"策划", @"架构",
        ] inText:tail]) {
        body = @"请先梳理目标、范围、关键流程、风险和验收标准，再给出可执行方案。";
    } else if ([self containsAny:@[
            @"实现", @"修复", @"优化", @"改进", @"开发", @"增加", @"支持",
        ] inText:tail]) {
        body = @"请直接实施最小范围修改，并说明验证结果、剩余风险和后续优化方向。";
    } else if ([self containsAny:@[
            @"分析", @"检查", @"评估", @"排查", @"审查", @"梳理",
        ] inText:tail]) {
        body = @"请按问题、原因、影响、修改建议和验收标准分项整理。";
    } else if ([self containsAny:@[
            @"写一份", @"撰写", @"整理成", @"总结", @"改写",
        ] inText:tail]) {
        body = @"请保持结构清晰、语言简洁，并输出可直接使用的完整版本。";
    }
    if (body.length == 0) {
        return nil;
    }
    unichar finalCharacter = [tail characterAtIndex:tail.length - 1];
    if ([self.sentenceEndingCharacters characterIsMember:finalCharacter]) {
        return [@"同时，" stringByAppendingString:body];
    }
    if ([self.clauseEndingCharacters characterIsMember:finalCharacter]) {
        return [@"并" stringByAppendingString:body];
    }
    return [@"，" stringByAppendingString:body];
}

- (BOOL)containsAny:(NSArray<NSString *> *)needles inText:(NSString *)text {
    for (NSUInteger index = 0, count = needles.count; index < count; index++) {
        if ([text rangeOfString:needles[index] options:NSCaseInsensitiveSearch].location
            != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

@end
