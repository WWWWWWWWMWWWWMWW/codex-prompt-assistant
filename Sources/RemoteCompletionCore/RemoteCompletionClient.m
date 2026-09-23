#import "RemoteCompletionClient.h"

#import "RemoteCompletionProtocol.h"

#import <CommonCrypto/CommonDigest.h>

static const NSUInteger CPARemoteCompletionFailureThreshold = 3;
static const NSTimeInterval CPARemoteCompletionCircuitDuration = 15.0;
// Authentication failures are deterministic and should not cause a request
// storm while the user is still configuring the key. Rate limits are shorter
// lived, while server/transport failures retain the three-strike circuit.
static const NSTimeInterval CPARemoteCompletionUnauthorizedCooldown = 60.0;
static const NSTimeInterval CPARemoteCompletionRateLimitCooldown = 5.0;
static const NSUInteger CPARemoteCompletionCacheCapacity = 8;
static const NSTimeInterval CPARemoteCompletionCacheLifetime = 15.0;
static const NSUInteger CPARemoteCompletionMinimumCacheInputCharacterCount = 8;
// Cache and preview thresholds remain conservative. Final acceptance uses
// the protocol contract, which also permits a short completed sentence suffix.
static const NSUInteger CPARemoteCompletionMinimumSuggestionCharacterCount = 10;
// The local model is allowed to publish a conservative, non-final preview
// once enough text exists to be useful. Final acceptance uses the protocol
// contract; cache writes retain the ordinary fragment threshold.
static const NSUInteger CPARemoteCompletionMinimumPreviewCharacterCount = 8;

static BOOL CPARemoteCompletionUsesSmallLocalModel(NSString *model) {
    NSString *normalized = model.lowercaseString;
    return [normalized containsString:@"qwen3-1.7b"]
        || [normalized containsString:@"qwen3-4b-instruct-2507"];
}

