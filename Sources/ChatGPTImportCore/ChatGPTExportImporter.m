#import "ChatGPTExportImporter.h"

#import "JSONArrayObjectStreamParser.h"
#import "SafeZIPArchiveReader.h"
#import "../CodexDataCore/CodexMessage.h"
#import "../CodexDataCore/CodexSourceMetadata.h"
#import "../CodexDataCore/LocalDataStore.h"

static NSString * const CPAChatGPTImportErrorDomain = @"CPAChatGPTImportErrorDomain";

typedef NS_ENUM(NSInteger, CPAChatGPTImportErrorCode) {
    CPAChatGPTImportErrorInvalidExport = 1,
    CPAChatGPTImportErrorCancelled = 2,
};

static void CPASetChatGPTImportError(NSError **error,
    CPAChatGPTImportErrorCode code, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPAChatGPTImportErrorDomain code:code
            userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

static NSString *CPAString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *CPADictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *CPAArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *CPATimestampString(id value) {
    if (![value isKindOfClass:NSNumber.class]) {
        return nil;
    }
    return [NSString stringWithFormat:@"%.6f", [value doubleValue]];
}

@interface CPAChatGPTImportLimits ()
@property(nonatomic, readwrite) uint64_t maximumArchiveBytes;
@property(nonatomic, readwrite) NSUInteger maximumEntryCount;
@property(nonatomic, readwrite) uint64_t maximumEntryUncompressedBytes;
@property(nonatomic, readwrite) uint64_t maximumTotalUncompressedBytes;
@property(nonatomic, readwrite) NSUInteger maximumConversationBytes;
@property(nonatomic, readwrite) double maximumCompressionRatio;
@end

@implementation CPAChatGPTImportLimits

- (instancetype)initWithMaximumArchiveBytes:(uint64_t)maximumArchiveBytes
    maximumEntryCount:(NSUInteger)maximumEntryCount
    maximumEntryUncompressedBytes:(uint64_t)maximumEntryUncompressedBytes
    maximumTotalUncompressedBytes:(uint64_t)maximumTotalUncompressedBytes
    maximumConversationBytes:(NSUInteger)maximumConversationBytes
    maximumCompressionRatio:(double)maximumCompressionRatio {
    self = [super init];
    if (self != nil) {
        _maximumArchiveBytes = maximumArchiveBytes;
        _maximumEntryCount = maximumEntryCount;
        _maximumEntryUncompressedBytes = maximumEntryUncompressedBytes;
        _maximumTotalUncompressedBytes = maximumTotalUncompressedBytes;
        _maximumConversationBytes = maximumConversationBytes;
        _maximumCompressionRatio = maximumCompressionRatio;
    }
    return self;
}

+ (instancetype)defaultLimits {
    return [[self alloc] initWithMaximumArchiveBytes:4ULL * 1024 * 1024 * 1024
        maximumEntryCount:10000
        maximumEntryUncompressedBytes:3ULL * 1024 * 1024 * 1024
        maximumTotalUncompressedBytes:8ULL * 1024 * 1024 * 1024
        maximumConversationBytes:64 * 1024 * 1024
        maximumCompressionRatio:200.0];
}

@end

@interface CPAChatGPTExportImportResult ()
@property(nonatomic, readwrite) NSUInteger conversationCount;
@property(nonatomic, readwrite) NSUInteger insertedMessageCount;
@property(nonatomic, readwrite) NSUInteger existingMessageCount;
@end

@implementation CPAChatGPTExportImportResult
@end

@interface CPAChatGPTNormalizedConversation : NSObject
@property(nonatomic, strong) CPACodexSourceMetadata *metadata;
@property(nonatomic, strong) NSArray<CPACodexMessage *> *messages;
@end

@implementation CPAChatGPTNormalizedConversation
@end

@interface CPAChatGPTExportImporter ()
@property(nonatomic, strong) CPAChatGPTImportLimits *limits;
@end

@implementation CPAChatGPTExportImporter

- (instancetype)initWithLimits:(CPAChatGPTImportLimits *)limits {
    self = [super init];
    if (self != nil) {
        _limits = limits;
    }
    return self;
}

- (CPAChatGPTExportImportResult *)importExportAtURL:(NSURL *)exportURL
    intoStore:(CPALocalDataStore *)store
    cancellationCheck:(CPAChatGPTImportCancellationCheck)cancellationCheck
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    if (![self limitsAreValid]) {
        CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
            @"ChatGPT import limits are invalid");
        return nil;
    }
    CPASafeZIPArchiveReader *archive = [[CPASafeZIPArchiveReader alloc]
        initWithURL:exportURL
        maximumArchiveBytes:self.limits.maximumArchiveBytes
        maximumEntryCount:self.limits.maximumEntryCount
        maximumEntryUncompressedBytes:self.limits.maximumEntryUncompressedBytes
        maximumTotalUncompressedBytes:self.limits.maximumTotalUncompressedBytes
        maximumCompressionRatio:self.limits.maximumCompressionRatio
        error:error];
    if (archive == nil) {
        return nil;
    }
    if (cancellationCheck != nil && cancellationCheck()) {
        CPASetChatGPTImportError(error, CPAChatGPTImportErrorCancelled,
            @"ChatGPT import was cancelled");
        return nil;
    }

    CPALocalImportSession *session = [store beginImportSessionForSourceKind:@"chatgpt"
        error:error];
    if (session == nil) {
        return nil;
    }
    __block NSUInteger conversationCount = 0;
    __block NSError *conversationError = nil;
    CPAJSONArrayObjectStreamParser *parser = [[CPAJSONArrayObjectStreamParser alloc]
        initWithMaximumObjectBytes:self.limits.maximumConversationBytes
        objectHandler:^BOOL(NSData *objectData, NSError **handlerError) {
            __strong NSError *retainedError = nil;
            __block BOOL handled = NO;
            @autoreleasepool {
                NSError *localError = nil;
                if (cancellationCheck != nil && cancellationCheck()) {
                    CPASetChatGPTImportError(&localError, CPAChatGPTImportErrorCancelled,
                        @"ChatGPT import was cancelled");
                } else {
                    CPAChatGPTNormalizedConversation *conversation =
                        [self normalizedConversationFromData:objectData error:&localError];
                    if (conversation != nil && [session importMetadata:conversation.metadata
                            messages:conversation.messages error:&localError]) {
                        conversationCount++;
                        handled = YES;
                    }
                }
                retainedError = localError;
            }
            if (!handled && handlerError != NULL) {
                *handlerError = retainedError ?: [NSError
                    errorWithDomain:CPAChatGPTImportErrorDomain
                    code:CPAChatGPTImportErrorInvalidExport
                    userInfo:@{NSLocalizedDescriptionKey:
                        @"ChatGPT conversation could not be imported"}];
            }
            return handled;
        }];
    BOOL streamed = [archive streamEntry:archive.conversationsEntry chunkSize:64 * 1024
        chunkHandler:^BOOL(NSData *chunk, NSError **chunkError) {
            return [parser consumeData:chunk error:chunkError];
        } error:&conversationError];
    BOOL finished = streamed && [parser finish:&conversationError];
    if (!finished) {
        [session rollback];
        if (error != NULL) {
            *error = conversationError ?: [NSError
                errorWithDomain:CPAChatGPTImportErrorDomain
                code:CPAChatGPTImportErrorInvalidExport
                userInfo:@{NSLocalizedDescriptionKey: @"ChatGPT export parsing failed"}];
        }
        return nil;
    }
    CPALocalImportResult *storeResult = [session commit:error];
    if (storeResult == nil) {
        return nil;
    }
    CPAChatGPTExportImportResult *result = [[CPAChatGPTExportImportResult alloc] init];
    result.conversationCount = conversationCount;
    result.insertedMessageCount = storeResult.insertedMessageCount;
    result.existingMessageCount = storeResult.existingMessageCount;
    return result;
}

