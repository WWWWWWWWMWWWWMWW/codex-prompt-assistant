#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CPACodexMessageRole) {
    CPACodexMessageRoleUser = 1,
    CPACodexMessageRoleAssistant = 2,
};

@interface CPACodexMessage : NSObject

@property(nonatomic, copy, readonly) NSString *messageID;
@property(nonatomic, copy, readonly) NSString *timestamp;
@property(nonatomic, readonly) CPACodexMessageRole role;
@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, readonly) NSUInteger sourceLineNumber;
@property(nonatomic, readonly) uint64_t sourceByteOffset;

- (instancetype)initWithMessageID:(NSString *)messageID
    timestamp:(NSString *)timestamp
    role:(CPACodexMessageRole)role
    text:(NSString *)text
    sourceLineNumber:(NSUInteger)sourceLineNumber
    sourceByteOffset:(uint64_t)sourceByteOffset NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
