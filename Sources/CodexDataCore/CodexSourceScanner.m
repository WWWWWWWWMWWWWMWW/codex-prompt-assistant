#import "CodexSourceScanner.h"

#import "CodexRecordParser.h"
#import "CodexSourceMetadata.h"
#import "JSONLLineReader.h"

@interface CPACodexScanReport ()
@property(nonatomic, readwrite) NSUInteger discoveredJSONLCount;
@property(nonatomic, readwrite) NSUInteger rootThreadCount;
@property(nonatomic, readwrite) NSUInteger subagentThreadCount;
@property(nonatomic, readwrite) NSUInteger unsupportedSourceCount;
@property(nonatomic, readwrite) NSUInteger duplicateThreadCount;
@property(nonatomic, readwrite) NSUInteger visibleMessageCount;
@property(nonatomic, readwrite) NSUInteger trailingPartialFileCount;
@property(nonatomic, readwrite) NSUInteger messageParseErrorCount;
@property(nonatomic, readwrite) uint64_t inspectedByteCount;
@end

@implementation CPACodexScanReport
@end

@interface CPACodexScannedSource : NSObject
@property(nonatomic, strong) CPACodexSourceMetadata *metadata;
@property(nonatomic) BOOL archived;
@property(nonatomic) NSUInteger visibleMessageCount;
@property(nonatomic) BOOL hasTrailingPartialLine;
@property(nonatomic) NSUInteger messageParseErrorCount;
@property(nonatomic) uint64_t inspectedByteCount;
@end

@implementation CPACodexScannedSource
@end

@implementation CPACodexSourceScanner

- (CPACodexScanReport *)scanActiveDirectory:(NSURL *)activeDirectory
    archivedDirectory:(NSURL *)archivedDirectory
    error:(NSError **)error {
    NSArray<NSURL *> *activeFiles = [self JSONLFilesBelowDirectory:activeDirectory error:error];
    if (activeFiles == nil) {
        return nil;
    }
    NSArray<NSURL *> *archivedFiles = [self JSONLFilesBelowDirectory:archivedDirectory error:error];
    if (archivedFiles == nil) {
        return nil;
    }

    CPACodexScanReport *report = [[CPACodexScanReport alloc] init];
    report.discoveredJSONLCount = activeFiles.count + archivedFiles.count;
    NSMutableDictionary<NSString *, CPACodexScannedSource *> *sourcesByThreadID =
        [NSMutableDictionary dictionary];

    for (NSUInteger groupIndex = 0; groupIndex < 2; groupIndex++) {
        NSArray<NSURL *> *files = groupIndex == 0 ? activeFiles : archivedFiles;
        BOOL archived = groupIndex == 1;
        for (NSUInteger i = 0, len = files.count; i < len; i++) {
            CPACodexScannedSource *source = [self scanFileURL:files[i]
                archived:archived];
            report.inspectedByteCount += source.inspectedByteCount;
            if (source == nil || source.metadata == nil
                || (![source.metadata.threadSource isEqualToString:@"user"]
                    && ![source.metadata.threadSource isEqualToString:@"subagent"])) {
                report.unsupportedSourceCount++;
                continue;
            }

            CPACodexScannedSource *existing = sourcesByThreadID[source.metadata.threadID];
            if (existing != nil) {
                report.duplicateThreadCount++;
                if (source.archived && !existing.archived) {
                    sourcesByThreadID[source.metadata.threadID] = source;
                }
            } else {
                sourcesByThreadID[source.metadata.threadID] = source;
            }
        }
    }

    NSArray<CPACodexScannedSource *> *uniqueSources = sourcesByThreadID.allValues;
    for (NSUInteger i = 0, len = uniqueSources.count; i < len; i++) {
        CPACodexScannedSource *source = uniqueSources[i];
        if (source.metadata.isRootUserThread) {
            report.rootThreadCount++;
            report.visibleMessageCount += source.visibleMessageCount;
            report.messageParseErrorCount += source.messageParseErrorCount;
            if (source.hasTrailingPartialLine) {
                report.trailingPartialFileCount++;
            }
        } else {
            report.subagentThreadCount++;
        }
    }
    return report;
}

