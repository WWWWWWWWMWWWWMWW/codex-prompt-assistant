#import "CodexThreadIDResolver.h"

static const int64_t CPAThreadIDReplayEventTag = 0x435041494452504cLL;

NSString *CPAThreadIDFromLink(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    if (![url.scheme isEqual:@"codex"] || ![url.host isEqual:@"threads"]
        || url.user != nil || url.password != nil || url.port != nil
        || url.query != nil || url.fragment != nil) return nil;
    NSArray *parts = [url.path componentsSeparatedByString:@"/"];
    if (parts.count != 2 || [parts[0] length] != 0 || [parts[1] length] != 36) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:parts[1]];
    return uuid.UUIDString.lowercaseString;
}

@interface CPAThreadIDTransaction ()
@property(nonatomic, strong) id<CPAThreadIDIO> io;
@property(nonatomic, strong) id saved;
@property(nonatomic) NSInteger before;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic, readwrite) BOOL pending;
@property(nonatomic, readwrite) BOOL cancelled;
@end
@implementation CPAThreadIDTransaction
- (instancetype)initWithIO:(id<CPAThreadIDIO>)io {
    self = [super init]; if (self) _io = io; return self;
}
- (BOOL)isValid { return !self.cancelled && (self.validate == nil || self.validate()); }
- (void)finish:(NSString *)identifier reason:(NSString *)reason {
    self.pending = NO; self.saved = nil;
    void (^done)(NSString *, NSString *) = self.completion;
    self.completion = nil; self.validate = nil;
    if (done) done(identifier, reason);
}
- (void)start {
    if (self.pending) return;
    self.before = self.io.revision;
    if (![self isValid] || ![self.io focusMatches]) { [self finish:nil reason:@"focus_before"]; return; }
    self.saved = [self.io capture];
    if (self.saved == nil || self.io.revision != self.before) {
        [self finish:nil reason:@"clipboard_before"]; return;
    }
    if (![self isValid] || ![self.io focusMatches]) { [self finish:nil reason:@"focus_before"]; return; }
    self.deadline = self.io.now + 0.75;
    self.pending = YES;
    if (![self.io sendCopy]) [self finish:nil reason:@"copy_unavailable"];
}
- (void)cancel { self.cancelled = YES; }
- (void)poll {
    if (!self.pending) return;
    if (![self isValid] || ![self.io focusMatches]) self.cancelled = YES;
    NSInteger revision = self.io.revision;
    if (revision == self.before) {
        if (self.io.now >= self.deadline) [self finish:nil reason:@"copy_timeout"];
        return;
    }
    NSString *identifier = CPAThreadIDFromLink(self.io.text);
    if (revision != self.before + 1 || self.io.revision != revision || identifier == nil) {
        // Another owner has written. Never replace their newest contents with our backup.
        [self finish:nil reason:@"clipboard_contended"]; return;
    }
    BOOL restored = [self.io restore:self.saved expectedRevision:revision];
    BOOL valid = [self isValid] && [self.io focusMatches] && self.io.now < self.deadline;
    [self finish:restored && valid ? identifier : nil reason:!restored ? @"clipboard_restore_changed"
        : valid ? @"ready" : @"cancelled"];
}
@end

