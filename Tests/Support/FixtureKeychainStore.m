// Test-link replacement only. Never link this file into production tools/apps.
#import "../../Sources/CodexDataCore/KeychainStore.h"
#import <CommonCrypto/CommonDigest.h>
#import <unistd.h>

@implementation CPAKeychainStore
- (NSString *)fixturePathForService:(NSString *)service account:(NSString *)account
    error:(NSError **)error {
    NSString *root = NSProcessInfo.processInfo.environment[@"CPA_TEST_ROOT"];
    NSDictionary *attributes = root.length ? [NSFileManager.defaultManager
        attributesOfItemAtPath:root error:nil] : nil;
    BOOL testService = [service hasPrefix:@"local.codex.prompt-assistant.crypto-test."]
        || [service hasPrefix:@"local.codex.prompt-assistant.rebuild-test."];
    if (!testService || !root.isAbsolutePath
        || ![attributes[NSFileType] isEqual:NSFileTypeDirectory]
        || [attributes[NSFileOwnerAccountID] unsignedIntValue] != getuid()
        || [attributes[NSFilePosixPermissions] unsignedShortValue] != 0700) {
        if (error) *error = [NSError errorWithDomain:@"CPATestCredentials" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Private test root and fixture service required"}];
        return nil;
    }
    NSData *identity = [NSJSONSerialization dataWithJSONObject:@[service, account]
        options:0 error:error];
    if (!identity) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(identity.bytes, (CC_LONG)identity.length, digest);
    NSMutableString *name = [NSMutableString stringWithString:@"fixture-key-"];
    for (NSUInteger i=0; i<sizeof(digest); i++) [name appendFormat:@"%02x",digest[i]];
    return [root stringByAppendingPathComponent:name];
}
- (BOOL)storeKeyData:(NSData *)data service:(NSString *)service
    account:(NSString *)account error:(NSError **)error {
    NSString *path = [self fixturePathForService:service account:account error:error];
    if (!path) return NO;
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600}
        ofItemAtPath:path error:error];
}
- (NSData *)keyDataForService:(NSString *)service account:(NSString *)account
    error:(NSError **)error {
    NSString *path = [self fixturePathForService:service account:account error:error];
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [NSData dataWithContentsOfFile:path options:0 error:error];
}
- (BOOL)deleteKeyForService:(NSString *)service account:(NSString *)account
    error:(NSError **)error {
    NSString *path = [self fixturePathForService:service account:account error:error];
    if (!path) return NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    return [NSFileManager.defaultManager removeItemAtPath:path error:error];
}
@end
