#import "GenericAccessibilityService.h"
#import "InputElementIdentity.h"
#import "WorkBuddyContextReader.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#import "SuggestionPolicyStore.h"
#import "WPSInputBridge.h"

NSString *CPABrowserHostFromDocumentValue(NSString *documentValue) {
    NSString *trimmed = [documentValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return @"";
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    NSString *scheme = components.scheme.lowercaseString;
    if (scheme.length > 0 && ![scheme isEqualToString:@"http"]
        && ![scheme isEqualToString:@"https"]) {
        return @"";
    }
    NSString *host = [CPASuggestionPolicyStore normalizedBrowserHost:trimmed];
    if ([CPASuggestionPolicyStore isFeishuDocumentHost:host]) {
        // A browser selection shares the Feishu switch only on HTTPS document
        // routes. Account pages, browser chrome, and unknown paths stay disabled.
        if (![scheme isEqual:@"https"] || components.user.length || components.password.length
            || (components.port != nil && components.port.integerValue != 443)
            || [components.percentEncodedPath rangeOfString:@"^/(?:docx|docs|wiki)/[A-Za-z0-9]+/?$"
                options:NSRegularExpressionSearch].location == NSNotFound) return @"";
    }
    return host;
}

NSString *CPALarkReadCursorText(NSUInteger maximumLength, NSRange selection,
    NSString *(^readRange)(NSRange)) {
    if (maximumLength > 65536 || selection.location > maximumLength
        || selection.length > maximumLength - selection.location) return nil;
    // AXValue includes presentation-only table/layout content. AXStringForRange
    // uses the same logical character space as AXSelectedTextRange instead.
    // An explicit failing upper bound avoids silently truncating a longer field.
    if (readRange(NSMakeRange(0, maximumLength + 1)) != nil) return nil;
    NSString *prefix = readRange(NSMakeRange(0, selection.location));
    if (prefix.length != selection.location || prefix == nil) return nil;
    NSUInteger low = selection.location, high = maximumLength;
    NSString *full = prefix;
    while (low < high) {
        NSUInteger mid = low + (high - low + 1) / 2;
        NSString *candidate = readRange(NSMakeRange(0, mid));
        if (candidate != nil) {
            if (candidate.length != mid || ![candidate hasPrefix:prefix]) return nil;
            low = mid; full = candidate;
        } else high = mid - 1;
    }
    if (NSMaxRange(selection) > full.length
        || ![readRange(NSMakeRange(0, full.length)) isEqual:full]
        || readRange(NSMakeRange(0, full.length + 1)) != nil) return nil;
    return full;
}

NSString *CPANormalizeLarkInput(NSString *text, NSRange *selection) {
    NSUInteger start = [text hasPrefix:@"\u200b\n"] ? 2 : 0;
    NSUInteger end = text.length;
    // Lark omits the final newline in its live composer, unlike AXValue writes.
    if (end > start && [text hasSuffix:@"\u200b"]) end--;
    while (end >= start + 2 && [[text substringWithRange:NSMakeRange(end - 2, 2)]
        isEqualToString:@"\u200b\n"]) end -= 2;
    if (selection != NULL && selection->location != NSNotFound) {
        // Live keyboard insertion confirms that Lark's selection counts the
        // leading sentinel, but not the AXValue-only newline following it.
        NSUInteger selectionStart = start > 0 ? 1 : 0;
        NSUInteger selectionEnd = selectionStart + end - start;
        NSUInteger left = MIN(MAX(selection->location, selectionStart), selectionEnd);
        NSUInteger right = selection->length > text.length - MIN(selection->location, text.length)
            ? text.length : selection->location + selection->length;
        right = MIN(MAX(right, left), selectionEnd);
        *selection = NSMakeRange(left - selectionStart, right - left);
    }
    NSString *result = [text substringWithRange:NSMakeRange(start, end - start)];
    if (start == 0 && end < text.length
        && ([[result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            isEqualToString:@"可以向自己发送文件或转发消息"] || [result hasPrefix:@"发送给 "]
            || [result rangeOfString:@"^按住\\s+fn\\s+说话\\s*发送给 [^\\r\\n]*\\s*$"
                options:NSRegularExpressionSearch].location != NSNotFound)) {
        if (selection != NULL) *selection = NSMakeRange(0, 0);
        return @"";
    }
    return result;
}

BOOL CPAIsFeishuDocumentEditor(NSString *bundle, NSString *host, NSString *role, id classes) {
    BOOL supported = [bundle isEqual:@"com.electron.lark"]
        || (CPASuggestionPolicyApplicationIsBrowser(bundle)
            && [CPASuggestionPolicyStore isFeishuDocumentHost:host]);
    return supported && [role isEqual:@"AXTextArea"]
        && [classes isKindOfClass:NSArray.class]
        && [classes containsObject:@"zone-container"] && [classes containsObject:@"text-editor"];
}

static BOOL CPAFeishuDocumentRootClasses(id classes) {
    return [classes isKindOfClass:NSArray.class] && [classes containsObject:@"page-block"]
        && [classes containsObject:@"root-block"];
}

// AX tables expose cells through both rows and columns. Remote AX identity
// survives independently allocated wrappers; ordinary fixture nodes use pointers.
static NSUInteger CPAFeishuNodeHash(const void *node, NSUInteger (*size)(const void *)) {
    (void)size;
    return CFGetTypeID(node) == AXUIElementGetTypeID() ? CFHash(node) : (NSUInteger)node;
}

static BOOL CPAFeishuNodesEqual(const void *left, const void *right, NSUInteger (*size)(const void *)) {
    (void)size;
    return left == right || (CFGetTypeID(left) == AXUIElementGetTypeID()
        && CFGetTypeID(right) == AXUIElementGetTypeID() && CFEqual(left, right));
}

static id CPAFeishuFocusedTextEditorDiagnostic(id root, id (^attribute)(id, NSString *), NSString *__strong *diagnostic) {
    __block NSUInteger nodeCount = 0, aliasCount = 0;
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    id (^finish)(id, NSString *) = ^id(id editor, NSString *reason) {
        if (diagnostic) *diagnostic = [NSString stringWithFormat:@"feishu_editor_stage=%@ nodes=%lu aliases=%lu durationMs=%lu",
            reason, (unsigned long)nodeCount, (unsigned long)aliasCount,
            (unsigned long)((NSProcessInfo.processInfo.systemUptime - started) * 1000)];
        return editor;
    };
    if (!CPAFeishuDocumentRootClasses(attribute(root, @"AXDOMClassList"))) return finish(nil, @"unknown_root");
    NSMutableArray *pending = [NSMutableArray arrayWithObject:@[root, @0, @[]]];
    NSPointerFunctions *identity = [[NSPointerFunctions alloc] initWithOptions:NSPointerFunctionsStrongMemory];
    identity.hashFunction = CPAFeishuNodeHash;
    identity.isEqualFunction = CPAFeishuNodesEqual;
    NSHashTable *visited = [[NSHashTable alloc] initWithPointerFunctions:identity capacity:0];
    id focused = nil;
    while (pending.count) {
        if (visited.count >= 1500) return finish(nil, @"node_limit");
        if (NSProcessInfo.processInfo.systemUptime - started > 0.2) return finish(nil, @"deadline");
        NSArray *entry = pending.lastObject;
        [pending removeLastObject];
        id node = entry[0]; NSUInteger depth = [entry[1] unsignedIntegerValue];
        if (depth > 32) return finish(nil, @"depth_limit");
        NSArray *ancestors = entry[2];
        for (id ancestor in ancestors) {
            if (CPAFeishuNodesEqual((__bridge const void *)node, (__bridge const void *)ancestor, NULL))
                return finish(nil, @"cycle");
        }
        if ([visited containsObject:node]) { aliasCount++; continue; }
        [visited addObject:node];
        nodeCount = visited.count;
        id classes = attribute(node, @"AXDOMClassList");
        if ([classes isKindOfClass:NSArray.class] && [classes containsObject:@"text-editor"]
            && [classes containsObject:@"zone-container"]
            && [attribute(node, @"AXRole") isEqual:@"AXTextArea"]) {
            if ([classes containsObject:@"text-editor-focused"]) {
                if (focused != nil) return finish(nil, @"ambiguous");
                focused = node;
            }
            // Text nodes and nested layout inside an editor are not candidates.
            continue;
        }
        id children = attribute(node, @"AXChildren");
        if (children == nil) continue;
        if (![children isKindOfClass:NSArray.class]) return finish(nil, @"invalid_children");
        if ([children count] + pending.count + visited.count > 1500) return finish(nil, @"node_limit");
        NSArray *childAncestors = [ancestors arrayByAddingObject:node];
        for (id child in children) [pending addObject:@[child, @(depth + 1), childAncestors]];
    }
    return finish(focused, focused ? @"ready" : @"not_found");
}

id CPAFeishuFocusedTextEditor(id root, id (^attribute)(id, NSString *)) {
    return CPAFeishuFocusedTextEditorDiagnostic(root, attribute, NULL);
}

@interface CPAGenericInputBody ()
@property(nonatomic, copy, readwrite) NSString *inputText;
@property(nonatomic, copy, readwrite) NSArray *workBuddyContext;
@property(nonatomic, readwrite) BOOL workBuddyContextReadPending;
@property(nonatomic, readwrite) BOOL hasSelectedRange;
@property(nonatomic, readwrite) NSInteger selectedLocation;
@property(nonatomic, readwrite) NSInteger selectedLength;
@property(nonatomic, readwrite) BOOL writableTextInput;
@property(nonatomic, readwrite) BOOL hasCaretBounds;
@property(nonatomic, readwrite) CGRect caretBounds;
@property(nonatomic, readwrite) BOOL hasElementFrame;
@property(nonatomic, readwrite) CGRect elementFrame;
@end

@implementation CPAGenericInputBody
@end

@interface CPAGenericAccessibilityService () <CPAWorkBuddyTreeReading>
@property(nonatomic, strong) CPAWorkBuddyContextReader *workBuddyReader;
@property(nonatomic, copy, readwrite) NSString *lastInspectionDiagnostic;
@property(nonatomic, strong) CPAInputElementIdentity *inputIdentity;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *runtimeAccessibilityAttempts;
@property(nonatomic, strong) CPAWPSInputBridge *wpsBridge;
@end

@implementation CPAGenericAccessibilityService

- (id)workBuddyAttribute:(NSString *)attribute element:(id)element {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue((__bridge AXUIElementRef)element,
        (__bridge CFStringRef)attribute, &value);
    if (error != kAXErrorSuccess) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

- (NSDictionary *)workBuddyStructureAttributesForElement:(id)element {
    NSArray *names = @[@"AXDOMClassList", @"AXChildren", @"AXParent", @"AXRole"];
    CFArrayRef values = NULL;
    AXError error = AXUIElementCopyMultipleAttributeValues((__bridge AXUIElementRef)element,
        (__bridge CFArrayRef)names, 0, &values);
    if (error != kAXErrorSuccess || values == NULL) { if (values) CFRelease(values); return nil; }
    NSArray *result = CFBridgingRelease(values);
    if (result.count != names.count) return nil;
    NSMutableDictionary *batch = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < names.count; i++) {
        id value = result[i];
        if (CFGetTypeID((__bridge CFTypeRef)value) == AXValueGetTypeID()
            && AXValueGetType((__bridge AXValueRef)value) == kAXValueAXErrorType) value = NSNull.null;
        batch[names[i]] = value;
    }
    return batch;
}

- (NSArray *)workBuddyContextForElement:(AXUIElementRef)element metadata:(CPAFocusedInputMetadata *)metadata
    pending:(BOOL *)pending {
    *pending = NO;
    if (!CPASuggestionPolicyApplicationIsWorkBuddy(metadata.bundleIdentifier)
        || self.policyCoordinator == nil || self.contextReadingPaused == nil) return nil;
    NSUInteger version = self.policyCoordinator.ruleVersion;
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    __block NSTimeInterval lastFocusCheck = 0;
    BOOL (^current)(void) = ^BOOL {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now - started > 0.5 || self.contextReadingPaused()
            || version != self.policyCoordinator.ruleVersion) return NO;
        if (lastFocusCheck == 0 || now - lastFocusCheck > 0.05) {
            lastFocusCheck = now;
            AXUIElementRef focused = [self copyFocusedElementForProcessIdentifier:metadata.processIdentifier];
            BOOL matches = focused != NULL && CFEqual(focused, element)
                && [self metadata:metadata matchesBundleIdentifier:metadata.bundleIdentifier
                    processIdentifier:metadata.processIdentifier element:focused];
            if (focused) CFRelease(focused);
            if (!matches) return NO;
        }
        return YES;
    };
    CPASuggestionDecision *decision = [self.policyCoordinator decisionForBundleIdentifier:metadata.bundleIdentifier
        role:metadata.role subrole:metadata.subrole semanticMetadata:metadata.semanticMetadata
        browserHost:metadata.browserHost globallyPaused:self.contextReadingPaused() temporarilyPaused:NO];
    if (decision.outcome == CPASuggestionPolicyOutcomeDisabled
        || decision.contextMode != CPAContextAccessModeWorkBuddyConversation) return nil;
    if (!current()) { *pending = YES; return nil; }
    if (self.workBuddyReader == nil) self.workBuddyReader = [CPAWorkBuddyContextReader new];
    NSArray *context = [self.workBuddyReader readComposer:(__bridge id)element tree:self stillCurrent:current];
    lastFocusCheck = 0;
    BOOL valid = current();
    *pending = !valid || self.workBuddyReader.readPending;
    self.lastInspectionDiagnostic = [NSString stringWithFormat:@"%@ %@ contextReadMs=%lu contextCurrent=%@ contextReadPending=%@",
        self.lastInspectionDiagnostic, self.workBuddyReader.diagnostic,
        (unsigned long)((NSProcessInfo.processInfo.systemUptime - started) * 1000), valid ? @"true" : @"false", *pending ? @"true" : @"false"];
    return valid ? context : nil;
}


- (void)prepareRuntimeAccessibilityForBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier {
    if (!CPASuggestionPolicyApplicationIsWorkBuddy(bundleIdentifier)
        && ![bundleIdentifier isEqualToString:@"com.electron.lark"]) return;
    if (self.runtimeAccessibilityAttempts == nil)
        self.runtimeAccessibilityAttempts = [NSMutableSet set];
    if ([self.runtimeAccessibilityAttempts containsObject:@(processIdentifier)]) return;
    [self.runtimeAccessibilityAttempts addObject:@(processIdentifier)];
    AXUIElementRef application = AXUIElementCreateApplication(processIdentifier);
    // Electron may not expose the composer until a client explicitly opts in.
    // Unsupported attributes are harmless; ordinary focus and policy gates still apply.
    AXUIElementSetAttributeValue(application, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
    AXUIElementSetAttributeValue(application, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
    CFRelease(application);
}


- (nullable AXUIElementRef)copyFocusedElementForProcessIdentifier:
    (pid_t)processIdentifier {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(systemWide,
        kAXFocusedUIElementAttribute, &value);
    CFRelease(systemWide);
    pid_t focusedProcessIdentifier = 0;
    AXError systemError = error;
    BOOL systemValueMatchesProcess = error == kAXErrorSuccess && value != NULL
        && CFGetTypeID(value) == AXUIElementGetTypeID()
        && AXUIElementGetPid((AXUIElementRef)value,
            &focusedProcessIdentifier) == kAXErrorSuccess
        && focusedProcessIdentifier == processIdentifier;
    if (!systemValueMatchesProcess) {
        if (value != NULL) {
            CFRelease(value);
        }
        AXUIElementRef application = AXUIElementCreateApplication(processIdentifier);
        value = NULL;
        error = AXUIElementCopyAttributeValue(application,
            kAXFocusedUIElementAttribute, &value);
        CFRelease(application);
    }
    focusedProcessIdentifier = 0;
    BOOL applicationValueMatchesProcess = error == kAXErrorSuccess
        && value != NULL && CFGetTypeID(value) == AXUIElementGetTypeID()
        && AXUIElementGetPid((AXUIElementRef)value,
            &focusedProcessIdentifier) == kAXErrorSuccess
        && focusedProcessIdentifier == processIdentifier;
    self.lastInspectionDiagnostic = [NSString stringWithFormat:
        @"focusProbePID=%d focusSystemError=%d focusAppError=%d focusOwnerPID=%d focusMatched=%@",
        processIdentifier, (int)systemError, (int)error, focusedProcessIdentifier,
        applicationValueMatchesProcess ? @"true" : @"false"];
    if (!applicationValueMatchesProcess) {
        if (value != NULL) {
            CFRelease(value);
        }
        return NULL;
    }
    NSString *bundle = [NSRunningApplication runningApplicationWithProcessIdentifier:processIdentifier].bundleIdentifier;
    BOOL feishuDocument = [bundle isEqual:@"com.electron.lark"]
        || (CPASuggestionPolicyApplicationIsBrowser(bundle)
            && [CPASuggestionPolicyStore isFeishuDocumentHost:
                [self browserHostForElement:(AXUIElementRef)value bundleIdentifier:bundle]]);
    if (feishuDocument && CPAFeishuDocumentRootClasses(
        [self workBuddyAttribute:@"AXDOMClassList" element:(__bridge id)value])) {
        // Feishu reports focus on the whole document, including its title,
        // author and toolbar. Its active editor exposes a paragraph-local range.
        // Resolve before policy/body reading and again during final acceptance.
        NSString *editorDiagnostic = nil;
        id editor = CPAFeishuFocusedTextEditorDiagnostic((__bridge id)value, ^id(id node, NSString *name) {
            return [self workBuddyAttribute:name element:node];
        }, &editorDiagnostic);
        AXUIElementRef resolved = editor ? (AXUIElementRef)CFRetain((__bridge CFTypeRef)editor) : NULL;
        CFRelease(value);
        self.lastInspectionDiagnostic = [NSString stringWithFormat:@"%@ %@",
            resolved ? @"feishu_active_editor_verified" : @"feishu_active_editor_unverified", editorDiagnostic];
        return resolved;
    }
    return (AXUIElementRef)value;
}

- (nullable NSString *)stringAttribute:(CFStringRef)attribute
    element:(AXUIElementRef)element {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL) {
        if (value != NULL) {
            CFRelease(value);
        }
        return nil;
    }
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value copy];
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        result = [(__bridge NSNumber *)value stringValue];
    }
    CFRelease(value);
    return result;
}

