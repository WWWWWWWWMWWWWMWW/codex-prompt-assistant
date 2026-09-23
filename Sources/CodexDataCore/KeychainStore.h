#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPAKeychainStore : NSObject

- (BOOL)storeKeyData:(NSData *)keyData
    service:(NSString *)service
    account:(NSString *)account
    error:(NSError **)error;
- (nullable NSData *)keyDataForService:(NSString *)service
    account:(NSString *)account
    error:(NSError **)error;
- (BOOL)deleteKeyForService:(NSString *)service
    account:(NSString *)account
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
