#import <Foundation/Foundation.h>

#import "SuggestionPolicy.h"
#import "SuggestionPolicyStore.h"

NS_ASSUME_NONNULL_BEGIN

/// Resolves persisted application/site rules and performs one metadata-only
/// policy decision. It never accepts or returns the input value.
@interface CPASuggestionPolicyCoordinator : NSObject

@property(nonatomic, readonly) NSUInteger ruleVersion;

/// Returns whether the current policy configuration can make a generic AX
/// metadata probe useful. Unknown applications remain pass-through until the
/// user explicitly enables them; an explicit application-off rule never
/// probes the focused element.
- (BOOL)shouldProbeMetadataForBundleIdentifier:(NSString *)bundleIdentifier;

- (instancetype)initWithStore:(CPASuggestionPolicyStore *)store
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

- (CPASuggestionDecision *)decisionForBundleIdentifier:
    (NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    browserHost:(NSString *)browserHost
    globallyPaused:(BOOL)globallyPaused
    temporarilyPaused:(BOOL)temporarilyPaused;

@end

NS_ASSUME_NONNULL_END
