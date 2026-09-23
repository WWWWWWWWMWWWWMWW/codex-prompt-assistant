#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/SuggestionPolicyStore.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSString *suiteName = [NSString stringWithFormat:
            @"local.codex.prompt-assistant.policy-tests.%@", NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [defaults removePersistentDomainForName:suiteName];
        CPASuggestionPolicyStore *store = [[CPASuggestionPolicyStore alloc]
            initWithUserDefaults:defaults];

        CPAApplicationRule *rule = [store ruleForBundleIdentifier:@"com.electron.lark"];
        Assert(rule.mode == CPAApplicationPolicyModeRecommended
                && !rule.searchExceptionEnabled
                && !rule.remoteCompletionAuthorized,
            @"an application without an override should use the safe recommended mode");

        NSUInteger initialVersion = store.ruleVersion;
        CPAApplicationRule *custom = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs
            searchExceptionEnabled:YES remoteCompletionAuthorized:YES];
        [store setRule:custom forBundleIdentifier:@"com.electron.lark"];
        rule = [store ruleForBundleIdentifier:@"com.electron.lark"];
        Assert(rule.mode == CPAApplicationPolicyModeEnableOrdinaryInputs
                && rule.searchExceptionEnabled
                && rule.remoteCompletionAuthorized
                && store.ruleVersion > initialVersion,
            @"application overrides should persist and invalidate cached decisions");

        Assert([[CPASuggestionPolicyStore normalizedBrowserHost:
                @" HTTPS://Example.COM:443/private/path?token=secret "]
                isEqualToString:@"example.com"],
            @"browser rules should keep only a normalized host");
        Assert([[CPASuggestionPolicyStore normalizedBrowserHost:@"Sub.Example.com."]
                isEqualToString:@"sub.example.com"],
            @"plain host input should be normalized without a trailing dot");
        Assert([CPASuggestionPolicyStore normalizedBrowserHost:@"not a host"].length == 0,
            @"invalid host text must not become a persisted site rule");

        CPAApplicationRule *siteRule = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs
            searchExceptionEnabled:NO remoteCompletionAuthorized:NO];
        BOOL saved = [store setRule:siteRule
            forBrowserHost:@"https://Docs.Example.com/editor/private?q=secret"];
        Assert(saved, @"a valid browser host should be saved");
        rule = [store ruleForBrowserHost:@"docs.example.com"];
        Assert(rule.mode == CPAApplicationPolicyModeEnableOrdinaryInputs,
            @"site rules should resolve by normalized host");
        NSString *persistedDescription = [[defaults persistentDomainForName:suiteName]
            description];
        Assert([persistedDescription containsString:@"docs.example.com"]
                && ![persistedDescription containsString:@"/editor/private"]
                && ![persistedDescription containsString:@"secret"],
            @"persisted policy data must never retain URL paths or query values");

        [defaults setObject:@{
            @"schemaVersion": @1,
            @"applications": @{
                @"com.example.corrupt": @{
                    @"mode": @99,
                    @"searchException": @"not-a-number",
                    @"remoteAuthorized": @[],
                },
            },
        } forKey:CPASuggestionPolicyStoreDefaultsKey];
        CPASuggestionPolicyStore *corruptStore = [[CPASuggestionPolicyStore alloc]
            initWithUserDefaults:defaults];
        rule = [corruptStore ruleForBundleIdentifier:@"com.example.corrupt"];
        Assert(rule.mode == CPAApplicationPolicyModeRecommended
                && !rule.searchExceptionEnabled
                && !rule.remoteCompletionAuthorized,
            @"corrupt values should fail closed to the recommended rule");

        [defaults setObject:@{
            @"schemaVersion": @999,
            @"applications": @{ @"com.electron.lark": @{
                @"mode": @(CPAApplicationPolicyModeEnableOrdinaryInputs),
            } },
        } forKey:CPASuggestionPolicyStoreDefaultsKey];
        CPASuggestionPolicyStore *futureStore = [[CPASuggestionPolicyStore alloc]
            initWithUserDefaults:defaults];
        rule = [futureStore ruleForBundleIdentifier:@"com.electron.lark"];
        Assert(rule.mode == CPAApplicationPolicyModeRecommended,
            @"an unsupported schema must fail closed instead of guessing");

        [defaults removePersistentDomainForName:suiteName];
        NSLog(@"PASS: SuggestionPolicyStoreTests");
    }
    return 0;
}
