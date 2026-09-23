#import "DataFoundationController.h"

#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "../CodexDataCore/CodexIncrementalImporter.h"
#import "../CodexDataCore/CodexRecordParser.h"
#import "../CodexDataCore/CodexSourceMetadata.h"
#import "../CodexDataCore/JSONLLineReader.h"
#import "../CodexDataCore/KeychainStore.h"
#import "../CodexDataCore/LocalDataStore.h"
#import "../CodexDataCore/LocalExpressionRecord.h"
#import "../CodexDataCore/MessageCrypto.h"
#import "../ExpressionLibraryCore/ExpressionLibraryBuilder.h"
#import "../ExpressionLibraryCore/ExpressionSuggestionIndex.h"

typedef struct {
    uint64_t deviceID;
    uint64_t inode;
    BOOL valid;
} CPADataDirectoryIdentity;

@interface CPADataSourceCandidate : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) BOOL archived;
@end

@implementation CPADataSourceCandidate
@end

@interface CPADataFoundationSnapshot ()
@property(nonatomic, readwrite) CPADataFoundationState state;
@property(nonatomic, readwrite) NSUInteger discoveredFileCount;
@property(nonatomic, readwrite) NSUInteger processedFileCount;
@property(nonatomic, readwrite) NSUInteger succeededFileCount;
@property(nonatomic, readwrite) NSUInteger skippedFileCount;
@property(nonatomic, readwrite) NSUInteger failedFileCount;
@property(nonatomic, readwrite) NSUInteger sourceErrorCount;
@property(nonatomic, readwrite) NSUInteger insertedMessageCount;
@property(nonatomic, readwrite) NSUInteger existingMessageCount;
@property(nonatomic, readwrite) NSUInteger storedSourceCount;
@property(nonatomic, readwrite) NSUInteger storedConversationCount;
@property(nonatomic, readwrite) NSUInteger storedMessageCount;
@property(nonatomic, readwrite) NSUInteger importRunCount;
@property(nonatomic, readwrite) NSUInteger tombstoneCount;
@property(nonatomic, readwrite) NSUInteger storedExpressionCount;
@property(nonatomic, readwrite) NSUInteger expressionBuildDurationMilliseconds;
@property(nonatomic, copy, readwrite) NSString *expressionBuildStatus;
@end

@implementation CPADataFoundationSnapshot

- (id)copyWithZone:(NSZone *)zone {
    CPADataFoundationSnapshot *copy = [[[self class] allocWithZone:zone] init];
    copy.state = self.state;
    copy.discoveredFileCount = self.discoveredFileCount;
    copy.processedFileCount = self.processedFileCount;
    copy.succeededFileCount = self.succeededFileCount;
    copy.skippedFileCount = self.skippedFileCount;
    copy.failedFileCount = self.failedFileCount;
    copy.sourceErrorCount = self.sourceErrorCount;
    copy.insertedMessageCount = self.insertedMessageCount;
    copy.existingMessageCount = self.existingMessageCount;
    copy.storedSourceCount = self.storedSourceCount;
    copy.storedConversationCount = self.storedConversationCount;
    copy.storedMessageCount = self.storedMessageCount;
    copy.importRunCount = self.importRunCount;
    copy.tombstoneCount = self.tombstoneCount;
    copy.storedExpressionCount = self.storedExpressionCount;
    copy.expressionBuildDurationMilliseconds = self.expressionBuildDurationMilliseconds;
    copy.expressionBuildStatus = self.expressionBuildStatus;
    return copy;
}

- (NSString *)statusTitle {
    switch (self.state) {
        case CPADataFoundationStateNotScanned:
            return @"数据：未扫描";
        case CPADataFoundationStateScanning:
            return [NSString stringWithFormat:@"数据：扫描中 %lu/%lu",
                (unsigned long)self.processedFileCount,
                (unsigned long)self.discoveredFileCount];
        case CPADataFoundationStatePaused:
            return [NSString stringWithFormat:@"数据：已暂停 %lu/%lu",
                (unsigned long)self.processedFileCount,
                (unsigned long)self.discoveredFileCount];
        case CPADataFoundationStateSynced:
            return [NSString stringWithFormat:@"数据：已同步 · %lu 条消息",
                (unsigned long)self.storedMessageCount];
        case CPADataFoundationStatePartialFailure:
            return [NSString stringWithFormat:@"数据：部分失败 · %lu 项",
                (unsigned long)(self.failedFileCount + self.sourceErrorCount)];
    }
}

