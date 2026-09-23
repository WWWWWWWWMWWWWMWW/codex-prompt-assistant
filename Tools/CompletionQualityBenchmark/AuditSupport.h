#import <Foundation/Foundation.h>
// Offline experiment only. Does not publish, rewrite, or insert candidates.
FOUNDATION_EXPORT NSDictionary *CPABenchmarkParseAudit(NSString *text);
FOUNDATION_EXPORT NSDictionary *CPABenchmarkAuditAttempt(NSDictionary *fixture,
    NSURL *baseURL, NSString *key, NSString *model,
    NSURLSessionConfiguration *configuration, NSTimeInterval deadline, NSString *version);
