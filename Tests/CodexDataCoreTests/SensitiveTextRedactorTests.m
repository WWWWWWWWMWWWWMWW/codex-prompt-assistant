#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/SensitiveTextRedactor.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void AssertDoesNotContain(NSString *text, NSString *secret) {
    Assert([text rangeOfString:secret].location == NSNotFound,
        [NSString stringWithFormat:@"脱敏结果仍包含合成秘密：%@", secret]);
}

int main(void) {
    @autoreleasepool {
        NSString *apiKey = [@"sk" stringByAppendingString:
            @"-demo_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"];
        NSString *bearer = @"Bearer opaqueBearerToken_1234567890";
        NSString *jwt = @"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZW1vVXNlciJ9.signaturePart12345";
        NSString *privateKeyBody = @"-----BEGIN PRIVATE KEY-----\nFAKE_PRIVATE_MATERIAL\n-----END PRIVATE KEY-----";
        NSString *password = @"correct-horse-demo";
        NSString *email = @"person@example.com";
        NSString *phone = @"13800138000";
        NSString *urlToken = @"https://example.test/path?token=urlSecret123456&mode=safe";
        NSString *input = [@[apiKey, bearer, jwt, privateKeyBody,
            [@"password=" stringByAppendingString:password], email, phone, urlToken]
            componentsJoinedByString:@"\n"];

        CPASensitiveTextRedactor *redactor = [[CPASensitiveTextRedactor alloc] init];
        CPARedactionResult *result = [redactor redactText:input];
        AssertDoesNotContain(result.redactedText, apiKey);
        AssertDoesNotContain(result.redactedText, bearer);
        AssertDoesNotContain(result.redactedText, jwt);
        AssertDoesNotContain(result.redactedText, @"FAKE_PRIVATE_MATERIAL");
        AssertDoesNotContain(result.redactedText, password);
        AssertDoesNotContain(result.redactedText, email);
        AssertDoesNotContain(result.redactedText, phone);
        AssertDoesNotContain(result.redactedText, @"urlSecret123456");

        NSArray<NSString *> *placeholders = @[
            @"{API_KEY}", @"{BEARER_TOKEN}", @"{JWT}", @"{PRIVATE_KEY}",
            @"{PASSWORD}", @"{EMAIL}", @"{PHONE}", @"{URL_TOKEN}",
        ];
        for (NSUInteger i = 0, len = placeholders.count; i < len; i++) {
            NSString *placeholder = placeholders[i];
            Assert([result.redactedText containsString:placeholder],
                [NSString stringWithFormat:@"应包含占位符 %@", placeholder]);
            Assert([result.typeCounts[placeholder] unsignedIntegerValue] == 1,
                [NSString stringWithFormat:@"占位符 %@ 计数应为 1", placeholder]);
        }
        Assert(result.totalReplacementCount == placeholders.count, @"替换总数应准确");

        NSString *benign = @"sketch token_budget api_key_name 版本 138，联系 example dot com";
        CPARedactionResult *benignResult = [redactor redactText:benign];
        Assert([benignResult.redactedText isEqualToString:benign], @"普通文本不应被误伤");
        Assert(benignResult.totalReplacementCount == 0, @"普通文本替换数应为 0");

        NSLog(@"PASS: SensitiveTextRedactorTests");
    }
    return 0;
}