- (NSString *)diagnosticSummary {
    return [NSString stringWithFormat:
        @"状态：%@\n发现文件：%lu\n已处理文件：%lu\n成功文件：%lu\n"
        @"跳过文件：%lu\n失败文件：%lu\n来源错误：%lu\n"
        @"本次新增消息：%lu\n本次已存在消息：%lu\n"
        @"库存来源：%lu\n库存会话：%lu\n库存消息：%lu\n导入批次：%lu\n删除记录：%lu\n"
        @"表达数量：%lu\n表达构建：%@\n构建耗时毫秒：%lu",
        self.statusTitle,
        (unsigned long)self.discoveredFileCount,
        (unsigned long)self.processedFileCount,
        (unsigned long)self.succeededFileCount,
        (unsigned long)self.skippedFileCount,
        (unsigned long)self.failedFileCount,
        (unsigned long)self.sourceErrorCount,
        (unsigned long)self.insertedMessageCount,
        (unsigned long)self.existingMessageCount,
        (unsigned long)self.storedSourceCount,
        (unsigned long)self.storedConversationCount,
        (unsigned long)self.storedMessageCount,
        (unsigned long)self.importRunCount,
        (unsigned long)self.tombstoneCount,
        (unsigned long)self.storedExpressionCount,
        self.expressionBuildStatus,
        (unsigned long)self.expressionBuildDurationMilliseconds];
}

@end

@interface CPADataFoundationController ()
@property(nonatomic, strong) NSURL *activeDirectory;
@property(nonatomic, strong) NSURL *archivedDirectory;
@property(nonatomic, strong) NSURL *databaseURL;
@property(nonatomic, copy) CPADataFoundationMasterKeyProvider masterKeyProvider;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@property(nonatomic, strong) dispatch_queue_t workerQueue;
@property(nonatomic, strong) CPADataFoundationSnapshot *snapshot;
@property(nonatomic, copy, nullable) CPADataFoundationUpdateHandler storedUpdateHandler;
@property(nonatomic) BOOL pauseRequested;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) CPAExpressionSuggestionIndex *suggestionIndex;
@end

@implementation CPADataFoundationController

- (instancetype)initWithActiveDirectory:(NSURL *)activeDirectory
    archivedDirectory:(NSURL *)archivedDirectory
    databaseURL:(NSURL *)databaseURL
    keychainService:(NSString *)keychainService
    keychainAccount:(NSString *)keychainAccount
    callbackQueue:(dispatch_queue_t)callbackQueue {
    CPADataFoundationMasterKeyProvider provider = ^NSData *(NSError **error) {
        CPAKeychainStore *keychain = [[CPAKeychainStore alloc] init];
        NSData *key = [keychain keyDataForService:keychainService
            account:keychainAccount error:error];
        if (key != nil || (error != NULL && *error != nil)) {
            return key;
        }
        CPAMessageCrypto *crypto = [[CPAMessageCrypto alloc] init];
        key = [crypto generateRandomMasterKey:error];
        if (key == nil || ![keychain storeKeyData:key service:keychainService
                account:keychainAccount error:error]) {
            return nil;
        }
        return key;
    };
    return [self initWithActiveDirectory:activeDirectory
        archivedDirectory:archivedDirectory
        databaseURL:databaseURL
        masterKeyProvider:provider
        callbackQueue:callbackQueue];
}

- (instancetype)initWithActiveDirectory:(NSURL *)activeDirectory
    archivedDirectory:(NSURL *)archivedDirectory
    databaseURL:(NSURL *)databaseURL
    masterKeyProvider:(CPADataFoundationMasterKeyProvider)masterKeyProvider
    callbackQueue:(dispatch_queue_t)callbackQueue {
    self = [super init];
    if (self != nil) {
        _activeDirectory = [activeDirectory URLByStandardizingPath];
        _archivedDirectory = [archivedDirectory URLByStandardizingPath];
        _databaseURL = [databaseURL URLByStandardizingPath];
        _masterKeyProvider = [masterKeyProvider copy];
        _callbackQueue = callbackQueue;
        _workerQueue = dispatch_queue_create(
            "local.codex.prompt-assistant.data-foundation", DISPATCH_QUEUE_SERIAL);
        _snapshot = [[CPADataFoundationSnapshot alloc] init];
        _snapshot.state = CPADataFoundationStateNotScanned;
        _snapshot.expressionBuildStatus = @"not_built";
        _suggestionIndex = [[CPAExpressionSuggestionIndex alloc]
            initWithExpressions:@[]];
    }
    return self;
}

