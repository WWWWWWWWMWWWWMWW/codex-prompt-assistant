#import "AccessibilitySnapshotBroker.h"

@interface CPAAccessibilitySnapshotBroker ()
@property(nonatomic, copy) CPASnapshotProvider provider;
@property(nonatomic, copy) CPASnapshotDelivery delivery;
@property(nonatomic) dispatch_queue_t workerQueue;
@property(nonatomic) dispatch_queue_t callbackQueue;
@property(nonatomic) NSUInteger currentGeneration;
@property(nonatomic) NSUInteger nextObservationSequence;
@property(nonatomic) NSUInteger latestObservationSequence;
@property(nonatomic) pid_t requestedProcessIdentifier;
@property(nonatomic) pid_t requestedFrontmostProcessIdentifier;
@property(nonatomic) BOOL workerRunning;
@property(nonatomic) BOOL refreshPending;
@property(nonatomic) BOOL stopped;
@property(nonatomic, strong, nullable) CPAAccessibilitySnapshot *latestSnapshot;
@property(nonatomic) pid_t latestSnapshotProcessIdentifier;
@property(nonatomic) pid_t latestSnapshotFrontmostProcessIdentifier;
@end

@implementation CPAAccessibilitySnapshotBroker

- (instancetype)initWithProvider:(CPASnapshotProvider)provider
    callbackQueue:(dispatch_queue_t)callbackQueue
    delivery:(CPASnapshotDelivery)delivery {
    NSParameterAssert(provider != nil);
    NSParameterAssert(delivery != nil);
    self = [super init];
    if (self != nil) {
        _provider = [provider copy];
        _delivery = [delivery copy];
        _callbackQueue = callbackQueue ?: dispatch_get_main_queue();
        _workerQueue = dispatch_queue_create(
            "local.codex.prompt-assistant.accessibility-snapshot",
            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)requestSnapshotForProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier {
    if (processIdentifier <= 0 || frontmostProcessIdentifier <= 0) {
        return;
    }
    BOOL shouldStart = NO;
    NSUInteger generation = 0;
    NSUInteger sequence = 0;
    @synchronized (self) {
        if (self.stopped) {
            return;
        }
        BOOL identityChanged = self.requestedProcessIdentifier != processIdentifier
            || self.requestedFrontmostProcessIdentifier != frontmostProcessIdentifier;
        if (identityChanged) {
            self.currentGeneration++;
            self.requestedProcessIdentifier = processIdentifier;
            self.requestedFrontmostProcessIdentifier = frontmostProcessIdentifier;
            self.latestSnapshot = nil;
            self.latestSnapshotProcessIdentifier = 0;
            self.latestSnapshotFrontmostProcessIdentifier = 0;
        }
        self.refreshPending = YES;
        if (!self.workerRunning) {
            self.workerRunning = YES;
            self.refreshPending = NO;
            shouldStart = YES;
            generation = self.currentGeneration;
            sequence = ++self.nextObservationSequence;
        }
    }
    if (!shouldStart) {
        return;
    }
    [self enqueueProviderForProcessIdentifier:processIdentifier
        frontmostProcessIdentifier:frontmostProcessIdentifier
        generation:generation sequence:sequence];
}

- (void)enqueueProviderForProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier
    generation:(NSUInteger)generation
    sequence:(NSUInteger)sequence {
    __weak CPAAccessibilitySnapshotBroker *weakSelf = self;
    dispatch_async(self.workerQueue, ^{
        CPAAccessibilitySnapshotBroker *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        CPASnapshotProvider provider = nil;
        @synchronized (strongSelf) {
            if (strongSelf.stopped) {
                strongSelf.workerRunning = NO;
                return;
            }
            provider = [strongSelf.provider copy];
        }
        CPAAccessibilitySnapshot *snapshot = provider != nil
            ? provider(processIdentifier, frontmostProcessIdentifier) : nil;

        BOOL shouldDeliver = NO;
        BOOL shouldStartNext = NO;
        pid_t nextProcessIdentifier = 0;
        pid_t nextFrontmostProcessIdentifier = 0;
        NSUInteger nextGeneration = 0;
        NSUInteger nextSequence = 0;
        CPASnapshotDelivery delivery = nil;
        @synchronized (strongSelf) {
            BOOL current = !strongSelf.stopped
                && generation == strongSelf.currentGeneration
                && processIdentifier == strongSelf.requestedProcessIdentifier
                && frontmostProcessIdentifier
                    == strongSelf.requestedFrontmostProcessIdentifier;
            if (current && snapshot != nil) {
                strongSelf.latestSnapshot = snapshot;
                strongSelf.latestSnapshotProcessIdentifier = processIdentifier;
                strongSelf.latestSnapshotFrontmostProcessIdentifier =
                    frontmostProcessIdentifier;
                strongSelf.latestObservationSequence = sequence;
                delivery = [strongSelf.delivery copy];
                shouldDeliver = delivery != nil;
            }
            if (!strongSelf.stopped && strongSelf.refreshPending) {
                strongSelf.refreshPending = NO;
                shouldStartNext = YES;
                nextProcessIdentifier = strongSelf.requestedProcessIdentifier;
                nextFrontmostProcessIdentifier =
                    strongSelf.requestedFrontmostProcessIdentifier;
                nextGeneration = strongSelf.currentGeneration;
                nextSequence = ++strongSelf.nextObservationSequence;
            } else {
                strongSelf.workerRunning = NO;
            }
        }

        if (shouldDeliver) {
            __weak CPAAccessibilitySnapshotBroker *deliverySelf = strongSelf;
            dispatch_async(strongSelf.callbackQueue, ^{
                CPAAccessibilitySnapshotBroker *callbackOwner = deliverySelf;
                if (callbackOwner == nil) {
                    return;
                }
                @synchronized (callbackOwner) {
                    // A newer observation for the same identity may have
                    // completed before this main-queue block runs. Never
                    // publish an older snapshot over that newer one.
                    if (callbackOwner.stopped
                        || generation != callbackOwner.currentGeneration
                        || sequence != callbackOwner.latestObservationSequence
                        || processIdentifier != callbackOwner.requestedProcessIdentifier
                        || frontmostProcessIdentifier
                            != callbackOwner.requestedFrontmostProcessIdentifier) {
                        return;
                    }
                }
                delivery(snapshot, processIdentifier, frontmostProcessIdentifier,
                    generation);
            });
        }
        if (shouldStartNext) {
            [strongSelf enqueueProviderForProcessIdentifier:nextProcessIdentifier
                frontmostProcessIdentifier:nextFrontmostProcessIdentifier
                generation:nextGeneration sequence:nextSequence];
        }
    });
}

- (CPAAccessibilitySnapshot *)latestSnapshotForProcessIdentifier:
    (pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier {
    @synchronized (self) {
        if (self.stopped
            || self.latestSnapshot == nil
            || self.latestSnapshotProcessIdentifier != processIdentifier
            || self.latestSnapshotFrontmostProcessIdentifier
                != frontmostProcessIdentifier) {
            return nil;
        }
        return self.latestSnapshot;
    }
}

- (NSUInteger)generation {
    @synchronized (self) {
        return self.currentGeneration;
    }
}

- (void)requestFreshSnapshotForProcessIdentifier:(pid_t)processIdentifier
    completion:(void (^)(CPAAccessibilitySnapshot *))completion {
    NSUInteger generation = self.generation;
    dispatch_async(self.workerQueue, ^{
        CPASnapshotProvider provider = nil;
        @synchronized (self) {
            if (!self.stopped && generation == self.currentGeneration && processIdentifier > 0) {
                provider = self.provider;
            }
        }
        CPAAccessibilitySnapshot *snapshot = provider != nil
            ? provider(processIdentifier, processIdentifier) : nil;
        dispatch_async(self.callbackQueue, ^{
            BOOL current = NO;
            @synchronized (self) {
                current = !self.stopped && generation == self.currentGeneration;
            }
            completion(current ? snapshot : nil);
        });
    });
}

- (BOOL)isRefreshInProgress {
    @synchronized (self) {
        return self.workerRunning;
    }
}

- (void)invalidate {
    @synchronized (self) {
        if (self.stopped) {
            return;
        }
        self.currentGeneration++;
        self.requestedProcessIdentifier = 0;
        self.requestedFrontmostProcessIdentifier = 0;
        self.latestSnapshot = nil;
        self.latestSnapshotProcessIdentifier = 0;
        self.latestSnapshotFrontmostProcessIdentifier = 0;
        self.refreshPending = NO;
    }
}

- (void)stop {
    @synchronized (self) {
        if (self.stopped) {
            return;
        }
        self.stopped = YES;
        self.currentGeneration++;
        self.requestedProcessIdentifier = 0;
        self.requestedFrontmostProcessIdentifier = 0;
        self.latestSnapshot = nil;
        self.latestSnapshotProcessIdentifier = 0;
        self.latestSnapshotFrontmostProcessIdentifier = 0;
        self.refreshPending = NO;
        self.provider = nil;
        self.delivery = nil;
    }
}

@end
