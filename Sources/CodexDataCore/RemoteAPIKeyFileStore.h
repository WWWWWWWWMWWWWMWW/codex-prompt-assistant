#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stores the remote API key in an owner-only encrypted file without invoking Keychain UI.
@interface CPARemoteAPIKeyFileStore : NSObject

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL;
- (nullable NSData *)keyData:(NSError **)error;
- (BOOL)storeKeyData:(NSData *)keyData error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
