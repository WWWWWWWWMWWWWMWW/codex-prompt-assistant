#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/KeychainStore.h"
#import "../../Sources/CodexPromptAssistantPOC/RemoteCompletionSettings.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

@interface CPAInMemoryKeychainStore : CPAKeychainStore
@property(nonatomic, copy) NSData *storedData;
@property(nonatomic, copy) NSString *capturedService;
@property(nonatomic, copy) NSString *capturedAccount;
@property(nonatomic) NSUInteger readCount;
@end

@implementation CPAInMemoryKeychainStore
- (BOOL)storeKeyData:(NSData *)keyData service:(NSString *)service
    account:(NSString *)account error:(NSError **)error {
    (void)error;
    self.storedData = keyData;
    self.capturedService = service;
    self.capturedAccount = account;
    return YES;
}
- (NSData *)keyDataForService:(NSString *)service account:(NSString *)account
    error:(NSError **)error {
    (void)error;
    self.readCount++;
    self.capturedService = service;
    self.capturedAccount = account;
    return self.storedData;
}
- (BOOL)deleteKeyForService:(NSString *)service account:(NSString *)account
    error:(NSError **)error {
    (void)error;
    self.capturedService = service;
    self.capturedAccount = account;
    self.storedData = nil;
    return YES;
}
@end

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"local.codex.prompt-assistant.settings-test."
            stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        CPAInMemoryKeychainStore *keychain = [[CPAInMemoryKeychainStore alloc] init];
        CPARemoteCompletionSettings *settings = [[CPARemoteCompletionSettings alloc]
            initWithKeychainStore:keychain userDefaults:defaults];
        Assert([settings.baseURL.absoluteString
            isEqualToString:@"https://sapi-ai.hortorgames.com/v1"],
            @"base URL should be fixed HTTPS endpoint");
        Assert(!settings.configured, @"settings should start unconfigured");
        Assert([settings.preferredModel isEqualToString:@"gpt-5.6-terra"],
            @"default completion model should use the faster GPT-5.6 variant");
        Assert(keychain.readCount == 0,
            @"startup configuration status must not read secret key data");

        Assert(settings.paused, @"unconfigured first use must default online completion to off");
        Assert([defaults objectForKey:@"remote-completion.paused"] != nil,
            @"first-use choice must persist before saving credentials");
        NSError *initialError = nil;
        Assert([settings saveAPIKey:@"synthetic-first-use-key" preferredModel:@"" error:&initialError],
            @"first-use service configuration saves independently");
        Assert(settings.paused, @"saving a service alone must not enable online completion");
        [defaults removePersistentDomainForName:suite];
        [defaults setBool:YES forKey:@"remote-completion.configured-v3"];
        settings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:keychain userDefaults:defaults];
        Assert(!settings.paused && [defaults objectForKey:@"remote-completion.paused"] == nil,
            @"configured legacy user keeps implicit enabled behavior without preference rewriting");
        for (NSNumber *configured in @[@NO, @YES]) {
            for (NSNumber *paused in @[@NO, @YES]) {
                [defaults setBool:configured.boolValue forKey:@"remote-completion.configured-v3"];
                [defaults setBool:paused.boolValue forKey:@"remote-completion.paused"];
                settings = [[CPARemoteCompletionSettings alloc] initWithKeychainStore:keychain userDefaults:defaults];
                Assert(settings.paused == paused.boolValue,
                    @"existing explicit online choice always wins, including unconfigured users");
            }
        }
        Assert(keychain.readCount == 0, @"default migration never reads credentials");
        [settings setPaused:YES];
        Assert(settings.paused && keychain.readCount == 0,
            @"networking can be disabled without credentials or reading secrets");
        CPARemoteCompletionSettings *reloadedSettings = [[CPARemoteCompletionSettings alloc]
            initWithKeychainStore:keychain userDefaults:defaults];
        Assert(reloadedSettings.paused, @"networking preference must persist across instances");
        [settings setPaused:NO];
        Assert(!reloadedSettings.paused, @"networking changes must be immediately observable");
        Assert(!settings.localPaused, @"local completion stays enabled for existing installations");
        for (NSUInteger mode = 0; mode < 4; mode++) {
            settings.localPaused = (mode & 1) != 0;
            settings.paused = (mode & 2) != 0;
            Assert(reloadedSettings.localPaused == ((mode & 1) != 0)
                && reloadedSettings.paused == ((mode & 2) != 0)
                && keychain.readCount == 0,
                @"all four provider combinations must persist independently without reading secrets");
        }
        settings.localPaused = NO;
        settings.paused = NO;
        Assert(!settings.expressionLibraryPaused, @"existing expression preference is preserved by default");
        settings.expressionLibraryPaused = YES;
        Assert(reloadedSettings.expressionLibraryPaused && !settings.localPaused && !settings.paused,
            @"expression pause persists independently from both model switches");
        reloadedSettings.expressionLibraryPaused = NO;
        Assert(!settings.expressionLibraryPaused, @"expression pause is reversible");

        NSError *error = nil;
        BOOL saved = [settings saveAPIKey:@"  new-test-key  "
            preferredModel:@"  chat-model  " error:&error];
        Assert(saved && error == nil, @"settings should save");
        Assert(settings.configured, @"saved key should configure completion");
        Assert(keychain.readCount == 0,
            @"configuration status after save must remain metadata-only");
        Assert([[settings apiKey:&error] isEqualToString:@"new-test-key"],
            @"key should round trip through secret store");
        Assert([settings.preferredModel isEqualToString:@"chat-model"],
            @"model should be normalized");
        Assert([keychain.capturedService isEqualToString:
            @"local.codex.prompt-assistant.remote"], @"remote service should be isolated");
        Assert([keychain.capturedAccount isEqualToString:@"api-key-v2"],
            @"remote key account should be versioned");
        NSDictionary *domain = [defaults persistentDomainForName:suite];
        Assert(![[domain.description lowercaseString] containsString:@"new-test-key"],
            @"API key must not enter user defaults");

        NSUInteger readsBeforeBlankSave = keychain.readCount;
        saved = [settings saveAPIKey:@"" preferredModel:@"new-model" error:&error];
        Assert(saved && keychain.readCount == readsBeforeBlankSave,
            @"blank key save should preserve configured secret without reading it");
        Assert([[settings apiKey:&error] isEqualToString:@"new-test-key"],
            @"blank key should preserve existing secret");
        Assert([settings.preferredModel isEqualToString:@"new-model"],
            @"model should still update");

        [defaults setObject:@"4.1-nano" forKey:@"remote-completion.preferred-model"];
        Assert([settings.preferredModel isEqualToString:@"gpt-5.6-terra"],
            @"legacy low-latency default should migrate to GPT-5.6");

        NSData *savedKey = [keychain.storedData copy];
        NSString *savedModel = [settings.preferredModel copy];
        NSUInteger reads = keychain.readCount;
        [settings setPaused:YES];
        [settings setPaused:NO];
        Assert([keychain.storedData isEqual:savedKey]
            && [settings.preferredModel isEqualToString:savedModel]
            && keychain.readCount == reads && settings.configured,
            @"network switch must preserve configured credentials/model without reading secrets");
        settings.localPaused = NO; settings.expressionLibraryPaused = NO;
        settings.onlineOnly = YES;
        Assert(settings.localPaused && settings.expressionLibraryPaused,
            @"online edition never uses local model or expressions even with legacy enabled flags");
        Assert(![defaults boolForKey:@"local-completion.paused"] && ![defaults boolForKey:@"expression-library.paused"],
            @"online-only runtime constraint does not overwrite rollback preferences");
        [defaults removePersistentDomainForName:suite];
        NSLog(@"PASS: RemoteCompletionSettingsTests");
    }
    return 0;
}
