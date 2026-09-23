#import <Foundation/Foundation.h>

@class CPACodexMessage;
@class CPACodexSourceMetadata;
@class CPALocalDataStore;
@class CPALocalExpressionBuildResult;
@class CPALocalExpressionCandidate;
@class CPALocalExpressionRecord;
@class CPALocalUserMessageRecord;

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^CPALocalUserMessageHandler)(CPALocalUserMessageRecord *record,
    BOOL *stop, NSError **error);

@interface CPALocalImportResult : NSObject
@property(nonatomic, readonly) NSUInteger insertedMessageCount;
@property(nonatomic, readonly) NSUInteger existingMessageCount;
@property(nonatomic, readonly) BOOL skippedTombstonedSource;
@end

@interface CPALocalDataCounts : NSObject
@property(nonatomic, readonly) NSUInteger sourceCount;
@property(nonatomic, readonly) NSUInteger conversationCount;
@property(nonatomic, readonly) NSUInteger messageCount;
@property(nonatomic, readonly) NSUInteger importRunCount;
@property(nonatomic, readonly) NSUInteger tombstoneCount;
@end

@interface CPALocalSourceCursor : NSObject

@property(nonatomic, copy, readonly) NSString *threadID;
@property(nonatomic, readonly) uint64_t deviceID;
@property(nonatomic, readonly) uint64_t inode;
@property(nonatomic, readonly) uint64_t safeOffset;
@property(nonatomic, readonly) NSUInteger safeLineNumber;
@property(nonatomic, readonly) uint64_t fileSize;
@property(nonatomic, readonly) NSUInteger parserVersion;

- (instancetype)initWithThreadID:(NSString *)threadID
    deviceID:(uint64_t)deviceID
    inode:(uint64_t)inode
    safeOffset:(uint64_t)safeOffset
    safeLineNumber:(NSUInteger)safeLineNumber
    fileSize:(uint64_t)fileSize
    parserVersion:(NSUInteger)parserVersion NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPALocalImportSession : NSObject

- (BOOL)importMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    error:(NSError **)error;
- (nullable CPALocalImportResult *)commit:(NSError **)error;
- (void)rollback;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPALocalDataStore : NSObject

- (nullable instancetype)initWithDatabaseURL:(NSURL *)databaseURL
    masterKey:(NSData *)masterKey
    error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable CPALocalImportResult *)importCodexMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    error:(NSError **)error;
- (nullable CPALocalImportResult *)importCodexMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    advancingCursor:(nullable CPALocalSourceCursor *)cursor
    error:(NSError **)error;
- (nullable CPALocalSourceCursor *)codexCursorForThreadID:(NSString *)threadID
    error:(NSError **)error;
- (BOOL)isSourceTombstonedForKind:(NSString *)sourceKind
    externalID:(NSString *)externalID
    error:(NSError **)error;
- (BOOL)deleteSourceKind:(NSString *)sourceKind
    externalID:(NSString *)externalID
    error:(NSError **)error;
- (nullable CPALocalImportSession *)beginImportSessionForSourceKind:(NSString *)sourceKind
    error:(NSError **)error;
- (nullable CPALocalDataCounts *)currentCounts:(NSError **)error;
- (BOOL)enumerateDecryptedUserMessages:(CPALocalUserMessageHandler)handler
    error:(NSError **)error;
- (nullable CPALocalExpressionBuildResult *)replaceActiveExpressions:
    (NSArray<CPALocalExpressionCandidate *> *)expressions
    extractorVersion:(NSUInteger)extractorVersion
    error:(NSError **)error;
- (nullable NSArray<CPALocalExpressionRecord *> *)loadActiveExpressions:
    (NSError **)error;
- (BOOL)deleteExpressionText:(NSString *)normalizedText error:(NSError **)error;
- (nullable NSString *)decryptedMessageTextForThreadID:(NSString *)threadID
    messageID:(NSString *)messageID
    error:(NSError **)error;
- (nullable NSString *)decryptedMessageTextForSourceKind:(NSString *)sourceKind
    conversationID:(NSString *)conversationID
    messageID:(NSString *)messageID
    error:(NSError **)error;
- (BOOL)close:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
