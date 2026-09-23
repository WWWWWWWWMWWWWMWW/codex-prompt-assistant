#import "CodexIncrementalImporter.h"

#import <sys/stat.h>

#import "CodexMessage.h"
#import "CodexRecordParser.h"
#import "CodexSourceMetadata.h"
#import "JSONLLineReader.h"
#import "LocalDataStore.h"

static NSString * const CPACodexIncrementalImporterErrorDomain =
    @"CPACodexIncrementalImporterErrorDomain";
static const NSUInteger CPACodexParserVersion = 1;

typedef struct {
    uint64_t deviceID;
    uint64_t inode;
    uint64_t size;
} CPAFileIdentity;

static void CPASetIncrementalImporterError(NSError **error, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPACodexIncrementalImporterErrorDomain
            code:1 userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

static BOOL CPAReadFileIdentity(NSURL *url, CPAFileIdentity *identity, NSError **error) {
    struct stat status;
    if (lstat(url.fileSystemRepresentation, &status) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey: @"Unable to inspect Codex source file"}];
        }
        return NO;
    }
    if (!S_ISREG(status.st_mode)) {
        CPASetIncrementalImporterError(error,
            @"Codex source must be a regular file and may not be a symbolic link");
        return NO;
    }
    identity->deviceID = (uint64_t)status.st_dev;
    identity->inode = (uint64_t)status.st_ino;
    identity->size = (uint64_t)status.st_size;
    return YES;
}

@interface CPACodexIncrementalImportResult ()
@property(nonatomic, readwrite) NSUInteger insertedMessageCount;
@property(nonatomic, readwrite) NSUInteger existingMessageCount;
@property(nonatomic, readwrite) uint64_t safeOffset;
@property(nonatomic, readwrite) NSUInteger safeLineNumber;
@property(nonatomic, readwrite) NSUInteger trailingByteCount;
@property(nonatomic, readwrite) BOOL didResetCursor;
@property(nonatomic, readwrite) BOOL skippedNonRootThread;
@property(nonatomic, readwrite) BOOL skippedDeletedSource;
@end

@implementation CPACodexIncrementalImportResult
@end

@interface CPACodexIncrementalImporter ()
@property(nonatomic, readonly) NSUInteger chunkSize;
@end

@implementation CPACodexIncrementalImporter

- (instancetype)initWithChunkSize:(NSUInteger)chunkSize {
    self = [super init];
    if (self != nil) {
        _chunkSize = MAX((NSUInteger)1, chunkSize);
    }
    return self;
}

