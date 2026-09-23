#import "OverlayController.h"

#import <QuartzCore/QuartzCore.h>

#import "Diagnostics.h"

static const CGFloat CPAOverlayHeight = 40.0;
static const CGFloat CPAOverlayCornerRadius = 8.0;
static const CGFloat CPAOverlayHorizontalPadding = 12.0;
static const CGFloat CPAOverlayShortcutClusterWidth = 158.0;

@interface CPANonActivatingPanel : NSPanel
@end

@implementation CPANonActivatingPanel

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeMainWindow {
    return NO;
}

@end

@interface CPAOverlayController ()
@property(nonatomic, strong) CPANonActivatingPanel *panel;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSTextField *tabKeyLabel;
@property(nonatomic, strong) NSTextField *tabActionLabel;
@property(nonatomic, strong) NSTextField *escapeKeyLabel;
@property(nonatomic, strong) NSTextField *escapeActionLabel;
@property(nonatomic) NSRect lastPanelFrame;
@property(nonatomic) BOOL hasLastPanelFrame;
@property(nonatomic) CFTimeInterval lastRenderTime;
- (NSTextField *)keycapLabelWithTitle:(NSString *)title;
- (NSTextField *)shortcutActionLabelWithTitle:(NSString *)title;
- (CGFloat)contentHeightForWidth:(CGFloat)width;
- (void)layoutContentForWidth:(CGFloat)width;
- (void)showPanelAtFrame:(NSRect)frame;
@end

@implementation CPAOverlayController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        [self configurePanel];
    }
    return self;
}

- (BOOL)visible {
    return self.panel.visible;
}

- (void)configurePanel {
    NSWindowStyleMask styleMask = NSWindowStyleMaskBorderless
        | NSWindowStyleMaskNonactivatingPanel;
    self.panel = [[CPANonActivatingPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, CPAOverlayHeight)
        styleMask:styleMask
        backing:NSBackingStoreBuffered
        defer:NO];
    // Keep the panel above Chromium/IME floating windows without activating
    // the helper application. NSFloatingWindowLevel is below the Sogou
    // candidate window on Retina macOS, which made a valid suggestion appear
    // to be missing while the input method was open.
    self.panel.level = NSStatusWindowLevel;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = NO;
    self.panel.ignoresMouseEvents = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.animationBehavior = NSWindowAnimationBehaviorNone;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorTransient
        | NSWindowCollectionBehaviorIgnoresCycle;

    NSView *container = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, 520, CPAOverlayHeight)];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    container.wantsLayer = YES;
    container.layer.backgroundColor = [NSColor colorWithSRGBRed:26.0 / 255.0
        green:109.0 / 255.0 blue:106.0 / 255.0 alpha:1.0].CGColor;
    container.layer.cornerRadius = CPAOverlayCornerRadius;

    self.label = [NSTextField labelWithString:@""];
    self.label.font = [NSFont fontWithName:@"PingFangSC-Regular" size:16.0]
        ?: [NSFont systemFontOfSize:16.0 weight:NSFontWeightRegular];
    self.label.textColor = [NSColor colorWithSRGBRed:0.94
        green:0.97 blue:0.97 alpha:1.0];
    self.label.lineBreakMode = NSLineBreakByWordWrapping;
    self.label.maximumNumberOfLines = 0;
    self.label.usesSingleLineMode = NO;
    [container addSubview:self.label];

    self.tabKeyLabel = [self keycapLabelWithTitle:@"Tab"];
    [container addSubview:self.tabKeyLabel];
    self.tabActionLabel = [self shortcutActionLabelWithTitle:@"接受"];
    [container addSubview:self.tabActionLabel];
    self.escapeKeyLabel = [self shortcutActionLabelWithTitle:@"Esc"];
    [container addSubview:self.escapeKeyLabel];
    self.escapeActionLabel = [self shortcutActionLabelWithTitle:@"忽略"];
    [container addSubview:self.escapeActionLabel];
    [self layoutContentForWidth:NSWidth(container.bounds)];
    self.panel.contentView = container;
}

- (NSTextField *)keycapLabelWithTitle:(NSString *)title {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    label.textColor = [NSColor colorWithSRGBRed:26.0 / 255.0
        green:109.0 / 255.0 blue:106.0 / 255.0 alpha:1.0];
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByClipping;
    label.wantsLayer = YES;
    label.layer.backgroundColor = [NSColor colorWithSRGBRed:0.94
        green:0.97 blue:0.97 alpha:1.0].CGColor;
    label.layer.cornerRadius = 3.0;
    return label;
}

