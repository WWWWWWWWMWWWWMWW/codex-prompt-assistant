#import <Foundation/Foundation.h>

#import "../../Sources/RemoteCompletionCore/RemoteCompletionSpeculation.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Assert(CPARemoteCanReusePrefixRequest(@"请帮", @"请帮我", 3, 0),
            @"an end-cursor extension should reuse the request");
        Assert(!CPARemoteCanReusePrefixRequest(@"请帮", @"请改我", 3, 0),
            @"a different prefix must cancel the request");
        Assert(!CPARemoteCanReusePrefixRequest(@"请帮", @"请帮我", 2, 0),
            @"a non-end cursor must not reuse the request");
        Assert(!CPARemoteCanReusePrefixRequest(@"请帮", @"请帮我", 3, 1),
            @"a selection must not reuse the request");
        Assert([CPARemoteRebaseInsertion(@"我写一份方案", @"请帮", @"请帮我")
            isEqualToString:@"写一份方案"],
            @"typed overlap should be removed from the insertion");
        Assert([CPARemoteRebaseInsertion(@"我写一份方案", @"请帮", @"请帮")
            isEqualToString:@"我写一份方案"],
            @"an unchanged input should keep the insertion");
        Assert(CPARemoteRebaseInsertion(@"给出建议", @"请帮", @"请帮我") == nil,
            @"an unsafe overlap must be discarded");
        NSLog(@"PASS: RemoteCompletionSpeculationTests");
    }
    return 0;
}
