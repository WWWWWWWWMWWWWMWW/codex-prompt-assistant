#import "LocalDataStore.h"

#import <CommonCrypto/CommonHMAC.h>
#import <sqlite3.h>
#import <sys/stat.h>

#import "CodexMessage.h"
#import "CodexSourceMetadata.h"
#import "LocalExpressionRecord.h"
#import "LocalUserMessageRecord.h"
#import "MessageCrypto.h"
#import "SensitiveTextRedactor.h"

static NSString * const CPALocalDataStoreErrorDomain = @"CPALocalDataStoreErrorDomain";

static NSString * const CPASchemaSQL =
    @"PRAGMA foreign_keys=ON;"
    @"PRAGMA journal_mode=WAL;"
    @"PRAGMA synchronous=FULL;"
    @"PRAGMA secure_delete=ON;"
    @"CREATE TABLE IF NOT EXISTS schema_migrations("
        "version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);"
    @"CREATE TABLE IF NOT EXISTS sources("
        "id INTEGER PRIMARY KEY, kind TEXT NOT NULL, external_id TEXT NOT NULL,"
        "thread_source TEXT NOT NULL, source_app TEXT NOT NULL, cli_version TEXT NOT NULL,"
        "source_timestamp TEXT NOT NULL, working_directory_encrypted BLOB,"
        "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(kind,external_id));"
    @"CREATE TABLE IF NOT EXISTS source_cursors("
        "source_id INTEGER PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,"
        "device_id INTEGER NOT NULL DEFAULT 0, inode INTEGER NOT NULL DEFAULT 0,"
        "safe_offset INTEGER NOT NULL DEFAULT 0, safe_line_number INTEGER NOT NULL DEFAULT 0,"
        "file_size INTEGER NOT NULL DEFAULT 0,"
        "parser_version INTEGER NOT NULL DEFAULT 1,"
        "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);"
    @"CREATE TABLE IF NOT EXISTS conversations("
        "id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,"
        "external_id TEXT NOT NULL, source_timestamp TEXT NOT NULL,"
        "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(source_id,external_id));"
    @"CREATE TABLE IF NOT EXISTS messages("
        "id INTEGER PRIMARY KEY,"
        "conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,"
        "external_id TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('user','assistant')),"
        "source_timestamp TEXT NOT NULL, body_encrypted BLOB NOT NULL,"
        "body_character_count INTEGER NOT NULL, redaction_counts_json TEXT NOT NULL,"
        "source_line_number INTEGER NOT NULL, source_byte_offset INTEGER NOT NULL,"
        "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(conversation_id,external_id));"
    @"CREATE TABLE IF NOT EXISTS import_runs("
        "id INTEGER PRIMARY KEY, source_kind TEXT NOT NULL,"
        "started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "finished_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, status TEXT NOT NULL,"
        "inserted_message_count INTEGER NOT NULL, existing_message_count INTEGER NOT NULL);"
    @"CREATE TABLE IF NOT EXISTS source_tombstones("
        "id INTEGER PRIMARY KEY, kind TEXT NOT NULL, external_id TEXT NOT NULL,"
        "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(kind,external_id));"
    @"CREATE TABLE IF NOT EXISTS expressions("
        "id INTEGER PRIMARY KEY, digest BLOB NOT NULL UNIQUE,"
        "body_encrypted BLOB NOT NULL,"
        "occurrence_count INTEGER NOT NULL CHECK(occurrence_count>0),"
        "conversation_count INTEGER NOT NULL CHECK(conversation_count>0),"
        "last_source_timestamp TEXT NOT NULL, extractor_version INTEGER NOT NULL,"
        "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);"
    @"CREATE TABLE IF NOT EXISTS expression_occurrences("
        "expression_id INTEGER NOT NULL REFERENCES expressions(id) ON DELETE CASCADE,"
        "message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,"
        "PRIMARY KEY(expression_id,message_id));"
    @"CREATE TABLE IF NOT EXISTS expression_tombstones("
        "digest BLOB PRIMARY KEY, body_encrypted BLOB NOT NULL,"
        "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);"
    @"CREATE TABLE IF NOT EXISTS expression_builds("
        "id INTEGER PRIMARY KEY, extractor_version INTEGER NOT NULL,"
        "status TEXT NOT NULL, source_message_count INTEGER NOT NULL,"
        "active_expression_count INTEGER NOT NULL,"
        "skipped_tombstone_count INTEGER NOT NULL,"
        "started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "finished_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);"
    @"INSERT OR IGNORE INTO schema_migrations(version) VALUES(1);";

static void CPASetStoreError(NSError **error, sqlite3 *database, NSString *fallback) {
    if (error == NULL) {
        return;
    }
    NSString *description = fallback;
    if (database != NULL) {
        const char *message = sqlite3_errmsg(database);
        if (message != NULL) {
            description = [NSString stringWithUTF8String:message];
        }
    }
    *error = [NSError errorWithDomain:CPALocalDataStoreErrorDomain
        code:1
        userInfo:@{NSLocalizedDescriptionKey: description}];
}

@interface CPALocalImportResult ()
@property(nonatomic, readwrite) NSUInteger insertedMessageCount;
@property(nonatomic, readwrite) NSUInteger existingMessageCount;
@property(nonatomic, readwrite) BOOL skippedTombstonedSource;
@end
@implementation CPALocalImportResult
@end

@interface CPALocalDataCounts ()
@property(nonatomic, readwrite) NSUInteger sourceCount;
@property(nonatomic, readwrite) NSUInteger conversationCount;
@property(nonatomic, readwrite) NSUInteger messageCount;
@property(nonatomic, readwrite) NSUInteger importRunCount;
@property(nonatomic, readwrite) NSUInteger tombstoneCount;
@end
@implementation CPALocalDataCounts
@end

@interface CPALocalSourceCursor ()
@property(nonatomic, copy, readwrite) NSString *threadID;
@property(nonatomic, readwrite) uint64_t deviceID;
@property(nonatomic, readwrite) uint64_t inode;
@property(nonatomic, readwrite) uint64_t safeOffset;
@property(nonatomic, readwrite) NSUInteger safeLineNumber;
@property(nonatomic, readwrite) uint64_t fileSize;
@property(nonatomic, readwrite) NSUInteger parserVersion;
@end

@implementation CPALocalSourceCursor

- (instancetype)initWithThreadID:(NSString *)threadID
    deviceID:(uint64_t)deviceID
    inode:(uint64_t)inode
    safeOffset:(uint64_t)safeOffset
    safeLineNumber:(NSUInteger)safeLineNumber
    fileSize:(uint64_t)fileSize
    parserVersion:(NSUInteger)parserVersion {
    self = [super init];
    if (self != nil) {
        _threadID = [threadID copy];
        _deviceID = deviceID;
        _inode = inode;
        _safeOffset = safeOffset;
        _safeLineNumber = safeLineNumber;
        _fileSize = fileSize;
        _parserVersion = parserVersion;
    }
    return self;
}