- (NSTextField *)shortcutActionLabelWithTitle:(NSString *)title {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont fontWithName:@"PingFangSC-Regular" size:13.0]
        ?: [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
    label.textColor = self.label.textColor;
    label.alignment = NSTextAlignmentLeft;
    label.lineBreakMode = NSLineBreakByClipping;
    return label;
}

- (CGFloat)contentHeightForWidth:(CGFloat)width {
    CGFloat textWidth = MAX(80.0, width - CPAOverlayShortcutClusterWidth
        - 2 * CPAOverlayHorizontalPadding - 10.0);
    // Measure the same wrapping cell and width that will be drawn, including
    // the cell's text insets. A three-line cap can hide text that Tab inserts.
    NSSize size = [self.label.cell cellSizeForBounds:NSMakeRect(0, 0, textWidth, CGFLOAT_MAX)];
    return MAX(CPAOverlayHeight, ceil(size.height) + 16.0);
}

- (void)layoutContentForWidth:(CGFloat)width {
    CGFloat shortcutX = width - CPAOverlayShortcutClusterWidth
        - CPAOverlayHorizontalPadding;
    CGFloat labelWidth = MAX(80.0,
        shortcutX - CPAOverlayHorizontalPadding - 10.0);
    CGFloat height = [self contentHeightForWidth:width];
    CGFloat keyY = floor((height - 24.0) / 2.0);
    CGFloat textHeight = ceil([self.label.cell cellSizeForBounds:
        NSMakeRect(0, 0, labelWidth, CGFLOAT_MAX)].height);
    self.label.frame = NSMakeRect(CPAOverlayHorizontalPadding,
        floor((height - textHeight) / 2.0), labelWidth, textHeight);
    self.tabKeyLabel.frame = NSMakeRect(shortcutX, keyY, 38.0, 24.0);
    self.tabActionLabel.frame = NSMakeRect(shortcutX + 44.0, keyY + 2.0, 30.0, 20.0);
    self.escapeKeyLabel.frame = NSMakeRect(shortcutX + 94.0, keyY + 2.0, 29.0, 20.0);
    self.escapeActionLabel.frame = NSMakeRect(shortcutX + 126.0,
        keyY + 2.0, 32.0, 20.0);
}

- (void)showSuggestion:(NSString *)suggestion atAccessibilityBounds:(CGRect)bounds {
    self.label.stringValue = suggestion;
    NSRect cocoaBounds = [self cocoaRectForAccessibilityRect:bounds];
    NSScreen *targetScreen = NSScreen.mainScreen;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSIntersectsRect(screen.frame, NSInsetRect(cocoaBounds, -1, -1))) {
            targetScreen = screen;
            break;
        }
    }
    NSRect visible = targetScreen.visibleFrame;
    CGFloat width = MIN(560.0, MAX(180.0, NSWidth(visible) - 12.0));
    CGFloat height = [self contentHeightForWidth:width];
    if (width < 280.0 || height > NSHeight(visible) - 12.0) {
        [self hide];
        CPADiagnosticLog(@"overlay withheld reason=content_does_not_fit");
        return;
    }
    [self layoutContentForWidth:width];
    CGFloat x = MIN(MAX(NSMinX(cocoaBounds), NSMinX(visible) + 6),
        NSMaxX(visible) - width - 6);
    CGFloat y = NSMinY(cocoaBounds) - height - 4;
    if (y < NSMinY(visible) + 6) y = NSMaxY(cocoaBounds) + 4;
    y = MIN(MAX(y, NSMinY(visible) + 6), NSMaxY(visible) - height - 6);
    NSRect frame = NSMakeRect(x, y, width, height);
    [self showPanelAtFrame:frame];
}

