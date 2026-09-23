#import <Foundation/Foundation.h>

#import <fcntl.h>
#import <sqlite3.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "../../Sources/CodexDataCore/CodexIncrementalImporter.h"
#import "../../Sources/CodexDataCore/CodexRecordParser.h"
#import "../../Sources/CodexDataCore/CodexSourceMetadata.h"
#import "../../Sources/CodexDataCore/JSONLLineReader.h"
#import "../../Sources/CodexDataCore/KeychainStore.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"
#import "../../Sources/CodexDataCore/MessageCrypto.h"

static NSString * const CPADefaultKeychainService = @"local.codex.prompt-assistant";
static NSString * const CPAKeychainAccount = @"database-master-key";

static NSArray<NSURL *> *JSONLFiles(NSURL *directory, NSError **error) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    __block NSError *enumerationError = nil;
    NSArray<NSURLResourceKey> *keys = @[
        NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
    ];
    NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager
        enumeratorAtURL:directory includingPropertiesForKeys:keys
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
                userInfo:@{NSLocalizedDescriptionKey: @"History directory is unavailable"}];
        }
        return nil;
    }
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSURL *url = nil;
    while ((url = [enumerator nextObject]) != nil) {
        NSNumber *isDirectory = nil;
        NSNumber *isRegular = nil;
        NSNumber *isSymlink = nil;
        NSError *resourceError = nil;
        BOOL loaded = [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey
                error:&resourceError]
            && [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey
                error:&resourceError]
            && [url getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey
                error:&resourceError];
        if (!loaded) {
            enumerationError = resourceError;
            break;
        }
        if (isSymlink.boolValue) {
            if (isDirectory.boolValue) {
                [enumerator skipDescendants];
            }
            continue;
        }
        if (isRegular.boolValue
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

static CPACodexSourceMetadata *MetadataForURL(NSURL *url) {
    CPAJSONLLineReader *reader = [[CPAJSONLLineReader alloc] initWithChunkSize:64 * 1024];
    CPACodexRecordParser *parser = [[CPACodexRecordParser alloc] init];
    __block CPACodexSourceMetadata *metadata = nil;
    NSError *error = nil;
    CPAJSONLReadResult *result = [reader readURL:url startingAtOffset:0
        lineHandler:^BOOL(NSData *lineData, uint64_t lineStartOffset,
            NSUInteger lineNumber, NSError **handlerError) {
            (void)lineStartOffset;
            (void)lineNumber;
            metadata = [parser parseMetadataLineData:lineData error:handlerError];
            return NO;
        } error:&error];
    return result != nil && error == nil ? metadata : nil;
}

static void RemoveStagingArtifacts(NSURL *databaseURL) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *suffixes = @[@"", @"-wal", @"-shm"];
    for (NSUInteger i = 0, len = suffixes.count; i < len; i++) {
        NSString *path = [databaseURL.path stringByAppendingString:suffixes[i]];
        if ([fileManager fileExistsAtPath:path]) {
            [fileManager removeItemAtPath:path error:nil];
        }
    }
}

static NSError *RebuildError(NSString *description) {
    return [NSError errorWithDomain:@"local.codex.prompt-assistant.rebuild"
        code:1 userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSArray<NSDictionary<NSString *, NSString *> *> *ReadTombstones(
    NSString *databasePath, NSError **error) {
    struct stat status;
    if (lstat(databasePath.fileSystemRepresentation, &status) != 0
        || !S_ISREG(status.st_mode) || S_ISLNK(status.st_mode)) {
        if (error != NULL) {
            *error = RebuildError(@"Tombstone source must be a regular file");
        }
        return nil;
    }
    char *resolvedFileSystemPath = realpath(databasePath.fileSystemRepresentation, NULL);
    if (resolvedFileSystemPath == NULL) {
        if (error != NULL) {
            *error = RebuildError(@"Cannot resolve tombstone source");
        }
        return nil;
    }
    NSString *resolvedPath = [NSString stringWithUTF8String:resolvedFileSystemPath];
    free(resolvedFileSystemPath);
    if (resolvedPath == nil) {
        if (error != NULL) {
            *error = RebuildError(@"Tombstone source path is invalid");
        }
        return nil;
    }
    sqlite3 *database = NULL;
    int openStatus = sqlite3_open_v2(resolvedPath.fileSystemRepresentation, &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, NULL);
    if (openStatus != SQLITE_OK) {
        if (database != NULL) {
            sqlite3_close_v2(database);
        }
        if (error != NULL) {
            *error = RebuildError([NSString stringWithFormat:
                @"Cannot open tombstone source (%s)", sqlite3_errstr(openStatus)]);
        }
        return nil;
    }
    sqlite3_stmt *tableStatement = NULL;
    int prepareStatus = sqlite3_prepare_v2(database,
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_tombstones'",
        -1, &tableStatement, NULL);
    if (prepareStatus != SQLITE_OK) {
        sqlite3_close_v2(database);
        if (error != NULL) {
            *error = RebuildError(@"Cannot inspect tombstone source schema");
        }
        return nil;
    }
    int tableStepStatus = sqlite3_step(tableStatement);
    BOOL hasTable = tableStepStatus == SQLITE_ROW;
    sqlite3_finalize(tableStatement);
    if (tableStepStatus != SQLITE_ROW && tableStepStatus != SQLITE_DONE) {
        sqlite3_close_v2(database);
        if (error != NULL) {
            *error = RebuildError(@"Cannot inspect tombstone source schema");
        }
        return nil;
    }
    if (!hasTable) {
        sqlite3_close_v2(database);
        return @[];
    }

    sqlite3_stmt *statement = NULL;
    prepareStatus = sqlite3_prepare_v2(database,
        "SELECT kind, external_id FROM source_tombstones ORDER BY kind, external_id",
        -1, &statement, NULL);
    if (prepareStatus != SQLITE_OK) {
        sqlite3_close_v2(database);
        if (error != NULL) {
            *error = RebuildError(@"Cannot read tombstone source");
        }
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *tombstones =
        [NSMutableArray array];
    int stepStatus = SQLITE_ROW;
    while ((stepStatus = sqlite3_step(statement)) == SQLITE_ROW) {
        const unsigned char *kindText = sqlite3_column_text(statement, 0);
        const unsigned char *externalIDText = sqlite3_column_text(statement, 1);
        if (kindText == NULL || externalIDText == NULL) {
            stepStatus = SQLITE_CORRUPT;
            break;
        }
        NSString *kind = [NSString stringWithUTF8String:(const char *)kindText];
        NSString *externalID = [NSString stringWithUTF8String:
            (const char *)externalIDText];
        if (kind == nil || externalID == nil) {
            stepStatus = SQLITE_CORRUPT;
            break;
        }
        [tombstones addObject:@{@"kind": kind, @"external_id": externalID}];
    }
    sqlite3_finalize(statement);
    sqlite3_close_v2(database);
    if (stepStatus != SQLITE_DONE) {
        if (error != NULL) {
            *error = RebuildError(@"Tombstone source contains invalid records");
        }
        return nil;
    }
    return tombstones;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--delete-test-key") == 0) {
            NSString *service = [NSString stringWithUTF8String:argv[2]];
            if (![service hasPrefix:@"local.codex.prompt-assistant.rebuild-test."]) {
                fprintf(stderr, "test_key_delete=false invalid_service\n");
                return 2;
            }
            NSError *deleteError = nil;
            BOOL deleted = [[[CPAKeychainStore alloc] init] deleteKeyForService:service
                account:CPAKeychainAccount error:&deleteError];
            if (!deleted) {
                fprintf(stderr, "test_key_delete=false\n");
                return 1;
            }
            printf("test_key_delete=true\n");
            return 0;
        }
        if (argc != 4 && argc != 5 && argc != 6) {
            fprintf(stderr, "usage: CodexDataRebuild <active-dir> <archived-dir> "
                "<new.staging.sqlite3> [keychain-service] [tombstone-source.sqlite3]\n");
            return 2;
        }
        NSString *activePath = [NSString stringWithUTF8String:argv[1]];
        NSString *archivedPath = [NSString stringWithUTF8String:argv[2]];
        NSString *databasePath = [NSString stringWithUTF8String:argv[3]];
        NSString *service = argc >= 5
            ? [NSString stringWithUTF8String:argv[4]]
            : CPADefaultKeychainService;
        NSString *tombstoneSourcePath = argc == 6
            ? [NSString stringWithUTF8String:argv[5]] : nil;
        if (![databasePath hasSuffix:@".staging.sqlite3"]) {
            fprintf(stderr, "rebuild_failed=destination_must_be_staging\n");
            return 2;
        }
        NSURL *databaseURL = [NSURL fileURLWithPath:databasePath];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSArray<NSString *> *suffixes = @[@"", @"-wal", @"-shm"];
        for (NSUInteger i = 0, len = suffixes.count; i < len; i++) {
            if ([fileManager fileExistsAtPath:
                    [databasePath stringByAppendingString:suffixes[i]]]) {
                fprintf(stderr, "rebuild_failed=destination_exists\n");
                return 2;
            }
        }

        NSError *error = nil;
        CPAKeychainStore *keychain = [[CPAKeychainStore alloc] init];
        NSData *masterKey = [keychain keyDataForService:service
            account:CPAKeychainAccount error:&error];
        if (error != nil) {
            fprintf(stderr, "rebuild_failed=keychain_read\n");
            return 1;
        }
        if (masterKey == nil) {
            masterKey = [[[CPAMessageCrypto alloc] init] generateRandomMasterKey:&error];
            if (masterKey == nil || ![keychain storeKeyData:masterKey service:service
                    account:CPAKeychainAccount error:&error]) {
                fprintf(stderr, "rebuild_failed=keychain_create\n");
                return 1;
            }
        }
        if (masterKey.length != 64) {
            fprintf(stderr, "rebuild_failed=invalid_master_key\n");
            return 1;
        }

        NSURL *activeURL = [NSURL fileURLWithPath:activePath isDirectory:YES];
        NSURL *archivedURL = [NSURL fileURLWithPath:archivedPath isDirectory:YES];
        NSArray<NSURL *> *activeFiles = JSONLFiles(activeURL, &error);
        NSArray<NSURL *> *archivedFiles = error == nil ? JSONLFiles(archivedURL, &error) : nil;
        if (activeFiles == nil || archivedFiles == nil || error != nil) {
            fprintf(stderr, "rebuild_failed=source_discovery\n");
            return 1;
        }
        NSArray<NSDictionary<NSString *, NSString *> *> *tombstones =
            tombstoneSourcePath == nil ? @[] : ReadTombstones(tombstoneSourcePath, &error);
        if (tombstones == nil || error != nil) {
            fprintf(stderr, "rebuild_failed=tombstone_source detail=%s\n",
                error.localizedDescription.UTF8String);
            return 1;
        }

        NSMutableDictionary<NSString *, NSURL *> *selected = [NSMutableDictionary dictionary];
        NSUInteger subagentCount = 0;
        NSUInteger unsupportedCount = 0;
        NSUInteger duplicateCount = 0;
        for (NSUInteger group = 0; group < 2; group++) {
            NSArray<NSURL *> *files = group == 0 ? activeFiles : archivedFiles;
            for (NSUInteger i = 0, len = files.count; i < len; i++) {
                CPACodexSourceMetadata *metadata = MetadataForURL(files[i]);
                if (metadata == nil) {
                    unsupportedCount++;
                    continue;
                }
                if (!metadata.isRootUserThread) {
                    subagentCount++;
                    continue;
                }
                if (selected[metadata.threadID] != nil) {
                    duplicateCount++;
                }
                selected[metadata.threadID] = files[i];
            }
        }

        int stagingDescriptor = open(databaseURL.fileSystemRepresentation,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (stagingDescriptor < 0) {
            fprintf(stderr, "rebuild_failed=secure_staging_create\n");
            return 2;
        }
        if (close(stagingDescriptor) != 0) {
            RemoveStagingArtifacts(databaseURL);
            fprintf(stderr, "rebuild_failed=secure_staging_close\n");
            return 1;
        }
        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:masterKey error:&error];
        if (store == nil) {
            RemoveStagingArtifacts(databaseURL);
            fprintf(stderr, "rebuild_failed=database_open\n");
            return 1;
        }
        for (NSUInteger i = 0, len = tombstones.count; i < len; i++) {
            NSDictionary<NSString *, NSString *> *tombstone = tombstones[i];
            if (![store deleteSourceKind:tombstone[@"kind"]
                    externalID:tombstone[@"external_id"] error:&error]) {
                [store close:nil];
                RemoveStagingArtifacts(databaseURL);
                fprintf(stderr, "rebuild_failed=tombstone_copy\n");
                return 1;
            }
        }
        CPACodexIncrementalImporter *importer = [[CPACodexIncrementalImporter alloc]
            initWithChunkSize:64 * 1024];
        NSArray<NSString *> *threadIDs = [selected.allKeys sortedArrayUsingSelector:
            @selector(compare:)];
        NSUInteger insertedCount = 0;
        NSUInteger tombstonedSourceCount = 0;
        for (NSUInteger i = 0, len = threadIDs.count; i < len; i++) {
            NSURL *url = selected[threadIDs[i]];
            CPACodexIncrementalImportResult *result = [importer importFileAtURL:url
                intoStore:store error:&error];
            if (result == nil || error != nil) {
                [store close:nil];
                RemoveStagingArtifacts(databaseURL);
                fprintf(stderr, "rebuild_failed=source_import\n");
                return 1;
            }
            insertedCount += result.insertedMessageCount;
            if (result.skippedDeletedSource) {
                tombstonedSourceCount++;
            }
        }
        if (![store close:&error]) {
            RemoveStagingArtifacts(databaseURL);
            fprintf(stderr, "rebuild_failed=database_close\n");
            return 1;
        }
        printf("rebuild_complete=true files=%lu root=%lu subagent=%lu unsupported=%lu "
            "duplicates=%lu inserted_messages=%lu tombstones_preserved=%lu "
            "tombstoned_sources=%lu\n",
            (unsigned long)(activeFiles.count + archivedFiles.count),
            (unsigned long)selected.count,
            (unsigned long)subagentCount,
            (unsigned long)unsupportedCount,
            (unsigned long)duplicateCount,
            (unsigned long)insertedCount,
            (unsigned long)tombstones.count,
            (unsigned long)tombstonedSourceCount);
    }
    return 0;
}