- (BOOL)limitsAreValid {
    return self.limits.maximumArchiveBytes >= 22
        && self.limits.maximumEntryCount > 0
        && self.limits.maximumEntryUncompressedBytes > 0
        && self.limits.maximumTotalUncompressedBytes
            >= self.limits.maximumEntryUncompressedBytes
        && self.limits.maximumConversationBytes > 0
        && self.limits.maximumCompressionRatio >= 1.0;
}

- (CPAChatGPTNormalizedConversation *)normalizedConversationFromData:(NSData *)data
    error:(NSError **)error {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSDictionary *conversation = CPADictionary(object);
    if (conversation == nil) {
        CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
            @"ChatGPT conversation is not an object");
        return nil;
    }
    NSString *conversationID = CPAString(conversation[@"id"]);
    NSString *currentNodeID = CPAString(conversation[@"current_node"]);
    NSDictionary *mapping = CPADictionary(conversation[@"mapping"]);
    NSString *conversationTimestamp = CPATimestampString(conversation[@"create_time"])
        ?: CPATimestampString(conversation[@"update_time"]);
    if (conversationID.length == 0 || currentNodeID.length == 0
        || mapping == nil || conversationTimestamp.length == 0) {
        CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
            @"ChatGPT conversation uses an unsupported schema");
        return nil;
    }

    NSMutableArray<NSDictionary *> *reversePath = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSString *nodeID = currentNodeID;
    while (nodeID != nil) {
        if ([visited containsObject:nodeID]) {
            CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
                @"ChatGPT conversation branch contains a cycle");
            return nil;
        }
        [visited addObject:nodeID];
        NSDictionary *node = CPADictionary(mapping[nodeID]);
        if (node == nil || ![CPAString(node[@"id"]) isEqualToString:nodeID]) {
            CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
                @"ChatGPT current branch references a missing node");
            return nil;
        }
        [reversePath addObject:node];
        id parentValue = node[@"parent"];
        if (parentValue == nil || parentValue == NSNull.null) {
            nodeID = nil;
        } else {
            nodeID = CPAString(parentValue);
            if (nodeID.length == 0) {
                CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
                    @"ChatGPT branch parent uses an unsupported type");
                return nil;
            }
        }
    }

    NSMutableArray<CPACodexMessage *> *messages = [NSMutableArray array];
    NSMutableSet<NSString *> *messageIDs = [NSMutableSet set];
    NSUInteger ordinal = 0;
    for (NSUInteger index = reversePath.count; index > 0; index--) {
        NSDictionary *node = reversePath[index - 1];
        id messageValue = node[@"message"];
        if (messageValue == nil || messageValue == NSNull.null) {
            continue;
        }
        NSDictionary *message = CPADictionary(messageValue);
        NSDictionary *author = CPADictionary(message[@"author"]);
        NSString *roleName = CPAString(author[@"role"]);
        if (message == nil || roleName.length == 0) {
            CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
                @"ChatGPT message author uses an unsupported schema");
            return nil;
        }
        CPACodexMessageRole role = 0;
        if ([roleName isEqualToString:@"user"]) {
            role = CPACodexMessageRoleUser;
        } else if ([roleName isEqualToString:@"assistant"]) {
            role = CPACodexMessageRoleAssistant;
        } else if ([roleName isEqualToString:@"system"]
            || [roleName isEqualToString:@"tool"]
            || [roleName isEqualToString:@"developer"]) {
            continue;
        } else {
            CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
                @"ChatGPT message role is unknown");
            return nil;
        }
        NSString *messageID = CPAString(message[@"id"]);
        NSDictionary *content = CPADictionary(message[@"content"]);
        if (messageID.length == 0 || content == nil || [messageIDs containsObject:messageID]) {
            CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
                @"ChatGPT visible message is missing a stable unique ID or content");
            return nil;
        }
        NSString *text = [self textFromContent:content error:error];
        if (text == nil) {
            return nil;
        }
        [messageIDs addObject:messageID];
        if (text.length == 0) {
            continue;
        }
        ordinal++;
        NSString *timestamp = CPATimestampString(message[@"create_time"])
            ?: conversationTimestamp;
        [messages addObject:[[CPACodexMessage alloc] initWithMessageID:messageID
            timestamp:timestamp role:role text:text
            sourceLineNumber:ordinal sourceByteOffset:0]];
    }

    CPACodexSourceMetadata *metadata = [[CPACodexSourceMetadata alloc]
        initWithThreadID:conversationID threadSource:@"user"
        source:@"chatgpt_export" cliVersion:@"export-v1"
        timestamp:conversationTimestamp workingDirectory:@""];
    CPAChatGPTNormalizedConversation *normalized =
        [[CPAChatGPTNormalizedConversation alloc] init];
    normalized.metadata = metadata;
    normalized.messages = messages;
    return normalized;
}

