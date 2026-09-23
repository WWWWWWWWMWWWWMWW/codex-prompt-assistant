#import <Foundation/Foundation.h>

#import "AccessibilitySnapshot.h"

NS_ASSUME_NONNULL_BEGIN

typedef CPAAccessibilitySnapshot * _Nullable (^CPASnapshotProvider)(
    pid_t processIdentifier,
    pid_t frontmostProcessIdentifier);
typedef void (^CPASnapshotDelivery)(CPAAccessibilitySnapshot *snapshot,
    pid_t processIdentifier,
    pid_t frontmostProcessIdentifier,
    NSUInteger generation);

/// Serializes potentially blocking AX/window reads off the main run loop.
/// Only the newest process/frontmost identity is publishable; an observation
/// from an older identity is discarded before delivery.
@interface CPAAccessibilitySnapshotBroker : NSObject

- (instancetype)initWithProvider:(CPASnapshotProvider)provider
    callbackQueue:(dispatch_queue_t)callbackQueue
    delivery:(CPASnapshotDelivery)delivery;

- (void)requestSnapshotForProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier;
/// Enqueues a new observation on the same serial worker. Never returns the
/// cached snapshot; invalidation/stop completes with nil on the callback queue.
- (void)requestFreshSnapshotForProcessIdentifier:(pid_t)processIdentifier
    completion:(void (^)(CPAAccessibilitySnapshot * _Nullable snapshot))completion;
- (nullable CPAAccessibilitySnapshot *)latestSnapshotForProcessIdentifier:
    (pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier;
- (NSUInteger)generation;
- (BOOL)isRefreshInProgress;
- (void)invalidate;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
