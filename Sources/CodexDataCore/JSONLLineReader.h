#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^CPAJSONLLineHandler)(
    NSData *lineData,
    uint64_t lineStartOffset,
    NSUInteger lineNumber,
    NSError **error
);

@interface CPAJSONLReadResult : NSObject

@property(nonatomic, readonly) uint64_t safeOffset;
@property(nonatomic, readonly) NSUInteger completeLineCount;
@property(nonatomic, readonly) NSUInteger trailingByteCount;
@property(nonatomic, readonly) uint64_t inspectedByteCount;
@property(nonatomic, readonly) BOOL stoppedEarly;

@end

@interface CPAJSONLLineReader : NSObject

- (instancetype)initWithChunkSize:(NSUInteger)chunkSize NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable CPAJSONLReadResult *)readURL:(NSURL *)url
    startingAtOffset:(uint64_t)startingOffset
    lineHandler:(CPAJSONLLineHandler)lineHandler
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