@end

@interface CPALocalDataStore ()
@property(nonatomic) sqlite3 *database;
@property(nonatomic, strong) NSMutableData *masterKey;
@property(nonatomic, strong) CPAMessageCrypto *crypto;
@property(nonatomic, strong) CPASensitiveTextRedactor *redactor;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL importSessionActive;
- (BOOL)upsertMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    sourceKind:(NSString *)sourceKind
    cursor:(nullable CPALocalSourceCursor *)cursor
    result:(CPALocalImportResult *)result
    error:(NSError **)error;
- (BOOL)insertImportRunForSourceKind:(NSString *)sourceKind
    result:(CPALocalImportResult *)result
    error:(NSError **)error;
- (BOOL)executeSQL:(NSString *)sql error:(NSError **)error;
- (void)finishImportSession;
@end

@interface CPALocalImportSession ()
@property(nonatomic, strong) CPALocalDataStore *store;
@property(nonatomic, copy) NSString *sourceKind;
@property(nonatomic, strong) CPALocalImportResult *result;
@property(nonatomic) BOOL active;
- (instancetype)initWithStore:(CPALocalDataStore *)store
    sourceKind:(NSString *)sourceKind;
@end

@implementation CPALocalImportSession

- (instancetype)initWithStore:(CPALocalDataStore *)store
    sourceKind:(NSString *)sourceKind {
    self = [super init];
    if (self != nil) {
        _store = store;
        _sourceKind = [sourceKind copy];
        _result = [[CPALocalImportResult alloc] init];
        _active = YES;
    }
    return self;
}

- (void)dealloc {
    [self rollback];
}

- (BOOL)importMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (!self.active) {
        CPASetStoreError(error, NULL, @"Local import session is no longer active");
        return NO;
    }
    CPALocalImportResult *partial = [[CPALocalImportResult alloc] init];
    if (![self.store upsertMetadata:metadata messages:messages
            sourceKind:self.sourceKind cursor:nil result:partial error:error]) {
        [self rollback];
        return NO;
    }
    self.result.insertedMessageCount += partial.insertedMessageCount;
    self.result.existingMessageCount += partial.existingMessageCount;
    self.result.skippedTombstonedSource = self.result.skippedTombstonedSource
        || partial.skippedTombstonedSource;
    return YES;
}

- (CPALocalImportResult *)commit:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (!self.active) {
        CPASetStoreError(error, NULL, @"Local import session is no longer active");
        return nil;
    }
    BOOL succeeded = [self.store insertImportRunForSourceKind:self.sourceKind
        result:self.result error:error]
        && [self.store executeSQL:@"COMMIT" error:error];
    if (!succeeded) {
        [self rollback];
        return nil;
    }
    self.active = NO;
    [self.store finishImportSession];
    CPALocalImportResult *committedResult = self.result;
    self.store = nil;
    return committedResult;
}

- (void)rollback {
    if (!self.active) {
        return;
    }
    (void)[self.store executeSQL:@"ROLLBACK" error:NULL];
    self.active = NO;
    [self.store finishImportSession];
    self.store = nil;
}

@end

@implementation CPALocalDataStore

- (instancetype)initWithDatabaseURL:(NSURL *)databaseURL
    masterKey:(NSData *)masterKey
    error:(NSError **)error {
    if (masterKey.length != 64) {
        CPASetStoreError(error, NULL, @"Database encryption key has invalid length");
        return nil;
    }
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _masterKey = [masterKey mutableCopy];
    _crypto = [[CPAMessageCrypto alloc] init];
    _redactor = [[CPASensitiveTextRedactor alloc] init];

    int status = sqlite3_open_v2(databaseURL.fileSystemRepresentation,
        &_database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        NULL);
    if (status != SQLITE_OK) {
        CPASetStoreError(error, _database, @"Unable to open local database");
        if (_database != NULL) {
            sqlite3_close_v2(_database);
            _database = NULL;
        }
        return nil;
    }
    if (chmod(databaseURL.fileSystemRepresentation, S_IRUSR | S_IWUSR) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                code:errno
                userInfo:@{NSLocalizedDescriptionKey: @"Unable to restrict database permissions"}];
        }
        sqlite3_close_v2(_database);
        _database = NULL;
        return nil;
    }
    if (![self executeSQL:CPASchemaSQL error:error]) {
        sqlite3_close_v2(_database);
        _database = NULL;
        return nil;
    }
    if (![self migrateCursorSchema:error]
        || ![self executeSQL:@"INSERT OR IGNORE INTO schema_migrations(version) VALUES(2)"
            error:error]
        || ![self executeSQL:@"INSERT OR IGNORE INTO schema_migrations(version) VALUES(3)"
            error:error]
        || ![self executeSQL:@"INSERT OR IGNORE INTO schema_migrations(version) VALUES(4)"
            error:error]) {
        sqlite3_close_v2(_database);
        _database = NULL;
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_database != NULL) {
        sqlite3_close_v2(_database);
    }
    [self clearMasterKey];
}

- (CPALocalImportResult *)importCodexMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    error:(NSError **)error {
    return [self importCodexMetadata:metadata messages:messages advancingCursor:nil error:error];
}

- (CPALocalImportResult *)importCodexMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    advancingCursor:(CPALocalSourceCursor *)cursor
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error] || !metadata.isRootUserThread) {
        if (metadata != nil && !metadata.isRootUserThread) {
            CPASetStoreError(error, self.database, @"Only root user threads may be imported");
        }
        return nil;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL, @"Another local import transaction is active");
        return nil;
    }
    if (cursor != nil && ![cursor.threadID isEqualToString:metadata.threadID]) {
        CPASetStoreError(error, NULL, @"Cursor thread does not match imported metadata");
        return nil;
    }
    if (![self executeSQL:@"BEGIN IMMEDIATE" error:error]) {
        return nil;
    }

    CPALocalImportResult *result = [[CPALocalImportResult alloc] init];
    BOOL succeeded = [self upsertMetadata:metadata messages:messages
        sourceKind:@"codex" cursor:cursor result:result error:error]
        && [self insertImportRunForSourceKind:@"codex" result:result error:error]
        && [self executeSQL:@"COMMIT" error:error];
    if (!succeeded) {
        (void)[self executeSQL:@"ROLLBACK" error:NULL];
        return nil;
    }
    return result;
}

