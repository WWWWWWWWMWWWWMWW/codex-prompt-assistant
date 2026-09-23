#import "ConversationContextProvider.h"

#import <sqlite3.h>

static const NSUInteger CPAContextMaximumMessages = 8;
static const NSUInteger CPAContextMaximumUserMessages = 6;
static const NSUInteger CPAContextMaximumAssistantMessages = 2;
static const NSUInteger CPAContextMaximumTailBytes = 8 * 1024 * 1024;
static const NSTimeInterval CPAContextRefreshInterval = 1.0;

@implementation CPAConversationContextSnapshot
- (instancetype)initWithSelectionGeneration:(NSUInteger)selection revision:(NSUInteger)revision
    availability:(CPAContextAvailability)availability messages:(NSArray *)messages
    sourceURL:(NSURL *)sourceURL truncatedMessageIndexes:(NSIndexSet *)indexes
    tailTruncated:(BOOL)tailTruncated {
    self = [super init];
    if (self) {
        _selectionGeneration = selection; _revision = revision; _availability = availability;
        NSMutableArray *copies = [NSMutableArray arrayWithCapacity:messages.count];
        for (NSDictionary *message in messages) {
            [copies addObject:@{@"role": [message[@"role"] copy], @"content": [message[@"content"] copy]}];
        }
        _messages = [copies copy]; _sourceURL = [sourceURL copy];
        _truncatedMessageIndexes = [indexes copy]; _tailTruncated = tailTruncated;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
@end

@interface CPAContextReadResult : NSObject
@property(nonatomic, copy) NSArray *messages;
@property(nonatomic, copy) NSIndexSet *truncatedIndexes;
@property(nonatomic) BOOL tailTruncated;
@end
@implementation CPAContextReadResult
@end

@interface CPAConversationContextProvider ()
@property(nonatomic, strong) NSURL *sessionsDirectoryURL;
@property(nonatomic, strong) NSURL *stateDatabaseURL;
@property(nonatomic, strong) NSURL *sessionIndexURL;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t refreshTimer;
@property(nonatomic, strong) CPAConversationContextSnapshot *currentSnapshot;
@property(nonatomic, copy, nullable) NSString *selectedConversationTitle;
@property(nonatomic, copy, nullable) NSString *selectedConversationIdentifier;
@property(nonatomic, copy, nullable) NSURL *selectedSourceURL;
@property(nonatomic, copy, nullable) NSURL *cachedSourceURL;
@property(nonatomic) unsigned long long cachedSourceSize;
@property(nonatomic, strong, nullable) NSDate *cachedModificationDate;
@property(nonatomic) NSUInteger selectionGeneration;
@property(nonatomic) unsigned long long cachedFileNumber;
- (nullable NSArray<NSString *> *)conversationIdentifiersForTitle:(NSString *)title;
- (nullable NSURL *)sourceURLForConversationTitle:(nullable NSString *)title
    identifier:(nullable NSString *)identifier availability:(CPAContextAvailability *)availability;
@end

@implementation CPAConversationContextProvider

- (instancetype)initWithSessionsDirectoryURL:(NSURL *)sessionsDirectoryURL {
    NSURL *codexDirectory = [sessionsDirectoryURL URLByDeletingLastPathComponent];
    NSURL *stateDatabaseURL = [codexDirectory URLByAppendingPathComponent:
        @"state_5.sqlite" isDirectory:NO];
    return [self initWithSessionsDirectoryURL:sessionsDirectoryURL
        stateDatabaseURL:stateDatabaseURL];
}

- (instancetype)initWithSessionsDirectoryURL:(NSURL *)sessionsDirectoryURL
    stateDatabaseURL:(NSURL *)stateDatabaseURL {
    self = [super init];
    if (self != nil) {
        _sessionsDirectoryURL = [sessionsDirectoryURL URLByStandardizingPath];
        _stateDatabaseURL = [stateDatabaseURL URLByStandardizingPath];
        _sessionIndexURL = [[stateDatabaseURL URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"session_index.jsonl" isDirectory:NO];
        _queue = dispatch_queue_create(
            "local.codex.prompt-assistant.conversation-context", DISPATCH_QUEUE_SERIAL);
        _currentSnapshot = [[CPAConversationContextSnapshot alloc] initWithSelectionGeneration:0
            revision:0 availability:CPAContextAvailabilityMissing messages:@[] sourceURL:nil
            truncatedMessageIndexes:NSIndexSet.indexSet tailTruncated:NO];
    }
    return self;
}

- (CPAConversationContextSnapshot *)currentSnapshot {
    @synchronized (self) { return _currentSnapshot; }
}

- (NSUInteger)contextGeneration { return self.currentSnapshot.revision; }

- (CPAConversationContextState)contextState {
    // Preserve the legacy accessor while new consumers use precise availability.
    @synchronized (self) {
        if (_currentSnapshot.availability == CPAContextAvailabilityLoading) return CPAConversationContextStateLoading;
        return self.selectedConversationTitle == nil && self.selectedConversationIdentifier == nil
            ? CPAConversationContextStateEmpty : CPAConversationContextStateReady;
    }
}

// Caller holds @synchronized(self). Compare actual selected material, not file mtime.
- (void)publishMessages:(NSArray *)messages sourceURL:(NSURL *)source
    availability:(CPAContextAvailability)availability truncatedIndexes:(NSIndexSet *)indexes
    tailTruncated:(BOOL)tailTruncated {
    CPAConversationContextSnapshot *old = _currentSnapshot;
    if (old.selectionGeneration == self.selectionGeneration && old.availability == availability
        && [old.messages isEqual:messages] && [old.truncatedMessageIndexes isEqual:indexes]
        && old.tailTruncated == tailTruncated
        && (old.sourceURL == source || [old.sourceURL isEqual:source])) return;
    _currentSnapshot = [[CPAConversationContextSnapshot alloc]
        initWithSelectionGeneration:self.selectionGeneration revision:old.revision + 1
        availability:availability messages:messages sourceURL:source
        truncatedMessageIndexes:indexes tailTruncated:tailTruncated];
    if (self.snapshotDidChange != nil) {
        __weak CPAConversationContextProvider *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^changed)(void) = weakSelf.snapshotDidChange;
            if (changed) changed();
        });
    }
}

