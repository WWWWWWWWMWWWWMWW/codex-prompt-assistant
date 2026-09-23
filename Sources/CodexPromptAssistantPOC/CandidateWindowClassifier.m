#import "CandidateWindowClassifier.h"

BOOL CPAWindowLooksLikeInputMethodCandidate(
    NSString *owner,
    CGRect bounds,
    CGFloat alpha,
    NSInteger layer
) {
    if (owner.length == 0 || alpha <= 0.0 || bounds.size.width < 80.0
        || bounds.size.height < 20.0 || bounds.size.height > 420.0) {
        return NO;
    }
    BOOL isMenuBarStatusWindow = layer >= 20
        && bounds.origin.y <= 1.0
        && bounds.size.height <= 40.0;
    if (isMenuBarStatusWindow) {
        return NO;
    }

    NSArray<NSString *> *ownerHints = @[
        @"Sogou", @"Pinyin", @"InputMethod", @"Input Method", @"IMK",
        @"TextInput", @"WeType", @"Baidu", @"QQInput", @"搜狗", @"输入法",
    ];
    for (NSUInteger i = 0, len = ownerHints.count; i < len; i++) {
        if ([owner localizedCaseInsensitiveContainsString:ownerHints[i]]) {
            return YES;
        }
    }
    return NO;
}