- (NSString *)textFromContent:(NSDictionary *)content error:(NSError **)error {
    NSString *contentType = CPAString(content[@"content_type"]);
    NSArray *parts = CPAArray(content[@"parts"]);
    if (contentType.length == 0 || parts == nil
        || (![contentType isEqualToString:@"text"]
            && ![contentType isEqualToString:@"multimodal_text"])) {
        CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
            @"ChatGPT visible message content type is unsupported");
        return nil;
    }
    NSMutableArray<NSString *> *textParts = [NSMutableArray array];
    for (NSUInteger i = 0, len = parts.count; i < len; i++) {
        id part = parts[i];
        NSString *text = CPAString(part);
        if (text == nil && [contentType isEqualToString:@"multimodal_text"]) {
            NSDictionary *partDictionary = CPADictionary(part);
            NSString *partType = CPAString(partDictionary[@"content_type"]);
            text = CPAString(partDictionary[@"text"]);
            if (text == nil && ([partType isEqualToString:@"image_asset_pointer"]
                    || [partType isEqualToString:@"audio_asset_pointer"])) {
                continue;
            }
        }
        if (text == nil) {
            CPASetChatGPTImportError(error, CPAChatGPTImportErrorInvalidExport,
                @"ChatGPT visible message part uses an unsupported schema");
            return nil;
        }
        NSString *trimmed = [text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) {
            [textParts addObject:trimmed];
        }
    }
    return [textParts componentsJoinedByString:@"\n"];
}

@end
