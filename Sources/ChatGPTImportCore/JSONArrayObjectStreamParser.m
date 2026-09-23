#import "JSONArrayObjectStreamParser.h"

static NSString * const CPAJSONArrayParserErrorDomain =
    @"CPAJSONArrayObjectStreamParserErrorDomain";

typedef NS_ENUM(NSUInteger, CPAJSONArrayParserState) {
    CPAJSONArrayParserStateExpectArray = 1,
    CPAJSONArrayParserStateExpectFirstObjectOrEnd = 2,
    CPAJSONArrayParserStateExpectObject = 3,
    CPAJSONArrayParserStateInsideObject = 4,
    CPAJSONArrayParserStateExpectCommaOrEnd = 5,
    CPAJSONArrayParserStateFinished = 6,
};

static void CPASetJSONArrayError(NSError **error, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPAJSONArrayParserErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

static BOOL CPAIsJSONWhitespace(uint8_t byte) {
    return byte == (uint8_t)' ' || byte == (uint8_t)'\t'
        || byte == (uint8_t)'\r' || byte == (uint8_t)'\n';
}

@interface CPAJSONArrayObjectStreamParser ()
@property(nonatomic) NSUInteger maximumObjectBytes;
@property(nonatomic, copy) CPAJSONObjectHandler objectHandler;
@property(nonatomic) CPAJSONArrayParserState state;
@property(nonatomic, strong) NSMutableData *objectBuffer;
@property(nonatomic) NSInteger depth;
@property(nonatomic) BOOL insideString;
@property(nonatomic) BOOL escaped;
@end

@implementation CPAJSONArrayObjectStreamParser

- (instancetype)initWithMaximumObjectBytes:(NSUInteger)maximumObjectBytes
    objectHandler:(CPAJSONObjectHandler)objectHandler {
    self = [super init];
    if (self != nil) {
        _maximumObjectBytes = MAX((NSUInteger)1, maximumObjectBytes);
        _objectHandler = [objectHandler copy];
        _state = CPAJSONArrayParserStateExpectArray;
        _objectBuffer = [NSMutableData data];
    }
    return self;
}

- (BOOL)consumeData:(NSData *)data error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0, len = data.length; i < len; i++) {
        uint8_t byte = bytes[i];
        if (self.state == CPAJSONArrayParserStateExpectArray) {
            if (CPAIsJSONWhitespace(byte)) {
                continue;
            }
            if (byte != (uint8_t)'[') {
                CPASetJSONArrayError(error, @"conversations.json must be a top-level array");
                return NO;
            }
            self.state = CPAJSONArrayParserStateExpectFirstObjectOrEnd;
            continue;
        }
        if (self.state == CPAJSONArrayParserStateExpectFirstObjectOrEnd
            || self.state == CPAJSONArrayParserStateExpectObject) {
            if (CPAIsJSONWhitespace(byte)) {
                continue;
            }
            if (byte == (uint8_t)']'
                && self.state == CPAJSONArrayParserStateExpectFirstObjectOrEnd) {
                self.state = CPAJSONArrayParserStateFinished;
                continue;
            }
            if (byte != (uint8_t)'{') {
                CPASetJSONArrayError(error,
                    @"conversations.json array entries must be objects without trailing commas");
                return NO;
            }
            [self.objectBuffer setLength:0];
            [self.objectBuffer appendBytes:&byte length:1];
            self.depth = 1;
            self.insideString = NO;
            self.escaped = NO;
            self.state = CPAJSONArrayParserStateInsideObject;
            continue;
        }
        if (self.state == CPAJSONArrayParserStateInsideObject) {
            if (self.objectBuffer.length >= self.maximumObjectBytes) {
                CPASetJSONArrayError(error, @"A ChatGPT conversation exceeds the size limit");
                return NO;
            }
            [self.objectBuffer appendBytes:&byte length:1];
            if (self.insideString) {
                if (self.escaped) {
                    self.escaped = NO;
                } else if (byte == (uint8_t)'\\') {
                    self.escaped = YES;
                } else if (byte == (uint8_t)'"') {
                    self.insideString = NO;
                }
                continue;
            }
            if (byte == (uint8_t)'"') {
                self.insideString = YES;
            } else if (byte == (uint8_t)'{' || byte == (uint8_t)'[') {
                self.depth++;
            } else if (byte == (uint8_t)'}' || byte == (uint8_t)']') {
                self.depth--;
                if (self.depth < 0) {
                    CPASetJSONArrayError(error, @"Conversation JSON nesting is invalid");
                    return NO;
                }
                if (self.depth == 0) {
                    if (byte != (uint8_t)'}') {
                        CPASetJSONArrayError(error, @"Conversation array entry is not an object");
                        return NO;
                    }
                    NSError *handlerError = nil;
                    BOOL handled = self.objectHandler(self.objectBuffer, &handlerError);
                    if (!handled) {
                        if (error != NULL) {
                            *error = handlerError ?: [NSError
                                errorWithDomain:CPAJSONArrayParserErrorDomain code:1
                                userInfo:@{NSLocalizedDescriptionKey:
                                    @"Conversation handler rejected an object"}];
                        }
                        return NO;
                    }
                    self.state = CPAJSONArrayParserStateExpectCommaOrEnd;
                }
            }
            continue;
        }
        if (self.state == CPAJSONArrayParserStateExpectCommaOrEnd) {
            if (CPAIsJSONWhitespace(byte)) {
                continue;
            }
            if (byte == (uint8_t)',') {
                self.state = CPAJSONArrayParserStateExpectObject;
            } else if (byte == (uint8_t)']') {
                self.state = CPAJSONArrayParserStateFinished;
            } else {
                CPASetJSONArrayError(error, @"Conversation array separator is invalid");
                return NO;
            }
            continue;
        }
        if (self.state == CPAJSONArrayParserStateFinished && !CPAIsJSONWhitespace(byte)) {
            CPASetJSONArrayError(error, @"Unexpected bytes follow conversations.json array");
            return NO;
        }
    }
    return YES;
}

- (BOOL)finish:(NSError **)error {
    if (self.state != CPAJSONArrayParserStateFinished) {
        CPASetJSONArrayError(error, @"conversations.json is incomplete");
        return NO;
    }
    return YES;
}

@end