// Only generic request scaffolding followed by an unfinished question word.
// Concrete nouns or a preceding clause fall outside this narrow gate.
static BOOL CPAObjectlessQuestionStem(NSString *input) {
    return [input rangeOfString:@"^(?:(?:请|麻烦|帮我|帮忙|我|我们|想|希望|需要|先|再|进一步|确认|了解|知道|解释|分析|核实|看看|弄清楚|一下))*(?:为什么|为何|怎么|如何|怎样)$"
        options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL CPAHasUserReference(NSArray *messages) {
    NSCharacterSet *edges = [NSCharacterSet characterSetWithCharactersInString:@" ，,。.!！?？\n\t"];
    for (NSDictionary *message in messages) {
        if (![message[@"role"] isEqual:@"user"] || ![message[@"content"] isKindOfClass:NSString.class]) continue;
        NSString *text = [message[@"content"] stringByTrimmingCharactersInSet:edges];
        if (text.length == 0 || CPAObjectlessQuestionStem(text)
            || [@[@"好", @"好的", @"可以", @"嗯", @"收到", @"谢谢", @"OK", @"ok", @"继续", @"继续吧"] containsObject:text]) continue;
        return YES;
    }
    return NO;
}

static BOOL CPALocalCompletionInputIsLowValue(NSString *input) {
    NSString *trimmed = [input stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || trimmed.length > 8) {
        return NO;
    }
    // Do not classify every short Chinese phrase as a test word: useful
    // prompts such as "继续" and "你好" are common real drafts. The gate is
    // limited to explicit test vocabulary or short ASCII probes.
    NSString *lowercase = trimmed.lowercaseString;
    NSArray<NSString *> *knownTestWords = @[
        @"ceshi", @"test", @"测试", @"测试一下", @"彩色", @"菜色",
    ];
    for (NSString *word in knownTestWords) {
        if ([lowercase isEqualToString:word]) {
            return YES;
        }
    }
    BOOL isASCII = [trimmed canBeConvertedToEncoding:NSASCIIStringEncoding];
    if (!isASCII || [trimmed rangeOfCharacterFromSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
        return NO;
    }
    NSCharacterSet *nonWord = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [trimmed rangeOfCharacterFromSet:nonWord].location == NSNotFound;
}

static BOOL CPALocalCompletionOutputIsLowValue(NSString *output) {
    NSString *trimmed = [output stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length < CPARemoteCompletionMinimumSuggestionCharacterCount) {
        return YES;
    }
    NSString *lowercase = trimmed.lowercaseString;
    NSArray<NSString *> *genericMarkers = @[
        @"具体情况", @"进一步提升", @"整体体验", @"通常情况下",
        @"as needed", @"for better results", @"in general",
    ];
    NSUInteger markerCount = 0;
    for (NSString *marker in genericMarkers) {
        if ([lowercase containsString:marker.lowercaseString]) {
            markerCount++;
        }
    }
    // Two or more generic markers are a stock continuation rather than a
    // concrete suffix. One marker can still be valid when grounded in input.
    return markerCount >= 2;
}

static BOOL CPALocalCompletionPreviewIsSafe(NSString *output) {
    NSString *trimmed = [output stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length < CPARemoteCompletionMinimumPreviewCharacterCount
        || trimmed.length >= CPARemoteCompletionMinimumSuggestionCharacterCount) {
        return NO;
    }
    if ([trimmed rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location
            != NSNotFound) {
        return NO;
    }

    // A preview is only useful when it already looks like a continuation.
    // Reject answer/advice leads and Markdown-like fragments before they can
    // reach the UI; the unchanged final parser remains the quality authority.
    NSArray<NSString *> *answerLeads = @[
        @"这是因为", @"原因是", @"可以尝试", @"你可以", @"建议",
        @"具体来说", @"请分别", @"we can ", @"you can ",
        @"the reason", @"you should ",
    ];
    NSString *lowercase = trimmed.lowercaseString;
    for (NSString *lead in answerLeads) {
        if ([lowercase hasPrefix:lead.lowercaseString]) {
            return NO;
        }
    }
    NSArray<NSString *> *continuationLeads = @[
        @"，", @",", @"、", @"；", @";", @"：", @":", @" ",
        @"并", @"同时", @"以及", @"确保", @"其中", @"从而",
        @"and ", @"also ", @"while ", @"that ", @"so ",
    ];
    for (NSString *lead in continuationLeads) {
        if ([trimmed hasPrefix:lead]) {
            return YES;
        }
    }
    return NO;
}

BOOL CPARemoteCompletionBaseURLIsAllowed(NSURL *baseURL) {
    NSString *scheme = baseURL.scheme.lowercaseString;
    NSString *host = baseURL.host.lowercaseString;
    if ([scheme isEqualToString:@"https"] && host.length > 0) {
        return YES;
    }
    if (![scheme isEqualToString:@"http"]) {
        return NO;
    }
    return [host isEqualToString:@"127.0.0.1"]
        || [host isEqualToString:@"localhost"]
        || [host isEqualToString:@"::1"];
}

@interface CPARemoteCompletionResult ()
@property(nonatomic, readwrite) CPARemoteCompletionOutcome outcome;
@property(nonatomic, copy, readwrite, nullable) NSString *insertionText;
@property(nonatomic, readwrite) NSInteger statusCode;
@property(nonatomic, readwrite) NSUInteger durationMilliseconds;
@property(nonatomic, copy, readwrite) NSNumber *completionDispatchMilliseconds;
@property(nonatomic, copy, readwrite) NSNumber *firstDataMilliseconds;
@property(nonatomic, copy, readwrite) NSNumber *validationMilliseconds;
@property(nonatomic, copy, readwrite) NSDictionary *responseDiagnostics;
@property(nonatomic, readwrite) NSUInteger inputCharacterCount;
@property(nonatomic, readwrite) NSUInteger outputCharacterCount;
@property(nonatomic, readwrite) NSUInteger streamParseWorkUnits;
@property(nonatomic, readwrite) NSUInteger redactionCount;
@property(nonatomic, copy, readwrite) NSString *requestID;
@property(nonatomic, copy, readwrite) NSString *phase;
@property(nonatomic, copy, readwrite, nullable) NSString *model;
@property(nonatomic, copy, readwrite, nullable) NSString *errorDomain;
@property(nonatomic, readwrite) NSInteger errorCode;
@property(nonatomic, copy, readwrite, nullable) NSString *errorMessage;
@property(nonatomic, readwrite, getter=isCacheHit) BOOL cacheHit;
@end

@implementation CPARemoteCompletionResult
- (NSString *)generationSource {
    if ([self.phase isEqual:@"explicit_option"]) return @"literal_option";
    if ([self.phase isEqual:@"explicit_user_scope"]) return @"literal_user_scope";
    if (self.cacheHit) return @"cache";
    if ([@[@"validate", @"request_build", @"circuit", @"cancel", @"no_suggestion_boundary",
        @"no_suggestion_insufficient_context", @"no_suggestion_invalid_context", @"no_suggestion_literal_only"] containsObject:self.phase]) return @"not_requested";
    if ([self.phase isEqual:@"no_suggestion_local_low_value"] && self.statusCode == 0) return @"not_requested";
    if ([@[@"model_discovery", @"completion", @"completion_quality_retry", @"response_parse",
        @"response_too_large", @"no_suggestion", @"no_suggestion_rejected", @"no_suggestion_too_short",
        @"no_suggestion_local_low_value"] containsObject:self.phase]) return @"provider";
    return @"unknown";
}
@end

@interface CPARemoteCompletionTask ()
@property(nonatomic, copy) NSString *rightContext;
@property(nonatomic, copy, readwrite) NSString *requestID;
@property(nonatomic, copy) dispatch_block_t cancellationHandler;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *sessionTask;
@property(nonatomic, copy) CPARemoteCompletionHandler completion;
@property(nonatomic, copy, nullable) CPARemoteCompletionProgressHandler progress;
@property(nonatomic, strong) NSDate *startedAt;
@property(nonatomic, copy) NSNumber *completionDispatchMilliseconds;
@property(nonatomic, copy) NSNumber *firstDataMilliseconds;
@property(nonatomic, strong) NSDate *validationStartedAt;
@property(nonatomic, copy) NSDictionary *responseDiagnostics;
@property(nonatomic) NSUInteger inputCharacterCount;
@property(nonatomic) NSUInteger redactionCount;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, copy) NSString *model;
@property(nonatomic) BOOL cacheHit;
@property(nonatomic) NSUInteger cacheEpoch;
@property(nonatomic) BOOL literalContinuationsOnly;
@property(nonatomic) BOOL documentContinuation;
@property(nonatomic) BOOL continuationAfterAcceptance;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL resultDelivered;
@property(nonatomic) NSUInteger qualityRetryCount;
@property(nonatomic, copy, nullable) NSString *qualityFallbackInsertion;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *contextMessages;
@property(nonatomic, copy) NSString *contextFingerprint;
@property(nonatomic, strong, nullable) NSMutableData *streamBuffer;
@property(nonatomic, strong, nullable) NSMutableData *responseData;
@property(nonatomic, strong, nullable) NSMutableString *streamPreviewText;
@property(nonatomic, copy, nullable) NSString *streamSentInput;
@property(nonatomic, copy, nullable) NSString *requestInput;
@property(nonatomic, copy, nullable) NSString *requestAPIKey;
@property(nonatomic, copy) NSString *preferredModel;
@property(nonatomic) NSUInteger streamedOutputCharacterCount;
@property(nonatomic) NSUInteger streamParseWorkUnits;
@property(nonatomic, copy, nullable) NSString *pendingProgressText;
@property(nonatomic) BOOL progressDeliveryScheduled;
@property(nonatomic) CFTimeInterval lastProgressDeliveryTime;
@end

@implementation CPARemoteCompletionTask

- (void)cancel {
    dispatch_block_t handler = nil;
    @synchronized (self) {
        if (self.resultDelivered || self.cancelled) {
            return;
        }
        self.cancelled = YES;
        handler = self.finished ? nil : self.cancellationHandler;
    }
    [self.sessionTask cancel];
    if (handler != nil) {
        handler();
    }
}

@end

@interface CPARemoteCompletionCacheEntry : NSObject
@property(nonatomic, copy) NSString *inputText;
@property(nonatomic, copy) NSString *insertionText;
@property(nonatomic, strong) NSDate *createdAt;
@property(nonatomic) NSUInteger inputCharacterCount;
@property(nonatomic) NSUInteger outputCharacterCount;
@property(nonatomic) NSUInteger redactionCount;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, copy) NSString *contextFingerprint;
@end

@implementation CPARemoteCompletionCacheEntry
@end

@interface CPARemoteCompletionClient () <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURL *baseURL;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) CPARemoteCompletionProtocol *protocol;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@property(nonatomic, strong, nullable) CPARemoteCompletionTask *activeTask;
@property(nonatomic, copy, nullable) NSString *cachedModel;
@property(nonatomic) NSUInteger consecutiveFailureCount;
@property(nonatomic, strong, nullable) NSDate *circuitOpenUntil;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CPARemoteCompletionCacheEntry *> *completionCache;
@property(nonatomic) NSUInteger cacheEpoch;
- (void)enqueueProgress:(NSString *)partial
                 forTask:(CPARemoteCompletionTask *)task;
- (void)deliverPendingProgressForTask:(CPARemoteCompletionTask *)task;
@end

@implementation CPARemoteCompletionClient

- (instancetype)initWithBaseURL:(NSURL *)baseURL
    sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration
    callbackQueue:(dispatch_queue_t)callbackQueue {
    self = [super init];
    if (self != nil) {
        _baseURL = [baseURL URLByStandardizingPath];
        NSURLSessionConfiguration *configuration = [sessionConfiguration copy];
        // Document infill waits for final validation and may produce no visible
        // streaming fragment. The former remote 5s/6s limits cut off otherwise
        // valid generations. Allow bounded latency; edits still cancel the task.
        BOOL loopback = [@[@"127.0.0.1", @"localhost", @"::1", @"[::1]"]
            containsObject:_baseURL.host.lowercaseString ?: @""];
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = loopback ? 12.0 : 15.0;
        configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:configuration
            delegate:self delegateQueue:delegateQueue];
        _protocol = [[CPARemoteCompletionProtocol alloc] init];
        _callbackQueue = callbackQueue;
        _completionCache = [[NSMutableDictionary alloc] init];
        _progressMinimumCharacterCount =
            CPARemoteCompletionMinimumSuggestionCharacterCount;
        _progressMinimumCharacterDelta = 1;
    }
    return self;
}

- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    apiKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel
    completion:(CPARemoteCompletionHandler)completion {
    return [self requestCompletionForInput:input contextMessages:@[] apiKey:apiKey
        preferredModel:preferredModel progress:nil completion:completion];
}

- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    apiKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel
    completion:(CPARemoteCompletionHandler)completion {
    return [self requestCompletionForInput:input contextMessages:contextMessages
        apiKey:apiKey preferredModel:preferredModel progress:nil completion:completion];
}

- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    apiKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel
    progress:(CPARemoteCompletionProgressHandler)progress
    completion:(CPARemoteCompletionHandler)completion {
    return [self requestCompletionForInput:input rightContext:@"" contextMessages:contextMessages
        apiKey:apiKey preferredModel:preferredModel progress:progress completion:completion];
}

- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    rightContext:(NSString *)rightContext
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    apiKey:(NSString *)apiKey preferredModel:(NSString *)preferredModel
    progress:(CPARemoteCompletionProgressHandler)progress
    completion:(CPARemoteCompletionHandler)completion {
    rightContext = [rightContext copy] ?: @"";
    NSString *normalizedKey = [apiKey stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *normalizedModel = [preferredModel stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Array copy alone retains mutable dictionaries and strings. Freeze the
    // actual request material before computing the identity used by the cache.
    NSMutableArray *contextSnapshot = [NSMutableArray array];
    BOOL invalidContext = contextMessages != nil && ![contextMessages isKindOfClass:NSArray.class];
    for (id message in (invalidContext ? @[] : contextMessages)) {
        if (![message isKindOfClass:NSDictionary.class]
            || ![message[@"role"] isKindOfClass:NSString.class]
            || ![@[@"user", @"assistant"] containsObject:message[@"role"]]
            || ![message[@"content"] isKindOfClass:NSString.class]) {
            invalidContext = YES;
            [contextSnapshot removeAllObjects];
            break; // Never drop a broken latest message and expose an older instruction.
        }
        [contextSnapshot addObject:@{@"role":[message[@"role"] copy] ?: @"",
            @"content":[message[@"content"] copy] ?: @""}];
    }
    NSArray<NSDictionary<NSString *, NSString *> *> *normalizedContext = [contextSnapshot copy];
    NSArray *identityContext = rightContext.length ? [normalizedContext arrayByAddingObject:
        @{@"role":@"right_context",@"content":rightContext}] : normalizedContext;
    NSString *applicationBundleIdentifier = self.applicationBundleIdentifier ?: @"";
    if (applicationBundleIdentifier.length) identityContext = [identityContext arrayByAddingObject:
        @{@"role":@"application", @"content":applicationBundleIdentifier}];
    BOOL documentContinuation = self.documentContinuation;
    if (documentContinuation) identityContext = [identityContext arrayByAddingObject:
        @{@"role":@"completion_mode", @"content":@"document"}];
    BOOL continuationAfterAcceptance = self.continuationAfterAcceptance && rightContext.length == 0;
    if (continuationAfterAcceptance) identityContext = [identityContext arrayByAddingObject:
        @{@"role":@"completion_stage", @"content":@"after_acceptance"}];
    NSString *contextFingerprint = [self contextFingerprintForMessages:identityContext];
    BOOL literalOnly = self.literalContinuationsOnly;

    // The editor can report the same stable input on several consecutive
    // polling ticks. Reuse an identical in-flight request instead of
    // cancelling it and starting another network stream. This is deliberately
    // exact-match only: a changed prefix still needs a fresh request or cache
    // rebase, so unrelated text is never coalesced.
    CPARemoteCompletionTask *active = nil;
    @synchronized (self) {
        active = self.activeTask;
        if (!invalidContext && active != nil && active.literalContinuationsOnly == literalOnly
            && active.cacheEpoch == self.cacheEpoch && !active.cancelled && !active.finished
            && [active.requestInput isEqualToString:input]
            && [active.requestAPIKey isEqualToString:normalizedKey]
            && [active.preferredModel isEqualToString:normalizedModel]
            && [active.contextFingerprint isEqualToString:contextFingerprint]) {
            return active;
        }
    }
    [self cancelActiveRequest];
    CPARemoteCompletionTask *token = [[CPARemoteCompletionTask alloc] init];
    token.requestID = [self newRequestIdentifier];
    token.phase = @"validate";
    token.completion = [completion copy];
    token.progress = [progress copy];
    token.contextMessages = normalizedContext;
    token.rightContext = rightContext;
    token.contextFingerprint = contextFingerprint;
    token.requestInput = [input copy];
    token.requestAPIKey = normalizedKey;
    token.preferredModel = normalizedModel;
    token.literalContinuationsOnly = literalOnly;
    token.documentContinuation = documentContinuation;
    token.continuationAfterAcceptance = continuationAfterAcceptance;
    token.startedAt = [NSDate date];
    token.inputCharacterCount = input.length;
    __weak CPARemoteCompletionClient *weakSelf = self;
    __weak CPARemoteCompletionTask *weakToken = token;
    token.cancellationHandler = ^{
        [weakSelf finishToken:weakToken outcome:CPARemoteCompletionOutcomeCancelled
            insertion:nil statusCode:0 error:nil phase:weakToken.phase ?: @"cancel"];
    };
    @synchronized (self) {
        token.cacheEpoch = self.cacheEpoch;
        self.activeTask = token;
    }

    if (input.length == 0 || normalizedKey.length == 0
        || !CPARemoteCompletionBaseURLIsAllowed(self.baseURL)) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeNotConfigured
            insertion:nil statusCode:0 error:nil phase:@"validate"];
        return token;
    }
    if (invalidContext) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
            insertion:nil statusCode:0 error:nil phase:@"no_suggestion_invalid_context"];
        return token;
    }
    if (!CPACompletionCanContinueAtCursor(input, input.length)) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
            insertion:nil statusCode:0 error:nil phase:@"no_suggestion_boundary"];
        return token;
    }
    // The same insufficient-context rule applies to every provider, before
    // cache reuse or model discovery. A bare continue cue supplies no object.
    NSString *bareInput = [input stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@" ，,。.!！?？\n\t"]];
    if (CPAObjectlessQuestionStem(bareInput) && !CPAHasUserReference(token.contextMessages)) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
            insertion:nil statusCode:0 error:nil phase:@"no_suggestion_insufficient_context"];
        return token;
    }
    if (token.contextMessages.count == 0
        && [@[@"继续", @"继续吧", @"继续支持", @"继续支持吧"] containsObject:bareInput]) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
            insertion:nil statusCode:0 error:nil phase:@"no_suggestion_insufficient_context"];
        return token;
    }
    NSString *literalContinuation = CPAExplicitOptionContinuation(input, token.contextMessages);
    NSString *literalPhase = @"explicit_option";
    if (literalContinuation == nil) {
        literalContinuation = CPAExplicitUserScopeContinuation(input, token.contextMessages);
        literalPhase = @"explicit_user_scope";
    }
    if (!documentContinuation && rightContext.length == 0 && literalContinuation.length > 0) {
        NSString *validated = [self.protocol normalizedCompletion:literalContinuation sentInput:input contextMessages:token.contextMessages];
        if ([validated isEqual:literalContinuation]
            && [self.protocol completionMeetsMinimumLength:validated sentInput:input contextMessages:token.contextMessages]) {
            [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
                insertion:validated statusCode:0 error:nil phase:literalPhase];
            return token;
        }
    }
    // This decision precedes cache, discovery and HTTP. A previous model result
    // must never masquerade as a verified literal continuation in this mode.
    if (token.literalContinuationsOnly) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
            insertion:nil statusCode:0 error:nil phase:@"no_suggestion_literal_only"];
        return token;
    }
    if (self.circuitOpenUntil != nil
        && [self.circuitOpenUntil timeIntervalSinceNow] > 0) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeCircuitOpen
            insertion:nil statusCode:0 error:nil phase:@"circuit"];
        return token;
    }
    if (normalizedModel.length > 0) {
        token.model = normalizedModel;
        if (CPARemoteCompletionUsesSmallLocalModel(normalizedModel)
            && CPALocalCompletionInputIsLowValue(input)) {
            [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
                insertion:nil statusCode:0 error:nil
                phase:@"no_suggestion_local_low_value"];
            return token;
        }
        CPARemoteCompletionCacheEntry *cached = [self cachedEntryForInput:input
            model:normalizedModel contextFingerprint:token.contextFingerprint];
        if (cached != nil) {
            token.phase = @"cache";
            token.model = cached.model;
            token.cacheHit = YES;
            token.redactionCount = cached.redactionCount;
            [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
                insertion:cached.insertionText statusCode:200 error:nil phase:@"cache"];
            return token;
        }
            [self startCompletionForToken:token input:input apiKey:normalizedKey
                model:normalizedModel qualityRetry:NO];
    } else if (self.cachedModel.length > 0) {
        token.model = self.cachedModel;
        if (CPARemoteCompletionUsesSmallLocalModel(self.cachedModel)
            && CPALocalCompletionInputIsLowValue(input)) {
            [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
                insertion:nil statusCode:0 error:nil
                phase:@"no_suggestion_local_low_value"];
            return token;
        }
        CPARemoteCompletionCacheEntry *cached = [self cachedEntryForInput:input
            model:self.cachedModel contextFingerprint:token.contextFingerprint];
        if (cached != nil) {
            token.phase = @"cache";
            token.model = cached.model;
            token.cacheHit = YES;
            token.redactionCount = cached.redactionCount;
            [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
                insertion:cached.insertionText statusCode:200 error:nil phase:@"cache"];
            return token;
        }
        [self startCompletionForToken:token input:input apiKey:normalizedKey
            model:self.cachedModel qualityRetry:NO];
    } else {
        token.phase = @"model_discovery";
        [self startModelDiscoveryForToken:token input:input apiKey:normalizedKey];
    }
    return token;
}

