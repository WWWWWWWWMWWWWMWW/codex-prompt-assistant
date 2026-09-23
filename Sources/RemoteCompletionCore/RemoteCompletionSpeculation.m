#import "RemoteCompletionSpeculation.h"

BOOL CPARemoteCanReusePrefixRequest(
    NSString *requestedInput,
    NSString *currentInput,
    NSInteger currentLocation,
    NSInteger currentSelectedLength) {
    if (requestedInput.length == 0 || currentInput.length <= requestedInput.length
        || currentSelectedLength != 0 || currentLocation < 0
        || (NSUInteger)currentLocation != currentInput.length) {
        return NO;
    }
    return [currentInput hasPrefix:requestedInput];
}

NSString *CPARemoteRebaseInsertion(
    NSString *insertion,
    NSString *requestedInput,
    NSString *currentInput) {
    if (insertion.length == 0 || requestedInput.length == 0
        || currentInput.length < requestedInput.length
        || ![currentInput hasPrefix:requestedInput]) {
        return nil;
    }
    NSUInteger typedSinceRequest = currentInput.length - requestedInput.length;
    if (typedSinceRequest == 0) {
        return insertion;
    }
    if (insertion.length < typedSinceRequest
        || ![insertion hasPrefix:[currentInput substringFromIndex:requestedInput.length]]) {
        return nil;
    }
    NSString *rebased = [insertion substringFromIndex:typedSinceRequest];
    return rebased.length > 0 ? rebased : nil;
}
