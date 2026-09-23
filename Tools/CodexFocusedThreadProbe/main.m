#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "../../Sources/CodexPromptAssistantPOC/CodexThreadIDResolver.h"

// Explicit one-shot probe, deliberately not part of the automatic completion loop.
// The only UI action is Codex's Copy deeplink command. Never read AXValue or paste.
static id Attribute(AXUIElementRef element, CFStringRef key) {
    if (element == NULL) return nil;
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element, key, &value);
    return CFBridgingRelease(value);
}

static void CollectTextAreas(AXUIElementRef element, NSMutableArray *matches,
    NSUInteger depth, NSUInteger *visited, CFAbsoluteTime deadline, BOOL *complete) {
    if (element == NULL || matches.count > 1) return;
    if (depth > 80 || ++*visited > 5000 || CFAbsoluteTimeGetCurrent() > deadline) {
        *complete = NO; return;
    }
    if ([Attribute(element, kAXRoleAttribute) isEqual:@"AXTextArea"]
        && [Attribute(element, kAXEnabledAttribute) boolValue])
        [matches addObject:(__bridge id)element];
    for (id child in Attribute(element, kAXChildrenAttribute))
        CollectTextAreas((__bridge AXUIElementRef)child, matches, depth + 1, visited, deadline, complete);
}

static BOOL ClipboardMatches(NSPasteboard *pasteboard, NSArray<NSPasteboardItem *> *saved) {
    NSInteger revision = pasteboard.changeCount;
    NSArray<NSPasteboardItem *> *actual = pasteboard.pasteboardItems;
    if (actual.count != saved.count) return NO;
    for (NSUInteger index = 0; index < saved.count; index++) {
        if (![[NSSet setWithArray:actual[index].types] isEqual:[NSSet setWithArray:saved[index].types]]) return NO;
        for (NSPasteboardType type in saved[index].types)
            if (![[actual[index] dataForType:type] isEqual:[saved[index] dataForType:type]]) return NO;
    }
    return revision == pasteboard.changeCount;
}

static NSString *CPAThreadIDFromDeeplink(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:text];
    if (![url.scheme isEqualToString:@"codex"] || ![url.host isEqualToString:@"threads"]
        || url.user != nil || url.password != nil || url.port != nil
        || url.query != nil || url.fragment != nil) return nil;
    NSArray *parts = [url.path componentsSeparatedByString:@"/"];
    if (parts.count != 2 || [parts[0] length] != 0) return nil;
    NSString *identifier = parts[1];
    return identifier.length == 36 && [[NSUUID alloc] initWithUUIDString:identifier] != nil
        ? identifier.lowercaseString : nil;
}

static BOOL OwnsCopy(NSInteger before, NSInteger after, NSString *value) {
    return after == before + 1 && CPAThreadIDFromDeeplink(value) != nil;
}

static int Emit(NSDictionary *result, int code) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    return code;
}

