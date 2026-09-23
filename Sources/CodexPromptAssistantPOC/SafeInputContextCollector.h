#import <Foundation/Foundation.h>

#import "SuggestionPolicyCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

/// Metadata gathered before any input value is requested. Semantic strings
/// are transient AX labels/hints and must never be logged or persisted.
@interface CPAFocusedInputMetadata : NSObject

@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, copy, readonly) NSString *role;
@property(nonatomic, copy, readonly) NSString *subrole;
@property(nonatomic, copy, readonly) NSArray<NSString *> *semanticMetadata;
@property(nonatomic, copy, readonly) NSString *browserHost;
/// Verified Feishu document paragraph, distinct from a chat composer.
@property(nonatomic) BOOL documentContinuation;
@property(nonatomic, readonly) pid_t processIdentifier;
/// Opaque in-memory identity used to reject focus races. Never log or persist.
@property(nonatomic, copy, readonly) NSString *fieldIdentity;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    browserHost:(NSString *)browserHost;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    browserHost:(NSString *)browserHost
    processIdentifier:(pid_t)processIdentifier
    fieldIdentity:(NSString *)fieldIdentity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@protocol CPAInputBodyReading <NSObject>

- (nullable id)readInputBodyForMetadata:(CPAFocusedInputMetadata *)metadata;

@end

@interface CPASafeInputContextCollection : NSObject

@property(nonatomic, strong, readonly) CPASuggestionDecision *decision;
@property(nonatomic, strong, readonly, nullable) id inputBody;

@end


@interface CPASafeInputContextCollector : NSObject

- (instancetype)initWithPolicyCoordinator:
    (CPASuggestionPolicyCoordinator *)policyCoordinator
    bodyReader:(id<CPAInputBodyReading>)bodyReader NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (CPASafeInputContextCollection *)collectContextForMetadata:
    (CPAFocusedInputMetadata *)metadata
    globallyPaused:(BOOL)globallyPaused
    temporarilyPaused:(BOOL)temporarilyPaused;

@end

NS_ASSUME_NONNULL_END
