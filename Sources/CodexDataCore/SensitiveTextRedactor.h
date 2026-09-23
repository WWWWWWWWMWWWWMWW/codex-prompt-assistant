#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPARedactionResult : NSObject

@property(nonatomic, copy, readonly) NSString *redactedText;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *typeCounts;
@property(nonatomic, readonly) NSUInteger totalReplacementCount;

@end


@interface CPASensitiveTextRedactor : NSObject

- (CPARedactionResult *)redactText:(NSString *)text;

@end


NS_ASSUME_NONNULL_END