- (void)cancelActiveRequest {
    CPARemoteCompletionTask *active = nil;
    @synchronized (self) {
        active = self.activeTask;
    }
    [active cancel];
}

- (void)invalidateCompletionCache {
    @synchronized (self) {
        self.cacheEpoch++;
        [self.completionCache removeAllObjects];
    }
}

- (void)startModelDiscoveryForToken:(CPARemoteCompletionTask *)token
    input:(NSString *)input apiKey:(NSString *)apiKey {
    token.phase = @"model_discovery";
    NSURL *url = [self.baseURL URLByAppendingPathComponent:@"models"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:[@"Bearer " stringByAppendingString:apiKey]
        forHTTPHeaderField:@"Authorization"];
    __weak CPARemoteCompletionClient *weakSelf = self;
    __weak CPARemoteCompletionTask *weakToken = token;
    token.sessionTask = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            CPARemoteCompletionClient *strongSelf = weakSelf;
            CPARemoteCompletionTask *strongToken = weakToken;
            if (strongSelf == nil || strongToken == nil || strongToken.cancelled
                || strongToken.finished) {
                return;
            }
            NSInteger statusCode = [strongSelf statusCodeForResponse:response];
            CPARemoteCompletionOutcome failure = [strongSelf failureOutcomeForError:error
                statusCode:statusCode];
            if (failure != CPARemoteCompletionOutcomeSuccess) {
                [strongSelf finishToken:strongToken outcome:failure insertion:nil
                    statusCode:statusCode error:error phase:@"model_discovery"];
                return;
            }
            NSError *parseError = nil;
            NSString *model = [strongSelf.protocol selectedModelFromResponseData:data
                preferredModel:@"" error:&parseError];
            if (model.length == 0 || parseError != nil) {
                [strongSelf finishToken:strongToken
                    outcome:CPARemoteCompletionOutcomeInvalidResponse
                    insertion:nil statusCode:statusCode error:parseError
                    phase:@"model_discovery"];
                return;
            }
            strongSelf.cachedModel = model;
            strongToken.model = model;
            [strongSelf startCompletionForToken:strongToken input:input
                apiKey:apiKey model:model qualityRetry:NO];
        }];
    [token.sessionTask resume];
}

