#import "JSONLLineReader.h"

@interface CPAJSONLReadResult ()
@property(nonatomic, readwrite) uint64_t safeOffset;
@property(nonatomic, readwrite) NSUInteger completeLineCount;
@property(nonatomic, readwrite) NSUInteger trailingByteCount;
@property(nonatomic, readwrite) uint64_t inspectedByteCount;
@property(nonatomic, readwrite) BOOL stoppedEarly;
@end

@implementation CPAJSONLReadResult
@end

@interface CPAJSONLLineReader ()
@property(nonatomic, readonly) NSUInteger chunkSize;
@end

@implementation CPAJSONLLineReader

- (instancetype)initWithChunkSize:(NSUInteger)chunkSize {
    self = [super init];
    if (self != nil) {
        _chunkSize = MAX((NSUInteger)1, chunkSize);
    }
    return self;
}

- (CPAJSONLReadResult *)readURL:(NSURL *)url
    startingAtOffset:(uint64_t)startingOffset
    lineHandler:(CPAJSONLLineHandler)lineHandler
    error:(NSError **)error {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:error];
    if (handle == nil) {
        return nil;
    }
    if (![handle seekToOffset:startingOffset error:error]) {
        [handle closeFile];
        return nil;
    }

    NSMutableData *buffer = [NSMutableData data];
    uint64_t bufferStartOffset = startingOffset;
    uint64_t safeOffset = startingOffset;
    NSUInteger completeLineCount = 0;
    NSUInteger scanIndex = 0;
    uint64_t inspectedByteCount = 0;
    BOOL reachedEnd = NO;
    BOOL stoppedEarly = NO;

    while (!reachedEnd && !stoppedEarly) {
        NSData *chunk = [handle readDataUpToLength:self.chunkSize error:error];
        if (chunk == nil) {
            [handle closeFile];
            return nil;
        }
        reachedEnd = chunk.length == 0;
        if (!reachedEnd) {
            [buffer appendData:chunk];
        }

        const uint8_t *bytes = buffer.bytes;
        NSUInteger lineStart = 0;
        NSUInteger consumed = 0;
        for (NSUInteger i = scanIndex, len = buffer.length; i < len; i++) {
            inspectedByteCount++;
            if (bytes[i] != (uint8_t)'\n') {
                continue;
            }

            NSUInteger lineLength = i - lineStart;
            if (lineLength > 0 && bytes[i - 1] == (uint8_t)'\r') {
                lineLength--;
            }
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(lineStart, lineLength)];
            NSError *handlerError = nil;
            BOOL shouldContinue = lineHandler(
                lineData,
                bufferStartOffset + lineStart,
                completeLineCount + 1,
                &handlerError
            );
            if (!shouldContinue && handlerError != nil) {
                if (error != NULL) {
                    *error = handlerError;
                }
                [handle closeFile];
                return nil;
            }
            completeLineCount++;
            consumed = i + 1;
            lineStart = consumed;
            safeOffset = bufferStartOffset + consumed;
            if (!shouldContinue) {
                stoppedEarly = YES;
                break;
            }
        }

        if (consumed > 0) {
            [buffer replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
            bufferStartOffset += consumed;
        }
        scanIndex = buffer.length;
    }
    [handle closeFile];

    CPAJSONLReadResult *result = [[CPAJSONLReadResult alloc] init];
    result.safeOffset = safeOffset;
    result.completeLineCount = completeLineCount;
    result.trailingByteCount = stoppedEarly ? 0 : buffer.length;
    result.inspectedByteCount = inspectedByteCount;
    result.stoppedEarly = stoppedEarly;
    return result;
}

@end
