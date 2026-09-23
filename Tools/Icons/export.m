#import <AppKit/AppKit.h>

static void Export(NSImage *master, NSInteger pixels, CGFloat inset, NSString *path) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    NSRect rect = NSMakeRect(pixels * inset, pixels * inset, pixels * (1 - 2 * inset), pixels * (1 - 2 * inset));
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:rect.size.width * .225 yRadius:rect.size.height * .225] addClip];
    [master drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![data writeToFile:path atomically:YES]) { NSLog(@"Export failed: %@", path); exit(1); }
}

// A compact, monochrome outline of the two interlocking paper folds.
static void ExportStatus(NSInteger pixels, NSString *path) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:pixels / 18.0]; [scale concat];
    [NSColor.blackColor setStroke];
    NSBezierPath *back = [NSBezierPath bezierPath];
    back.lineWidth = 1.35; back.lineJoinStyle = NSLineJoinStyleRound; back.lineCapStyle = NSLineCapStyleRound;
    [back moveToPoint:NSMakePoint(8.6, 2.3)];
    [back curveToPoint:NSMakePoint(2.1, 4.5) controlPoint1:NSMakePoint(6.5, 3.0) controlPoint2:NSMakePoint(2.8, 3.0)];
    [back curveToPoint:NSMakePoint(1.8, 10.4) controlPoint1:NSMakePoint(1.2, 6.0) controlPoint2:NSMakePoint(1.3, 8.6)];
    [back curveToPoint:NSMakePoint(9.0, 16.1) controlPoint1:NSMakePoint(2.5, 12.6) controlPoint2:NSMakePoint(6.8, 15.5)];
    [back curveToPoint:NSMakePoint(10.0, 10.0) controlPoint1:NSMakePoint(10.0, 16.5) controlPoint2:NSMakePoint(10.7, 12.7)];
    [back curveToPoint:NSMakePoint(8.8, 8.0) controlPoint1:NSMakePoint(9.9, 9.1) controlPoint2:NSMakePoint(9.3, 8.4)];
    [back moveToPoint:NSMakePoint(2.1, 4.5)];
    [back curveToPoint:NSMakePoint(7.4, 10.8) controlPoint1:NSMakePoint(1.1, 6.5) controlPoint2:NSMakePoint(5.1, 9.8)];
    [back stroke];
    NSBezierPath *front = [NSBezierPath bezierPath];
    front.lineWidth = 1.35; front.lineJoinStyle = NSLineJoinStyleRound; front.lineCapStyle = NSLineCapStyleRound;
    [front moveToPoint:NSMakePoint(11.8, 11.3)];
    [front curveToPoint:NSMakePoint(16.3, 8.9) controlPoint1:NSMakePoint(14.1, 10.8) controlPoint2:NSMakePoint(16.2, 10.0)];
    [front curveToPoint:NSMakePoint(12.5, 1.7) controlPoint1:NSMakePoint(16.7, 6.9) controlPoint2:NSMakePoint(14.1, 2.7)];
    [front curveToPoint:NSMakePoint(10.6, 1.8) controlPoint1:NSMakePoint(11.7, 1.1) controlPoint2:NSMakePoint(11.0, 1.1)];
    [front curveToPoint:NSMakePoint(7.0, 9.1) controlPoint1:NSMakePoint(9.0, 4.0) controlPoint2:NSMakePoint(7.2, 6.8)];
    [front moveToPoint:NSMakePoint(7.6, 6.6)];
    [front curveToPoint:NSMakePoint(16.3, 8.9) controlPoint1:NSMakePoint(8.6, 4.8) controlPoint2:NSMakePoint(15.1, 7.3)];
    [front stroke];
    [NSGraphicsContext restoreGraphicsState];
    if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]) exit(1);
}

int main(void) { @autoreleasepool {
    // Platform packaging: apply native rounded corners and export pixel-density variants.
    NSImage *master = [[NSImage alloc] initWithContentsOfFile:@"Resources/Artwork/AppIcon-master.png"];
    if (!master) return 1;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:@".build/AppIcon.iconset"
        withIntermediateDirectories:YES attributes:nil error:&error]) return 1;
    for (NSNumber *value in @[@16, @32, @128, @256, @512]) {
        NSInteger size = value.integerValue;
        Export(master, size, .05, [NSString stringWithFormat:@".build/AppIcon.iconset/icon_%ldx%ld.png", size, size]);
        Export(master, size * 2, .05, [NSString stringWithFormat:@".build/AppIcon.iconset/icon_%ldx%ld@2x.png", size, size]);
    }
    Export(master, 1024, .05, @"Resources/Artwork/AppIcon-preview.png");
    ExportStatus(18, @"Resources/StatusIcon.png");
    ExportStatus(36, @"Resources/StatusIcon@2x.png");
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/iconutil"];
    task.arguments = @[@"-c", @"icns", @".build/AppIcon.iconset", @"-o", @"Resources/AppIcon.icns"];
    if (![task launchAndReturnError:&error]) return 1;
    [task waitUntilExit];
    return task.terminationStatus;
} }
