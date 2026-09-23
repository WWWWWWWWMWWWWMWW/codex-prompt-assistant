#import "AuditSupport.h"
#import "../../Sources/RemoteCompletionCore/RemoteCompletionClient.h"

NSDictionary *CPABenchmarkParseAudit(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return nil;
    // This closed schema needs no escapes. Reject them before Foundation can
    // collapse an escaped duplicate key onto a literal key.
    if ([text containsString:@"\\"]) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
        options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class] || json.count != 2) return nil;
    if (![json[@"decision"] isKindOfClass:NSString.class] || ![json[@"reason"] isKindOfClass:NSString.class]) return nil;
    // NSJSONSerialization accepts duplicate keys. Require one literal occurrence
    // of each key; escaped or duplicate keys fail closed rather than overriding.
    for (NSString *key in @[@"decision",@"reason"]) {
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:
            [NSString stringWithFormat:@"\"%@\"\\s*:",key] options:0 error:nil];
        if ([pattern numberOfMatchesInString:text options:0 range:NSMakeRange(0,text.length)] != 1) return nil;
    }
    if ([json[@"decision"] isEqual:@"allow"] && [json[@"reason"] isEqual:@"ok"]) return json;
    if ([json[@"decision"] isEqual:@"reject"] && [@[@"no_gap",@"scope",@"unsupported",@"repeat",@"role",@"structure",@"ambiguous"] containsObject:json[@"reason"]]) return json;
    return nil;
}

NSDictionary *CPABenchmarkAuditAttempt(NSDictionary *fixture, NSURL *url, NSString *key,
    NSString *model, NSURLSessionConfiguration *configuration, NSTimeInterval deadline, NSString *version) {
    NSMutableDictionary *row = [@{@"id":fixture[@"id"],@"family_id":fixture[@"family_id"],
        @"model":model,@"adapter":@"chat-audit",@"audit_version":version,
        @"decision":NSNull.null,@"reason":NSNull.null,@"raw":NSNull.null,
        @"audit_ms":@0,@"request_count":@0,@"stage":@"system_failure"} mutableCopy];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    if (deadline <= 0) { row[@"outcome"] = @"deadline_before_audit"; return row; }
    if (!CPARemoteCompletionBaseURLIsAllowed(url) || !key.length || !model.length) {
        row[@"outcome"] = @"configuration"; return row;
    }
    if (![@[@"audit-v1",@"audit-v2",@"audit-v3"] containsObject:version]) { row[@"outcome"] = @"invalid_version"; return row; }
    NSString *rules = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"Tools/CompletionQualityBenchmark/%@.txt",version]
        encoding:NSUTF8StringEncoding error:nil];
    if (!rules.length) { row[@"outcome"] = @"missing_template"; return row; }
    NSMutableArray *messages = [NSMutableArray array];
    for (NSDictionary *item in fixture[@"context"][@"messages"]) {
        [messages addObject:@{@"role":item[@"role"],@"content":item[@"content"]}];
    }
    NSDictionary *input = @{@"before_cursor":fixture[@"before_cursor"],
        @"after_cursor":fixture[@"after_cursor"] ?: @"",@"candidate":fixture[@"candidate"],
        @"context":@{@"availability":fixture[@"context"][@"availability"],
            @"truncated":fixture[@"context"][@"truncated"],@"window_limited":@YES,@"messages":messages}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:input options:NSJSONWritingSortedKeys error:nil];
    NSMutableDictionary *body = [@{@"model":model,@"stream":@NO,
        @"messages":@[@{@"role":@"system",@"content":rules},
            @{@"role":@"user",@"content":[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]}]} mutableCopy];
    BOOL local = [@[@"127.0.0.1",@"localhost",@"::1",@"[::1]"] containsObject:url.host];
    if (local) { body[@"temperature"] = @0; body[@"max_tokens"] = @96; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[url URLByAppendingPathComponent:@"chat/completions"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    NSURLSessionConfiguration *config = [configuration copy];
    config.timeoutIntervalForRequest = MIN(local ? 10.0 : 5.0, deadline);
    config.timeoutIntervalForResource = deadline; config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __block NSData *responseData;
    __block NSHTTPURLResponse *response;
    __block NSError *failure;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:
        ^(NSData *value, NSURLResponse *info, NSError *error) {
            responseData = value; response = (NSHTTPURLResponse *)info; failure = error;
            dispatch_semaphore_signal(done);
        }];
    [task resume]; row[@"request_count"] = @1;
    BOOL timeout = dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(deadline*NSEC_PER_SEC))) != 0;
    row[@"audit_ms"] = @((NSProcessInfo.processInfo.systemUptime-start)*1000);
    if (timeout) { [task cancel]; row[@"outcome"] = @"harness_deadline"; }
    else if (failure || response.statusCode != 200) {
        row[@"outcome"] = @"transport_or_http";
        row[@"error_code"] = @(failure.code); row[@"status_code"] = @(response.statusCode);
    } else {
        id outer = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
        id choices = [outer isKindOfClass:NSDictionary.class] ? outer[@"choices"] : nil;
        id first = [choices isKindOfClass:NSArray.class] && [choices count] ? choices[0] : nil;
        id message = [first isKindOfClass:NSDictionary.class] ? first[@"message"] : nil;
        NSString *raw = [message isKindOfClass:NSDictionary.class] && [message[@"content"] isKindOfClass:NSString.class] ? message[@"content"] : nil;
        row[@"raw"] = raw ?: (id)NSNull.null;
        NSDictionary *decision = CPABenchmarkParseAudit(raw);
        BOOL truncated = [first isKindOfClass:NSDictionary.class] && [first[@"finish_reason"] isEqual:@"length"];
        if (decision && !truncated) { [row addEntriesFromDictionary:decision]; row[@"stage"] = @"audit_decision"; row[@"outcome"] = @"success"; }
        else row[@"outcome"] = truncated ? @"resource_truncation" : @"invalid_response";
    }
    [session invalidateAndCancel];
    return row;
}