- (CPALocalImportSession *)beginImportSessionForSourceKind:(NSString *)sourceKind
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return nil;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL, @"Another local import transaction is active");
        return nil;
    }
    if (![sourceKind isEqualToString:@"chatgpt"]) {
        CPASetStoreError(error, NULL, @"Unsupported streaming import source kind");
        return nil;
    }
    if (![self executeSQL:@"BEGIN IMMEDIATE" error:error]) {
        return nil;
    }
    self.importSessionActive = YES;
    return [[CPALocalImportSession alloc] initWithStore:self sourceKind:sourceKind];
}

- (void)finishImportSession {
    self.importSessionActive = NO;
}

- (BOOL)upsertMetadata:(CPACodexSourceMetadata *)metadata
    messages:(NSArray<CPACodexMessage *> *)messages
    sourceKind:(NSString *)sourceKind
    cursor:(CPALocalSourceCursor *)cursor
    result:(CPALocalImportResult *)result
    error:(NSError **)error {
    if (!metadata.isRootUserThread) {
        CPASetStoreError(error, NULL, @"Only visible user conversations may be imported");
        return NO;
    }
    BOOL tombstoned = [self isSourceTombstonedForKind:sourceKind
        externalID:metadata.threadID error:error];
    if (error != NULL && *error != nil) {
        return NO;
    }
    if (tombstoned) {
        result.skippedTombstonedSource = YES;
        return YES;
    }
    NSData *workingDirectoryData = [metadata.workingDirectory
        dataUsingEncoding:NSUTF8StringEncoding];
    NSData *encryptedWorkingDirectory = nil;
    if (workingDirectoryData.length > 0) {
        encryptedWorkingDirectory = [self.crypto encryptData:workingDirectoryData
            masterKey:self.masterKey error:error];
        if (encryptedWorkingDirectory == nil) {
            return NO;
        }
    }

    sqlite3_stmt *sourceStatement = NULL;
    NSString *sourceSQL = @"INSERT INTO sources("
        "kind,external_id,thread_source,source_app,cli_version,source_timestamp,"
        "working_directory_encrypted) VALUES(?,?,?,?,?,?,?) "
        "ON CONFLICT(kind,external_id) DO UPDATE SET "
        "thread_source=excluded.thread_source,source_app=excluded.source_app,"
        "cli_version=excluded.cli_version,source_timestamp=excluded.source_timestamp,"
        "working_directory_encrypted=COALESCE(sources.working_directory_encrypted,"
        "excluded.working_directory_encrypted),updated_at=CURRENT_TIMESTAMP";
    if (![self prepareSQL:sourceSQL statement:&sourceStatement error:error]) {
        return NO;
    }
    [self bindText:sourceKind atIndex:1 statement:sourceStatement];
    [self bindText:metadata.threadID atIndex:2 statement:sourceStatement];
    [self bindText:metadata.threadSource atIndex:3 statement:sourceStatement];
    [self bindText:metadata.source atIndex:4 statement:sourceStatement];
    [self bindText:metadata.cliVersion atIndex:5 statement:sourceStatement];
    [self bindText:metadata.timestamp atIndex:6 statement:sourceStatement];
    [self bindData:encryptedWorkingDirectory atIndex:7 statement:sourceStatement];
    BOOL sourceInserted = [self stepDone:sourceStatement error:error];
    sqlite3_finalize(sourceStatement);
    if (!sourceInserted) {
        return NO;
    }

    sqlite3_int64 sourceID = [self integerIDForSQL:
        @"SELECT id FROM sources WHERE kind=? AND external_id=?"
        first:sourceKind second:metadata.threadID error:error];
    if (sourceID <= 0) {
        return NO;
    }
    sqlite3_stmt *conversationStatement = NULL;
    if (![self prepareSQL:@"INSERT OR IGNORE INTO conversations("
            "source_id,external_id,source_timestamp) VALUES(?,?,?)"
            statement:&conversationStatement error:error]) {
        return NO;
    }
    sqlite3_bind_int64(conversationStatement, 1, sourceID);
    [self bindText:metadata.threadID atIndex:2 statement:conversationStatement];
    [self bindText:metadata.timestamp atIndex:3 statement:conversationStatement];
    BOOL conversationInserted = [self stepDone:conversationStatement error:error];
    sqlite3_finalize(conversationStatement);
    if (!conversationInserted) {
        return NO;
    }
    sqlite3_int64 conversationID = [self integerIDForSQL:
        @"SELECT id FROM conversations WHERE source_id=? AND external_id=?"
        integer:sourceID text:metadata.threadID error:error];
    if (conversationID <= 0) {
        return NO;
    }

    for (NSUInteger i = 0, len = messages.count; i < len; i++) {
        CPACodexMessage *message = messages[i];
        if (message.role != CPACodexMessageRoleUser
            && message.role != CPACodexMessageRoleAssistant) {
            CPASetStoreError(error, NULL, @"Message role is invalid");
            return NO;
        }
        if ([self messageExists:message.messageID
                conversationID:conversationID error:error]) {
            result.existingMessageCount++;
            continue;
        }
        if (error != NULL && *error != nil) {
            return NO;
        }

        NSData *plaintext = [message.text dataUsingEncoding:NSUTF8StringEncoding];
        NSData *encrypted = [self.crypto encryptData:plaintext
            masterKey:self.masterKey error:error];
        if (encrypted == nil) {
            return NO;
        }
        CPARedactionResult *redaction = [self.redactor redactText:message.text];
        NSData *countsData = [NSJSONSerialization dataWithJSONObject:redaction.typeCounts
            options:NSJSONWritingSortedKeys error:error];
        if (countsData == nil) {
            return NO;
        }
        NSString *countsJSON = [[NSString alloc] initWithData:countsData
            encoding:NSUTF8StringEncoding];

        sqlite3_stmt *messageStatement = NULL;
        if (![self prepareSQL:@"INSERT INTO messages("
                "conversation_id,external_id,role,source_timestamp,body_encrypted,"
                "body_character_count,redaction_counts_json,source_line_number,"
                "source_byte_offset) VALUES(?,?,?,?,?,?,?,?,?)"
                statement:&messageStatement error:error]) {
            return NO;
        }
        sqlite3_bind_int64(messageStatement, 1, conversationID);
        [self bindText:message.messageID atIndex:2 statement:messageStatement];
        [self bindText:message.role == CPACodexMessageRoleUser ? @"user" : @"assistant"
            atIndex:3 statement:messageStatement];
        [self bindText:message.timestamp atIndex:4 statement:messageStatement];
        [self bindData:encrypted atIndex:5 statement:messageStatement];
        sqlite3_bind_int64(messageStatement, 6, (sqlite3_int64)message.text.length);
        [self bindText:countsJSON atIndex:7 statement:messageStatement];
        sqlite3_bind_int64(messageStatement, 8,
            (sqlite3_int64)message.sourceLineNumber);
        sqlite3_bind_int64(messageStatement, 9,
            (sqlite3_int64)message.sourceByteOffset);
        BOOL inserted = [self stepDone:messageStatement error:error];
        sqlite3_finalize(messageStatement);
        if (!inserted) {
            return NO;
        }
        result.insertedMessageCount++;
    }

    if (cursor != nil) {
        sqlite3_stmt *cursorStatement = NULL;
        NSString *cursorSQL = @"INSERT INTO source_cursors("
            "source_id,device_id,inode,safe_offset,safe_line_number,file_size,parser_version) "
            "VALUES(?,?,?,?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET "
            "device_id=excluded.device_id,inode=excluded.inode,"
            "safe_offset=excluded.safe_offset,safe_line_number=excluded.safe_line_number,"
            "file_size=excluded.file_size,parser_version=excluded.parser_version,"
            "updated_at=CURRENT_TIMESTAMP";
        if (![self prepareSQL:cursorSQL statement:&cursorStatement error:error]) {
            return NO;
        }
        sqlite3_bind_int64(cursorStatement, 1, sourceID);
        sqlite3_bind_int64(cursorStatement, 2, (sqlite3_int64)cursor.deviceID);
        sqlite3_bind_int64(cursorStatement, 3, (sqlite3_int64)cursor.inode);
        sqlite3_bind_int64(cursorStatement, 4, (sqlite3_int64)cursor.safeOffset);
        sqlite3_bind_int64(cursorStatement, 5, (sqlite3_int64)cursor.safeLineNumber);
        sqlite3_bind_int64(cursorStatement, 6, (sqlite3_int64)cursor.fileSize);
        sqlite3_bind_int64(cursorStatement, 7, (sqlite3_int64)cursor.parserVersion);
        BOOL cursorUpdated = [self stepDone:cursorStatement error:error];
        sqlite3_finalize(cursorStatement);
        if (!cursorUpdated) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)insertImportRunForSourceKind:(NSString *)sourceKind
    result:(CPALocalImportResult *)result
    error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (![self prepareSQL:@"INSERT INTO import_runs("
            "source_kind,status,inserted_message_count,existing_message_count) "
            "VALUES(?,'success',?,?)" statement:&statement error:error]) {
        return NO;
    }
    [self bindText:sourceKind atIndex:1 statement:statement];
    sqlite3_bind_int64(statement, 2, (sqlite3_int64)result.insertedMessageCount);
    sqlite3_bind_int64(statement, 3, (sqlite3_int64)result.existingMessageCount);
    BOOL inserted = [self stepDone:statement error:error];
    sqlite3_finalize(statement);
    return inserted;
}

