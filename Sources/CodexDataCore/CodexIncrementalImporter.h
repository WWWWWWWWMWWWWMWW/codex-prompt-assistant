#import <Foundation/Foundation.h>

@class CPALocalDataStore;

NS_ASSUME_NONNULL_BEGIN

@interface CPACodexIncrementalImportResult : NSObject

@property(nonatomic, readonly) NSUInteger insertedMessageCount;
@property(nonatomic, readonly) NSUInteger existingMessageCount;
@property(nonatomic, readonly) uint64_t safeOffset;
@property(nonatomic, readonly) NSUInteger safeLineNumber;
@property(nonatomic, readonly) NSUInteger trailingByteCount;
@property(nonatomic, readonly) BOOL didResetCursor;
@property(nonatomic, readonly) BOOL skippedNonRootThread;
@property(nonatomic, readonly) BOOL skippedDeletedSource;

@end

@interface CPACodexIncrementalImporter : NSObject

- (instancetype)initWithChunkSize:(NSUInteger)chunkSize NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable CPACodexIncrementalImportResult *)importFileAtURL:(NSURL *)fileURL
    intoStore:(CPALocalDataStore *)store
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
