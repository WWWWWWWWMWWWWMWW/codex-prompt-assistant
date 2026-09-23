#import "SensitiveTextRedactor.h"

@interface CPARedactionResult ()
@property(nonatomic, copy, readwrite) NSString *redactedText;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, NSNumber *> *typeCounts;
@property(nonatomic, readwrite) NSUInteger totalReplacementCount;
@end

@implementation CPARedactionResult
@end

@implementation CPASensitiveTextRedactor

- (CPARedactionResult *)redactText:(NSString *)text {
    NSArray<NSDictionary<NSString *, id> *> *rules = @[
        @{
            @"pattern": @"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----.*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----",
            @"placeholder": @"{PRIVATE_KEY}",
            @"replacement": @"{PRIVATE_KEY}",
            @"options": @(NSRegularExpressionDotMatchesLineSeparators),
        },
        @{
            @"pattern": @"(?i)([?&](?:access_token|token|api_key|key|secret)=)[^&#\\s]+",
            @"placeholder": @"{URL_TOKEN}",
            @"replacement": @"$1{URL_TOKEN}",
            @"options": @0,
        },
        @{
            @"pattern": @"(?i)\\bBearer\\s+[A-Za-z0-9._~+/-]{16,}=*",
            @"placeholder": @"{BEARER_TOKEN}",
            @"replacement": @"{BEARER_TOKEN}",
            @"options": @0,
        },
        @{
            @"pattern": @"\\b[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b",
            @"placeholder": @"{JWT}",
            @"replacement": @"{JWT}",
            @"options": @0,
        },
        @{
            @"pattern": @"(?i)\\b(?:sk|pk)-[A-Za-z0-9_-]{16,}\\b",
            @"placeholder": @"{API_KEY}",
            @"replacement": @"{API_KEY}",
            @"options": @0,
        },
        @{
            @"pattern": @"(?i)\\b(password|passwd|pwd)\\s*[:=]\\s*(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
            @"placeholder": @"{PASSWORD}",
            @"replacement": @"$1={PASSWORD}",
            @"options": @0,
        },
        @{
            @"pattern": @"(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b",
            @"placeholder": @"{EMAIL}",
            @"replacement": @"{EMAIL}",
            @"options": @0,
        },
        @{
            @"pattern": @"(?<![0-9])(?:\\+?86[- ]?)?1[3-9][0-9]{9}(?![0-9])",
            @"placeholder": @"{PHONE}",
            @"replacement": @"{PHONE}",
            @"options": @0,
        },
    ];

    NSString *redacted = [text copy];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSUInteger total = 0;
    for (NSUInteger i = 0, len = rules.count; i < len; i++) {
        NSDictionary<NSString *, id> *rule = rules[i];
        NSError *error = nil;
        NSRegularExpression *expression = [NSRegularExpression
            regularExpressionWithPattern:rule[@"pattern"]
            options:[rule[@"options"] unsignedIntegerValue]
            error:&error];
        NSCAssert(expression != nil && error == nil, @"Invalid built-in redaction rule");
        NSRange fullRange = NSMakeRange(0, redacted.length);
        NSUInteger matchCount = [expression numberOfMatchesInString:redacted
            options:0 range:fullRange];
        if (matchCount == 0) {
            continue;
        }
        NSString *placeholder = rule[@"placeholder"];
        counts[placeholder] = @([counts[placeholder] unsignedIntegerValue] + matchCount);
        total += matchCount;
        redacted = [expression stringByReplacingMatchesInString:redacted
            options:0
            range:fullRange
            withTemplate:rule[@"replacement"]];
    }

    CPARedactionResult *result = [[CPARedactionResult alloc] init];
    result.redactedText = redacted;
    result.typeCounts = counts;
    result.totalReplacementCount = total;
    return result;
}

@end