static int SelfTest(void) {
    NSString *good = @"codex://threads/00000000-0000-4000-8000-000000000001";
    NSArray *bad = @[@"", @"codex://threads/not-an-id", [good stringByAppendingString:@"/extra"],
        [good stringByAppendingString:@"?x=1"], [good stringByAppendingString:@"#x"],
        @"https://threads/00000000-0000-4000-8000-000000000001",
        @"codex://user@threads/00000000-0000-4000-8000-000000000001",
        @"codex://threads:80/00000000-0000-4000-8000-000000000001"];
    NSUInteger failures = CPAThreadIDFromDeeplink(good) == nil;
    for (NSString *value in bad) failures += CPAThreadIDFromDeeplink(value) != nil;
    failures += !OwnsCopy(10, 11, good);
    failures += OwnsCopy(10, 10, good); // unchanged clipboard is never an answer
    failures += OwnsCopy(10, 12, good); // intervening clipboard write is not ours
    failures += OwnsCopy(10, 11, @"unrelated synthetic clipboard");
    return Emit(@{@"selfTestFailures": @(failures)}, failures == 0 ? 0 : 1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if ([arguments containsObject:@"--self-test"]) return SelfTest();
        if (argc < 3 || ![arguments containsObject:@"--copy-current-thread-id"]) {
            (void)argv;
            return Emit(@{@"error": @"explicit_copy_action_and_pid_required"}, 2);
        }
        NSUInteger position = [arguments indexOfObject:@"--pid"];
        if (position == NSNotFound || position + 1 >= arguments.count)
            return Emit(@{@"error": @"pid_required"}, 2);
        NSRunningApplication *app = [NSRunningApplication
            runningApplicationWithProcessIdentifier:arguments[position + 1].intValue];
        if (![app.bundleIdentifier isEqualToString:@"com.openai.codex"])
            return Emit(@{@"error": @"app_identity_mismatch"}, 2);
        if (!AXIsProcessTrusted())
            return Emit(@{@"error": @"accessibility_permission_missing"}, 2);
        NSRunningApplication *previous = NSWorkspace.sharedWorkspace.frontmostApplication;
        BOOL activate = [arguments containsObject:@"--activate"];
        if (activate && previous.processIdentifier != app.processIdentifier) {
            [app activateWithOptions:0];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        }
        AXUIElementRef ax = AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(ax, 0.2);
        @try {
            if ([arguments containsObject:@"--focus-composer"]
                && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == app.processIdentifier) {
                id currentWindow = Attribute(ax, kAXFocusedWindowAttribute);
                NSMutableArray *matches = [NSMutableArray array];
                NSUInteger visited = 0;
                BOOL complete = YES;
                CollectTextAreas((__bridge AXUIElementRef)currentWindow, matches, 0, &visited,
                    CFAbsoluteTimeGetCurrent() + 2.0, &complete);
                if (matches.count != 1 || !complete)
                    return Emit(@{@"error": @"unique_editor_required"}, 3);
                AXUIElementSetAttributeValue((__bridge AXUIElementRef)matches.firstObject,
                    kAXFocusedAttribute, kCFBooleanTrue);
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
            id focus = Attribute(ax, kAXFocusedUIElementAttribute);
            id window = Attribute((__bridge AXUIElementRef)focus, kAXWindowAttribute);
            if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != app.processIdentifier
                || ![Attribute((__bridge AXUIElementRef)focus, kAXRoleAttribute) isEqual:@"AXTextArea"]
                || window == nil)
                return Emit(@{@"error": @"focused_codex_composer_required",
                    @"frontmostMatches": @(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == app.processIdentifier),
                    @"focusRole": Attribute((__bridge AXUIElementRef)focus, kAXRoleAttribute) ?: @"missing",
                    @"windowAvailable": @(window != nil)}, 3);

            if ([arguments containsObject:@"--production-resolver"]) {
                CPACodexThreadIDResolver *resolver = [CPACodexThreadIDResolver new];
                __block BOOL finished = NO;
                __block NSDictionary *result = nil;
                NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
                [resolver resolveProcessIdentifier:app.processIdentifier validate:^BOOL {
                    return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == app.processIdentifier;
                } completion:^(NSString *identifier, NSString *reason) {
                    NSMutableDictionary *record = [@{@"success": @(identifier != nil), @"reason": reason,
                        @"latencyMs": @((NSUInteger)((NSProcessInfo.processInfo.systemUptime - started) * 1000))} mutableCopy];
                    if (identifier != nil) record[@"threadId"] = identifier;
                    result = record; finished = YES;
                }];
                while (!finished) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                return Emit(result, [result[@"success"] boolValue] ? 0 : 4);
            }

            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            NSInteger before = pasteboard.changeCount;
            NSMutableArray *saved = [NSMutableArray array];
            NSUInteger bytes = 0;
            for (NSPasteboardItem *item in pasteboard.pasteboardItems) {
                NSPasteboardItem *copy = [NSPasteboardItem new];
                for (NSPasteboardType type in item.types) {
                    NSData *data = [item dataForType:type];
                    bytes += data.length;
                    if (data == nil || bytes > 8 * 1024 * 1024)
                        return Emit(@{@"error": @"clipboard_cannot_be_preserved"}, 3);
                    [copy setData:data forType:type];
                }
                [saved addObject:copy];
            }
            if (pasteboard.changeCount != before)
                return Emit(@{@"error": @"clipboard_changed_before_copy"}, 3);
            id lastFocus = Attribute(ax, kAXFocusedUIElementAttribute);
            if (lastFocus == nil || !CFEqual((__bridge CFTypeRef)focus, (__bridge CFTypeRef)lastFocus)
                || NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != app.processIdentifier)
                return Emit(@{@"error": @"focus_changed_before_copy"}, 3);

            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            CGEventRef down = CGEventCreateKeyboardEvent(NULL, 37, true);
            CGEventRef up = CGEventCreateKeyboardEvent(NULL, 37, false);
            if (down == NULL || up == NULL) {
                if (down) CFRelease(down);
                if (up) CFRelease(up);
                return Emit(@{@"error": @"keyboard_event_creation"}, 3);
            }
            CGEventSetFlags(down, kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate);
            CGEventSetFlags(up, kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate);
            CGEventPostToPid(app.processIdentifier, down);
            CGEventPostToPid(app.processIdentifier, up);
            CFRelease(down); CFRelease(up);
            while (pasteboard.changeCount == before && CFAbsoluteTimeGetCurrent() - start < 1.2)
                [NSThread sleepForTimeInterval:0.01];

            NSInteger after = pasteboard.changeCount;
            NSString *value = [pasteboard stringForType:NSPasteboardTypeString];
            NSString *identifier = OwnsCopy(before, after, value) ? CPAThreadIDFromDeeplink(value) : nil;
            id fresh = Attribute(ax, kAXFocusedUIElementAttribute);
            BOOL same = fresh != nil && CFEqual((__bridge CFTypeRef)focus, (__bridge CFTypeRef)fresh)
                && [window isEqual:Attribute((__bridge AXUIElementRef)fresh, kAXWindowAttribute)]
                && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == app.processIdentifier;
            BOOL restored = NO;
            // Never overwrite a newer external clipboard write. This check and write
            // are not atomic; this is one reason the probe must not be an auto-poller.
            if (identifier != nil && pasteboard.changeCount == after) {
                [pasteboard clearContents];
                restored = saved.count == 0 || [pasteboard writeObjects:saved];
                restored = restored && ClipboardMatches(pasteboard, saved);
            }
            BOOL success = identifier != nil && same && restored;
            NSMutableDictionary *result = [@{@"success": @(success), @"sameFocusWindow": @(same),
                @"clipboardRestored": @(restored), @"clipboardChanged": @(after != before),
                @"latencyMs": @((NSUInteger)((CFAbsoluteTimeGetCurrent() - start) * 1000))} mutableCopy];
            if (success) result[@"threadId"] = identifier;
            else result[@"error"] = @"copy_or_focus_or_clipboard_validation_failed";
            return Emit(result, success ? 0 : 4);
        } @finally {
            CFRelease(ax);
            if (activate && previous.processIdentifier != app.processIdentifier
                && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == app.processIdentifier)
                [previous activateWithOptions:0];
        }
    }
}