- (CPALocalSourceCursor *)codexCursorForThreadID:(NSString *)threadID
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    NSString *sql = @"SELECT c.device_id,c.inode,c.safe_offset,c.safe_line_number,"
        "c.file_size,c.parser_version FROM source_cursors c "
        "JOIN sources s ON s.id=c.source_id WHERE s.kind='codex' AND s.external_id=?";
    if (![self prepareSQL:sql statement:&statement error:error]) {
        return nil;
    }
    [self bindText:threadID atIndex:1 statement:statement];
    CPALocalSourceCursor *cursor = nil;
    int status = sqlite3_step(statement);
    if (status == SQLITE_ROW) {
        cursor = [[CPALocalSourceCursor alloc] initWithThreadID:threadID
            deviceID:(uint64_t)sqlite3_column_int64(statement, 0)
            inode:(uint64_t)sqlite3_column_int64(statement, 1)
            safeOffset:(uint64_t)sqlite3_column_int64(statement, 2)
            safeLineNumber:(NSUInteger)sqlite3_column_int64(statement, 3)
            fileSize:(uint64_t)sqlite3_column_int64(statement, 4)
            parserVersion:(NSUInteger)sqlite3_column_int64(statement, 5)];
    } else if (status != SQLITE_DONE) {
        CPASetStoreError(error, self.database, @"Unable to read source cursor");
    }
    sqlite3_finalize(statement);
    return cursor;
}

- (BOOL)isSourceTombstonedForKind:(NSString *)sourceKind
    externalID:(NSString *)externalID
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return NO;
    }
    sqlite3_stmt *statement = NULL;
    if (![self prepareSQL:@"SELECT 1 FROM source_tombstones WHERE kind=? AND external_id=?"
            statement:&statement error:error]) {
        return NO;
    }
    [self bindText:sourceKind atIndex:1 statement:statement];
    [self bindText:externalID atIndex:2 statement:statement];
    int status = sqlite3_step(statement);
    BOOL found = status == SQLITE_ROW;
    if (status != SQLITE_ROW && status != SQLITE_DONE) {
        CPASetStoreError(error, self.database, @"Unable to read source tombstone");
    }
    sqlite3_finalize(statement);
    return found;
}

- (BOOL)deleteSourceKind:(NSString *)sourceKind
    externalID:(NSString *)externalID
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return NO;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL, @"Cannot delete a source during an import session");
        return NO;
    }
    if (sourceKind.length == 0 || externalID.length == 0) {
        CPASetStoreError(error, NULL, @"Source deletion identity is invalid");
        return NO;
    }
    if (![self executeSQL:@"BEGIN IMMEDIATE" error:error]) {
        return NO;
    }
    sqlite3_stmt *tombstoneStatement = NULL;
    BOOL succeeded = [self prepareSQL:@"INSERT OR IGNORE INTO source_tombstones("
        "kind,external_id) VALUES(?,?)" statement:&tombstoneStatement error:error];
    if (succeeded) {
        [self bindText:sourceKind atIndex:1 statement:tombstoneStatement];
        [self bindText:externalID atIndex:2 statement:tombstoneStatement];
        succeeded = [self stepDone:tombstoneStatement error:error];
    }
    sqlite3_finalize(tombstoneStatement);
    sqlite3_stmt *deleteStatement = NULL;
    if (succeeded) {
        succeeded = [self prepareSQL:@"DELETE FROM sources WHERE kind=? AND external_id=?"
            statement:&deleteStatement error:error];
    }
    if (succeeded) {
        [self bindText:sourceKind atIndex:1 statement:deleteStatement];
        [self bindText:externalID atIndex:2 statement:deleteStatement];
        succeeded = [self stepDone:deleteStatement error:error];
    }
    sqlite3_finalize(deleteStatement);
    if (succeeded) {
        succeeded = [self executeSQL:@"COMMIT" error:error];
    }
    if (!succeeded) {
        (void)[self executeSQL:@"ROLLBACK" error:NULL];
    }
    return succeeded;
}

