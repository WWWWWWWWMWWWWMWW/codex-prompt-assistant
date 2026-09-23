#import <Foundation/Foundation.h>

#import "../../Sources/RemoteCompletionCore/RemoteCompletionClient.h"
#import "../../Sources/RemoteCompletionCore/RemoteCompletionProtocol.h"

@interface CPAValidationCounter : CPARemoteCompletionProtocol
@property(nonatomic) NSUInteger count;
@end
@implementation CPAValidationCounter
- (NSString *)normalizedCompletion:(NSString *)text sentInput:(NSString *)input {
    if (input.length > 0) self.count++;
    return [super normalizedCompletion:text sentInput:input];
}
@end

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSData *RequestBodyData(NSURLRequest *request) {
    if (request.HTTPBody != nil) {
        return request.HTTPBody;
    }
    NSInputStream *stream = request.HTTPBodyStream;
    if (stream == nil) {
        return nil;
    }
    [stream open];
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    while (stream.hasBytesAvailable) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count <= 0) {
            break;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    [stream close];
    return data;
}

typedef void (^CPAStubHandler)(NSURLRequest *request,
    void (^respond)(NSInteger statusCode, NSDictionary *body));
typedef void (^CPAStubStreamingHandler)(NSURLRequest *request,
    void (^respond)(NSInteger statusCode, NSData *data));

@interface CPAStubURLProtocol : NSURLProtocol
@property(class, nonatomic, copy) CPAStubHandler handler;
@property(class, nonatomic, copy) CPAStubStreamingHandler streamingHandler;
@end

static CPAStubHandler CPAStoredHandler = nil;
static CPAStubStreamingHandler CPAStoredStreamingHandler = nil;

