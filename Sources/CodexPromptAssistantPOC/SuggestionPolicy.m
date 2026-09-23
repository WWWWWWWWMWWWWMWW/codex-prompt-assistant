#import "SuggestionPolicy.h"

static NSString *const CPACodexPolicyBundleIdentifier = @"com.openai.codex";
static NSString *const CPAWorkBuddyPolicyBundleIdentifier = @"com.workbuddy.workbuddy";
static NSString *const CPALarkPolicyBundleIdentifier = @"com.electron.lark";
static NSString *const CPAWeChatPolicyBundleIdentifier = @"com.tencent.xinWeChat";

static BOOL CPAIdentifierMatchesAnyPrefix(
    NSString *bundleIdentifier,
    NSArray<NSString *> *prefixes
) {
    for (NSString *prefix in prefixes) {
        if ([bundleIdentifier hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

BOOL CPASuggestionPolicyApplicationIsBrowser(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) {
        return NO;
    }
    static NSSet<NSString *> *browserApplications;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        browserApplications = [NSSet setWithArray:@[
            @"com.apple.Safari",
            @"com.apple.SafariTechnologyPreview",
            @"com.google.Chrome",
            @"com.google.Chrome.beta",
            @"com.google.Chrome.canary",
            @"org.chromium.Chromium",
            @"org.mozilla.firefox",
            @"org.mozilla.firefoxdeveloperedition",
            @"com.microsoft.edgemac",
            @"com.brave.Browser",
            @"company.thebrowser.Browser",
            @"com.kagi.kagimacOS",
        ]];
    });
    return [browserApplications containsObject:bundleIdentifier];
}

CPAApplicationDefaultPolicyClass
CPASuggestionPolicyDefaultClassForApplication(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) {
        return CPAApplicationDefaultPolicyClassPermanentlyBlocked;
    }
    if ([bundleIdentifier isEqualToString:CPACodexPolicyBundleIdentifier]) {
        return CPAApplicationDefaultPolicyClassCodex;
    }
    if ([bundleIdentifier isEqualToString:@"local.codex.prompt-assistant-poc"]
        || [bundleIdentifier isEqualToString:@"local.codex.prompt-assistant-installer"]
        || CPAIdentifierMatchesAnyPrefix(bundleIdentifier, @[
            @"com.apple.SecurityAgent",
            @"com.apple.LocalAuthentication",
            @"com.apple.authorizationhost",
            @"com.apple.loginwindow",
        ])) {
        return CPAApplicationDefaultPolicyClassPermanentlyBlocked;
    }
    if (CPASuggestionPolicyApplicationIsBrowser(bundleIdentifier)) {
        return CPAApplicationDefaultPolicyClassBrowser;
    }
    static NSSet<NSString *> *manualEnableApplications;
    static dispatch_once_t manualOnceToken;
    dispatch_once(&manualOnceToken, ^{
        manualEnableApplications = [NSSet setWithArray:@[
            @"com.apple.Terminal",
            @"com.googlecode.iterm2",
            @"dev.warp.Warp-Stable",
            @"com.github.wez.wezterm",
            @"org.alacritty",
            @"com.microsoft.VSCode",
            @"com.microsoft.VSCodeInsiders",
            @"com.todesktop.230313mzl4w4u92",
            @"com.apple.dt.Xcode",
            @"dev.zed.Zed",
            @"com.sublimetext.4",
        ]];
    });
    if ([manualEnableApplications containsObject:bundleIdentifier]
        || [bundleIdentifier hasPrefix:@"com.jetbrains."]) {
        return CPAApplicationDefaultPolicyClassManualEnable;
    }
    return CPAApplicationDefaultPolicyClassStandard;
}

BOOL CPASuggestionPolicyApplicationIsKnown(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) {
        return NO;
    }
    static NSSet<NSString *> *knownApplications;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownApplications = [NSSet setWithArray:@[
            CPACodexPolicyBundleIdentifier,
            CPAWorkBuddyPolicyBundleIdentifier,
            @"com.tencent.workbuddy.mac",
            CPALarkPolicyBundleIdentifier,
            CPAWeChatPolicyBundleIdentifier,
            @"com.apple.Safari",
            @"com.google.Chrome",
            @"org.mozilla.firefox",
        ]];
    });
    return [knownApplications containsObject:bundleIdentifier];
}

