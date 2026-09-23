#import "InputMethodState.h"

static const NSTimeInterval CPAUncommittedCompositionGuardInterval = 0.55;
static const NSTimeInterval CPACommittedCompositionSettleInterval = 0.10;

@interface CPAInputMethodState ()
@property(nonatomic, readwrite) BOOL potentialComposition;
@end

@implementation CPAInputMethodState

- (void)noteKeyCode:(CGKeyCode)keyCode
    commandModified:(BOOL)commandModified
    usesChineseInput:(BOOL)usesChineseInput {
    if (!usesChineseInput) {
        self.potentialComposition = NO;
        return;
    }
    if (commandModified) {
        return;
    }
    if ([self isPinyinCompositionKeyCode:keyCode]) {
        self.potentialComposition = YES;
        return;
    }
    if ([self isCandidateCommitKeyCode:keyCode]) {
        self.potentialComposition = NO;
    }
}

- (void)noteMouseDown {
    self.potentialComposition = NO;
}

- (BOOL)shouldPassThroughSuggestionKeyCode:(CGKeyCode)keyCode {
    return self.potentialComposition
        && (keyCode == (CGKeyCode)kVK_Tab || keyCode == (CGKeyCode)kVK_Escape);
}

- (NSTimeInterval)suggestionDelayRemainingForElapsedSinceLastTextKey:
    (NSTimeInterval)elapsed {
    if (elapsed < 0) {
        return 0;
    }
    NSTimeInterval guardInterval = self.potentialComposition
        ? CPAUncommittedCompositionGuardInterval
        : CPACommittedCompositionSettleInterval;
    return MAX((NSTimeInterval)0, guardInterval - elapsed);
}

- (BOOL)isPinyinCompositionKeyCode:(CGKeyCode)keyCode {
    switch (keyCode) {
        case kVK_ANSI_A:
        case kVK_ANSI_B:
        case kVK_ANSI_C:
        case kVK_ANSI_D:
        case kVK_ANSI_E:
        case kVK_ANSI_F:
        case kVK_ANSI_G:
        case kVK_ANSI_H:
        case kVK_ANSI_I:
        case kVK_ANSI_J:
        case kVK_ANSI_K:
        case kVK_ANSI_L:
        case kVK_ANSI_M:
        case kVK_ANSI_N:
        case kVK_ANSI_O:
        case kVK_ANSI_P:
        case kVK_ANSI_Q:
        case kVK_ANSI_R:
        case kVK_ANSI_S:
        case kVK_ANSI_T:
        case kVK_ANSI_U:
        case kVK_ANSI_V:
        case kVK_ANSI_W:
        case kVK_ANSI_X:
        case kVK_ANSI_Y:
        case kVK_ANSI_Z:
        case kVK_ANSI_Quote:
            return YES;
        default:
            return NO;
    }
}

- (BOOL)isCandidateCommitKeyCode:(CGKeyCode)keyCode {
    switch (keyCode) {
        case kVK_Space:
        case kVK_Return:
        case kVK_ANSI_KeypadEnter:
        case kVK_ANSI_0:
        case kVK_ANSI_1:
        case kVK_ANSI_2:
        case kVK_ANSI_3:
        case kVK_ANSI_4:
        case kVK_ANSI_5:
        case kVK_ANSI_6:
        case kVK_ANSI_7:
        case kVK_ANSI_8:
        case kVK_ANSI_9:
            return YES;
        default:
            return NO;
    }
}

@end
