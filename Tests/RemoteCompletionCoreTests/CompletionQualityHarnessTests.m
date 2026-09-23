#import "../../Tools/CompletionQualityBenchmark/BenchmarkSupport.h"
#import "../../Tools/CompletionQualityBenchmark/AuditSupport.h"
static NSUInteger failures;
static NSString *responseText;
static BOOL hang;
static NSData *lastBody;
static void Check(BOOL value, NSString *message) {
    if (!value) { failures++; NSLog(@"FAIL %@",message); }
}
@interface CPAHarnessStub : NSURLProtocol
@end
@implementation CPAHarnessStub
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { (void)request; return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    lastBody = self.request.HTTPBody;
    if (!lastBody && self.request.HTTPBodyStream) {
        NSInputStream *stream = self.request.HTTPBodyStream;
        [stream open]; NSMutableData *body = [NSMutableData data];
        uint8_t buffer[4096]; NSInteger count;
        while ((count=[stream read:buffer maxLength:sizeof(buffer)])>0) [body appendBytes:buffer length:(NSUInteger)count];
        [stream close]; lastBody=body;
    }
    if (hang) return;
    [self.client URLProtocol:self didReceiveResponse:[[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil]
        cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[responseText dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
int main(void) { @autoreleasepool {
    NSDictionary *user = @{@"role":@"user", @"content":@"关闭定时器后计数仍持续增长，原因尚未确定。"};
    NSDictionary *claim = @{@"role":@"assistant", @"content":@"原因是旧回调没有移除。"};
    NSArray *tail = @[user, claim];
    Check([CPABenchmarkUserTurnContext(tail, @"请帮我确认为什么") isEqual:@[user]],
        @"unreferenced trailing assistant explanation is excluded");
    for (NSString *draft in @[@"请核查你刚才提到的", @"按第二项继续完善", @"Please expand the second option"])
        Check([CPABenchmarkUserTurnContext(tail, draft) isEqual:tail], @"draft reference retains assistant tail");
    NSArray *chain = @[user, claim, @{@"role":@"user", @"content":@"好的"}];
    Check([CPABenchmarkUserTurnContext(chain, @"请先核对配置中的") isEqual:chain], @"ack preserves its entire preceding chain");
    NSArray *shortTail = @[user, @{@"role":@"user", @"content":@"好的"}, claim];
    Check([CPABenchmarkUserTurnContext(shortTail, @"请帮我确认为什么") isEqual:shortTail], @"short user message does not establish self-contained scope");
    NSArray *reference = @[claim, @{@"role":@"user", @"content":@"只做你提到的第二项。"}];
    Check([CPABenchmarkUserTurnContext(reference, @"我希望先了解如何") isEqual:reference], @"assistant options before user selection survive");
    Check([CPABenchmarkUserTurnContext(@[claim], @"我希望先了解如何") isEqual:@[claim]], @"missing user boundary preserves material");
    Check([CPABenchmarkUserTurnContext(@[], @"请继续补充") isEqual:@[]], @"empty stays empty");
    for (NSNumber *prefix in @[@YES, @NO]) {
        CPARemoteCompletionProtocol *p = [CPARemoteCompletionProtocol new];
        CPARemoteCompletionRequest *r = [p requestForInput:@"请帮我确认为什么"
            contextMessages:CPABenchmarkUserTurnContext(tail, @"请帮我确认为什么")
            model:prefix.boolValue ? @"mlx-community/Qwen3-4B-Instruct-2507-4bit" : @"synthetic-model"
            qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
        NSString *serialized = [[NSString alloc] initWithData:r.bodyData encoding:NSUTF8StringEncoding];
        Check([serialized containsString:user[@"content"]] && ![serialized containsString:claim[@"content"]],
            @"both adapters receive the selected user boundary without discarded assistant text");
    }
    NSDictionary *replay = @{@"id":@"replay",@"before_cursor":@"请核对记录 B 是否",
        @"raw":@"保留了原来的字段顺序。",@"finish_reason":@"stop"};
    Check([CPABenchmarkReplay(replay)[@"stage"] isEqual:@"candidate"],@"pure replay uses production final gates");
    NSMutableDictionary *cutReplay = [replay mutableCopy]; cutReplay[@"finish_reason"]=@"length";
    Check([CPABenchmarkReplay(cutReplay)[@"stage"] isEqual:@"quality_rejection"],@"replay preserves resource truncation rejection");
    cutReplay[@"raw"]=NSNull.null;
    Check([CPABenchmarkReplay(cutReplay)[@"stage"] isEqual:@"not_observed"],@"missing output is not a successful abstention");
    NSDictionary *fixture = @{@"id":@"synthetic",@"family_id":@"synthetic",@"before_cursor":@"请核对记录 B 是否",
        @"after_cursor":@"",@"selection":@0,@"context":@{@"messages":@[]},
        @"expected":@"SECRET_GOLD_NEVER_SEND",@"capability":@"end_of_text"};
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.protocolClasses = @[CPAHarnessStub.class];
    NSDictionary *(^run)(void) = ^{ return CPABenchmarkAttempt(fixture,[NSURL URLWithString:@"https://synthetic.invalid/v1"],
        @"synthetic-key",@"synthetic-model",NO,nil,nil,config,0.15); };
    hang = YES;
    NSDictionary *row = run();
    Check([row[@"stage"] isEqual:@"system_failure"] && [row[@"outcome"] isEqual:@"harness_deadline"],@"timeout is a failure");
    Check(row[@"first_segment_ms"] == NSNull.null,@"timeout does not invent first-token time");
    hang = NO;
    responseText = @"{\"choices\":[{\"message\":{\"content\":\"包含状态字段。\"},\"finish_reason\":\"stop\"}]}";
    row = run();
    Check([row[@"display_candidate"] isEqual:@"包含状态字段。"],@"case after timeout still completes");
    Check([row[@"raw"] isEqual:@"包含状态字段。"] && row[@"first_segment_ms"] == NSNull.null,@"raw preserved, no fabricated segment timing");
    responseText = @"{\"choices\":[{\"message\":{\"content\":\"我可以帮助你解决问题。\"},\"finish_reason\":\"stop\"}]}";
    row = run();
    Check([row[@"stage"] isEqual:@"quality_rejection"] && [row[@"raw"] length] && row[@"display_candidate"] == NSNull.null,@"rejected raw is not model abstention");
    responseText = @"{\"choices\":[{\"message\":{\"content\":\"\"},\"finish_reason\":\"stop\"}]}";
    Check([run()[@"stage"] isEqual:@"model_abstention"],@"observed empty is abstention");
    responseText = @"{malformed";
    Check([run()[@"stage"] isEqual:@"system_failure"],@"parse failure is not a correct stop");
    responseText = @"data: {\"choices\":[{\"delta\":{\"content\":\"未闭合内容\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n";
    row = run();
    Check([row[@"raw"] isEqual:@"未闭合内容"] && [row[@"stage"] isEqual:@"resource_truncation"],@"truncated stream keeps raw and separate result");
    for (NSNumber *prefix in @[@NO,@YES]) {
        CPABenchmarkProtocol *p = [CPABenchmarkProtocol new];
        NSString *model = prefix.boolValue ? @"mlx-community/Qwen3-4B-Instruct-2507-4bit" : @"synthetic-model";
        NSArray *context = @[@{@"role":@"user",@"content":@"只核查状态字段。"}];
        CPARemoteCompletionRequest *a = [p requestForInput:fixture[@"before_cursor"] contextMessages:context model:model qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
        p.experimentalSystem = @"G1 synthetic contract";
        CPARemoteCompletionRequest *b = [p requestForInput:fixture[@"before_cursor"] contextMessages:context model:model qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
        NSMutableDictionary *ab = [NSJSONSerialization JSONObjectWithData:a.bodyData options:NSJSONReadingMutableContainers error:nil];
        NSMutableDictionary *bb = [NSJSONSerialization JSONObjectWithData:b.bodyData options:NSJSONReadingMutableContainers error:nil];
        NSString *bodyText = [[NSString alloc] initWithData:b.bodyData encoding:NSUTF8StringEncoding];
        Check(![bodyText containsString:@"draft_focus"] && [bodyText containsString:@"只核查状态字段。"],@"remove heuristic labels, retain context");
        Check(![bodyText containsString:@"SECRET_GOLD_NEVER_SEND"],@"no gold labels in model payload");
        if (prefix.boolValue) {
            NSString *ap = ab[@"prompt"], *bp = bb[@"prompt"];
            Check([[ap substringFromIndex:[ap rangeOfString:@"<|im_end|>"].location]
                isEqual:[bp substringFromIndex:[bp rangeOfString:@"<|im_end|>"].location]],@"prefill and examples unchanged");
            [ab removeObjectForKey:@"prompt"]; [bb removeObjectForKey:@"prompt"];
        } else { [ab[@"messages"] removeObjectAtIndex:0]; [bb[@"messages"] removeObjectAtIndex:0]; }
        Check([ab isEqual:bb] && [a.sentInput isEqual:b.sentInput],@"only system template changes, budget/model/draft fixed");
        p.experimentalSystem = nil;
        p.experimentalSuffix = @"SYNTHETIC_INTENT_GUARD";
        CPARemoteCompletionRequest *suffixRequest = [p requestForInput:fixture[@"before_cursor"] contextMessages:context model:model qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
        NSDictionary *originalBody = [NSJSONSerialization JSONObjectWithData:a.bodyData options:0 error:nil];
        NSMutableDictionary *suffixBody = [NSJSONSerialization JSONObjectWithData:suffixRequest.bodyData options:NSJSONReadingMutableContainers error:nil];
        if (prefix.boolValue) {
            suffixBody[@"prompt"] = [suffixBody[@"prompt"] stringByReplacingOccurrencesOfString:@"\nSYNTHETIC_INTENT_GUARD" withString:@""];
        } else {
            suffixBody[@"messages"][0][@"content"] = [suffixBody[@"messages"][0][@"content"] stringByReplacingOccurrencesOfString:@"\nSYNTHETIC_INTENT_GUARD" withString:@""];
        }
        Check([originalBody isEqual:suffixBody],@"intent experiment only appends system suffix; exact payload otherwise preserved");
        p.experimentalSuffix = nil;
        p.removesDraftFocus = YES;
        CPARemoteCompletionRequest *noFocus = [p requestForInput:fixture[@"before_cursor"] contextMessages:context model:model qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
        NSDictionary *noFocusBody = [NSJSONSerialization JSONObjectWithData:noFocus.bodyData options:0 error:nil];
        NSMutableDictionary *expectedBody = [NSJSONSerialization JSONObjectWithData:a.bodyData options:NSJSONReadingMutableContainers error:nil];
        NSMutableString *expectedPrompt = [(prefix.boolValue ? expectedBody[@"prompt"] : expectedBody[@"messages"][0][@"content"]) mutableCopy];
        NSRange fs = [expectedPrompt rangeOfString:@"\n<draft_focus untrusted_reference=\"true\">"];
        NSRange fe = [expectedPrompt rangeOfString:@"</draft_focus>"];
        Check(fs.location != NSNotFound && fe.location > fs.location,@"baseline includes focus block");
        if (fs.location != NSNotFound && fe.location > fs.location)
            [expectedPrompt deleteCharactersInRange:NSMakeRange(fs.location,NSMaxRange(fe)-fs.location)];
        if (prefix.boolValue) expectedBody[@"prompt"]=expectedPrompt;
        else expectedBody[@"messages"][0][@"content"]=expectedPrompt;
        Check([expectedBody isEqual:noFocusBody],@"focus ablation preserves all other request content and parameters");
        p.removesDraftFocus = NO;
        p.narrowsRepetitionRule = YES;
        CPARemoteCompletionRequest *narrow = [p requestForInput:fixture[@"before_cursor"] contextMessages:context model:model qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
        NSMutableDictionary *narrowBody = [NSJSONSerialization JSONObjectWithData:narrow.bodyData options:NSJSONReadingMutableContainers error:nil];
        NSString *narrowText = prefix.boolValue ? narrowBody[@"prompt"] : narrowBody[@"messages"][0][@"content"];
        NSString *baselineText = prefix.boolValue ? originalBody[@"prompt"] : originalBody[@"messages"][0][@"content"];
        if ([baselineText containsString:@"Do not restate existing phrases, conclusions or restrictions."])
            Check([narrowText containsString:@"You may reuse objects"],@"legacy narrow repetition experiment is active");
        else
            Check([baselineText containsString:@"不复述当前草稿"] && [baselineText isEqual:narrowText],
                @"author contract already limits repetition to current draft; legacy ablation is a no-op");
        narrowText = [narrowText stringByReplacingOccurrencesOfString:@"Do not repeat text already present in the current draft. You may reuse objects, observed phenomena and scope explicitly stated by the user in conversation history when needed to complete the draft." withString:@"Do not restate existing phrases, conclusions or restrictions."];
        if (prefix.boolValue) narrowBody[@"prompt"]=narrowText;
        else narrowBody[@"messages"][0][@"content"]=narrowText;
        Check([originalBody isEqual:narrowBody],@"only repetition rule changes");
        p.narrowsRepetitionRule = NO;
        for (NSString *availability in @[@"missing",@"ready_empty",@"error",@"ambiguous",@"loading",@"ready"]) {
            p.contextState = @{@"availability":availability,@"truncated":@YES,@"window_limited":@YES};
            CPARemoteCompletionRequest *c = [p requestForInput:fixture[@"before_cursor"] contextMessages:context model:model qualityRetry:NO useLocalPrefix:prefix.boolValue error:nil];
            NSDictionary *cb = [NSJSONSerialization JSONObjectWithData:c.bodyData options:0 error:nil];
            NSDictionary *original = [NSJSONSerialization JSONObjectWithData:a.bodyData options:0 error:nil];
            NSString *cs = prefix.boolValue ? cb[@"prompt"] : cb[@"messages"][0][@"content"];
            NSString *as = prefix.boolValue ? original[@"prompt"] : original[@"messages"][0][@"content"];
            NSRange start = [cs rangeOfString:@"<context_state>"];
            NSRange end = [cs rangeOfString:@"</context_state>"];
            Check(start.location != NSNotFound && end.location > start.location,@"state has a separate serialized boundary");
            if (start.location != NSNotFound && end.location > start.location) {
                NSString *json = [cs substringWithRange:NSMakeRange(NSMaxRange(start),end.location-NSMaxRange(start))];
                Check([[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] isEqual:p.contextState],@"exact state/truncation preserved");
            }
            NSString *originalSystem = prefix.boolValue ? [as substringToIndex:[as rangeOfString:@"<|im_end|>"].location] : as;
            Check([cs hasPrefix:originalSystem],@"state experiment preserves baseline system including draft_focus");
            if (prefix.boolValue) {
                Check([[as substringFromIndex:[as rangeOfString:@"<|im_end|>"].location] isEqual:
                    [cs substringFromIndex:[cs rangeOfString:@"<|im_end|>"].location]],@"state does not change local examples or prefill");
            } else Check([cb[@"messages"][1] isEqual:original[@"messages"][1]],@"state does not change chat draft");
            for (NSString *field in @[@"model",@"temperature",@"max_tokens",@"stop",@"stream"])
                Check(cb[field] == original[field] || [cb[field] isEqual:original[field]],@"state does not change generation budgets");
        }
    }
    NSLog(@"CompletionQualityHarnessTests failures=%lu",(unsigned long)failures);
    Check(CPABenchmarkParseAudit(@"{\"decision\":\"allow\",\"reason\":\"ok\"}") != nil,@"valid allow");
    Check(CPABenchmarkParseAudit(@"{\"decision\":\"reject\",\"reason\":\"unsupported\"}") != nil,@"valid reject");
    for (NSString *bad in @[@"```json\n{\"decision\":\"allow\",\"reason\":\"ok\"}\n```",
        @"{\"decision\":\"allow\",\"reason\":\"unsupported\"}",
        @"{\"decision\":\"reject\",\"reason\":\"ok\"}",
        @"{\"decision\":\"reject\",\"decision\":\"allow\",\"reason\":\"ok\"}",
        @"{\"decision\":\"reject\",\"deci\\u0073ion\":\"allow\",\"reason\":\"ok\"}",
        @"{\"decision\":\"allow\",\"reason\":\"ok\",\"replacement\":\"new\"}",
        @"{\"decision\":\"allow\",\"reason\":null}", @"[]", @"allow", @"{\"decision\":\"reject\",\"reason\":\"other\"}"])
        Check(CPABenchmarkParseAudit(bad)==nil,@"malformed/duplicate/rewrite responses fail closed");
    NSMutableDictionary *auditFixture = [fixture mutableCopy];
    auditFixture[@"context"] = @{@"messages":@[],@"availability":@"missing",@"truncated":@NO};
    auditFixture[@"candidate"] = @"包含状态字段。";
    NSDictionary *(^audit)(double) = ^(double deadline) { return CPABenchmarkAuditAttempt(auditFixture,
        [NSURL URLWithString:@"https://synthetic.invalid/v1"],@"synthetic-key",@"synthetic-model",config,deadline,@"audit-v1"); };
    NSDictionary *expiredAudit = audit(0);
    Check([expiredAudit[@"outcome"] isEqual:@"deadline_before_audit"] && [expiredAudit[@"request_count"] unsignedIntegerValue]==0,@"expired shared budget never requests review");
    hang = YES;
    Check([audit(.1)[@"stage"] isEqual:@"system_failure"],@"review timeout is failure, not reject");
    hang = NO;
    responseText = @"{\"choices\":[{\"message\":{\"content\":\"{\\\"decision\\\":\\\"allow\\\",\\\"reason\\\":\\\"ok\\\"}\"},\"finish_reason\":\"stop\"}]}";
    Check([audit(.5)[@"decision"] isEqual:@"allow"],@"next review succeeds after timeout");
    NSDictionary *auditBody = [NSJSONSerialization JSONObjectWithData:lastBody options:0 error:nil];
    NSArray *auditMessages = auditBody[@"messages"];
    NSDictionary *sent = [NSJSONSerialization JSONObjectWithData:[auditMessages[1][@"content"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    Check([sent[@"candidate"] isEqual:auditFixture[@"candidate"]] && [sent[@"before_cursor"] isEqual:auditFixture[@"before_cursor"]],@"audit exact candidate and original draft");
    Check(sent.count==4 && sent[@"expected"]==nil && sent[@"audit_expected"]==nil,@"gold and review labels excluded from audit inputs");
    Check(![[[NSString alloc] initWithData:lastBody encoding:NSUTF8StringEncoding] containsString:@"SECRET_GOLD_NEVER_SEND"],@"gold marker never leaves the harness");
    auditFixture[@"expected_audit"] = @"SECRET_GOLD_NEVER_SEND";
    NSDictionary *v3 = CPABenchmarkAuditAttempt(auditFixture,[NSURL URLWithString:@"https://synthetic.invalid/v1"],
        @"synthetic-key",@"synthetic-model",config,.5,@"audit-v3");
    Check([v3[@"decision"] isEqual:@"allow"],@"v3 audit uses the same closed response parser");
    NSString *v3Body = [[NSString alloc] initWithData:lastBody encoding:NSUTF8StringEncoding];
    Check([v3Body containsString:@"并列行为和范围"] && ![v3Body containsString:@"SECRET_GOLD_NEVER_SEND"],@"v3 template selected without leaking gold labels");
    responseText = [responseText stringByReplacingOccurrencesOfString:@"\"stop\"" withString:@"\"length\""];
    Check([audit(.5)[@"stage"] isEqual:@"system_failure"],@"truncated allow is never accepted");
    NSLog(@"Audit and harness failures=%lu",(unsigned long)failures);
    return failures ? 1 : 0;
} }
