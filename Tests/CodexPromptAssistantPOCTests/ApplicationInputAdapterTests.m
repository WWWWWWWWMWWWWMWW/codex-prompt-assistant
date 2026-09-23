#import <Foundation/Foundation.h>

#import "../../Sources/CodexPromptAssistantPOC/ApplicationInputAdapter.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static CPAInputSceneClassification *Classify(
    CPAApplicationInputAdapter *adapter,
    NSString *bundleIdentifier,
    NSString *role,
    NSString *subrole,
    NSArray<NSString *> *metadata
) {
    return [adapter classificationForBundleIdentifier:bundleIdentifier
        role:role
        subrole:subrole
        semanticMetadata:metadata];
}

int main(void) {
    @autoreleasepool {
        CPAApplicationInputAdapter *adapter =
            [[CPAApplicationInputAdapter alloc] init];
        CPAInputSceneClassification *result = Classify(adapter,
            @"com.openai.codex", @"AXTextArea", @"", @[]);
        Assert(result.scene == CPAInputSceneLongFormEditor
                && result.confidenceHigh,
            @"Codex composer should use its verified app preset");

        result = Classify(adapter, @"com.workbuddy.workbuddy",
            @"AXTextArea", @"", @[]);
        Assert(result.scene == CPAInputSceneLongFormEditor,
            @"WorkBuddy text areas should use the prompt-editor preset");

        result = Classify(adapter, @"com.tencent.workbuddy.mac",
            @"AXTextArea", @"", @[]);
        Assert(result.scene == CPAInputSceneLongFormEditor && result.confidenceHigh,
            @"WorkBuddy 5.5 text areas retain the prompt-editor preset");
        result = Classify(adapter, @"com.tencent.workbuddy.mac",
            @"AXTextField", @"AXSecureTextField", @[]);
        Assert(result.scene == CPAInputScenePassword,
            @"WorkBuddy 5.5 must still protect secure fields");

        result = Classify(adapter, @"com.electron.lark", @"AXTextArea", @"",
            @[@"document editor"]);
        Assert(result.scene == CPAInputSceneLongFormEditor,
            @"Lark document metadata should identify a long-form editor");

        result = Classify(adapter, @"com.electron.lark", @"AXTextArea", @"",
            @[@"message composer"]);
        Assert(result.scene == CPAInputSceneChatComposer,
            @"Lark message metadata should identify a chat composer");

        result = Classify(adapter, @"com.electron.lark", @"AXTextArea", @"",
            @[]);
        Assert(result.scene == CPAInputSceneUnknown,
            @"ambiguous Lark text areas must fail closed");

        result = Classify(adapter, @"com.tencent.xinWeChat", @"AXTextArea", @"",
            @[]);
        Assert(result.scene == CPAInputSceneChatComposer,
            @"WeChat text areas may be identified, while policy remains off");

        result = Classify(adapter, @"com.google.Chrome", @"AXTextField", @"",
            @[@"search query"]);
        Assert(result.scene == CPAInputSceneSearch,
            @"browser search metadata must be protected");

        result = Classify(adapter, @"com.google.Chrome", @"AXTextField",
            @"AXSecureTextField", @[@"search query"]);
        Assert(result.scene == CPAInputScenePassword,
            @"secure browser fields must outrank search metadata");

        result = Classify(adapter, @"com.google.Chrome", @"AXTextField", @"",
            @[@"verification code"]);
        Assert(result.scene == CPAInputSceneOneTimeCode,
            @"browser verification-code metadata must be protected");

        result = Classify(adapter, @"com.google.Chrome", @"AXTextArea", @"",
            @[]);
        Assert(result.scene == CPAInputSceneLongFormEditor,
            @"browser text areas may be classified before exact-site policy");

        result = Classify(adapter, @"com.example.unknown", @"AXTextField", @"",
            @[]);
        Assert(result.scene == CPAInputSceneUnknown,
            @"unknown applications must not infer ordinary fields from role alone");

        NSLog(@"PASS: ApplicationInputAdapterTests");
    }
    return 0;
}
