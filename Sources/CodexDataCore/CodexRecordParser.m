#import "CodexRecordParser.h"

#import "CodexMessage.h"
#import "CodexSourceMetadata.h"

static NSString * const CPACodexRecordParserErrorDomain = @"CPACodexRecordParserErrorDomain";

static void CPASetRecordParserError(NSError **error, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPACodexRecordParserErrorDomain
            code:1
            userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

@implementation CPACodexRecordParser

- (CPACodexSourceMetadata *)parseMetadataLineData:(NSData *)lineData
    error:(NSError **)error {
    NSDictionary *record = [self dictionaryFromLineData:lineData error:error];
    if (record == nil) {
        return nil;
    }
    if (![record[@"type"] isEqual:@"session_meta"]
        || ![record[@"payload"] isKindOfClass:NSDictionary.class]) {
        CPASetRecordParserError(error, @"First JSONL record is not session_meta");
        return nil;
    }

    NSDictionary *payload = record[@"payload"];
    NSString *threadID = [self stringValue:payload[@"id"]];
    NSString *threadSource = [self stringValue:payload[@"thread_source"]];
    if (threadID.length == 0 || threadSource.length == 0) {
        CPASetRecordParserError(error, @"session_meta is missing id or thread_source");
        return nil;
    }

    NSString *timestamp = [self stringValue:payload[@"timestamp"]];
    if (timestamp.length == 0) {
        timestamp = [self stringValue:record[@"timestamp"]];
    }
    return [[CPACodexSourceMetadata alloc] initWithThreadID:threadID
        threadSource:threadSource
        source:[self stringValue:payload[@"source"]]
        cliVersion:[self stringValue:payload[@"cli_version"]]
        timestamp:timestamp
        workingDirectory:[self stringValue:payload[@"cwd"]]];
}

- (CPACodexMessage *)parseMessageLineData:(NSData *)lineData
    lineNumber:(NSUInteger)lineNumber
    lineStartOffset:(uint64_t)lineStartOffset
    error:(NSError **)error {
    NSDictionary *record = [self dictionaryFromLineData:lineData error:error];
    if (record == nil) {
        return nil;
    }
    if (![record[@"type"] isEqual:@"response_item"]
        || ![record[@"payload"] isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    NSDictionary *payload = record[@"payload"];
    if (![payload[@"type"] isEqual:@"message"]
        || ![payload[@"role"] isKindOfClass:NSString.class]) {
        return nil;
    }

    NSString *roleName = payload[@"role"];
    CPACodexMessageRole role = 0;
    NSString *acceptedContentType = nil;
    if ([roleName isEqualToString:@"user"]) {
        role = CPACodexMessageRoleUser;
        acceptedContentType = @"input_text";
    } else if ([roleName isEqualToString:@"assistant"]) {
        role = CPACodexMessageRoleAssistant;
        acceptedContentType = @"output_text";
    } else {
        return nil;
    }

    NSString *timestamp = [self stringValue:record[@"timestamp"]];
    NSString *messageID = [self stringValue:payload[@"id"]];
    if (messageID.length == 0) {
        NSString *timeComponent = timestamp.length > 0
            ? timestamp
            : [NSString stringWithFormat:@"offset-%llu", lineStartOffset];
        messageID = [NSString stringWithFormat:@"legacy:%@:%@:%lu",
            timeComponent,
            roleName,
            (unsigned long)lineNumber];
    }

    NSArray *content = [payload[@"content"] isKindOfClass:NSArray.class]
        ? payload[@"content"]
        : @[];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = 0, len = content.count; i < len; i++) {
        id value = content[i];
        if (![value isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *item = value;
        if (![item[@"type"] isEqual:acceptedContentType]
            || ![item[@"text"] isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *text = item[@"text"];
        NSString *trimmed = [text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([trimmed hasPrefix:@"<image "] || [trimmed isEqualToString:@"</image>"]) {
            continue;
        }
        if (trimmed.length > 0) {
            [parts addObject:trimmed];
        }
    }

    NSString *text = [parts componentsJoinedByString:@"\n"];
    if (role == CPACodexMessageRoleUser) {
        NSRange requestMarker = [text rangeOfString:@"## My request:"
            options:NSBackwardsSearch];
        if (requestMarker.location != NSNotFound) {
            NSUInteger requestStart = NSMaxRange(requestMarker);
            text = [text substringFromIndex:requestStart];
        }
    }
    text = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        return nil;
    }

    return [[CPACodexMessage alloc] initWithMessageID:messageID
        timestamp:timestamp
        role:role
        text:text
        sourceLineNumber:lineNumber
        sourceByteOffset:lineStartOffset];
}

- (NSDictionary *)dictionaryFromLineData:(NSData *)lineData error:(NSError **)error {
    id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:error];
    if (object == nil) {
        return nil;
    }
    if (![object isKindOfClass:NSDictionary.class]) {
        CPASetRecordParserError(error, @"JSONL record is not an object");
        return nil;
    }
    return object;
}

- (NSString *)stringValue:(id)value {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

@end