static id CPAIDAttribute(AXUIElementRef element, CFStringRef attribute) {
    if (element == NULL) return nil;
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element, attribute, &value);
    return CFBridgingRelease(value);
}
@interface CPAThreadIDNativeIO : NSObject <CPAThreadIDIO>
@property(nonatomic) pid_t pid;
@property(nonatomic, strong) id application;
@property(nonatomic, strong) id field;
@property(nonatomic, strong) id window;
@end
@implementation CPAThreadIDNativeIO
- (NSInteger)revision { return NSPasteboard.generalPasteboard.changeCount; }
- (NSString *)text { return [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]; }
- (NSTimeInterval)now { return NSProcessInfo.processInfo.systemUptime; }
- (id)capture {
    NSInteger revision = self.revision;
    NSMutableArray *result = [NSMutableArray array]; NSUInteger bytes = 0;
    for (NSPasteboardItem *item in NSPasteboard.generalPasteboard.pasteboardItems) {
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSPasteboardType type in item.types) {
            // Lazy file promises can synchronously call an external owner; do not start.
            if ([type.lowercaseString containsString:@"promise"]) return nil;
            NSData *data = [item dataForType:type]; bytes += data.length;
            if (data == nil || bytes > 8 * 1024 * 1024) return nil;
            values[type] = data;
        }
        [result addObject:values];
    }
    return self.revision == revision ? result : nil;
}
- (BOOL)restore:(id)saved expectedRevision:(NSInteger)revision {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *values in saved) {
        NSPasteboardItem *item = [NSPasteboardItem new];
        for (NSPasteboardType type in values) [item setData:values[type] forType:type];
        [items addObject:item];
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    if (self.revision != revision) return NO;
    NSInteger cleared = [pasteboard clearContents];
    // macOS offers no cross-process compare-and-swap. Recheck immediately and verify bytes.
    if (self.revision != cleared) return NO;
    if (items.count > 0 && ![pasteboard writeObjects:items]) return NO;
    return [[self capture] isEqual:saved];
}
- (BOOL)focusMatches {
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != self.pid) return NO;
    if (self.application == nil) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
        if (![app.bundleIdentifier isEqual:@"com.openai.codex"]) return NO;
        AXUIElementRef element = AXUIElementCreateApplication(self.pid);
        AXUIElementSetMessagingTimeout(element, 0.08);
        self.application = CFBridgingRelease(element);
    }
    id focus = CPAIDAttribute((__bridge AXUIElementRef)self.application, kAXFocusedUIElementAttribute);
    if (![CPAIDAttribute((__bridge AXUIElementRef)focus, kAXRoleAttribute) isEqual:@"AXTextArea"]
        || [CPAIDAttribute((__bridge AXUIElementRef)focus, kAXSubroleAttribute) isEqual:@"AXSecureTextField"]) return NO;
    id window = CPAIDAttribute((__bridge AXUIElementRef)focus, kAXWindowAttribute);
    if (window == nil) return NO;
    if (self.field == nil) { self.field = focus; self.window = window; }
    return CFEqual((__bridge CFTypeRef)focus, (__bridge CFTypeRef)self.field)
        && CFEqual((__bridge CFTypeRef)window, (__bridge CFTypeRef)self.window);
}
- (BOOL)sendCopy {
    if (![self focusMatches]) return NO;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 37, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 37, false);
    if (down == NULL || up == NULL) {
        if (down) CFRelease(down); if (up) CFRelease(up); return NO;
    }
    for (id item in @[(__bridge id)down, (__bridge id)up]) {
        CGEventRef event = (__bridge CGEventRef)item;
        CGEventSetFlags(event, kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate);
        CGEventSetIntegerValueField(event, kCGEventSourceUserData, CPAThreadIDCopyEventTag);
        CGEventPostToPid(self.pid, event);
    }
    CFRelease(down); CFRelease(up); return YES;
}
@end

