#import "SuggestionContextIdentity.h"

@interface CPASuggestionContextIdentity ()
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, readwrite) pid_t processIdentifier;
@property(nonatomic, readwrite) NSInteger windowIdentifier;
@property(nonatomic, copy, readwrite) NSString *fieldIdentity;
@property(nonatomic, copy, readwrite) NSString *browserHost;
@property(nonatomic, readwrite) NSUInteger ruleVersion;
@end

@implementation CPASuggestionContextIdentity

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier
    windowIdentifier:(NSInteger)windowIdentifier
    fieldIdentity:(NSString *)fieldIdentity
    browserHost:(NSString *)browserHost
    ruleVersion:(NSUInteger)ruleVersion {
    self = [super init];
    if (self != nil) {
        _bundleIdentifier = [bundleIdentifier copy];
        _processIdentifier = processIdentifier;
        _windowIdentifier = windowIdentifier;
        _fieldIdentity = [fieldIdentity copy];
        _browserHost = [browserHost copy];
        _ruleVersion = ruleVersion;
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:CPASuggestionContextIdentity.class]) {
        return NO;
    }
    CPASuggestionContextIdentity *other = object;
    return self.processIdentifier == other.processIdentifier
        && self.windowIdentifier == other.windowIdentifier
        && self.ruleVersion == other.ruleVersion
        && [self.bundleIdentifier isEqualToString:other.bundleIdentifier]
        && [self.fieldIdentity isEqualToString:other.fieldIdentity]
        && [self.browserHost isEqualToString:other.browserHost];
}

- (NSUInteger)hash {
    return self.bundleIdentifier.hash
        ^ (NSUInteger)self.processIdentifier
        ^ (NSUInteger)self.windowIdentifier
        ^ self.fieldIdentity.hash
        ^ self.browserHost.hash
        ^ self.ruleVersion;
}

@end

@interface CPASuggestionContextGenerationTracker ()
@property(nonatomic, readwrite) NSUInteger generation;
@property(nonatomic, strong, readwrite, nullable)
    CPASuggestionContextIdentity *currentIdentity;
@end

@implementation CPASuggestionContextGenerationTracker

- (BOOL)observeIdentity:(CPASuggestionContextIdentity *)identity {
    if ([self.currentIdentity isEqual:identity]) {
        return NO;
    }
    self.currentIdentity = identity;
    self.generation += 1;
    return YES;
}

- (BOOL)clear {
    if (self.currentIdentity == nil) {
        return NO;
    }
    self.currentIdentity = nil;
    self.generation += 1;
    return YES;
}

@end
