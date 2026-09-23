#import "SafeInputContextCollector.h"

@interface CPAFocusedInputMetadata ()
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, copy, readwrite) NSString *role;
@property(nonatomic, copy, readwrite) NSString *subrole;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *semanticMetadata;
@property(nonatomic, copy, readwrite) NSString *browserHost;
@property(nonatomic, readwrite) pid_t processIdentifier;
@property(nonatomic, copy, readwrite) NSString *fieldIdentity;
@end

@implementation CPAFocusedInputMetadata

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    browserHost:(NSString *)browserHost {
    return [self initWithBundleIdentifier:bundleIdentifier
        role:role
        subrole:subrole
        semanticMetadata:semanticMetadata
        browserHost:browserHost
        processIdentifier:0
        fieldIdentity:@""];
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    browserHost:(NSString *)browserHost
    processIdentifier:(pid_t)processIdentifier
    fieldIdentity:(NSString *)fieldIdentity {
    self = [super init];
    if (self != nil) {
        _bundleIdentifier = [bundleIdentifier copy];
        _role = [role copy];
        _subrole = [subrole copy];
        _semanticMetadata = [semanticMetadata copy];
        _browserHost = [browserHost copy];
        _processIdentifier = processIdentifier;
        _fieldIdentity = [fieldIdentity copy];
    }
    return self;
}

@end

@interface CPASafeInputContextCollection ()
@property(nonatomic, strong, readwrite) CPASuggestionDecision *decision;
@property(nonatomic, strong, readwrite, nullable) id inputBody;

- (instancetype)initWithDecision:(CPASuggestionDecision *)decision
    inputBody:(nullable id)inputBody;
@end

@implementation CPASafeInputContextCollection

- (instancetype)initWithDecision:(CPASuggestionDecision *)decision
    inputBody:(nullable id)inputBody {
    self = [super init];
    if (self != nil) {
        _decision = decision;
        _inputBody = inputBody;
    }
    return self;
}

@end

@interface CPASafeInputContextCollector ()
@property(nonatomic, strong) CPASuggestionPolicyCoordinator *policyCoordinator;
@property(nonatomic, strong) id<CPAInputBodyReading> bodyReader;
@end

@implementation CPASafeInputContextCollector

- (instancetype)initWithPolicyCoordinator:
    (CPASuggestionPolicyCoordinator *)policyCoordinator
    bodyReader:(id<CPAInputBodyReading>)bodyReader {
    self = [super init];
    if (self != nil) {
        _policyCoordinator = policyCoordinator;
        _bodyReader = bodyReader;
    }
    return self;
}

- (CPASafeInputContextCollection *)collectContextForMetadata:
    (CPAFocusedInputMetadata *)metadata
    globallyPaused:(BOOL)globallyPaused
    temporarilyPaused:(BOOL)temporarilyPaused {
    CPASuggestionDecision *decision = [self.policyCoordinator
        decisionForBundleIdentifier:metadata.bundleIdentifier
        role:metadata.role
        subrole:metadata.subrole
        semanticMetadata:metadata.semanticMetadata
        browserHost:metadata.browserHost
        globallyPaused:globallyPaused
        temporarilyPaused:temporarilyPaused];
    if (decision.outcome == CPASuggestionPolicyOutcomeDisabled) {
        return [[CPASafeInputContextCollection alloc]
            initWithDecision:decision inputBody:nil];
    }
    id inputBody = [self.bodyReader readInputBodyForMetadata:metadata];
    return [[CPASafeInputContextCollection alloc]
        initWithDecision:decision inputBody:inputBody];
}

@end
