#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Structural eligibility at the cursor; existing right context is preserved.
/// Sentence/question completion is judged by the provider and output validation.
FOUNDATION_EXPORT BOOL CPACompletionCanContinueAtCursor(NSString *text, NSUInteger cursor);
FOUNDATION_EXPORT BOOL CPAInsertionFitsRightContext(NSString *insertion, NSString *rightContext);

FOUNDATION_EXPORT BOOL CPASupportsLocalPrefixCompletionModel(NSString *model);

/// Literal continuation for a narrowly formatted, explicitly selected action.
/// Returns nil for ambiguous references, conditions, or non-generic drafts.
FOUNDATION_EXPORT NSString * _Nullable CPAExplicitOptionContinuation(NSString *input, NSArray *messages);

/// Literal latest-user scope, for generic how drafts or an exact draft prefix
/// that has already begun the same scope's exclusion clause.
/// Unsupported or qualified material returns nil; no history inference is performed.
FOUNDATION_EXPORT NSString * _Nullable CPAExplicitUserScopeContinuation(NSString *input, NSArray *messages);

@interface CPARemoteCompletionRequest : NSObject

@property(nonatomic, copy, readonly) NSData *bodyData;
@property(nonatomic, copy, readonly) NSString *completionPath;
@property(nonatomic, copy, readonly) NSString *sentInput;
@property(nonatomic, readonly) NSUInteger inputCharacterCount;
@property(nonatomic, readonly) NSUInteger redactionCount;

@end

@interface CPARemoteCompletionProtocol : NSObject

/// Verified target application bundle. Empty keeps the generic prompt.
@property(nonatomic, copy) NSString *applicationBundleIdentifier;

- (nullable CPARemoteCompletionRequest *)requestForInput:(NSString *)input
    model:(NSString *)model
    error:(NSError **)error;
- (nullable CPARemoteCompletionRequest *)requestForInput:(NSString *)input
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    model:(NSString *)model
    error:(NSError **)error;
- (nullable CPARemoteCompletionRequest *)requestForInput:(NSString *)input
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    model:(NSString *)model
    qualityRetry:(BOOL)qualityRetry
    error:(NSError **)error;
/// Opt in only for the resident model whose ChatML template has been verified.
- (nullable CPARemoteCompletionRequest *)requestForInput:(NSString *)input
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    model:(NSString *)model
    qualityRetry:(BOOL)qualityRetry
    useLocalPrefix:(BOOL)useLocalPrefix
    error:(NSError **)error;
- (nullable CPARemoteCompletionRequest *)requestForInput:(NSString *)input
    rightContext:(NSString *)rightContext
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    model:(NSString *)model qualityRetry:(BOOL)qualityRetry
    useLocalPrefix:(BOOL)useLocalPrefix error:(NSError **)error;
/// Document body mode is selected from verified editor metadata, never draft instructions.
- (nullable CPARemoteCompletionRequest *)requestForInput:(NSString *)input
    rightContext:(NSString *)rightContext
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    model:(NSString *)model qualityRetry:(BOOL)qualityRetry
    useLocalPrefix:(BOOL)useLocalPrefix documentContinuation:(BOOL)documentContinuation
    error:(NSError **)error;
/// Accepted suffix stage uses separate chat/document instructions; middle/local modes retain their contract.
- (nullable CPARemoteCompletionRequest *)requestForInput:(NSString *)input
    rightContext:(NSString *)rightContext
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    model:(NSString *)model qualityRetry:(BOOL)qualityRetry
    useLocalPrefix:(BOOL)useLocalPrefix documentContinuation:(BOOL)documentContinuation
    continuationAfterAcceptance:(BOOL)continuationAfterAcceptance error:(NSError **)error;
- (nullable NSString *)selectedModelFromResponseData:(nullable NSData *)data
    preferredModel:(NSString *)preferredModel
    error:(NSError **)error;
- (nullable NSString *)completionSuffixFromResponseData:(NSData *)data
    sentInput:(NSString *)sentInput
    error:(NSError **)error;
- (nullable NSString *)completionSuffixFromSSEText:(NSString *)text
    sentInput:(NSString *)sentInput
    error:(NSError **)error;

/// Context belongs to this request; only user-authored evidence may justify a closure.
- (nullable NSString *)completionSuffixFromResponseData:(NSData *)data
    sentInput:(NSString *)sentInput contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    error:(NSError **)error;
/// Only counts and allowlisted reasons; never includes input or provider text.
- (nullable NSString *)completionSuffixFromResponseData:(NSData *)data
    sentInput:(NSString *)sentInput contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages
    diagnostics:(NSDictionary * _Nullable * _Nullable)diagnostics error:(NSError **)error;
- (nullable NSString *)normalizedCompletion:(NSString *)content sentInput:(NSString *)sentInput
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages;
- (BOOL)completionMeetsMinimumLength:(NSString *)completion sentInput:(NSString *)sentInput
    contextMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)contextMessages;

/// Parses raw SSE content without dropping individually unsafe fragments.
- (nullable NSString *)completionTextFromSSEText:(NSString *)text error:(NSError **)error;

/// Validates an accumulated stream or final suffix against its actual input.
- (nullable NSString *)normalizedCompletion:(NSString *)content sentInput:(NSString *)sentInput;

/// Returns whether a suffix meets the fragment threshold or naturally closes
/// the current sentence (three or more characters with terminal punctuation). Short values remain parseable so the client can
/// report a no_suggestion_too_short phase instead of conflating them with
/// an empty model response.
- (BOOL)completionMeetsMinimumLength:(NSString *)completion;
/// Final-result gate: permits bounded, context-supported closures without adding punctuation.
- (BOOL)completionMeetsMinimumLength:(NSString *)completion sentInput:(NSString *)sentInput;

@end

NS_ASSUME_NONNULL_END
