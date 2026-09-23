#import <Foundation/Foundation.h>

@class CPALocalExpressionRecord;

NS_ASSUME_NONNULL_BEGIN

@interface CPAExpressionSuggestion : NSObject

@property(nonatomic, copy, readonly) NSString *fullText;
@property(nonatomic, copy, readonly) NSString *insertionText;

- (instancetype)initWithFullText:(NSString *)fullText
    insertionText:(NSString *)insertionText NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPAExpressionSuggestionIndex : NSObject

- (instancetype)initWithExpressions:(NSArray<CPALocalExpressionRecord *> *)expressions
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable CPAExpressionSuggestion *)suggestionForInput:(NSString *)input
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength;

@end

NS_ASSUME_NONNULL_END
