#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN
#define CPAThreadIDCopyEventTag 0x4350414944434f50LL
FOUNDATION_EXPORT NSString * _Nullable CPAThreadIDFromLink(NSString * _Nullable value);

/// Injectable boundary: production uses the general pasteboard; tests use only memory.
@protocol CPAThreadIDIO <NSObject>
- (NSInteger)revision;
- (nullable id)capture;
- (nullable NSString *)text;
- (BOOL)restore:(id)saved expectedRevision:(NSInteger)revision;
- (BOOL)focusMatches;
- (BOOL)sendCopy;
- (NSTimeInterval)now;
@end

@interface CPAThreadIDTransaction : NSObject
@property(nonatomic, readonly) BOOL pending;
@property(nonatomic, readonly) BOOL cancelled;
@property(nonatomic, copy, nullable) BOOL (^validate)(void);
@property(nonatomic, copy, nullable) void (^completion)(NSString * _Nullable identifier, NSString *reason);
- (instancetype)initWithIO:(id<CPAThreadIDIO>)io;
- (void)start;
- (void)poll;
/// Cancels publication. If already sent, still finishes clipboard cleanup.
- (void)cancel;
@end

/// Main-thread asynchronous resolver. Never activates, focuses, reads draft text or sends.
/// User clipboard shortcut pairs are deferred during the short copy transaction.
@interface CPACodexThreadIDResolver : NSObject
@property(nonatomic, readonly) BOOL pending;
- (void)resolveProcessIdentifier:(pid_t)pid validate:(BOOL (^)(void))validate
    completion:(void (^)(NSString * _Nullable identifier, NSString *reason))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