@implementation CPAStubURLProtocol
+ (CPAStubHandler)handler { return CPAStoredHandler; }
+ (void)setHandler:(CPAStubHandler)handler { CPAStoredHandler = [handler copy]; }
+ (CPAStubStreamingHandler)streamingHandler { return CPAStoredStreamingHandler; }
+ (void)setStreamingHandler:(CPAStubStreamingHandler)handler {
    CPAStoredStreamingHandler = [handler copy];
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { (void)request; return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    CPAStubHandler handler = CPAStubURLProtocol.handler;
    if (handler == nil) {
        [self.client URLProtocol:self didFailWithError:[NSError
            errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost
            userInfo:nil]];
        return;
    }
    __weak CPAStubURLProtocol *weakSelf = self;
    CPAStubStreamingHandler streamingHandler = CPAStubURLProtocol.streamingHandler;
    if (streamingHandler != nil) {
        streamingHandler(self.request, ^(NSInteger statusCode, NSData *data) {
            CPAStubURLProtocol *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                initWithURL:strongSelf.request.URL statusCode:statusCode
                HTTPVersion:@"HTTP/1.1"
                headerFields:@{@"Content-Type": @"text/event-stream"}];
            [strongSelf.client URLProtocol:strongSelf didReceiveResponse:response
                cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [strongSelf.client URLProtocol:strongSelf didLoadData:data];
            [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
        });
        return;
    }
    handler(self.request, ^(NSInteger statusCode, NSDictionary *body) {
        CPAStubURLProtocol *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
            initWithURL:strongSelf.request.URL statusCode:statusCode
            HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
        [strongSelf.client URLProtocol:strongSelf didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [strongSelf.client URLProtocol:strongSelf didLoadData:data];
        [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
    });
}
- (void)stopLoading {}
@end

static CPARemoteCompletionClient *Client(void) {
    NSURLSessionConfiguration *configuration =
        NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[CPAStubURLProtocol.class];
    return [[CPARemoteCompletionClient alloc]
        initWithBaseURL:[NSURL URLWithString:@"https://example.invalid/v1"]
        sessionConfiguration:configuration
        callbackQueue:dispatch_get_main_queue()];
}

static CPARemoteCompletionResult *WaitForResultWithContext(
    CPARemoteCompletionClient *client,
    NSString *input,
    NSString *model,
    NSArray<NSDictionary<NSString *, NSString *> *> *contextMessages,
    BOOL cancelImmediately);

static CPARemoteCompletionResult *WaitForResult(CPARemoteCompletionClient *client,
    NSString *input, NSString *model, BOOL cancelImmediately) {
    return WaitForResultWithContext(client, input, model, @[], cancelImmediately);
}

static CPARemoteCompletionResult *WaitForResultWithContext(
    CPARemoteCompletionClient *client,
    NSString *input,
    NSString *model,
    NSArray<NSDictionary<NSString *, NSString *> *> *contextMessages,
    BOOL cancelImmediately) {
    __block CPARemoteCompletionResult *captured = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    CPARemoteCompletionTask *task = [client requestCompletionForInput:input
        contextMessages:contextMessages
        apiKey:@"test-key-not-a-real-secret" preferredModel:model progress:nil
        completion:^(CPARemoteCompletionResult *result) {
            captured = result;
            dispatch_semaphore_signal(semaphore);
        }];
    if (cancelImmediately) {
        [task cancel];
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:7.0];
    while (captured == nil && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Assert(captured != nil, @"completion should arrive");
    return captured;
}

static void MiddleRequestReplay(void) {
    __block NSUInteger calls = 0;
    __block NSString *answer = @"接口超时";
    CPAStubURLProtocol.handler = ^(NSURLRequest *req, void (^respond)(NSInteger, NSDictionary *)) {
        calls++;
        NSDictionary *body = [NSJSONSerialization JSONObjectWithData:RequestBodyData(req) options:0 error:nil];
        NSDictionary *parts = [NSJSONSerialization JSONObjectWithData:[body[@"messages"][1][@"content"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        Assert([parts[@"before_cursor"] isEqual:@"请根据当前记录详细说明"] && [parts[@"after_cursor"] length] > 0, @"HTTP has both cursor sides");
        respond(200,@{@"choices":@[@{@"message":@{@"content":answer},@"finish_reason":@"stop"}]});
    };
    CPARemoteCompletionClient *client = Client();
    for (NSUInteger i=0;i<5;i++) {
        if(i==1) answer=@"当前测试接口的连接持续超时";
        __block CPARemoteCompletionResult *result=nil;
        NSString *right = i==3 ? @"的影响。" : @"的原因。";
        if(i==4) { [client invalidateCompletionCache]; answer=@"接口超时的原因。"; }
        [client requestCompletionForInput:@"请根据当前记录详细说明" rightContext:right contextMessages:@[] apiKey:@"synthetic-key" preferredModel:@"fixture"
            progress:nil completion:^(CPARemoteCompletionResult *r){result=r;}];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while(!result && deadline.timeIntervalSinceNow>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Assert(result!=nil,@"middle response arrives");
        if(i<4) Assert([result.insertionText isEqual:answer],@"short connecting suffix survives client validation");
        else Assert(result.insertionText.length==0,@"client rejects repeated right-hand text");
        Assert(calls==(i==0?1:i==1?2:i==2?2:i==3?3:4),@"cache identity includes the right side");
    }
}

static void SlowDocumentCompletionReplay(void) {
    CPARemoteCompletionClient *client = Client();
    NSURLSession *session = [client valueForKey:@"session"];
    // A document completion arriving after six seconds must have time to finish,
    // while an unresponsive or endlessly streaming provider stays bounded.
    Assert(session.configuration.timeoutIntervalForRequest > 6.0
        && session.configuration.timeoutIntervalForResource > 6.0
        && session.configuration.timeoutIntervalForResource <= 15.0,
        @"remote document completion must survive six seconds with a bounded deadline");
    CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
        (void)request;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.1 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                respond(200, @{@"choices":@[@{@"message":@{@"content":@"自然流畅"},@"finish_reason":@"stop"}]});
            });
    };
    __block CPARemoteCompletionResult *result = nil;
    [client requestCompletionForInput:@"合成测试：这些细节让使用过程更加" rightContext:@"，其他设置保持不变。"
        contextMessages:@[] apiKey:@"synthetic-key" preferredModel:@"fixture" progress:nil
        completion:^(CPARemoteCompletionResult *r) { result = r; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:9];
    while (!result && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Assert([result.insertionText isEqual:@"自然流畅"],
        @"a slow middle-document suffix still reaches final validation");
}

int main(void) {
    @autoreleasepool {
        SlowDocumentCompletionReplay();
        MiddleRequestReplay();
        __block NSUInteger literalModeHTTP = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            (void)request; literalModeHTTP++;
            respond(200, @{@"choices":@[@{@"message":@{@"content":@"请标明需要进一步核实的对应关系。"}}]});
        };
        CPARemoteCompletionClient *literalClient = Client();
        NSString *openDraft = @"请核对当前输入字段的映射，";
        CPARemoteCompletionResult *seed = WaitForResult(literalClient, openDraft, @"fixture", NO);
        Assert(seed.insertionText.length > 0 && literalModeHTTP == 1, @"seed a model candidate cache");
        literalClient.literalContinuationsOnly = YES;
        CPARemoteCompletionResult *restricted = WaitForResult(literalClient, openDraft, @"fixture", NO);
        Assert(restricted.insertionText == nil && !restricted.cacheHit && literalModeHTTP == 1
            && [restricted.phase isEqual:@"no_suggestion_literal_only"], @"literal-only must not reuse model output from cache");
        restricted = WaitForResult(literalClient, @"请明确另一项核查的范围，", @"", NO);
        Assert(restricted.insertionText == nil && literalModeHTTP == 1, @"literal-only must not discover or call a model");
        restricted = WaitForResultWithContext(literalClient, @"我希望先了解如何", @"fixture",
            @[@{@"role":@"user", @"content":@"只修改颜色，不调整布局。"}], NO);
        Assert([restricted.insertionText isEqual:@"只修改颜色，不调整布局。"]
            && [restricted.generationSource isEqual:@"literal_user_scope"] && literalModeHTTP == 1,
            @"verified literal scope remains available without network");
        literalClient.literalContinuationsOnly = NO;
        restricted = WaitForResult(literalClient, openDraft, @"fixture", NO);
        Assert(restricted.insertionText.length > 0 && restricted.cacheHit, @"local-only use can resume its prior generation path");
        CPARemoteCompletionResult *unknownSource = [CPARemoteCompletionResult new];
        [unknownSource setValue:@"future-unrecognized-phase" forKey:@"phase"];
        Assert([unknownSource.generationSource isEqual:@"unknown"],
            @"unrecognized diagnostic phases must not be reported as provider requests");
        Assert(CPARemoteCompletionBaseURLIsAllowed(
                [NSURL URLWithString:@"https://example.invalid/v1"]),
            @"remote HTTPS endpoints should remain allowed");
        Assert(CPARemoteCompletionBaseURLIsAllowed(
                [NSURL URLWithString:@"http://127.0.0.1:18921/v1"]),
            @"a loopback HTTP endpoint should be allowed for the local model");
        Assert(!CPARemoteCompletionBaseURLIsAllowed(
                [NSURL URLWithString:@"http://example.invalid/v1"]),
            @"plain HTTP must stay forbidden for non-local providers");
        __block NSUInteger requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            (void)request; requestCount++;
            respond(200, @{@"choices":@[@{@"message":@{@"content":@""}, @"finish_reason":@"stop"}]});
        };
        for (NSString *draft in @[@"请核对当前输入字段的映射。", @"请核对当前输入字段的映射？",
            @"需要把appstore去掉，并核实可选列表中不再显示 App Store。还有现在为什么不会接着提示后面的了"]) {
            CPARemoteCompletionResult *r = WaitForResult(Client(), draft, @"fixture-remote", NO);
            Assert(requestCount == 1 && r.statusCode == 200 && r.insertionText.length == 0,
                @"sentences and the reported second clause reach HTTP; empty model responses stay empty");
            requestCount = 0;
        }
        for (NSString *model in @[@"fixture-remote", @"mlx-community/Qwen3-4B-Instruct-2507-4bit"]) {
            CPARemoteCompletionClient *optionClient = Client();
            optionClient.usesLocalPrefixCompletion = [model hasPrefix:@"mlx"];
            NSDate *cooldown = [NSDate dateWithTimeIntervalSinceNow:60];
            [optionClient setValue:cooldown forKey:@"circuitOpenUntil"];
            [optionClient setValue:@2 forKey:@"consecutiveFailureCount"];
            for (NSArray *pick in @[
                @[@"只做你提到的第二项。", @"保留草稿。", @"第一项是修改颜色，第二项是保留草稿。"],
                @[@"只选第一项", @"修改颜色。", @"第一项是修改颜色，第二项是保留草稿。"],
                @[@"只选第二项", @"保留草稿。", @"1. **修改颜色**。\n\n2. **保留草稿。**\n"],
                @[@"只选第二项", @"核对字体。", @"1. **修改颜色**。\n\n2. **核对字体。**\n"]]) {
                NSArray *history = @[@{@"role":@"assistant", @"content":pick[2]},
                    @{@"role":@"user", @"content":pick[0]}];
                CPARemoteCompletionResult *r = WaitForResultWithContext(optionClient, @"我希望先了解如何", model, history, NO);
                Assert([r.insertionText isEqual:pick[1]] && [r.phase isEqual:@"explicit_option"]
                    && r.statusCode == 0 && requestCount == 0,
                    @"literal selected action uses no HTTP and updates when user choice changes");
                Assert([r.generationSource isEqual:@"literal_option"], @"literal option provenance is distinct from a model response");
                Assert([[optionClient valueForKey:@"circuitOpenUntil"] isEqual:cooldown]
                    && [[optionClient valueForKey:@"consecutiveFailureCount"] integerValue] == 2,
                    @"literal success must not reset provider failure or rate-limit cooldown state");
            }
            for (NSArray *pair in @[
                @[@"只改颜色，不动布局。", @"只改颜色，不动布局。"],
                @[@"取消之前方案，改为只保留草稿，不导出记录。", @"只保留草稿，不导出记录。"]]) {
                NSArray *history = @[@{@"role":@"assistant", @"content":@"之前考虑调整布局和字号。"},
                    @{@"role":@"user", @"content":pair[0]}];
                CPARemoteCompletionResult *r = WaitForResultWithContext(optionClient, @"我希望先了解如何", model, history, NO);
                Assert([r.insertionText isEqual:pair[1]] && [r.phase isEqual:@"explicit_user_scope"]
                    && r.statusCode == 0 && requestCount == 0,
                    @"user scope must preserve exclusion and latest replacement without HTTP");
                Assert([r.generationSource isEqual:@"literal_user_scope"], @"user scope provenance is distinct from a model response");
                Assert([[optionClient valueForKey:@"circuitOpenUntil"] isEqual:cooldown]
                    && [[optionClient valueForKey:@"consecutiveFailureCount"] integerValue] == 2,
                    @"user scope success cannot clear provider cooldown or failure count");
            }
            NSArray *ordinaryHistory = @[@{@"role":@"user", @"content":@"只恢复窗口位置，不调整按钮大小和文字间距。"}];
            CPARemoteCompletionResult *ordinary = WaitForResultWithContext(optionClient,
                @"请只恢复窗口位置，不调", model, ordinaryHistory, NO);
            Assert([ordinary.insertionText isEqual:@"整按钮大小和文字间距。"]
                && [ordinary.generationSource isEqual:@"literal_user_scope"] && requestCount == 0,
                @"ordinary exclusion completion must use the same no-network path for both providers");
            Assert([[optionClient valueForKey:@"circuitOpenUntil"] isEqual:cooldown]
                && [[optionClient valueForKey:@"consecutiveFailureCount"] integerValue] == 2,
                @"ordinary literal completion cannot clear provider health state");
            for (NSString *draft in @[@"原文 {{field_", @"我希望先了解如何", @"请核对 https://example.test/path"]) {
                CPARemoteCompletionResult *stopped = WaitForResultWithContext(optionClient, draft, model, @[], NO);
                Assert(stopped.insertionText == nil && stopped.statusCode == 0 && requestCount == 0,
                    @"protected syntax and missing-context stops do not contact the provider");
                Assert([stopped.generationSource isEqual:@"not_requested"], @"a boundary stop must not be labeled as model generation");
                Assert([[optionClient valueForKey:@"circuitOpenUntil"] isEqual:cooldown]
                    && [[optionClient valueForKey:@"consecutiveFailureCount"] integerValue] == 2,
                    @"a no-request stop cannot prove provider recovery or clear its cooldown");
            }
            [optionClient setValue:nil forKey:@"circuitOpenUntil"];
            CPARemoteCompletionResult *fallback = WaitForResultWithContext(optionClient, @"我希望先了解如何", model,
                @[@{@"role":@"assistant", @"content":@"第一项是修改颜色，第二项是保留草稿。"},
                    @{@"role":@"user", @"content":@"只做第二项，但不要新增功能。"}], NO);
            Assert(requestCount == 1 && ![fallback.phase isEqual:@"explicit_option"],
                @"qualified selection falls through to the existing provider path without invented extraction");
            requestCount = 0;
            for (NSArray *pair in @[
                @[@"我希望先了解如何", @"只改颜色，但不要动布局。"],
                @[@"我希望先了解如何", @"好的"],
                @[@"我希望先了解如何保留草稿", @"只改颜色，不动布局。"]]) {
                CPARemoteCompletionClient *fallbackClient = Client();
                fallbackClient.usesLocalPrefixCompletion = [model hasPrefix:@"mlx"];
                CPARemoteCompletionResult *r = WaitForResultWithContext(fallbackClient, pair[0], model,
                    @[@{@"role":@"user", @"content":pair[1]}], NO);
                if ([pair[1] isEqual:@"好的"]) {
                    Assert(requestCount == 0 && [r.phase isEqual:@"no_suggestion_insufficient_context"],
                        @"a bare acknowledgment retains the existing insufficient-context gate");
                } else if ([pair[0] isEqual:@"我希望先了解如何保留草稿"]) {
                    Assert(requestCount == 1 && ![r.phase isEqual:@"explicit_user_scope"],
                        @"a specific question reaches the provider without reviving old scope");
                } else {
                    Assert(requestCount == 1 && ![r.phase isEqual:@"explicit_user_scope"],
                        [NSString stringWithFormat:@"unsupported scope fallback: fixture=%@ phase=%@ requests=%lu",
                            pair, r.phase, (unsigned long)requestCount]);
                }
                requestCount = 0;
            }
        }
        // Final diagnostics distinguish provider abstention, truncation and echo
        // across both wire formats. Never include an arbitrary provider reason.
        NSString *diagnosticInput = @"请接着整理内容";
        NSArray *diagnosticCases = @[
            @[@"", @"stop", @"empty_content", @"stop"],
            @[diagnosticInput, @"stop", @"echo_only", @"stop"],
            @[@"保留原文并核查对应来源，遇到缺失字段时", @"length", @"length_limit", @"length"],
            @[@"我可以帮你完成这个任务。", @"stop", @"filtered", @"stop"],
            @[@"保留", @"stop", @"too_short", @"stop"],
            @[@"", @"private-provider-text-must-not-escape", @"empty_content", @"other"],
            @[@"并标明每条记录对应的来源。", @"stop", @"none", @"stop"]
        ];
        for (NSNumber *stream in @[@NO, @YES]) {
            for (NSArray *item in diagnosticCases) {
                NSDictionary *choice = @{@"message":@{@"content":item[0]}, @"finish_reason":item[1]};
                CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
                    (void)request; respond(200, @{@"choices":@[choice]});
                };
                CPAStubURLProtocol.streamingHandler = stream.boolValue ?
                    ^(NSURLRequest *request, void (^respond)(NSInteger, NSData *)) {
                        (void)request;
                        NSData *event = [NSJSONSerialization dataWithJSONObject:@{@"choices":@[choice]} options:0 error:nil];
                        NSString *body = [NSString stringWithFormat:@"data: %@\n\ndata: [DONE]\n\n",
                            [[NSString alloc] initWithData:event encoding:NSUTF8StringEncoding]];
                        respond(200, [body dataUsingEncoding:NSUTF8StringEncoding]);
                    } : nil;
                CPARemoteCompletionClient *diagnosticClient = Client();
                diagnosticClient.requiresFinalValidation = YES;
                CPARemoteCompletionResult *r = WaitForResult(diagnosticClient, diagnosticInput, @"fixture-remote", NO);
                Assert([r.responseDiagnostics[@"finishReason"] isEqual:item[3]]
                    && [r.responseDiagnostics[@"rawOutputCharacterCount"] isEqual:@([item[0] length])]
                    && [r.responseDiagnostics[@"noSuggestionReason"] isEqual:item[2]]
                    && [r.responseDiagnostics[@"responseFormat"] isEqual:stream.boolValue ? @"sse" : @"json"]
                    && [r.responseDiagnostics[@"doneSeen"] boolValue] == stream.boolValue,
                    [NSString stringWithFormat:@"sanitized final diagnostics agree for JSON/SSE: %@", r.responseDiagnostics]);
                Assert(r.firstDataMilliseconds != nil && r.completionDispatchMilliseconds != nil
                    && r.validationMilliseconds != nil
                    && r.firstDataMilliseconds.unsignedIntegerValue >= r.completionDispatchMilliseconds.unsignedIntegerValue
                    && r.firstDataMilliseconds.unsignedIntegerValue <= r.durationMilliseconds + 1,
                    @"response timing distinguishes request dispatch, first body data and final validation");
                Assert([item[2] isEqual:@"none"] ? r.insertionText.length > 0 : r.insertionText.length == 0,
                    @"diagnostics never make empty, echoed, truncated or filtered content insertable");
                if ([item[2] isEqual:@"length_limit"])
                    Assert([r.phase isEqual:@"no_suggestion_rejected"], @"SSE truncation must no longer masquerade as provider abstention");
            }
        }
        CPAStubURLProtocol.streamingHandler = nil;
        __block BOOL requestWasRedacted = NO;
        for (NSArray *pair in @[@[@"", @"no_suggestion"],
            @[@"我可以帮你完成这个任务。", @"no_suggestion_rejected"]]) {
            CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
                (void)request;
                respond(200, @{@"choices":@[@{@"message":@{@"content":pair[0]}}]});
            };
            CPARemoteCompletionResult *emptyOrRejected = WaitForResult(Client(), @"请接着整理内容", @"fixture-remote", NO);
            Assert([emptyOrRejected.phase isEqual:pair[1]] && emptyOrRejected.insertionText == nil,
                @"empty model output and a rejected nonempty response have different diagnostic phases");
        }
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            (void)request; requestCount++;
            respond(200, @{@"choices":@[@{@"message":@{@"content":@""}, @"finish_reason":@"stop"}]});
        };
        for (id bad in @[@[NSNull.null], @[@{@"role":@"user", @"content":@7}],
            @[@{@"role":@"user"}], @[@{@"role":@7, @"content":@"只改颜色。"}],
            @[@{@"role":@"system", @"content":@"只改颜色。"}], @[@{@"content":@"只改颜色。"}],
            @[@{@"role":@"user", @"content":@"只改颜色。"}, NSNull.null]]) {
            CPARemoteCompletionResult *invalid = nil;
            BOOL threw = NO;
            @try { invalid = WaitForResultWithContext(Client(), @"我希望先了解如何", @"fixture-remote", bad, NO); }
            @catch (NSException *exception) { (void)exception; threw = YES; }
            Assert(!threw && [invalid.phase isEqual:@"no_suggestion_invalid_context"]
                && invalid.insertionText == nil && requestCount == 0,
                @"malformed context stops without a crash, HTTP request, or borrowing an older user scope");
        }
        {
            NSMutableString *content = [@"只改颜色，不动布局。" mutableCopy];
            NSMutableString *role = [@"user" mutableCopy];
            NSMutableDictionary *message = [@{@"role":role, @"content":content} mutableCopy];
            CPARemoteCompletionClient *snapshotClient = Client();
            CPARemoteCompletionTask *task = [snapshotClient requestCompletionForInput:@"我希望先了解如何"
                contextMessages:@[message] apiKey:@"test-key-not-a-real-secret" preferredModel:@"fixture-remote"
                progress:nil completion:^(CPARemoteCompletionResult *r) { (void)r; }];
            [content setString:@"只删除原文。"];
            [role setString:@"assistant"];
            message[@"content"] = @"只调整布局。";
            NSArray *captured = [task valueForKey:@"contextMessages"];
            Assert([captured[0][@"role"] isEqual:@"user"] && [captured[0][@"content"] isEqual:@"只改颜色，不动布局。"],
                @"request context and its fingerprint must share an immutable snapshot of role and content");
            [task cancel];
        }
        for (NSArray *history in @[
            @[@{@"role":@"user", @"content":@"只改颜色，不动布局。"}],
            @[@{@"role":@"assistant", @"content":@"第一项是修改颜色，第二项是保留草稿。"},
                @{@"role":@"user", @"content":@"只选第二项"}]]) {
            CPARemoteCompletionResult *cancelled = WaitForResultWithContext(Client(), @"我希望先了解如何",
                @"fixture-remote", history, YES);
            Assert(cancelled.outcome == CPARemoteCompletionOutcomeCancelled
                && cancelled.insertionText == nil && cancelled.outputCharacterCount == 0 && requestCount == 0,
                @"cancelling a computed literal before callback delivery suppresses its insertion");
        }
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            requestCount++;
            Assert([request.URL.path isEqualToString:@"/v1/chat/completions"],
                @"manual model should skip discovery");
            Assert([[request valueForHTTPHeaderField:@"Authorization"]
                isEqualToString:@"Bearer test-key-not-a-real-secret"],
                @"authorization header should be present");
            Assert([[request valueForHTTPHeaderField:@"Accept"]
                isEqualToString:@"text/event-stream"],
                @"completion request should advertise SSE support");
            NSDictionary *body = [NSJSONSerialization JSONObjectWithData:
                RequestBodyData(request) options:0 error:nil];
            NSString *content = body[@"messages"][1][@"content"];
            requestWasRedacted = [content containsString:@"{EMAIL}"]
                && ![content containsString:@"person@example.com"];
            respond(200, @{
                @"choices": @[@{@"message": @{@"content": @" done with a complete continuation"}}],
            });
        };
        CPARemoteCompletionResult *result = WaitForResult(Client(),
            @"contact person@example.com", @"manual-chat", NO);
        Assert(result.outcome == CPARemoteCompletionOutcomeSuccess,
            @"manual completion should succeed");
        Assert([result.generationSource isEqual:@"provider"], @"an HTTP completion records provider provenance");
        Assert([result.insertionText isEqualToString:@" done with a complete continuation"],
            @"suffix should be returned");
        Assert(result.requestID.length >= 8 && result.phase.length > 0,
            @"successful completion should carry request diagnostics");
        Assert([result.model isEqualToString:@"manual-chat"]
                && result.errorDomain == nil && result.errorMessage == nil,
            @"successful completion should carry model without an error");
        Assert(requestCount == 1 && requestWasRedacted,
            @"request should be single and redacted");

        __block NSUInteger cueRequestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            (void)request; cueRequestCount++;
            respond(200, @{@"choices":@[@{@"message":@{@"content":@"检查原文与结果的具体差异。"}}]});
        };
        CPARemoteCompletionResult *cueResult = WaitForResult(Client(), @"继续支持吧，", @"manual-chat", NO);
        Assert(cueRequestCount==0 && cueResult.insertionText==nil
            && [cueResult.phase isEqual:@"no_suggestion_insufficient_context"],
            @"remote context-free continue cues must abstain before any network request");
        cueResult = WaitForResult(Client(), @"继续吧", @"", NO);
        Assert(cueRequestCount==0 && [cueResult.phase isEqual:@"no_suggestion_insufficient_context"],
            @"missing context is decided before even model discovery");
        cueResult = WaitForResultWithContext(Client(), @"继续支持吧，", @"manual-chat",
            @[@{@"role":@"user",@"content":@"请核对原文与结果的差异"}], NO);
        Assert(cueRequestCount==1 && cueResult.insertionText.length>0,
            @"remote continue cues with actual selected context remain eligible");

        for (NSString *model in @[@"manual-chat", @"Qwen3-4B-Instruct-2507"]) {
            for (NSString *draft in @[@"请帮我确认为什么", @"我希望先了解如何"]) {
                for (NSArray *history in @[@[], @[@{@"role": @"assistant", @"content": @"可以研究如何构建证据链。"}],
                    @[@{@"role": @"user", @"content": @"好的"}], @[@{@"role": @"user", @"content": draft}]]) {
                    NSUInteger before = cueRequestCount;
                    CPARemoteCompletionResult *missing = WaitForResultWithContext(Client(), draft, model, history, NO);
                    Assert(cueRequestCount == before && [missing.phase isEqual:@"no_suggestion_insufficient_context"],
                        @"objectless question stems need user material before any model request");
                }
                NSUInteger before = cueRequestCount;
                WaitForResultWithContext(Client(), draft, model,
                    @[@{@"role": @"user", @"content": @"本轮检查搜索框的输入和清空行为，不改布局。"}], NO);
                Assert(cueRequestCount == before + 1, @"question stem with concrete user context remains eligible");
            }
        }

        NSURLSessionConfiguration *prefixConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        prefixConfiguration.protocolClasses = @[CPAStubURLProtocol.class];
        CPARemoteCompletionClient *prefixClient = [[CPARemoteCompletionClient alloc]
            initWithBaseURL:[NSURL URLWithString:@"http://127.0.0.1:18921/v1"]
            sessionConfiguration:prefixConfiguration callbackQueue:dispatch_get_main_queue()];
        prefixClient.usesLocalPrefixCompletion = YES;
        prefixClient.requiresFinalValidation = YES;
        __block NSUInteger prefixRequestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            prefixRequestCount++;
            NSDictionary *body = [NSJSONSerialization JSONObjectWithData:RequestBodyData(request) options:0 error:nil];
            Assert([request.URL.path isEqualToString:@"/v1/completions"] && body[@"prompt"] != nil,
                @"local opt-in must route through text completion");
            respond(200, @{@"choices": @[@{@"text": @"检查原文与结果的具体差异。"}]});
        };
        CPARemoteCompletionResult *prefixResult = WaitForResult(prefixClient,
            @"不要修改配置，只需要", @"Qwen3-4B-Instruct-2507", NO);
        Assert([prefixResult.insertionText isEqualToString:@"检查原文与结果的具体差异。"],
            @"client must return the generated suffix alone");
        for (NSString *blocked in @[@"原文 {{field_", @"代码：\n```json\n{", @"请核对 https://example.test/path"]) {
            CPARemoteCompletionResult *boundaryResult = WaitForResult(prefixClient, blocked, @"Qwen3-4B-Instruct-2507", NO);
            Assert(prefixRequestCount == 1 && boundaryResult.insertionText.length == 0
                && [boundaryResult.phase isEqualToString:@"no_suggestion_boundary"],
                @"protected syntax must not reach the network or cache");
        }
        prefixResult = WaitForResult(prefixClient, @"继续支持吧，", @"Qwen3-4B-Instruct-2507", NO);
        Assert(prefixRequestCount == 1 && prefixResult.insertionText.length == 0
            && [prefixResult.phase isEqualToString:@"no_suggestion_insufficient_context"],
            @"context-free continuation cues must not generate stock instructions");
        prefixResult = WaitForResultWithContext(prefixClient, @"继续支持吧，", @"Qwen3-4B-Instruct-2507",
            @[@{@"role": @"user", @"content": @"请核对这次提示词的具体偏差"}], NO);
        Assert(prefixRequestCount == 2 && prefixResult.insertionText.length > 0,
            @"a short cue with reference context can still request a continuation");
        CPARemoteCompletionClient *remotePrefixClient = Client();
        remotePrefixClient.usesLocalPrefixCompletion = YES;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            NSDictionary *body = [NSJSONSerialization JSONObjectWithData:RequestBodyData(request) options:0 error:nil];
            Assert([request.URL.path isEqualToString:@"/v1/chat/completions"] && body[@"prompt"] == nil,
                @"a remote host must never use the local tokenizer assumption");
            respond(200, @{@"choices": @[@{@"message": @{@"content": @"检查原文与结果的具体差异。"}}]});
        };
        prefixResult = WaitForResult(remotePrefixClient, @"请核对原文", @"Qwen3-4B-Instruct-2507", NO);
        Assert(prefixResult.outcome == CPARemoteCompletionOutcomeSuccess, @"remote chat compatibility retained");

        // Isolated test words are low-value for the resident small model. The
        // remote GPT-5.6 path remains responsible for quality fallback.
        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            requestCount++;
            respond(200, @{
                @"choices": @[@{@"message": @{@"content":
                    @" this response should not be requested"}}],
            });
        };
        result = WaitForResult(Client(), @"ceshi",
            @"mlx-community/Qwen3-4B-Instruct-2507-4bit", NO);
        Assert(requestCount == 0 && result.outcome == CPARemoteCompletionOutcomeSuccess
                && result.insertionText == nil
                && [result.phase isEqualToString:@"no_suggestion_local_low_value"],
            @"a local model must skip isolated test words without a network request");

        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            requestCount++;
            respond(200, @{
                @"choices": @[@{ @"message": @{ @"content":
                    @"，请继续补充完整的 AI 提示词约束和输出格式。" }}],
            });
        };
        result = WaitForResult(Client(), @"核对字段",
            @"mlx-community/Qwen3-4B-Instruct-2507-4bit", NO);
        Assert(requestCount == 1 && result.outcome == CPARemoteCompletionOutcomeSuccess
                && result.insertionText.length > 0,
            @"a meaningful short Chinese draft must not be blocked by the low-value gate");

        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            requestCount++;
            respond(200, @{
                @"choices": @[@{@"message": @{@"content":
                    @"，在具体情况下可以进一步提升整体体验，通常情况下再持续优化。"}}],
            });
        };
        result = WaitForResult(Client(), @"请优化这个复杂流程",
            @"mlx-community/Qwen3-4B-Instruct-2507-4bit", NO);
        Assert(requestCount == 1 && result.outcome == CPARemoteCompletionOutcomeSuccess
                && result.insertionText == nil
                && [result.phase isEqualToString:@"no_suggestion_local_low_value"],
            @"a generic local continuation should be suppressed without fallback pollution");

        __block NSUInteger progressCount = 0;
        __block CPARemoteCompletionResult *streamResult = nil;
        dispatch_semaphore_t streamSemaphore = dispatch_semaphore_create(0);
        CPAStubURLProtocol.streamingHandler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSData *)) {
            (void)request;
            NSDictionary *first = @{
                @"choices": @[@{@"delta": @{ @"content": @" first part of a" }}],
            };
            NSDictionary *second = @{
                @"choices": @[@{@"delta": @{ @"content": @" meaningful continuation" }}],
            };
            NSData *firstData = [NSJSONSerialization dataWithJSONObject:first options:0 error:nil];
            NSData *secondData = [NSJSONSerialization dataWithJSONObject:second options:0 error:nil];
            NSString *body = [NSString stringWithFormat:@"data: %@\n\ndata: %@\n\ndata: [DONE]\n\n",
                [[NSString alloc] initWithData:firstData encoding:NSUTF8StringEncoding],
                [[NSString alloc] initWithData:secondData encoding:NSUTF8StringEncoding]];
            respond(200, [body dataUsingEncoding:NSUTF8StringEncoding]);
        };
        CPARemoteCompletionClient *streamClient = Client();
        [streamClient requestCompletionForInput:@"streaming" contextMessages:@[]
            apiKey:@"test-key-not-a-real-secret" preferredModel:@"manual-chat"
            progress:^(NSString *partial) {
                (void)partial;
                progressCount++;
            }
            completion:^(CPARemoteCompletionResult *value) {
                streamResult = value;
                dispatch_semaphore_signal(streamSemaphore);
            }];
        NSDate *streamDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (streamResult == nil && [streamDeadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Assert(streamResult != nil && progressCount > 0
            && [streamResult.insertionText isEqualToString:
                @" first part of a meaningful continuation"],
            @"SSE data should emit a partial continuation before final completion");
        progressCount = 0;
        streamResult = nil;
        CPARemoteCompletionClient *validatedClient = Client();
        validatedClient.requiresFinalValidation = YES;
        [validatedClient requestCompletionForInput:@"streaming" contextMessages:@[]
            apiKey:@"test-key-not-a-real-secret" preferredModel:@"manual-chat"
            progress:^(NSString *partial) { (void)partial; progressCount++; }
            completion:^(CPARemoteCompletionResult *value) { streamResult = value; }];
        streamDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (streamResult == nil && streamDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Assert(streamResult.insertionText.length > 0 && progressCount == 0,
            @"final validation mode must never expose an acceptable partial draft");
        CPAStubURLProtocol.streamingHandler = nil;

        // Local streaming may publish a conservative preview before the final
        // first long streamed sentence. The final result must still satisfy the
        // unchanged full-result contract.
        __block NSUInteger localProgressCount = 0;
        __block NSString *localProgressText = nil;
        __block NSString *localFirstProgressText = nil;
        streamResult = nil;
        CPAStubURLProtocol.streamingHandler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSData *)) {
            (void)request;
            NSDictionary *first = @{
                @"choices": @[@{@"delta": @{@"content": @"，请继续补充当前"}}],
            };
            NSDictionary *second = @{
                @"choices": @[@{@"delta": @{@"content":
                    @" but now a complete local continuation"}}],
            };
            NSData *firstData = [NSJSONSerialization dataWithJSONObject:first options:0 error:nil];
            NSData *secondData = [NSJSONSerialization dataWithJSONObject:second options:0 error:nil];
            NSString *body = [NSString stringWithFormat:@"data: %@\n\ndata: %@\n\ndata: [DONE]\n\n",
                [[NSString alloc] initWithData:firstData encoding:NSUTF8StringEncoding],
                [[NSString alloc] initWithData:secondData encoding:NSUTF8StringEncoding]];
            respond(200, [body dataUsingEncoding:NSUTF8StringEncoding]);
        };
        CPARemoteCompletionClient *localStreamClient = Client();
        localStreamClient.progressMinimumCharacterCount = 8;
        [localStreamClient requestCompletionForInput:
            @"a sufficiently descriptive local request"
            contextMessages:@[] apiKey:@"test-key-not-a-real-secret"
            preferredModel:@"mlx-community/Qwen3-4B-Instruct-2507-4bit"
            progress:^(NSString *partial) {
                localProgressCount++;
                if (localFirstProgressText == nil) {
                    localFirstProgressText = partial;
                }
                localProgressText = partial;
            }
            completion:^(CPARemoteCompletionResult *value) {
                streamResult = value;
            }];
        NSDate *localStreamDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (streamResult == nil && [localStreamDeadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Assert(streamResult != nil && localProgressCount > 0
                && localFirstProgressText.length >= 8
                && localFirstProgressText.length < 20
                && localProgressText.length >= localFirstProgressText.length
                && streamResult.insertionText.length >= 20,
            @"local streaming should show a safe early preview without weakening final quality");
        CPAStubURLProtocol.streamingHandler = nil;

        // Repeated text split across SSE events must never become an acceptable preview.
        __block NSUInteger repeatedProgressCount = 0;
        __block CPARemoteCompletionResult *repeatedResult = nil;
        CPAStubURLProtocol.streamingHandler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSData *)) {
            (void)request;
            NSMutableString *body = [NSMutableString string];
            for (NSString *piece in @[@"盲区确认后", @"提交整改清单", @"，会议记录由", @"项目经理归档。"] ) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:
                    @{@"choices": @[@{@"delta": @{@"content": piece}}]}
                    options:0 error:nil];
                [body appendFormat:@"data: %@\n\n",
                    [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
            }
            [body appendString:@"data: [DONE]\n\n"];
            respond(200, [body dataUsingEncoding:NSUTF8StringEncoding]);
        };
        CPARemoteCompletionClient *repeatedClient = Client();
        repeatedClient.progressMinimumCharacterCount = 8;
        [repeatedClient requestCompletionForInput:
            @"这次复盘明确责任人。盲区确认后提交整改清单，会议记录由项目经理归档。"
            contextMessages:@[] apiKey:@"test-key-not-a-real-secret"
            preferredModel:@"mlx-community/Qwen3-4B-Instruct-2507-4bit"
            progress:^(NSString *partial) { (void)partial; repeatedProgressCount++; }
            completion:^(CPARemoteCompletionResult *value) { repeatedResult = value; }];
        NSDate *repeatedDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (repeatedResult == nil && [repeatedDeadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Assert(repeatedResult != nil && repeatedResult.insertionText.length == 0
            && repeatedProgressCount == 0,
            @"repeated SSE fragments must be rejected before any preview is delivered");
        CPAStubURLProtocol.streamingHandler = nil;

        // A burst of tiny SSE chunks must be coalesced before it reaches the
        // main/UI queue. Otherwise every token schedules a separate callback
        // and can delay the event tap while the panel is being repainted.
        __block NSUInteger burstProgressCount = 0;
        __block CPARemoteCompletionResult *burstResult = nil;
        CPAStubURLProtocol.streamingHandler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSData *)) {
            (void)request;
            NSMutableString *body = [NSMutableString string];
            for (NSUInteger index = 0; index < 24; index++) {
                NSString *piece = index == 0 ? @"，" : @"续";
                NSDictionary *event = @{
                    @"choices": @[@{@"delta": @{@"content": piece}}],
                };
                NSData *eventData = [NSJSONSerialization dataWithJSONObject:event
                    options:0 error:nil];
                NSString *eventText = [[NSString alloc] initWithData:eventData
                    encoding:NSUTF8StringEncoding];
                [body appendFormat:@"data: %@\n\n%@", eventText,
                    index == 23 ? @"data: [DONE]\n\n" : @""];
            }
            respond(200, [body dataUsingEncoding:NSUTF8StringEncoding]);
        };
        CPARemoteCompletionClient *burstClient = Client();
        burstClient.progressMinimumCharacterCount = 8;
        burstClient.progressMinimumCharacterDelta = 4;
        CPAValidationCounter *validationCounter = [CPAValidationCounter new];
        [burstClient setValue:validationCounter forKey:@"protocol"];
        [burstClient requestCompletionForInput:
            @"a sufficiently descriptive burst-stream request"
            contextMessages:@[] apiKey:@"test-key-not-a-real-secret"
            preferredModel:@"mlx-community/Qwen3-4B-Instruct-2507-4bit"
            progress:^(NSString *partial) {
                (void)partial;
                burstProgressCount++;
            }
            completion:^(CPARemoteCompletionResult *value) {
                burstResult = value;
            }];
        NSDate *burstDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (burstResult == nil && [burstDeadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Assert(burstResult != nil && burstResult.insertionText.length >= 20
                && burstProgressCount > 0 && burstProgressCount <= 3
                && burstResult.streamParseWorkUnits > 0
                && burstResult.streamParseWorkUnits <= 4000,
            [NSString stringWithFormat:
                @"stream progress should be latest-only coalesced and parse incrementally (result=%@ length=%lu count=%lu work=%lu)",
                burstResult != nil ? burstResult.phase : @"nil",
                (unsigned long)(burstResult != nil ? burstResult.insertionText.length : 0),
                (unsigned long)burstProgressCount,
                (unsigned long)(burstResult != nil ? burstResult.streamParseWorkUnits : 0)]);
        Assert(validationCounter.count <= 6,
            @"24 tiny deltas should require at most five preview checks and one final check");
        CPAStubURLProtocol.streamingHandler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSData *)) {
            (void)request;
            respond(200, [NSMutableData dataWithLength:300 * 1024]);
        };
        CPARemoteCompletionResult *oversized = WaitForResult(Client(),
            @"synthetic oversized-response request", @"manual-chat", NO);
        Assert(oversized.outcome == CPARemoteCompletionOutcomeInvalidResponse
            && [oversized.phase isEqualToString:@"response_too_large"],
            @"oversized responses must terminate before parsing and release their buffers");
        CPAStubURLProtocol.streamingHandler = nil;

        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            requestCount++;
            NSString *content = @"，并补充具体修改建议、优先级和验收标准。";
            respond(200, @{
                @"choices": @[@{@"message": @{@"content": content}}],
            });
        };
        result = WaitForResult(Client(), @"quality-retry", @"manual-chat", NO);
        Assert(requestCount == 1
                && [result.insertionText isEqualToString:
                    @"，并补充具体修改建议、优先级和验收标准。"],
            @"a usable continuation should return after one request without a latency retry");

        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            requestCount++;
            NSString *content = @"检查输入提示是否正";
            respond(200, @{
                @"choices": @[@{@"message": @{@"content": content}}],
            });
        };
        result = WaitForResult(Client(), @"quality-fallback", @"manual-chat", NO);
        Assert(requestCount == 1 && result.insertionText == nil
                && [result.phase isEqualToString:@"no_suggestion_too_short"],
            @"a too-short result should stop after one request instead of doubling latency");

        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            respond(200, @{@"choices": @[@{@"message": @{@"content": @"检查输入提示是否正常"}}]});
        };
        result = WaitForResult(Client(), @"请在提交前", @"manual-chat", NO);
        Assert([result.insertionText isEqualToString:@"检查输入提示是否正常"],
            @"short natural suffixes must survive the client acceptance gate");
        result = WaitForResult(Client(), @"请在提交前", @"Qwen3-4B-Instruct-2507", NO);
        Assert([result.insertionText isEqualToString:@"检查输入提示是否正常"],
            @"local short suffixes must survive the local quality and final gates");
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            respond(200, @{@"choices": @[@{@"message": @{@"content": @"保留待确认项。"}}]});
        };
        result = WaitForResult(Client(), @"缺少依据的内容", @"manual-chat", NO);
        Assert([result.insertionText isEqualToString:@"保留待确认项。"], @"completed short suffix is not lost at the client gate");




        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            respond(200, @{@"choices": @[@{@"message": @{@"content": @"译文"}, @"finish_reason": @"stop"}]});
        };
        result = WaitForResult(Client(), @"请把正文翻译成英文，只输出", @"manual-chat", NO);
        Assert([result.insertionText isEqualToString:@"译文"], @"context-supported final short closure preserves exact text");
        result = WaitForResult(Client(), @"请检查记录，只输出", @"manual-chat", NO);
        Assert(result.insertionText == nil, @"unrelated short result remains rejected");

        for (NSString *model in @[@"manual-chat", @"mlx-community/Qwen3-4B-Instruct-2507-4bit"]) {
            for (NSArray *item in @[
                    @[@"请将刚才提到的颜色填入配置，颜色为", @"刚才指定的颜色是浅蓝色。", @"浅蓝色"],
                    @[@"这次段落改写的", @"我观察到这次段落改写把疑问句误写成了结论。", @"问题在于把疑问句误写成了结论。"]]) {
                CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
                    (void)request; respond(200, @{@"choices":@[@{@"message":@{@"content":item[2]}, @"finish_reason":@"stop"}]});
                };
                CPARemoteCompletionClient *groundedClient = Client();
                NSArray *context = @[@{@"role":@"user", @"content":item[1]}];
                result = WaitForResultWithContext(groundedClient, item[0], model, context, NO);
                Assert([result.insertionText isEqual:item[2]], @"client passes request evidence to both final gates");
                result = WaitForResultWithContext(groundedClient, item[0], model, @[], NO);
                Assert(result.insertionText == nil, @"context removal cannot reuse cached grounding");
            }
        }

        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            requestCount++;
            respond(200, @{
                @"choices": @[@{ @"message": @{ @"content":
                    @"，需要找到更高效的方法来解决这个问题，才能避免延误。" } }],
            });
        };
        result = WaitForResult(Client(), @"rejected-generic", @"manual-chat", NO);
        Assert(requestCount == 1 && result.insertionText == nil
            && [result.phase isEqualToString:@"no_suggestion_rejected"],
            @"clearly generic output should be rejected without a second slow request");

        requestCount = 0;
        CPARemoteCompletionClient *cacheClient = Client();
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            requestCount++;
            Assert([request.URL.path isEqualToString:@"/v1/chat/completions"],
                @"cache test should use completion endpoint");
            NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:RequestBodyData(request) options:0 error:nil];
            NSString *instructions = payload[@"messages"][0][@"content"];
            Assert([instructions containsString:@"inline document coauthor"] == (requestCount == 2),
                @"client must transmit document instructions only for the sampled document mode");
            respond(200, @{
                @"choices": @[@{@"message": @{@"content": @" cached continuation text that completes the current thought"}}],
            });
        };
        result = WaitForResult(cacheClient, @"cached-prefix", @"manual-chat", NO);
        CPARemoteCompletionResult *cachedResult = WaitForResult(cacheClient,
            @"cached-prefix", @"manual-chat", NO);
        Assert(requestCount == 1 && cachedResult.isCacheHit
                && [cachedResult.phase isEqualToString:@"cache"],
            @"same input should use the short-lived in-memory cache");

        cacheClient.documentContinuation = YES;
        cachedResult = WaitForResult(cacheClient, @"cached-prefix", @"manual-chat", NO);
        Assert(requestCount == 2 && !cachedResult.isCacheHit,
            @"document mode must not reuse a prompt-writing cached candidate");
        cachedResult = WaitForResult(cacheClient, @"cached-prefix", @"manual-chat", NO);
        Assert(requestCount == 2 && cachedResult.isCacheHit,
            @"document-mode requests can reuse their own cache");
        cacheClient.documentContinuation = NO;
        cachedResult = WaitForResult(cacheClient, @"cached-prefix", @"manual-chat", NO);
        Assert(requestCount == 2 && cachedResult.isCacheHit,
            @"returning to chat can reuse only its original prompt-mode cache entry");

        for (NSNumber *document in @[@NO, @YES]) {
            CPARemoteCompletionClient *stageClient = Client();
            stageClient.documentContinuation = document.boolValue;
            __block NSUInteger stageRequests = 0;
            CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
                stageRequests++;
                NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:RequestBodyData(request) options:0 error:nil];
                NSString *instructions = payload[@"messages"][0][@"content"];
                Assert([instructions containsString:document.boolValue ? @"文档续写阶段：" : @"续写阶段：作者刚刚接受"] == (stageRequests == 2),
                    @"stage is sampled for the actual HTTP request, not borrowed from cache");
                stageClient.continuationAfterAcceptance = NO; // In-flight property edits cannot alter this request's cache identity.
                respond(200, @{@"choices":@[@{@"message":@{@"content":@"并比较不同来源字段的含义是否一致。"}}]});
            };
            result = WaitForResult(stageClient, @"请核对字段映射。", @"manual-chat", NO);
            stageClient.continuationAfterAcceptance = YES;
            result = WaitForResult(stageClient, @"请核对字段映射。", @"manual-chat", NO);
            Assert(stageRequests == 2 && !result.isCacheHit, @"accepted stage cannot reuse ordinary cached suffix");
            stageClient.continuationAfterAcceptance = YES;
            result = WaitForResult(stageClient, @"请核对字段映射。", @"manual-chat", NO);
            Assert(stageRequests == 2 && result.isCacheHit, @"accepted stage retains its own sampled cache identity");
            stageClient.continuationAfterAcceptance = NO;
            result = WaitForResult(stageClient, @"请核对字段映射。", @"manual-chat", NO);
            Assert(stageRequests == 2 && result.isCacheHit, @"ordinary request returns to only its own cache");

        }

        // A request started under the old context/config epoch must not refill
        // the cache after invalidation, even if its transport completes later.
        requestCount = 0;
        CPARemoteCompletionClient *epochClient = Client();
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request; requestCount++;
            if (requestCount == 1) [epochClient invalidateCompletionCache];
            respond(200, @{@"choices": @[@{@"message": @{@"content":
                @" cached continuation text that completes the current thought"}}]});
        };
        result = WaitForResult(epochClient, @"cache-epoch-input", @"manual-chat", NO);
        cachedResult = WaitForResult(epochClient, @"cache-epoch-input", @"manual-chat", NO);
        Assert(requestCount == 2 && !cachedResult.isCacheHit,
            @"late completion must not repopulate an invalidated cache epoch");
        cachedResult = WaitForResult(epochClient, @"cache-epoch-input", @"manual-chat", NO);
        Assert(requestCount == 2 && cachedResult.isCacheHit,
            @"a result generated in the current epoch can still be cached");

        requestCount = 0;
        CPARemoteCompletionClient *contextCacheClient = Client();
        NSArray *firstContext = @[@{ @"role": @"user", @"content": @"first topic" }];
        NSArray *secondContext = @[@{ @"role": @"user", @"content": @"second topic" }];
        result = WaitForResultWithContext(contextCacheClient, @"same longer input",
            @"manual-chat", firstContext, NO);
        cachedResult = WaitForResultWithContext(contextCacheClient, @"same longer input",
            @"manual-chat", secondContext, NO);
        Assert(requestCount == 2 && !cachedResult.isCacheHit,
            @"same text from a different conversation context must not reuse an old result");
        cachedResult = WaitForResultWithContext(contextCacheClient, @"same longer input",
            @"manual-chat", secondContext, NO);
        Assert(requestCount == 2 && cachedResult.isCacheHit,
            @"same text may reuse a result only when the conversation context also matches");

        requestCount = 0;
        CPARemoteCompletionClient *shortCacheClient = Client();
        result = WaitForResult(shortCacheClient, @"但是", @"manual-chat", NO);
        cachedResult = WaitForResult(shortCacheClient, @"但是", @"manual-chat", NO);
        Assert(requestCount == 2 && !cachedResult.isCacheHit,
            @"very short ambiguous input must never reuse a cross-conversation completion");

        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            requestCount++;
            respond(200, @{
                @"choices": @[@{ @"message": @{ @"content": @" world with more context and a complete next clause" } }],
            });
        };
        CPARemoteCompletionClient *prefixCacheClient = Client();
        result = WaitForResult(prefixCacheClient, @"hello1234", @"manual-chat", NO);
        cachedResult = WaitForResult(prefixCacheClient, @"hello1234 w", @"manual-chat", NO);
        Assert(requestCount == 1 && cachedResult.isCacheHit
                && [cachedResult.insertionText isEqualToString:
                    @"orld with more context and a complete next clause"],
            @"continued typing should reuse a valid cached suffix");

        requestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            requestCount++;
            if ([request.URL.path hasSuffix:@"/models"]) {
                respond(200, @{@"data": @[@{@"id": @"chat-auto"}]});
            } else {
                NSDictionary *body = [NSJSONSerialization JSONObjectWithData:
                    RequestBodyData(request) options:0 error:nil];
                Assert([body[@"model"] isEqualToString:@"chat-auto"],
                    @"discovered model should be used");
                respond(200, @{
                    @"choices": @[@{@"message": @{@"content": @" ok with a discovered model continuation"}}],
                });
            }
        };
        result = WaitForResult(Client(), @"prefix", @"", NO);
        Assert(result.outcome == CPARemoteCompletionOutcomeSuccess
            && requestCount == 2, @"model discovery and completion should run");

        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    respond(200, @{
                        @"choices": @[@{@"message": @{@"content": @" late continuation text"}}],
                    });
                });
        };
        result = WaitForResult(Client(), @"cancel", @"manual-chat", YES);
        Assert(result.outcome == CPARemoteCompletionOutcomeCancelled,
            @"cancel should suppress the response");

        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(2.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    respond(200, @{
                        @"choices": @[@{@"message": @{@"content": @" patient continuation text"}}],
                    });
                });
        };
        result = WaitForResult(Client(), @"slow", @"manual-chat", NO);
        Assert(result.outcome == CPARemoteCompletionOutcomeSuccess,
            @"a valid 2.3 second model response should not time out");

        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            respond(401, @{});
        };
        result = WaitForResult(Client(), @"auth", @"manual-chat", NO);
        Assert(result.outcome == CPARemoteCompletionOutcomeUnauthorized,
            @"401 should be classified");

        __block NSUInteger failureRequestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            failureRequestCount++;
            respond(500, @{});
        };
        CPARemoteCompletionClient *circuitClient = Client();
        CPARemoteCompletionResult *serverFailureResult = nil;
        for (NSUInteger i = 0; i < 3; i++) {
            result = WaitForResult(circuitClient, @"server", @"manual-chat", NO);
            serverFailureResult = result;
            Assert(result.outcome == CPARemoteCompletionOutcomeServerError,
                @"500 should be classified");
        }
        result = WaitForResult(circuitClient, @"server", @"manual-chat", NO);
        Assert(result.outcome == CPARemoteCompletionOutcomeCircuitOpen
                && failureRequestCount == 3,
            @"three failures should open the circuit without a fourth request");
        Assert(serverFailureResult.errorDomain != nil
                && serverFailureResult.errorMessage.length > 0,
            @"failure should include safe error diagnostics");

        // Invalid credentials should be cooled down immediately instead of
        // sending the same request on every polling tick.
        __block NSUInteger unauthorizedRequestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            unauthorizedRequestCount++;
            respond(401, @{});
        };
        CPARemoteCompletionClient *unauthorizedClient = Client();
        CPARemoteCompletionResult *unauthorizedResult = WaitForResult(
            unauthorizedClient, @"auth-cooldown", @"manual-chat", NO);
        CPARemoteCompletionResult *cooledDownResult = WaitForResult(
            unauthorizedClient, @"auth-cooldown", @"manual-chat", NO);
        Assert(unauthorizedResult.outcome == CPARemoteCompletionOutcomeUnauthorized
                && cooledDownResult.outcome == CPARemoteCompletionOutcomeCircuitOpen
                && unauthorizedRequestCount == 1,
            @"401 should open an immediate cooldown without a retry storm");

        // Identical polling observations should share one in-flight request;
        // a changed input remains eligible for a new request.
        __block NSUInteger duplicateRequestCount = 0;
        CPAStubURLProtocol.handler = ^(NSURLRequest *request,
            void (^respond)(NSInteger, NSDictionary *)) {
            (void)request;
            duplicateRequestCount++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                respond(200, @{
                    @"choices": @[@{ @"message": @{ @"content":
                        @" shared in-flight continuation with enough detail" } }],
                });
            });
        };
        CPARemoteCompletionClient *duplicateClient = Client();
        __block CPARemoteCompletionResult *duplicateResult = nil;
        CPARemoteCompletionTask *firstDuplicateTask =
            [duplicateClient requestCompletionForInput:@"same-in-flight-prefix"
                apiKey:@"test-key-not-a-real-secret" preferredModel:@"manual-chat"
                completion:^(CPARemoteCompletionResult *value) {
                    duplicateResult = value;
                }];
        CPARemoteCompletionTask *secondDuplicateTask =
            [duplicateClient requestCompletionForInput:@"same-in-flight-prefix"
                apiKey:@"test-key-not-a-real-secret" preferredModel:@"manual-chat"
                completion:^(CPARemoteCompletionResult *value) {
                    (void)value;
                }];
        Assert(firstDuplicateTask == secondDuplicateTask
                && duplicateRequestCount <= 1,
            @"identical active requests should be coalesced before transport starts");
        NSDate *duplicateDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (duplicateResult == nil && [duplicateDeadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Assert(duplicateResult != nil && duplicateRequestCount == 1,
            @"coalesced request should produce one eventual network completion");

        // A transport failure is distinct from HTTP authentication/rate-limit
        // failures and remains observable to the caller.
        CPAStubURLProtocol.handler = nil;
        result = WaitForResult(Client(), @"network-failure", @"manual-chat", NO);
        Assert(result.outcome == CPARemoteCompletionOutcomeTransportError,
            @"a connection failure should be classified as transport error");

        // This intentionally overlaps cancellation with a valid request. Run it
        // after zero-HTTP assertions so its allowed request cannot pollute them.
        CPAStubURLProtocol.handler = ^(NSURLRequest *request, void (^respond)(NSInteger, NSDictionary *)) {
            (void)request; (void)respond; // Keep a provider request pending.
        };
        {
            CPARemoteCompletionClient *switchClient = Client();
            CPARemoteCompletionHandler ignore = ^(CPARemoteCompletionResult *r) { (void)r; };
            CPARemoteCompletionTask *generating = [switchClient requestCompletionForInput:@"请继续完善核查要求，"
                contextMessages:@[] apiKey:@"test-key-not-a-real-secret" preferredModel:@"fixture-remote" progress:nil completion:ignore];
            switchClient.literalContinuationsOnly = YES;
            __block CPARemoteCompletionResult *literalResult = nil;
            CPARemoteCompletionTask *literal = [switchClient requestCompletionForInput:@"请继续完善核查要求，"
                contextMessages:@[] apiKey:@"test-key-not-a-real-secret" preferredModel:@"fixture-remote" progress:nil completion:^(CPARemoteCompletionResult *r) { literalResult = r; }];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
            while (!literalResult && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            Assert(literal != generating && [literalResult.phase isEqual:@"no_suggestion_literal_only"]
                && [literalResult.generationSource isEqual:@"not_requested"],
                @"a literal request must not coalesce with an in-flight model request");
            [[switchClient valueForKey:@"session"] invalidateAndCancel];
        }
        for (NSNumber *document in @[@NO, @YES]) {
            CPARemoteCompletionClient *stageSwitch = Client();
            stageSwitch.documentContinuation = document.boolValue;
            CPARemoteCompletionHandler ignore = ^(CPARemoteCompletionResult *r) { (void)r; };
            CPARemoteCompletionTask *ordinary = [stageSwitch requestCompletionForInput:@"请核对字段映射。"
                contextMessages:@[] apiKey:@"synthetic-key" preferredModel:@"fixture-remote" progress:nil completion:ignore];
            stageSwitch.continuationAfterAcceptance = YES;
            CPARemoteCompletionTask *accepted = [stageSwitch requestCompletionForInput:@"请核对字段映射。"
                contextMessages:@[] apiKey:@"synthetic-key" preferredModel:@"fixture-remote" progress:nil completion:ignore];
            CPARemoteCompletionTask *sameAccepted = [stageSwitch requestCompletionForInput:@"请核对字段映射。"
                contextMessages:@[] apiKey:@"synthetic-key" preferredModel:@"fixture-remote" progress:nil completion:ignore];
            Assert(accepted != ordinary && sameAccepted == accepted,
                @"in-flight coalescing must distinguish ordinary and accepted stages, but reuse identical accepted requests");
            [accepted cancel];
            [[stageSwitch valueForKey:@"session"] invalidateAndCancel];
        }
        {
            CPARemoteCompletionClient *coalescingClient = Client();
            CPARemoteCompletionHandler ignore = ^(CPARemoteCompletionResult *r) { (void)r; };
            CPARemoteCompletionTask *valid = [coalescingClient requestCompletionForInput:@"整理内容"
                contextMessages:@[] apiKey:@"test-key-not-a-real-secret" preferredModel:@"fixture-remote" progress:nil completion:ignore];
            CPARemoteCompletionTask *invalid = [coalescingClient requestCompletionForInput:@"整理内容"
                contextMessages:(id)@[NSNull.null] apiKey:@"test-key-not-a-real-secret" preferredModel:@"fixture-remote" progress:nil completion:ignore];
            Assert(invalid != valid, @"malformed context cannot coalesce with a valid empty-context in-flight request");
            [invalid cancel];
        }
        NSLog(@"PASS: RemoteCompletionClientTests");
    }
    return 0;
}
