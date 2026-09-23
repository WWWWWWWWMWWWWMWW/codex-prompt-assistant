#import "ExpressionSuggestionIndex.h"

#import "../CodexDataCore/LocalExpressionRecord.h"

@implementation CPAExpressionSuggestion

- (instancetype)initWithFullText:(NSString *)fullText
    insertionText:(NSString *)insertionText {
    self = [super init];
    if (self != nil) {
        _fullText = [fullText copy];
        _insertionText = [insertionText copy];
    }
    return self;
}

@end

@interface CPAExpressionSuggestionIndex ()
@property(nonatomic, copy) NSDictionary<NSString *,
    NSArray<CPALocalExpressionRecord *> *> *groups;
@property(nonatomic, strong) NSCharacterSet *sentenceBoundaryCharacters;
@end

@implementation CPAExpressionSuggestionIndex

- (instancetype)initWithExpressions:(NSArray<CPALocalExpressionRecord *> *)expressions {
    self = [super init];
    if (self != nil) {
        NSArray<CPALocalExpressionRecord *> *ranked = [expressions
            sortedArrayUsingComparator:^NSComparisonResult(
                CPALocalExpressionRecord *first,
                CPALocalExpressionRecord *second) {
                if (first.conversationCount != second.conversationCount) {
                    return first.conversationCount > second.conversationCount
                        ? NSOrderedAscending : NSOrderedDescending;
                }
                if (first.occurrenceCount != second.occurrenceCount) {
                    return first.occurrenceCount > second.occurrenceCount
                        ? NSOrderedAscending : NSOrderedDescending;
                }
                NSComparisonResult timestampOrder = [second.lastSourceTimestamp
                    compare:first.lastSourceTimestamp options:NSLiteralSearch];
                if (timestampOrder != NSOrderedSame) {
                    return timestampOrder;
                }
                return [first.normalizedText compare:second.normalizedText
                    options:NSLiteralSearch];
            }];
        NSMutableDictionary<NSString *,
            NSMutableArray<CPALocalExpressionRecord *> *> *mutableGroups =
            [NSMutableDictionary dictionary];
        for (NSUInteger i = 0, len = ranked.count; i < len; i++) {
            CPALocalExpressionRecord *record = ranked[i];
            if (record.normalizedText.length == 0) {
                continue;
            }
            NSRange firstRange = [record.normalizedText
                rangeOfComposedCharacterSequenceAtIndex:0];
            NSString *key = [record.normalizedText substringWithRange:firstRange];
            NSMutableArray<CPALocalExpressionRecord *> *group = mutableGroups[key];
            if (group == nil) {
                group = [NSMutableArray array];
                mutableGroups[key] = group;
            }
            [group addObject:record];
        }
        NSMutableDictionary<NSString *, NSArray<CPALocalExpressionRecord *> *>
            *immutableGroups = [NSMutableDictionary dictionary];
        NSArray<NSString *> *keys = mutableGroups.allKeys;
        for (NSUInteger i = 0, len = keys.count; i < len; i++) {
            NSString *key = keys[i];
            immutableGroups[key] = [mutableGroups[key] copy];
        }
        _groups = [immutableGroups copy];
        _sentenceBoundaryCharacters = [NSCharacterSet
            characterSetWithCharactersInString:@"\n\r。！？!?；;"];
    }
    return self;
}

- (CPAExpressionSuggestion *)suggestionForInput:(NSString *)input
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength {
    if (selectedLength > 0 || cursorLocation > input.length || cursorLocation == 0) {
        return nil;
    }
    NSString *beforeCursor = [input substringToIndex:cursorLocation];
    NSRange boundary = [beforeCursor rangeOfCharacterFromSet:
        self.sentenceBoundaryCharacters options:NSBackwardsSearch];
    NSUInteger start = boundary.location == NSNotFound
        ? 0 : NSMaxRange(boundary);
    NSString *prefix = [beforeCursor substringFromIndex:start];
    NSUInteger firstNonWhitespace = 0;
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceCharacterSet;
    while (firstNonWhitespace < prefix.length
            && [whitespace characterIsMember:
                [prefix characterAtIndex:firstNonWhitespace]]) {
        firstNonWhitespace++;
    }
    if (firstNonWhitespace > 0) {
        prefix = [prefix substringFromIndex:firstNonWhitespace];
    }
    if (![self prefixIsLongEnough:prefix]) {
        return nil;
    }
    NSRange firstRange = [prefix rangeOfComposedCharacterSequenceAtIndex:0];
    NSString *key = [prefix substringWithRange:firstRange];
    NSArray<CPALocalExpressionRecord *> *group = self.groups[key];
    for (NSUInteger i = 0, len = group.count; i < len; i++) {
        NSString *fullText = group[i].normalizedText;
        if (![fullText hasPrefix:prefix] || fullText.length == prefix.length) {
            continue;
        }
        NSString *insertionText = [fullText substringFromIndex:prefix.length];
        return [[CPAExpressionSuggestion alloc] initWithFullText:fullText
            insertionText:insertionText];
    }
    return nil;
}

- (BOOL)prefixIsLongEnough:(NSString *)prefix {
    if (prefix.length == 0) {
        return NO;
    }
    BOOL isASCII = YES;
    for (NSUInteger i = 0, len = prefix.length; i < len; i++) {
        if ([prefix characterAtIndex:i] > 0x7f) {
            isASCII = NO;
            break;
        }
    }
    // Two-character CJK prefixes are often generic connectors (for example,
    // “但是” or “然后”).  A history expression can share that prefix while
    // still being unrelated to the clause the user is writing.  Keep the
    // local path conservative; the remote completion path handles the
    // shorter input with the full typed text and conversation context.
    if (prefix.length < 3) {
        return NO;
    }
    if (isASCII) {
        return YES;
    }

    NSArray<NSString *> *genericPrefixes = @[
        @"但是", @"而且", @"然后", @"所以", @"因为", @"如果", @"现在",
        @"可以", @"需要", @"建议", @"这个", @"另外", @"不过",
    ];
    for (NSUInteger i = 0, len = genericPrefixes.count; i < len; i++) {
        NSString *genericPrefix = genericPrefixes[i];
        if ([prefix hasPrefix:genericPrefix]
            && prefix.length < genericPrefix.length + 3) {
            return NO;
        }
    }
    return YES;
}

@end