- (CPADataFoundationUpdateHandler)updateHandler {
    @synchronized (self) {
        return self.storedUpdateHandler;
    }
}

- (void)setUpdateHandler:(CPADataFoundationUpdateHandler)updateHandler {
    @synchronized (self) {
        self.storedUpdateHandler = updateHandler;
    }
}

- (CPADataFoundationSnapshot *)currentSnapshot {
    @synchronized (self) {
        return [self.snapshot copy];
    }
}

- (BOOL)startScan {
    __block BOOL accepted = NO;
    [self mutateSnapshot:^(CPADataFoundationSnapshot *snapshot) {
        if (snapshot.state == CPADataFoundationStateScanning) {
            return;
        }
        self.pauseRequested = NO;
        self.generation++;
        snapshot.state = CPADataFoundationStateScanning;
        snapshot.discoveredFileCount = 0;
        snapshot.processedFileCount = 0;
        snapshot.succeededFileCount = 0;
        snapshot.skippedFileCount = 0;
        snapshot.failedFileCount = 0;
        snapshot.sourceErrorCount = 0;
        snapshot.insertedMessageCount = 0;
        snapshot.existingMessageCount = 0;
        snapshot.expressionBuildStatus = @"pending";
        snapshot.expressionBuildDurationMilliseconds = 0;
        accepted = YES;
    }];
    if (!accepted) {
        return NO;
    }
    NSUInteger generation = 0;
    @synchronized (self) {
        generation = self.generation;
    }
    dispatch_async(self.workerQueue, ^{
        [self performScanForGeneration:generation];
    });
    return YES;
}

- (void)requestPause {
    @synchronized (self) {
        if (self.snapshot.state == CPADataFoundationStateScanning) {
            self.pauseRequested = YES;
        }
    }
}

- (BOOL)resumeScan {
    @synchronized (self) {
        if (self.snapshot.state != CPADataFoundationStatePaused) {
            return NO;
        }
    }
    return [self startScan];
}

