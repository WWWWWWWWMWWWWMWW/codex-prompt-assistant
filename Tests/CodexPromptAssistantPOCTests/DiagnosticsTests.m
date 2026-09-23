#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/Diagnostics.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSString *runRoot = NSProcessInfo.processInfo.environment[@"CPA_TEST_ROOT"];
        Assert(runRoot.length > 0 && [[CPADiagnosticLogPath stringByDeletingLastPathComponent]
            isEqualToString:runRoot], @"test diagnostics must stay inside this private run directory");
        NSString *token = NSUUID.UUID.UUIDString;
        NSString *first = [NSString stringWithFormat:@"diagnostic-test first %@", token];
        NSString *second = [NSString stringWithFormat:@"diagnostic-test second %@", token];
        CPADiagnosticLog(@"%@", first);
        CPADiagnosticLog(@"%@", second);
        CPADiagnosticLogFlush();
        NSString *contents = [NSString stringWithContentsOfFile:CPADiagnosticLogPath
            encoding:NSUTF8StringEncoding error:nil];
        Assert([contents containsString:first] && [contents containsString:second],
            @"asynchronous diagnostic writes should be flushed");
        Assert([contents rangeOfString:first].location
                < [contents rangeOfString:second].location,
            @"diagnostic queue should preserve event order");

        NSString *testPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"cpa-diagnostics-%@.log", token]];
        CPAStatefulDiagnosticWriter *writer = [[CPAStatefulDiagnosticWriter alloc]
            initWithLogPath:testPath
            maximumFileSize:240
            rotationCount:2
            repeatSummaryInterval:10.0];
        NSDate *start = [NSDate dateWithTimeIntervalSince1970:1000];
        NSString *targetPath = [testPath stringByAppendingString:@".targets"];
        CPAStatefulDiagnosticWriter *targetWriter = [[CPAStatefulDiagnosticWriter alloc]
            initWithLogPath:targetPath maximumFileSize:4096 rotationCount:0
            repeatSummaryInterval:15.0];
        NSArray<NSString *> *bundles = @[@"synthetic.editor.a", @"synthetic.editor.a",
            @"synthetic.editor.b", @"synthetic.editor.b", @""];
        NSArray<NSNumber *> *pids = @[@101, @101, @101, @102, @0];
        for (NSUInteger index = 0; index < bundles.count; index++) {
            [targetWriter recordState:CPADiagnosticStateWithTarget(@"writable", bundles[index], pids[index].intValue)
                message:[NSString stringWithFormat:@"synthetic target index=%lu", (unsigned long)index]
                atDate:[start dateByAddingTimeInterval:index]];
            NSString *targetLog = [NSString stringWithContentsOfFile:targetPath
                encoding:NSUTF8StringEncoding error:nil];
            if (index == 1) {
                Assert(![targetLog containsString:@"index=1"],
                    @"unchanged application and process should retain log throttling");
            } else {
                Assert([targetLog containsString:[NSString stringWithFormat:@"index=%lu", (unsigned long)index]],
                    @"application, process, and unknown-target transitions must log immediately");
            }
        }
        [NSFileManager.defaultManager removeItemAtPath:targetPath error:nil];
        [writer recordState:@"ax-unavailable"
            message:@"snapshot focused_element_unavailable error=-25212"
            atDate:start];
        [writer recordState:@"ax-unavailable"
            message:@"snapshot focused_element_unavailable error=-25212"
            atDate:[start dateByAddingTimeInterval:1.0]];
        [writer recordState:@"ax-unavailable"
            message:@"snapshot focused_element_unavailable error=-25212"
            atDate:[start dateByAddingTimeInterval:2.0]];
        NSString *throttled = [NSString stringWithContentsOfFile:testPath
            encoding:NSUTF8StringEncoding error:nil];
        Assert([[throttled componentsSeparatedByString:@"focused_element_unavailable"] count]
                - 1 == 1,
            @"same AX failure state should be written once before the summary interval");
        [writer recordState:@"ax-unavailable"
            message:@"snapshot focused_element_unavailable error=-25212"
            atDate:[start dateByAddingTimeInterval:11.0]];
        throttled = [NSString stringWithContentsOfFile:testPath
            encoding:NSUTF8StringEncoding error:nil];
        Assert([throttled containsString:@"repeated=3"],
            @"sustained AX failures should emit a periodic count summary");
        [writer recordState:@"ax-recovered" message:@"snapshot writable=true"
            atDate:[start dateByAddingTimeInterval:12.0]];
        throttled = [NSString stringWithContentsOfFile:testPath
            encoding:NSUTF8StringEncoding error:nil];
        Assert([throttled containsString:@"snapshot writable=true"],
            @"a diagnostic state transition should be logged immediately");

        for (NSUInteger index = 0; index < 20; index++) {
            [writer recordMessage:[NSString stringWithFormat:
                @"bounded diagnostic event index=%lu", (unsigned long)index]
                atDate:[start dateByAddingTimeInterval:20.0 + index]];
        }
        NSDictionary *activeAttributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:testPath error:nil];
        Assert([activeAttributes fileSize] <= 240,
            @"active diagnostic log should stay within the configured size cap");
        Assert([NSFileManager.defaultManager fileExistsAtPath:
                [testPath stringByAppendingString:@".1"]],
            @"exceeding the cap should create a bounded rotated log");
        [NSFileManager.defaultManager removeItemAtPath:testPath error:nil];
        [NSFileManager.defaultManager removeItemAtPath:
            [testPath stringByAppendingString:@".1"] error:nil];
        [NSFileManager.defaultManager removeItemAtPath:
            [testPath stringByAppendingString:@".2"] error:nil];
        NSLog(@"PASS: DiagnosticsTests");
    }
    return 0;
}
