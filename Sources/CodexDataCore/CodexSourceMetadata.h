#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPACodexSourceMetadata : NSObject

@property(nonatomic, copy, readonly) NSString *threadID;
@property(nonatomic, copy, readonly) NSString *threadSource;
@property(nonatomic, copy, readonly) NSString *source;
@property(nonatomic, copy, readonly) NSString *cliVersion;
@property(nonatomic, copy, readonly) NSString *timestamp;
@property(nonatomic, copy, readonly) NSString *workingDirectory;
@property(nonatomic, readonly) BOOL isRootUserThread;

- (instancetype)initWithThreadID:(NSString *)threadID
    threadSource:(NSString *)threadSource
    source:(NSString *)source
    cliVersion:(NSString *)cliVersion
    timestamp:(NSString *)timestamp
    workingDirectory:(NSString *)workingDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
