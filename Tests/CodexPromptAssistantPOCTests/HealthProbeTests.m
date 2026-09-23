#import <Foundation/Foundation.h>
#import "../../Sources/CodexPromptAssistantPOC/HealthProbe.h"
#include <unistd.h>

@interface CPAHealthResponder (Fixture)
- (NSData *)responseForData:(NSData *)data;
@end
#define Check(x) do { if (!(x)) { NSLog(@"FAIL HealthProbeTests line %d", __LINE__); exit(1); } } while (0)

int main(void) { @autoreleasepool {
    NSMutableDictionary *state = [@{@"eventTapEnabled":@YES, @"accessibilityGranted":@YES,
        @"modelPreserved":@YES, @"privateInput":@"fixture-never-return"} mutableCopy];
    CPAHealthResponder *server = [[CPAHealthResponder alloc] initWithStateProvider:^NSDictionary *{ return state; }];
    Check([server responseForData:[@"not-a-nonce" dataUsingEncoding:NSUTF8StringEncoding]] == nil);
    Check([server responseForData:[NSMutableData dataWithLength:129]] == nil);
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSData *encoded = [server responseForData:[nonce dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:encoded options:0 error:NULL];
    Check([reply[@"nonce"] isEqual:nonce] && [reply[@"pid"] isEqual:@(getpid())]);
    Check(reply[@"privateInput"] == nil && reply[@"build"] != nil);
    state[@"eventTapEnabled"] = @NO;
    reply = [NSJSONSerialization JSONObjectWithData:[server responseForData:[nonce dataUsingEncoding:NSUTF8StringEncoding]] options:0 error:NULL];
    Check([reply[@"eventTapEnabled"] isEqual:@NO]);
    Check([server start]); Check([server start]);
    __block BOOL done = NO;
    __block NSDictionary *received = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *value = CPACopyHealthProbeResult(getpid());
        dispatch_async(dispatch_get_main_queue(), ^{ received = value; done = YES; });
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Check(done && [received[@"eventTapEnabled"] isEqual:@NO] && [received[@"mainThreadResponsive"] isEqual:@YES]);
    Check(![received[@"nonce"] isEqual:nonce]);
    // Deliberately block this fixture's main run loop. The background caller
    // must time out instead of treating an existing port as a healthy app.
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSDictionary *timedOut = @{};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        timedOut = CPACopyHealthProbeResult(getpid());
        dispatch_semaphore_signal(finished);
    });
    Check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0);
    Check(timedOut == nil);
    [server stop]; [server stop];
    Check(CPACopyHealthProbeResult(getpid()) == nil);
    Check(CPACopyHealthProbeResult(-1) == nil);
    NSLog(@"PASS: HealthProbeTests nonce, current state, private-field exclusion, main-runloop IPC, blocked-main timeout, stop and unavailable endpoint");
} return 0; }