- (CPALocalDataCounts *)currentCounts:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return nil;
    }
    CPALocalDataCounts *counts = [[CPALocalDataCounts alloc] init];
    counts.sourceCount = [self countForSQL:@"SELECT COUNT(*) FROM sources" error:error];
    if (error != NULL && *error != nil) return nil;
    counts.conversationCount = [self countForSQL:@"SELECT COUNT(*) FROM conversations" error:error];
    if (error != NULL && *error != nil) return nil;
    counts.messageCount = [self countForSQL:@"SELECT COUNT(*) FROM messages" error:error];
    if (error != NULL && *error != nil) return nil;
    counts.importRunCount = [self countForSQL:@"SELECT COUNT(*) FROM import_runs" error:error];
    if (error != NULL && *error != nil) return nil;
    counts.tombstoneCount = [self countForSQL:@"SELECT COUNT(*) FROM source_tombstones"
        error:error];
    if (error != NULL && *error != nil) return nil;
    return counts;
}

- (BOOL)enumerateDecryptedUserMessages:(CPALocalUserMessageHandler)handler
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return NO;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL,
            @"Cannot enumerate user messages during an active import session");
        return NO;
    }
    if (handler == nil) {
        CPASetStoreError(error, NULL, @"User message handler is unavailable");
        return NO;
    }

    sqlite3_stmt *statement = NULL;
    NSString *sql = @"SELECT id,conversation_id,source_timestamp,body_encrypted,"
        "redaction_counts_json FROM messages WHERE role='user' ORDER BY id";
    if (![self prepareSQL:sql statement:&statement error:error]) {
        return NO;
    }

    BOOL succeeded = YES;
    BOOL stopped = NO;
    int status = SQLITE_ROW;
    while ((status = sqlite3_step(statement)) == SQLITE_ROW) {
        NSError *rowError = nil;
        @autoreleasepool {
            int64_t messageRowID = sqlite3_column_int64(statement, 0);
            int64_t conversationRowID = sqlite3_column_int64(statement, 1);
            const unsigned char *timestampBytes = sqlite3_column_text(statement, 2);
            const void *envelopeBytes = sqlite3_column_blob(statement, 3);
            int envelopeLength = sqlite3_column_bytes(statement, 3);
            const unsigned char *redactionBytes = sqlite3_column_text(statement, 4);
            if (messageRowID <= 0 || conversationRowID <= 0 || timestampBytes == NULL
                || envelopeBytes == NULL || envelopeLength <= 0 || redactionBytes == NULL) {
                CPASetStoreError(&rowError, NULL, @"Stored user message is incomplete");
                succeeded = NO;
            } else {
                NSString *timestamp = [NSString stringWithUTF8String:
                    (const char *)timestampBytes];
                NSString *redactionJSON = [NSString stringWithUTF8String:
                    (const char *)redactionBytes];
                NSData *redactionData = [redactionJSON dataUsingEncoding:
                    NSUTF8StringEncoding];
                NSError *jsonError = nil;
                id redactionObject = redactionData == nil ? nil :
                    [NSJSONSerialization JSONObjectWithData:redactionData
                        options:0 error:&jsonError];
                if (timestamp == nil || ![redactionObject isKindOfClass:NSDictionary.class]
                    || jsonError != nil) {
                    CPASetStoreError(&rowError, NULL,
                        @"Stored user message metadata is invalid");
                    succeeded = NO;
                } else {
                    NSData *envelope = [NSData dataWithBytes:envelopeBytes
                        length:(NSUInteger)envelopeLength];
                    NSData *plaintext = [self.crypto decryptEnvelope:envelope
                        masterKey:self.masterKey error:&rowError];
                    NSString *text = plaintext == nil ? nil : [[NSString alloc]
                        initWithData:plaintext encoding:NSUTF8StringEncoding];
                    if (text == nil) {
                        if (rowError == nil) {
                            CPASetStoreError(&rowError, NULL,
                                @"Decrypted user message is not valid UTF-8");
                        }
                        succeeded = NO;
                    } else {
                        CPALocalUserMessageRecord *record = [[CPALocalUserMessageRecord alloc]
                            initWithMessageRowID:messageRowID
                            conversationRowID:conversationRowID
                            sourceTimestamp:timestamp
                            text:text
                            containsSensitiveData:[(NSDictionary *)redactionObject count] > 0];
                        BOOL shouldStop = NO;
                        NSError *handlerError = nil;
                        BOOL handled = handler(record, &shouldStop, &handlerError);
                        if (!handled) {
                            rowError = handlerError ?: [NSError errorWithDomain:
                                CPALocalDataStoreErrorDomain code:1 userInfo:@{
                                    NSLocalizedDescriptionKey: @"User message handler failed",
                                }];
                            succeeded = NO;
                        } else if (shouldStop) {
                            stopped = YES;
                        }
                    }
                }
            }
        }
        if (!succeeded && error != NULL) {
            *error = rowError;
        }
        if (!succeeded || stopped) {
            break;
        }
    }
    if (succeeded && !stopped && status != SQLITE_DONE) {
        CPASetStoreError(error, self.database, @"Unable to enumerate user messages");
        succeeded = NO;
    }
    sqlite3_finalize(statement);
    return succeeded;
}

