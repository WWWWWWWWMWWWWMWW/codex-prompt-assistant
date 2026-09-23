#import <Foundation/Foundation.h>

#import "../../Sources/RemoteCompletionCore/RemoteCompletionClient.h"

static NSString *const LocalModelName = @"mlx-community/Qwen3-4B-Instruct-2507-4bit";

int main(void) {
    @autoreleasepool {
        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        dispatch_queue_t callbackQueue = dispatch_queue_create(
            "local.codex.prompt-assistant.local-model-benchmark",
            DISPATCH_QUEUE_SERIAL);
        NSString *configuredBaseURL = NSProcessInfo.processInfo.environment[
            @"CPA_LOCAL_MODEL_BASE_URL"];
        NSURL *baseURL = [NSURL URLWithString:
            configuredBaseURL.length > 0
                ? configuredBaseURL : @"http://127.0.0.1:18921/v1"];
        CPARemoteCompletionClient *client = [[CPARemoteCompletionClient alloc]
            initWithBaseURL:baseURL
            sessionConfiguration:configuration
            callbackQueue:callbackQueue];
        client.progressMinimumCharacterCount = 8;
        client.progressMinimumCharacterDelta = 4;
        NSArray<NSString *> *samples = @[
            @"测试",
            @"怎么还是这句话，这句话应该",
            @"现在出现的速度还是太慢了，能做到1秒以内吗",
            @"检查下提示词是否存在歧义、冲突或可优化之处",
            @"这个工具现在还有什么可以优化的地方吗",
        ];
        NSArray<NSDictionary<NSString *, NSString *> *> *context = @[
            @{ @"role": @"user", @"content": @"我们正在优化一个实时灰字续写工具。" },
            @{ @"role": @"assistant", @"content": @"目标是续写用户正在编写的 AI 提示词，而不是回答问题。" },
        ];
        for (NSUInteger index = 0; index < samples.count; index++) {
            NSString *sample = samples[index];
            NSDate *startedAt = [NSDate date];
            __block NSUInteger firstProgressMilliseconds = 0;
            __block CPARemoteCompletionResult *finalResult = nil;
            dispatch_semaphore_t finished = dispatch_semaphore_create(0);
            [client requestCompletionForInput:sample
                contextMessages:context
                apiKey:@"local-loopback"
                preferredModel:LocalModelName
                progress:^(NSString *partialInsertion) {
                    if (firstProgressMilliseconds == 0 && partialInsertion.length > 0) {
                        firstProgressMilliseconds = (NSUInteger)llround(
                            -[startedAt timeIntervalSinceNow] * 1000.0);
                    }
                }
                completion:^(CPARemoteCompletionResult *result) {
                    finalResult = result;
                    dispatch_semaphore_signal(finished);
                }];
            long waitResult = dispatch_semaphore_wait(finished,
                dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));
            if (waitResult != 0 || finalResult == nil) {
                NSLog(@"SAMPLE %lu timeout", (unsigned long)(index + 1));
                return 1;
            }
            NSUInteger totalMilliseconds = (NSUInteger)llround(
                -[startedAt timeIntervalSinceNow] * 1000.0);
            NSUInteger firstMilliseconds = firstProgressMilliseconds > 0
                ? firstProgressMilliseconds : totalMilliseconds;
            // Keep benchmark output metadata-only. Never write model output
            // text to the terminal or a diagnostic log.
            NSLog(@"SAMPLE %lu firstMs=%lu totalMs=%lu outcome=%ld phase=%@ outputLength=%lu",
                (unsigned long)(index + 1),
                (unsigned long)firstMilliseconds,
                (unsigned long)totalMilliseconds,
                (long)finalResult.outcome,
                finalResult.phase,
                (unsigned long)finalResult.outputCharacterCount);
        }
        [client cancelActiveRequest];
    }
    return 0;
}
