#import "Diagnostics.h"

#ifdef CPA_TEST_DIAGNOSTIC_LOG_PATH
NSString *const CPADiagnosticLogPath = @CPA_TEST_DIAGNOSTIC_LOG_PATH;
#else
NSString *const CPADiagnosticLogPath = @"/tmp/CodexPromptAssistantPOC-diagnostic.log";
#endif
static const unsigned long long CPADiagnosticMaximumFileSize = 1024 * 1024;
static const NSUInteger CPADiagnosticRotationCount = 3;
static const NSTimeInterval CPADiagnosticRepeatSummaryInterval = 15.0;

NSString *CPADiagnosticStateWithTarget(NSString *state,
    NSString *bundleIdentifier, int processIdentifier) {
    return [NSString stringWithFormat:@"target=%d:%lu:%@:%@",
        processIdentifier, (unsigned long)bundleIdentifier.length,
        bundleIdentifier, state];
}

@interface CPAStatefulDiagnosticWriter ()
@property(nonatomic, copy) NSString *logPath;
@property(nonatomic) unsigned long long maximumFileSize;
@property(nonatomic) NSUInteger rotationCount;
@property(nonatomic) NSTimeInterval repeatSummaryInterval;
@property(nonatomic, copy, nullable) NSString *lastState;
@property(nonatomic, copy, nullable) NSString *lastStateMessage;
@property(nonatomic, strong, nullable) NSDate *lastStateWriteDate;
@property(nonatomic) NSUInteger suppressedRepeatCount;
@end

@implementation CPAStatefulDiagnosticWriter

- (instancetype)initWithLogPath:(NSString *)logPath
                maximumFileSize:(unsigned long long)maximumFileSize
                   rotationCount:(NSUInteger)rotationCount
           repeatSummaryInterval:(NSTimeInterval)repeatSummaryInterval {
    self = [super init];
    if (self != nil) {
        _logPath = [logPath copy];
        _maximumFileSize = MAX((unsigned long long)128, maximumFileSize);
        _rotationCount = rotationCount;
        _repeatSummaryInterval = MAX(0.1, repeatSummaryInterval);
    }
    return self;
}

- (void)rotateIfNeededForByteCount:(NSUInteger)byteCount {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    unsigned long long currentSize = [[fileManager
        attributesOfItemAtPath:self.logPath error:nil] fileSize];
    if (currentSize + byteCount <= self.maximumFileSize) {
        return;
    }
    if (self.rotationCount == 0) {
        [fileManager removeItemAtPath:self.logPath error:nil];
        return;
    }
    for (NSUInteger index = self.rotationCount; index > 0; index--) {
        NSString *destination = [self.logPath stringByAppendingFormat:@".%lu",
            (unsigned long)index];
        [fileManager removeItemAtPath:destination error:nil];
        NSString *source = index == 1 ? self.logPath
            : [self.logPath stringByAppendingFormat:@".%lu",
                (unsigned long)(index - 1)];
        if ([fileManager fileExistsAtPath:source]) {
            [fileManager moveItemAtPath:source toPath:destination error:nil];
        }
    }
}

- (void)writeMessage:(NSString *)message atDate:(NSDate *)date {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    [self rotateIfNeededForByteCount:data.length];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:self.logPath]) {
        [fileManager createFileAtPath:self.logPath contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    if (handle == nil) {
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

- (void)recordMessage:(NSString *)message atDate:(NSDate *)date {
    [self writeMessage:message atDate:date];
}

- (void)writeSuppressedSummaryAtDate:(NSDate *)date {
    if (self.suppressedRepeatCount == 0 || self.lastStateMessage.length == 0) {
        return;
    }
    NSString *summary = [NSString stringWithFormat:@"%@ repeated=%lu",
        self.lastStateMessage,
        (unsigned long)self.suppressedRepeatCount];
    [self writeMessage:summary atDate:date];
    self.suppressedRepeatCount = 0;
    self.lastStateWriteDate = date;
}

- (void)recordState:(NSString *)state
            message:(NSString *)message
             atDate:(NSDate *)date {
    if (![state isEqualToString:self.lastState]) {
        [self writeSuppressedSummaryAtDate:date];
        self.lastState = [state copy];
        self.lastStateMessage = [message copy];
        self.lastStateWriteDate = date;
        self.suppressedRepeatCount = 0;
        [self writeMessage:message atDate:date];
        return;
    }
    self.suppressedRepeatCount += 1;
    self.lastStateMessage = [message copy];
    if (self.lastStateWriteDate == nil
        || [date timeIntervalSinceDate:self.lastStateWriteDate]
            >= self.repeatSummaryInterval) {
        [self writeSuppressedSummaryAtDate:date];
    }
}

@end

static dispatch_queue_t CPADiagnosticQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "local.codex.prompt-assistant.diagnostics",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static CPAStatefulDiagnosticWriter *CPADiagnosticWriter(void) {
    static CPAStatefulDiagnosticWriter *writer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        writer = [[CPAStatefulDiagnosticWriter alloc]
            initWithLogPath:CPADiagnosticLogPath
            maximumFileSize:CPADiagnosticMaximumFileSize
            rotationCount:CPADiagnosticRotationCount
            repeatSummaryInterval:CPADiagnosticRepeatSummaryInterval];
    });
    return writer;
}

void CPADiagnosticLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    dispatch_async(CPADiagnosticQueue(), ^{
        [CPADiagnosticWriter() recordMessage:message atDate:NSDate.date];
    });
}

void CPADiagnosticLogState(NSString *state, NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    dispatch_async(CPADiagnosticQueue(), ^{
        [CPADiagnosticWriter() recordState:state message:message atDate:NSDate.date];
    });
}

void CPADiagnosticLogFlush(void) {
    dispatch_sync(CPADiagnosticQueue(), ^{});
}
