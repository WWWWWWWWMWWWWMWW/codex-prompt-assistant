#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/KeyboardShadowBuffer.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        CPAKeyboardShadowBuffer *buffer = [[CPAKeyboardShadowBuffer alloc] init];
        [buffer applyCommittedText:@"你好 world"];
        Assert([buffer.text isEqualToString:@"你好 world"] && buffer.cursorLocation == 8,
            @"文本应追加到光标位置");
        [buffer applyBackspace];
        Assert([buffer.text isEqualToString:@"你好 worl"], @"退格应按组合字符删除");
        [buffer moveCursorToStartSelecting:NO];
        [buffer applyCommittedText:@"X"];
        Assert([buffer.text isEqualToString:@"X你好 worl"], @"开头插入应保持后缀");
        [buffer moveCursorRightSelecting:YES];
        Assert(buffer.selectedLength == 1, @"Shift 右移应建立一个字符选区");
        [buffer applyCommittedText:@"Y"];
        Assert([buffer.text isEqualToString:@"XY好 worl"], @"插入应替换选区");
        [buffer selectAll];
        [buffer applyCommittedText:@"重写"];
        Assert([buffer.text isEqualToString:@"重写"] && buffer.cursorLocation == 2,
            @"全选后插入应替换全文");

        [buffer replaceWithAuthoritativeText:@"abcdef"
            cursorLocation:3 selectedLength:0];
        [buffer moveCursorLeftSelecting:YES];
        Assert(buffer.cursorLocation == 2 && buffer.selectedLength == 1,
            @"从中间向左 Shift 选择应建立反向选区");
        [buffer moveCursorRightSelecting:YES];
        Assert(buffer.cursorLocation == 3 && buffer.selectedLength == 0,
            @"反向选区 Shift 右移应收缩到锚点");
        [buffer moveCursorRightSelecting:YES];
        [buffer moveCursorRightSelecting:YES];
        Assert(buffer.cursorLocation == 3 && buffer.selectedLength == 2,
            @"Shift 右移应从活动端继续扩展");
        [buffer moveCursorLeftSelecting:YES];
        Assert(buffer.cursorLocation == 3 && buffer.selectedLength == 1,
            @"Shift 左移应收缩活动端而非跳到另一端");
        [buffer applyBackspace];
        Assert([buffer.text isEqualToString:@"abcef"] && buffer.cursorLocation == 3
                && buffer.selectedLength == 0,
            @"反向/正向选区退格应删除整个选区");

        [buffer replaceWithAuthoritativeText:@"clipboard"
            cursorLocation:9 selectedLength:0];
        [buffer markUnknown];
        Assert(!buffer.valid, @"剪贴板/撤销等不可观测快捷键后应等待 AX 校准");
        [buffer applyCommittedText:@"X"];
        Assert([buffer.text isEqualToString:@"clipboardX"] && !buffer.valid,
            @"未知状态下仍可保守跟随提交文本但不能恢复有效");
        [buffer replaceWithAuthoritativeText:@"校准"
            cursorLocation:2 selectedLength:0];
        Assert(buffer.valid && [buffer.text isEqualToString:@"校准"],
            @"AX 权威同步应恢复影子缓冲有效状态");
        [buffer clearAfterSubmit];
        Assert(buffer.text.length == 0 && buffer.valid, @"提交后应清空影子文本");

        [buffer handleMouseDownInsideFallbackInput:YES];
        Assert(buffer.valid && buffer.text.length == 0,
            @"空草稿点击保守输入区应允许冷启动记录");
        [buffer applyCommittedText:@"draft"];
        [buffer handleMouseDownInsideFallbackInput:YES];
        Assert(!buffer.valid,
            @"非空草稿内点击可能移动光标，必须等待 AX 校准");
        [buffer reset];
        [buffer handleMouseDownInsideFallbackInput:NO];
        Assert(!buffer.valid,
            @"点击保守输入区外不能猜测用户正在编辑 composer");
        NSLog(@"PASS: KeyboardShadowBufferTests");
    }
    return 0;
}
