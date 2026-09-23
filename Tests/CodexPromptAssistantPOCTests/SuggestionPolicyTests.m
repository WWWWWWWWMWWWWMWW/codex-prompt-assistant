#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/SuggestionPolicy.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPAInputContext *Context(NSString *bundleIdentifier, CPAInputScene scene) {
    return [[CPAInputContext alloc] initWithBundleIdentifier:bundleIdentifier
        scene:scene semanticConfidenceHigh:YES secureTextEntry:NO];
}

static CPAApplicationRule *Rule(CPAApplicationPolicyMode mode) {
    return [[CPAApplicationRule alloc] initWithMode:mode
        searchExceptionEnabled:NO remoteCompletionAuthorized:NO];
}

int main(void) {
    @autoreleasepool {
        CPASuggestionPolicyEngine *engine = [[CPASuggestionPolicyEngine alloc] init];
        CPAInputContext *codex = Context(@"com.openai.codex",
            CPAInputSceneLongFormEditor);
        CPAApplicationRule *recommended = Rule(CPAApplicationPolicyModeRecommended);

        CPASuggestionDecision *decision = [engine decisionForContext:codex
            rule:recommended globallyPaused:YES temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled
                && decision.reason == CPASuggestionPolicyReasonGlobalPause,
            @"global pause must stop all suggestion work with an explainable reason");

        CPAInputContext *password = [[CPAInputContext alloc]
            initWithBundleIdentifier:@"com.google.Chrome"
            scene:CPAInputSceneGeneralText semanticConfidenceHigh:YES
            secureTextEntry:YES];
        decision = [engine decisionForContext:password
            rule:Rule(CPAApplicationPolicyModeEnableOrdinaryInputs)
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled
                && decision.reason == CPASuggestionPolicyReasonHardSensitive,
            @"secure text must stay blocked even when the application is enabled");

        NSArray<NSNumber *> *hardScenes = @[
            @(CPAInputScenePassword), @(CPAInputSceneOneTimeCode),
            @(CPAInputSceneLogin), @(CPAInputScenePayment),
        ];
        for (NSNumber *scene in hardScenes) {
            decision = [engine decisionForContext:Context(@"com.electron.lark",
                    (CPAInputScene)scene.integerValue)
                rule:Rule(CPAApplicationPolicyModeEnableOrdinaryInputs)
                globallyPaused:NO temporarilyPaused:NO];
            Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled
                    && decision.reason == CPASuggestionPolicyReasonHardSensitive,
                @"password, OTP, login, and payment scenes must be non-overridable");
        }

        decision = [engine decisionForContext:Context(@"com.google.Chrome",
                CPAInputSceneSearch)
            rule:Rule(CPAApplicationPolicyModeEnableOrdinaryInputs)
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.reason == CPASuggestionPolicyReasonSearchProtected,
            @"search should be softly protected by default");
        CPAApplicationRule *searchException = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs
            searchExceptionEnabled:YES remoteCompletionAuthorized:YES];
        decision = [engine decisionForContext:Context(@"com.google.Chrome",
                CPAInputSceneSearch)
            rule:searchException globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"an explicit search exception may use local completion only");

        decision = [engine decisionForContext:codex
            rule:Rule(CPAApplicationPolicyModeDisabled)
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.reason == CPASuggestionPolicyReasonExplicitlyDisabled,
            @"an explicit application disable must override its preset");

        decision = [engine decisionForContext:codex rule:recommended
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalAndRemote
                && decision.contextMode == CPAContextAccessModeCodexConversation
                && decision.reason == CPASuggestionPolicyReasonPresetEnabled,
            @"Codex recommended mode should preserve the existing completion stack");

        decision = [engine decisionForContext:Context(@"com.workbuddy.workbuddy",
                CPAInputSceneLongFormEditor)
            rule:recommended globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && decision.contextMode == CPAContextAccessModeWorkBuddyConversation,
            @"WorkBuddy remains local-only with its own conversation context");

        decision = [engine decisionForContext:Context(@"com.tencent.workbuddy.mac",
                CPAInputSceneLongFormEditor)
            rule:recommended globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && decision.contextMode == CPAContextAccessModeWorkBuddyConversation,
            @"WorkBuddy 5.5 uses conversation context without implicit remote authorization");
        CPAApplicationRule *workBuddyRemote = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeRecommended
            searchExceptionEnabled:NO remoteCompletionAuthorized:YES];
        decision = [engine decisionForContext:Context(@"com.tencent.workbuddy.mac",
                CPAInputSceneLongFormEditor)
            rule:workBuddyRemote globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalAndRemote
                && decision.contextMode == CPAContextAccessModeWorkBuddyConversation,
            @"Explicit WorkBuddy authorization permits the remote context path");

        decision = [engine decisionForContext:Context(@"com.electron.lark",
                CPAInputSceneLongFormEditor)
            rule:recommended globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"Lark long-form editing should use its cautious local preset");
        decision = [engine decisionForContext:Context(@"com.electron.lark",
                CPAInputSceneChatComposer)
            rule:recommended globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"Lark chat should use local-only suggestions in safe global mode");
        decision = [engine decisionForContext:Context(@"com.tencent.xinWeChat",
                CPAInputSceneChatComposer)
            rule:recommended globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"WeChat chat should use local-only suggestions in safe global mode");

        CPAInputContext *unknown = Context(@"com.example.unknown",
            CPAInputSceneGeneralText);
        decision = [engine decisionForContext:unknown rule:recommended
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && decision.contextMode == CPAContextAccessModeCurrentInputOnly,
            @"ordinary applications should default to local current-input suggestions");
        decision = [engine decisionForContext:unknown
            rule:Rule(CPAApplicationPolicyModeEnableOrdinaryInputs)
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalOnly,
            @"users may explicitly enable an ordinary field in an unknown application");

        CPAInputContext *uncertain = [[CPAInputContext alloc]
            initWithBundleIdentifier:@"com.example.unknown"
            scene:CPAInputSceneGeneralText semanticConfidenceHigh:NO
            secureTextEntry:NO];
        decision = [engine decisionForContext:uncertain
            rule:Rule(CPAApplicationPolicyModeEnableOrdinaryInputs)
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.reason == CPASuggestionPolicyReasonInsufficientSemantics,
            @"explicit application enable must not authorize an uncertain field");

        CPAApplicationRule *remoteAuthorized = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs
            searchExceptionEnabled:NO remoteCompletionAuthorized:YES];
        decision = [engine decisionForContext:unknown rule:remoteAuthorized
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeLocalAndRemote
                && decision.contextMode == CPAContextAccessModeCurrentInputOnly,
            @"remote authorization must not grant non-Codex history access");

        NSArray<NSString *> *manualEnableApplications = @[
            @"com.google.Chrome",
            @"com.apple.Terminal",
            @"com.microsoft.VSCode",
        ];
        for (NSString *bundleIdentifier in manualEnableApplications) {
            decision = [engine decisionForContext:Context(bundleIdentifier,
                    CPAInputSceneGeneralText)
                rule:recommended globallyPaused:NO temporarilyPaused:NO];
            Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled
                    && decision.reason == CPASuggestionPolicyReasonPresetDisabled,
                @"browsers, terminals, and code editors must default off");
        }

        CPAInputContext *securityAgent = Context(@"com.apple.SecurityAgent",
            CPAInputSceneGeneralText);
        decision = [engine decisionForContext:securityAgent
            rule:Rule(CPAApplicationPolicyModeEnableOrdinaryInputs)
            globallyPaused:NO temporarilyPaused:NO];
        Assert(decision.outcome == CPASuggestionPolicyOutcomeDisabled
                && decision.reason == CPASuggestionPolicyReasonHardSensitive,
            @"system authorization applications must remain blocked after manual enable");

        Assert(decision.statusText.length > 0
                && [decision.statusText rangeOfString:@"com.example"].location
                    == NSNotFound,
            @"status feedback should explain the decision without exposing identifiers");

        NSLog(@"PASS: SuggestionPolicyTests");
    }
    return 0;
}