- (void)start {
    dispatch_async(self.queue, ^{
        [self refreshLocked];
    });
    if (self.refreshTimer != nil) {
        return;
    }
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    self.refreshTimer = timer;
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, 0),
        (uint64_t)(CPAContextRefreshInterval * NSEC_PER_SEC),
        (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak CPAConversationContextProvider *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf refreshLocked];
    });
    dispatch_resume(timer);
}

- (void)stop {
    dispatch_source_t timer = self.refreshTimer;
    self.refreshTimer = nil;
    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)cachedContextMessages {
    return self.currentSnapshot.messages;
}

- (void)selectConversationWithTitle:(NSString *)title {
    [self selectConversationTitle:title identifier:nil];
}

- (void)selectConversationWithIdentifier:(NSString *)identifier {
    NSUUID *uuid = identifier.length == 36 ? [[NSUUID alloc] initWithUUIDString:identifier] : nil;
    [self selectConversationTitle:nil identifier:uuid.UUIDString.lowercaseString];
}

- (void)selectConversationTitle:(NSString *)title identifier:(NSString *)identifier {
    NSString *normalized = [title stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *key = identifier ?: normalized;
    __block NSUInteger generation = 0;
    @synchronized (self) {
        self.selectedConversationTitle = normalized.length > 0 ? normalized : nil;
        self.selectedConversationIdentifier = identifier;
        self.selectedSourceURL = nil;
        self.cachedSourceURL = nil;
        self.cachedSourceSize = 0;
        self.cachedModificationDate = nil;
        generation = ++self.selectionGeneration;
        [self publishMessages:@[] sourceURL:nil availability:key.length > 0
            ? CPAContextAvailabilityLoading : CPAContextAvailabilityMissing
            truncatedIndexes:NSIndexSet.indexSet tailTruncated:NO];
    }
    if (key.length == 0) {
        return;
    }
    dispatch_async(self.queue, ^{
        CPAContextAvailability resolution = CPAContextAvailabilityMissing;
        NSURL *sourceURL = [self sourceURLForConversationTitle:normalized identifier:identifier availability:&resolution];
        @synchronized (self) {
            BOOL stillSelected = generation == self.selectionGeneration
                && [(self.selectedConversationIdentifier ?: self.selectedConversationTitle) isEqualToString:key];
            if (!stillSelected) {
                return;
            }
            self.selectedSourceURL = sourceURL;
            // An unresolved title is an explicit, safe empty result. It must not
            // remain in loading forever, otherwise callers can never distinguish
            // a legitimate empty context from a transient switch race.
            if (sourceURL == nil) {
                [self publishMessages:@[] sourceURL:nil availability:resolution
                    truncatedIndexes:NSIndexSet.indexSet tailTruncated:NO];
            }
        }
        if (sourceURL != nil) {
            [self refreshLocked];
        }
    });
}

- (void)invalidateCachedContext {
    @synchronized (self) {
        self.selectedConversationTitle = nil;
        self.selectedConversationIdentifier = nil;
        self.selectedSourceURL = nil;
        self.cachedSourceURL = nil;
        self.cachedSourceSize = 0;
        self.cachedModificationDate = nil;
        self.selectionGeneration++;
        [self publishMessages:@[] sourceURL:nil availability:CPAContextAvailabilityMissing
            truncatedIndexes:NSIndexSet.indexSet tailTruncated:NO];
    }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)cachedContextMessagesModifiedAfterDate:
    (NSDate *)date {
    @synchronized (self) {
        if (self.cachedModificationDate == nil
            || [self.cachedModificationDate compare:date] != NSOrderedDescending) {
            return @[];
        }
        return self.currentSnapshot.messages;
    }
}

- (void)refreshLocked {
    NSURL *sourceURL = nil;
    NSUInteger generation = 0;
    NSString *title = nil, *identifier = nil;
    @synchronized (self) {
        sourceURL = self.selectedSourceURL; generation = self.selectionGeneration;
        title = self.selectedConversationTitle; identifier = self.selectedConversationIdentifier;
    }
    if (sourceURL == nil) {
        if (title.length == 0 && identifier.length == 0) return;
        CPAContextAvailability availability = CPAContextAvailabilityMissing;
        sourceURL = [self sourceURLForConversationTitle:title identifier:identifier availability:&availability];
        @synchronized (self) {
            if (generation != self.selectionGeneration) return;
            self.selectedSourceURL = sourceURL;
            if (sourceURL == nil) {
                [self publishMessages:@[] sourceURL:nil availability:availability
                    truncatedIndexes:NSIndexSet.indexSet tailTruncated:NO];
                return;
            }
        }
    }
    // NSURL resource values may be cached on the retained URL. Read fresh stat data.
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:sourceURL.path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    unsigned long long fileNumber = [attributes[NSFileSystemFileNumber] unsignedLongLongValue];
    NSDate *date = attributes[NSFileModificationDate];
    @synchronized (self) {
        if (attributes != nil && [sourceURL isEqual:self.cachedSourceURL]
            && size == self.cachedSourceSize && fileNumber == self.cachedFileNumber
            && [date isEqualToDate:self.cachedModificationDate]
            && self.currentSnapshot.availability != CPAContextAvailabilityError) return;
    }
    BOOL correctHeader = identifier == nil || [self sourceURL:sourceURL hasSessionIdentifier:identifier];
    CPAContextReadResult *read = attributes == nil || !correctHeader ? nil : [self readContextFromURL:sourceURL];
    NSDictionary *after = [NSFileManager.defaultManager attributesOfItemAtPath:sourceURL.path error:nil];
    // Do not publish a read taken across a replacement/append as one coherent revision.
    if (![attributes[NSFileSize] isEqual:after[NSFileSize]]
        || ![attributes[NSFileModificationDate] isEqual:after[NSFileModificationDate]]
        || ![attributes[NSFileSystemFileNumber] isEqual:after[NSFileSystemFileNumber]]) read = nil;
    @synchronized (self) {
        if (generation != self.selectionGeneration || ![sourceURL isEqual:self.selectedSourceURL]) return;
        if (read == nil) {
            [self publishMessages:@[] sourceURL:sourceURL availability:CPAContextAvailabilityError
                truncatedIndexes:NSIndexSet.indexSet tailTruncated:NO];
            return;
        }
        [self publishMessages:read.messages sourceURL:sourceURL availability:read.messages.count > 0
            ? CPAContextAvailabilityReady : CPAContextAvailabilityReadyEmpty
            truncatedIndexes:read.truncatedIndexes tailTruncated:read.tailTruncated];
        self.cachedSourceURL = sourceURL; self.cachedSourceSize = size;
        self.cachedFileNumber = fileNumber; self.cachedModificationDate = date;
    }
}

- (nullable NSURL *)sourceURLForConversationTitle:(NSString *)title
    availability:(CPAContextAvailability *)availability {
    return [self sourceURLForConversationTitle:title identifier:nil availability:availability];
}

- (BOOL)sourceURL:(NSURL *)url hasSessionIdentifier:(NSString *)identifier {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path];
    if (handle == nil) return NO;
    NSData *data = nil;
    @try { data = [handle readDataOfLength:64 * 1024]; }
    @catch (NSException *exception) { (void)exception; return NO; }
    @finally { [handle closeFile]; }
    const uint8_t *bytes = data.bytes;
    const uint8_t *newline = memchr(bytes, '\n', data.length);
    NSUInteger count = newline == NULL ? data.length : (NSUInteger)(newline - bytes);
    id header = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(0, count)]
        options:0 error:nil];
    if (![header isKindOfClass:NSDictionary.class] || ![header[@"type"] isEqual:@"session_meta"]
        || ![header[@"payload"] isKindOfClass:NSDictionary.class]) return NO;
    return [header[@"payload"][@"id"] isEqual:identifier];
}

