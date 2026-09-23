#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/SafeInputContextCollector.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

@interface CPAFakeInputBodyReader : NSObject <CPAInputBodyReading>
@property(nonatomic) NSUInteger readCount;
@end

@implementation CPAFakeInputBodyReader
- (nullable id)readInputBodyForMetadata:(CPAFocusedInputMetadata *)metadata {
    (void)metadata;
    self.readCount += 1;
    return @"opaque-test-body";
}
@end

static CPAFocusedInputMetadata *Metadata(
    NSString *bundleIdentifier,
    NSString *role,
    NSString *subrole,
    NSArray<NSString *> *semantics,
    NSString *host
) {
    return [[CPAFocusedInputMetadata alloc]
        initWithBundleIdentifier:bundleIdentifier
        role:role
        subrole:subrole
        semanticMetadata:semantics
        browserHost:host];
}

int main(void) {
    @autoreleasepool {
        NSString *suiteName = [NSString stringWithFormat:
            @"local.codex.prompt-assistant.collector-tests.%@",
            NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [defaults removePersistentDomainForName:suiteName];
        CPASuggestionPolicyStore *store = [[CPASuggestionPolicyStore alloc]
            initWithUserDefaults:defaults];
        CPASuggestionPolicyCoordinator *coordinator =
            [[CPASuggestionPolicyCoordinator alloc] initWithStore:store];
        CPAFakeInputBodyReader *reader = [[CPAFakeInputBodyReader alloc] init];
        CPASafeInputContextCollector *collector = [[CPASafeInputContextCollector alloc]
            initWithPolicyCoordinator:coordinator bodyReader:reader];

        CPASafeInputContextCollection *result = [collector collectContextForMetadata:
            Metadata(@"com.workbuddy.workbuddy", @"AXTextField",
                @"AXSecureTextField", @[], @"")
            globallyPaused:NO temporarilyPaused:NO];
        Assert(result.decision.reason == CPASuggestionPolicyReasonHardSensitive
                && result.inputBody == nil && reader.readCount == 0,
            @"secure fields must not call the body reader");

        result = [collector collectContextForMetadata:
            Metadata(@"com.workbuddy.workbuddy", @"AXTextField", @"",
                @[@"search query"], @"")
            globallyPaused:NO temporarilyPaused:NO];
        Assert(result.decision.outcome == CPASuggestionPolicyOutcomeDisabled
                && reader.readCount == 0,
            @"protected search fields must not call the body reader");

        result = [collector collectContextForMetadata:
            Metadata(@"com.example.unknown", @"AXTextArea", @"", @[], @"")
            globallyPaused:NO temporarilyPaused:NO];
        Assert(result.decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && result.inputBody != nil && reader.readCount == 1,
            @"ordinary applications should perform one current-input body read");

        result = [collector collectContextForMetadata:
            Metadata(@"com.apple.SecurityAgent", @"AXTextField", @"", @[], @"")
            globallyPaused:NO temporarilyPaused:NO];
        Assert(result.decision.reason == CPASuggestionPolicyReasonHardSensitive
                && result.inputBody == nil && reader.readCount == 1,
            @"system authorization applications must never call the body reader");

        result = [collector collectContextForMetadata:
            Metadata(@"com.workbuddy.workbuddy", @"AXTextArea", @"", @[], @"")
            globallyPaused:YES temporarilyPaused:NO];
        Assert(result.decision.reason == CPASuggestionPolicyReasonGlobalPause
                && reader.readCount == 1,
            @"global pause must short-circuit before a body read");

        result = [collector collectContextForMetadata:
            Metadata(@"com.workbuddy.workbuddy", @"AXTextArea", @"", @[], @"")
            globallyPaused:NO temporarilyPaused:NO];
        Assert(result.decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && result.inputBody != nil && reader.readCount == 2,
            @"an allowed WorkBuddy editor should perform one body read");

        CPAApplicationRule *siteRule = [[CPAApplicationRule alloc]
            initWithMode:CPAApplicationPolicyModeEnableOrdinaryInputs
            searchExceptionEnabled:NO remoteCompletionAuthorized:NO];
        [store setRule:siteRule forBrowserHost:@"docs.example.com"];
        result = [collector collectContextForMetadata:
            Metadata(@"com.google.Chrome", @"AXTextArea", @"", @[],
                @"docs.example.com")
            globallyPaused:NO temporarilyPaused:NO];
        Assert(result.decision.outcome == CPASuggestionPolicyOutcomeLocalOnly
                && reader.readCount == 3,
            @"an exact enabled site should perform one body read");

        // Enabling a site or search exception must never override sensitivity.
        NSUInteger safeReadCount = reader.readCount;
        for (NSInteger mode = CPAApplicationPolicyModeRecommended;
                mode <= CPAApplicationPolicyModeDisabled; mode++) {
            CPAApplicationRule *rule = [[CPAApplicationRule alloc]
                initWithMode:mode searchExceptionEnabled:YES
                remoteCompletionAuthorized:YES];
            [store setRule:rule forBundleIdentifier:@"com.example.editor"];
            [store setRule:rule forBrowserHost:@"docs.example.com"];
            for (NSString *bundle in @[@"com.example.editor", @"com.google.Chrome"]) {
                for (NSString *hint in @[@"password", @"verification code", @"login", @"payment"]) {
                    result = [collector collectContextForMetadata:
                        Metadata(bundle, @"AXTextField", @"", @[hint], @"docs.example.com")
                        globallyPaused:NO temporarilyPaused:NO];
                    Assert(result.inputBody == nil && reader.readCount == safeReadCount,
                        @"sensitive semantics must never read a body in any mode");
                }
                result = [collector collectContextForMetadata:
                    Metadata(bundle, @"AXTextField", @"AXSecureTextField", @[], @"docs.example.com")
                    globallyPaused:NO temporarilyPaused:NO];
                Assert(result.inputBody == nil && reader.readCount == safeReadCount,
                    @"secure inputs must never read a body in any mode");
            }
        }
        for (NSString *host in @[@"", @"other.example.com", @"sub.docs.example.com"]) {
            result = [collector collectContextForMetadata:
                Metadata(@"com.google.Chrome", @"AXTextArea", @"", @[], host)
                globallyPaused:NO temporarilyPaused:NO];
            Assert(result.inputBody == nil && reader.readCount == safeReadCount,
                @"unknown and sibling sites must remain unread");
        }

        [defaults removePersistentDomainForName:suiteName];
        NSLog(@"PASS: SafeInputContextCollectorTests");
    }
    return 0;
}
