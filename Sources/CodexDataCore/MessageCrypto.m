#import "MessageCrypto.h"

#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Security/Security.h>
#import <string.h>

static NSString * const CPAMessageCryptoErrorDomain = @"CPAMessageCryptoErrorDomain";
static const uint8_t CPAEnvelopeMagic[] = {'C', 'P', 'A', '1'};
static const NSUInteger CPAMasterKeyLength = 64;
static const NSUInteger CPAAESKeyLength = 32;
static const NSUInteger CPAIVLength = kCCBlockSizeAES128;
static const NSUInteger CPAMACLength = CC_SHA256_DIGEST_LENGTH;

static void CPASetMessageCryptoError(NSError **error, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPAMessageCryptoErrorDomain
            code:1
            userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

@implementation CPAMessageCrypto

- (NSData *)generateRandomMasterKey:(NSError **)error {
    NSMutableData *key = [NSMutableData dataWithLength:CPAMasterKeyLength];
    if (SecRandomCopyBytes(kSecRandomDefault, key.length, key.mutableBytes) != errSecSuccess) {
        CPASetMessageCryptoError(error, @"Unable to generate encryption key");
        return nil;
    }
    return key;
}

- (NSData *)encryptData:(NSData *)plaintext
    masterKey:(NSData *)masterKey
    error:(NSError **)error {
    if (![self validateMasterKey:masterKey error:error]) {
        return nil;
    }

    uint8_t iv[CPAIVLength];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(iv), iv) != errSecSuccess) {
        CPASetMessageCryptoError(error, @"Unable to generate encryption IV");
        return nil;
    }

    NSMutableData *ciphertext = [NSMutableData dataWithLength:
        plaintext.length + kCCBlockSizeAES128];
    size_t ciphertextLength = 0;
    const uint8_t *keyBytes = masterKey.bytes;
    CCCryptorStatus status = CCCrypt(kCCEncrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        keyBytes,
        CPAAESKeyLength,
        iv,
        plaintext.bytes,
        plaintext.length,
        ciphertext.mutableBytes,
        ciphertext.length,
        &ciphertextLength);
    if (status != kCCSuccess) {
        CPASetMessageCryptoError(error, @"Unable to encrypt message");
        return nil;
    }
    ciphertext.length = ciphertextLength;

    NSMutableData *envelope = [NSMutableData data];
    [envelope appendBytes:CPAEnvelopeMagic length:sizeof(CPAEnvelopeMagic)];
    [envelope appendBytes:iv length:sizeof(iv)];
    [envelope appendData:ciphertext];

    uint8_t mac[CPAMACLength];
    CCHmac(kCCHmacAlgSHA256,
        keyBytes + CPAAESKeyLength,
        CPAAESKeyLength,
        envelope.bytes,
        envelope.length,
        mac);
    [envelope appendBytes:mac length:sizeof(mac)];
    (void)memset_s(iv, sizeof(iv), 0, sizeof(iv));
    (void)memset_s(mac, sizeof(mac), 0, sizeof(mac));
    return envelope;
}

- (NSData *)decryptEnvelope:(NSData *)envelope
    masterKey:(NSData *)masterKey
    error:(NSError **)error {
    if (![self validateMasterKey:masterKey error:error]) {
        return nil;
    }
    NSUInteger minimumLength = sizeof(CPAEnvelopeMagic) + CPAIVLength
        + kCCBlockSizeAES128 + CPAMACLength;
    const uint8_t *envelopeBytes = envelope.bytes;
    if (envelope.length < minimumLength
        || timingsafe_bcmp(envelopeBytes, CPAEnvelopeMagic, sizeof(CPAEnvelopeMagic)) != 0) {
        CPASetMessageCryptoError(error, @"Unable to decrypt message envelope");
        return nil;
    }

    NSUInteger authenticatedLength = envelope.length - CPAMACLength;
    const uint8_t *actualMAC = envelopeBytes + authenticatedLength;
    const uint8_t *keyBytes = masterKey.bytes;
    uint8_t expectedMAC[CPAMACLength];
    CCHmac(kCCHmacAlgSHA256,
        keyBytes + CPAAESKeyLength,
        CPAAESKeyLength,
        envelopeBytes,
        authenticatedLength,
        expectedMAC);
    BOOL authentic = timingsafe_bcmp(expectedMAC, actualMAC, CPAMACLength) == 0;
    (void)memset_s(expectedMAC, sizeof(expectedMAC), 0, sizeof(expectedMAC));
    if (!authentic) {
        CPASetMessageCryptoError(error, @"Unable to decrypt message envelope");
        return nil;
    }

    const uint8_t *iv = envelopeBytes + sizeof(CPAEnvelopeMagic);
    const uint8_t *ciphertext = iv + CPAIVLength;
    NSUInteger ciphertextLength = authenticatedLength
        - sizeof(CPAEnvelopeMagic) - CPAIVLength;
    NSMutableData *plaintext = [NSMutableData dataWithLength:ciphertextLength];
    size_t plaintextLength = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        keyBytes,
        CPAAESKeyLength,
        iv,
        ciphertext,
        ciphertextLength,
        plaintext.mutableBytes,
        plaintext.length,
        &plaintextLength);
    if (status != kCCSuccess) {
        [plaintext resetBytesInRange:NSMakeRange(0, plaintext.length)];
        CPASetMessageCryptoError(error, @"Unable to decrypt message envelope");
        return nil;
    }
    plaintext.length = plaintextLength;
    return plaintext;
}

- (BOOL)validateMasterKey:(NSData *)masterKey error:(NSError **)error {
    if (masterKey.length == CPAMasterKeyLength) {
        return YES;
    }
    CPASetMessageCryptoError(error, @"Encryption key has invalid length");
    return NO;
}

@end
