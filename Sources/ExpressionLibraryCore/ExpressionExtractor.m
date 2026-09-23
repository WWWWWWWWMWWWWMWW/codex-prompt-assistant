#import "ExpressionExtractor.h"

@interface CPAExtractedExpression ()
@property(nonatomic, copy, readwrite) NSString *normalizedText;
@end

@implementation CPAExtractedExpression

- (instancetype)initWithNormalizedText:(NSString *)normalizedText {
    self = [super init];
    if (self != nil) {
        _normalizedText = [normalizedText copy];
    }
    return self;
}

@end

@interface CPAExpressionExtractor ()
@property(nonatomic, strong) NSRegularExpression *whitespacePattern;
@property(nonatomic, strong) NSArray<NSRegularExpression *> *noisePatterns;
@property(nonatomic, strong) NSCharacterSet *sentenceEndCharacters;
@property(nonatomic, strong) NSCharacterSet *programSymbolCharacters;
@end

@implementation CPAExpressionExtractor

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _whitespacePattern = [NSRegularExpression regularExpressionWithPattern:@"\\s+"
            options:0 error:NULL];
        NSArray<NSString *> *patterns = @[
            @"(?i)(?:https?|ftp)://|\\bwww\\.",
            @"^(?:/|~/|[A-Za-z]:\\\\)",
            @"^(?:\\{|\\[).*(?:\\\"[^\\\"]+\\\"\\s*:)",
            @"^(?:\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}|\\[?(?:DEBUG|INFO|WARN|ERROR|TRACE|FATAL)\\]?[\\s:])",
            @"(?i)^(?:const|let|var|class|function|def|import|from|#import|#include|NSString|SELECT|INSERT|UPDATE|DELETE)\\b",
            @"^<[^>]+>$",
        ];
        NSMutableArray<NSRegularExpression *> *compiled = [NSMutableArray array];
        for (NSUInteger i = 0, len = patterns.count; i < len; i++) {
            NSRegularExpression *pattern = [NSRegularExpression
                regularExpressionWithPattern:patterns[i] options:0 error:NULL];
            [compiled addObject:pattern];
        }
        _noisePatterns = [compiled copy];
        _sentenceEndCharacters = [NSCharacterSet characterSetWithCharactersInString:
            @"。！？!?；;"];
        _programSymbolCharacters = [NSCharacterSet characterSetWithCharactersInString:
            @"{}[]()=<>/\\|&$@#^*~`"];
    }
    return self;
}

- (NSArray<CPAExtractedExpression *> *)expressionsFromText:(NSString *)text
    containsSensitiveData:(BOOL)containsSensitiveData {
    if (containsSensitiveData || text.length == 0) {
        return @[];
    }
    NSMutableArray<CPAExtractedExpression *> *expressions = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet];
    BOOL insideCodeFence = NO;
    for (NSUInteger lineIndex = 0, lineCount = lines.count;
            lineIndex < lineCount; lineIndex++) {
        NSString *line = lines[lineIndex];
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        if ([trimmedLine hasPrefix:@"```"]) {
            insideCodeFence = !insideCodeFence;
            continue;
        }
        if (insideCodeFence || trimmedLine.length == 0) {
            continue;
        }
        NSArray<NSString *> *sentences = [self sentencesFromLine:line];
        for (NSUInteger sentenceIndex = 0, sentenceCount = sentences.count;
                sentenceIndex < sentenceCount; sentenceIndex++) {
            NSString *normalized = [self normalizedCandidate:sentences[sentenceIndex]];
            if (![self isLearnableCandidate:normalized] || [seen containsObject:normalized]) {
                continue;
            }
            [seen addObject:normalized];
            [expressions addObject:[[CPAExtractedExpression alloc]
                initWithNormalizedText:normalized]];
        }
    }
    return expressions;
}

- (NSArray<NSString *> *)sentencesFromLine:(NSString *)line {
    NSMutableArray<NSString *> *sentences = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    for (NSUInteger i = 0, len = line.length; i < len; i++) {
        unichar character = [line characterAtIndex:i];
        [current appendFormat:@"%C", character];
        if ([self.sentenceEndCharacters characterIsMember:character]) {
            [sentences addObject:[current copy]];
            [current setString:@""];
        }
    }
    if (current.length > 0) {
        [sentences addObject:[current copy]];
    }
    return sentences;
}

- (NSString *)normalizedCandidate:(NSString *)candidate {
    NSString *collapsed = [self.whitespacePattern stringByReplacingMatchesInString:candidate
        options:0 range:NSMakeRange(0, candidate.length) withTemplate:@" "];
    return [collapsed stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (BOOL)isLearnableCandidate:(NSString *)candidate {
    if (candidate.length < 4 || candidate.length > 160
        || [candidate containsString:@"`"] || [candidate containsString:@"/"]
        || [candidate containsString:@"\\"]) {
        return NO;
    }
    NSRange fullRange = NSMakeRange(0, candidate.length);
    for (NSUInteger i = 0, len = self.noisePatterns.count; i < len; i++) {
        if ([self.noisePatterns[i] firstMatchInString:candidate
                options:0 range:fullRange] != nil) {
            return NO;
        }
    }
    NSUInteger programSymbolCount = 0;
    for (NSUInteger i = 0, len = candidate.length; i < len; i++) {
        if ([self.programSymbolCharacters characterIsMember:
                [candidate characterAtIndex:i]]) {
            programSymbolCount++;
        }
    }
    return programSymbolCount * 4 <= candidate.length;
}

@end
