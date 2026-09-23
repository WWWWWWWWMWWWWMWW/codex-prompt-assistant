#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL CPARemoteCanReusePrefixRequest(
    NSString *requestedInput,
    NSString *currentInput,
    NSInteger currentLocation,
    NSInteger currentSelectedLength);

FOUNDATION_EXPORT NSString *_Nullable CPARemoteRebaseInsertion(
    NSString *insertion,
    NSString *requestedInput,
    NSString *currentInput);

NS_ASSUME_NONNULL_END
