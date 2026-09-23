#import <Foundation/Foundation.h>
#import "../../Sources/CodexPromptAssistantPOC/OnlineScopeDefaults.h"
#import "../../Sources/CodexPromptAssistantPOC/SuggestionPolicyCoordinator.h"
#import "../../Sources/CodexPromptAssistantPOC/SafeInputContextCollector.h"
@interface OnlineBodyReader : NSObject <CPAInputBodyReading>
@property NSUInteger reads;
@end
@implementation OnlineBodyReader
- (id)readInputBodyForMetadata:(CPAFocusedInputMetadata *)metadata { (void)metadata; self.reads++; return @"synthetic input"; }
@end
#define Check(x) do { if (!(x)) { NSLog(@"FAIL online scopes line %d", __LINE__); exit(1); } } while (0)
static CPASuggestionDecision *Decision(CPASuggestionPolicyCoordinator *c, NSString *bundle, NSString *host, NSString *subrole) {
    return [c decisionForBundleIdentifier:bundle role:@"AXTextArea" subrole:subrole semanticMetadata:@[@"message input"] browserHost:host globallyPaused:NO temporarilyPaused:NO];
}
int main(void) { @autoreleasepool {
    NSString *suite = [@"test.online-scopes." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    CPASuggestionPolicyStore *store = [[CPASuggestionPolicyStore alloc] initWithUserDefaults:defaults];
    // Legacy authorization must not become implicit online selection.
    [store setRule:[[CPAApplicationRule alloc] initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs searchExceptionEnabled:YES remoteCompletionAuthorized:YES] forBundleIdentifier:@"com.apple.TextEdit"];
    store.onlineScopesOnly = YES;
    CPASuggestionPolicyCoordinator *c = [[CPASuggestionPolicyCoordinator alloc] initWithStore:store];
    Check(Decision(c,@"com.openai.codex",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.apple.TextEdit",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(![c shouldProbeMetadataForBundleIdentifier:@"com.apple.TextEdit"]);
    NSUInteger v = store.ruleVersion;
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.openai.codex" host:@""];
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.apple.TextEdit" host:@""];
    Check(store.ruleVersion == v + 2);
    Check(Decision(c,@"com.openai.codex",@"",@"").outcome == CPASuggestionPolicyOutcomeLocalAndRemote);
    Check(Decision(c,@"com.apple.TextEdit",@"",@"").outcome == CPASuggestionPolicyOutcomeLocalAndRemote);
    Check(Decision(c,@"com.apple.Notes",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.apple.TextEdit",@"",@"AXSecureTextField").outcome == CPASuggestionPolicyOutcomeDisabled);
    // Existing 0.3.0 selections outside the new catalogue remain inert, even
    // when they were persisted as enabled before the upgrade.
    [defaults setObject:@{@"applications":@{@"com.apple.TextEdit":@YES,@"com.openai.codex":@YES,
        @"com.tencent.workbuddy.mac":@YES,@"com.apple.Passwords":@YES,@"com.apple.AppStore":@YES},
        @"sites":@{@"docs.example.com":@YES}} forKey:@"OnlineCompletionScopes.v1"];
    Check(![c shouldProbeMetadataForBundleIdentifier:@"com.google.Chrome"]);
    Check([c shouldProbeMetadataForBundleIdentifier:@"com.tencent.workbuddy.mac"]);
    Check(Decision(c,@"com.google.Chrome",@"docs.example.com",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.tencent.workbuddy.mac",@"",@"").outcome == CPASuggestionPolicyOutcomeLocalAndRemote);
    Check(Decision(c,@"com.apple.AppStore",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.apple.Passwords",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(store.storedBrowserHosts.count == 0 && store.storedApplicationIdentifiers.count == 3);
    NSUInteger beforeRejected = store.ruleVersion;
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.apple.AppStore" host:@""];
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.google.Chrome" host:@"docs.example.com"];
    Check(store.ruleVersion == beforeRejected);
    NSSet *expected = [NSSet setWithArray:@[@"com.apple.Stickies",@"com.apple.Terminal",@"com.apple.TextEdit",@"com.apple.freeform",@"com.electron.lark",@"com.kingsoft.wpsoffice.mac",@"com.openai.codex",@"com.tencent.workbuddy.mac",@"com.tencent.codebuddy",@"com.tencent.xinWeChat"]];
    NSArray *targets = CPASuggestionPolicyStore.onlineScopeTargets;
    Check(targets.count == 10 && [[NSSet setWithArray:[targets valueForKey:@"bundle"]] isEqual:expected]);
    for (NSDictionary *target in targets) {
        Check([target[@"host"] length] == 0);
        if ([target[@"bundle"] isEqual:@"com.openai.codex"]) Check([target[@"title"] isEqual:@"Codex"]);
        [store setOnlineScopeSelected:YES bundleIdentifier:target[@"bundle"] host:@""];
        Check(Decision(c,target[@"bundle"],@"",@"").outcome == CPASuggestionPolicyOutcomeLocalAndRemote);
    }
    Check([c shouldProbeMetadataForBundleIdentifier:@"com.google.Chrome"]);
    Check(Decision(c,@"com.google.Chrome",@"tenant.feishu.cn",@"").outcome == CPASuggestionPolicyOutcomeLocalAndRemote);
    for (NSString *host in @[@"", @"example.com", @"feishu.cn.evil.test", @"evilfeishu.cn", @"a.b.feishu.cn"])
        Check(Decision(c,@"com.google.Chrome",host,@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.google.Chrome",@"tenant.feishu.cn",@"AXSecureTextField").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check([c decisionForBundleIdentifier:@"com.google.Chrome" role:@"AXTextField" subrole:@""
        semanticMetadata:@[@"地址和搜索栏"] browserHost:@"" globallyPaused:NO temporarilyPaused:NO].outcome == CPASuggestionPolicyOutcomeDisabled);
    Check([c decisionForBundleIdentifier:@"com.google.Chrome" role:@"AXTextArea" subrole:@""
        semanticMetadata:@[@"搜索"] browserHost:@"tenant.feishu.cn" globallyPaused:NO temporarilyPaused:NO].outcome == CPASuggestionPolicyOutcomeDisabled);
    [store setOnlineScopeSelected:NO bundleIdentifier:@"com.electron.lark" host:@""];
    Check(![c shouldProbeMetadataForBundleIdentifier:@"com.google.Chrome"]);
    Check(Decision(c,@"com.google.Chrome",@"tenant.feishu.cn",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.electron.lark",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.electron.lark" host:@""];
    [store setOnlineScopeSelected:NO bundleIdentifier:@"com.openai.codex" host:@""];
    Check(Decision(c,@"com.openai.codex",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.apple.TextEdit",@"",@"").outcome == CPASuggestionPolicyOutcomeLocalAndRemote);
    CPASuggestionPolicyStore *reloaded = [[CPASuggestionPolicyStore alloc] initWithUserDefaults:defaults]; reloaded.onlineScopesOnly = YES;
    Check([reloaded ruleForBundleIdentifier:@"com.apple.TextEdit"].remoteCompletionAuthorized);
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.apple.SecurityAgent" host:@""];
    Check(Decision(c,@"com.apple.SecurityAgent",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    OnlineBodyReader *reader = [OnlineBodyReader new];
    CPASafeInputContextCollector *collector = [[CPASafeInputContextCollector alloc] initWithPolicyCoordinator:c bodyReader:reader];
    CPAFocusedInputMetadata *input = [[CPAFocusedInputMetadata alloc] initWithBundleIdentifier:@"com.apple.TextEdit" role:@"AXTextArea" subrole:@"" semanticMetadata:@[@"document"] browserHost:@""];
    Check([collector collectContextForMetadata:input globallyPaused:NO temporarilyPaused:NO].inputBody != nil && reader.reads == 1);
    [store setOnlineScopeSelected:NO bundleIdentifier:@"com.apple.TextEdit" host:@""];
    Check([collector collectContextForMetadata:input globallyPaused:NO temporarilyPaused:NO].inputBody == nil && reader.reads == 1);
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.apple.TextEdit" host:@""];
    Check([collector collectContextForMetadata:input globallyPaused:YES temporarilyPaused:NO].inputBody == nil && reader.reads == 1);
    CPAFocusedInputMetadata *search = [[CPAFocusedInputMetadata alloc] initWithBundleIdentifier:@"com.apple.TextEdit" role:@"AXTextField" subrole:@"" semanticMetadata:@[@"search query"] browserHost:@""];
    Check([collector collectContextForMetadata:search globallyPaused:NO temporarilyPaused:NO].inputBody == nil && reader.reads == 1);
    CPAFocusedInputMetadata *webDocument = [[CPAFocusedInputMetadata alloc] initWithBundleIdentifier:@"com.google.Chrome"
        role:@"AXTextArea" subrole:@"" semanticMetadata:@[@"document editor"] browserHost:@"tenant.feishu.cn"];
    NSUInteger webReads = reader.reads;
    Check([collector collectContextForMetadata:webDocument globallyPaused:NO temporarilyPaused:NO].inputBody != nil
        && reader.reads == webReads + 1);
    [store setOnlineScopeSelected:NO bundleIdentifier:@"com.electron.lark" host:@""];
    Check([collector collectContextForMetadata:webDocument globallyPaused:NO temporarilyPaused:NO].inputBody == nil
        && reader.reads == webReads + 1);
    [store setOnlineScopeSelected:YES bundleIdentifier:@"com.electron.lark" host:@""];
    CPAFocusedInputMetadata *unknownSite = [[CPAFocusedInputMetadata alloc] initWithBundleIdentifier:@"com.google.Chrome"
        role:@"AXTextArea" subrole:@"" semanticMetadata:@[@"document editor"] browserHost:@"unknown.example.com"];
    Check([collector collectContextForMetadata:unknownSite globallyPaused:NO temporarilyPaused:NO].inputBody == nil
        && reader.reads == webReads + 1);
    [defaults setObject:CPAOnlineScopesWithInstallationDefaults(nil) forKey:@"OnlineCompletionScopes.v1"];
    Check(Decision(c,@"com.openai.codex",@"",@"").outcome == CPASuggestionPolicyOutcomeLocalAndRemote);
    Check(Decision(c,@"com.tencent.workbuddy.mac",@"",@"").contextMode == CPAContextAccessModeWorkBuddyConversation);
    Check(Decision(c,@"com.tencent.workbuddy.mac",@"",@"AXSecureTextField").outcome == CPASuggestionPolicyOutcomeDisabled);
    Check(Decision(c,@"com.apple.TextEdit",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    [store setOnlineScopeSelected:NO bundleIdentifier:@"com.tencent.workbuddy.mac" host:@""];
    [defaults setObject:CPAOnlineScopesWithInstallationDefaults([defaults objectForKey:@"OnlineCompletionScopes.v1"]) forKey:@"OnlineCompletionScopes.v1"];
    Check(Decision(c,@"com.tencent.workbuddy.mac",@"",@"").outcome == CPASuggestionPolicyOutcomeDisabled);
    [defaults removePersistentDomainForName:suite];
    NSLog(@"PASS online scopes: exact ten apps/union/removed app and site rejection/Codex/revoke/persistence/sensitive guard/legacy isolation.");
} return 0; }
