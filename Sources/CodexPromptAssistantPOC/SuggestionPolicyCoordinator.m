#import "SuggestionPolicyCoordinator.h"

#import "ApplicationInputAdapter.h"
#import "SuggestionTriggerPolicy.h"

@interface CPASuggestionPolicyCoordinator ()
@property(nonatomic, strong) CPASuggestionPolicyStore *store;
@property(nonatomic, strong) CPAApplicationInputAdapter *inputAdapter;
@property(nonatomic, strong) CPASuggestionPolicyEngine *policyEngine;
@end

@implementation CPASuggestionPolicyCoordinator

- (instancetype)init {
    return [self initWithStore:[[CPASuggestionPolicyStore alloc] init]];
}

- (instancetype)initWithStore:(CPASuggestionPolicyStore *)store {
    self = [super init];
    if (self != nil) {
        _store = store;
        _inputAdapter = [[CPAApplicationInputAdapter alloc] init];
        _policyEngine = [[CPASuggestionPolicyEngine alloc] init];
    }
    return self;
}

- (NSUInteger)ruleVersion {
    return self.store.ruleVersion;
}

- (BOOL)shouldProbeMetadataForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0
        || [bundleIdentifier isEqualToString:@"com.openai.codex"]) {
        return NO;
    }
    CPAApplicationRule *rule = [self.store
        ruleForBundleIdentifier:bundleIdentifier];
    BOOL explicitlyEnabled =
        rule.mode == CPAApplicationPolicyModeEnableOrdinaryInputs;
    BOOL explicitlyDisabled = rule.mode == CPAApplicationPolicyModeDisabled;
    if (self.store.onlineScopesOnly && CPASuggestionPolicyApplicationIsBrowser(bundleIdentifier))
        return [self.store ruleForBundleIdentifier:@"com.electron.lark"].remoteCompletionAuthorized;
    if (self.store.onlineScopesOnly
        && ![CPASuggestionPolicyStore allowsOnlineScopeBundleIdentifier:bundleIdentifier]) return NO;
    CPAApplicationDefaultPolicyClass policyClass =
        CPASuggestionPolicyDefaultClassForApplication(bundleIdentifier);
    if (policyClass == CPAApplicationDefaultPolicyClassPermanentlyBlocked) {
        return NO;
    }
    BOOL probesByDefault =
        policyClass == CPAApplicationDefaultPolicyClassStandard
        || policyClass == CPAApplicationDefaultPolicyClassBrowser;
    return CPAGenericMetadataProbeMayStart(
        probesByDefault,
        explicitlyEnabled,
        explicitlyDisabled,
        NO,
        -1.0);
}

- (BOOL)isBrowserBundleIdentifier:(NSString *)bundleIdentifier {
    return CPASuggestionPolicyApplicationIsBrowser(bundleIdentifier);
}

- (CPASuggestionDecision *)decisionForBundleIdentifier:
    (NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    browserHost:(NSString *)browserHost
    globallyPaused:(BOOL)globallyPaused
    temporarilyPaused:(BOOL)temporarilyPaused {
    CPAApplicationRule *applicationRule = [self.store
        ruleForBundleIdentifier:bundleIdentifier];
    BOOL browser = [self isBrowserBundleIdentifier:bundleIdentifier];
    CPAApplicationRule *effectiveRule = applicationRule;
    if (browser && (self.store.onlineScopesOnly || applicationRule.mode != CPAApplicationPolicyModeDisabled)) {
        effectiveRule = [self.store ruleForBrowserHost:browserHost];
    }
    CPAApplicationDefaultPolicyClass policyClass =
        CPASuggestionPolicyDefaultClassForApplication(bundleIdentifier);
    BOOL allowOrdinaryTextInference =
        effectiveRule.mode == CPAApplicationPolicyModeEnableOrdinaryInputs
        || (effectiveRule.mode == CPAApplicationPolicyModeRecommended
            && policyClass == CPAApplicationDefaultPolicyClassStandard);
    CPAInputSceneClassification *classification = [self.inputAdapter
        classificationForBundleIdentifier:bundleIdentifier
        role:role
        subrole:subrole
        semanticMetadata:semanticMetadata
        allowOrdinaryTextInference:allowOrdinaryTextInference];
    CPAInputContext *context = [[CPAInputContext alloc]
        initWithBundleIdentifier:bundleIdentifier
        scene:classification.scene
        semanticConfidenceHigh:classification.confidenceHigh
        secureTextEntry:classification.scene == CPAInputScenePassword];
    return [self.policyEngine decisionForContext:context
        rule:effectiveRule
        globallyPaused:globallyPaused
        temporarilyPaused:temporarilyPaused];
}

@end