- (nullable NSString *)URLLikeStringAttribute:(CFStringRef)attribute
    element:(AXUIElementRef)element {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL) {
        if (value != NULL) {
            CFRelease(value);
        }
        return nil;
    }
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value copy];
    } else if (CFGetTypeID(value) == CFURLGetTypeID()) {
        result = [(__bridge NSURL *)value absoluteString];
    }
    CFRelease(value);
    return result;
}

- (NSString *)browserDocumentURLForElement:(AXUIElementRef)element {
    AXUIElementRef current = element;
    CFRetain(current);
    for (NSUInteger depth = 0; depth < 32 && current != NULL; depth++) {
        // The nearest web area owns the focused field. Never authorize a link's
        // target URL or a containing trusted page around an untrusted iframe.
        if ([[self stringAttribute:kAXRoleAttribute element:current] isEqual:@"AXWebArea"]) {
            NSString *url = [self URLLikeStringAttribute:CFSTR("AXURL") element:current];
            if (!url.length) url = [self URLLikeStringAttribute:CFSTR("AXDocument") element:current];
            CFRelease(current); return url ?: @"";
        }
        CFTypeRef parent = NULL;
        AXError error = AXUIElementCopyAttributeValue(current, kAXParentAttribute, &parent);
        CFRelease(current); current = NULL;
        if (error != kAXErrorSuccess || parent == NULL
            || CFGetTypeID(parent) != AXUIElementGetTypeID()) {
            if (parent) CFRelease(parent);
            break;
        }
        current = (AXUIElementRef)parent;
    }
    if (current) CFRelease(current);
    return @"";
}

