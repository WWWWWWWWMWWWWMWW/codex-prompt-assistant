#import "ApplicationInputAdapter.h"

static BOOL CPAStringContainsAnyToken(
    NSString *value,
    NSArray<NSString *> *tokens
) {
    for (NSString *token in tokens) {
        if ([value containsString:token]) {
            return YES;
        }
    }
    return NO;
}

@implementation CPAApplicationInputAdapter

- (BOOL)isBrowserBundleIdentifier:(NSString *)bundleIdentifier {
    static NSSet<NSString *> *browserIdentifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        browserIdentifiers = [NSSet setWithArray:@[
            @"com.apple.Safari",
            @"com.google.Chrome",
            @"org.mozilla.firefox",
        ]];
    });
    return [browserIdentifiers containsObject:bundleIdentifier];
}

- (NSString *)normalizedMetadata:(NSArray<NSString *> *)semanticMetadata {
    NSMutableArray<NSString *> *normalized = [[NSMutableArray alloc] init];
    for (id value in semanticMetadata) {
        if (![value isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *text = [(NSString *)value lowercaseString];
        if (text.length > 0) {
            [normalized addObject:text];
        }
    }
    return [normalized componentsJoinedByString:@" "];
}

- (CPAInputSceneClassification *)classificationForBundleIdentifier:
    (NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata {
    return [self classificationForBundleIdentifier:bundleIdentifier
        role:role
        subrole:subrole
        semanticMetadata:semanticMetadata
        allowOrdinaryTextInference:NO];
}

- (CPAInputSceneClassification *)classificationForBundleIdentifier:
    (NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    allowOrdinaryTextInference:(BOOL)allowOrdinaryTextInference {
    NSString *metadata = [self normalizedMetadata:semanticMetadata];
    CPAInputSceneEvidence *evidence = [[CPAInputSceneEvidence alloc]
        initWithRole:role subrole:subrole];
    evidence.secureTextEntry = [subrole isEqualToString:@"AXSecureTextField"]
        || CPAStringContainsAnyToken(metadata, @[
            @"password", @"passcode", @"密码",
        ]);
    evidence.oneTimeCodeHint = CPAStringContainsAnyToken(metadata, @[
        @"one time code", @"one-time code", @"verification code",
        @"验证码", @"动态码",
    ]);
    evidence.paymentHint = CPAStringContainsAnyToken(metadata, @[
        @"card number", @"credit card", @"payment", @"cvv", @"cvc",
        @"信用卡", @"银行卡", @"卡号", @"支付",
    ]);
    evidence.loginHint = CPAStringContainsAnyToken(metadata, @[
        @"log in", @"login", @"sign in", @"username", @"user name",
        @"登录", @"登陆",
    ]);
    evidence.searchHint = CPAStringContainsAnyToken(metadata, @[
        @"search", @"search query", @"搜索", @"查询",
    ]);

    BOOL textArea = [role isEqualToString:@"AXTextArea"]
        || [role isEqualToString:@"AXTextView"];
    BOOL textField = [role isEqualToString:@"AXTextField"];
    if ([bundleIdentifier isEqualToString:@"com.openai.codex"] && textArea) {
        evidence.longFormEditorHint = YES;
    } else if (CPASuggestionPolicyApplicationIsWorkBuddy(bundleIdentifier)) {
        evidence.longFormEditorHint = textArea;
        evidence.ordinaryTextHint = textField;
    } else if ([bundleIdentifier isEqualToString:@"com.electron.lark"]) {
        evidence.chatComposerHint = textArea
            && CPAStringContainsAnyToken(metadata, @[
                @"message composer", @"chat composer", @"message input",
                @"消息", @"聊天",
            ]);
        evidence.longFormEditorHint = textArea
            && CPAStringContainsAnyToken(metadata, @[
                @"document editor", @"doc editor", @"long form",
                @"文档", @"正文",
            ]);
    } else if ([bundleIdentifier isEqualToString:@"com.tencent.xinWeChat"]
        && textArea) {
        evidence.chatComposerHint = YES;
    } else if ([self isBrowserBundleIdentifier:bundleIdentifier] && textArea) {
        // A browser scene still needs an exact host rule in the policy layer.
        evidence.longFormEditorHint = YES;
    }
    if (allowOrdinaryTextInference
        && !evidence.chatComposerHint && !evidence.longFormEditorHint) {
        evidence.longFormEditorHint = textArea;
        evidence.ordinaryTextHint = textField;
    }

    CPAInputSceneClassifier *classifier = [[CPAInputSceneClassifier alloc] init];
    return [classifier classifyEvidence:evidence];
}

@end
