#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/InputSceneClassifier.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPAInputSceneEvidence *Evidence(NSString *role, NSString *subrole) {
    return [[CPAInputSceneEvidence alloc] initWithRole:role subrole:subrole];
}

int main(void) {
    @autoreleasepool {
        CPAInputSceneClassifier *classifier = [[CPAInputSceneClassifier alloc] init];
        CPAInputSceneEvidence *evidence = Evidence(@"AXTextField", @"AXSecureTextField");
        CPAInputSceneClassification *result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputScenePassword && result.confidenceHigh,
            @"a secure AX subrole must be a high-confidence password scene");

        evidence = Evidence(@"AXTextArea", @"");
        evidence.secureTextEntry = YES;
        evidence.searchHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputScenePassword,
            @"secure evidence must outrank all soft scene hints");

        evidence = Evidence(@"AXTextField", @"");
        evidence.oneTimeCodeHint = YES;
        evidence.searchHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputSceneOneTimeCode && result.confidenceHigh,
            @"OTP evidence must outrank search evidence");

        evidence = Evidence(@"AXTextField", @"");
        evidence.paymentHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputScenePayment,
            @"payment evidence should be classified before ordinary text");

        evidence = Evidence(@"AXTextField", @"");
        evidence.loginHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputSceneLogin,
            @"login evidence should be hard-protected");

        result = [classifier classifyEvidence:Evidence(@"AXTextField", @"AXSearchField")];
        Assert(result.scene == CPAInputSceneSearch && result.confidenceHigh,
            @"AXSearchField must be classified without reading its value");

        evidence = Evidence(@"AXTextArea", @"");
        evidence.chatComposerHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputSceneChatComposer && result.confidenceHigh,
            @"an adapter-confirmed chat composer should be usable policy metadata");

        evidence = Evidence(@"AXTextArea", @"");
        evidence.longFormEditorHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputSceneLongFormEditor && result.confidenceHigh,
            @"an adapter-confirmed long-form editor should be high confidence");

        evidence = Evidence(@"AXTextArea", @"");
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputSceneUnknown && !result.confidenceHigh,
            @"a generic text role without adapter evidence must fail closed");

        evidence = Evidence(@"AXButton", @"");
        evidence.longFormEditorHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputSceneUnknown,
            @"non-text roles must never become editors from a soft hint alone");

        evidence = Evidence(@"AXTextField", @"");
        evidence.ordinaryTextHint = YES;
        result = [classifier classifyEvidence:evidence];
        Assert(result.scene == CPAInputSceneGeneralText && result.confidenceHigh,
            @"an adapter-confirmed ordinary field should become general text");

        NSLog(@"PASS: InputSceneClassifierTests");
    }
    return 0;
}
