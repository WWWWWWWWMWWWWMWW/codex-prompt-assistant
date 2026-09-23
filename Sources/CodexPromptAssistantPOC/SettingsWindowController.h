#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Presentation only. Runtime state and mutations remain owned by the app delegate.
typedef NSDictionary * _Nonnull (^CPASettingsStateProvider)(void);
typedef NSString * _Nullable (^CPASettingsActionHandler)(NSString *action, NSDictionary *values);
typedef NSDictionary * _Nonnull (^CPASettingsRuleProvider)(NSDictionary *target);
@interface CPASettingsWindowController : NSWindowController <NSWindowDelegate, NSTextFieldDelegate>
- (instancetype)initWithStateProvider:(CPASettingsStateProvider)stateProvider
    actionHandler:(CPASettingsActionHandler)actionHandler
    ruleProvider:(CPASettingsRuleProvider)ruleProvider;
- (void)presentWithRuleTargets:(NSArray<NSDictionary *> *)targets;
- (void)refreshState;
@end
NS_ASSUME_NONNULL_END
