#import "ApplicationMenu.h"

#import "SuggestionPolicy.h"

NSString *CPALastCompletionStatusText(CPARemoteCompletionOutcome outcome, NSString *phase, BOOL hasCandidate) {
    switch (outcome) {
        case CPARemoteCompletionOutcomeCancelled: return @"请求已取消";
        case CPARemoteCompletionOutcomeNotConfigured: return @"服务尚未配置";
        case CPARemoteCompletionOutcomeCircuitOpen: return @"服务暂时冷却";
        case CPARemoteCompletionOutcomeTimedOut: return @"等待服务超时";
        case CPARemoteCompletionOutcomeUnauthorized: return @"服务身份验证失败";
        case CPARemoteCompletionOutcomeRateLimited: return @"服务请求受限";
        case CPARemoteCompletionOutcomeServerError: return @"服务端出错";
        case CPARemoteCompletionOutcomeTransportError: return @"无法连接服务";
        case CPARemoteCompletionOutcomeInvalidResponse: return @"服务响应无法解析";
        case CPARemoteCompletionOutcomeSuccess: break;
        default: return @"请求状态未知";
    }
    if (hasCandidate) {
        return [@[@"explicit_option", @"explicit_user_scope"] containsObject:phase]
            ? @"已生成字面候选，尚需显示检查" : @"已生成候选，尚需显示检查";
    }
    NSDictionary *reasons = @{
        @"no_suggestion_boundary":@"输入已完整或当前位置不适合续写",
        @"no_suggestion_insufficient_context":@"可用上下文不足",
        @"no_suggestion_invalid_context":@"上下文格式异常，已停止补全",
        @"no_suggestion_local_low_value":@"当前内容未通过本地候选规则",
        @"no_suggestion_too_short":@"候选未满足完整性要求",
        @"no_suggestion_rejected":@"候选被规则拒绝或响应不完整",
        @"no_suggestion":@"服务未返回可用续写"};
    return reasons[phase ?: @""] ?: @"本次未产生可用候选";
}

NSString *CPAApplicationPolicyScopeTitle(
    NSString *applicationName,
    NSString *bundleIdentifier,
    NSString *browserHost
) {
    if (CPASuggestionPolicyApplicationIsBrowser(bundleIdentifier)) {
        return browserHost.length > 0
            ? [NSString stringWithFormat:@"当前站点：%@", browserHost]
            : @"当前站点：未识别（保持关闭）";
    }
    NSString *name = applicationName.length > 0 ? applicationName : @"当前应用";
    return [NSString stringWithFormat:@"当前应用：%@", name];
}

BOOL CPAApplicationPolicyScopeCanBeConfigured(
    NSString *bundleIdentifier,
    NSString *browserHost
) {
    CPAApplicationDefaultPolicyClass policyClass =
        CPASuggestionPolicyDefaultClassForApplication(bundleIdentifier);
    if (policyClass == CPAApplicationDefaultPolicyClassPermanentlyBlocked) {
        return NO;
    }
    return policyClass != CPAApplicationDefaultPolicyClassBrowser
        || browserHost.length > 0;
}

static NSMenuItem *CPAMenuItem(
    NSString *title,
    SEL action,
    NSString *keyEquivalent,
    NSEventModifierFlags modifierMask
) {
    NSMenuItem *item = [[NSMenuItem alloc]
        initWithTitle:title action:action keyEquivalent:keyEquivalent];
    item.keyEquivalentModifierMask = modifierMask;
    return item;
}

NSMenu *CPACreateApplicationMainMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *applicationRoot = [[NSMenuItem alloc] initWithTitle:@"应用"
        action:nil keyEquivalent:@""];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"应用"];
    [applicationMenu addItem:CPAMenuItem(
        @"设置…", @selector(showRemoteSettings:), @",", NSEventModifierFlagCommand
    )];
    [applicationMenu addItem:NSMenuItem.separatorItem];
    [applicationMenu addItem:CPAMenuItem(
        @"退出续言",
        @selector(terminate:),
        @"q",
        NSEventModifierFlagCommand
    )];
    applicationRoot.submenu = applicationMenu;
    [mainMenu addItem:applicationRoot];

    NSMenuItem *editRoot = [[NSMenuItem alloc] initWithTitle:@"编辑"
        action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItem:CPAMenuItem(
        @"撤销", @selector(undo:), @"z", NSEventModifierFlagCommand
    )];
    [editMenu addItem:CPAMenuItem(
        @"重做",
        @selector(redo:),
        @"z",
        NSEventModifierFlagCommand | NSEventModifierFlagShift
    )];
    [editMenu addItem:NSMenuItem.separatorItem];
    [editMenu addItem:CPAMenuItem(
        @"剪切", @selector(cut:), @"x", NSEventModifierFlagCommand
    )];
    [editMenu addItem:CPAMenuItem(
        @"复制", @selector(copy:), @"c", NSEventModifierFlagCommand
    )];
    [editMenu addItem:CPAMenuItem(
        @"粘贴", @selector(paste:), @"v", NSEventModifierFlagCommand
    )];
    [editMenu addItem:CPAMenuItem(
        @"全选", @selector(selectAll:), @"a", NSEventModifierFlagCommand
    )];
    editRoot.submenu = editMenu;
    [mainMenu addItem:editRoot];

    return mainMenu;
}