- (NSData *)expressionDigestForText:(NSString *)text {
    static const uint8_t domain[] = {
        'e', 'x', 'p', 'r', 'e', 's', 's', 'i', 'o', 'n', '-', 'v', '1', 0,
    };
    NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *input = [NSMutableData dataWithBytes:domain length:sizeof(domain)];
    [input appendData:textData];
    const uint8_t *keyBytes = self.masterKey.bytes;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, keyBytes + 32, 32,
        input.bytes, input.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

- (BOOL)validateExpressionCandidates:
    (NSArray<CPALocalExpressionCandidate *> *)expressions
    extractorVersion:(NSUInteger)extractorVersion
    error:(NSError **)error {
    if (extractorVersion == 0) {
        CPASetStoreError(error, NULL, @"Expression extractor version is invalid");
        return NO;
    }
    NSMutableSet<NSData *> *digests = [NSMutableSet set];
    for (NSUInteger i = 0, len = expressions.count; i < len; i++) {
        CPALocalExpressionCandidate *candidate = expressions[i];
        NSArray<NSNumber *> *messageIDs = candidate.occurrenceMessageRowIDs;
        NSSet<NSNumber *> *uniqueMessageIDs = [NSSet setWithArray:messageIDs];
        if (candidate.normalizedText.length == 0
            || candidate.occurrenceCount == 0
            || candidate.occurrenceCount != messageIDs.count
            || uniqueMessageIDs.count != messageIDs.count
            || candidate.conversationCount == 0
            || candidate.conversationCount > candidate.occurrenceCount
            || candidate.lastSourceTimestamp.length == 0) {
            CPASetStoreError(error, NULL, @"Expression candidate metadata is invalid");
            return NO;
        }
        for (NSUInteger messageIndex = 0, messageCount = messageIDs.count;
                messageIndex < messageCount; messageIndex++) {
            if (messageIDs[messageIndex].longLongValue <= 0) {
                CPASetStoreError(error, NULL,
                    @"Expression candidate source identity is invalid");
                return NO;
            }
        }
        NSData *digest = [self expressionDigestForText:candidate.normalizedText];
        if ([digests containsObject:digest]) {
            CPASetStoreError(error, NULL, @"Expression candidate is duplicated");
            return NO;
        }
        [digests addObject:digest];
    }
    return YES;
}

- (CPALocalExpressionBuildResult *)replaceActiveExpressions:
    (NSArray<CPALocalExpressionCandidate *> *)expressions
    extractorVersion:(NSUInteger)extractorVersion
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return nil;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL,
            @"Cannot replace expressions during an active import session");
        return nil;
    }
    if (![self validateExpressionCandidates:expressions
            extractorVersion:extractorVersion error:error]) {
        return nil;
    }
    if (![self executeSQL:@"BEGIN IMMEDIATE" error:error]) {
        return nil;
    }

    BOOL succeeded = [self executeSQL:@"DELETE FROM expressions" error:error];
    sqlite3_stmt *tombstoneStatement = NULL;
    sqlite3_stmt *expressionStatement = NULL;
    sqlite3_stmt *occurrenceStatement = NULL;
    if (succeeded) {
        succeeded = [self prepareSQL:
            @"SELECT 1 FROM expression_tombstones WHERE digest=?"
            statement:&tombstoneStatement error:error];
    }
    if (succeeded) {
        succeeded = [self prepareSQL:@"INSERT INTO expressions("
            "digest,body_encrypted,occurrence_count,conversation_count,"
            "last_source_timestamp,extractor_version) VALUES(?,?,?,?,?,?)"
            statement:&expressionStatement error:error];
    }
    if (succeeded) {
        succeeded = [self prepareSQL:@"INSERT INTO expression_occurrences("
            "expression_id,message_id) VALUES(?,?)"
            statement:&occurrenceStatement error:error];
    }

    NSUInteger activeCount = 0;
    NSUInteger skippedCount = 0;
    NSMutableSet<NSNumber *> *sourceMessageIDs = [NSMutableSet set];
    for (NSUInteger i = 0, len = expressions.count; succeeded && i < len; i++) {
        CPALocalExpressionCandidate *candidate = expressions[i];
        NSData *digest = [self expressionDigestForText:candidate.normalizedText];
        sqlite3_reset(tombstoneStatement);
        sqlite3_clear_bindings(tombstoneStatement);
        [self bindData:digest atIndex:1 statement:tombstoneStatement];
        int tombstoneStatus = sqlite3_step(tombstoneStatement);
        if (tombstoneStatus == SQLITE_ROW) {
            skippedCount++;
            continue;
        }
        if (tombstoneStatus != SQLITE_DONE) {
            CPASetStoreError(error, self.database,
                @"Unable to read expression deletion decision");
            succeeded = NO;
            break;
        }

        NSData *plaintext = [candidate.normalizedText
            dataUsingEncoding:NSUTF8StringEncoding];
        NSData *encrypted = [self.crypto encryptData:plaintext
            masterKey:self.masterKey error:error];
        if (encrypted == nil) {
            succeeded = NO;
            break;
        }
        sqlite3_reset(expressionStatement);
        sqlite3_clear_bindings(expressionStatement);
        [self bindData:digest atIndex:1 statement:expressionStatement];
        [self bindData:encrypted atIndex:2 statement:expressionStatement];
        sqlite3_bind_int64(expressionStatement, 3,
            (sqlite3_int64)candidate.occurrenceCount);
        sqlite3_bind_int64(expressionStatement, 4,
            (sqlite3_int64)candidate.conversationCount);
        [self bindText:candidate.lastSourceTimestamp
            atIndex:5 statement:expressionStatement];
        sqlite3_bind_int64(expressionStatement, 6, (sqlite3_int64)extractorVersion);
        if (![self stepDone:expressionStatement error:error]) {
            succeeded = NO;
            break;
        }
        sqlite3_int64 expressionID = sqlite3_last_insert_rowid(self.database);
        NSArray<NSNumber *> *messageIDs = candidate.occurrenceMessageRowIDs;
        for (NSUInteger messageIndex = 0, messageCount = messageIDs.count;
                succeeded && messageIndex < messageCount; messageIndex++) {
            NSNumber *messageID = messageIDs[messageIndex];
            sqlite3_reset(occurrenceStatement);
            sqlite3_clear_bindings(occurrenceStatement);
            sqlite3_bind_int64(occurrenceStatement, 1, expressionID);
            sqlite3_bind_int64(occurrenceStatement, 2, messageID.longLongValue);
            succeeded = [self stepDone:occurrenceStatement error:error];
            if (succeeded) {
                [sourceMessageIDs addObject:messageID];
            }
        }
        if (succeeded) {
            activeCount++;
        }
    }
    sqlite3_finalize(tombstoneStatement);
    sqlite3_finalize(expressionStatement);
    sqlite3_finalize(occurrenceStatement);

    sqlite3_stmt *buildStatement = NULL;
    if (succeeded) {
        succeeded = [self prepareSQL:@"INSERT INTO expression_builds("
            "extractor_version,status,source_message_count,active_expression_count,"
            "skipped_tombstone_count) VALUES(?,'success',?,?,?)"
            statement:&buildStatement error:error];
    }
    if (succeeded) {
        sqlite3_bind_int64(buildStatement, 1, (sqlite3_int64)extractorVersion);
        sqlite3_bind_int64(buildStatement, 2,
            (sqlite3_int64)sourceMessageIDs.count);
        sqlite3_bind_int64(buildStatement, 3, (sqlite3_int64)activeCount);
        sqlite3_bind_int64(buildStatement, 4, (sqlite3_int64)skippedCount);
        succeeded = [self stepDone:buildStatement error:error];
    }
    sqlite3_finalize(buildStatement);
    if (succeeded) {
        succeeded = [self executeSQL:@"COMMIT" error:error];
    }
    if (!succeeded) {
        (void)[self executeSQL:@"ROLLBACK" error:NULL];
        return nil;
    }
    return [[CPALocalExpressionBuildResult alloc]
        initWithActiveExpressionCount:activeCount
        skippedTombstoneCount:skippedCount];
}

