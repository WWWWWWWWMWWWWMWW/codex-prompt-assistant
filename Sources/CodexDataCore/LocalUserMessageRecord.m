#import "LocalUserMessageRecord.h"

@interface CPALocalUserMessageRecord ()
@property(nonatomic, readwrite) int64_t messageRowID;
@property(nonatomic, readwrite) int64_t conversationRowID;
@property(nonatomic, copy, readwrite) NSString *sourceTimestamp;
@property(nonatomic, copy, readwrite) NSString *text;
@property(nonatomic, readwrite) BOOL containsSensitiveData;
@end

@implementation CPALocalUserMessageRecord

- (instancetype)initWithMessageRowID:(int64_t)messageRowID
    conversationRowID:(int64_t)conversationRowID
    sourceTimestamp:(NSString *)sourceTimestamp
    text:(NSString *)text
    containsSensitiveData:(BOOL)containsSensitiveData {
    self = [super init];
    if (self != nil) {
        _messageRowID = messageRowID;
        _conversationRowID = conversationRowID;
        _sourceTimestamp = [sourceTimestamp copy];
        _text = [text copy];
        _containsSensitiveData = containsSensitiveData;
    }
    return self;
}

@end
