#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_INLINE BOOL CPASuggestionPolicyApplicationIsWorkBuddy(NSString *bundleIdentifier) {
    return [bundleIdentifier isEqualToString:@"com.workbuddy.workbuddy"]
        || [bundleIdentifier isEqualToString:@"com.tencent.workbuddy.mac"];
}

typedef NS_ENUM(NSInteger, CPAInputScene) {
    CPAInputSceneUnknown = 0,
    CPAInputSceneGeneralText,
    CPAInputSceneLongFormEditor,
    CPAInputSceneChatComposer,
    CPAInputSceneSearch,
    CPAInputSceneLogin,
    CPAInputScenePassword,
    CPAInputSceneOneTimeCode,
    CPAInputScenePayment,
};

typedef NS_ENUM(NSInteger, CPAApplicationPolicyMode) {
    CPAApplicationPolicyModeRecommended = 0,
    CPAApplicationPolicyModeEnableOrdinaryInputs,
    CPAApplicationPolicyModeDisabled,
};

typedef NS_ENUM(NSInteger, CPASuggestionPolicyOutcome) {
    CPASuggestionPolicyOutcomeDisabled = 0,
    CPASuggestionPolicyOutcomeLocalOnly,
    CPASuggestionPolicyOutcomeLocalAndRemote,
};

typedef NS_ENUM(NSInteger, CPAContextAccessMode) {
    CPAContextAccessModeNone = 0,
    CPAContextAccessModeCurrentInputOnly,
    CPAContextAccessModeCodexConversation,
    CPAContextAccessModeWorkBuddyConversation,
};

typedef NS_ENUM(NSInteger, CPAApplicationDefaultPolicyClass) {
    CPAApplicationDefaultPolicyClassStandard = 0,
    CPAApplicationDefaultPolicyClassBrowser,
    CPAApplicationDefaultPolicyClassManualEnable,
    CPAApplicationDefaultPolicyClassPermanentlyBlocked,
    CPAApplicationDefaultPolicyClassCodex,
};

typedef NS_ENUM(NSInteger, CPASuggestionPolicyReason) {
    CPASuggestionPolicyReasonGlobalPause = 0,
    CPASuggestionPolicyReasonTemporaryPause,
    CPASuggestionPolicyReasonHardSensitive,
    CPASuggestionPolicyReasonExplicitlyDisabled,
    CPASuggestionPolicyReasonInsufficientSemantics,
    CPASuggestionPolicyReasonSearchProtected,
    CPASuggestionPolicyReasonPresetEnabled,
    CPASuggestionPolicyReasonPresetDisabled,
    CPASuggestionPolicyReasonUserEnabled,
    CPASuggestionPolicyReasonUnknownApplication,
};

/// Returns whether an application has a built-in recommendation preset. The
/// result is metadata-only and does not inspect the focused element or input.
FOUNDATION_EXPORT BOOL CPASuggestionPolicyApplicationIsKnown(
    NSString *bundleIdentifier
);

/// Classifies an application using bundle metadata only. Standard applications
/// may use local current-input suggestions by default; other classes retain
/// their stricter policy boundary.
FOUNDATION_EXPORT CPAApplicationDefaultPolicyClass
CPASuggestionPolicyDefaultClassForApplication(NSString *bundleIdentifier);

FOUNDATION_EXPORT BOOL CPASuggestionPolicyApplicationIsBrowser(
    NSString *bundleIdentifier
);

@interface CPAInputContext : NSObject

@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, readonly) CPAInputScene scene;
@property(nonatomic, readonly) BOOL semanticConfidenceHigh;
@property(nonatomic, readonly) BOOL secureTextEntry;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    scene:(CPAInputScene)scene
    semanticConfidenceHigh:(BOOL)semanticConfidenceHigh
    secureTextEntry:(BOOL)secureTextEntry NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPAApplicationRule : NSObject

@property(nonatomic, readonly) CPAApplicationPolicyMode mode;
@property(nonatomic, readonly) BOOL searchExceptionEnabled;
@property(nonatomic, readonly) BOOL remoteCompletionAuthorized;

- (instancetype)initWithMode:(CPAApplicationPolicyMode)mode
    searchExceptionEnabled:(BOOL)searchExceptionEnabled
    remoteCompletionAuthorized:(BOOL)remoteCompletionAuthorized
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end


@interface CPASuggestionDecision : NSObject

@property(nonatomic, readonly) CPASuggestionPolicyOutcome outcome;
@property(nonatomic, readonly) CPAContextAccessMode contextMode;
@property(nonatomic, readonly) CPASuggestionPolicyReason reason;
/// A concise explanation suitable for the menu bar. It never contains input,
/// bundle identifiers, field labels, window titles, or site information.
@property(nonatomic, copy, readonly) NSString *statusText;

@end


@interface CPASuggestionPolicyEngine : NSObject

- (CPASuggestionDecision *)decisionForContext:(CPAInputContext *)context
    rule:(CPAApplicationRule *)rule
    globallyPaused:(BOOL)globallyPaused
    temporarilyPaused:(BOOL)temporarilyPaused;

@end

NS_ASSUME_NONNULL_END
