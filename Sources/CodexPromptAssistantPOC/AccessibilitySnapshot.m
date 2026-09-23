#import "AccessibilitySnapshot.h"

@implementation CPAAccessibilitySnapshot

+ (BOOL)isUsableCaretBounds:(CGRect)bounds {
    return isfinite(bounds.origin.x)
        && isfinite(bounds.origin.y)
        && isfinite(bounds.size.width)
        && isfinite(bounds.size.height)
        && bounds.size.height > 0.0;
}

+ (NSInteger)effectiveSelectedLocationForReportedLocation:(NSInteger)reportedLocation
    selectedLength:(NSInteger)selectedLength
    valueLength:(NSInteger)valueLength
    hasUsableCaretBounds:(BOOL)hasUsableCaretBounds {
    BOOL codexZeroRangeFallback = reportedLocation == 0
        && selectedLength == 0
        && valueLength > 0
        && !hasUsableCaretBounds;
    return codexZeroRangeFallback ? valueLength : reportedLocation;
}

- (BOOL)hasSuggestionAnchor {
    return self.hasCaretBounds || self.hasElementFrame;
}

+ (CGRect)conservativeInputFrameForWindowFrame:(CGRect)windowFrame {
    if (![self isUsableCaretBounds:windowFrame]
        || windowFrame.size.width < 320.0 || windowFrame.size.height < 240.0) {
        return CGRectZero;
    }
    CGFloat width = MIN(784.0, MAX(320.0, windowFrame.size.width - 80.0));
    CGFloat height = 52.0;
    CGFloat bottomInset = MIN(110.0, MAX(72.0, windowFrame.size.height * 0.11));
    return CGRectMake(
        CGRectGetMidX(windowFrame) - width / 2.0,
        CGRectGetMaxY(windowFrame) - bottomInset,
        width,
        height
    );
}

+ (nullable CPAAccessibilitySnapshot *)shadowSnapshotFromInspection:
    (CPAAccessibilitySnapshot *)inspection
    shadowText:(NSString *)shadowText
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength
    fallbackInputFrame:(CGRect)fallbackInputFrame {
    BOOL frameUsable = [self isUsableCaretBounds:fallbackInputFrame]
        && fallbackInputFrame.size.width >= 320.0;
    if (!inspection.permissionGranted || !inspection.codexIsRunning
        || !inspection.codexIsFrontmost || inspection.writableTextInput
        || shadowText.length == 0 || !frameUsable
        || cursorLocation > shadowText.length
        || selectedLength > shadowText.length - cursorLocation) {
        return nil;
    }
    CPAAccessibilitySnapshot *shadow = [[CPAAccessibilitySnapshot alloc] init];
    shadow.permissionGranted = inspection.permissionGranted;
    shadow.codexIsRunning = inspection.codexIsRunning;
    shadow.codexIsFrontmost = inspection.codexIsFrontmost;
    shadow.targetApplicationIsFrontmost = inspection.targetApplicationIsFrontmost;
    shadow.targetBundleIdentifier = inspection.targetBundleIdentifier;
    shadow.targetProcessIdentifier = inspection.targetProcessIdentifier;
    shadow.suggestionPolicyOutcome = inspection.suggestionPolicyOutcome;
    shadow.contextAccessMode = inspection.contextAccessMode;
    shadow.suggestionPolicyReason = inspection.suggestionPolicyReason;
    shadow.targetFieldIdentity = inspection.targetFieldIdentity;
    shadow.browserHost = inspection.browserHost;
    shadow.documentContinuation = inspection.documentContinuation;
    shadow.policyRuleVersion = inspection.policyRuleVersion;
    shadow.codexInputDecision = inspection.codexInputDecision;
    shadow.inputReadingGeneration = inspection.inputReadingGeneration;
    shadow.candidateContextGeneration = inspection.candidateContextGeneration;
    shadow.policyStatusText = inspection.policyStatusText;
    shadow.focusedRole = @"AXTextArea";
    shadow.writableTextInput = YES;
    shadow.inputText = shadowText;
    shadow.hasValueCharacterCount = YES;
    shadow.valueCharacterCount = shadowText.length;
    shadow.hasSelectedRange = YES;
    shadow.selectedLocation = (NSInteger)cursorLocation;
    shadow.selectedLength = (NSInteger)selectedLength;
    shadow.hasElementFrame = YES;
    shadow.elementFrame = fallbackInputFrame;
    shadow.diagnostic = @"shadow_input active=true anchor=window";
    return shadow;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _diagnostic = @"not_inspected";
        _targetBundleIdentifier = @"";
        _suggestionPolicyOutcome = CPASuggestionPolicyOutcomeDisabled;
        _contextAccessMode = CPAContextAccessModeNone;
        _targetFieldIdentity = @"";
        _browserHost = @"";
        _policyStatusText = @"未启用";
    }
    return self;
}

- (NSString *)summary {
    if (!self.permissionGranted) {
        return @"尚未获得辅助功能权限";
    }
    if (!self.codexIsRunning) {
        return @"未检测到 ChatGPT/Codex 桌面应用";
    }
    if (!self.codexIsFrontmost) {
        return @"请先把 Codex 窗口切到最前面";
    }
    if (self.rendererAccessibilitySuspected) {
        return @"Codex 输入框未暴露，正在使用窗口输入降级";
    }
    if (self.focusedRole == nil) {
        return @"未找到当前焦点控件";
    }
    if (self.writableTextInput) {
        NSString *rangeText = self.hasSelectedRange
            ? [NSString stringWithFormat:@"选区位置 %ld，长度 %ld",
                (long)self.selectedLocation,
                (long)self.selectedLength]
            : @"未取得选区";
        return [NSString stringWithFormat:@"已找到可写输入框（%@；%@）",
            self.focusedRole,
            rangeText];
    }
    return [NSString stringWithFormat:@"焦点控件为 %@，但尚未确认是可写输入框",
        self.focusedRole];
}

@end
