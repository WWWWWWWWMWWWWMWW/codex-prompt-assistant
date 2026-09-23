#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CPADataFoundationState) {
    CPADataFoundationStateNotScanned = 1,
    CPADataFoundationStateScanning = 2,
    CPADataFoundationStatePaused = 3,
    CPADataFoundationStateSynced = 4,
    CPADataFoundationStatePartialFailure = 5,
};

@interface CPADataFoundationSnapshot : NSObject <NSCopying>

@property(nonatomic, readonly) CPADataFoundationState state;
@property(nonatomic, readonly) NSUInteger discoveredFileCount;
@property(nonatomic, readonly) NSUInteger processedFileCount;
@property(nonatomic, readonly) NSUInteger succeededFileCount;
@property(nonatomic, readonly) NSUInteger skippedFileCount;
@property(nonatomic, readonly) NSUInteger failedFileCount;
@property(nonatomic, readonly) NSUInteger sourceErrorCount;
@property(nonatomic, readonly) NSUInteger insertedMessageCount;
@property(nonatomic, readonly) NSUInteger existingMessageCount;
@property(nonatomic, readonly) NSUInteger storedSourceCount;
@property(nonatomic, readonly) NSUInteger storedConversationCount;
@property(nonatomic, readonly) NSUInteger storedMessageCount;
@property(nonatomic, readonly) NSUInteger importRunCount;
@property(nonatomic, readonly) NSUInteger tombstoneCount;
@property(nonatomic, readonly) NSUInteger storedExpressionCount;
@property(nonatomic, readonly) NSUInteger expressionBuildDurationMilliseconds;
@property(nonatomic, copy, readonly) NSString *expressionBuildStatus;
@property(nonatomic, copy, readonly) NSString *statusTitle;
@property(nonatomic, copy, readonly) NSString *diagnosticSummary;

@end

typedef NSData * _Nullable (^CPADataFoundationMasterKeyProvider)(NSError **error);
typedef void (^CPADataFoundationUpdateHandler)(CPADataFoundationSnapshot *snapshot);

@interface CPADataFoundationController : NSObject

@property(nonatomic, copy, nullable) CPADataFoundationUpdateHandler updateHandler;
@property(nonatomic, strong, readonly) CPADataFoundationSnapshot *currentSnapshot;

- (instancetype)initWithActiveDirectory:(NSURL *)activeDirectory
    archivedDirectory:(NSURL *)archivedDirectory
    databaseURL:(NSURL *)databaseURL
    keychainService:(NSString *)keychainService
    keychainAccount:(NSString *)keychainAccount
    callbackQueue:(dispatch_queue_t)callbackQueue;

- (instancetype)initWithActiveDirectory:(NSURL *)activeDirectory
    archivedDirectory:(NSURL *)archivedDirectory
    databaseURL:(NSURL *)databaseURL
    masterKeyProvider:(CPADataFoundationMasterKeyProvider)masterKeyProvider
    callbackQueue:(dispatch_queue_t)callbackQueue NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startScan;
- (void)requestPause;
- (BOOL)resumeScan;
- (nullable NSString *)suggestionForInput:(NSString *)input
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength;

@end

NS_ASSUME_NONNULL_END
