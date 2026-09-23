#import <Foundation/Foundation.h>

#import "SuggestionPolicy.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CPASuggestionPolicyStoreDefaultsKey;

@interface CPASuggestionPolicyStore : NSObject

/// In-memory invalidation token. It changes after every successful mutation
/// and is intentionally unrelated to user text or application content.
@property(atomic, readonly) NSUInteger ruleVersion;
/// Product scope list shared by presentation and runtime authorization.
+ (NSArray<NSDictionary *> *)onlineScopeTargets;
+ (BOOL)allowsOnlineScopeBundleIdentifier:(NSString *)bundle;
+ (BOOL)isFeishuDocumentHost:(NSString *)host;
/// Online edition: explicit supported application allowlist; empty means disabled.
@property(nonatomic) BOOL onlineScopesOnly;
- (void)setOnlineScopeSelected:(BOOL)selected bundleIdentifier:(NSString *)bundle host:(NSString *)host;
@property(nonatomic, copy, readonly) NSArray<NSString *> *storedApplicationIdentifiers;
@property(nonatomic, copy, readonly) NSArray<NSString *> *storedBrowserHosts;

- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

- (CPAApplicationRule *)ruleForBundleIdentifier:(NSString *)bundleIdentifier;
- (void)setRule:(CPAApplicationRule *)rule
    forBundleIdentifier:(NSString *)bundleIdentifier;

- (CPAApplicationRule *)ruleForBrowserHost:(NSString *)hostOrURL;
- (BOOL)setRule:(CPAApplicationRule *)rule
    forBrowserHost:(NSString *)hostOrURL;

/// Returns a lowercase host only. Paths, queries, fragments, credentials, and
/// ports are discarded and never persisted.
+ (NSString *)normalizedBrowserHost:(NSString *)hostOrURL;

@end

NS_ASSUME_NONNULL_END
