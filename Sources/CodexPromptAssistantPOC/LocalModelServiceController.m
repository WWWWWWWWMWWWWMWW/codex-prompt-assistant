#import "LocalModelServiceController.h"

#import <unistd.h>

#import "Diagnostics.h"

static NSString *const CPALocalModelServiceLabel =
    @"local.codex.prompt-assistant-model";

@interface CPALocalModelServiceController ()
@property(nonatomic) uid_t userID;
@property(nonatomic, copy) NSString *homeDirectory;
@end

@implementation CPALocalModelServiceController

+ (NSString *)serviceTargetForUserID:(uid_t)userID {
    return [NSString stringWithFormat:@"gui/%u/%@", userID,
        CPALocalModelServiceLabel];
}

+ (NSArray<NSString *> *)printArgumentsForUserID:(uid_t)userID {
    return @[@"print", [self serviceTargetForUserID:userID]];
}

+ (NSArray<NSString *> *)bootstrapArgumentsForUserID:(uid_t)userID
                                      homeDirectory:(NSString *)homeDirectory {
    NSString *domain = [NSString stringWithFormat:@"gui/%u", userID];
    NSString *plistPath = [homeDirectory stringByAppendingPathComponent:
        @"Library/LaunchAgents/local.codex.prompt-assistant-model.plist"];
    return @[@"bootstrap", domain, plistPath];
}

+ (NSArray<NSString *> *)bootoutArgumentsForUserID:(uid_t)userID {
    return @[@"bootout", [self serviceTargetForUserID:userID]];
}

- (instancetype)init {
    return [self initWithPreservesResidentModel:
        [NSProcessInfo.processInfo.arguments containsObject:@"--preserve-resident-model"]];
}

- (instancetype)initWithPreservesResidentModel:(BOOL)preservesResidentModel {
    self = [super init];
    if (self != nil) {
        _preservesResidentModel = preservesResidentModel;
        _userID = getuid();
        _homeDirectory = [NSHomeDirectory() copy];
    }
    return self;
}

- (int)runLaunchctlWithArguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        return -1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

- (BOOL)ensureRunning {
    int printStatus = [self runLaunchctlWithArguments:
        [self.class printArgumentsForUserID:self.userID]];
    if (printStatus == 0) {
        CPADiagnosticLog(@"local_model_service ensure=already_loaded status=0");
        return YES;
    }
    if (self.preservesResidentModel) {
        CPADiagnosticLog(@"local_model_service ensure=preserved_unavailable status=%d", printStatus);
        return NO;
    }
    int bootstrapStatus = [self runLaunchctlWithArguments:
        [self.class bootstrapArgumentsForUserID:self.userID
            homeDirectory:self.homeDirectory]];
    CPADiagnosticLog(@"local_model_service ensure=bootstrap status=%d",
        bootstrapStatus);
    return bootstrapStatus == 0;
}

- (BOOL)stop {
    if (self.preservesResidentModel) {
        CPADiagnosticLog(@"local_model_service stop=blocked_update_launch");
        return NO;
    }
    int status = [self runLaunchctlWithArguments:
        [self.class bootoutArgumentsForUserID:self.userID]];
    CPADiagnosticLog(@"local_model_service stop status=%d", status);
    // A missing service is already in the desired fully stopped state.
    return status == 0 || status == 3;
}

@end
