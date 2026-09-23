#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPAExtractedExpression : NSObject

@property(nonatomic, copy, readonly) NSString *normalizedText;

- (instancetype)initWithNormalizedText:(NSString *)normalizedText
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPAExpressionExtractor : NSObject

- (NSArray<CPAExtractedExpression *> *)expressionsFromText:(NSString *)text
    containsSensitiveData:(BOOL)containsSensitiveData;

@end

NS_ASSUME_NONNULL_END
