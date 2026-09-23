#import "CodexMessage.h"

@implementation CPACodexMessage

- (instancetype)initWithMessageID:(NSString *)messageID
    timestamp:(NSString *)timestamp
    role:(CPACodexMessageRole)role
    text:(NSString *)text
    sourceLineNumber:(NSUInteger)sourceLineNumber
    sourceByteOffset:(uint64_t)sourceByteOffset {
    self = [super init];
    if (self != nil) {
        _messageID = [messageID copy];
        _timestamp = [timestamp copy];
        _role = role;
        _text = [text copy];
        _sourceLineNumber = sourceLineNumber;
        _sourceByteOffset = sourceByteOffset;
    }
    return self;
}

@end