- (NSArray<NSURL *> *)JSONLFilesBelowDirectory:(NSURL *)directory
    error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    __block NSError *enumerationError = nil;
    NSArray<NSURLResourceKey> *keys = @[
        NSURLIsDirectoryKey,
        NSURLIsRegularFileKey,
        NSURLIsSymbolicLinkKey,
    ];
    NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager
        enumeratorAtURL:directory
        includingPropertiesForKeys:keys
        options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:^BOOL(NSURL *url, NSError *encounteredError) {
            (void)url;
            enumerationError = encounteredError;
            return NO;
        }];
    if (enumerator == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSFileReadNoSuchFileError
                userInfo:@{NSLocalizedDescriptionKey: @"Codex history directory is unavailable"}];
        }
        return nil;
    }

    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSURL *url = nil;
    while ((url = [enumerator nextObject]) != nil) {
        NSNumber *isSymbolicLink = nil;
        NSNumber *isDirectory = nil;
        NSNumber *isRegularFile = nil;
        NSError *resourceError = nil;
        BOOL loaded = [url getResourceValue:&isSymbolicLink
            forKey:NSURLIsSymbolicLinkKey error:&resourceError]
            && [url getResourceValue:&isDirectory
                forKey:NSURLIsDirectoryKey error:&resourceError]
            && [url getResourceValue:&isRegularFile
                forKey:NSURLIsRegularFileKey error:&resourceError];
        if (!loaded) {
            enumerationError = resourceError;
            break;
        }
        if (isSymbolicLink.boolValue) {
            if (isDirectory.boolValue) {
                [enumerator skipDescendants];
            }
            continue;
        }
        if (isRegularFile.boolValue
            && [url.pathExtension localizedCaseInsensitiveCompare:@"jsonl"] == NSOrderedSame) {
            [files addObject:url];
        }
    }
    if (enumerationError != nil) {
        if (error != NULL) {
            *error = enumerationError;
        }
        return nil;
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.path compare:right.path];
    }];
    return files;
}

- (CPACodexScannedSource *)scanFileURL:(NSURL *)url archived:(BOOL)archived {
    CPAJSONLLineReader *reader = [[CPAJSONLLineReader alloc] initWithChunkSize:64 * 1024];
    CPACodexRecordParser *parser = [[CPACodexRecordParser alloc] init];
    __block CPACodexSourceMetadata *metadata = nil;
    __block NSUInteger visibleMessageCount = 0;
    __block NSUInteger messageParseErrorCount = 0;
    NSError *readError = nil;
    CPAJSONLReadResult *readResult = [reader readURL:url
        startingAtOffset:0
        lineHandler:^BOOL(NSData *lineData, uint64_t lineStartOffset, NSUInteger lineNumber,
            NSError **handlerError) {
            (void)handlerError;
            NSError *parseError = nil;
            if (lineNumber == 1) {
                metadata = [parser parseMetadataLineData:lineData error:&parseError];
                return metadata != nil && metadata.isRootUserThread;
            }
            if (metadata == nil || !metadata.isRootUserThread) {
                return YES;
            }
            id message = [parser parseMessageLineData:lineData
                lineNumber:lineNumber
                lineStartOffset:lineStartOffset
                error:&parseError];
            if (parseError != nil) {
                messageParseErrorCount++;
            } else if (message != nil) {
                visibleMessageCount++;
            }
            return YES;
        }
        error:&readError];
    if (readResult == nil || readError != nil) {
        return nil;
    }

    CPACodexScannedSource *source = [[CPACodexScannedSource alloc] init];
    source.metadata = metadata;
    source.archived = archived;
    source.visibleMessageCount = visibleMessageCount;
    source.hasTrailingPartialLine = readResult.trailingByteCount > 0;
    source.messageParseErrorCount = messageParseErrorCount;
    source.inspectedByteCount = readResult.inspectedByteCount;
    return source;
}

@end
