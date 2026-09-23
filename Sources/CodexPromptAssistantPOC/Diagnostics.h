#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CPADiagnosticLogPath;
FOUNDATION_EXPORT void CPADiagnosticLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT void CPADiagnosticLogState(
    NSString *state,
    NSString *format,
    ...
) NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT void CPADiagnosticLogFlush(void);

/// Scope throttling to the observed application/process, without input content.
FOUNDATION_EXPORT NSString *CPADiagnosticStateWithTarget(
    NSString *state, NSString *bundleIdentifier, int processIdentifier);

/// Synchronous writer used by the production serial queue and unit tests.
/// State records are emitted immediately on transitions, then summarized at a
/// fixed interval without changing the caller's probe frequency.
@interface CPAStatefulDiagnosticWriter : NSObject

- (instancetype)initWithLogPath:(NSString *)logPath
                maximumFileSize:(unsigned long long)maximumFileSize
                   rotationCount:(NSUInteger)rotationCount
           repeatSummaryInterval:(NSTimeInterval)repeatSummaryInterval;
- (void)recordMessage:(NSString *)message atDate:(NSDate *)date;
- (void)recordState:(NSString *)state
            message:(NSString *)message
             atDate:(NSDate *)date;

@end

NS_ASSUME_NONNULL_END
