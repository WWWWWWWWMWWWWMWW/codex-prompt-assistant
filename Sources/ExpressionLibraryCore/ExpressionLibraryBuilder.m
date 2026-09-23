#import "ExpressionLibraryBuilder.h"

#import "ExpressionExtractor.h"
#import "../CodexDataCore/LocalDataStore.h"
#import "../CodexDataCore/LocalExpressionRecord.h"
#import "../CodexDataCore/LocalUserMessageRecord.h"

static const NSUInteger CPAExpressionExtractorVersion = 1;

@interface CPAExpressionAccumulator : NSObject
@property(nonatomic, copy) NSString *normalizedText;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *messageRowIDs;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *conversationRowIDs;
@property(nonatomic, copy) NSString *lastSourceTimestamp;
@end

@implementation CPAExpressionAccumulator

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _normalizedText = @"";
        _messageRowIDs = [NSMutableSet set];
        _conversationRowIDs = [NSMutableSet set];
        _lastSourceTimestamp = @"";
    }
    return self;
}

@end

@interface CPAExpressionLibraryBuilder ()
@property(nonatomic, strong) CPAExpressionExtractor *extractor;
@end

@implementation CPAExpressionLibraryBuilder

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _extractor = [[CPAExpressionExtractor alloc] init];
    }
    return self;
}

- (CPALocalExpressionBuildResult *)rebuildStore:(CPALocalDataStore *)store
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    NSMutableDictionary<NSString *, CPAExpressionAccumulator *> *accumulators =
        [NSMutableDictionary dictionary];
    BOOL enumerated = [store enumerateDecryptedUserMessages:
        ^BOOL(CPALocalUserMessageRecord *record, BOOL *stop, NSError **handlerError) {
            (void)stop;
            (void)handlerError;
            NSArray<CPAExtractedExpression *> *extracted = [self.extractor
                expressionsFromText:record.text
                containsSensitiveData:record.containsSensitiveData];
            for (NSUInteger i = 0, len = extracted.count; i < len; i++) {
                NSString *normalizedText = extracted[i].normalizedText;
                CPAExpressionAccumulator *accumulator = accumulators[normalizedText];
                if (accumulator == nil) {
                    accumulator = [[CPAExpressionAccumulator alloc] init];
                    accumulator.normalizedText = normalizedText;
                    accumulators[normalizedText] = accumulator;
                }
                [accumulator.messageRowIDs addObject:@(record.messageRowID)];
                [accumulator.conversationRowIDs addObject:@(record.conversationRowID)];
                if (accumulator.lastSourceTimestamp.length == 0
                    || [record.sourceTimestamp compare:accumulator.lastSourceTimestamp]
                        == NSOrderedDescending) {
                    accumulator.lastSourceTimestamp = record.sourceTimestamp;
                }
            }
            return YES;
        } error:error];
    if (!enumerated) {
        return nil;
    }

    NSMutableArray<CPALocalExpressionCandidate *> *candidates = [NSMutableArray array];
    NSArray<NSString *> *keys = [[accumulators allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0, len = keys.count; i < len; i++) {
        CPAExpressionAccumulator *accumulator = accumulators[keys[i]];
        if (accumulator.conversationRowIDs.count < 2) {
            continue;
        }
        NSArray<NSNumber *> *messageRowIDs = [[accumulator.messageRowIDs allObjects]
            sortedArrayUsingSelector:@selector(compare:)];
        CPALocalExpressionCandidate *candidate = [[CPALocalExpressionCandidate alloc]
            initWithNormalizedText:accumulator.normalizedText
            occurrenceMessageRowIDs:messageRowIDs
            occurrenceCount:messageRowIDs.count
            conversationCount:accumulator.conversationRowIDs.count
            lastSourceTimestamp:accumulator.lastSourceTimestamp];
        [candidates addObject:candidate];
    }
    return [store replaceActiveExpressions:candidates
        extractorVersion:CPAExpressionExtractorVersion error:error];
}

@end