- (void)startCompletionForToken:(CPARemoteCompletionTask *)token
    input:(NSString *)input apiKey:(NSString *)apiKey model:(NSString *)model
    qualityRetry:(BOOL)qualityRetry {
    token.phase = qualityRetry ? @"completion_quality_retry" : @"completion";
    token.model = model;
    NSString *host = self.baseURL.host.lowercaseString;
    BOOL loopback = [@[@"127.0.0.1", @"localhost", @"::1", @"[::1]"] containsObject:host ?: @""];
    BOOL useLocalPrefix = self.usesLocalPrefixCompletion && loopback
        && CPASupportsLocalPrefixCompletionModel(model);
    NSError *buildError = nil;
    self.protocol.applicationBundleIdentifier = self.applicationBundleIdentifier ?: @"";
    CPARemoteCompletionRequest *completionRequest = token.continuationAfterAcceptance
        ? [self.protocol requestForInput:input rightContext:token.rightContext
            contextMessages:token.contextMessages model:model qualityRetry:qualityRetry
            useLocalPrefix:useLocalPrefix documentContinuation:token.documentContinuation continuationAfterAcceptance:YES error:&buildError]
        : token.documentContinuation
        ? [self.protocol requestForInput:input rightContext:token.rightContext
            contextMessages:token.contextMessages model:model qualityRetry:qualityRetry
            useLocalPrefix:useLocalPrefix documentContinuation:YES error:&buildError]
        : (token.rightContext.length
            ? [self.protocol requestForInput:input rightContext:token.rightContext
                contextMessages:token.contextMessages model:model qualityRetry:qualityRetry
                useLocalPrefix:useLocalPrefix error:&buildError]
            : [self.protocol requestForInput:input contextMessages:token.contextMessages model:model
                qualityRetry:qualityRetry useLocalPrefix:useLocalPrefix error:&buildError]);
    if (completionRequest == nil || buildError != nil) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeInvalidResponse
            insertion:nil statusCode:0 error:buildError phase:@"request_build"];
        return;
    }
    token.redactionCount = completionRequest.redactionCount;
    token.streamBuffer = [NSMutableData data];
    token.responseData = [NSMutableData data];
    token.streamPreviewText = [NSMutableString string];
    token.streamSentInput = completionRequest.sentInput;
    token.requestInput = input;
    token.requestAPIKey = apiKey;
    token.streamedOutputCharacterCount = 0;
    NSURL *url = [self.baseURL URLByAppendingPathComponent:completionRequest.completionPath];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = completionRequest.bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    [request setValue:[@"Bearer " stringByAppendingString:apiKey]
        forHTTPHeaderField:@"Authorization"];
    token.completionDispatchMilliseconds = @((NSUInteger)llround(-token.startedAt.timeIntervalSinceNow * 1000.0));
    token.firstDataMilliseconds = nil;
    token.sessionTask = [self.session dataTaskWithRequest:request];
    [token.sessionTask resume];
}

- (void)finishCompletionTask:(CPARemoteCompletionTask *)token
    input:(NSString *)input apiKey:(NSString *)apiKey model:(NSString *)model
    qualityRetry:(BOOL)qualityRetry data:(NSData *)data response:(NSURLResponse *)response
    error:(NSError *)error {
    if (token == nil || token.cancelled || token.finished) {
        return;
    }
    NSInteger statusCode = [self statusCodeForResponse:response];
    CPARemoteCompletionOutcome failure = [self failureOutcomeForError:error
        statusCode:statusCode];
    if (failure != CPARemoteCompletionOutcomeSuccess) {
        [self finishToken:token outcome:failure insertion:nil
            statusCode:statusCode error:error phase:@"completion"];
        return;
    }
    NSError *parseError = nil;
    NSDictionary *diagnostics = nil;
    token.validationStartedAt = NSDate.date;
    NSString *insertion = [self.protocol completionSuffixFromResponseData:data
        sentInput:token.streamSentInput contextMessages:token.contextMessages
        diagnostics:&diagnostics error:&parseError];
    token.responseDiagnostics = diagnostics ?: @{};
    if (parseError != nil) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeInvalidResponse
            insertion:nil statusCode:statusCode error:parseError phase:@"response_parse"];
        return;
    }
    if (insertion.length == 0) {
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess insertion:nil
            statusCode:statusCode error:nil phase:insertion == nil ? @"no_suggestion_rejected" : @"no_suggestion"];
        return;
    }
    if (CPARemoteCompletionUsesSmallLocalModel(model)
        && insertion.length >= CPARemoteCompletionMinimumSuggestionCharacterCount
        && CPALocalCompletionOutputIsLowValue(insertion)) {
        NSMutableDictionary *rejectedDiagnostics = [token.responseDiagnostics mutableCopy];
        rejectedDiagnostics[@"noSuggestionReason"] = @"local_low_value";
        token.responseDiagnostics = rejectedDiagnostics;
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess
            insertion:nil statusCode:statusCode error:nil
            phase:@"no_suggestion_local_low_value"];
        return;
    }
    BOOL fitsRightContext = CPAInsertionFitsRightContext(insertion, token.rightContext);
    if (!fitsRightContext
        || (token.rightContext.length == 0 && ![self.protocol completionMeetsMinimumLength:insertion sentInput:token.streamSentInput contextMessages:token.contextMessages])) {
        NSMutableDictionary *rejectedDiagnostics = [token.responseDiagnostics mutableCopy];
        rejectedDiagnostics[@"noSuggestionReason"] = fitsRightContext ? @"too_short" : @"right_context";
        token.responseDiagnostics = rejectedDiagnostics;
        [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess insertion:nil
            statusCode:statusCode error:nil phase:@"no_suggestion_too_short"];
        return;
    }
    [self storeCacheEntryForInput:input model:model insertion:insertion
        inputCharacterCount:token.inputCharacterCount outputCharacterCount:insertion.length
        redactionCount:token.redactionCount
        contextFingerprint:token.contextFingerprint epoch:token.cacheEpoch];
    [self finishToken:token outcome:CPARemoteCompletionOutcomeSuccess insertion:insertion
        statusCode:statusCode error:nil
        phase:qualityRetry ? @"completion_quality_retry" : @"completion"];
}

