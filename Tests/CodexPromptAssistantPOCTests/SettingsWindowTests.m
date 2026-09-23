#import <AppKit/AppKit.h>
#import "../../Sources/CodexPromptAssistantPOC/OnlineScopeDefaults.h"
#import "../../Sources/CodexPromptAssistantPOC/SettingsWindowController.h"
@interface CPASettingsWindowController (Testing)
- (void)saveService:(id)sender;
- (void)toggleOnline:(NSButton *)sender;
- (void)toggleScope:(NSButton *)sender;
@end
#define Check(x) do { if (!(x)) { NSLog(@"FAIL settings line %d", __LINE__); exit(1); } } while (0)
static void Collect(NSView *view, NSMutableArray *buttons, NSMutableArray *fields) {
    if ([view isKindOfClass:NSButton.class]) [buttons addObject:view];
    if ([view isKindOfClass:NSTextField.class] && [(NSTextField *)view isEditable]) [fields addObject:view];
    for (NSView *child in view.subviews) Collect(child, buttons, fields);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSMutableDictionary *state = [@{@"remote":@NO,@"configured":@YES,@"permission":@YES} mutableCopy];
    NSMutableDictionary *selected = [NSMutableDictionary new];
    __block NSUInteger calls = 0; __block BOOL rejectSave = YES;
    CPASettingsWindowController *controller = [[CPASettingsWindowController alloc]
        initWithStateProvider:^NSDictionary *{ return state; }
        actionHandler:^NSString *(NSString *action, NSDictionary *values) {
            calls++;
            if ([action isEqual:@"service"]) {
                Check([values[@"key"] isEqual:@"synthetic-key-never-real"]);
                Check(values[@"model"] == nil);
                return rejectSave ? @"合成保存失败" : nil;
            }
            if ([action isEqual:@"remote"]) {
                if (![state[@"configured"] boolValue]) return @"请先填写 API Key。";
                state[@"remote"] = values[@"enabled"];
            }
            if ([action isEqual:@"scope"]) selected[values[@"title"]] = values[@"enabled"];
            return nil;
        } ruleProvider:^NSDictionary *(NSDictionary *target) {
            BOOL yes = [selected[target[@"title"]] boolValue];
            return @{@"mode":yes ? @1 : @2, @"remote":@(yes)};
        }];
    [controller presentWithRuleTargets:@[@{@"bundle":@"com.openai.codex",@"host":@"",@"title":@"Codex"},
        @{@"bundle":@"com.apple.TextEdit",@"host":@"",@"title":@"文本编辑"},
        @{@"bundle":@"com.apple.Stickies",@"host":@"",@"title":@"便笺（Stickies）"},
        @{@"bundle":@"com.apple.Terminal",@"host":@"",@"title":@"终端"},
        @{@"bundle":@"com.apple.freeform",@"host":@"",@"title":@"无边记"},
        @{@"bundle":@"com.electron.lark",@"host":@"",@"title":@"飞书（含网页版）"},
        @{@"bundle":@"com.kingsoft.wpsoffice.mac",@"host":@"",@"title":@"WPS Office"},
        @{@"bundle":@"com.tencent.workbuddy.mac",@"host":@"",@"title":@"WorkBuddy"},
        @{@"bundle":@"com.tencent.codebuddy",@"host":@"",@"title":@"CodeBuddy"},
        @{@"bundle":@"com.tencent.xinWeChat",@"host":@"",@"title":@"微信"}]];
    Check(calls == 0);
    NSSecureTextField *key = [controller valueForKey:@"keyField"];
    Check(key.stringValue.length == 0);
    [controller saveService:nil]; Check(calls == 0);
    key.stringValue = @"synthetic-key-never-real"; [controller refreshState];
    Check([key.stringValue isEqual:@"synthetic-key-never-real"]);
    [controller saveService:nil]; Check(key.stringValue.length > 0);
    rejectSave = NO; [controller saveService:nil]; Check(key.stringValue.length == 0);
    NSButton *online = [controller valueForKey:@"onlineSwitch"];
    state[@"configured"] = @NO; online.state = NSControlStateValueOn; [controller toggleOnline:online];
    Check(online.state == NSControlStateValueOff);
    state[@"configured"] = @YES; online.state = NSControlStateValueOn; [controller toggleOnline:online];
    Check([state[@"remote"] boolValue]);
    NSArray<NSButton *> *scopes = [controller valueForKey:@"scopeButtons"];
    Check(scopes.count == 10);
    for (NSButton *scope in scopes) Check(NSContainsRect(scope.superview.bounds, scope.frame));
    scopes[0].state = NSControlStateValueOn; [controller toggleScope:scopes[0]];
    scopes[1].state = NSControlStateValueOn; [controller toggleScope:scopes[1]];
    Check(scopes[0].state == NSControlStateValueOn && scopes[1].state == NSControlStateValueOn && scopes[2].state == NSControlStateValueOff);
    scopes[0].state = NSControlStateValueOff; [controller toggleScope:scopes[0]];
    Check(scopes[1].state == NSControlStateValueOn);
    NSMutableArray *buttons = [NSMutableArray new], *fields = [NSMutableArray new];
    Collect(controller.window.contentView, buttons, fields);
    Check(fields.count == 1 && fields.firstObject == key);
    for (NSButton *button in buttons) Check(![button.title containsString:@"本地"] && ![button.title containsString:@"高级"] && ![button.title containsString:@"历史"] && ![button.title containsString:@"网站"] && ![button.title isEqual:@"App Store"]);
    key.stringValue = @"unsaved-synthetic";
    [controller windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:controller.window]];
    Check(key.stringValue.length == 0);
    if ((argc == 2 && strcmp(argv[1],"--showcase") == 0) || [NSBundle.mainBundle.bundleIdentifier isEqual:@"local.codex.settings-preview"]) {
        [selected removeAllObjects];
        NSDictionary *initial = CPAOnlineScopesWithInstallationDefaults(nil)[@"applications"];
        for (NSDictionary *target in [controller valueForKey:@"targets"])
            selected[target[@"title"]] = @([initial[target[@"bundle"]] boolValue]);
        [controller presentWithRuleTargets:[controller valueForKey:@"targets"]]; [NSApp run];
    }
    [controller close]; NSLog(@"PASS settings: only 3 groups, secure key save/retry/clear, independent multiselect, provider refresh, prerequisite.");
} return 0; }