- (NSArray<CPALocalExpressionRecord *> *)loadActiveExpressions:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return nil;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL,
            @"Cannot load expressions during an active import session");
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    NSString *sql = @"SELECT body_encrypted,occurrence_count,conversation_count,"
        "last_source_timestamp,extractor_version FROM expressions "
        "ORDER BY conversation_count DESC,occurrence_count DESC,"
        "last_source_timestamp DESC,id ASC";
    if (![self prepareSQL:sql statement:&statement error:error]) {
        return nil;
    }
    NSMutableArray<CPALocalExpressionRecord *> *records = [NSMutableArray array];
    BOOL succeeded = YES;
    int status = SQLITE_ROW;
    while ((status = sqlite3_step(statement)) == SQLITE_ROW) {
        NSError *rowError = nil;
        @autoreleasepool {
            const void *envelopeBytes = sqlite3_column_blob(statement, 0);
            int envelopeLength = sqlite3_column_bytes(statement, 0);
            sqlite3_int64 occurrenceCount = sqlite3_column_int64(statement, 1);
            sqlite3_int64 conversationCount = sqlite3_column_int64(statement, 2);
            const unsigned char *timestampBytes = sqlite3_column_text(statement, 3);
            sqlite3_int64 extractorVersion = sqlite3_column_int64(statement, 4);
            if (envelopeBytes == NULL || envelopeLength <= 0 || occurrenceCount <= 0
                || conversationCount <= 0 || timestampBytes == NULL
                || extractorVersion <= 0) {
                CPASetStoreError(&rowError, NULL,
                    @"Stored expression metadata is invalid");
                succeeded = NO;
            } else {
                NSData *envelope = [NSData dataWithBytes:envelopeBytes
                    length:(NSUInteger)envelopeLength];
                NSData *plaintext = [self.crypto decryptEnvelope:envelope
                    masterKey:self.masterKey error:&rowError];
                NSString *text = plaintext == nil ? nil : [[NSString alloc]
                    initWithData:plaintext encoding:NSUTF8StringEncoding];
                NSString *timestamp = [NSString stringWithUTF8String:
                    (const char *)timestampBytes];
                if (text == nil || timestamp == nil) {
                    if (rowError == nil) {
                        CPASetStoreError(&rowError, NULL,
                            @"Stored expression is not valid UTF-8");
                    }
                    succeeded = NO;
                } else {
                    CPALocalExpressionRecord *record = [[CPALocalExpressionRecord alloc]
                        initWithNormalizedText:text
                        occurrenceCount:(NSUInteger)occurrenceCount
                        conversationCount:(NSUInteger)conversationCount
                        lastSourceTimestamp:timestamp
                        extractorVersion:(NSUInteger)extractorVersion];
                    [records addObject:record];
                }
            }
        }
        if (!succeeded && error != NULL) {
            *error = rowError;
        }
        if (!succeeded) {
            break;
        }
    }
    if (succeeded && status != SQLITE_DONE) {
        CPASetStoreError(error, self.database, @"Unable to load expressions");
        succeeded = NO;
    }
    sqlite3_finalize(statement);
    return succeeded ? [records copy] : nil;
}

- (BOOL)deleteExpressionText:(NSString *)normalizedText error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return NO;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL,
            @"Cannot delete an expression during an active import session");
        return NO;
    }
    if (normalizedText.length == 0) {
        CPASetStoreError(error, NULL, @"Expression deletion text is invalid");
        return NO;
    }
    NSData *digest = [self expressionDigestForText:normalizedText];
    NSData *plaintext = [normalizedText dataUsingEncoding:NSUTF8StringEncoding];
    NSData *encrypted = [self.crypto encryptData:plaintext
        masterKey:self.masterKey error:error];
    if (encrypted == nil) {
        return NO;
    }
    if (![self executeSQL:@"BEGIN IMMEDIATE" error:error]) {
        return NO;
    }

    sqlite3_stmt *tombstoneStatement = NULL;
    BOOL succeeded = [self prepareSQL:@"INSERT OR IGNORE INTO "
        "expression_tombstones(digest,body_encrypted) VALUES(?,?)"
        statement:&tombstoneStatement error:error];
    if (succeeded) {
        [self bindData:digest atIndex:1 statement:tombstoneStatement];
        [self bindData:encrypted atIndex:2 statement:tombstoneStatement];
        succeeded = [self stepDone:tombstoneStatement error:error];
    }
    sqlite3_finalize(tombstoneStatement);

    sqlite3_stmt *deleteStatement = NULL;
    if (succeeded) {
        succeeded = [self prepareSQL:@"DELETE FROM expressions WHERE digest=?"
            statement:&deleteStatement error:error];
    }
    if (succeeded) {
        [self bindData:digest atIndex:1 statement:deleteStatement];
        succeeded = [self stepDone:deleteStatement error:error];
    }
    sqlite3_finalize(deleteStatement);
    if (succeeded) {
        succeeded = [self executeSQL:@"COMMIT" error:error];
    }
    if (!succeeded) {
        (void)[self executeSQL:@"ROLLBACK" error:NULL];
    }
    return succeeded;
}

- (NSString *)decryptedMessageTextForThreadID:(NSString *)threadID
    messageID:(NSString *)messageID
    error:(NSError **)error {
    return [self decryptedMessageTextForSourceKind:@"codex"
        conversationID:threadID messageID:messageID error:error];
}

- (NSString *)decryptedMessageTextForSourceKind:(NSString *)sourceKind
    conversationID:(NSString *)conversationID
    messageID:(NSString *)messageID
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self ensureOpen:error]) {
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    NSString *sql = @"SELECT m.body_encrypted FROM messages m "
        "JOIN conversations c ON c.id=m.conversation_id "
        "JOIN sources s ON s.id=c.source_id "
        "WHERE s.kind=? AND c.external_id=? AND m.external_id=?";
    if (![self prepareSQL:sql statement:&statement error:error]) {
        return nil;
    }
    [self bindText:sourceKind atIndex:1 statement:statement];
    [self bindText:conversationID atIndex:2 statement:statement];
    [self bindText:messageID atIndex:3 statement:statement];
    NSData *envelope = nil;
    int status = sqlite3_step(statement);
    if (status == SQLITE_ROW) {
        const void *bytes = sqlite3_column_blob(statement, 0);
        int length = sqlite3_column_bytes(statement, 0);
        envelope = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    } else if (status != SQLITE_DONE) {
        CPASetStoreError(error, self.database, @"Unable to read encrypted message");
    }
    sqlite3_finalize(statement);
    if (envelope == nil) {
        return nil;
    }
    NSData *plaintext = [self.crypto decryptEnvelope:envelope
        masterKey:self.masterKey error:error];
    if (plaintext == nil) {
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:plaintext encoding:NSUTF8StringEncoding];
    if (text == nil) {
        CPASetStoreError(error, self.database, @"Decrypted message is not valid UTF-8");
    }
    return text;
}

