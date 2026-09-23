#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/AccessibilitySnapshotBroker.h"

#include <unistd.h>

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPAAccessibilitySnapshot *SnapshotForPID(pid_t processIdentifier) {
    CPAAccessibilitySnapshot *snapshot = [[CPAAccessibilitySnapshot alloc] init];
    snapshot.permissionGranted = YES;
    snapshot.codexIsRunning = YES;
    snapshot.codexIsFrontmost = YES;
    snapshot.targetApplicationIsFrontmost = YES;
    snapshot.targetBundleIdentifier = @"com.openai.codex";
    snapshot.targetProcessIdentifier = processIdentifier;
    snapshot.diagnostic = [NSString stringWithFormat:@"pid=%d", processIdentifier];
    return snapshot;
}

static void RunMainLoopUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && [deadline timeIntervalSinceNow] > 0.0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

int main(void) {
    @autoreleasepool {
        __block BOOL providerRanOnMain = NO;
        __block NSUInteger providerCount = 0;
        __block NSMutableArray<NSNumber *> *deliveredPIDs = [NSMutableArray array];
        dispatch_semaphore_t firstStarted = dispatch_semaphore_create(0);
        dispatch_semaphore_t releaseFirst = dispatch_semaphore_create(0);
        CPASnapshotProvider provider = ^CPAAccessibilitySnapshot *(
            pid_t processIdentifier, pid_t frontmostProcessIdentifier) {
            (void)frontmostProcessIdentifier;
            providerRanOnMain = NSThread.isMainThread;
            providerCount++;
            if (processIdentifier == 11) {
                dispatch_semaphore_signal(firstStarted);
                dispatch_semaphore_wait(releaseFirst,
                    dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            }
            return SnapshotForPID(processIdentifier);
        };
        CPASnapshotDelivery delivery = ^(CPAAccessibilitySnapshot *snapshot,
            pid_t processIdentifier, pid_t frontmostProcessIdentifier,
            NSUInteger generation) {
            (void)frontmostProcessIdentifier;
            (void)generation;
            [deliveredPIDs addObject:@(processIdentifier)];
            Assert(snapshot.targetProcessIdentifier == processIdentifier,
                @"delivered snapshot must retain its process identity");
        };
        CPAAccessibilitySnapshotBroker *broker =
            [[CPAAccessibilitySnapshotBroker alloc] initWithProvider:provider
                callbackQueue:dispatch_get_main_queue() delivery:delivery];

        CFAbsoluteTime requestStarted = CFAbsoluteTimeGetCurrent();
        [broker requestSnapshotForProcessIdentifier:11
            frontmostProcessIdentifier:11];
        NSTimeInterval requestElapsed = CFAbsoluteTimeGetCurrent() - requestStarted;
        Assert(requestElapsed < 0.05,
            @"requesting an AX snapshot must return without waiting for the provider");
        Assert(dispatch_semaphore_wait(firstStarted,
            dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) == 0,
            @"the provider should run asynchronously");

        NSUInteger generationBeforeSwitch = broker.generation;
        [broker requestSnapshotForProcessIdentifier:22
            frontmostProcessIdentifier:22];
        Assert(broker.generation > generationBeforeSwitch,
            @"a process switch must advance the snapshot generation");
        dispatch_semaphore_signal(releaseFirst);
        RunMainLoopUntil(^{ return (BOOL)(deliveredPIDs.count > 0); }, 2.0);
        Assert(!providerRanOnMain,
            @"AX/window provider work must never execute on the main thread");
        Assert(deliveredPIDs.count == 1 && deliveredPIDs[0].intValue == 22,
            @"a stale snapshot from the previous process must be discarded");
        CPAAccessibilitySnapshot *latest = [broker
            latestSnapshotForProcessIdentifier:22 frontmostProcessIdentifier:22];
        Assert(latest.targetProcessIdentifier == 22,
            @"latest snapshot must belong to the current process");

        [broker stop];
        NSUInteger countBeforeStop = providerCount;
        [broker requestSnapshotForProcessIdentifier:33
            frontmostProcessIdentifier:33];
        RunMainLoopUntil(^{ return NO; }, 0.05);
        Assert(providerCount == countBeforeStop,
            @"stopped broker must not schedule more AX work");
        __block NSUInteger reads = 0;
        CPAAccessibilitySnapshotBroker *freshBroker = [[CPAAccessibilitySnapshotBroker alloc]
            initWithProvider:^CPAAccessibilitySnapshot *(pid_t pid, pid_t front) {
                (void)front;
                CPAAccessibilitySnapshot *value = SnapshotForPID(pid);
                value.inputText = [NSString stringWithFormat:@"synthetic-%lu", (unsigned long)++reads];
                return value;
            } callbackQueue:dispatch_get_main_queue()
            delivery:^(CPAAccessibilitySnapshot *value, pid_t pid, pid_t front, NSUInteger generation) {
                (void)value; (void)pid; (void)front; (void)generation;
            }];
        [freshBroker requestSnapshotForProcessIdentifier:44 frontmostProcessIdentifier:44];
        RunMainLoopUntil(^{ return (BOOL)([freshBroker latestSnapshotForProcessIdentifier:44 frontmostProcessIdentifier:44] != nil); }, 2);
        __block BOOL finished = NO;
        [freshBroker requestFreshSnapshotForProcessIdentifier:44 completion:^(CPAAccessibilitySnapshot *value) {
            Assert([value.inputText isEqualToString:@"synthetic-2"], @"acceptance must perform a new read, never reuse the cached value");
            finished = YES;
        }];
        RunMainLoopUntil(^{ return finished; }, 2);
        Assert(finished, @"fresh observation must complete asynchronously");
        finished = NO;
        [freshBroker requestFreshSnapshotForProcessIdentifier:44 completion:^(CPAAccessibilitySnapshot *value) {
            Assert(value == nil, @"invalidation rejects a queued or completed acceptance read");
            finished = YES;
        }];
        [freshBroker invalidate];
        RunMainLoopUntil(^{ return finished; }, 2);
        Assert(finished, @"invalidated reads still complete with nil");
        [freshBroker stop];
        NSLog(@"PASS: AccessibilitySnapshotBrokerTests");
    }
    return 0;
}
