#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPALocalUserMessageRecord : NSObject

@property(nonatomic, readonly) int64_t messageRowID;
@property(nonatomic, readonly) int64_t conversationRowID;
@property(nonatomic, copy, readonly) NSString *sourceTimestamp;
@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, readonly) BOOL containsSensitiveData;

- (instancetype)initWithMessageRowID:(int64_t)messageRowID
    conversationRowID:(int64_t)conversationRowID
    sourceTimestamp:(NSString *)sourceTimestamp
    text:(NSString *)text
    containsSensitiveData:(BOOL)containsSensitiveData NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
