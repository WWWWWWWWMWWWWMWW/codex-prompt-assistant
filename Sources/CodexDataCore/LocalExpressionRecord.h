#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPALocalExpressionCandidate : NSObject

@property(nonatomic, copy, readonly) NSString *normalizedText;
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *occurrenceMessageRowIDs;
@property(nonatomic, readonly) NSUInteger occurrenceCount;
@property(nonatomic, readonly) NSUInteger conversationCount;
@property(nonatomic, copy, readonly) NSString *lastSourceTimestamp;

- (instancetype)initWithNormalizedText:(NSString *)normalizedText
    occurrenceMessageRowIDs:(NSArray<NSNumber *> *)occurrenceMessageRowIDs
    occurrenceCount:(NSUInteger)occurrenceCount
    conversationCount:(NSUInteger)conversationCount
    lastSourceTimestamp:(NSString *)lastSourceTimestamp NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPALocalExpressionRecord : NSObject

@property(nonatomic, copy, readonly) NSString *normalizedText;
@property(nonatomic, readonly) NSUInteger occurrenceCount;
@property(nonatomic, readonly) NSUInteger conversationCount;
@property(nonatomic, copy, readonly) NSString *lastSourceTimestamp;
@property(nonatomic, readonly) NSUInteger extractorVersion;

- (instancetype)initWithNormalizedText:(NSString *)normalizedText
    occurrenceCount:(NSUInteger)occurrenceCount
    conversationCount:(NSUInteger)conversationCount
    lastSourceTimestamp:(NSString *)lastSourceTimestamp
    extractorVersion:(NSUInteger)extractorVersion NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPALocalExpressionBuildResult : NSObject

@property(nonatomic, readonly) NSUInteger activeExpressionCount;
@property(nonatomic, readonly) NSUInteger skippedTombstoneCount;

- (instancetype)initWithActiveExpressionCount:(NSUInteger)activeExpressionCount
    skippedTombstoneCount:(NSUInteger)skippedTombstoneCount NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end


NS_ASSUME_NONNULL_END
