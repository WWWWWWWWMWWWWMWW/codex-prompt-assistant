#import <Foundation/Foundation.h>
#import "../../Sources/RemoteCompletionCore/RemoteCompletionClient.h"
#import "../../Sources/RemoteCompletionCore/RemoteCompletionProtocol.h"

// Tool-only instrumentation. Never link this subclass into the assistant.
@interface CPABenchmarkProtocol : CPARemoteCompletionProtocol
@property(nonatomic) BOOL documentContinuation;
@property(nonatomic, copy) NSString *experimentalSystem;
@property(nonatomic, copy) NSString *experimentalSuffix;
@property(nonatomic) BOOL removesDraftFocus;
@property(nonatomic) BOOL narrowsRepetitionRule;
@property(nonatomic, copy) NSDictionary *contextState;
@property(nonatomic, copy) NSString *rawText;
@property(nonatomic, copy) NSString *finishReason;
@property(nonatomic, copy) NSString *protocolCandidate;
@property(nonatomic) NSUInteger requestCount;
@end

/// Pure replay of fixed model text through production parsing and final gates.
/// No provider, credential, model request, or application state is accessed.
FOUNDATION_EXPORT NSDictionary *CPABenchmarkReplay(NSDictionary *fixture);

// Experiment only: preserve the conversation through the last user turn.
FOUNDATION_EXPORT NSArray *CPABenchmarkUserTurnContext(NSArray *messages, NSString *draft);

FOUNDATION_EXPORT NSDictionary *CPABenchmarkAttempt(NSDictionary *fixture,
    NSURL *baseURL, NSString *key, NSString *model, BOOL prefix, NSString *system, NSDictionary *contextState,
    NSURLSessionConfiguration *configuration, NSTimeInterval deadline);
