#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CPAHealthResponder : NSObject
- (instancetype)initWithStateProvider:(NSDictionary *(^)(void))provider;
- (BOOL)start;
- (void)stop;
@end

NSDictionary * _Nullable CPACopyHealthProbeResult(pid_t pid);
int CPARunHealthProbe(pid_t pid);
NS_ASSUME_NONNULL_END
