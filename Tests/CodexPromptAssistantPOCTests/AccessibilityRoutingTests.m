#import <Foundation/Foundation.h>

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSString *MethodBody(NSString *source, NSString *signature) {
    NSRange start = [source rangeOfString:signature];
    Assert(start.location != NSNotFound,
        [NSString stringWithFormat:@"missing method signature: %@", signature]);
    NSRange nextMethod = [source rangeOfString:@"\n- ("
        options:0
        range:NSMakeRange(NSMaxRange(start), source.length - NSMaxRange(start))];
    NSUInteger end = nextMethod.location == NSNotFound
        ? source.length : nextMethod.location;
    return [source substringWithRange:NSMakeRange(start.location, end - start.location)];
}

int main(void) {
    @autoreleasepool {
        NSString *source = [NSString stringWithContentsOfFile:
            @"Sources/CodexPromptAssistantPOC/main.m"
            encoding:NSUTF8StringEncoding error:nil];
        Assert(source.length > 0, @"main.m must be readable from the project root");
        NSString *accessibilitySource = [NSString stringWithContentsOfFile:
            @"Sources/CodexPromptAssistantPOC/AccessibilityService.m"
            encoding:NSUTF8StringEncoding error:nil];
        Assert(accessibilitySource.length > 0,
            @"AccessibilityService.m must be readable from the project root");

        NSString *inspect = MethodBody(source,
            @"- (CPAAccessibilitySnapshot *)inspectCurrentTarget {");
        Assert([inspect containsString:@"requestCodexSnapshotRefresh"],
            @"inspectCurrentTarget must schedule a background snapshot refresh");
        Assert([inspect containsString:@"cachedCodexSnapshot"],
            @"inspectCurrentTarget must consume the cached Codex snapshot");
        Assert([inspect rangeOfString:@"inspectFocusedElementForCodexProcessIdentifier:"].location
                == NSNotFound,
            @"inspectCurrentTarget must not synchronously inspect AX");

        NSString *update = MethodBody(source, @"- (CPAAccessibilitySnapshot *)updateStatus {");
        Assert([update containsString:@"updateStatusWithSnapshot"],
            @"updateStatus must process an already collected snapshot");
        Assert([update rangeOfString:@"currentCodexFallbackInputFrame:"].location
                == NSNotFound,
            @"updateStatus must not synchronously scan window metadata");

        NSString *poll = MethodBody(source, @"- (void)pollAccessibility:(NSTimer *)timer {");
        Assert([poll containsString:@"requestCodexSnapshotRefresh"],
            @"pollAccessibility must schedule a background snapshot refresh");
        Assert([poll rangeOfString:@"tryEnableRuntimeAccessibilityForProcessIdentifier:"].location
                == NSNotFound
            && [poll rangeOfString:@"refreshCurrentCodexTextInputForProcessIdentifier:"].location
                == NSNotFound,
            @"pollAccessibility must not block on AX recovery");

        NSString *recovery = MethodBody(source, @"- (void)recoverCodexFocus:(NSTimer *)timer {");
        Assert([recovery containsString:@"requestCodexSnapshotRefresh"],
            @"recoverCodexFocus must defer AX recovery to the broker");
        Assert([recovery rangeOfString:@"refreshCurrentCodexTextInputForProcessIdentifier:"].location
                == NSNotFound
            && [recovery rangeOfString:@"focusLastKnownTextInputForProcessIdentifier:"].location
                == NSNotFound,
            @"recoverCodexFocus must not synchronously block the main run loop");

        NSString *shortcut = MethodBody(source,
            @"- (BOOL)keyboardInterceptorShouldHandleSuggestionKeys {");
        Assert([shortcut containsString:@"cachedCodexSnapshot"],
            @"keyboard shortcut gate must use the cached snapshot");
        Assert([shortcut rangeOfString:@"inspectFocusedElementForCodexProcessIdentifier:"].location
                == NSNotFound,
            @"keyboard shortcut gate must never synchronously inspect AX");

        // One-shot suggestion timers must continue through event-tracking
        // run-loop modes (for example while the host is processing a key
        // event); otherwise the model start can be delayed by a whole mode
        // switch even though the snapshot is already validated.
        Assert([source containsString:@"CPAScheduleOneShotTimer"],
            @"suggestion scheduling must use the common-mode timer helper");
        Assert([source containsString:@"NSRunLoopCommonModes"],
            @"the timer helper must register with common run-loop modes");

        Assert([accessibilitySource containsString:@"CPAConversationTitleGraceInterval"],
            @"conversation title lookup must retain a short-lived cache during AX churn");
        Assert([accessibilitySource containsString:@"cachedConversationTitleDate"],
            @"conversation title cache must track freshness for the AX grace window");

        NSString *modelSchedule = MethodBody(source,
            @"- (void)scheduleModelSuggestionsForSnapshot:(CPAAccessibilitySnapshot *)snapshot\n    signature:(NSString *)signature delay:(NSTimeInterval)delay {");
        Assert([modelSchedule containsString:@"CPALocalModelCanStartImmediately"],
            @"ready local context must use the immediate dispatch decision");
        Assert([modelSchedule containsString:@"startLocalModelSuggestionForSnapshot:snapshot"],
            @"ready local context must start without a second timer callback");
        NSString *warmup = MethodBody(source, @"- (void)warmLocalModel {");
        Assert([warmup containsString:@"localModelWarmupTask"],
            @"warm-up must be tracked as a separate task");
        Assert([warmup containsString:@"CPALocalModelWarmupMayStartWithPendingWork"],
            @"warm-up must yield to queued suggestion work");

        NSLog(@"PASS: AccessibilityRoutingTests");
    }
    return 0;
}