- (void)performScanForGeneration:(NSUInteger)generation {
    @autoreleasepool {
        NSError *activeError = nil;
        NSError *archivedError = nil;
        CPADataDirectoryIdentity activeIdentity = {0};
        CPADataDirectoryIdentity archivedIdentity = {0};
        NSArray<NSURL *> *activeFiles = [self JSONLFilesBelowDirectory:self.activeDirectory
            identity:&activeIdentity error:&activeError];
        NSArray<NSURL *> *archivedFiles = [self JSONLFilesBelowDirectory:self.archivedDirectory
            identity:&archivedIdentity error:&archivedError];
        NSUInteger duplicateFileCount = 0;
        NSArray<NSURL *> *files = [self preferredFilesFromActive:activeFiles ?: @[]
            archived:archivedFiles ?: @[] duplicateCount:&duplicateFileCount];
        NSUInteger discoveredFileCount = (activeFiles != nil ? activeFiles.count : 0)
            + (archivedFiles != nil ? archivedFiles.count : 0);
        NSUInteger sourceErrors = (activeError != nil ? 1 : 0)
            + (archivedError != nil ? 1 : 0);
        BOOL sourceCollectionSucceeded = sourceErrors == 0;
        BOOL fileImportsSucceeded = YES;
        [self mutateSnapshotForGeneration:generation block:^(CPADataFoundationSnapshot *snapshot) {
            snapshot.discoveredFileCount = discoveredFileCount;
            snapshot.processedFileCount = duplicateFileCount;
            snapshot.skippedFileCount = duplicateFileCount;
            snapshot.sourceErrorCount = sourceErrors;
        }];
        if ([self shouldPauseGeneration:generation]) {
            [self finishPausedGeneration:generation];
            return;
        }

        NSError *storeError = nil;
        CPALocalDataStore *store = [self openStore:&storeError];
        if (store == nil) {
            [self mutateSnapshotForGeneration:generation
                block:^(CPADataFoundationSnapshot *snapshot) {
                    snapshot.sourceErrorCount++;
                    snapshot.expressionBuildStatus = @"failed";
                    snapshot.state = CPADataFoundationStatePartialFailure;
                }];
            return;
        }
        CPACodexIncrementalImporter *importer = [[CPACodexIncrementalImporter alloc]
            initWithChunkSize:64 * 1024];
        for (NSUInteger i = 0, len = files.count; i < len; i++) {
            if ([self shouldPauseGeneration:generation]) {
                [self updateStoredCountsFromStore:store generation:generation];
                NSError *closeError = nil;
                if (![store close:&closeError]) {
                    [self mutateSnapshotForGeneration:generation
                        block:^(CPADataFoundationSnapshot *snapshot) {
                            snapshot.sourceErrorCount++;
                        }];
                }
                [self finishPausedGeneration:generation];
                return;
            }
            @autoreleasepool {
                NSError *fileError = nil;
                CPACodexIncrementalImportResult *result = [importer
                    importFileAtURL:files[i] intoStore:store error:&fileError];
                BOOL fileFailed = result == nil || fileError != nil;
                if (fileFailed) {
                    fileImportsSucceeded = NO;
                }
                [self mutateSnapshotForGeneration:generation
                    block:^(CPADataFoundationSnapshot *snapshot) {
                        snapshot.processedFileCount++;
                        if (fileFailed) {
                            snapshot.failedFileCount++;
                        } else if (result.skippedNonRootThread
                            || result.skippedDeletedSource) {
                            snapshot.skippedFileCount++;
                        } else {
                            snapshot.succeededFileCount++;
                            snapshot.insertedMessageCount += result.insertedMessageCount;
                            snapshot.existingMessageCount += result.existingMessageCount;
                        }
                    }];
            }
        }
        BOOL directoryChanged = (activeIdentity.valid
                && ![self directory:self.activeDirectory stillMatches:activeIdentity])
            || (archivedIdentity.valid
                && ![self directory:self.archivedDirectory stillMatches:archivedIdentity]);
        if (directoryChanged) {
            [self mutateSnapshotForGeneration:generation
                block:^(CPADataFoundationSnapshot *snapshot) {
                    snapshot.sourceErrorCount++;
                }];
        }
        BOOL mayBuildExpressions = sourceCollectionSucceeded
            && fileImportsSucceeded && !directoryChanged;
        if (mayBuildExpressions) {
            CFAbsoluteTime buildStarted = CFAbsoluteTimeGetCurrent();
            NSError *buildError = nil;
            NSArray<CPALocalExpressionRecord *> *expressionRecords =
                [self buildExpressionRecordsForStore:store error:&buildError];
            NSUInteger durationMilliseconds = (NSUInteger)llround(
                (CFAbsoluteTimeGetCurrent() - buildStarted) * 1000.0);
            if (expressionRecords == nil || buildError != nil) {
                [self mutateSnapshotForGeneration:generation
                    block:^(CPADataFoundationSnapshot *snapshot) {
                        snapshot.sourceErrorCount++;
                        snapshot.expressionBuildStatus = @"failed";
                        snapshot.expressionBuildDurationMilliseconds =
                            durationMilliseconds;
                    }];
            } else {
                CPAExpressionSuggestionIndex *newIndex =
                    [[CPAExpressionSuggestionIndex alloc]
                        initWithExpressions:expressionRecords];
                @synchronized (self) {
                    self.suggestionIndex = newIndex;
                }
                [self mutateSnapshotForGeneration:generation
                    block:^(CPADataFoundationSnapshot *snapshot) {
                        snapshot.storedExpressionCount = expressionRecords.count;
                        snapshot.expressionBuildStatus = @"success";
                        snapshot.expressionBuildDurationMilliseconds =
                            durationMilliseconds;
                    }];
            }
        } else {
            [self mutateSnapshotForGeneration:generation
                block:^(CPADataFoundationSnapshot *snapshot) {
                    snapshot.expressionBuildStatus = @"skipped_partial";
                }];
        }
        [self updateStoredCountsFromStore:store generation:generation];
        NSError *closeError = nil;
        if (![store close:&closeError]) {
            [self mutateSnapshotForGeneration:generation
                block:^(CPADataFoundationSnapshot *snapshot) {
                    snapshot.sourceErrorCount++;
                }];
        }
        if ([self shouldPauseGeneration:generation]) {
            [self finishPausedGeneration:generation];
            return;
        }
        [self mutateSnapshotForGeneration:generation block:^(CPADataFoundationSnapshot *snapshot) {
            snapshot.state = snapshot.failedFileCount > 0 || snapshot.sourceErrorCount > 0
                ? CPADataFoundationStatePartialFailure
                : CPADataFoundationStateSynced;
        }];
    }
}

- (NSArray<CPALocalExpressionRecord *> *)buildExpressionRecordsForStore:
    (CPALocalDataStore *)store error:(NSError **)error {
    CPAExpressionLibraryBuilder *builder = [[CPAExpressionLibraryBuilder alloc] init];
    CPALocalExpressionBuildResult *result = [builder rebuildStore:store error:error];
    if (result == nil) {
        return nil;
    }
    return [store loadActiveExpressions:error];
}