- (CPACodexIncrementalImportResult *)importFileAtURL:(NSURL *)fileURL
    intoStore:(CPALocalDataStore *)store
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    CPAFileIdentity initialIdentity;
    if (!CPAReadFileIdentity(fileURL, &initialIdentity, error)) {
        return nil;
    }

    CPAJSONLLineReader *reader = [[CPAJSONLLineReader alloc]
        initWithChunkSize:self.chunkSize];
    CPACodexRecordParser *parser = [[CPACodexRecordParser alloc] init];
    __block CPACodexSourceMetadata *metadata = nil;
    CPAJSONLReadResult *metadataRead = [reader readURL:fileURL startingAtOffset:0
        lineHandler:^BOOL(NSData *lineData, uint64_t lineStartOffset,
            NSUInteger lineNumber, NSError **handlerError) {
            (void)lineStartOffset;
            (void)lineNumber;
            metadata = [parser parseMetadataLineData:lineData error:handlerError];
            return NO;
        } error:error];
    if (metadataRead == nil) {
        return nil;
    }
    if (metadata == nil) {
        CPASetIncrementalImporterError(error,
            @"Codex source has no complete supported metadata record");
        return nil;
    }
    if (!metadata.isRootUserThread) {
        if (![metadata.threadSource isEqualToString:@"subagent"]) {
            CPASetIncrementalImporterError(error,
                @"Codex source thread_source is unsupported");
            return nil;
        }
        CPACodexIncrementalImportResult *skipped =
            [[CPACodexIncrementalImportResult alloc] init];
        skipped.skippedNonRootThread = YES;
        return skipped;
    }
    BOOL tombstoned = [store isSourceTombstonedForKind:@"codex"
        externalID:metadata.threadID error:error];
    if (error != NULL && *error != nil) {
        return nil;
    }
    if (tombstoned) {
        CPACodexIncrementalImportResult *skipped =
            [[CPACodexIncrementalImportResult alloc] init];
        skipped.skippedDeletedSource = YES;
        return skipped;
    }

    CPALocalSourceCursor *storedCursor = [store codexCursorForThreadID:metadata.threadID
        error:error];
    if (error != NULL && *error != nil) {
        return nil;
    }
    BOOL cursorMatches = storedCursor != nil
        && storedCursor.deviceID == initialIdentity.deviceID
        && storedCursor.inode == initialIdentity.inode
        && storedCursor.parserVersion == CPACodexParserVersion
        && initialIdentity.size >= storedCursor.safeOffset;
    BOOL didResetCursor = storedCursor != nil && !cursorMatches;
    uint64_t startingOffset = cursorMatches ? storedCursor.safeOffset : 0;
    NSUInteger startingLineNumber = cursorMatches ? storedCursor.safeLineNumber : 0;

    NSMutableArray<CPACodexMessage *> *messages = [NSMutableArray array];
    CPAJSONLReadResult *readResult = [reader readURL:fileURL
        startingAtOffset:startingOffset
        lineHandler:^BOOL(NSData *lineData, uint64_t lineStartOffset,
            NSUInteger relativeLineNumber, NSError **handlerError) {
            NSUInteger absoluteLineNumber = startingLineNumber + relativeLineNumber;
            if (startingOffset == 0 && absoluteLineNumber == 1) {
                NSError *metadataError = nil;
                CPACodexSourceMetadata *replayedMetadata =
                    [parser parseMetadataLineData:lineData error:&metadataError];
                if (replayedMetadata == nil
                    || ![replayedMetadata.threadID isEqualToString:metadata.threadID]
                    || !replayedMetadata.isRootUserThread) {
                    if (handlerError != NULL) {
                        *handlerError = metadataError ?: [NSError
                            errorWithDomain:CPACodexIncrementalImporterErrorDomain
                            code:1 userInfo:@{NSLocalizedDescriptionKey:
                                @"Codex metadata changed during import"}];
                    }
                    return NO;
                }
                return YES;
            }
            NSError *parseError = nil;
            CPACodexMessage *message = [parser parseMessageLineData:lineData
                lineNumber:absoluteLineNumber lineStartOffset:lineStartOffset
                error:&parseError];
            if (parseError != nil) {
                if (handlerError != NULL) {
                    *handlerError = parseError;
                }
                return NO;
            }
            if (message != nil) {
                [messages addObject:message];
            }
            return YES;
        } error:error];
    if (readResult == nil) {
        return nil;
    }

    CPAFileIdentity finalIdentity;
    if (!CPAReadFileIdentity(fileURL, &finalIdentity, error)) {
        return nil;
    }
    if (initialIdentity.deviceID != finalIdentity.deviceID
        || initialIdentity.inode != finalIdentity.inode
        || finalIdentity.size < readResult.safeOffset) {
        CPASetIncrementalImporterError(error,
            @"Codex source changed identity or was truncated during import");
        return nil;
    }

    NSUInteger finalLineNumber = startingLineNumber + readResult.completeLineCount;
    CPALocalSourceCursor *advancedCursor = [[CPALocalSourceCursor alloc]
        initWithThreadID:metadata.threadID
        deviceID:finalIdentity.deviceID inode:finalIdentity.inode
        safeOffset:readResult.safeOffset safeLineNumber:finalLineNumber
        fileSize:finalIdentity.size parserVersion:CPACodexParserVersion];
    CPALocalImportResult *storeResult = [store importCodexMetadata:metadata
        messages:messages advancingCursor:advancedCursor error:error];
    if (storeResult == nil) {
        return nil;
    }

    CPACodexIncrementalImportResult *result =
        [[CPACodexIncrementalImportResult alloc] init];
    result.insertedMessageCount = storeResult.insertedMessageCount;
    result.existingMessageCount = storeResult.existingMessageCount;
    result.safeOffset = readResult.safeOffset;
    result.safeLineNumber = finalLineNumber;
    result.trailingByteCount = readResult.trailingByteCount;
    result.didResetCursor = didResetCursor;
    return result;
}

@end