@interface CPACodexThreadIDResolver ()
@property(nonatomic, strong) CPAThreadIDTransaction *transaction;
@property(nonatomic, strong) CPAThreadIDNativeIO *io;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) CFMachPortRef tap;
@property(nonatomic) CFRunLoopSourceRef tapSource;
@property(nonatomic) CFMachPortRef processTap;
@property(nonatomic) CFRunLoopSourceRef processTapSource;
@property(nonatomic) BOOL copyDownObserved;
@property(nonatomic) BOOL copyDownBlocked;
@property(nonatomic, strong) NSMutableArray *deferredEvents;
@property(nonatomic, strong) NSMutableSet *deferredKeys;
- (CGEventRef)handleType:(CGEventType)type event:(CGEventRef)event;
@end
static CGEventRef CPAIDEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    return [(__bridge CPACodexThreadIDResolver *)context handleType:type event:event];
}
@implementation CPACodexThreadIDResolver
- (BOOL)pending { return self.transaction.pending; }
- (CGEventRef)handleType:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [self cancel]; if (self.tap) CGEventTapEnable(self.tap, true);
        if (self.processTap) CGEventTapEnable(self.processTap, true); return event;
    }
    int64_t tag = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (tag == CPAThreadIDReplayEventTag) return event;
    if (tag == CPAThreadIDCopyEventTag) {
        // Never let a cancelled queued synthetic key-down reach the host.
        if (type == kCGEventKeyDown) {
            self.copyDownObserved = YES;
            if (!self.pending || self.transaction.cancelled) {
                self.copyDownBlocked = YES;
                return NULL;
            }
        }
        return event;
    }
    if (!self.pending) return event;
    CGKeyCode key = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    BOOL clipboardKey = (CGEventGetFlags(event) & kCGEventFlagMaskCommand)
        && (key == 8 || key == 7 || key == 9); // C / X / V, includes alternate paste
    BOOL paired = [self.deferredKeys containsObject:@(key)];
    if ((type == kCGEventKeyDown && clipboardKey) || (type == kCGEventKeyUp && paired)) {
        [self.transaction cancel];
        [self.deferredEvents addObject:CFBridgingRelease(CGEventCreateCopy(event))];
        if (type == kCGEventKeyDown) [self.deferredKeys addObject:@(key)];
        else [self.deferredKeys removeObject:@(key)];
        return NULL;
    }
    if (type != kCGEventKeyUp) [self.transaction cancel];
    return event;
}
- (void)poll { [self.transaction poll]; }
- (void)resolveProcessIdentifier:(pid_t)pid validate:(BOOL (^)(void))validate
    completion:(void (^)(NSString *, NSString *))completion {
    NSAssert(NSThread.isMainThread, @"ID resolution is main-thread owned");
    if (self.pending) { completion(nil, @"busy"); return; }
    self.copyDownObserved = NO; self.copyDownBlocked = NO;
    self.deferredEvents = [NSMutableArray array]; self.deferredKeys = [NSMutableSet set];
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)
        | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventRightMouseDown)
        | CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventScrollWheel);
    self.tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, CPAIDEvent, (__bridge void *)self);
    if (self.tap == NULL) { completion(nil, @"event_guard_unavailable"); return; }
    self.tapSource = CFMachPortCreateRunLoopSource(NULL, self.tap, 0);
    if (self.tapSource == NULL) { CFRelease(self.tap); self.tap = NULL;
        completion(nil, @"event_guard_unavailable"); return; }
    CFRunLoopAddSource(CFRunLoopGetMain(), self.tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(self.tap, true);
    // CGEventPostToPid enters immediately before process taps, bypassing the
    // session tap. Keep both: session guards user clipboard keys; process guards
    // our queued copy command at its actual delivery boundary.
    self.processTap = CGEventTapCreateForPid(pid, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, CPAIDEvent, (__bridge void *)self);
    if (self.processTap) self.processTapSource = CFMachPortCreateRunLoopSource(NULL, self.processTap, 0);
    if (self.processTapSource == NULL) {
        if (self.processTap) { CFMachPortInvalidate(self.processTap); CFRelease(self.processTap); self.processTap = NULL; }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.tapSource, kCFRunLoopCommonModes);
        CFRelease(self.tapSource); self.tapSource = NULL;
        CFMachPortInvalidate(self.tap); CFRelease(self.tap); self.tap = NULL;
        completion(nil, @"process_event_guard_unavailable"); return;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), self.processTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(self.processTap, true);
    self.io = [CPAThreadIDNativeIO new]; self.io.pid = pid;
    self.transaction = [[CPAThreadIDTransaction alloc] initWithIO:self.io];
    self.transaction.validate = validate;
    __weak CPACodexThreadIDResolver *weakSelf = self;
    self.transaction.completion = ^(NSString *identifier, NSString *reason) {
        CPACodexThreadIDResolver *owner = weakSelf;
        [owner.timer invalidate]; owner.timer = nil;
        NSString *diagnosticReason = reason;
        if ([reason isEqual:@"copy_timeout"]) {
            diagnosticReason = owner.copyDownBlocked ? @"copy_cancelled_before_dispatch"
                : owner.copyDownObserved ? @"copy_timeout_after_dispatch" : @"copy_dispatch_unobserved";
        }
        BOOL replay = [owner.io focusMatches];
        NSArray *events = [owner.deferredEvents copy];
        [owner.deferredEvents removeAllObjects]; [owner.deferredKeys removeAllObjects];
        if (owner.tapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), owner.tapSource, kCFRunLoopCommonModes);
            CFRelease(owner.tapSource); owner.tapSource = NULL; }
        if (owner.tap) { CFMachPortInvalidate(owner.tap); CFRelease(owner.tap); owner.tap = NULL; }
        if (owner.processTapSource) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), owner.processTapSource, kCFRunLoopCommonModes);
            CFRelease(owner.processTapSource); owner.processTapSource = NULL;
        }
        if (owner.processTap) { CFMachPortInvalidate(owner.processTap); CFRelease(owner.processTap); owner.processTap = NULL; }
        if (replay) for (id item in events) {
            CGEventRef event = (__bridge CGEventRef)item;
            CGEventSetIntegerValueField(event, kCGEventSourceUserData, CPAThreadIDReplayEventTag);
            CGEventPostToPid(pid, event);
        }
        owner.io = nil;
        completion(identifier, diagnosticReason);
    };
    [self.transaction start];
    if (self.pending) {
        self.timer = [NSTimer timerWithTimeInterval:0.015 target:self selector:@selector(poll) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}
- (void)cancel { [self.transaction cancel]; }
@end