- (NSString *)suggestionForInput:(NSString *)input
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength {
    CPAExpressionSuggestionIndex *index = nil;
    @synchronized (self) {
        index = self.suggestionIndex;
    }
    CPAExpressionSuggestion *suggestion = [index suggestionForInput:input
        cursorLocation:cursorLocation selectedLength:selectedLength];
    return suggestion.insertionText;
}

- (NSArray<NSURL *> *)preferredFilesFromActive:(NSArray<NSURL *> *)activeFiles
    archived:(NSArray<NSURL *> *)archivedFiles
    duplicateCount:(NSUInteger *)duplicateCount {
    NSMutableDictionary<NSString *, CPADataSourceCandidate *> *byThreadID =
        [NSMutableDictionary dictionary];
    NSMutableArray<CPADataSourceCandidate *> *unclassified = [NSMutableArray array];
    NSUInteger duplicates = 0;
    for (NSUInteger groupIndex = 0; groupIndex < 2; groupIndex++) {
        NSArray<NSURL *> *files = groupIndex == 0 ? activeFiles : archivedFiles;
        BOOL archived = groupIndex == 1;
        for (NSUInteger i = 0, len = files.count; i < len; i++) {
            CPADataSourceCandidate *candidate = [[CPADataSourceCandidate alloc] init];
            candidate.url = files[i];
            candidate.archived = archived;
            CPACodexSourceMetadata *metadata = [self metadataForFileURL:candidate.url];
            if (metadata.threadID.length == 0) {
                [unclassified addObject:candidate];
                continue;
            }
            CPADataSourceCandidate *existing = byThreadID[metadata.threadID];
            if (existing == nil) {
                byThreadID[metadata.threadID] = candidate;
                continue;
            }
            duplicates++;
            if (candidate.archived && !existing.archived) {
                byThreadID[metadata.threadID] = candidate;
            }
        }
    }
    NSMutableArray<NSURL *> *preferred = [NSMutableArray array];
    NSArray<CPADataSourceCandidate *> *classified = byThreadID.allValues;
    for (NSUInteger i = 0, len = classified.count; i < len; i++) {
        [preferred addObject:classified[i].url];
    }
    for (NSUInteger i = 0, len = unclassified.count; i < len; i++) {
        [preferred addObject:unclassified[i].url];
    }
    [preferred sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.path compare:right.path];
    }];
    if (duplicateCount != NULL) {
        *duplicateCount = duplicates;
    }
    return preferred;
}

- (CPACodexSourceMetadata *)metadataForFileURL:(NSURL *)url {
    CPAJSONLLineReader *reader = [[CPAJSONLLineReader alloc] initWithChunkSize:64 * 1024];
    CPACodexRecordParser *parser = [[CPACodexRecordParser alloc] init];
    __block CPACodexSourceMetadata *metadata = nil;
    NSError *readError = nil;
    (void)[reader readURL:url startingAtOffset:0
        lineHandler:^BOOL(NSData *lineData, uint64_t lineStartOffset,
            NSUInteger lineNumber, NSError **handlerError) {
            (void)lineStartOffset;
            (void)lineNumber;
            metadata = [parser parseMetadataLineData:lineData error:handlerError];
            return NO;
        }
        error:&readError];
    return readError == nil ? metadata : nil;
}

- (CPALocalDataStore *)openStore:(NSError **)error {
    NSURL *directory = [self.databaseURL URLByDeletingLastPathComponent];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700}
            error:error]) {
        return nil;
    }
    struct stat directoryStatus;
    if (lstat(directory.fileSystemRepresentation, &directoryStatus) != 0
        || !S_ISDIR(directoryStatus.st_mode) || S_ISLNK(directoryStatus.st_mode)
        || directoryStatus.st_uid != geteuid()) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSFileWriteNoPermissionError
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Local data directory is not a safe regular directory"}];
        }
        return nil;
    }
    if (chmod(directory.fileSystemRepresentation, S_IRWXU) != 0
        || ![self prepareDatabaseFile:error]) {
        if (error != NULL && *error == nil) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Unable to secure the local data path"}];
        }
        return nil;
    }
    NSData *providedKey = self.masterKeyProvider(error);
    if (providedKey.length != 64) {
        if (error != NULL && *error == nil) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSFileWriteUnknownError
                userInfo:@{NSLocalizedDescriptionKey: @"Local data key is unavailable"}];
        }
        return nil;
    }
    NSMutableData *workingKey = [providedKey mutableCopy];
    CPALocalDataStore *store = [[CPALocalDataStore alloc]
        initWithDatabaseURL:self.databaseURL masterKey:workingKey error:error];
    memset(workingKey.mutableBytes, 0, workingKey.length);
    return store;
}

