#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/SuggestionContextIdentity.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPASuggestionContextIdentity *Identity(
    NSString *bundleIdentifier,
    pid_t processIdentifier,
    NSInteger windowIdentifier,
    NSString *fieldIdentity,
    NSString *browserHost,
    NSUInteger ruleVersion
) {
    return [[CPASuggestionContextIdentity alloc]
        initWithBundleIdentifier:bundleIdentifier
        processIdentifier:processIdentifier
        windowIdentifier:windowIdentifier
        fieldIdentity:fieldIdentity
        browserHost:browserHost
        ruleVersion:ruleVersion];
}

int main(void) {
    @autoreleasepool {
        CPASuggestionContextGenerationTracker *tracker =
            [[CPASuggestionContextGenerationTracker alloc] init];
        CPASuggestionContextIdentity *base = Identity(@"com.electron.lark",
            100, 7, @"field-a", @"", 1);
        Assert([tracker observeIdentity:base] && tracker.generation == 1,
            @"the first identity should establish generation one");
        Assert(![tracker observeIdentity:base] && tracker.generation == 1,
            @"an identical identity must not churn generations");

        NSArray<CPASuggestionContextIdentity *> *changes = @[
            Identity(@"com.workbuddy.workbuddy", 100, 7, @"field-a", @"", 1),
            Identity(@"com.electron.lark", 101, 7, @"field-a", @"", 1),
            Identity(@"com.electron.lark", 100, 8, @"field-a", @"", 1),
            Identity(@"com.electron.lark", 100, 7, @"field-b", @"", 1),
            Identity(@"com.electron.lark", 100, 7, @"field-a",
                @"docs.example.com", 1),
            Identity(@"com.electron.lark", 100, 7, @"field-a", @"", 2),
        ];
        for (CPASuggestionContextIdentity *changed in changes) {
            CPASuggestionContextGenerationTracker *isolated =
                [[CPASuggestionContextGenerationTracker alloc] init];
            [isolated observeIdentity:base];
            Assert([isolated observeIdentity:changed]
                    && isolated.generation == 2,
                @"each application, process, window, field, site, or rule change must invalidate");
        }

        [tracker clear];
        Assert(tracker.generation == 2 && tracker.currentIdentity == nil,
            @"clearing focus should invalidate the established context");
        Assert(![tracker clear] && tracker.generation == 2,
            @"repeated clear without identity should be stable");

        NSLog(@"PASS: SuggestionContextIdentityTests");
    }
    return 0;
}
