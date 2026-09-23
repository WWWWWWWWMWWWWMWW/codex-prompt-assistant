#import "KeychainStore.h"

#import <LocalAuthentication/LocalAuthentication.h>
#import <Security/Security.h>

static NSString * const CPAKeychainStoreErrorDomain = @"CPAKeychainStoreErrorDomain";

static void CPASetKeychainError(NSError **error, OSStatus status) {
    if (error != NULL) {
        NSString *message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
        *error = [NSError errorWithDomain:CPAKeychainStoreErrorDomain
            code:status
            userInfo:@{NSLocalizedDescriptionKey: message ?: @"Keychain operation failed"}];
    }
}

@interface CPAKeychainStore ()
- (nullable SecAccessRef)copyTrustedAccess:(NSError **)error CF_RETURNS_RETAINED;
- (NSMutableDictionary *)noninteractiveQueryForIdentity:(NSDictionary *)identity;
@end

@implementation CPAKeychainStore

- (BOOL)storeKeyData:(NSData *)keyData
    service:(NSString *)service
    account:(NSString *)account
    error:(NSError **)error {
    NSDictionary *identity = [self identityForService:service account:account];
    SecAccessRef access = [self copyTrustedAccess:error];
    if (access == NULL) {
        return NO;
    }
    NSMutableDictionary *updateQuery = [self noninteractiveQueryForIdentity:identity];
    NSDictionary *updatedAttributes = @{
        (__bridge id)kSecValueData: keyData,
        (__bridge id)kSecAttrAccess: (__bridge id)access,
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)updateQuery,
        (__bridge CFDictionaryRef)updatedAttributes);
    if (status == errSecSuccess) {
        CFRelease(access);
        return YES;
    }
    if (status != errSecItemNotFound) {
        CFRelease(access);
        CPASetKeychainError(error, status);
        return NO;
    }

    NSMutableDictionary *item = [identity mutableCopy];
    item[(__bridge id)kSecValueData] = keyData;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    item[(__bridge id)kSecAttrAccess] = (__bridge id)access;
    status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    CFRelease(access);
    if (status != errSecSuccess) {
        CPASetKeychainError(error, status);
        return NO;
    }
    return YES;
}

- (NSData *)keyDataForService:(NSString *)service
    account:(NSString *)account
    error:(NSError **)error {
    NSMutableDictionary *query = [self noninteractiveQueryForIdentity:
        [self identityForService:service account:account]];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        return nil;
    }
    if (status != errSecSuccess || result == NULL) {
        CPASetKeychainError(error, status);
        if (result != NULL) {
            CFRelease(result);
        }
        return nil;
    }
    return CFBridgingRelease(result);
}

- (BOOL)deleteKeyForService:(NSString *)service
    account:(NSString *)account
    error:(NSError **)error {
    NSMutableDictionary *query = [self noninteractiveQueryForIdentity:
        [self identityForService:service account:account]];
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status == errSecSuccess || status == errSecItemNotFound) {
        return YES;
    }
    CPASetKeychainError(error, status);
    return NO;
}

- (SecAccessRef)copyTrustedAccess:(NSError **)error {
    NSString *executablePath = NSBundle.mainBundle.executablePath;
    if (executablePath.length == 0) {
        CPASetKeychainError(error, errSecParam);
        return NULL;
    }
    SecTrustedApplicationRef trustedApplication = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = SecTrustedApplicationCreateFromPath(
        executablePath.fileSystemRepresentation,
        &trustedApplication
    );
    if (status != errSecSuccess || trustedApplication == NULL) {
        CPASetKeychainError(error, status);
        return NULL;
    }
    const void *values[] = {trustedApplication};
    CFArrayRef trustedApplications = CFArrayCreate(
        kCFAllocatorDefault,
        values,
        1,
        &kCFTypeArrayCallBacks
    );
    SecAccessRef access = NULL;
    status = SecAccessCreate(
        CFSTR("Codex Prompt Assistant"),
        trustedApplications,
        &access
    );
#pragma clang diagnostic pop
    CFRelease(trustedApplications);
    CFRelease(trustedApplication);
    if (status != errSecSuccess || access == NULL) {
        CPASetKeychainError(error, status);
        if (access != NULL) {
            CFRelease(access);
        }
        return NULL;
    }
    return access;
}

- (NSMutableDictionary *)noninteractiveQueryForIdentity:(NSDictionary *)identity {
    NSMutableDictionary *query = [identity mutableCopy];
    LAContext *context = [[LAContext alloc] init];
    context.interactionNotAllowed = YES;
    query[(__bridge id)kSecUseAuthenticationContext] = context;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    query[(__bridge id)kSecUseAuthenticationUI] =
        (__bridge id)kSecUseAuthenticationUIFail;
#pragma clang diagnostic pop
    return query;
}

- (NSDictionary *)identityForService:(NSString *)service account:(NSString *)account {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecAttrSynchronizable: @NO,
    };
}

@end
