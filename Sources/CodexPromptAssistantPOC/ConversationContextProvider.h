#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CPAConversationContextState) {
    /// No conversation has been selected yet.
    CPAConversationContextStateEmpty = 0,
    /// A new conversation was selected and its rollout is still being resolved/read.
    CPAConversationContextStateLoading,
    /// The current selection has been resolved. The message array may legitimately be empty.
    CPAConversationContextStateReady,
};

typedef NS_ENUM(NSInteger, CPAContextAvailability) {
    CPAContextAvailabilityMissing = 0,
    CPAContextAvailabilityLoading,
    CPAContextAvailabilityReadyEmpty,
    CPAContextAvailabilityReady,
    CPAContextAvailabilityAmbiguous,
    CPAContextAvailabilityError,
};

/// One immutable publication; revision and the material it identifies are read together.
/// Source identity and text remain in memory, never diagnostic fields.
@interface CPAConversationContextSnapshot : NSObject <NSCopying>
@property(nonatomic, readonly) NSUInteger selectionGeneration;
@property(nonatomic, readonly) NSUInteger revision;
@property(nonatomic, readonly) CPAContextAvailability availability;
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *messages;
@property(nonatomic, copy, readonly, nullable) NSURL *sourceURL;
@property(nonatomic, copy, readonly) NSIndexSet *truncatedMessageIndexes;
@property(nonatomic, readonly) BOOL tailTruncated;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithSelectionGeneration:(NSUInteger)selection revision:(NSUInteger)revision
    availability:(CPAContextAvailability)availability messages:(NSArray *)messages
    sourceURL:(nullable NSURL *)sourceURL truncatedMessageIndexes:(NSIndexSet *)indexes
    tailTruncated:(BOOL)tailTruncated NS_DESIGNATED_INITIALIZER;
@end

/// Maintains a small in-memory snapshot of the uniquely selected Codex session.
/// File scanning and JSON parsing never run on the input/suggestion thread.
@interface CPAConversationContextProvider : NSObject

/// Compatibility accessor for currentSnapshot.revision (selection AND content changes).
/// New requests must use currentSnapshot, not fetch the revision and messages separately.
@property(nonatomic, readonly) NSUInteger contextGeneration;
/// Distinguishes "not loaded yet" from a valid conversation with no usable messages.
@property(nonatomic, readonly) CPAConversationContextState contextState;
@property(nonatomic, strong, readonly) CPAConversationContextSnapshot *currentSnapshot;
/// Invoked on the main queue for changed publications only. Consumers re-read the
/// current snapshot; notifications never carry text and may coalesce in that read.
@property(nonatomic, copy, nullable) void (^snapshotDidChange)(void);

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithSessionsDirectoryURL:(NSURL *)sessionsDirectoryURL;
- (instancetype)initWithSessionsDirectoryURL:(NSURL *)sessionsDirectoryURL
    stateDatabaseURL:(NSURL *)stateDatabaseURL NS_DESIGNATED_INITIALIZER;
- (void)start;
- (void)stop;

/// Selects the visible Codex conversation by its sidebar title. The previous
/// snapshot is cleared synchronously. If the title cannot be resolved to one
/// unique local thread, the context remains empty instead of guessing.
- (void)selectConversationWithTitle:(nullable NSString *)title;

/// Select by a verified local Codex UUID. Never falls back to title matching.
/// The log header must agree with the ID before any context is published.
- (void)selectConversationWithIdentifier:(nullable NSString *)identifier;

/// Returns up to six user messages and two final assistant replies (3000 characters total).
/// Long messages retain their beginning and end. The returned array is safe to use
/// synchronously from the suggestion path and contains no file I/O.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)cachedContextMessages;

/// Drops the previous session snapshot immediately. The background refresh will
/// stays empty until a new explicit conversation selection.
- (void)invalidateCachedContext;

/// Returns the cached context only when its source session changed after `date`.
/// This lets the caller avoid carrying the previous chat into a newly selected chat.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)cachedContextMessagesModifiedAfterDate:
    (NSDate *)date;

@end

NS_ASSUME_NONNULL_END
