#import <AppKit/AppKit.h>

#import "../../Sources/CodexPromptAssistantPOC/ApplicationMenu.h"

static void CPARequire(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        CPARequire([CPALastCompletionStatusText(CPARemoteCompletionOutcomeSuccess, @"no_suggestion_boundary", NO)
            isEqual:@"输入已完整或当前位置不适合续写"], @"boundary stop explains why no suggestion was requested");
        CPARequire([CPALastCompletionStatusText(CPARemoteCompletionOutcomeSuccess, @"no_suggestion_insufficient_context", NO)
            isEqual:@"可用上下文不足"], @"missing context is separate from a provider failure");
        CPARequire([CPALastCompletionStatusText(CPARemoteCompletionOutcomeTimedOut, @"completion", NO)
            isEqual:@"等待服务超时"], @"timeout is not normal model abstention");
        CPARequire([CPALastCompletionStatusText(CPARemoteCompletionOutcomeSuccess, @"no_suggestion_rejected", NO)
            isEqual:@"候选被规则拒绝或响应不完整"], @"rejected content is separate from an empty suffix");
        CPARequire([CPALastCompletionStatusText(CPARemoteCompletionOutcomeSuccess, @"explicit_user_scope", YES)
            isEqual:@"已生成字面候选，尚需显示检查"], @"literal success must not claim a model response or actual display");
        CPARequire([CPALastCompletionStatusText(CPARemoteCompletionOutcomeCancelled, @"explicit_option", NO)
            isEqual:@"请求已取消"], @"cancellation takes precedence over generation phase");
        CPARequire([CPALastCompletionStatusText(CPARemoteCompletionOutcomeSuccess, @"fixture-private-value", NO)
            isEqual:@"本次未产生可用候选"], @"unknown phase text is not copied into the menu");
        NSMenu *mainMenu = CPACreateApplicationMainMenu();
        NSMenuItem *editRoot = [mainMenu itemWithTitle:@"编辑"];
        CPARequire(editRoot != nil, @"main menu should include Edit");

        NSMenuItem *pasteItem = [editRoot.submenu itemWithTitle:@"粘贴"];
        CPARequire(pasteItem != nil, @"Edit menu should include Paste");
        CPARequire(pasteItem.action == @selector(paste:),
            @"Paste should use the standard responder-chain action");
        CPARequire([pasteItem.keyEquivalent isEqualToString:@"v"],
            @"Paste should use Command-V");
        CPARequire((pasteItem.keyEquivalentModifierMask & NSEventModifierFlagCommand) != 0,
            @"Paste should require Command");

        NSMenuItem *applicationRoot = [mainMenu itemWithTitle:@"应用"];
        NSMenuItem *settings = [applicationRoot.submenu itemWithTitle:@"设置…"];
        CPARequire(settings.action == @selector(showRemoteSettings:) && [settings.keyEquivalent isEqual:@","],
            @"settings should use the standard Command-Comma entry");
        NSMenuItem *pauseItem = [applicationRoot.submenu itemWithTitle:@"暂停提示（本次运行）"];
        CPARequire(pauseItem == nil, @"online edition has no second pause setting");
        NSMenuItem *quitItem = [applicationRoot.submenu
            itemWithTitle:@"退出续言"];
        CPARequire(quitItem != nil && quitItem.action == @selector(terminate:),
            @"the application menu should use a user-facing full-exit label");

        CPARequire([CPAApplicationPolicyScopeTitle(@"备忘录",
                @"com.apple.Notes", @"")
                isEqualToString:@"当前应用：备忘录"],
            @"ordinary applications should use an application-scoped title");
        CPARequire([CPAApplicationPolicyScopeTitle(@"Google Chrome",
                @"com.google.Chrome", @"docs.example.com")
                isEqualToString:@"当前站点：docs.example.com"],
            @"browsers should display the exact configurable hostname");
        CPARequire([CPAApplicationPolicyScopeTitle(@"Google Chrome",
                @"com.google.Chrome", @"")
                isEqualToString:@"当前站点：未识别（保持关闭）"],
            @"unknown browser sites should explain why controls are unavailable");
        CPARequire(CPAApplicationPolicyScopeCanBeConfigured(
                @"com.apple.Notes", @""),
            @"ordinary applications should be configurable");
        CPARequire(!CPAApplicationPolicyScopeCanBeConfigured(
                @"com.google.Chrome", @""),
            @"browser rules must require an exact hostname");
        CPARequire(!CPAApplicationPolicyScopeCanBeConfigured(
                @"com.apple.SecurityAgent", @""),
            @"system authorization applications must not be configurable");
        NSLog(@"PASS: ApplicationMenuTests");
    }
    return 0;
}
