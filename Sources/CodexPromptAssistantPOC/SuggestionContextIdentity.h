#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPASuggestionContextIdentity : NSObject

@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, readonly) pid_t processIdentifier;
@property(nonatomic, readonly) NSInteger windowIdentifier;
@property(nonatomic, copy, readonly) NSString *fieldIdentity;
@property(nonatomic, copy, readonly) NSString *browserHost;
@property(nonatomic, readonly) NSUInteger ruleVersion;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier
    windowIdentifier:(NSInteger)windowIdentifier
    fieldIdentity:(NSString *)fieldIdentity
    browserHost:(NSString *)browserHost
    ruleVersion:(NSUInteger)ruleVersion NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPASuggestionContextGenerationTracker : NSObject

@property(nonatomic, readonly) NSUInteger generation;
@property(nonatomic, strong, readonly, nullable)
    CPASuggestionContextIdentity *currentIdentity;

/// Returns YES when the identity established a new generation.
- (BOOL)observeIdentity:(CPASuggestionContextIdentity *)identity;
/// Returns YES when an established identity was cleared.
- (BOOL)clear;

@end

NS_ASSUME_NONNULL_END