- (BOOL)prepareDatabaseFile:(NSError **)error {
    int descriptor = open(self.databaseURL.fileSystemRepresentation,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Unable to safely open the local database file"}];
        }
        return NO;
    }
    struct stat status;
    BOOL valid = YES;
    int validationError = 0;
    if (fstat(descriptor, &status) != 0) {
        valid = NO;
        validationError = errno;
    } else if (!S_ISREG(status.st_mode)
        || status.st_uid != geteuid() || status.st_nlink != 1) {
        valid = NO;
        validationError = EPERM;
    } else if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
        valid = NO;
        validationError = errno;
    }
    int closeStatus = close(descriptor);
    int closeError = closeStatus == 0 ? 0 : errno;
    if (!valid || closeStatus != 0) {
        if (error != NULL) {
            int failureCode = !valid ? validationError : closeError;
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failureCode
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Local database file failed its safety check"}];
        }
        return NO;
    }
    return YES;
}

- (void)updateStoredCountsFromStore:(CPALocalDataStore *)store
    generation:(NSUInteger)generation {
    NSError *countError = nil;
    CPALocalDataCounts *counts = [store currentCounts:&countError];
    [self mutateSnapshotForGeneration:generation block:^(CPADataFoundationSnapshot *snapshot) {
        if (counts == nil || countError != nil) {
            snapshot.sourceErrorCount++;
            return;
        }
        snapshot.storedSourceCount = counts.sourceCount;
        snapshot.storedConversationCount = counts.conversationCount;
        snapshot.storedMessageCount = counts.messageCount;
        snapshot.importRunCount = counts.importRunCount;
        snapshot.tombstoneCount = counts.tombstoneCount;
    }];
}

- (NSArray<NSURL *> *)JSONLFilesBelowDirectory:(NSURL *)directory
    identity:(CPADataDirectoryIdentity *)identity
    error:(NSError **)error {
    struct stat status;
    if (lstat(directory.fileSystemRepresentation, &status) != 0
        || !S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSFileReadNoSuchFileError
                userInfo:@{NSLocalizedDescriptionKey: @"Codex history directory is unavailable"}];
        }
        return nil;
    }
    identity->deviceID = (uint64_t)status.st_dev;
    identity->inode = (uint64_t)status.st_ino;
    identity->valid = YES;

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
                code:NSFileReadUnknownError
                userInfo:@{NSLocalizedDescriptionKey: @"Codex history cannot be enumerated"}];
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

- (BOOL)directory:(NSURL *)directory stillMatches:(CPADataDirectoryIdentity)identity {
    if (!identity.valid) {
        return NO;
    }
    struct stat status;
    return lstat(directory.fileSystemRepresentation, &status) == 0
        && S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode)
        && (uint64_t)status.st_dev == identity.deviceID
        && (uint64_t)status.st_ino == identity.inode;
}

- (BOOL)shouldPauseGeneration:(NSUInteger)generation {
    @synchronized (self) {
        return generation != self.generation || self.pauseRequested;
    }
}

- (void)finishPausedGeneration:(NSUInteger)generation {
    [self mutateSnapshotForGeneration:generation block:^(CPADataFoundationSnapshot *snapshot) {
        snapshot.state = CPADataFoundationStatePaused;
        snapshot.expressionBuildStatus = @"paused";
    }];
}

- (void)mutateSnapshotForGeneration:(NSUInteger)generation
    block:(void (^)(CPADataFoundationSnapshot *snapshot))block {
    @synchronized (self) {
        if (generation != self.generation) {
            return;
        }
    }
    [self mutateSnapshot:block];
}

- (void)mutateSnapshot:(void (^)(CPADataFoundationSnapshot *snapshot))block {
    CPADataFoundationSnapshot *published = nil;
    CPADataFoundationUpdateHandler handler = nil;
    @synchronized (self) {
        block(self.snapshot);
        published = [self.snapshot copy];
        handler = self.storedUpdateHandler;
    }
    if (handler != nil) {
        dispatch_async(self.callbackQueue, ^{
            handler(published);
        });
    }
}

@end
