#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^CPAZIPChunkHandler)(NSData *chunk, NSError **error);

@interface CPASafeZIPEntry : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) uint64_t compressedSize;
@property(nonatomic, readonly) uint64_t uncompressedSize;
@end

@interface CPASafeZIPArchiveReader : NSObject

- (nullable instancetype)initWithURL:(NSURL *)url
    maximumArchiveBytes:(uint64_t)maximumArchiveBytes
    maximumEntryCount:(NSUInteger)maximumEntryCount
    maximumEntryUncompressedBytes:(uint64_t)maximumEntryUncompressedBytes
    maximumTotalUncompressedBytes:(uint64_t)maximumTotalUncompressedBytes
    maximumCompressionRatio:(double)maximumCompressionRatio
    error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSUInteger entryCount;
@property(nonatomic, strong, readonly) CPASafeZIPEntry *conversationsEntry;

- (BOOL)streamEntry:(CPASafeZIPEntry *)entry
    chunkSize:(NSUInteger)chunkSize
    chunkHandler:(CPAZIPChunkHandler)chunkHandler
    error:(NSError **)error;

@end
NS_ASSUME_NONNULL_END
