#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

#import "../../Sources/CodexPromptAssistantPOC/GenericAccessibilityService.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

#include "WorkBuddyContextReaderTests.inc"

int main(void) {
    @autoreleasepool {
        WorkBuddyReaderTests();
        NSArray *documentClasses = @[@"zone-container", @"text-editor", @"text-editor-focused"];
        Assert(CPAIsFeishuDocumentEditor(@"com.electron.lark", @"", @"AXTextArea", documentClasses),
            @"native document paragraph uses document continuation");
        Assert(CPAIsFeishuDocumentEditor(@"com.google.Chrome", @"team.feishu.cn", @"AXTextArea", documentClasses),
            @"verified browser document paragraph uses document continuation");
        Assert(!CPAIsFeishuDocumentEditor(@"com.electron.lark", @"", @"AXTextArea", @[@"chat-input"])
            && !CPAIsFeishuDocumentEditor(@"com.google.Chrome", @"example.com", @"AXTextArea", documentClasses)
            && !CPAIsFeishuDocumentEditor(@"com.openai.codex", @"", @"AXTextArea", documentClasses)
            && !CPAIsFeishuDocumentEditor(@"com.electron.lark", @"", @"AXTextField", documentClasses),
            @"chat, unknown sites, other apps and non-body fields retain prompt mode");
        NSDictionary *title = @{@"AXRole":@"AXTextArea", @"AXDOMClassList":@[@"zone-container", @"text-editor"]};
        NSDictionary *paragraph = @{@"AXRole":@"AXTextArea", @"AXDOMClassList":@[@"zone-container", @"text-editor", @"text-editor-focused"]};
        NSDictionary *(^rootWith)(NSArray *) = ^NSDictionary *(NSArray *children) {
            return @{@"AXDOMClassList":@[@"page-block", @"root-block"], @"AXChildren":children};
        };
        id (^metadataOnly)(id, NSString *) = ^id(id node, NSString *name) {
            Assert([@[@"AXDOMClassList", @"AXRole", @"AXChildren"] containsObject:name],
                @"paragraph resolution must not read body, title or selection text before policy");
            return node[name];
        };
        Assert(CPAFeishuFocusedTextEditor(rootWith(@[title, @{@"AXChildren":@[paragraph]}]), metadataOnly) == paragraph,
            @"Feishu root focus must resolve to its active paragraph, excluding page chrome");
        Assert(CPAFeishuFocusedTextEditor(rootWith(@[paragraph, title]), metadataOnly) == paragraph,
            @"paragraph resolution does not depend on document order");
        // AX tables may expose the same cell through rows and columns. Separate
        // AX references to one remote object compare equal but have different pointers.
        id cellRefA = CFBridgingRelease(AXUIElementCreateApplication(4242));
        id cellRefB = CFBridgingRelease(AXUIElementCreateApplication(4242));
        Assert(cellRefA != cellRefB && CFEqual((__bridge CFTypeRef)cellRefA, (__bridge CFTypeRef)cellRefB),
            @"fixture must model distinct wrappers for the same accessibility element");
        id (^aliasedMetadata)(id, NSString *) = ^id(id node, NSString *name) {
            return metadataOnly((node == cellRefA || node == cellRefB) ? paragraph : node, name);
        };
        id aliasRoot = rootWith(@[@{@"AXChildren":@[cellRefA]}, @{@"AXChildren":@[cellRefB]}]);
        Assert(CPAFeishuFocusedTextEditor(aliasRoot, aliasedMetadata) != nil,
            @"table row/column aliases of one focused paragraph must not become ambiguous");
        Assert(CPAFeishuFocusedTextEditor(rootWith(@[paragraph, paragraph]), metadataOnly) == paragraph,
            @"a shared paragraph node is scanned once");
        NSMutableDictionary *cycle = [@{} mutableCopy];
        cycle[@"AXChildren"] = @[cycle];
        Assert(CPAFeishuFocusedTextEditor(rootWith(@[paragraph, cycle]), metadataOnly) == nil,
            @"a genuine ancestor cycle stays rejected, unlike a shared cell alias");
        [cycle removeAllObjects];
        Assert(CPAFeishuFocusedTextEditor(rootWith(@[title]), metadataOnly) == nil,
            @"no active paragraph must not fall back to document text");
        Assert(CPAFeishuFocusedTextEditor(rootWith(@[paragraph, [paragraph mutableCopy]]), metadataOnly) == nil,
            @"two active editors are ambiguous and must fail closed");
        Assert(CPAFeishuFocusedTextEditor(@{@"AXChildren":@[paragraph]}, metadataOnly) == nil,
            @"unrecognized editor containers are not scanned");
        NSMutableArray *oversized = [NSMutableArray array];
        for (NSUInteger i = 0; i < 1501; i++) [oversized addObject:@{}];
        Assert(CPAFeishuFocusedTextEditor(rootWith(oversized), metadataOnly) == nil,
            @"large documents stay bounded without a guessed paragraph");
        NSString *logical = @"前文\n表格正文。请说明的原因。后文保持。";
        __block NSUInteger reads = 0;
        NSString *(^reader)(NSRange) = ^NSString *(NSRange r) {
            reads++;
            return NSMaxRange(r) <= logical.length ? [logical substringWithRange:r] : nil;
        };
        Assert([CPALarkReadCursorText(1366, NSMakeRange(12, 0), reader) isEqual:logical]
            && reads < 20, @"range text preserves both sides despite AXValue layout/table differences");
        Assert([CPALarkReadCursorText(logical.length, NSMakeRange(logical.length, 0), reader) isEqual:logical],
            @"logical end cursor remains supported");
        Assert(CPALarkReadCursorText(8, NSMakeRange(3, 0), reader) == nil,
            @"a logical body longer than AXValue bound is never silently cut");
        Assert(CPALarkReadCursorText(70000, NSMakeRange(3, 0), reader) == nil,
            @"oversized AX projections fail closed without a scan");
        __block NSUInteger equalLengthReads = 0;
        Assert(CPALarkReadCursorText(1366, NSMakeRange(12, 0), ^NSString *(NSRange r) {
            NSString *part = reader(r);
            if (r.length == logical.length && ++equalLengthReads > 1) return @"changed";
            return part;
        }) == nil, @"a document change during range read invalidates the body");
        Assert(CPALarkReadCursorText(1366, NSMakeRange(12, 0), ^NSString *(NSRange r) {
            NSString *part = reader(r);
            return part && r.length > 12 ? [@"错" stringByAppendingString:[part substringFromIndex:1]] : part;
        }) == nil, @"full range and cursor prefix must belong to the same text");
        NSRange selection = NSMakeRange(15, 0);
        Assert(CPANormalizeLarkInput(@"可以向自己发送文件或转发消息\n\u200b\n\u200b\n", &selection).length == 0
            && selection.location == 0, @"Lark's self-chat placeholder is not a user draft");
        selection = NSMakeRange(5, 0);
        Assert([CPANormalizeLarkInput(@"\u200b\n继续支持\u200b\n\u200b\n", &selection)
            isEqualToString:@"继续支持"] && selection.location == 4,
            @"Lark visual end-of-input must map past only its invisible wrapper");
        selection = NSMakeRange(5, 0);
        Assert([CPANormalizeLarkInput(@"\u200b\n继续支持\u200b\n\u200b\n\u200b", &selection)
            isEqualToString:@"继续支持"] && selection.location == 4,
            @"live Lark composers can end in a bare zero-width sentinel");
        Assert(CPANormalizeLarkInput(@"发送给 测试\n\u200b\n\u200b", NULL).length == 0,
            @"recipient placeholders must not become draft content");
        selection = NSMakeRange(19, 0);
        Assert(CPANormalizeLarkInput(@"按住 \nfn \n说话\n发送给 合成群聊\n\u200b\n\u200b\n\u200b", &selection).length == 0
            && selection.location == 0, @"voice hint plus recipient placeholder is not a draft for middle insertion");
        selection = NSMakeRange(3, 0);
        Assert([CPANormalizeLarkInput(@"\u200b\n继续支持\u200b\n", &selection)
            isEqualToString:@"继续支持"] && selection.location == 2,
            @"real mid-text cursors must remain mid-text");
        selection = NSMakeRange(0, 4);
        Assert([CPANormalizeLarkInput(@"\u200b\n继续支持\u200b\n", &selection)
            isEqualToString:@"继续支持"] && selection.location == 0 && selection.length == 3,
            @"selections crossing the wrapper must map without underflow");
        selection = NSMakeRange(5, 0);
        Assert([CPANormalizeLarkInput(@"第一行\n第二行\n", &selection)
            isEqualToString:@"第一行\n第二行\n"] && selection.location == 5,
            @"ordinary paragraph breaks must remain untouched");
        Assert([CPABrowserHostFromDocumentValue(
                @"https://Docs.Example.com/private?q=secret#draft")
                isEqualToString:@"docs.example.com"],
            @"browser metadata should retain only a normalized hostname");
        Assert([CPABrowserHostFromDocumentValue(
                @"https://user:password@sub.example.com:8443/path")
                isEqualToString:@"sub.example.com"],
            @"credentials, ports, and paths must be discarded");
        Assert(CPABrowserHostFromDocumentValue(@"file:///Users/test/private.txt")
                .length == 0,
            @"local documents must not become browser site rules");
        Assert(CPABrowserHostFromDocumentValue(@"chrome://settings/passwords")
                .length == 0,
            @"browser internal pages must not become site rules");
        Assert(CPABrowserHostFromDocumentValue(@"not a url").length == 0,
            @"invalid browser document metadata must be rejected");
        for (NSString *url in @[@"https://tenant.feishu.cn/docx/Abc123", @"https://TENANT.feishu.cn/docs/Abc123#cursor", @"https://tenant.feishu.cn/wiki/Abc123?from=share"])
            Assert([CPABrowserHostFromDocumentValue(url) isEqual:@"tenant.feishu.cn"], @"HTTPS Feishu document route is recognized");
        for (NSString *url in @[@"https://tenant.feishu.cn/", @"https://tenant.feishu.cn/accounts/login",
            @"http://tenant.feishu.cn/docx/Abc123", @"https://user:pass@tenant.feishu.cn/docx/Abc123",
            @"https://tenant.feishu.cn:9443/docx/Abc123", @"https://tenant.feishu.cn/docx/",
            @"https://tenant.feishu.cn/docx/Abc123/other", @"tenant.feishu.cn/docx/Abc123"])
            Assert(CPABrowserHostFromDocumentValue(url).length == 0, @"non-document or ambiguous Feishu URL fails closed");
        NSLog(@"PASS: GenericAccessibilityServiceTests");
    }
    return 0;
}
