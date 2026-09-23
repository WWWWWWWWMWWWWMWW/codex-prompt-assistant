#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/KeychainStore.h"
#import "../../Sources/CodexDataCore/MessageCrypto.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSData *SyntheticKey(uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:64];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        bytes[i] = (uint8_t)(seed + i);
    }
    return data;
}

int main(void) {
    @autoreleasepool {
        CPAMessageCrypto *crypto = [[CPAMessageCrypto alloc] init];
        NSData *masterKey = SyntheticKey(1);
        NSData *wrongKey = SyntheticKey(99);
        NSData *plaintext = [@"private local message" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;

        NSData *first = [crypto encryptData:plaintext masterKey:masterKey error:&error];
        Assert(first != nil && error == nil, @"合法明文应可加密");
        NSData *second = [crypto encryptData:plaintext masterKey:masterKey error:&error];
        Assert(second != nil && ![first isEqualToData:second], @"每次加密必须使用不同随机 IV");

        NSData *decrypted = [crypto decryptEnvelope:first masterKey:masterKey error:&error];
        Assert([decrypted isEqualToData:plaintext] && error == nil, @"正确密钥应还原原文");

        error = nil;
        Assert([crypto decryptEnvelope:first masterKey:wrongKey error:&error] == nil
                && error != nil,
            @"错误密钥必须失败");

        NSMutableData *tampered = [first mutableCopy];
        uint8_t *tamperedBytes = tampered.mutableBytes;
        tamperedBytes[24] ^= 0x01;
        error = nil;
        Assert([crypto decryptEnvelope:tampered masterKey:masterKey error:&error] == nil
                && error != nil,
            @"密文被篡改必须在解密前失败");

        error = nil;
        NSData *randomKey = [crypto generateRandomMasterKey:&error];
        Assert(randomKey.length == 64 && error == nil, @"主密钥必须是 64 个随机字节");

        NSString *service = [@"local.codex.prompt-assistant.crypto-test."
            stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *account = @"unit-test";
        CPAKeychainStore *keychain = [[CPAKeychainStore alloc] init];
        error = nil;
        Assert([keychain storeKeyData:randomKey service:service account:account error:&error]
                && error == nil,
            @"测试主密钥应可写入隔离凭据替身");
        CPAKeychainStore *newInstance = [[CPAKeychainStore alloc] init];
        NSData *reloaded = [newInstance keyDataForService:service account:account error:&error];
        Assert([reloaded isEqualToData:randomKey] && error == nil,
            @"新实例应可从隔离凭据替身读取同一密钥");
        Assert([keychain deleteKeyForService:service account:account error:&error]
                && error == nil,
            @"测试密钥应可清理");
        error = nil;
        Assert([keychain keyDataForService:service account:account error:&error] == nil
                && error == nil,
            @"删除后应返回未找到且不泄露错误细节");

        NSLog(@"PASS: CryptoEnvelopeTests");
    }
    return 0;
}
