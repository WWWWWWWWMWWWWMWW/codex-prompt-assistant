#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/CandidateWindowClassifier.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        CGRect statusItem = CGRectMake(516.0, 0.0, 158.0, 24.0);
        Assert(!CPAWindowLooksLikeInputMethodCandidate(
                @"搜狗输入法", statusItem, 1.0, 25),
            @"菜单栏中的搜狗状态项不能被当成候选框");

        CGRect candidatePanel = CGRectMake(180.0, 330.0, 600.0, 170.0);
        Assert(CPAWindowLooksLikeInputMethodCandidate(
                @"搜狗输入法", candidatePanel, 1.0, 3),
            @"输入区域附近的搜狗候选面板应被识别");

        Assert(!CPAWindowLooksLikeInputMethodCandidate(
                @"Codex", candidatePanel, 1.0, 3),
            @"普通应用窗口不能被当成输入法候选框");

        NSLog(@"PASS: CandidateWindowClassifierTests");
    }
    return 0;
}
