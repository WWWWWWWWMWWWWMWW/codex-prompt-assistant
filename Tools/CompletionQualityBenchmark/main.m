#import <Foundation/Foundation.h>
#import "BenchmarkSupport.h"
#import "AuditSupport.h"
#import "../../Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.h"
#import "../../Sources/CodexDataCore/RemoteAPIKeyFileStore.h"
static NSString *const LocalModelName = @"mlx-community/Qwen3-4B-Instruct-2507-4bit";
int main(void) {
    @autoreleasepool {
        // This branch intentionally precedes settings and credential access.
        const char *replayPath = getenv("CPA_BENCHMARK_REPLAY");
        if (replayPath) {
            NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:replayPath]];
            id cases = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![cases isKindOfClass:NSArray.class] || ![cases count]) return 2;
            for (id fixture in cases) {
                if (![fixture isKindOfClass:NSDictionary.class]
                    || ![fixture[@"id"] isKindOfClass:NSString.class]
                    || ![fixture[@"before_cursor"] isKindOfClass:NSString.class]) return 2;
                NSDictionary *row = CPABenchmarkReplay(fixture);
                NSData *json = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
                if (!json) return 2;
                puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            }
            return 0;
        }
        NSURL *baseURL = [NSURL URLWithString:@"http://127.0.0.1:18921/v1"];
        BOOL remote = getenv("CPA_BENCHMARK_REMOTE") != NULL;
        NSString *apiKey = @"local-loopback";
        NSString *model = LocalModelName;
        if (remote) {
            NSURL *directory = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/Application Support/CodexPromptAssistant"]];
            // Opt-in only. Never initialize a missing credential store or print credentials.
            for (NSString *name in @[@"remote-api-key-v1.bin", @"remote-master-key-v1.bin"]) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:[directory URLByAppendingPathComponent:name].path]) return 2;
            }
            CPARemoteCompletionSettings *settings = [[CPARemoteCompletionSettings alloc]
                initWithAPIKeyFileStore:[[CPARemoteAPIKeyFileStore alloc] initWithDirectoryURL:directory]
                userDefaults:[[NSUserDefaults alloc] initWithSuiteName:@"local.codex.prompt-assistant-poc"]];
            apiKey = [settings apiKey:nil]; model = settings.preferredModel; baseURL = settings.baseURL;
            if (apiKey.length == 0) return 2;
        }

        NSDictionary *env = NSProcessInfo.processInfo.environment;
        if (remote && getenv("CPA_BENCHMARK_LIST_MODELS")) {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[baseURL URLByAppendingPathComponent:@"models"]];
            [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
            NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block NSArray *ids = nil;
            NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (!error && [(NSHTTPURLResponse *)response statusCode] == 200) {
                    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                    NSMutableArray *names = [NSMutableArray array];
                    for (id item in ([value isKindOfClass:NSDictionary.class] && [value[@"data"] isKindOfClass:NSArray.class] ? value[@"data"] : @[]))
                        if ([item isKindOfClass:NSDictionary.class] && [item[@"id"] isKindOfClass:NSString.class]) [names addObject:item[@"id"]];
                    ids = names;
                }
                dispatch_semaphore_signal(done);
            }];
            [task resume];
            BOOL timedOut = dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC)) != 0;
            [session invalidateAndCancel];
            if (timedOut || !ids) return 3;
            puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:ids options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        if (remote && [env[@"CPA_BENCHMARK_MODEL"] length]) model = env[@"CPA_BENCHMARK_MODEL"];

        NSString *fixturePath = env[@"CPA_BENCHMARK_FIXTURES"] ?: @"Tools/CompletionQualityBenchmark/fixtures/legacy24.json";
        NSData *fixtureData = [NSData dataWithContentsOfFile:fixturePath];
        if (!fixtureData) return 2;
        NSArray *fixtures = [NSJSONSerialization JSONObjectWithData:fixtureData options:0 error:nil];
        if (![fixtures isKindOfClass:NSArray.class] || !fixtures.count) return 2;
        NSString *variant = env[@"CPA_BENCHMARK_VARIANT"] ?: @"baseline";
        if (![@[@"baseline", @"g1", @"context-v1"] containsObject:variant]) return 2;
        NSString *system = [variant isEqual:@"g1"] ? [NSString stringWithContentsOfFile:@"Tools/CompletionQualityBenchmark/g1.txt" encoding:NSUTF8StringEncoding error:nil] : nil;
        if ([variant isEqual:@"g1"] && !system.length) return 2;
        for (NSDictionary *fixture in fixtures) {
            NSDictionary *state = [variant isEqual:@"context-v1"] ? @{
                @"availability":fixture[@"context"][@"availability"],
                @"truncated":fixture[@"context"][@"truncated"],
                @"window_limited":@YES} : nil;
            NSMutableDictionary *row = getenv("CPA_BENCHMARK_AUDIT") ? [CPABenchmarkAuditAttempt(fixture,baseURL,apiKey,model,
                NSURLSessionConfiguration.ephemeralSessionConfiguration,
                MIN(13.0,MAX(0,13.0-[fixture[@"generation_ms"] doubleValue]/1000)),
                env[@"CPA_BENCHMARK_AUDIT_VERSION"] ?: @"audit-v1") mutableCopy] : [CPABenchmarkAttempt(fixture,baseURL,apiKey,model,
                !remote && getenv("CPA_BENCHMARK_CHAT") == NULL, system, state,
                NSURLSessionConfiguration.ephemeralSessionConfiguration, 13.0) mutableCopy];
            row[@"provider"] = remote ? @"remote" : @"local";
            row[@"variant"] = variant;
            NSData *json = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
            if (!json) return 2;
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            fflush(stdout); // Every attempt persists even if a later request fails.
        }
    }
    return 0; // Per-attempt failures are data, not a reason to drop the remaining group.
}
