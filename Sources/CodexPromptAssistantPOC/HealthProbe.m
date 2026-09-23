#import "HealthProbe.h"
#import "CPABuildMetadata.h"
#include <unistd.h>
#include <stdio.h>

static NSString *CPAHealthPortName(pid_t pid) {
    return [NSString stringWithFormat:@"local.codex.prompt-assistant-poc.health.%u.%d", getuid(), pid];
}

@interface CPAHealthResponder ()
@property(nonatomic, copy) NSDictionary *(^provider)(void);
@property(nonatomic, copy) NSString *instance;
@property(nonatomic) CFMessagePortRef port;
@property(nonatomic) CFRunLoopSourceRef source;
- (NSData *)responseForData:(NSData *)data;
@end

static CFDataRef CPAHealthReply(CFMessagePortRef port, SInt32 messageID, CFDataRef data, void *info) {
    (void)port;
    if (messageID != 1 || data == NULL) return NULL;
    NSData *reply = [(__bridge CPAHealthResponder *)info responseForData:(__bridge NSData *)data];
    return reply ? CFBridgingRetain(reply) : NULL;
}

@implementation CPAHealthResponder
- (instancetype)initWithStateProvider:(NSDictionary *(^)(void))provider {
    self = [super init];
    if (self) { _provider = [provider copy]; _instance = NSUUID.UUID.UUIDString; }
    return self;
}
- (NSData *)responseForData:(NSData *)data {
    if (!NSThread.isMainThread || data.length > 128) return nil;
    NSString *nonce = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (![[[NSUUID alloc] initWithUUIDString:nonce ?: @""] UUIDString] || nonce.length != 36) return nil;
    NSDictionary *state = self.provider();
    NSDictionary *build = [NSJSONSerialization JSONObjectWithData:[@CPA_BUILD_METADATA_JSON dataUsingEncoding:NSUTF8StringEncoding]
        options:0 error:NULL];
    NSDictionary *reply = @{@"schema":@1, @"nonce":nonce, @"pid":@(getpid()), @"uid":@(getuid()),
        @"instance":self.instance, @"build":build, @"mainThreadResponsive":@YES,
        @"eventTapEnabled":@([state[@"eventTapEnabled"] boolValue]),
        @"accessibilityGranted":@([state[@"accessibilityGranted"] boolValue]),
        @"modelPreserved":@([state[@"modelPreserved"] boolValue])};
    return [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
}
- (BOOL)start {
    if (!NSThread.isMainThread) return NO;
    if (self.port) return YES;
    CFMessagePortContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    Boolean existing = false;
    CFMessagePortRef port = CFMessagePortCreateLocal(NULL, (__bridge CFStringRef)CPAHealthPortName(getpid()),
        CPAHealthReply, &context, &existing);
    if (!port) return NO;
    if (existing) { CFRelease(port); return NO; }
    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, port, 0);
    if (!source) { CFMessagePortInvalidate(port); CFRelease(port); return NO; }
    self.port = port; self.source = source;
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    return YES;
}
- (void)stop {
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source); _source = NULL;
    }
    if (_port) { CFMessagePortInvalidate(_port); CFRelease(_port); _port = NULL; }
}
- (void)dealloc { [self stop]; }
@end

NSDictionary *CPACopyHealthProbeResult(pid_t pid) {
    if (pid <= 0) return nil;
    CFMessagePortRef port = CFMessagePortCreateRemote(NULL, (__bridge CFStringRef)CPAHealthPortName(pid));
    if (!port) return nil;
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSData *request = [nonce dataUsingEncoding:NSUTF8StringEncoding];
    CFDataRef reply = NULL;
    SInt32 result = CFMessagePortSendRequest(port, 1, (__bridge CFDataRef)request, 1.0, 2.0,
        kCFRunLoopDefaultMode, &reply);
    CFRelease(port);
    NSData *data = CFBridgingRelease(reply);
    if (result != kCFMessagePortSuccess || !data || data.length > 8192) return nil;
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"nonce"] isEqual:nonce]
        || ![response[@"schema"] isEqual:@1] || ![response[@"pid"] isEqual:@(pid)]
        || ![response[@"uid"] isEqual:@(getuid())]) return nil;
    return response;
}

int CPARunHealthProbe(pid_t pid) {
    NSDictionary *response = CPACopyHealthProbeResult(pid);
    if (!response) { fputs("Health response unavailable or invalid.\n", stderr); return 2; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
}
