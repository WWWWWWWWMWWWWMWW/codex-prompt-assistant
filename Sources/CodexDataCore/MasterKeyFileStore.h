#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stores the local database key in an owner-only file without invoking Keychain UI.
@interface CPAMasterKeyFileStore : NSObject

- (instancetype)initWithURL:(NSURL *)url;
- (nullable NSData *)keyData:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
