#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/InputMethodState.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        CPAInputMethodState *state = [[CPAInputMethodState alloc] init];

        [state noteKeyCode:kVK_ANSI_C commandModified:NO usesChineseInput:YES];
        Assert(state.potentialComposition,
            @"中文输入源输入拼音字母后应进入潜在组词状态");
        Assert([state shouldPassThroughSuggestionKeyCode:kVK_Tab],
            @"组词状态的 Tab 必须交给输入法");
        Assert([state suggestionDelayRemainingForElapsedSinceLastTextKey:0.30]
                > 0.20,
            @"未明确提交的拼音组词必须保留原有候选保护时间");

        [state noteKeyCode:kVK_Space commandModified:NO usesChineseInput:YES];
        Assert(!state.potentialComposition,
            @"空格选词后应退出潜在组词状态");
        Assert([state suggestionDelayRemainingForElapsedSinceLastTextKey:0.12]
                == 0,
            @"明确选词后不应再被旧的 550ms 输入法保护阻塞");
        Assert([state suggestionDelayRemainingForElapsedSinceLastTextKey:0.05]
                > 0,
            @"明确选词后仍应保留极短的提交稳定时间");

        [state noteKeyCode:kVK_ANSI_S commandModified:NO usesChineseInput:NO];
        Assert(!state.potentialComposition,
            @"英文输入源不能误判为中文组词");

        [state noteKeyCode:kVK_ANSI_A commandModified:NO usesChineseInput:YES];
        [state noteMouseDown];
        Assert(!state.potentialComposition,
            @"鼠标提交或切换焦点后应退出潜在组词状态");

        NSLog(@"PASS: InputMethodStateTests");
    }
    return 0;
}
