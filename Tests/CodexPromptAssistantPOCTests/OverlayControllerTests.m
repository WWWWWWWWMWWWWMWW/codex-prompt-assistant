#import <AppKit/AppKit.h>

#include <math.h>

#import "../../Sources/CodexPromptAssistantPOC/OverlayController.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSTextField *LabelWithText(NSView *container, NSString *text) {
    NSArray<NSView *> *subviews = container.subviews;
    for (NSUInteger i = 0, count = subviews.count; i < count; i++) {
        NSView *view = subviews[i];
        if ([view isKindOfClass:NSTextField.class]
            && [((NSTextField *)view).stringValue isEqualToString:text]) {
            return (NSTextField *)view;
        }
    }
    return nil;
}

static void WriteViewSnapshotIfRequested(NSView *view) {
    NSString *path = NSProcessInfo.processInfo.environment[
        @"CPA_OVERLAY_SNAPSHOT_PATH"];
    if (path.length == 0) {
        return;
    }
    NSBitmapImageRep *representation = [view
        bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:representation];
    NSData *pngData = [representation representationUsingType:NSBitmapImageFileTypePNG
        properties:@{}];
    Assert([pngData writeToFile:path atomically:YES],
        @"the overlay visual snapshot should be written");
}

static void AssertCompleteText(CPAOverlayController *controller, NSString *text) {
    NSWindow *panel = [controller valueForKey:@"panel"];
    NSTextField *label = LabelWithText(panel.contentView, text);
    Assert(controller.visible && label != nil, @"the complete candidate should be visible");
    // Independently lay out every glyph, without the view's line/height limits.
    NSTextStorage *storage = [[NSTextStorage alloc] initWithString:text
        attributes:@{NSFontAttributeName:label.font}];
    NSLayoutManager *layout = [NSLayoutManager new];
    NSTextContainer *container = [[NSTextContainer alloc]
        initWithContainerSize:NSMakeSize(NSWidth(label.frame) - 4, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container]; [storage addLayoutManager:layout];
    [layout ensureLayoutForTextContainer:container];
    __block NSUInteger lines = 0;
    [layout enumerateLineFragmentsForGlyphRange:[layout glyphRangeForTextContainer:container]
        usingBlock:^(NSRect rect, NSRect used, NSTextContainer *tc, NSRange range, BOOL *stop) {
            (void)rect; (void)used; (void)tc; (void)range; (void)stop; lines++;
        }];
    NSLog(@"candidate length=%lu lines=%lu requiredHeight=%.0f availableHeight=%.0f",
        (unsigned long)text.length, (unsigned long)lines,
        NSHeight([layout usedRectForTextContainer:container]), NSHeight(label.frame));
    Assert(label.maximumNumberOfLines == 0 || (NSUInteger)label.maximumNumberOfLines >= lines,
        @"the candidate must not be truncated by a line limit");
    Assert(NSHeight(label.frame) >= ceil(NSHeight([layout usedRectForTextContainer:container])),
        @"the text frame must accommodate all glyphs before Tab is offered");
    for (NSString *title in @[@"Tab", @"Esc", @"接受", @"忽略"]) {
        NSTextField *key = LabelWithText(panel.contentView, title);
        Assert(key != nil && NSContainsRect(panel.contentView.bounds, key.frame)
            && !NSIntersectsRect(label.frame, key.frame),
            @"shortcut labels must stay inside the panel without overlapping the candidate");
    }
    Assert(NSContainsRect(panel.screen.visibleFrame, panel.frame),
        @"the entire readable candidate must stay inside the screen");
}

@interface CPAOrderingProbePanel : NSPanel
@property(nonatomic) BOOL orderFrontRegardlessCalled;
@property(nonatomic) BOOL relativeOrderingCalled;
@end

@implementation CPAOrderingProbePanel

- (void)orderFrontRegardless {
    self.orderFrontRegardlessCalled = YES;
}

- (void)orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWindowNumber {
    (void)place;
    (void)otherWindowNumber;
    self.relativeOrderingCalled = YES;
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        pid_t frontmostBefore = NSWorkspace.sharedWorkspace
            .frontmostApplication.processIdentifier;
        BOOL activeBefore = application.active;

        CPAOverlayController *controller = [[CPAOverlayController alloc] init];
        [controller showSuggestionBar:@"继续补充具体的优化建议"
            atAccessibilityInputFrame:CGRectMake(500, 700, 600, 60)];
        [[NSRunLoop mainRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.05]];

        pid_t frontmostAfter = NSWorkspace.sharedWorkspace
            .frontmostApplication.processIdentifier;
        Assert(frontmostAfter == frontmostBefore,
            @"showing a suggestion must preserve the frontmost application");
        Assert(application.active == activeBefore,
            @"showing a suggestion must not change helper activation state");
        Assert(controller.visible, @"suggestion panel should still be visible");
        NSWindow *panel = [controller valueForKey:@"panel"];
        Assert(panel.alphaValue >= 0.99,
            @"first candidate should be opaque immediately without a fade-in delay");
        NSRect panelFrame = panel.frame;
        NSView *container = panel.contentView;
        Assert(fabs(NSHeight(panelFrame) - 40.0) < 0.5,
            @"the reference-style suggestion bar should use a compact 40pt height");
        Assert(container.wantsLayer && fabs(container.layer.cornerRadius - 8.0) < 0.5,
            @"the suggestion surface should use an 8pt corner radius");
        Assert(container.layer.borderWidth == 0.0 && !panel.hasShadow,
            @"the reference surface should be flat without a border or shadow");
        CGFloat surfaceAlpha = CGColorGetAlpha(container.layer.backgroundColor);
        Assert(surfaceAlpha == 1.0,
            @"the teal suggestion surface should stay consistent over every host");
        NSTextField *tabKeyLabel = LabelWithText(container, @"Tab");
        NSTextField *escapeKeyLabel = LabelWithText(container, @"Esc");
        Assert(tabKeyLabel != nil && escapeKeyLabel != nil,
            @"Tab and Esc should remain separate readable shortcut labels");
        Assert(tabKeyLabel.wantsLayer && tabKeyLabel.layer.cornerRadius >= 2.5
                && escapeKeyLabel.layer.backgroundColor == NULL,
            @"only Tab should have a rounded keycap background");
        Assert(panel.ignoresMouseEvents && !panel.canBecomeKeyWindow
                && !panel.canBecomeMainWindow,
            @"restyling must preserve click-through and nonactivating behavior");
        WriteViewSnapshotIfRequested(container);
        [controller showSuggestionBar:
            @"这是一条明显更长的流式续写，但它不应让候选条持续改变宽度或位置"
            atAccessibilityInputFrame:CGRectMake(500, 700, 600, 60)];
        NSRect streamedFrame = panel.frame;
        Assert(NSMinX(panelFrame) == NSMinX(streamedFrame)
                && NSWidth(panelFrame) == NSWidth(streamedFrame),
            @"streamed text must keep a stable horizontal anchor and width");
        Assert(NSHeight(streamedFrame) > 40.0 && NSHeight(streamedFrame) <= 90.0,
            @"long suggestions should wrap to a bounded multiline panel");
        // The fixed synthetic anchor is on its containing display, which need
        // not be mainScreen when the user is working on a second monitor.
        NSScreen *fixtureScreen = nil;
        for (NSScreen *screen in NSScreen.screens) {
            if (NSPointInRect(NSMakePoint(500, 700), screen.frame)) { fixtureScreen = screen; break; }
        }
        Assert(fixtureScreen != nil, @"the synthetic anchor must belong to an available screen");
        NSRect screenFrame = fixtureScreen.frame;
        CGFloat expectedY = NSMaxY(screenFrame) - 700.0 - 60.0 + 60.0 + 6.0;
        Assert(fabs(NSMinX(panelFrame) - 512.0) < 0.5,
            @"panel x should stay in logical accessibility coordinates");
        Assert(fabs(NSMinY(panelFrame) - expectedY) < 0.5,
            @"panel y should be converted from top-left AX coordinates");
        Assert(NSContainsRect(screenFrame, panelFrame),
            [NSString stringWithFormat:@"panel should remain on the target screen: screen=%@ panel=%@", NSStringFromRect(screenFrame), NSStringFromRect(panelFrame)]);
        [controller showSuggestion:
            @"这是一条需要完整展示的较长续写，重点验证右侧屏幕边缘不会截断候选，同时保留清晰可见的快捷键，并避免覆盖当前正在输入的文本。"
            atAccessibilityBounds:CGRectMake(NSMaxX(screenFrame) - 12, 200, 1, 18)];
        Assert(NSContainsRect(panel.screen.visibleFrame, panel.frame),
            @"a caret near the right edge must not push the suggestion off-screen");
        WriteViewSnapshotIfRequested(panel.contentView);

        NSString *longCandidate = [@"逐项核对记录并保留原文中的待确认事项。"
            stringByPaddingToLength:240 withString:@"逐项核对记录并保留原文中的待确认事项。" startingAtIndex:0];
        [controller showSuggestionBar:longCandidate
            atAccessibilityInputFrame:CGRectMake(500, 300, 204, 60)];
        WriteViewSnapshotIfRequested(panel.contentView);
        AssertCompleteText(controller, longCandidate);
        [controller showSuggestion:longCandidate
            atAccessibilityBounds:CGRectMake(NSMaxX(screenFrame) - 12, 200, 1, 18)];
        AssertCompleteText(controller, longCandidate);
        NSString *multiline = @"字段名称\n数据类型\n来源说明\n对应关系\n待确认事项\n最后一行也必须显示完整。";
        [controller showSuggestionBar:multiline atAccessibilityInputFrame:CGRectMake(500, 300, 204, 60)];
        AssertCompleteText(controller, multiline);
        NSString *tallCandidate = [@"字段\n" stringByPaddingToLength:240 withString:@"字段\n" startingAtIndex:0];
        [controller showSuggestionBar:tallCandidate atAccessibilityInputFrame:CGRectMake(500, 300, 204, 60)];
        Assert(!controller.visible, @"an unreviewable candidate must hide the old panel, not offer Tab");
        [controller showSuggestionBar:@"继续核对字段" atAccessibilityInputFrame:CGRectMake(500, 300, 204, 60)];
        AssertCompleteText(controller, @"继续核对字段");
        [controller hide];
        Assert(!controller.visible, @"hide should order out the panel");

        CPAOverlayController *orderingController = [[CPAOverlayController alloc] init];
        CPAOrderingProbePanel *probePanel = [[CPAOrderingProbePanel alloc]
            initWithContentRect:NSMakeRect(0, 0, 520, 32)
            styleMask:NSWindowStyleMaskBorderless
            backing:NSBackingStoreBuffered
            defer:NO];
        [orderingController setValue:probePanel forKey:@"panel"];
        [orderingController showSuggestionBar:@"后台候选"
            atAccessibilityInputFrame:CGRectMake(500, 700, 600, 60)];
        Assert(probePanel.orderFrontRegardlessCalled,
            @"an inactive helper must order the candidate front regardless");
        Assert(!probePanel.relativeOrderingCalled,
            @"relative ordering can be discarded when the helper is inactive");

        NSLog(@"PASS: OverlayControllerTests");
    }
    return 0;
}