- (nullable NSURL *)sourceURLForConversationTitle:(NSString *)title identifier:(NSString *)identifier
    availability:(CPAContextAvailability *)availability {
    *availability = CPAContextAvailabilityError;
    sqlite3 *database = NULL;
    int openResult = sqlite3_open_v2(self.stateDatabaseURL.fileSystemRepresentation,
        &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
    if (openResult != SQLITE_OK || database == NULL) {
        if (database != NULL) {
            sqlite3_close(database);
        }
        return nil;
    }

    *availability = CPAContextAvailabilityMissing;
    NSArray<NSString *> *mappedIdentifiers = identifier != nil ? @[identifier]
        : [self conversationIdentifiersForTitle:title];
    if (mappedIdentifiers.count > 1) {
        // The index retains names of archived copies/forks. A single active
        // task is resolvable; multiple active namesakes must never be guessed.
        NSMutableArray *active = [NSMutableArray array];
        sqlite3_stmt *lookup = NULL;
        if (sqlite3_prepare_v2(database, "SELECT id FROM threads WHERE id = ? AND archived = 0",
                -1, &lookup, NULL) == SQLITE_OK) {
            for (NSString *identifier in mappedIdentifiers) {
                sqlite3_reset(lookup);
                sqlite3_bind_text(lookup, 1, identifier.UTF8String, -1, SQLITE_TRANSIENT);
                if (sqlite3_step(lookup) == SQLITE_ROW) [active addObject:identifier];
            }
        }
        if (lookup != NULL) sqlite3_finalize(lookup);
        if (active.count != 1) { *availability = CPAContextAvailabilityAmbiguous; sqlite3_close(database); return nil; }
        mappedIdentifiers = active;
    }
    BOOL useMappedIdentifier = mappedIdentifiers.count == 1;
    const char *sql = useMappedIdentifier
        ? "SELECT rollout_path FROM threads "
            "WHERE rollout_path <> '' AND id = ? LIMIT 2"
        : "SELECT rollout_path FROM threads "
            "WHERE archived = 0 AND rollout_path <> '' "
            "AND (name = ? OR ((name IS NULL OR name = '') AND title = ?)) "
            "ORDER BY recency_at_ms DESC LIMIT 2";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, sql, -1, &statement, NULL) != SQLITE_OK) {
        *availability = CPAContextAvailabilityError;
        sqlite3_close(database);
        return nil;
    }
    NSString *lookupValue = useMappedIdentifier
        ? mappedIdentifiers.firstObject : title;
    sqlite3_bind_text(statement, 1, lookupValue.UTF8String, -1, SQLITE_TRANSIENT);
    if (!useMappedIdentifier) {
        sqlite3_bind_text(statement, 2, title.UTF8String, -1, SQLITE_TRANSIENT);
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:2];
    while (sqlite3_step(statement) == SQLITE_ROW && paths.count < 2) {
        const unsigned char *value = sqlite3_column_text(statement, 0);
        if (value != NULL) {
            NSString *path = [NSString stringWithUTF8String:(const char *)value];
            if (path.length > 0) {
                [paths addObject:path];
            }
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
    if (paths.count != 1) {
        if (paths.count > 1) *availability = CPAContextAvailabilityAmbiguous;
        return nil;
    }
    NSURL *sourceURL = [[NSURL fileURLWithPath:paths.firstObject]
        URLByStandardizingPath];
    if (![sourceURL.pathExtension.lowercaseString isEqualToString:@"jsonl"]
        || ![self sourceURLIsInsideCodexDataDirectory:sourceURL]) {
        return nil;
    }
    *availability = CPAContextAvailabilityError;
    NSNumber *isRegular = nil;
    [sourceURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
    return isRegular.boolValue ? sourceURL : nil;
}

- (nullable NSArray<NSString *> *)conversationIdentifiersForTitle:(NSString *)title {
    NSString *text = [NSString stringWithContentsOfURL:self.sessionIndexURL
        encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) {
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *latestNamesByIdentifier =
        [NSMutableDictionary dictionary];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSUInteger index = 0, count = lines.count; index < count; index++) {
        NSString *line = [lines[index] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) {
            continue;
        }
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        id entryValue = [NSJSONSerialization JSONObjectWithData:lineData
            options:0 error:nil];
        if (![entryValue isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *identifier = ((NSDictionary *)entryValue)[@"id"];
        NSString *name = ((NSDictionary *)entryValue)[@"thread_name"];
        if (![identifier isKindOfClass:NSString.class]
            || ![name isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *normalized = [name stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (identifier.length > 0 && normalized.length > 0) {
            latestNamesByIdentifier[identifier] = normalized;
        }
    }
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:2];
    [latestNamesByIdentifier enumerateKeysAndObjectsUsingBlock:
        ^(NSString *identifier, NSString *name, BOOL *stop) {
        if ([name isEqualToString:title]) {
            [identifiers addObject:identifier];
            (void)stop;
        }
    }];
    return [identifiers copy];
}

- (BOOL)sourceURLIsInsideCodexDataDirectory:(NSURL *)sourceURL {
    NSString *sourcePath = sourceURL.path.stringByStandardizingPath;
    NSString *codexPath = self.sessionsDirectoryURL.URLByDeletingLastPathComponent
        .path.stringByStandardizingPath;
    if (sourcePath.length <= codexPath.length || ![sourcePath hasPrefix:codexPath]) {
        return NO;
    }
    unichar separator = [sourcePath characterAtIndex:codexPath.length];
    return separator == '/';
}

- (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)readRecentMessagesFromURL:(NSURL *)url {
    return [self readContextFromURL:url].messages;
}

- (nullable CPAContextReadResult *)readContextFromURL:(NSURL *)url {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path];
    if (handle == nil) return nil;
    unsigned long long offset = 0;
    NSData *data = nil;
    @try {
        unsigned long long length = handle.seekToEndOfFile;
        offset = length > CPAContextMaximumTailBytes ? length - CPAContextMaximumTailBytes : 0;
        [handle seekToFileOffset:offset];
        data = [handle readDataToEndOfFile];
    } @catch (NSException *exception) {
        (void)exception; return nil;
    } @finally { [handle closeFile]; }
    CPAContextReadResult *result = [CPAContextReadResult new];
    result.messages = @[]; result.truncatedIndexes = NSIndexSet.indexSet;
    result.tailTruncated = offset > 0;
    // Discard the first partial line as bytes before UTF-8 decoding. A seek
    // landing inside a Chinese character must not erase the whole snapshot.
    if (offset > 0) {
        const uint8_t *bytes = data.bytes;
        const uint8_t *newline = memchr(bytes, '\n', data.length);
        if (newline == NULL) return result;
        NSUInteger start = (NSUInteger)(newline - bytes) + 1;
        data = [data subdataWithRange:NSMakeRange(start, data.length - start)];
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) return nil;
    if (text.length == 0) return result;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *reverseMessages =
        [NSMutableArray arrayWithCapacity:CPAContextMaximumMessages];
    NSMutableIndexSet *reverseTruncated = [NSMutableIndexSet indexSet];
    NSUInteger startIndex = 0;
    NSUInteger userCount = 0, assistantCount = 0;
    for (NSInteger index = (NSInteger)lines.count - 1;
        index >= (NSInteger)startIndex && reverseMessages.count < CPAContextMaximumMessages;
        index--) {
        NSString *line = [lines[(NSUInteger)index]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) {
            continue;
        }
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:lineData
            options:0 error:nil];
        if (![entry isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *payload = entry[@"payload"];
        if (![@"response_item" isEqual:entry[@"type"]]) continue;
        if (![payload isKindOfClass:NSDictionary.class]) return nil;
        if (![@"message" isEqual:payload[@"type"]]
            || (![@"user" isEqual:payload[@"role"]] && ![@"assistant" isEqual:payload[@"role"]])) {
            continue;
        }
        BOOL user = [payload[@"role"] isEqualToString:@"user"];
        NSString *channel = payload[@"channel"];
        NSString *phase = payload[@"phase"];
        if (!user && ((channel != nil && ![@"final" isEqual:channel])
            || (phase != nil && ![@"final_answer" isEqual:phase]))) continue;
        if ((user && userCount >= CPAContextMaximumUserMessages)
            || (!user && assistantCount >= CPAContextMaximumAssistantMessages)) continue;
        BOOL truncated = NO;
        NSString *content = [self textFromMessagePayload:payload truncated:&truncated];
        if (content.length == 0) {
            continue;
        }
        if ([content hasPrefix:@"<environment_context>"]) continue;
        if (user) userCount++; else assistantCount++;
        NSString *role = [payload[@"role"] copy];
        if (truncated) [reverseTruncated addIndex:reverseMessages.count];
        [reverseMessages addObject:@{ @"role": role, @"content": content }];
    }
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *ordered =
        [NSMutableArray arrayWithCapacity:reverseMessages.count];
    NSMutableIndexSet *truncated = [NSMutableIndexSet indexSet];
    for (NSInteger index = (NSInteger)reverseMessages.count - 1; index >= 0; index--) {
        if ([reverseTruncated containsIndex:(NSUInteger)index]) [truncated addIndex:ordered.count];
        [ordered addObject:reverseMessages[(NSUInteger)index]];
    }
    result.messages = ordered; result.truncatedIndexes = truncated;
    return result;
}

- (NSString *)textFromMessagePayload:(NSDictionary *)payload truncated:(BOOL *)truncated {
    NSArray *blocks = payload[@"content"];
    if (![blocks isKindOfClass:NSArray.class]) {
        return @"";
    }
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger index = 0, count = blocks.count; index < count; index++) {
        NSDictionary *block = blocks[index];
        if (![block isKindOfClass:NSDictionary.class]
            || (![@"input_text" isEqual:block[@"type"]]
                && ![@"output_text" isEqual:block[@"type"]])) {
            continue;
        }
        NSString *value = block[@"text"];
        if ([value isKindOfClass:NSString.class] && value.length > 0) {
            if (text.length > 0) {
                [text appendString:@"\n"];
            }
            [text appendString:value];
        }
    }
    NSUInteger limit = [payload[@"role"] isEqualToString:@"user"] ? 400 : 300;
    if (text.length > limit) {
        *truncated = YES;
        NSString *marker = @"\n[…中间省略…]\n";
        NSUInteger headLength = (limit - marker.length) / 2;
        NSUInteger tailLength = limit - marker.length - headLength;
        // Enumerated composed ranges may expand; trim toward the interior to
        // keep the budget strict without splitting emoji or combining marks.
        NSRange head = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, headLength)];
        if (NSMaxRange(head) > headLength) head.length = [text rangeOfComposedCharacterSequenceAtIndex:headLength - 1].location;
        NSUInteger tailStart = text.length - tailLength;
        NSRange tail = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(tailStart, tailLength)];
        if (tail.location < tailStart) tail.location = NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex:tailStart]);
        tail.length = text.length - tail.location;
        return [NSString stringWithFormat:@"%@%@%@", [text substringWithRange:head], marker, [text substringWithRange:tail]];
    }
    return [text copy];
}

@end
