#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/KeychainStore.h"
#import "../../Sources/CodexDataCore/MessageCrypto.h"

static const char *ActionUsage = "usage: CryptoProbe <create|verify|delete> <service>\n";

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "%s", ActionUsage);
            return 2;
        }
        NSString *action = [NSString stringWithUTF8String:argv[1]];
        NSString *service = [NSString stringWithUTF8String:argv[2]];
        NSString *account = @"database-master-key";
        CPAKeychainStore *keychain = [[CPAKeychainStore alloc] init];
        NSError *error = nil;

        if ([action isEqualToString:@"create"]) {
            NSData *key = [[[CPAMessageCrypto alloc] init] generateRandomMasterKey:&error];
            if (key == nil || ![keychain storeKeyData:key
                    service:service account:account error:&error]) {
                fprintf(stderr, "create=false error=%s\n",
                    error.localizedDescription.UTF8String);
                return 1;
            }
            printf("create=true key_bytes=%lu\n", (unsigned long)key.length);
            return 0;
        }
        if ([action isEqualToString:@"verify"]) {
            NSData *key = [keychain keyDataForService:service account:account error:&error];
            if (key.length != 64 || error != nil) {
                fprintf(stderr, "verify=false error=%s\n",
                    (error.localizedDescription ?: @"missing key").UTF8String);
                return 1;
            }
            printf("verify=true key_bytes=%lu\n", (unsigned long)key.length);
            return 0;
        }
        if ([action isEqualToString:@"delete"]) {
            if (![keychain deleteKeyForService:service account:account error:&error]) {
                fprintf(stderr, "delete=false error=%s\n",
                    error.localizedDescription.UTF8String);
                return 1;
            }
            printf("delete=true\n");
            return 0;
        }

        fprintf(stderr, "%s", ActionUsage);
        return 2;
    }
}