- (CPARemoteCompletionTask *)taskForDataTask:(NSURLSessionDataTask *)dataTask {
    CPARemoteCompletionTask *task = nil;
    @synchronized (self) {
        task = self.activeTask;
    }
    if (task == nil || task.sessionTask != dataTask) {
        return nil;
    }
    @synchronized (task) {
        if (task.cancelled || task.finished) {
            return nil;
        }
    }
    return task;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    CPARemoteCompletionTask *task = [self taskForDataTask:dataTask];
    if (task == nil || data.length == 0) {
        return;
    }
    // A suffix is at most 90 characters; cap even malformed or endless SSE bodies.
    static const NSUInteger maximumResponseBytes = 256 * 1024;
    if (data.length > maximumResponseBytes - task.responseData.length) {
        [self finishToken:task outcome:CPARemoteCompletionOutcomeInvalidResponse
            insertion:nil statusCode:[self statusCodeForResponse:dataTask.response]
            error:[NSError errorWithDomain:@"local.codex.prompt-assistant.remote"
                code:1 userInfo:@{NSLocalizedDescriptionKey: @"Completion response exceeds size limit"}]
            phase:@"response_too_large"];
        [dataTask cancel];
        task.responseData = nil;
        task.streamBuffer = nil;
        task.streamPreviewText = nil;
        return;
    }
    if (task.firstDataMilliseconds == nil)
        task.firstDataMilliseconds = @((NSUInteger)llround(-task.startedAt.timeIntervalSinceNow * 1000.0));
    [task.responseData appendData:data];
    if (self.requiresFinalValidation || task.rightContext.length) return;
    [task.streamBuffer appendData:data];
    const uint8_t *bytes = task.streamBuffer.bytes;
    NSUInteger length = task.streamBuffer.length;
    NSUInteger lineStart = 0;
    for (NSUInteger index = 0; index < length; index++) {
        if (bytes[index] != '\n') {
            continue;
        }
        NSUInteger lineLength = index - lineStart + 1;
        NSData *lineData = [task.streamBuffer subdataWithRange:
            NSMakeRange(lineStart, lineLength)];
        NSString *line = [[NSString alloc] initWithData:lineData
            encoding:NSUTF8StringEncoding];
        lineStart = index + 1;
        if (line.length == 0 || ![line hasPrefix:@"data:"]) {
            continue;
        }
        NSError *parseError = nil;
        // Parse only this newly completed SSE event for the preview path.
        // Validate the accumulated preview with the actual input below; an
        // individual delta cannot establish answer style or repetition.
        // The full response is also validated once at completion.
        NSString *piece = [self.protocol completionTextFromSSEText:line error:&parseError];
        task.streamParseWorkUnits += line.length;
        if (piece.length > 0) {
            [task.streamPreviewText appendString:piece];
        }

        BOOL localModel = CPARemoteCompletionUsesSmallLocalModel(task.model);
        NSUInteger configuredMinimum = self.progressMinimumCharacterCount;
        if (configuredMinimum == 0) {
            configuredMinimum = CPARemoteCompletionMinimumSuggestionCharacterCount;
        }
        NSUInteger minimumNextLength = task.streamedOutputCharacterCount == 0
            ? configuredMinimum
            : task.streamedOutputCharacterCount
                + MAX((NSUInteger)1, self.progressMinimumCharacterDelta);
        // No UI update is eligible yet: avoid repeating full-input quality work.
        if (piece.length == 0 || parseError != nil
            || task.streamPreviewText.length < minimumNextLength) continue;
        NSString *partial = [self.protocol normalizedCompletion:task.streamPreviewText
            sentInput:task.streamSentInput ?: @"" contextMessages:task.contextMessages];
        BOOL isLocalPreview = localModel
            && partial.length < CPARemoteCompletionMinimumSuggestionCharacterCount;
        if (parseError != nil || partial.length < minimumNextLength
            || (isLocalPreview && !CPALocalCompletionPreviewIsSafe(partial))
            || (localModel && CPALocalCompletionOutputIsLowValue(partial)
                && partial.length >= CPARemoteCompletionMinimumSuggestionCharacterCount)) {
            continue;
        }
        task.streamedOutputCharacterCount = partial.length;
        [self enqueueProgress:partial forTask:task];
    }
    if (lineStart > 0) {
        [task.streamBuffer replaceBytesInRange:NSMakeRange(0, lineStart)
            withBytes:NULL length:0];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)sessionTask
    didCompleteWithError:(NSError *)error {
    (void)session;
    if (![sessionTask isKindOfClass:NSURLSessionDataTask.class]) {
        return;
    }
    CPARemoteCompletionTask *task = [self taskForDataTask:(NSURLSessionDataTask *)sessionTask];
    if (task == nil || ![task.phase hasPrefix:@"completion"]) {
        return;
    }
    [self finishCompletionTask:task input:task.requestInput
        apiKey:task.requestAPIKey model:task.model qualityRetry:[task.phase isEqualToString:
            @"completion_quality_retry"] data:task.responseData
        response:sessionTask.response error:error];
}

- (NSInteger)statusCodeForResponse:(NSURLResponse *)response {
    return [response isKindOfClass:NSHTTPURLResponse.class]
        ? ((NSHTTPURLResponse *)response).statusCode : 0;
}

- (CPARemoteCompletionOutcome)failureOutcomeForError:(NSError *)error
    statusCode:(NSInteger)statusCode {
    if (error != nil && [error.domain isEqualToString:NSURLErrorDomain]
        && error.code == NSURLErrorCancelled) {
        return CPARemoteCompletionOutcomeCancelled;
    }
    // Prefer an HTTP status when one is available. NSURLSession may surface
    // a non-nil transport error alongside a response; treating a 401/429/5xx
    // as a generic network error would otherwise defeat the matching
    // cooldown/circuit policy below.
    if (statusCode == 401 || statusCode == 403) {
        return CPARemoteCompletionOutcomeUnauthorized;
    }
    if (statusCode == 429) {
        return CPARemoteCompletionOutcomeRateLimited;
    }
    if (statusCode >= 500) {
        return CPARemoteCompletionOutcomeServerError;
    }
    if (error != nil) {
        if ([error.domain isEqualToString:NSURLErrorDomain]
            && error.code == NSURLErrorTimedOut) {
            return CPARemoteCompletionOutcomeTimedOut;
        }
        return CPARemoteCompletionOutcomeTransportError;
    }
    if (statusCode >= 200 && statusCode < 300) {
        return CPARemoteCompletionOutcomeSuccess;
    }
    if (statusCode == 401 || statusCode == 403) {
        return CPARemoteCompletionOutcomeUnauthorized;
    }
    if (statusCode == 429) {
        return CPARemoteCompletionOutcomeRateLimited;
    }
    if (statusCode >= 500) {
        return CPARemoteCompletionOutcomeServerError;
    }
    return CPARemoteCompletionOutcomeInvalidResponse;
}

- (void)enqueueProgress:(NSString *)partial
                 forTask:(CPARemoteCompletionTask *)task {
    if (partial.length == 0 || task == nil) {
        return;
    }
    BOOL shouldSchedule = NO;
    NSTimeInterval delay = 0.0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    @synchronized (task) {
        if (task.cancelled || task.progress == nil) {
            return;
        }
        // Keep only the newest prefix while a main-queue delivery is pending.
        // This bounds UI work during a fast SSE burst without changing the
        // final accumulated response or its quality checks.
        task.pendingProgressText = [partial copy];
        if (!task.progressDeliveryScheduled) {
            task.progressDeliveryScheduled = YES;
            shouldSchedule = YES;
            if (task.lastProgressDeliveryTime > 0.0) {
                CFTimeInterval elapsed = now - task.lastProgressDeliveryTime;
                if (elapsed >= 0.0 && elapsed < (1.0 / 60.0)) {
                    delay = (1.0 / 60.0) - elapsed;
                }
            }
        }
    }
    if (!shouldSchedule) {
        return;
    }
    __weak CPARemoteCompletionClient *weakSelf = self;
    dispatch_block_t deliveryBlock = ^{
        CPARemoteCompletionClient *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf deliverPendingProgressForTask:task];
    };
    if (delay > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)llround(delay * (NSTimeInterval)NSEC_PER_SEC)),
            self.callbackQueue, deliveryBlock);
    } else {
        dispatch_async(self.callbackQueue, deliveryBlock);
    }
}