- (BOOL)close:(NSError **)error {
    if (self.closed || self.database == NULL) {
        return YES;
    }
    if (self.importSessionActive) {
        CPASetStoreError(error, NULL, @"Cannot close database during an active import session");
        return NO;
    }
    if (![self executeSQL:@"PRAGMA wal_checkpoint(TRUNCATE)" error:error]) {
        return NO;
    }
    int status = sqlite3_close_v2(self.database);
    if (status != SQLITE_OK) {
        CPASetStoreError(error, self.database, @"Unable to close local database");
        return NO;
    }
    self.database = NULL;
    self.closed = YES;
    [self clearMasterKey];
    return YES;
}

- (void)clearMasterKey {
    if (self.masterKey.length > 0) {
        [self.masterKey resetBytesInRange:NSMakeRange(0, self.masterKey.length)];
    }
    self.masterKey = nil;
}

- (BOOL)ensureOpen:(NSError **)error {
    if (!self.closed && self.database != NULL) {
        return YES;
    }
    CPASetStoreError(error, NULL, @"Local database is closed");
    return NO;
}

- (BOOL)executeSQL:(NSString *)sql error:(NSError **)error {
    char *message = NULL;
    int status = sqlite3_exec(self.database, sql.UTF8String, NULL, NULL, &message);
    if (status == SQLITE_OK) {
        return YES;
    }
    NSString *description = message != NULL
        ? [NSString stringWithUTF8String:message]
        : @"Local database operation failed";
    if (message != NULL) {
        sqlite3_free(message);
    }
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPALocalDataStoreErrorDomain
            code:status userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

- (BOOL)migrateCursorSchema:(NSError **)error {
    NSArray<NSString *> *definitions = @[
        @"device_id INTEGER NOT NULL DEFAULT 0",
        @"inode INTEGER NOT NULL DEFAULT 0",
        @"safe_line_number INTEGER NOT NULL DEFAULT 0",
    ];
    for (NSUInteger i = 0, len = definitions.count; i < len; i++) {
        NSString *definition = definitions[i];
        NSString *column = [definition componentsSeparatedByString:@" "][0];
        if ([self table:@"source_cursors" hasColumn:column error:error]) {
            continue;
        }
        if (error != NULL && *error != nil) {
            return NO;
        }
        NSString *sql = [NSString stringWithFormat:@"ALTER TABLE source_cursors ADD COLUMN %@",
            definition];
        if (![self executeSQL:sql error:error]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)table:(NSString *)tableName hasColumn:(NSString *)columnName
    error:(NSError **)error {
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", tableName];
    sqlite3_stmt *statement = NULL;
    if (![self prepareSQL:sql statement:&statement error:error]) {
        return NO;
    }
    BOOL found = NO;
    int status = SQLITE_ROW;
    while ((status = sqlite3_step(statement)) == SQLITE_ROW) {
        const char *name = (const char *)sqlite3_column_text(statement, 1);
        if (name != NULL && [columnName isEqualToString:
                [NSString stringWithUTF8String:name]]) {
            found = YES;
            break;
        }
    }
    if (status != SQLITE_ROW && status != SQLITE_DONE) {
        CPASetStoreError(error, self.database, @"Unable to inspect local database schema");
    }
    sqlite3_finalize(statement);
    return found;
}

- (BOOL)prepareSQL:(NSString *)sql statement:(sqlite3_stmt **)statement
    error:(NSError **)error {
    int status = sqlite3_prepare_v2(self.database, sql.UTF8String, -1, statement, NULL);
    if (status == SQLITE_OK) {
        return YES;
    }
    CPASetStoreError(error, self.database, @"Unable to prepare local database operation");
    return NO;
}

- (BOOL)stepDone:(sqlite3_stmt *)statement error:(NSError **)error {
    if (sqlite3_step(statement) == SQLITE_DONE) {
        return YES;
    }
    CPASetStoreError(error, self.database, @"Unable to update local database");
    return NO;
}

- (void)bindText:(NSString *)text atIndex:(int)index statement:(sqlite3_stmt *)statement {
    sqlite3_bind_text(statement, index, text.UTF8String, -1, SQLITE_TRANSIENT);
}

- (void)bindData:(NSData *)data atIndex:(int)index statement:(sqlite3_stmt *)statement {
    if (data == nil) {
        sqlite3_bind_null(statement, index);
    } else {
        sqlite3_bind_blob(statement, index, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    }
}

- (sqlite3_int64)integerIDForSQL:(NSString *)sql first:(NSString *)first
    second:(NSString *)second error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (![self prepareSQL:sql statement:&statement error:error]) return 0;
    [self bindText:first atIndex:1 statement:statement];
    [self bindText:second atIndex:2 statement:statement];
    sqlite3_int64 value = 0;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        value = sqlite3_column_int64(statement, 0);
    } else {
        CPASetStoreError(error, self.database, @"Unable to locate local source");
    }
    sqlite3_finalize(statement);
    return value;
}

- (sqlite3_int64)integerIDForSQL:(NSString *)sql integer:(sqlite3_int64)integer
    text:(NSString *)text error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (![self prepareSQL:sql statement:&statement error:error]) return 0;
    sqlite3_bind_int64(statement, 1, integer);
    [self bindText:text atIndex:2 statement:statement];
    sqlite3_int64 value = 0;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        value = sqlite3_column_int64(statement, 0);
    } else {
        CPASetStoreError(error, self.database, @"Unable to locate local conversation");
    }
    sqlite3_finalize(statement);
    return value;
}

- (BOOL)messageExists:(NSString *)messageID conversationID:(sqlite3_int64)conversationID
    error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (![self prepareSQL:@"SELECT 1 FROM messages WHERE conversation_id=? AND external_id=?"
            statement:&statement error:error]) {
        return NO;
    }
    sqlite3_bind_int64(statement, 1, conversationID);
    [self bindText:messageID atIndex:2 statement:statement];
    int status = sqlite3_step(statement);
    BOOL exists = status == SQLITE_ROW;
    if (status != SQLITE_ROW && status != SQLITE_DONE) {
        CPASetStoreError(error, self.database, @"Unable to check existing message");
    }
    sqlite3_finalize(statement);
    return exists;
}

- (NSUInteger)countForSQL:(NSString *)sql error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (![self prepareSQL:sql statement:&statement error:error]) return 0;
    NSUInteger count = 0;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        count = (NSUInteger)sqlite3_column_int64(statement, 0);
    } else {
        CPASetStoreError(error, self.database, @"Unable to count local records");
    }
    sqlite3_finalize(statement);
    return count;
}

@end
