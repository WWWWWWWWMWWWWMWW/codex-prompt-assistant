#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/SuggestionPolicyCoordinator.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPASuggestionDecision *Decision(
    CPASuggestionPolicyCoordinator *coordinator,
    NSString *bundleIdentifier,
    NSString *role,
    NSString *subrole,
    NSArray<NSString *> *metadata,
    NSString *host
) {
    return [coordinator decisionForBundleIdentifier:bundleIdentifier
        role:role
        subrole:subrole
        semanticMetadata:metadata
        browserHost:host
        globallyPaused:NO
        temporarilyPaused:NO];
}

int main(void) {
    @autoreleasepool {
        NSString *suiteName = [NSString stringWithFormat:
            @"local.codex.prompt-assistant.coordinator-tests.%@",
            NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [defaults removePersistentDomainForName:suiteName];
        CPASuggestionPolicyStore *store = [[CPASuggestionPolicyStore alloc]
            initWithUserDefaults:defaults];
        CPASuggestionPolicyCoordinator *coordinator =
            [[CPASuggestionPolicyCoordinator alloc] initWithStore:store];

        Assert([coordinator shouldProbeMetadataForBundleIdentifier:
            @"com.example.editor"],
            @"ordinary applications should inspect metadata in safe global mode");
        Assert([coordinator shouldProbeMetadataForBundleIdentifier:
            @"com.workbuddy.workbuddy"],
            @"known preset applications may inspect metadata when needed");
        Assert(![coordinator shouldProbeMetadataForBundleIdentifier:
            @"com.apple.Terminal"],
            @"terminals must skip metadata probes until explicitly enabled");
        Assert(![coordinator shouldProbeMetadataForBundleIdentifier:
            @"com.microsoft.VSCode"],
            @"code editors must skip metadata probes until explicitly enabled");
        Assert(![coordinator shouldProbeMetadataForBundleIdentifier:
            @"com.apple.SecurityAgent"],
            @"system authorization applications must never be probed");

        CPASuggestionDecision *decision = Decision(coordinator,
            @"com.openai.codex", @"AXTextArea", @"", @[], @"");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalAndRemote
                && decision.contextMode == CPAContextAccessModeCodexConversation,
            @"Codex should retain its recommended preset and context boundary");

        decision = Decision(coordinator, @"com.electron.lark", @"AXTextArea", @"",
            @[@"message composer"], @"");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"Lark chat should use local-only suggestions under safe global mode");

        CPAApplicationRule *enabledRule = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs
            searchExceptionEnabled:NO remoteCompletionAuthorized:NO];
        [store setRule:enabledRule forBundleIdentifier:@"com.example.editor"];
        Assert([coordinator shouldProbeMetadataForBundleIdentifier:
            @"com.example.editor"],
            @"an explicitly enabled unknown application may inspect metadata");
        decision = Decision(coordinator, @"com.example.editor", @"AXTextField", @"",
            @[], @"");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"an ordinary app may infer an ordinary text role after explicit enable");

        decision = Decision(coordinator, @"com.example.notes", @"AXTextArea", @"",
            @[], @"");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"an ordinary app should infer a safe text area in recommended mode");

        [store setRule:enabledRule forBundleIdentifier:@"com.google.Chrome"];
        decision = Decision(coordinator, @"com.google.Chrome", @"AXTextArea", @"",
            @[], @"");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled,
            @"enabling a browser application must not enable unknown sites");

        [store setRule:enabledRule forBrowserHost:@"https://docs.example.com/private"];
        decision = Decision(coordinator, @"com.google.Chrome", @"AXTextArea", @"",
            @[], @"docs.example.com");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && decision.contextMode == CPAContextAccessModeCurrentInputOnly,
            @"an exact enabled browser host should allow local current-input completion");

        decision = Decision(coordinator, @"com.google.Chrome", @"AXTextField",
            @"AXSecureTextField", @[], @"docs.example.com");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled
                && decision.reason == CPASuggestionPolicyReasonHardSensitive,
            @"a site allowlist must never override a secure field");

        CPAApplicationRule *searchRule = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs
            searchExceptionEnabled:YES remoteCompletionAuthorized:NO];
        [store setRule:searchRule forBrowserHost:@"docs.example.com"];
        decision = Decision(coordinator, @"com.google.Chrome", @"AXTextField", @"",
            @[@"search query"], @"docs.example.com");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && decision.reason == CPASuggestionPolicyReasonUserEnabled,
            @"a search exception must be scoped to the exact enabled host");

        CPAApplicationRule *disabledRule = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeDisabled
            searchExceptionEnabled:NO remoteCompletionAuthorized:NO];
        [store setRule:disabledRule forBundleIdentifier:@"com.google.Chrome"];
        Assert(![coordinator shouldProbeMetadataForBundleIdentifier:
            @"com.google.Chrome"],
            @"an explicitly disabled application must skip metadata probes");
        decision = Decision(coordinator, @"com.google.Chrome", @"AXTextArea", @"",
            @[], @"docs.example.com");
        Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled
                && decision.reason == CPASuggestionPolicyReasonExplicitlyDisabled,
            @"browser application off must override an enabled site");

        [defaults removePersistentDomainForName:suiteName];
        NSLog(@"PASS: SuggestionPolicyCoordinatorTests");
    }
    return 0;
}
