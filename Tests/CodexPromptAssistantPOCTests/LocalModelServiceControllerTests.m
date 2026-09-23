#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/LocalModelServiceController.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

@interface FixtureModelServiceController : CPALocalModelServiceController
@property(nonatomic) int printStatus;
@property(nonatomic) int actionStatus;
@property(nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *commands;
@end

@implementation FixtureModelServiceController
- (int)runLaunchctlWithArguments:(NSArray<NSString *> *)arguments {
    if (self.commands == nil) self.commands = [NSMutableArray array];
    [self.commands addObject:arguments];
    return [arguments.firstObject isEqualToString:@"print"] ? self.printStatus : self.actionStatus;
}
@end

int main(void) {
    @autoreleasepool {
        uid_t uid = 501;
        NSString *home = @"/Users/tester";
        NSArray<NSString *> *bootout = [CPALocalModelServiceController
            bootoutArgumentsForUserID:uid];
        NSArray<NSString *> *bootstrap = [CPALocalModelServiceController
            bootstrapArgumentsForUserID:uid homeDirectory:home];
        NSArray<NSString *> *printArguments = [CPALocalModelServiceController
            printArgumentsForUserID:uid];
        Assert([bootout isEqualToArray:@[
                @"bootout", @"gui/501/local.codex.prompt-assistant-model"]],
            @"explicit model-stop command must target only the helper-owned model service");
        Assert([bootstrap isEqualToArray:@[
                @"bootstrap", @"gui/501",
                @"/Users/tester/Library/LaunchAgents/local.codex.prompt-assistant-model.plist"]],
            @"reopen must bootstrap the installed local model service without a shell");
        Assert([printArguments isEqualToArray:@[
                @"print", @"gui/501/local.codex.prompt-assistant-model"]],
            @"service availability should use the exact helper-owned label");
        NSString *joined = [[bootout arrayByAddingObjectsFromArray:bootstrap]
            componentsJoinedByString:@" "];
        Assert([joined rangeOfString:@"com.openai.codex"].location == NSNotFound
                && [joined rangeOfString:@"/Applications/ChatGPT"].location == NSNotFound,
            @"local model lifecycle commands must never target Codex or ChatGPT");

        FixtureModelServiceController *protected = [[FixtureModelServiceController alloc]
            initWithPreservesResidentModel:YES];
        Assert(protected.preservesResidentModel, @"update launch protection must be explicit and immutable");
        for (NSNumber *status in @[@0, @3, @(-1), @5]) {
            protected.printStatus = status.intValue;
            [protected.commands removeAllObjects];
            Assert([protected ensureRunning] == (status.intValue == 0),
                @"protected launch should report only an already loaded model as available");
            Assert(protected.commands.count == 1
                && [protected.commands.firstObject.firstObject isEqualToString:@"print"],
                @"missing or uncertain model must never bootstrap during protected launch");
        }
        [protected.commands removeAllObjects];
        Assert(![protected stop] && protected.commands.count == 0,
            @"protected controller must never stop the resident model");

        FixtureModelServiceController *normal = [[FixtureModelServiceController alloc]
            initWithPreservesResidentModel:NO];
        normal.printStatus = 3;
        Assert([normal ensureRunning] && normal.commands.count == 2
            && [normal.commands.lastObject.firstObject isEqualToString:@"bootstrap"],
            @"ordinary launches retain explicit local service startup behavior");
        normal.actionStatus = 5;
        Assert(![normal ensureRunning], @"ordinary bootstrap failure must remain visible");
        normal.actionStatus = 3;
        Assert([normal stop], @"ordinary stop preserves already absent service semantics");

        FixtureModelServiceController *fromArguments = [[FixtureModelServiceController alloc] init];
        BOOL protectedArgument = [NSProcessInfo.processInfo.arguments containsObject:@"--preserve-resident-model"];
        Assert(fromArguments.preservesResidentModel == protectedArgument,
            @"production initializer must honor only the explicit update argument");
        NSLog(@"PASS: LocalModelServiceControllerTests");
    }
    return 0;
}
