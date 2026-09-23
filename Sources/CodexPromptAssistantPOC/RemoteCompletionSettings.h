#import <Foundation/Foundation.h>

@class CPAKeychainStore;
@class CPARemoteAPIKeyFileStore;

NS_ASSUME_NONNULL_BEGIN

@interface CPARemoteCompletionSettings : NSObject

@property(nonatomic, strong, readonly) NSURL *baseURL;
@property(nonatomic) BOOL onlineOnly;
@property(nonatomic, readonly, getter=isConfigured) BOOL configured;
@property(nonatomic, getter=isPaused) BOOL paused;
@property(nonatomic, getter=isLocalPaused) BOOL localPaused;
/// Independently pauses history expression lookup without disabling either model.
@property(nonatomic) BOOL expressionLibraryPaused;
@property(nonatomic, copy, readonly) NSString *preferredModel;

- (instancetype)initWithKeychainStore:(CPAKeychainStore *)keychainStore
    userDefaults:(NSUserDefaults *)userDefaults;
- (instancetype)initWithAPIKeyFileStore:(CPARemoteAPIKeyFileStore *)fileStore
    userDefaults:(NSUserDefaults *)userDefaults;
- (instancetype)init;

- (nullable NSString *)apiKey:(NSError **)error;
- (BOOL)saveAPIKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