- (void)deliverPendingProgressForTask:(CPARemoteCompletionTask *)task {
    CPARemoteCompletionProgressHandler progress = nil;
    NSString *partial = nil;
    @synchronized (task) {
        if (task.cancelled) {
            task.pendingProgressText = nil;
            task.progressDeliveryScheduled = NO;
            return;
        }
        partial = [task.pendingProgressText copy];
        task.pendingProgressText = nil;
        progress = [task.progress copy];
        task.lastProgressDeliveryTime = CFAbsoluteTimeGetCurrent();
        if (partial.length == 0 || progress == nil) {
            task.progressDeliveryScheduled = NO;
            return;
        }
    }
    progress(partial);

    BOOL shouldSchedule = NO;
    @synchronized (task) {
        if (task.cancelled || task.finished) {
            task.pendingProgressText = nil;
            task.progressDeliveryScheduled = NO;
        } else if (task.pendingProgressText.length > 0) {
            // Leave the scheduled flag set while handing off one more latest
            // value. The next block runs on the same callback queue, yielding
            // between UI updates instead of looping inside one run-loop turn.
            shouldSchedule = YES;
        } else {
            task.progressDeliveryScheduled = NO;
        }
    }
    if (!shouldSchedule) {
        return;
    }
    NSTimeInterval delay = 1.0 / 60.0;
    __weak CPARemoteCompletionClient *weakSelf = self;
    dispatch_block_t deliveryBlock = ^{
        CPARemoteCompletionClient *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf deliverPendingProgressForTask:task];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)llround(delay * (NSTimeInterval)NSEC_PER_SEC)),
        self.callbackQueue, deliveryBlock);
}