- (NSString *)browserHostForElement:(AXUIElementRef)element
    bundleIdentifier:(NSString *)bundleIdentifier {
    if (!CPASuggestionPolicyApplicationIsBrowser(bundleIdentifier)) return @"";
    return CPABrowserHostFromDocumentValue([self browserDocumentURLForElement:element]);
}

- (NSString *)fieldIdentityForElement:(AXUIElementRef)element {
    NSString *rendererIdentifier = @"";
    for (NSString *attribute in @[@"AXIdentifier", @"ChromeAXNodeId", @"AXDOMIdentifier"]) {
        NSString *value = [self stringAttribute:(__bridge CFStringRef)attribute element:element];
        if (value.length > 0) { rendererIdentifier = value; break; }
    }
    // Only an opaque token leaves this object. Full URL stays transient and
    // makes navigation to another document revoke even an identical draft.
    NSString *documentURL = [self browserDocumentURLForElement:element];
    if ([CPASuggestionPolicyStore isFeishuDocumentHost:CPABrowserHostFromDocumentValue(documentURL)])
        rendererIdentifier = [rendererIdentifier stringByAppendingFormat:@"|%@", documentURL];
    CFTypeRef window = NULL;
    AXUIElementCopyAttributeValue(element, kAXWindowAttribute, &window);
    if (window != NULL && CFGetTypeID(window) != AXUIElementGetTypeID()) {
        CFRelease(window); window = NULL;
    }
    if (self.inputIdentity == nil) self.inputIdentity = [CPAInputElementIdentity new];
    NSString *token = [self.inputIdentity tokenForElement:(__bridge id)element
        window:(__bridge id)window rendererIdentifier:rendererIdentifier];
    if (window != NULL) CFRelease(window);
    return token;
}

