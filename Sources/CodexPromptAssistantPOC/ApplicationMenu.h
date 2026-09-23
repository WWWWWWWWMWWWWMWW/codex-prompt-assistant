#import <AppKit/AppKit.h>
#import "../RemoteCompletionCore/RemoteCompletionClient.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSMenu *CPACreateApplicationMainMenu(void);
/// Status of the last completed request, not a claim that its text was displayed.
FOUNDATION_EXPORT NSString *CPALastCompletionStatusText(CPARemoteCompletionOutcome outcome, NSString *phase, BOOL hasCandidate);

FOUNDATION_EXPORT NSString *CPAApplicationPolicyScopeTitle(
    NSString *applicationName,
    NSString *bundleIdentifier,
    NSString *browserHost
);

FOUNDATION_EXPORT BOOL CPAApplicationPolicyScopeCanBeConfigured(
    NSString *bundleIdentifier,
    NSString *browserHost
);

NS_ASSUME_NONNULL_END
