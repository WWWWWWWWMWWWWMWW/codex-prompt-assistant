#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CPARemoteCompletionOutcome) {
    CPARemoteCompletionOutcomeSuccess = 0,
    CPARemoteCompletionOutcomeCancelled,
    CPARemoteCompletionOutcomeNotConfigured,
    CPARemoteCompletionOutcomeCircuitOpen,
    CPARemoteCompletionOutcomeTimedOut,
    CPARemoteCompletionOutcomeUnauthorized,
    CPARemoteCompletionOutcomeRateLimited,
    CPARemoteCompletionOutcomeServerError,
    CPARemoteCompletionOutcomeTransportError,
    CPARemoteCompletionOutcomeInvalidResponse,
};

@interface CPARemoteCompletionResult : NSObject

@property(nonatomic, readonly) CPARemoteCompletionOutcome outcome;
@property(nonatomic, copy, readonly, nullable) NSString *insertionText;
@property(nonatomic, readonly) NSInteger statusCode;
@property(nonatomic, readonly) NSUInteger durationMilliseconds;
/// Offsets from request creation; nil for a stage that was not observed.
@property(nonatomic, copy, readonly, nullable) NSNumber *completionDispatchMilliseconds;
@property(nonatomic, copy, readonly, nullable) NSNumber *firstDataMilliseconds;
/// Final parsing/validation duration (not an offset); nil if not reached.
@property(nonatomic, copy, readonly, nullable) NSNumber *validationMilliseconds;
/// Counts and allowlisted final-response reasons only, no text or credentials.
@property(nonatomic, copy, readonly) NSDictionary *responseDiagnostics;
@property(nonatomic, readonly) NSUInteger inputCharacterCount;
@property(nonatomic, readonly) NSUInteger outputCharacterCount;
/// Diagnostic-only amount of SSE payload text inspected before completion.
/// This contains no payload content and is used to detect accidental
/// cumulative reparsing on the streaming preview path.
@property(nonatomic, readonly) NSUInteger streamParseWorkUnits;
@property(nonatomic, readonly) NSUInteger redactionCount;
@property(nonatomic, copy, readonly) NSString *requestID;
@property(nonatomic, copy, readonly) NSString *phase;
@property(nonatomic, copy, readonly, nullable) NSString *model;
@property(nonatomic, copy, readonly, nullable) NSString *errorDomain;
@property(nonatomic, readonly) NSInteger errorCode;
@property(nonatomic, copy, readonly, nullable) NSString *errorMessage;
@property(nonatomic, readonly, getter=isCacheHit) BOOL cacheHit;
/// Whitelisted diagnostic provenance; never contains model output or user text.
@property(nonatomic, copy, readonly) NSString *generationSource;

@end

@interface CPARemoteCompletionTask : NSObject
@property(nonatomic, copy, readonly) NSString *requestID;
- (void)cancel;
@end

typedef void (^CPARemoteCompletionHandler)(CPARemoteCompletionResult *result);
typedef void (^CPARemoteCompletionProgressHandler)(NSString *insertionText);

/// Remote providers must use HTTPS. Plain HTTP is accepted only for a model
/// service bound to the current Mac's loopback interface.
FOUNDATION_EXPORT BOOL CPARemoteCompletionBaseURLIsAllowed(NSURL *baseURL);

@interface CPARemoteCompletionClient : NSObject

/// Number of visible characters required before a streaming partial is
/// published. Final-result quality validation remains unchanged.
@property(nonatomic) NSUInteger progressMinimumCharacterCount;
@property(nonatomic) NSUInteger progressMinimumCharacterDelta;
/// Withhold provisional candidates until final quality validation completes.
@property(nonatomic) BOOL requiresFinalValidation;
/// Set before the first request. Only loopback + verified Qwen models opt in.
@property(nonatomic) BOOL usesLocalPrefixCompletion;
/// Sampled synchronously at request entry, after input validation and before
/// model/cache access. Allows only verified verbatim scope/option continuations.
@property(nonatomic) BOOL literalContinuationsOnly;
/// Sampled at request entry and included in cache/in-flight identity.
@property(nonatomic) BOOL documentContinuation;
/// Verified accepted chat/document suffix; sampled at request entry, isolated in cache identity.
@property(nonatomic) BOOL continuationAfterAcceptance;
/// Verified target application bundle, sampled into request identity.
@property(nonatomic, copy) NSString *applicationBundleIdentifier;

- (instancetype)initWithBaseURL:(NSURL *)baseURL
    sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration
    callbackQueue:(dispatch_queue_t)callbackQueue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    apiKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel
    completion:(CPARemoteCompletionHandler)completion;
- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    apiKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel
    progress:(nullable CPARemoteCompletionProgressHandler)progress
    completion:(CPARemoteCompletionHandler)completion;
- (CPARemoteCompletionTask *)requestCompletionForInput:(NSString *)input
    rightContext:(NSString *)rightContext
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    apiKey:(NSString *)apiKey preferredModel:(NSString *)preferredModel
    progress:(nullable CPARemoteCompletionProgressHandler)progress
    completion:(CPARemoteCompletionHandler)completion;
- (void)cancelActiveRequest;
- (void)invalidateCompletionCache;

@end

NS_ASSUME_NONNULL_END
