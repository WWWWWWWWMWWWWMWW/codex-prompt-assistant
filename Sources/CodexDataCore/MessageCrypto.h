#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPAMessageCrypto : NSObject

- (nullable NSData *)generateRandomMasterKey:(NSError **)error;
- (nullable NSData *)encryptData:(NSData *)plaintext
    masterKey:(NSData *)masterKey
    error:(NSError **)error;
- (nullable NSData *)decryptEnvelope:(NSData *)envelope
    masterKey:(NSData *)masterKey
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
