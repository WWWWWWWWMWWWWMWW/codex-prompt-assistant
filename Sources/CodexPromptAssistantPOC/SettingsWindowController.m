#import "SettingsWindowController.h"

@interface CPAScopeListView : NSView
@end
@implementation CPAScopeListView
- (BOOL)isFlipped { return YES; }
@end

@interface CPASettingsWindowController ()
@property(nonatomic, copy) CPASettingsStateProvider stateProvider;
@property(nonatomic, copy) CPASettingsActionHandler actionHandler;
@property(nonatomic, copy) CPASettingsRuleProvider ruleProvider;
@property(nonatomic, strong) NSButton *onlineSwitch;
@property(nonatomic, strong) NSSecureTextField *keyField;
@property(nonatomic, strong) NSTextField *keyStatus;
@property(nonatomic, strong) NSTextField *notice;
@property(nonatomic, strong) NSButton *permissionButton;
@property(nonatomic, strong) NSScrollView *scopeScroll;
@property(nonatomic, strong) NSArray<NSDictionary *> *targets;
@property(nonatomic, strong) NSMutableArray<NSButton *> *scopeButtons;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, copy) NSString *lastResult;
@end

@implementation CPASettingsWindowController
- (instancetype)initWithStateProvider:(CPASettingsStateProvider)stateProvider
    actionHandler:(CPASettingsActionHandler)actionHandler ruleProvider:(CPASettingsRuleProvider)ruleProvider {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,580,650)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        _stateProvider = [stateProvider copy]; _actionHandler = [actionHandler copy]; _ruleProvider = [ruleProvider copy];
        _targets = @[]; _scopeButtons = [NSMutableArray new];
        window.title = @"续言 · 设置"; window.delegate = self; window.releasedWhenClosed = NO;
        [self buildInterface]; [window center]; [self refreshState];
    }
    return self;
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size secondary:(BOOL)secondary {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = frame; label.font = [NSFont systemFontOfSize:size weight:size >= 18 ? NSFontWeightSemibold : NSFontWeightRegular];
    label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    [self.window.contentView addSubview:label]; return label;
}
- (void)buildInterface {
    [self label:@"写到一半，续言帮你接下去" frame:NSMakeRect(28,594,524,30) size:22 secondary:NO];
    self.onlineSwitch = [NSButton checkboxWithTitle:@"在线续写" target:self action:@selector(toggleOnline:)];
    self.onlineSwitch.frame = NSMakeRect(28,551,220,28); [self.window.contentView addSubview:self.onlineSwitch];
    [self label:@"API Key" frame:NSMakeRect(28,514,200,22) size:14 secondary:NO];
    self.keyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(28,476,420,28)];
    self.keyField.placeholderString = @"输入 API Key"; self.keyField.accessibilityLabel = @"API Key";
    [self.window.contentView addSubview:self.keyField];
    NSButton *save = [NSButton buttonWithTitle:@"保存" target:self action:@selector(saveService:)];
    save.frame = NSMakeRect(460,475,92,30); save.bezelStyle = NSBezelStyleRounded; [self.window.contentView addSubview:save];
    self.keyStatus = [self label:@"" frame:NSMakeRect(28,448,524,22) size:12 secondary:YES];
    [self label:@"使用范围（可多选）" frame:NSMakeRect(28,403,370,26) size:18 secondary:NO];
    [self label:@"勾选后立即生效，只续写当前正在输入的位置。\n该范围的输入与可用任务上下文会发送到在线服务。\n未选范围不读取正文、不联网；全部取消则不续写。"
        frame:NSMakeRect(28,331,524,65) size:13 secondary:YES];
    self.scopeScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(28,139,524,185)];
    self.scopeScroll.hasVerticalScroller = NO; self.scopeScroll.borderType = NSBezelBorder;
    [self.window.contentView addSubview:self.scopeScroll];
    [self label:@"飞书含客户端和浏览器中的飞书文档，其他网站不生效。密码、搜索框等位置不续写。Tab 接受，Esc 忽略，不会自动发送。"
        frame:NSMakeRect(28,86,524,44) size:12 secondary:YES];
    self.notice = [self label:@"" frame:NSMakeRect(28,18,386,58) size:12 secondary:YES];
    self.permissionButton = [NSButton buttonWithTitle:@"允许辅助功能…" target:self action:@selector(requestPermission:)];
    self.permissionButton.frame = NSMakeRect(420,32,138,32); self.permissionButton.bezelStyle = NSBezelStyleRounded;
    [self.window.contentView addSubview:self.permissionButton];
}
- (void)presentWithRuleTargets:(NSArray<NSDictionary *> *)targets {
    self.targets = [targets copy]; [self rebuildScopes]; [self refreshState];
    [self showWindow:nil]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self.refreshTimer invalidate];
    __weak CPASettingsWindowController *owner = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer; [owner refreshState];
    }];
}
- (void)rebuildScopes {
    [self.scopeButtons removeAllObjects];
    NSView *list = [[CPAScopeListView alloc] initWithFrame:NSMakeRect(0,0,502,MAX(180,((self.targets.count + 1) / 2) * 32 + 12))];
    for (NSUInteger index=0; index<self.targets.count; index++) {
        NSButton *button = [NSButton checkboxWithTitle:self.targets[index][@"title"] ?: @"应用" target:self action:@selector(toggleScope:)];
        button.tag = index; button.frame = NSMakeRect(10 + (index % 2) * 252,6 + 32 * (index / 2),240,28);
        button.toolTip = [self.targets[index][@"host"] length] ? self.targets[index][@"host"] : self.targets[index][@"bundle"];
        [list addSubview:button]; [self.scopeButtons addObject:button];
    }
    self.scopeScroll.documentView = list;
}
- (void)refreshState {
    NSDictionary *state = self.stateProvider();
    self.onlineSwitch.state = [state[@"remote"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.keyField.placeholderString = [state[@"configured"] boolValue] ? @"已保存；输入新 Key 可替换" : @"输入 API Key";
    self.keyStatus.stringValue = [state[@"configured"] boolValue]
        ? @"Key 已保存在本机（不回显）；服务：sapi-ai.hortorgames.com"
        : @"请使用 sapi-ai.hortorgames.com 的 Key，其他服务的 Key 不通用。";
    for (NSButton *button in self.scopeButtons) {
        NSDictionary *rule = self.ruleProvider(self.targets[button.tag]);
        button.state = [rule[@"mode"] integerValue] == 1 && [rule[@"remote"] boolValue]
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    NSString *result = state[@"remoteResult"];
    if (result.length && ![result isEqual:self.lastResult]) {
        self.lastResult = result;
        self.notice.stringValue = result;
    }
    self.permissionButton.hidden = [state[@"permission"] boolValue];
    if (!self.permissionButton.hidden) self.notice.stringValue = @"首次使用需要允许辅助功能，才能显示并插入续写。";
    else if ([self.notice.stringValue hasPrefix:@"首次使用需要"]) self.notice.stringValue = @"";
}
- (void)toggleOnline:(NSButton *)sender {
    NSString *error = self.actionHandler(@"remote", @{@"enabled":@(sender.state == NSControlStateValueOn)});
    self.notice.stringValue = error ?: @"已立即生效。"; [self refreshState];
    if (error) [self.window makeFirstResponder:self.keyField];
}
- (void)saveService:(id)sender {
    (void)sender;
    NSString *key = [self.keyField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!key.length) { self.notice.stringValue = @"请输入 API Key。"; return; }
    NSString *error = self.actionHandler(@"service", @{@"key":key});
    if (!error) self.keyField.stringValue = @"";
    self.notice.stringValue = error ?: @"Key 已保存；服务有效性将在实际续写时检查。";
    [self refreshState];
}
- (void)toggleScope:(NSButton *)sender {
    NSMutableDictionary *values = [self.targets[sender.tag] mutableCopy];
    values[@"enabled"] = @(sender.state == NSControlStateValueOn);
    NSString *error = self.actionHandler(@"scope", values);
    self.notice.stringValue = error ?: @"范围已生效；取消勾选会同时清除旧候选。"; [self refreshState];
}
- (void)requestPermission:(id)sender { (void)sender; self.actionHandler(@"permission", @{}); }
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification; self.keyField.stringValue = @""; [self.refreshTimer invalidate]; self.refreshTimer = nil;
}
@end
