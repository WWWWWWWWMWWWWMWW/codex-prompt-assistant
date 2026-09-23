#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.h"
#import "../../Sources/CodexPromptAssistantPOC/LocalSuggestionCoordinator.h"
#import "../../Sources/CodexPromptAssistantPOC/InputElementIdentity.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPAAccessibilitySnapshot *Snapshot(NSString *text) {
    CPAAccessibilitySnapshot *snapshot = [[CPAAccessibilitySnapshot alloc] init];
    snapshot.writableTextInput = YES;
    snapshot.hasElementFrame = YES;
    snapshot.hasValueCharacterCount = YES;
    snapshot.valueCharacterCount = text.length;
    snapshot.hasSelectedRange = YES;
    snapshot.selectedLocation = text.length;
    snapshot.selectedLength = 0;
    snapshot.inputText = text;
    return snapshot;
}

int main(void) {
    @autoreleasepool {
        __block NSString *lookedUpText = nil;
        CPALocalSuggestionCoordinator *coordinator =
            [[CPALocalSuggestionCoordinator alloc]
                initWithLookup:^NSString *(NSString *input, NSUInteger cursorLocation,
                    NSUInteger selectedLength) {
                    lookedUpText = input;
                    if ([input isEqualToString:@"请先"]
                        && cursorLocation == 2 && selectedLength == 0) {
                        return @"把方案梳理清楚。";
                    }
                    return nil;
                }];
        CPAAccessibilitySnapshot *snapshot = Snapshot(@"请先");
        NSString *signature = [coordinator inputSignatureForSnapshot:snapshot];
        snapshot.documentContinuation = YES;
        Assert(![[coordinator inputSignatureForSnapshot:snapshot] isEqual:signature],
            @"mode changes must invalidate pending display and acceptance signatures");
        snapshot.documentContinuation = NO;
        [coordinator prepareRemoteInsertion:@"旧候选" signature:signature];
        NSString *replaced = [coordinator inputSignatureForSnapshot:Snapshot(@"先请")];
        Assert(![signature isEqualToString:replaced]
                && [coordinator consumeInsertionForSignature:replaced] == nil,
            @"同长度替换必须拒绝旧候选");
        Assert([signature rangeOfString:snapshot.inputText].location == NSNotFound,
            @"签名不得包含正文");
        NSString *suggestion = [coordinator prepareAutomaticSuggestionForSnapshot:snapshot
            signature:signature];
        Assert([lookedUpText isEqualToString:@"请先"]
                && [suggestion isEqualToString:@"把方案梳理清楚。"],
            @"自动提示应用短暂正文查询本地后缀");
        Assert([[coordinator consumeInsertionForSignature:signature]
                    isEqualToString:@"把方案梳理清楚。"]
                && [coordinator consumeInsertionForSignature:signature] == nil,
            @"Tab 接受必须只能取出当前后缀一次");

        suggestion = [coordinator prepareAutomaticSuggestionForSnapshot:Snapshot(@"无匹配")
            signature:@"3:3:0"];
        Assert(suggestion == nil
                && [coordinator consumeInsertionForSignature:@"3:3:0"] == nil,
            @"无本地匹配时不得保留或显示固定兜底提示");

        [coordinator prepareManualInsertion:@"，这是手动测试"
            signature:@"3:3:0"];
        [coordinator clear];
        Assert([coordinator consumeInsertionForSignature:@"3:3:0"] == nil,
            @"输入签名变化或 Esc 取消时必须清除待插入后缀");
        [coordinator prepareManualInsertion:@"，这是手动测试"
            signature:@"3:3:0"];
        Assert([[coordinator consumeInsertionForSignature:@"3:3:0"]
                    isEqualToString:@"，这是手动测试"],
            @"手动诊断夹具仍可明确显示和接受");

        [coordinator prepareRemoteInsertion:@" remote suffix"
            signature:@"6:6:0"];
        Assert([[coordinator consumeInsertionForSignature:@"6:6:0"]
                    isEqualToString:@" remote suffix"],
            @"远程结果必须绑定请求时的输入签名");

        CPAInputElementIdentity *identity = [CPAInputElementIdentity new];
        NSObject *fieldA = [NSObject new], *fieldB = [NSObject new];
        NSObject *windowA = [NSObject new], *windowB = [NSObject new];
        NSString *ownerA = [identity tokenForElement:fieldA window:windowA rendererIdentifier:@"shared-id"];
        Assert([ownerA isEqualToString:[identity tokenForElement:fieldA window:windowA rendererIdentifier:@"shared-id"]],
            @"同一控件和窗口必须保持身份稳定");
        NSString *ownerB = [identity tokenForElement:fieldA window:windowB rendererIdentifier:@"shared-id"];
        Assert(![ownerA isEqualToString:ownerB], @"重复 AX 标识不能跨窗口复用身份");
        NSString *returned = [identity tokenForElement:fieldA window:windowA rendererIdentifier:@"shared-id"];
        Assert(![ownerA isEqualToString:returned], @"离开后返回不能复活旧身份");
        Assert(![returned isEqualToString:[identity tokenForElement:fieldB window:windowA rendererIdentifier:@"shared-id"]],
            @"同窗口内重复标识的不同控件也必须隔离");
        snapshot.targetFieldIdentity = ownerA;
        signature = [coordinator inputSignatureForSnapshot:snapshot];
        [coordinator prepareRemoteInsertion:@"旧窗口候选" signature:signature];
        snapshot.targetFieldIdentity = ownerB;
        Assert([coordinator consumeInsertionForSignature:[coordinator inputSignatureForSnapshot:snapshot]] == nil,
            @"相同文本也不能跨窗口接受候选");
        snapshot.inputText = nil;
        Assert([coordinator inputSignatureForSnapshot:snapshot].length == 0,
            @"未知正文不得生成可接受的长度签名");
        [coordinator prepareManualInsertion:@"无主候选" signature:@""];
        Assert([coordinator consumeInsertionForSignature:@""] == nil, @"空签名不得接受候选");
        NSLog(@"PASS: LocalSuggestionCoordinatorTests");
    }
    return 0;
}
