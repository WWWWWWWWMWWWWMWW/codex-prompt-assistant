#import "RemoteCompletionSettings.h"

#import "../CodexDataCore/KeychainStore.h"
#import "../CodexDataCore/RemoteAPIKeyFileStore.h"

static NSString *const CPARemoteKeychainService =
    @"local.codex.prompt-assistant.remote";
static NSString *const CPARemoteKeychainAccount = @"api-key-v2";
static NSString *const CPARemotePreferredModelDefaultsKey =
    @"remote-completion.preferred-model";
static NSString *const CPARemoteConfiguredDefaultsKey =
    @"remote-completion.configured-v3";
static NSString *const CPARemoteDefaultModel = @"gpt-5.6-terra";
static NSString *const CPALegacyFastModel = @"4.1-nano";
static NSString *const CPARemoteSettingsErrorDomain =
    @"local.codex.prompt-assistant.remote-settings";

@interface CPARemoteCompletionSettings ()
@property(nonatomic, strong) CPAKeychainStore *keychainStore;
@property(nonatomic, strong) CPARemoteAPIKeyFileStore *fileStore;
@property(nonatomic, strong) NSUserDefaults *userDefaults;
@property(nonatomic, strong, readwrite) NSURL *baseURL;
- (instancetype)initWithKeychainStore:(CPAKeychainStore *)keychainStore
    fileStore:(CPARemoteAPIKeyFileStore *)fileStore
    userDefaults:(NSUserDefaults *)userDefaults NS_DESIGNATED_INITIALIZER;
@end

@implementation CPARemoteCompletionSettings

- (instancetype)init {
    NSString *home = NSHomeDirectory();
    NSURL *applicationSupport = [NSURL fileURLWithPath:
        [home stringByAppendingPathComponent:@"Library/Application Support"]
        isDirectory:YES];
    NSURL *directory = [applicationSupport
        URLByAppendingPathComponent:@"CodexPromptAssistant" isDirectory:YES];
    self = [self initWithAPIKeyFileStore:[[CPARemoteAPIKeyFileStore alloc]
        initWithDirectoryURL:directory]
        userDefaults:NSUserDefaults.standardUserDefaults];
    if (self) _onlineOnly = YES;
    return self;
}

- (instancetype)initWithKeychainStore:(CPAKeychainStore *)keychainStore
    userDefaults:(NSUserDefaults *)userDefaults {
    return [self initWithKeychainStore:keychainStore fileStore:nil
        userDefaults:userDefaults];
}

- (instancetype)initWithAPIKeyFileStore:(CPARemoteAPIKeyFileStore *)fileStore
    userDefaults:(NSUserDefaults *)userDefaults {
    return [self initWithKeychainStore:nil fileStore:fileStore
        userDefaults:userDefaults];
}

- (instancetype)initWithKeychainStore:(CPAKeychainStore *)keychainStore
    fileStore:(CPARemoteAPIKeyFileStore *)fileStore
    userDefaults:(NSUserDefaults *)userDefaults {
    self = [super init];
    if (self != nil) {
        _keychainStore = keychainStore;
        _fileStore = fileStore;
        _userDefaults = userDefaults;
        _baseURL = [NSURL URLWithString:@"https://sapi-ai.hortorgames.com/v1"];
        // No saved choice and no service: start offline. Persist before configuration
        // so saving a key alone cannot implicitly grant online completion.
        // Explicit choices and configured legacy users retain their existing behavior.
        if ([_userDefaults objectForKey:@"remote-completion.paused"] == nil &&
            ![_userDefaults boolForKey:CPARemoteConfiguredDefaultsKey]) {
            [_userDefaults setBool:YES forKey:@"remote-completion.paused"];
        }
    }
    return self;
}

- (BOOL)isConfigured {
    return [self.userDefaults boolForKey:CPARemoteConfiguredDefaultsKey];
}

- (BOOL)isPaused {
    return [self.userDefaults boolForKey:@"remote-completion.paused"];
}

- (void)setPaused:(BOOL)paused {
    [self.userDefaults setBool:paused forKey:@"remote-completion.paused"];
}

- (BOOL)isLocalPaused {
    return self.onlineOnly || [self.userDefaults boolForKey:@"local-completion.paused"];
}

- (void)setLocalPaused:(BOOL)paused {
    [self.userDefaults setBool:paused forKey:@"local-completion.paused"];
}

- (BOOL)expressionLibraryPaused {
    return self.onlineOnly || [self.userDefaults boolForKey:@"expression-library.paused"];
}

- (void)setExpressionLibraryPaused:(BOOL)paused {
    [self.userDefaults setBool:paused forKey:@"expression-library.paused"];
}

- (NSString *)preferredModel {
    id value = [self.userDefaults objectForKey:CPARemotePreferredModelDefaultsKey];
    if (![value isKindOfClass:NSString.class]) {
        return CPARemoteDefaultModel;
    }
    NSString *model = [self normalizedValue:value];
    if (model.length == 0) {
        return CPARemoteDefaultModel;
    }
    // 4.1-nano was an earlier latency experiment. Migrate that implicit
    // default back to the requested GPT-5.6 series.
    if ([model isEqualToString:CPALegacyFastModel]) {
        return CPARemoteDefaultModel;
    }
    return model;
}

- (NSString *)apiKey:(NSError **)error {
    NSData *data = self.fileStore != nil
        ? [self.fileStore keyData:error]
        : [self.keychainStore keyDataForService:CPARemoteKeychainService
            account:CPARemoteKeychainAccount error:error];
    if (data == nil) {
        return nil;
    }
    NSString *value = [[NSString alloc] initWithData:data
        encoding:NSUTF8StringEncoding];
    NSString *normalized = [self normalizedValue:value ?: @""];
    if (normalized.length == 0 && error != NULL) {
        *error = [self errorWithDescription:@"Stored API key is invalid"];
    }
    return normalized.length > 0 ? normalized : nil;
}

- (BOOL)saveAPIKey:(NSString *)apiKey
    preferredModel:(NSString *)preferredModel
    error:(NSError **)error {
    NSString *normalizedKey = [self normalizedValue:apiKey];
    if (normalizedKey.length > 0) {
        NSData *data = [normalizedKey dataUsingEncoding:NSUTF8StringEncoding];
        BOOL stored = self.fileStore != nil
            ? [self.fileStore storeKeyData:data error:error]
            : [self.keychainStore storeKeyData:data
                service:CPARemoteKeychainService account:CPARemoteKeychainAccount
                error:error];
        if (data == nil || !stored) {
            return NO;
        }
        [self.userDefaults setBool:YES forKey:CPARemoteConfiguredDefaultsKey];
    } else {
        if (!self.configured) {
            if (error != NULL) {
                *error = [self errorWithDescription:@"API key is required"];
            }
            return NO;
        }
    }
    NSString *model = [self normalizedValue:preferredModel];
    if (model.length > 0) {
        [self.userDefaults setObject:model forKey:CPARemotePreferredModelDefaultsKey];
    } else {
        [self.userDefaults removeObjectForKey:CPARemotePreferredModelDefaultsKey];
    }
    return YES;
}

- (NSString *)normalizedValue:(NSString *)value {
    return [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSError *)errorWithDescription:(NSString *)description {
    return [NSError errorWithDomain:CPARemoteSettingsErrorDomain code:1
        userInfo:@{NSLocalizedDescriptionKey: description}];
}

@end
