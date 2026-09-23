#import "WPSInputBridge.h"
#import <AppKit/AppKit.h>
@implementation CPAWPSInputBridge
- (NSDictionary *)requestPhase:(NSString *)phase processIdentifier:(pid_t)pid
    documentId:(NSString *)documentId {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front.processIdentifier != pid
        || ![front.bundleIdentifier isEqualToString:@"com.kingsoft.wpsoffice.mac"]) return nil;
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/wps/jsaddons/CodexPromptAssistantBridge_1.0.0/bridge"];
    NSData *readyData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"ready.json"]];
    if (readyData.length == 0 || readyData.length > 1024) return nil;
    id ready = [NSJSONSerialization JSONObjectWithData:readyData options:0 error:nil];
    if (![ready isKindOfClass:NSDictionary.class]
        || ![ready[@"version"] isKindOfClass:NSNumber.class]
        || ![ready[@"time"] isKindOfClass:NSNumber.class]
        || [ready[@"version"] integerValue] != 1
        || fabs(NSDate.date.timeIntervalSince1970 * 1000 - [ready[@"time"] doubleValue]) > 2000) return nil;
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSMutableDictionary *request = [@{@"id":identifier, @"phase":phase,
        @"pid":@(pid), @"createdAt":@(NSDate.date.timeIntervalSince1970 * 1000)} mutableCopy];
    if (documentId != nil) request[@"documentId"] = documentId;
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (![data writeToFile:[directory stringByAppendingPathComponent:@"request.json"] atomically:YES]) return nil;
    NSString *responsePath = [directory stringByAppendingPathComponent:@"response.json"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.25];
    while (deadline.timeIntervalSinceNow > 0) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:responsePath error:nil];
        if ([attributes fileSize] <= 32768) {
            NSData *responseData = [NSData dataWithContentsOfFile:responsePath];
            id result = responseData.length > 0 && responseData.length <= 32768
                ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
            if ([result isKindOfClass:NSDictionary.class] && [result[@"id"] isEqual:identifier]
                && [result[@"phase"] isEqual:phase]
                && [result[@"pid"] isKindOfClass:NSNumber.class] && [result[@"pid"] intValue] == pid
                && [result[@"eligible"] isKindOfClass:NSNumber.class]) {
                [NSFileManager.defaultManager removeItemAtPath:responsePath error:nil];
                return [result[@"eligible"] boolValue] ? result : nil;
            }
        }
        [NSThread sleepForTimeInterval:0.02]; // Called exclusively by the background generic probe.
    }
    return nil;
}
@end
