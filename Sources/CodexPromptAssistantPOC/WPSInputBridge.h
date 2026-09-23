#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface CPAWPSInputBridge : NSObject
- (nullable NSDictionary *)requestPhase:(NSString *)phase processIdentifier:(pid_t)pid
    documentId:(nullable NSString *)documentId;
@end
NS_ASSUME_NONNULL_END