- (void)showSuggestionBar:(NSString *)suggestion
    atAccessibilityInputFrame:(CGRect)inputFrame {
    self.label.stringValue = suggestion;

    NSRect cocoaInputFrame = [self cocoaRectForAccessibilityRect:inputFrame];
    CGFloat availableWidth = MAX(180.0, NSWidth(cocoaInputFrame) - 24.0);
    // A narrow host must not squeeze the text underneath the shortcut cluster.
    CGFloat width = MAX(360.0, MIN(availableWidth * 0.78, availableWidth));
    CGFloat height = [self contentHeightForWidth:width];
    [self layoutContentForWidth:width];

    NSScreen *targetScreen = NSScreen.mainScreen;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSIntersectsRect(screen.frame, cocoaInputFrame)) {
            targetScreen = screen;
            break;
        }
    }
    NSRect visibleFrame = targetScreen != nil ? targetScreen.visibleFrame : NSZeroRect;
    if (targetScreen != nil) {
        width = MIN(width, MAX(180.0, NSWidth(visibleFrame) - 12.0));
        height = [self contentHeightForWidth:width];
        [self layoutContentForWidth:width];
    }
    if (width < 280.0 || height > NSHeight(visibleFrame) - 12.0) {
        [self hide];
        CPADiagnosticLog(@"overlay withheld reason=content_does_not_fit");
        return;
    }
    CGFloat x = NSMinX(cocoaInputFrame) + 12.0;
    CGFloat y = NSMaxY(cocoaInputFrame) + 6.0;
    if (targetScreen != nil) {
        x = MIN(MAX(x, NSMinX(visibleFrame) + 6.0), NSMaxX(visibleFrame) - width - 6.0);
        if (y + height > NSMaxY(visibleFrame)) {
            y = NSMinY(cocoaInputFrame) - height - 6.0;
        }
    }

    if (targetScreen != nil) y = MIN(MAX(y, NSMinY(visibleFrame) + 6),
        NSMaxY(visibleFrame) - height - 6);
    [self showPanelAtFrame:NSMakeRect(x, y, width, height)];
}

- (void)hide {
    if (self.panel.visible) {
        CPADiagnosticLog(@"overlay hide");
        [self.panel orderOut:nil];
        self.panel.alphaValue = 1.0;
    }
}

- (void)showPanelAtFrame:(NSRect)frame {
    BOOL wasVisible = self.panel.visible;
    // Streamed candidates can arrive several times within one run-loop turn.
    // Avoid forcing a Core Animation/layout transaction when the anchor did
    // not move; this keeps the global keyboard tap responsive.
    BOOL frameChanged = !self.hasLastPanelFrame
        || !NSEqualRects(self.lastPanelFrame, frame);
    if (frameChanged) {
        [self.panel setFrame:frame display:YES];
        self.lastPanelFrame = frame;
        self.hasLastPanelFrame = YES;
    }
    CFTimeInterval now = CACurrentMediaTime();
    BOOL withinFrameBudget = self.lastRenderTime > 0.0
        && now - self.lastRenderTime < (1.0 / 60.0);
    if (withinFrameBudget && wasVisible && !frameChanged) {
        // The next stream chunk will refresh the text; do not force another
        // window transaction inside the same display frame.
        return;
    }
    self.lastRenderTime = now;
    CPADiagnosticLog(@"overlay panel_frame x=%ld y=%ld width=%ld height=%ld level=%ld",
        (long)llround(NSMinX(frame)),
        (long)llround(NSMinY(frame)),
        (long)llround(NSWidth(frame)),
        (long)llround(NSHeight(frame)),
        (long)self.panel.level);
    if (!wasVisible) {
        // The candidate is an inline affordance, not a modal surface. Show it
        // atomically so the first usable prefix is visible in the same turn as
        // the model callback; a fade here only adds perceived latency and can
        // make a just-arrived Tab press target the host application's UI.
        self.panel.alphaValue = 1.0;
        [self.panel orderFrontRegardless];
    }
}

- (NSRect)cocoaRectForAccessibilityRect:(CGRect)accessibilityRect {
    CGPoint accessibilityPoint = accessibilityRect.origin;
    for (NSScreen *screen in NSScreen.screens) {
        // AXUIElement positions use AppKit's logical point space. Comparing
        // them with CGDisplayBounds (backing pixels on Retina) scales the
        // anchor incorrectly and places the panel far from the composer.
        NSRect screenFrame = screen.frame;
        if (!NSPointInRect(NSMakePoint(accessibilityPoint.x, accessibilityPoint.y),
                           screenFrame)) {
            continue;
        }

        CGFloat localX = accessibilityRect.origin.x - NSMinX(screenFrame);
        CGFloat localY = accessibilityRect.origin.y - NSMinY(screenFrame);
        return NSMakeRect(
            NSMinX(screenFrame) + localX,
            NSMaxY(screenFrame) - localY - accessibilityRect.size.height,
            accessibilityRect.size.width,
            accessibilityRect.size.height
        );
    }

    NSScreen *mainScreen = NSScreen.mainScreen;
    CGFloat mainHeight = mainScreen != nil ? NSMaxY(mainScreen.frame) : 0.0;
    return NSMakeRect(
        accessibilityRect.origin.x,
        mainHeight - accessibilityRect.origin.y - accessibilityRect.size.height,
        accessibilityRect.size.width,
        accessibilityRect.size.height
    );
}

@end
