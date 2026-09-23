#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL CPAWindowLooksLikeInputMethodCandidate(
    NSString *owner,
    CGRect bounds,
    CGFloat alpha,
    NSInteger layer
);

NS_ASSUME_NONNULL_END
