#import "InputSceneClassifier.h"

@interface CPAInputSceneEvidence ()
@property(nonatomic, copy, readwrite) NSString *role;
@property(nonatomic, copy, readwrite) NSString *subrole;
@end

@implementation CPAInputSceneEvidence

- (instancetype)initWithRole:(NSString *)role subrole:(NSString *)subrole {
    self = [super init];
    if (self != nil) {
        _role = [role copy];
        _subrole = [subrole copy];
    }
    return self;
}

@end

@interface CPAInputSceneClassification ()
@property(nonatomic, readwrite) CPAInputScene scene;
@property(nonatomic, readwrite) BOOL confidenceHigh;

- (instancetype)initWithScene:(CPAInputScene)scene
    confidenceHigh:(BOOL)confidenceHigh;
@end

@implementation CPAInputSceneClassification

- (instancetype)initWithScene:(CPAInputScene)scene
    confidenceHigh:(BOOL)confidenceHigh {
    self = [super init];
    if (self != nil) {
        _scene = scene;
        _confidenceHigh = confidenceHigh;
    }
    return self;
}

@end

@implementation CPAInputSceneClassifier

- (CPAInputSceneClassification *)classificationWithScene:
    (CPAInputScene)scene confidenceHigh:(BOOL)confidenceHigh {
    return [[CPAInputSceneClassification alloc] initWithScene:scene
        confidenceHigh:confidenceHigh];
}

- (BOOL)isTextRole:(NSString *)role {
    static NSSet<NSString *> *textRoles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textRoles = [NSSet setWithArray:@[
            @"AXTextArea",
            @"AXTextField",
            @"AXTextView",
        ]];
    });
    return [textRoles containsObject:role];
}

- (CPAInputSceneClassification *)classifyEvidence:
    (CPAInputSceneEvidence *)evidence {
    if (evidence.secureTextEntry
        || [evidence.subrole isEqualToString:@"AXSecureTextField"]) {
        return [self classificationWithScene:CPAInputScenePassword
            confidenceHigh:YES];
    }
    if (evidence.oneTimeCodeHint) {
        return [self classificationWithScene:CPAInputSceneOneTimeCode
            confidenceHigh:YES];
    }
    if (evidence.paymentHint) {
        return [self classificationWithScene:CPAInputScenePayment
            confidenceHigh:YES];
    }
    if (evidence.loginHint) {
        return [self classificationWithScene:CPAInputSceneLogin
            confidenceHigh:YES];
    }
    if (evidence.searchHint
        || [evidence.subrole isEqualToString:@"AXSearchField"]) {
        return [self classificationWithScene:CPAInputSceneSearch
            confidenceHigh:YES];
    }
    if (![self isTextRole:evidence.role]) {
        return [self classificationWithScene:CPAInputSceneUnknown
            confidenceHigh:NO];
    }
    if (evidence.chatComposerHint) {
        return [self classificationWithScene:CPAInputSceneChatComposer
            confidenceHigh:YES];
    }
    if (evidence.longFormEditorHint) {
        return [self classificationWithScene:CPAInputSceneLongFormEditor
            confidenceHigh:YES];
    }
    if (evidence.ordinaryTextHint) {
        return [self classificationWithScene:CPAInputSceneGeneralText
            confidenceHigh:YES];
    }
    return [self classificationWithScene:CPAInputSceneUnknown
        confidenceHigh:NO];
}

@end