@interface CPAInputContext ()
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, readwrite) CPAInputScene scene;
@property(nonatomic, readwrite) BOOL semanticConfidenceHigh;
@property(nonatomic, readwrite) BOOL secureTextEntry;
@end

@implementation CPAInputContext

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    scene:(CPAInputScene)scene
    semanticConfidenceHigh:(BOOL)semanticConfidenceHigh
    secureTextEntry:(BOOL)secureTextEntry {
    self = [super init];
    if (self != nil) {
        _bundleIdentifier = [bundleIdentifier copy];
        _scene = scene;
        _semanticConfidenceHigh = semanticConfidenceHigh;
        _secureTextEntry = secureTextEntry;
    }
    return self;
}

@end

@interface CPAApplicationRule ()
@property(nonatomic, readwrite) CPAApplicationPolicyMode mode;
@property(nonatomic, readwrite) BOOL searchExceptionEnabled;
@property(nonatomic, readwrite) BOOL remoteCompletionAuthorized;
@end

@implementation CPAApplicationRule

- (instancetype)initWithMode:(CPAApplicationPolicyMode)mode
    searchExceptionEnabled:(BOOL)searchExceptionEnabled
    remoteCompletionAuthorized:(BOOL)remoteCompletionAuthorized {
    self = [super init];
    if (self != nil) {
        _mode = mode;
        _searchExceptionEnabled = searchExceptionEnabled;
        _remoteCompletionAuthorized = remoteCompletionAuthorized;
    }
    return self;
}

@end

@interface CPASuggestionDecision ()
@property(nonatomic, readwrite) CPASuggestionPolicyOutcome outcome;
@property(nonatomic, readwrite) CPAContextAccessMode contextMode;
@property(nonatomic, readwrite) CPASuggestionPolicyReason reason;
@property(nonatomic, copy, readwrite) NSString *statusText;
- (instancetype)initWithOutcome:(CPASuggestionPolicyOutcome)outcome
    contextMode:(CPAContextAccessMode)contextMode
    reason:(CPASuggestionPolicyReason)reason
    statusText:(NSString *)statusText;
@end

@implementation CPASuggestionDecision

- (instancetype)initWithOutcome:(CPASuggestionPolicyOutcome)outcome
    contextMode:(CPAContextAccessMode)contextMode
    reason:(CPASuggestionPolicyReason)reason
    statusText:(NSString *)statusText {
    self = [super init];
    if (self != nil) {
        _outcome = outcome;
        _contextMode = contextMode;
        _reason = reason;
        _statusText = [statusText copy];
    }
    return self;
}

@end

@implementation CPASuggestionPolicyEngine

- (CPASuggestionDecision *)disabledDecisionWithReason:
    (CPASuggestionPolicyReason)reason statusText:(NSString *)statusText {
    return [[CPASuggestionDecision alloc]
        initWithOutcome:CPASuggestionPolicyOutcomeDisabled
        contextMode:CPAContextAccessModeNone
        reason:reason
        statusText:statusText];
}

- (BOOL)isHardSensitiveContext:(CPAInputContext *)context {
    return CPASuggestionPolicyDefaultClassForApplication(
            context.bundleIdentifier)
            == CPAApplicationDefaultPolicyClassPermanentlyBlocked
        || context.secureTextEntry
        || context.scene == CPAInputScenePassword
        || context.scene == CPAInputSceneOneTimeCode
        || context.scene == CPAInputSceneLogin
        || context.scene == CPAInputScenePayment;
}

- (BOOL)isOrdinaryScene:(CPAInputScene)scene {
    return scene == CPAInputSceneGeneralText
        || scene == CPAInputSceneLongFormEditor
        || scene == CPAInputSceneChatComposer;
}

