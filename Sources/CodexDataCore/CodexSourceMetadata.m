#import "CodexSourceMetadata.h"

@implementation CPACodexSourceMetadata

- (instancetype)initWithThreadID:(NSString *)threadID
    threadSource:(NSString *)threadSource
    source:(NSString *)source
    cliVersion:(NSString *)cliVersion
    timestamp:(NSString *)timestamp
    workingDirectory:(NSString *)workingDirectory {
    self = [super init];
    if (self != nil) {
        _threadID = [threadID copy];
        _threadSource = [threadSource copy];
        _source = [source copy];
        _cliVersion = [cliVersion copy];
        _timestamp = [timestamp copy];
        _workingDirectory = [workingDirectory copy];
    }
    return self;
}

- (BOOL)isRootUserThread {
    return [self.threadSource isEqualToString:@"user"];
}

@end