- (NSArray<NSString *> *)semanticMetadataForElement:(AXUIElementRef)element {
    NSArray<NSString *> *attributes = @[
        (__bridge NSString *)kAXTitleAttribute,
        (__bridge NSString *)kAXDescriptionAttribute,
        (__bridge NSString *)kAXPlaceholderValueAttribute,
        (__bridge NSString *)kAXHelpAttribute,
        @"AXDOMIdentifier",
        @"AXARIAProperties",
    ];
    NSMutableArray<NSString *> *values = [[NSMutableArray alloc] init];
    for (NSString *attribute in attributes) {
        NSString *value = [self stringAttribute:(__bridge CFStringRef)attribute
            element:element];
        if (value.length > 0 && value.length <= 512) {
            [values addObject:value];
        }
    }
    return values;
}

- (nullable CPAFocusedInputMetadata *)inspectFocusedInputMetadata {
    NSDictionary *options = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @NO,
    };
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        return nil;
    }
    NSRunningApplication *application =
        NSWorkspace.sharedWorkspace.frontmostApplication;
    NSString *bundleIdentifier = application.bundleIdentifier ?: @"";
    if (application == nil || bundleIdentifier.length == 0
        || [bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {
        return nil;
    }
    return [self inspectFocusedInputMetadataForBundleIdentifier:bundleIdentifier
        processIdentifier:application.processIdentifier];
}

- (nullable CPAFocusedInputMetadata *)
    inspectFocusedInputMetadataForBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier {
    if (bundleIdentifier.length == 0 || processIdentifier <= 0
        || [bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {
        return nil;
    }
    NSDictionary *options = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @NO,
    };
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        return nil;
    }
    [self prepareRuntimeAccessibilityForBundleIdentifier:bundleIdentifier
        processIdentifier:processIdentifier];
    AXUIElementRef element = [self copyFocusedElementForProcessIdentifier:
        processIdentifier];
    if (element == NULL) {
        return nil;
    }
    NSString *role = [self stringAttribute:kAXRoleAttribute element:element] ?: @"";
    NSString *subrole = [self stringAttribute:kAXSubroleAttribute element:element] ?: @"";
    NSString *identity = [self fieldIdentityForElement:element];
    NSArray<NSString *> *semantics = [self semanticMetadataForElement:element];
    if ([bundleIdentifier isEqualToString:@"com.kingsoft.wpsoffice.mac"]
        && [role isEqualToString:@"AXSplitGroup"]) {
        if (self.wpsBridge == nil) self.wpsBridge = [CPAWPSInputBridge new];
        NSDictionary *state = [self.wpsBridge requestPhase:@"metadata"
            processIdentifier:processIdentifier documentId:nil];
        if ([state[@"documentId"] isKindOfClass:NSString.class]) {
            identity = [@"wps:" stringByAppendingString:state[@"documentId"]];
            role = @"AXTextArea";
            semantics = [semantics arrayByAddingObject:@"document editor"];
        }
    }
    NSString *browserHost = [self browserHostForElement:element
        bundleIdentifier:bundleIdentifier];
    CFTypeRef classes = NULL;
    AXUIElementCopyAttributeValue(element, CFSTR("AXDOMClassList"), &classes);
    BOOL documentContinuation = CPAIsFeishuDocumentEditor(bundleIdentifier, browserHost, role, (__bridge id)classes);
    if (classes) CFRelease(classes);
    CFRelease(element);
    CPAFocusedInputMetadata *metadata = [[CPAFocusedInputMetadata alloc]
        initWithBundleIdentifier:bundleIdentifier
        role:role
        subrole:subrole
        semanticMetadata:semantics
        browserHost:browserHost
        processIdentifier:processIdentifier
        fieldIdentity:identity];
    metadata.documentContinuation = documentContinuation;
    return metadata;
}

- (BOOL)metadata:(CPAFocusedInputMetadata *)metadata
    matchesBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier
    element:(AXUIElementRef)element {
    if (processIdentifier != metadata.processIdentifier
        || ![bundleIdentifier isEqualToString:metadata.bundleIdentifier]) {
        return NO;
    }
    if (CPASuggestionPolicyApplicationIsBrowser(bundleIdentifier)
        && ![[self browserHostForElement:element bundleIdentifier:bundleIdentifier] isEqual:metadata.browserHost]) return NO;
    NSString *role = [self stringAttribute:kAXRoleAttribute element:element] ?: @"";
    NSString *subrole = [self stringAttribute:kAXSubroleAttribute element:element] ?: @"";
    if (![role isEqualToString:metadata.role]
        || ![subrole isEqualToString:metadata.subrole]) {
        return NO;
    }
    if (metadata.fieldIdentity.length > 0) {
        NSString *identity = [self fieldIdentityForElement:element];
        return [identity isEqualToString:metadata.fieldIdentity];
    }
    return YES;
}

- (BOOL)metadata:(CPAFocusedInputMetadata *)metadata
    matchesApplication:(NSRunningApplication *)application
    element:(AXUIElementRef)element {
    if (application.processIdentifier != metadata.processIdentifier
        || ![application.bundleIdentifier isEqualToString:metadata.bundleIdentifier]) {
        return NO;
    }
    NSString *role = [self stringAttribute:kAXRoleAttribute element:element] ?: @"";
    NSString *subrole = [self stringAttribute:kAXSubroleAttribute element:element] ?: @"";
    if (![role isEqualToString:metadata.role]
        || ![subrole isEqualToString:metadata.subrole]) {
        return NO;
    }
    if (metadata.fieldIdentity.length > 0) {
        NSString *identity = [self fieldIdentityForElement:element];
        return [identity isEqualToString:metadata.fieldIdentity];
    }
    return YES;
}

- (nullable CPAGenericInputBody *)readInputBodyForMetadata:
    (CPAFocusedInputMetadata *)metadata {
    if (metadata.processIdentifier <= 0
        || metadata.bundleIdentifier.length == 0) {
        return nil;
    }
    AXUIElementRef element = [self copyFocusedElementForProcessIdentifier:
        metadata.processIdentifier];
    if (element == NULL) {
        return nil;
    }
    BOOL usesWPSBridge = [metadata.bundleIdentifier isEqualToString:@"com.kingsoft.wpsoffice.mac"]
        && [metadata.fieldIdentity hasPrefix:@"wps:"];
    if (!usesWPSBridge && ![self metadata:metadata
            matchesBundleIdentifier:metadata.bundleIdentifier
            processIdentifier:metadata.processIdentifier
            element:element]) {
        CFRelease(element);
        return nil;
    }
    NSDictionary *wpsState = nil;
    if (usesWPSBridge) {
        if (![[self stringAttribute:kAXRoleAttribute element:element] isEqualToString:@"AXSplitGroup"]) {
            CFRelease(element); return nil;
        }
        wpsState = [self.wpsBridge requestPhase:@"body" processIdentifier:metadata.processIdentifier
            documentId:[metadata.fieldIdentity substringFromIndex:4]];
    }
    NSString *value = usesWPSBridge ? wpsState[@"text"]
        : [self stringAttribute:kAXValueAttribute element:element];
    if (usesWPSBridge && (![value isKindOfClass:NSString.class] || value.length > 2000
        || ![wpsState[@"cursor"] isKindOfClass:NSNumber.class]
        || [wpsState[@"cursor"] integerValue] < 0 || [wpsState[@"cursor"] unsignedIntegerValue] > value.length)) {
        CFRelease(element); return nil;
    }
    if (value == nil) {
        CFRelease(element);
        return nil;
    }
    CPAGenericInputBody *body = [[CPAGenericInputBody alloc] init];
    body.inputText = value;
    CFRange originalSelection = CFRangeMake(-1, 0);

    CFTypeRef rangeValue = NULL;
    AXError rangeError = AXUIElementCopyAttributeValue(element,
        kAXSelectedTextRangeAttribute, &rangeValue);
    if (rangeError == kAXErrorSuccess && rangeValue != NULL
        && CFGetTypeID(rangeValue) == AXValueGetTypeID()
        && AXValueGetType((AXValueRef)rangeValue) == kAXValueCFRangeType) {
        CFRange range = CFRangeMake(0, 0);
        if (AXValueGetValue((AXValueRef)rangeValue, kAXValueCFRangeType, &range)) {
            originalSelection = range;
            body.hasSelectedRange = YES;
            body.selectedLocation = range.location;
            body.selectedLength = range.length;
        }
        CFTypeRef boundsValue = NULL;
        AXError boundsError = AXUIElementCopyParameterizedAttributeValue(element,
            kAXBoundsForRangeParameterizedAttribute, rangeValue, &boundsValue);
        if (boundsError == kAXErrorSuccess && boundsValue != NULL
            && CFGetTypeID(boundsValue) == AXValueGetTypeID()
            && AXValueGetType((AXValueRef)boundsValue) == kAXValueCGRectType) {
            CGRect bounds = CGRectZero;
            if (AXValueGetValue((AXValueRef)boundsValue,
                    kAXValueCGRectType, &bounds)
                && isfinite(bounds.origin.x) && isfinite(bounds.origin.y)
                && isfinite(bounds.size.height) && bounds.size.height > 0.0) {
                body.hasCaretBounds = YES;
                body.caretBounds = bounds;
            }
        }
        if (boundsValue != NULL) {
            CFRelease(boundsValue);
        }
    }
    if (rangeValue != NULL) {
        CFRelease(rangeValue);
    }

    CFTypeRef positionValue = NULL;
    CFTypeRef sizeValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute,
            &positionValue) == kAXErrorSuccess
        && AXUIElementCopyAttributeValue(element, kAXSizeAttribute,
            &sizeValue) == kAXErrorSuccess
        && positionValue != NULL && sizeValue != NULL
        && CFGetTypeID(positionValue) == AXValueGetTypeID()
        && CFGetTypeID(sizeValue) == AXValueGetTypeID()
        && AXValueGetType((AXValueRef)positionValue) == kAXValueCGPointType
        && AXValueGetType((AXValueRef)sizeValue) == kAXValueCGSizeType) {
        CGPoint position = CGPointZero;
        CGSize size = CGSizeZero;
        if (AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &position)
            && AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size)
            && size.width > 0.0 && size.height > 0.0) {
            body.hasElementFrame = YES;
            body.elementFrame = CGRectMake(position.x, position.y,
                size.width, size.height);
        }
    }
    if (positionValue != NULL) {
        CFRelease(positionValue);
    }
    if (sizeValue != NULL) {
        CFRelease(sizeValue);
    }

    Boolean settable = false;
    AXError settableError = AXUIElementIsAttributeSettable(element,
        kAXValueAttribute, &settable);
    if (usesWPSBridge) {
        body.hasSelectedRange = YES;
        body.selectedLocation = [wpsState[@"cursor"] integerValue];
        body.selectedLength = 0;
    }
    BOOL usesLarkRanges = [metadata.bundleIdentifier isEqualToString:@"com.electron.lark"]
        || (CPASuggestionPolicyApplicationIsBrowser(metadata.bundleIdentifier)
            && [CPASuggestionPolicyStore isFeishuDocumentHost:metadata.browserHost]);
    if (usesLarkRanges
        && body.hasSelectedRange && body.selectedLocation >= 0 && body.selectedLength >= 0) {
        NSRange selection = NSMakeRange(body.selectedLocation, body.selectedLength);
        body.inputText = CPANormalizeLarkInput(value, &selection);
        if (body.inputText.length && body.selectedLength == 0) {
            __block BOOL rangeReadFailed = NO;
            NSString *cursorText = CPALarkReadCursorText(value.length,
                NSMakeRange(body.selectedLocation, body.selectedLength), ^NSString *(NSRange requested) {
                    CFRange range = CFRangeMake(requested.location, requested.length);
                    AXValueRef parameter = AXValueCreate(kAXValueCFRangeType, &range);
                    CFTypeRef result = NULL;
                    AXError error = AXUIElementCopyParameterizedAttributeValue(element,
                        kAXStringForRangeParameterizedAttribute, parameter, &result);
                    CFRelease(parameter);
                    id text = CFBridgingRelease(result);
                    if (error == kAXErrorNoValue) return nil; // Range extends past the logical end.
                    if (error != kAXErrorSuccess || ![text isKindOfClass:NSString.class]) {
                        rangeReadFailed = YES; return nil;
                    }
                    return text;
                });
            if (cursorText == nil || rangeReadFailed) {
                self.lastInspectionDiagnostic = @"lark_cursor_mapping_unverified";
                CFRelease(element); return nil;
            }
            // The legacy normalizer expects the leading wrapper's layout LF
            // excluded from the coordinate; range text counts actual characters.
            NSUInteger offset = body.selectedLocation;
            selection = NSMakeRange(offset - ([cursorText hasPrefix:@"\u200b\n"] && offset > 0 ? 1 : 0), 0);
            body.inputText = CPANormalizeLarkInput(cursorText, &selection);
        }
        body.selectedLocation = selection.location;
        body.selectedLength = selection.length;
    }
    body.writableTextInput = body.hasSelectedRange
        || (settableError == kAXErrorSuccess && settable);
    BOOL contextPending = NO;
    body.workBuddyContext = [self workBuddyContextForElement:element metadata:metadata pending:&contextPending];
    body.workBuddyContextReadPending = contextPending;
    NSString *contextDiagnostic = self.lastInspectionDiagnostic;
    if (CPASuggestionPolicyApplicationIsWorkBuddy(metadata.bundleIdentifier)
        || usesLarkRanges) {
        AXUIElementRef focused = [self copyFocusedElementForProcessIdentifier:metadata.processIdentifier];
        BOOL current = focused != NULL && CFEqual(focused, element)
            && [self metadata:metadata matchesBundleIdentifier:metadata.bundleIdentifier
                processIdentifier:metadata.processIdentifier element:focused];
        if (current) current = [[self stringAttribute:kAXValueAttribute element:focused] isEqual:value];
        if (current && usesLarkRanges) {
            CFTypeRef latestRange = NULL;
            CFRange latest = CFRangeMake(-1, 0);
            AXError latestError = AXUIElementCopyAttributeValue(focused,
                kAXSelectedTextRangeAttribute, &latestRange);
            current = latestError == kAXErrorSuccess && latestRange
                && CFGetTypeID(latestRange) == AXValueGetTypeID()
                && AXValueGetType((AXValueRef)latestRange) == kAXValueCFRangeType
                && AXValueGetValue((AXValueRef)latestRange, kAXValueCFRangeType, &latest)
                && latest.location == originalSelection.location && latest.length == originalSelection.length;
            if (latestRange) CFRelease(latestRange);
        }
        if (focused) CFRelease(focused);
        if (!current) { CFRelease(element); return nil; }
    }
    self.lastInspectionDiagnostic = contextDiagnostic;
    CFRelease(element);
    return body;
}

@end