- (BOOL)recommendedPresetEnablesContext:(CPAInputContext *)context {
    CPAApplicationDefaultPolicyClass policyClass =
        CPASuggestionPolicyDefaultClassForApplication(context.bundleIdentifier);
    return (policyClass == CPAApplicationDefaultPolicyClassCodex
            || policyClass == CPAApplicationDefaultPolicyClassStandard)
        && [self isOrdinaryScene:context.scene];
}

- (CPASuggestionDecision *)enabledDecisionForContext:(CPAInputContext *)context
    rule:(CPAApplicationRule *)rule
    reason:(CPASuggestionPolicyReason)reason {
    BOOL isCodex = [context.bundleIdentifier
        isEqualToString:CPACodexPolicyBundleIdentifier];
    BOOL allowsRemote = isCodex || rule.remoteCompletionAuthorized;
    CPASuggestionPolicyOutcome outcome = allowsRemote
        ? CPASuggestionPolicyOutcomeLocalAndRemote
        : CPASuggestionPolicyOutcomeLocalOnly;
    CPAContextAccessMode contextMode = isCodex
        ? CPAContextAccessModeCodexConversation
        : (CPASuggestionPolicyApplicationIsWorkBuddy(context.bundleIdentifier)
            ? CPAContextAccessModeWorkBuddyConversation : CPAContextAccessModeCurrentInputOnly);
    return [[CPASuggestionDecision alloc] initWithOutcome:outcome
        contextMode:contextMode
        reason:reason
        statusText:allowsRemote ? @"已启用 · 本地与远程" : @"已启用 · 仅本地"];
}

- (CPASuggestionDecision *)decisionForContext:(CPAInputContext *)context
    rule:(CPAApplicationRule *)rule
    globallyPaused:(BOOL)globallyPaused
    temporarilyPaused:(BOOL)temporarilyPaused {
    if (globallyPaused) {
        return [self disabledDecisionWithReason:CPASuggestionPolicyReasonGlobalPause
            statusText:@"已暂停"];
    }
    if (temporarilyPaused) {
        return [self disabledDecisionWithReason:CPASuggestionPolicyReasonTemporaryPause
            statusText:@"已临时暂停"];
    }
    if ([self isHardSensitiveContext:context]) {
        return [self disabledDecisionWithReason:CPASuggestionPolicyReasonHardSensitive
            statusText:@"敏感场景 · 已保护"];
    }
    if (!context.semanticConfidenceHigh || context.scene == CPAInputSceneUnknown) {
        return [self disabledDecisionWithReason:
            CPASuggestionPolicyReasonInsufficientSemantics
            statusText:@"场景不明确 · 未启用"];
    }
    if (rule.mode == CPAApplicationPolicyModeDisabled) {
        return [self disabledDecisionWithReason:
            CPASuggestionPolicyReasonExplicitlyDisabled
            statusText:@"当前应用 · 已关闭"];
    }
    if (context.scene == CPAInputSceneSearch) {
        if (!rule.searchExceptionEnabled) {
            return [self disabledDecisionWithReason:
                CPASuggestionPolicyReasonSearchProtected
                statusText:@"搜索框 · 已保护"];
        }
        return [[CPASuggestionDecision alloc]
            initWithOutcome:CPASuggestionPolicyOutcomeLocalOnly
            contextMode:CPAContextAccessModeCurrentInputOnly
            reason:CPASuggestionPolicyReasonUserEnabled
            statusText:@"搜索例外 · 仅本地"];
    }
    if (![self isOrdinaryScene:context.scene]) {
        return [self disabledDecisionWithReason:
            CPASuggestionPolicyReasonInsufficientSemantics
            statusText:@"场景不支持 · 未启用"];
    }
    if (rule.mode == CPAApplicationPolicyModeEnableOrdinaryInputs) {
        return [self enabledDecisionForContext:context rule:rule
            reason:CPASuggestionPolicyReasonUserEnabled];
    }
    if ([self recommendedPresetEnablesContext:context]) {
        return [self enabledDecisionForContext:context rule:rule
            reason:CPASuggestionPolicyReasonPresetEnabled];
    }
    return [self disabledDecisionWithReason:
        CPASuggestionPolicyReasonPresetDisabled
        statusText:@"推荐策略 · 需手动开启"];
}

@end
