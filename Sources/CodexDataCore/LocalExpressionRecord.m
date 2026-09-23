#import "LocalExpressionRecord.h"

@implementation CPALocalExpressionCandidate

- (instancetype)initWithNormalizedText:(NSString *)normalizedText
    occurrenceMessageRowIDs:(NSArray<NSNumber *> *)occurrenceMessageRowIDs
    occurrenceCount:(NSUInteger)occurrenceCount
    conversationCount:(NSUInteger)conversationCount
    lastSourceTimestamp:(NSString *)lastSourceTimestamp {
    self = [super init];
    if (self != nil) {
        _normalizedText = [normalizedText copy];
        _occurrenceMessageRowIDs = [occurrenceMessageRowIDs copy];
        _occurrenceCount = occurrenceCount;
        _conversationCount = conversationCount;
        _lastSourceTimestamp = [lastSourceTimestamp copy];
    }
    return self;
}

@end

@implementation CPALocalExpressionRecord

- (instancetype)initWithNormalizedText:(NSString *)normalizedText
    occurrenceCount:(NSUInteger)occurrenceCount
    conversationCount:(NSUInteger)conversationCount
    lastSourceTimestamp:(NSString *)lastSourceTimestamp
    extractorVersion:(NSUInteger)extractorVersion {
    self = [super init];
    if (self != nil) {
        _normalizedText = [normalizedText copy];
        _occurrenceCount = occurrenceCount;
        _conversationCount = conversationCount;
        _lastSourceTimestamp = [lastSourceTimestamp copy];
        _extractorVersion = extractorVersion;
    }
    return self;
}

@end

@implementation CPALocalExpressionBuildResult

- (instancetype)initWithActiveExpressionCount:(NSUInteger)activeExpressionCount
    skippedTombstoneCount:(NSUInteger)skippedTombstoneCount {
    self = [super init];
    if (self != nil) {
        _activeExpressionCount = activeExpressionCount;
        _skippedTombstoneCount = skippedTombstoneCount;
    }
    return self;
}

@end
