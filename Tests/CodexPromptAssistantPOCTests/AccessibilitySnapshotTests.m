#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        CPAAccessibilitySnapshot *missingPermission = [[CPAAccessibilitySnapshot alloc] init];
        missingPermission.permissionGranted = NO;
        missingPermission.codexIsRunning = YES;
        missingPermission.codexIsFrontmost = YES;
        Assert([missingPermission.summary isEqualToString:@"尚未获得辅助功能权限"],
            @"权限缺失应优先报告");

        CPAAccessibilitySnapshot *writable = [[CPAAccessibilitySnapshot alloc] init];
        writable.permissionGranted = YES;
        writable.codexIsRunning = YES;
        writable.codexIsFrontmost = YES;
        writable.focusedRole = @"AXTextArea";
        writable.hasSelectedRange = YES;
        writable.selectedLocation = 12;
        writable.selectedLength = 0;
        writable.writableTextInput = YES;
        writable.hasValueCharacterCount = YES;
        writable.valueCharacterCount = 22;
        writable.inputText = @"private-snapshot-value";
        writable.composerIdentifier = @"private-node-identifier";
        writable.conversationTitle = @"private-conversation-title";
        writable.diagnostic = @"valueLength=22";
        Assert([writable.summary containsString:@"已找到可写输入框"],
            @"应报告已找到输入框");
        Assert([writable.summary containsString:@"位置 12"],
            @"摘要应包含选区位置");
        Assert([writable.summary rangeOfString:writable.inputText].location == NSNotFound
                && [writable.diagnostic rangeOfString:writable.inputText].location
                    == NSNotFound,
            @"输入框正文只能短暂保存，不得出现在摘要或诊断");
        Assert([writable.summary rangeOfString:writable.composerIdentifier].location
                    == NSNotFound
                && [writable.summary rangeOfString:writable.conversationTitle].location
                    == NSNotFound,
            @"对话标识和标题不得出现在用户可见摘要中");

        CPAAccessibilitySnapshot *rendererUnavailable =
            [[CPAAccessibilitySnapshot alloc] init];
        rendererUnavailable.permissionGranted = YES;
        rendererUnavailable.codexIsRunning = YES;
        rendererUnavailable.codexIsFrontmost = YES;
        rendererUnavailable.rendererAccessibilitySuspected = YES;
        Assert([rendererUnavailable.summary containsString:@"窗口输入降级"],
            @"连续拿不到输入框时应提示无需重启 Codex 的降级路径");
        writable.hasCaretBounds = YES;
        writable.caretBounds = CGRectMake(100, 200, 1, 18);
        Assert(CGRectGetMinX(writable.caretBounds) == 100,
            @"应保存光标矩形而不改变坐标");
        Assert([CPAAccessibilitySnapshot isUsableCaretBounds:CGRectMake(100, 200, 0, 18)],
            @"零宽但有高度的系统光标矩形应视为可用");
        Assert(![CPAAccessibilitySnapshot isUsableCaretBounds:CGRectMake(0, 1080, 0, 0)],
            @"Codex 返回的零尺寸占位矩形不能视为可用光标坐标");
        NSInteger effectiveLocation = [CPAAccessibilitySnapshot
            effectiveSelectedLocationForReportedLocation:0
            selectedLength:0
            valueLength:5
            hasUsableCaretBounds:NO];
        Assert(effectiveLocation == 5,
            @"Codex 把无坐标的非空输入光标报告为 0 时应降级到句尾");
        effectiveLocation = [CPAAccessibilitySnapshot
            effectiveSelectedLocationForReportedLocation:0
            selectedLength:0
            valueLength:5
            hasUsableCaretBounds:YES];
        Assert(effectiveLocation == 0,
            @"真实光标坐标可用时必须保留开头光标");

        CPAAccessibilitySnapshot *fallback = [[CPAAccessibilitySnapshot alloc] init];
        fallback.hasCaretBounds = NO;
        fallback.hasElementFrame = YES;
        fallback.elementFrame = CGRectMake(200, 700, 600, 120);
        Assert(fallback.hasSuggestionAnchor,
            @"拿不到光标坐标时，输入框整体边界应作为候选条锚点");

        CGRect windowFrame = CGRectMake(4, 25, 1900, 968);
        CGRect conservativeFrame = [CPAAccessibilitySnapshot
            conservativeInputFrameForWindowFrame:windowFrame];
        Assert(CGRectGetWidth(conservativeFrame) >= 600
                && CGRectGetMaxY(conservativeFrame) <= CGRectGetMaxY(windowFrame)
                && CGRectGetMaxY(windowFrame) - CGRectGetMaxY(conservativeFrame) <= 80,
            @"冷启动锚点应位于 Codex 主窗口底部的保守输入区");

        CPAAccessibilitySnapshot *unavailable = [[CPAAccessibilitySnapshot alloc] init];
        unavailable.permissionGranted = YES;
        unavailable.codexIsRunning = YES;
        unavailable.codexIsFrontmost = YES;
        unavailable.targetApplicationIsFrontmost = YES;
        unavailable.targetBundleIdentifier = @"com.openai.codex";
        unavailable.targetProcessIdentifier = 42;
        unavailable.suggestionPolicyOutcome =
            CPASuggestionPolicyOutcomeLocalAndRemote;
        unavailable.contextAccessMode = CPAContextAccessModeCodexConversation;
        unavailable.diagnostic = @"focused_element_unavailable error=-25212";
        CPAAccessibilitySnapshot *coldStart = [CPAAccessibilitySnapshot
            shadowSnapshotFromInspection:unavailable
            shadowText:@"继续优化"
            cursorLocation:4
            selectedLength:0
            fallbackInputFrame:conservativeFrame];
        Assert(coldStart != nil && coldStart.writableTextInput
                && coldStart.hasSuggestionAnchor
                && [coldStart.inputText isEqualToString:@"继续优化"],
            @"AX -25212 且无任何历史锚点时，应能用当前窗口和影子草稿冷启动");
        Assert(coldStart.targetApplicationIsFrontmost
                && [coldStart.targetBundleIdentifier isEqualToString:
                    @"com.openai.codex"]
                && coldStart.targetProcessIdentifier == 42
                && coldStart.suggestionPolicyOutcome
                    == CPASuggestionPolicyOutcomeLocalAndRemote
                && coldStart.contextAccessMode
                    == CPAContextAccessModeCodexConversation,
            @"shadow snapshots must retain the current target and policy boundary");
        Assert([CPAAccessibilitySnapshot shadowSnapshotFromInspection:unavailable
                shadowText:@"" cursorLocation:0 selectedLength:0
                fallbackInputFrame:conservativeFrame] == nil,
            @"没有可确认的输入文本时必须保持静默");

        NSLog(@"PASS: AccessibilitySnapshotTests");
    }
    return 0;
}