- (void)finishToken:(CPARemoteCompletionTask *)token
    outcome:(CPARemoteCompletionOutcome)outcome
    insertion:(NSString *)insertion
    statusCode:(NSInteger)statusCode
    error:(NSError *)error
    phase:(NSString *)phase {
    if (token == nil) {
        return;
    }
    if (error == nil
        && outcome != CPARemoteCompletionOutcomeSuccess
        && outcome != CPARemoteCompletionOutcomeCancelled
        && outcome != CPARemoteCompletionOutcomeNotConfigured
        && outcome != CPARemoteCompletionOutcomeCircuitOpen) {
        NSString *description = statusCode > 0
            ? [NSString stringWithFormat:@"Remote completion HTTP status %ld",
                (long)statusCode]
            : @"Remote completion failed without an error";
        error = [NSError errorWithDomain:@"local.codex.prompt-assistant.remote"
            code:statusCode userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    @synchronized (token) {
        if (token.finished) {
            return;
        }
        token.finished = YES;
        if (outcome != CPARemoteCompletionOutcomeSuccess || insertion.length == 0) {
            token.pendingProgressText = nil;
        }
    }
    BOOL countsAsFailure = outcome != CPARemoteCompletionOutcomeSuccess
        && outcome != CPARemoteCompletionOutcomeCancelled
        && outcome != CPARemoteCompletionOutcomeNotConfigured
        && outcome != CPARemoteCompletionOutcomeCircuitOpen;
    @synchronized (self) {
        // Only a fresh successful provider response proves recovery. Local
        // boundaries, literal closures and cached results never reset health.
        if (outcome == CPARemoteCompletionOutcomeSuccess && statusCode >= 200
            && statusCode < 300 && !token.cacheHit) {
            self.consecutiveFailureCount = 0;
            self.circuitOpenUntil = nil;
        } else if (outcome == CPARemoteCompletionOutcomeUnauthorized) {
            // A bad key will not become valid by retrying. Open immediately
            // and avoid repeatedly sending credentials until the cooldown
            // elapses (the next request will naturally probe again).
            self.consecutiveFailureCount = 0;
            self.circuitOpenUntil = [NSDate dateWithTimeIntervalSinceNow:
                CPARemoteCompletionUnauthorizedCooldown];
        } else if (outcome == CPARemoteCompletionOutcomeRateLimited) {
            self.consecutiveFailureCount = 0;
            self.circuitOpenUntil = [NSDate dateWithTimeIntervalSinceNow:
                CPARemoteCompletionRateLimitCooldown];
        } else if (countsAsFailure) {
            self.consecutiveFailureCount++;
            if (self.consecutiveFailureCount >= CPARemoteCompletionFailureThreshold) {
                self.circuitOpenUntil = [NSDate dateWithTimeIntervalSinceNow:
                    CPARemoteCompletionCircuitDuration];
                self.consecutiveFailureCount = 0;
            }
        }
        if (self.activeTask == token) {
            self.activeTask = nil;
        }
    }
    CPARemoteCompletionResult *result = [[CPARemoteCompletionResult alloc] init];
    result.outcome = outcome;
    result.insertionText = insertion;
    result.statusCode = statusCode;
    result.durationMilliseconds = (NSUInteger)llround(
        -[token.startedAt timeIntervalSinceNow] * 1000.0);
    result.completionDispatchMilliseconds = token.completionDispatchMilliseconds;
    result.firstDataMilliseconds = token.firstDataMilliseconds;
    result.validationMilliseconds = token.validationStartedAt != nil
        ? @((NSUInteger)llround(-token.validationStartedAt.timeIntervalSinceNow * 1000.0)) : nil;
    result.responseDiagnostics = token.responseDiagnostics ?: @{};
    result.inputCharacterCount = token.inputCharacterCount;
    result.outputCharacterCount = insertion.length;
    result.streamParseWorkUnits = token.streamParseWorkUnits;
    result.redactionCount = token.redactionCount;
    result.requestID = token.requestID;
    result.phase = phase.length > 0 ? phase : token.phase ?: @"unknown";
    result.model = token.model;
    result.cacheHit = token.cacheHit;
    result.errorDomain = error.domain;
    result.errorCode = error.code;
    result.errorMessage = [self safeErrorMessage:error];
    dispatch_async(self.callbackQueue, ^{
        @synchronized (token) {
            if (token.cancelled) {
                result.outcome = CPARemoteCompletionOutcomeCancelled;
                result.insertionText = nil;
                result.outputCharacterCount = 0;
                token.pendingProgressText = nil;
            }
            token.resultDelivered = YES;
        }
        // Drain a successful preview before the terminal callback; rejected
        // results already cleared it. Delayed delivery blocks then find nil.
        [self deliverPendingProgressForTask:token];
        token.completion(result);
    });
}

- (NSString *)newRequestIdentifier {
    NSString *identifier = NSUUID.UUID.UUIDString;
    return identifier.length > 12 ? [identifier substringToIndex:12] : identifier;
}

- (NSString *)safeErrorMessage:(NSError *)error {
    if (error == nil) {
        return nil;
    }
    NSString *message = error.localizedDescription ?: @"Unknown remote completion error";
    NSArray<NSString *> *parts = [message componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    message = [parts componentsJoinedByString:@" "];
    while ([message containsString:@"  "]) {
        message = [message stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (message.length > 160) {
        message = [message substringToIndex:160];
    }
    return message.length > 0 ? message : @"Unknown remote completion error";
}

- (NSString *)contextFingerprintForMessages:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)messages {
    NSMutableString *material = [NSMutableString string];
    for (NSUInteger i = 0, len = messages.count; i < len; i++) {
        NSString *role = messages[i][@"role"] ?: @"";
        NSString *content = messages[i][@"content"] ?: @"";
        [material appendFormat:@"%lu:%@:%lu:%@;",
            (unsigned long)role.length, role,
            (unsigned long)content.length, content];
    }
    NSData *data = [material dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *fingerprint = [NSMutableString stringWithCapacity:
        CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [fingerprint appendFormat:@"%02x", digest[i]];
    }
    return fingerprint;
}

- (NSString *)cacheKeyForInput:(NSString *)input
    model:(NSString *)model
    contextFingerprint:(NSString *)contextFingerprint {
    NSString *material = [NSString stringWithFormat:@"%@\x1f%@\x1f%@",
        model, contextFingerprint ?: @"", input];
    NSData *data = [material dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *key = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [key appendFormat:@"%02x", digest[i]];
    }
    return key;
}

- (nullable CPARemoteCompletionCacheEntry *)cachedEntryForInput:(NSString *)input
    model:(NSString *)model
    contextFingerprint:(NSString *)contextFingerprint {
    if (input.length < CPARemoteCompletionMinimumCacheInputCharacterCount) {
        return nil;
    }
    NSString *key = [self cacheKeyForInput:input model:model
        contextFingerprint:contextFingerprint];
    @synchronized (self) {
        CPARemoteCompletionCacheEntry *entry = self.completionCache[key];
        if (entry != nil) {
            if (-[entry.createdAt timeIntervalSinceNow] <= CPARemoteCompletionCacheLifetime
                && entry.insertionText.length >= CPARemoteCompletionMinimumSuggestionCharacterCount) {
                return entry;
            }
            [self.completionCache removeObjectForKey:key];
        }

        // Reuse only a still-valid remainder when the user continued typing
        // inside a previously returned continuation.
        NSArray<NSString *> *keys = self.completionCache.allKeys;
        for (NSUInteger index = 0, count = keys.count; index < count; index++) {
            NSString *candidateKey = keys[index];
            CPARemoteCompletionCacheEntry *candidate = self.completionCache[candidateKey];
            if (candidate == nil) {
                continue;
            }
            if (-[candidate.createdAt timeIntervalSinceNow] > CPARemoteCompletionCacheLifetime) {
                [self.completionCache removeObjectForKey:candidateKey];
                continue;
            }
            if (![candidate.model isEqualToString:model]
                || ![candidate.contextFingerprint isEqualToString:contextFingerprint]
                || candidate.insertionText.length < CPARemoteCompletionMinimumSuggestionCharacterCount
                || candidate.inputText.length < CPARemoteCompletionMinimumCacheInputCharacterCount
                || input.length <= candidate.inputText.length
                || ![input hasPrefix:candidate.inputText]) {
                continue;
            }
            NSString *fullContinuation = [candidate.inputText
                stringByAppendingString:candidate.insertionText];
            if (input.length >= fullContinuation.length
                || ![fullContinuation hasPrefix:input]) {
                continue;
            }
            CPARemoteCompletionCacheEntry *rebased = [[CPARemoteCompletionCacheEntry alloc] init];
            rebased.inputText = input;
            rebased.insertionText = [fullContinuation substringFromIndex:input.length];
            rebased.createdAt = candidate.createdAt;
            rebased.inputCharacterCount = input.length;
            rebased.outputCharacterCount = rebased.insertionText.length;
            rebased.redactionCount = candidate.redactionCount;
            rebased.model = model;
            rebased.contextFingerprint = contextFingerprint;
            return rebased;
        }
        return nil;
    }
}

- (void)storeCacheEntryForInput:(NSString *)input
    model:(NSString *)model
    insertion:(NSString *)insertion
    inputCharacterCount:(NSUInteger)inputCharacterCount
    outputCharacterCount:(NSUInteger)outputCharacterCount
    redactionCount:(NSUInteger)redactionCount
    contextFingerprint:(NSString *)contextFingerprint epoch:(NSUInteger)epoch {
    if (input.length < CPARemoteCompletionMinimumCacheInputCharacterCount
        || model.length == 0 || insertion.length == 0) {
        return;
    }
    CPARemoteCompletionCacheEntry *entry = [[CPARemoteCompletionCacheEntry alloc] init];
    entry.inputText = input;
    entry.insertionText = insertion;
    entry.createdAt = [NSDate date];
    entry.inputCharacterCount = inputCharacterCount;
    entry.outputCharacterCount = outputCharacterCount;
    entry.redactionCount = redactionCount;
    entry.model = model;
    entry.contextFingerprint = contextFingerprint ?: @"";
    NSString *key = [self cacheKeyForInput:input model:model
        contextFingerprint:entry.contextFingerprint];
    @synchronized (self) {
        if (epoch != self.cacheEpoch) return;
        if (self.completionCache.count >= CPARemoteCompletionCacheCapacity
            && self.completionCache[key] == nil) {
            NSString *oldestKey = nil;
            NSDate *oldestDate = nil;
            NSArray<NSString *> *keys = self.completionCache.allKeys;
            for (NSUInteger i = 0, len = keys.count; i < len; i++) {
                CPARemoteCompletionCacheEntry *candidate = self.completionCache[keys[i]];
                if (oldestDate == nil
                    || [candidate.createdAt compare:oldestDate] == NSOrderedAscending) {
                    oldestDate = candidate.createdAt;
                    oldestKey = keys[i];
                }
            }
            if (oldestKey != nil) {
                [self.completionCache removeObjectForKey:oldestKey];
            }
        }
        self.completionCache[key] = entry;
    }
}

@end
