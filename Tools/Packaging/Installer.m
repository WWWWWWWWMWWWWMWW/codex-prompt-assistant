#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import "../../Sources/CodexDataCore/RemoteAPIKeyFileStore.h"
#import "../../Sources/CodexPromptAssistantPOC/OnlineScopeDefaults.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

static BOOL Testing = NO;
static NSString *const AppName = @"CodexPromptAssistantPOC.app";
static NSString *const AppID = @"local.codex.prompt-assistant-poc";
static NSFileManager *FM(void) { return NSFileManager.defaultManager; }
static BOOL Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"续言安装" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *SHA(NSData *data) {
    if (!data || data.length > UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}
static BOOL PlainDirectory(NSURL *url) {
    struct stat st;
    return lstat(url.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == getuid();
}
static BOOL Exists(NSURL *url) {
    struct stat st; return lstat(url.fileSystemRepresentation, &st) == 0;
}
static NSString *CanonicalPath(NSURL *url) {
    char *value = realpath(url.fileSystemRepresentation, NULL);
    if (!value) return nil;
    NSString *result = [NSString stringWithUTF8String:value];free(value);return result;
}
static BOOL Verify(NSURL *app, NSArray *manifest, NSError **error) {
    if (!manifest.count) return Fail(error, @"安装包校验信息缺失，请重新获取安装包。");
    NSString *rootPath = CanonicalPath(app);
    if (!rootPath) return Fail(error, @"应用路径不可用。");
    NSMutableDictionary *actual = [NSMutableDictionary dictionary];
    NSMutableArray<NSURL *> *paths = [NSMutableArray arrayWithObject:app];
    __block BOOL enumerationFailed = NO;
    NSDirectoryEnumerator *enumerator = [FM() enumeratorAtURL:app includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *failure) { (void)url; (void)failure; enumerationFailed = YES; return NO; }];
    for (NSURL *url in enumerator) [paths addObject:url];
    if (enumerationFailed) return Fail(error, @"无法完整读取应用文件。");
    for (NSURL *url in paths) {
        struct stat st;
        if (lstat(url.fileSystemRepresentation, &st) != 0 || (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)))
            return Fail(error, @"应用包含无法验证的文件或链接，未执行安装。");
        NSString *path = CanonicalPath(url);
        if (![path isEqual:rootPath] && ![path hasPrefix:[rootPath stringByAppendingString:@"/"]])
            return Fail(error, @"应用文件路径异常。");
        NSString *relative = [path isEqual:rootPath] ? @"." : [path substringFromIndex:rootPath.length + 1];
        NSMutableDictionary *row = [@{@"path":relative, @"type":S_ISDIR(st.st_mode) ? @"directory" : @"file",
            @"mode":@(st.st_mode & 0777)} mutableCopy];
        if (S_ISREG(st.st_mode)) {
            NSString *digest = SHA([NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error]);
            if (!digest) return Fail(error, @"无法读取应用文件，请重新获取安装包。");
            row[@"sha256"] = digest;
        }
        actual[relative] = row;
    }
    if (actual.count != manifest.count) return Fail(error, @"应用文件不完整或版本不同，现有文件保持原样。");
    for (NSDictionary *row in manifest)
        if (![actual[row[@"path"]] isEqual:row]) {
            if (Testing) fprintf(stderr,"Manifest mismatch: %s expected=%s actual=%s\n",[row[@"path"] UTF8String],row.description.UTF8String,[actual[row[@"path"]] description].UTF8String);
            return Fail(error, @"应用文件校验不一致，现有文件保持原样。");
        }
    SecStaticCodeRef code = NULL; SecRequirementRef requirement = NULL;
    NSString *rule = [NSString stringWithFormat:@"identifier \"%@\"", AppID];
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)app, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecRequirementCreateWithString((__bridge CFStringRef)rule, kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code,
        kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return status == errSecSuccess ? YES : Fail(error, @"应用签名验证失败，未执行安装。");
}

static NSArray *PreviousManifest(void) {
    NSData *data = [NSData dataWithContentsOfURL:[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"previous-manifest.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
static BOOL AssistantIsRunning(void) {
    return !Testing && [NSRunningApplication runningApplicationsWithBundleIdentifier:AppID].count > 0;
}
// Scope is a new installation, exact reuse, or one approved previous payload.
// Existing helper must exit normally before replacement; no service or model edits.
static BOOL Install(NSURL *payload, NSURL *userHome, NSArray *manifest, BOOL *alreadyInstalled, NSError **error) {
    if (alreadyInstalled) *alreadyInstalled = NO;
    if (AssistantIsRunning()) return Fail(error, @"请先从菜单栏退出续言，再点“安装并打开”。安装器不会结束其他应用或本地模型。");
    if (!Verify(payload, manifest, error)) return NO;
    if (![userHome.path isEqual:userHome.URLByResolvingSymlinksInPath.path] || !PlainDirectory(userHome))
        return Fail(error, @"用户目录无法安全确认，未执行安装。");
    NSURL *applications = [userHome URLByAppendingPathComponent:@"Applications" isDirectory:YES];
    if (!Exists(applications) && ![FM() createDirectoryAtURL:applications withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0755} error:error]) return NO;
    if (!PlainDirectory(applications)) return Fail(error, @"应用程序目录是链接或不可用，未执行安装。");
    NSURL *lockURL = [applications URLByAppendingPathComponent:@".codex-prompt-assistant-install.lock"];
    int lock = open(lockURL.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    struct stat lockStat;
    if (lock < 0) return Fail(error, @"无法创建安装锁，请检查目录权限。");
    if (fstat(lock, &lockStat) != 0 || !S_ISREG(lockStat.st_mode) || lockStat.st_uid != getuid()
        || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        close(lock); return Fail(error, @"另一个安装正在进行，或安装锁不可用。请稍后重试。");
    }
    NSURL *destination = [applications URLByAppendingPathComponent:AppName isDirectory:YES];
    NSURL *stage = nil;
    BOOL success = NO;
    @try {
        if (Exists(destination)) {
            if (Verify(destination, manifest, NULL)) {
                if (alreadyInstalled) *alreadyInstalled = YES;
                success = YES;
            } else if (Verify(destination, PreviousManifest(), NULL)) {
                stage = [applications URLByAppendingPathComponent:[@".cpa-install-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
                if ([FM() createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) {
                    NSURL *stagedApp = [stage URLByAppendingPathComponent:AppName];
                    NSURL *backup = [applications URLByAppendingPathComponent:[@".cpa-upgrade-backup-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                    if ([FM() copyItemAtURL:payload toURL:stagedApp error:error] && Verify(stagedApp, manifest, error)
                        && [FM() createDirectoryAtURL:backup withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) {
                        NSURL *previous = [backup URLByAppendingPathComponent:AppName];
                        // Recheck immediately before atomic exchange. Keep original bytes for rollback.
                        if (!AssistantIsRunning() && Verify(destination, PreviousManifest(), error)
                            && renamex_np(stagedApp.fileSystemRepresentation,destination.fileSystemRepresentation,RENAME_SWAP) == 0) {
                            if (Verify(destination,manifest,error)
                                && renamex_np(stagedApp.fileSystemRepresentation,previous.fileSystemRepresentation,RENAME_EXCL) == 0) success = YES;
                            else {
                                // Never remove the old app if restoring it fails.
                                if (renamex_np(stagedApp.fileSystemRepresentation,destination.fileSystemRepresentation,RENAME_SWAP) != 0) {
                                    stage = nil;
                                    Fail(error, @"恢复旧版失败。升级前文件已保留在用户应用程序目录的 .cpa-install- 文件夹，请勿删除。");
                                }
                            }
                        } else Fail(error, @"旧版仍在运行或安装位置发生变化，请先退出续言后重试。");
                    }
                }
            } else Fail(error, @"已有版本不在此安装包支持的升级范围内，现有文件保持原样。");
        } else {
            stage = [applications URLByAppendingPathComponent:[@".cpa-install-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
            if ([FM() createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) {
                NSURL *stagedApp = [stage URLByAppendingPathComponent:AppName isDirectory:YES];
                if ([FM() copyItemAtURL:payload toURL:stagedApp error:error] && Verify(stagedApp, manifest, error)) {
                    // Atomic, exclusive rename: even a concurrent destination cannot be overwritten.
                    if (renamex_np(stagedApp.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_EXCL) != 0)
                        Fail(error, @"安装位置已被占用或无法写入，未覆盖现有应用。");
                    else success = Verify(destination, manifest, error);
                }
            }
        }
    } @finally {
        if (stage) [FM() removeItemAtURL:stage error:NULL];
        flock(lock, LOCK_UN); close(lock);
    }
    return success;
}

static NSURL *Payload(void) { return [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:AppName]; }
static NSArray *Manifest(void) {
    NSData *data = [NSData dataWithContentsOfURL:[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"payload-manifest.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *NormalizedKey(NSString *key) {
    return [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static BOOL ValidateKey(NSString *key, NSError **error) {
    NSString *value = NormalizedKey(key);
    return value.length > 0 && value.length <= 4096
        && [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound
        ? YES : Fail(error, @"请输入有效格式的 API Key（不能为空或包含空格）。");
}
static BOOL SaveKey(NSString *key, NSURL *directory, NSError **error) {
    if (!ValidateKey(key,error)) return NO;
    CPARemoteAPIKeyFileStore *store = [[CPARemoteAPIKeyFileStore alloc] initWithDirectoryURL:directory];
    if (![store storeKeyData:[NormalizedKey(key) dataUsingEncoding:NSUTF8StringEncoding] error:NULL])
        return Fail(error,@"应用已安装，但 Key 未能保存。请检查用户目录权限后重试；不要发送 Key 给他人。");
    return YES;
}

@interface InstallerDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *status;
@property NSButton *button;
@property NSSecureTextField *keyField;
@end
@implementation InstallerDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
    NSMenu *menu = [NSMenu new]; NSMenuItem *item = [NSMenuItem new]; NSMenu *application = [NSMenu new];
    [application addItemWithTitle:@"退出安装器" action:@selector(terminate:) keyEquivalent:@"q"];
    item.submenu = application; [menu addItem:item];
    NSMenuItem *editRoot = [NSMenuItem new]; NSMenu *edit = [[NSMenu alloc] initWithTitle:@"编辑"];
    [edit addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editRoot.submenu = edit; [menu addItem:editRoot]; NSApp.mainMenu = menu;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,540,420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"安装续言"; self.window.releasedWhenClosed = NO;
    NSView *content = self.window.contentView;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(32,315,64,64)];
    icon.image = NSApp.applicationIconImage; [content addSubview:icon];
    NSTextField *title = [NSTextField labelWithString:@"续言"];
    title.font = [NSFont systemFontOfSize:29 weight:NSFontWeightSemibold];title.frame = NSMakeRect(112,343,380,38);[content addSubview:title];
    NSString *packageVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSTextField *version = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ · Apple 芯片 · macOS 15 及以上", packageVersion]];
    version.textColor = NSColor.secondaryLabelColor;version.frame = NSMakeRect(113,317,390,22);[content addSubview:version];
    NSTextField *body = [NSTextField wrappingLabelWithString:@"填写 API Key 后安装到当前用户的“应用程序”目录。\n默认选择 Codex 和 WorkBuddy；安装后允许辅助功能即可使用。"];
    body.font = [NSFont systemFontOfSize:14];body.frame = NSMakeRect(32,243,476,60);[content addSubview:body];
    NSTextField *keyLabel = [NSTextField labelWithString:@"API Key（必填）"];
    keyLabel.frame = NSMakeRect(32,215,476,22); [content addSubview:keyLabel];
    self.keyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(32,179,476,28)];
    self.keyField.placeholderString = @"输入 sapi-ai.hortorgames.com 的 API Key";
    self.keyField.accessibilityLabel = @"API Key（必填）"; [content addSubview:self.keyField];
    NSTextField *hint = [NSTextField wrappingLabelWithString:@"Key 加密保存在本机，不回显。安装不验证服务额度；其他服务的 Key 不通用。已有版本请先从菜单栏退出续言。"];
    hint.font = [NSFont systemFontOfSize:12]; hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect(32,125,476,46); [content addSubview:hint];
    self.status = [NSTextField wrappingLabelWithString:@"首次默认勾选 Codex 和 WorkBuddy，其输入及可用任务上下文将用于在线续写；已有选择保留，可在设置中取消。"];
    self.status.textColor = NSColor.secondaryLabelColor;self.status.frame = NSMakeRect(32,67,476,50);[content addSubview:self.status];
    self.button = [NSButton buttonWithTitle:@"安装并打开" target:self action:@selector(installAndOpen:)];
    self.button.bezelStyle = NSBezelStyleRounded;self.button.keyEquivalent = @"\r";
    self.button.frame = NSMakeRect(340,25,168,34);[content addSubview:self.button];
    [self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)installAndOpen:(id)sender {
    (void)sender;
    NSString *key = [self.keyField.stringValue copy];
    NSError *validation = nil;
    if (!ValidateKey(key,&validation)) { self.status.stringValue = validation.localizedDescription; [self.window makeFirstResponder:self.keyField]; return; }
    if (AssistantIsRunning()) { self.status.stringValue = @"请先从菜单栏退出续言，再安装。"; return; }
    self.button.enabled = NO; self.keyField.enabled = NO; self.status.stringValue = @"正在检查并安装…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error = nil;BOOL existing = NO;
        NSURL *userHome = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
        BOOL okay = Install(Payload(), userHome, Manifest(), &existing, &error);
        if (okay) {
            NSURL *directory = [userHome URLByAppendingPathComponent:@"Library/Application Support/CodexPromptAssistant"];
            okay = SaveKey(key,directory,&error);
            if (okay) {
                CFStringRef domain = (__bridge CFStringRef)AppID;
                CFPropertyListRef previous = CFPreferencesCopyAppValue(CFSTR("remote-completion.configured-v3"),domain);
                if (!previous) CFPreferencesSetAppValue(CFSTR("remote-completion.paused"),kCFBooleanFalse,domain);
                if (previous) CFRelease(previous);
                CFPreferencesSetAppValue(CFSTR("remote-completion.configured-v3"),kCFBooleanTrue,domain);
                id scopes = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("OnlineCompletionScopes.v1"),domain));
                CFPreferencesSetAppValue(CFSTR("OnlineCompletionScopes.v1"),
                    (__bridge CFPropertyListRef)CPAOnlineScopesWithInstallationDefaults(scopes),domain);
                if (!CFPreferencesAppSynchronize(domain)) okay = Fail(&error,@"Key 已保存，但配置同步失败。请重试安装。");
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.button.enabled = YES; self.keyField.enabled = YES;
            if (!okay) { self.status.stringValue = error.localizedDescription ?: @"安装失败，请重新获取安装包。";return; }
            self.keyField.stringValue = @""; self.keyField.enabled = NO; self.button.enabled = NO;
            self.status.stringValue = existing ? @"此版本已安装，正在打开续言。" : @"安装完成，正在打开续言。";
            NSURL *installed = [[userHome URLByAppendingPathComponent:@"Applications"] URLByAppendingPathComponent:AppName];
            NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
            configuration.arguments = @[@"--preserve-resident-model", @"--open-remote-settings"];
            [NSWorkspace.sharedWorkspace openApplicationAtURL:installed configuration:configuration
                completionHandler:^(NSRunningApplication *app, NSError *openError) {
                    (void)app;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.status.stringValue = openError ? @"应用已安装，但未能打开。请在用户“应用程序”目录中打开续言。"
                            : @"已打开续言，可在设置中调整默认使用范围。可关闭安装器。";
                        self.button.title = @"安装完成";
                    });
                }];
        });
    });
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application { (void)application;return YES; }
@end

static int SelfTest(NSURL *previousPayload) {
    Testing = YES;
    NSURL *root = [[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[@"cpa-installer-test-" stringByAppendingString:NSUUID.UUID.UUIDString]] URLByResolvingSymlinksInPath];
    if (![FM() createDirectoryAtURL:root withIntermediateDirectories:NO attributes:nil error:NULL]) return 1;
    __block int failures = 0; __block int count = 0;
    void (^check)(BOOL, NSString *) = ^(BOOL okay, NSString *name) { count++;if (!okay) failures++;fprintf(stderr,"%s %s\n",okay?"PASS":"FAIL",name.UTF8String); };
    @try {
        NSArray *manifest = Manifest(); BOOL existing = NO; NSError *error = nil;
        NSDictionary *initial = CPAOnlineScopesWithInstallationDefaults(nil);
        check([initial[@"applications"] isEqual:@{@"com.openai.codex":@YES,@"com.tencent.workbuddy.mac":@YES}],@"fresh install selects only Codex and WorkBuddy");
        NSDictionary *custom = @{@"applications":@{@"com.openai.codex":@NO,@"com.apple.TextEdit":@YES},@"sites":@{@"example.test":@NO}};
        NSDictionary *merged = CPAOnlineScopesWithInstallationDefaults(custom);
        check([merged[@"applications"] isEqual:@{@"com.openai.codex":@NO,@"com.tencent.workbuddy.mac":@YES,@"com.apple.TextEdit":@YES}]
            && [merged[@"sites"] isEqual:custom[@"sites"]],@"upgrade preserves explicit selections and fills missing defaults");
        NSDictionary *off = @{@"applications":@{@"com.openai.codex":@NO,@"com.tencent.workbuddy.mac":@NO}};
        check([CPAOnlineScopesWithInstallationDefaults(off) isEqual:off],@"reinstall never reverses explicit deselection");
        check([CPAOnlineScopesWithInstallationDefaults(initial) isEqual:initial],@"installation defaults are idempotent");
        NSURL *keys = [root URLByAppendingPathComponent:@"isolated-keys"];
        check(!SaveKey(@" \n",keys,&error) && !Exists(keys),@"empty key rejected before writes");
        check(!ValidateKey(@"synthetic key",&error),@"key whitespace rejected");
        check(SaveKey(@" synthetic-installer-key ",keys,&error),@"synthetic key encrypted save");
        CPARemoteAPIKeyFileStore *store = [[CPARemoteAPIKeyFileStore alloc] initWithDirectoryURL:keys];
        check([[store keyData:NULL] isEqual:[@"synthetic-installer-key" dataUsingEncoding:NSUTF8StringEncoding]],@"app-compatible encrypted readback");
        NSData *envelope = [NSData dataWithContentsOfURL:[keys URLByAppendingPathComponent:@"remote-api-key-v1.bin"]];
        check([envelope rangeOfData:[@"synthetic-installer-key" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,envelope.length)].location == NSNotFound,@"no plaintext key file");
        struct stat keyStat; lstat([keys URLByAppendingPathComponent:@"remote-api-key-v1.bin"].fileSystemRepresentation,&keyStat);
        check((keyStat.st_mode & 0777) == 0600,@"key owner-only permissions");
        check(Verify(Payload(),manifest,&error),@"signed embedded payload");
        BOOL fresh = Install(Payload(),root,manifest,&existing,&error);
        if (!fresh) fprintf(stderr,"Fresh install error: %s; root=%s; canonical=%s\n",error.localizedDescription.UTF8String,root.path.UTF8String,root.URLByResolvingSymlinksInPath.path.UTF8String);
        check(fresh && !existing,@"fresh per-user install");
        NSURL *destination = [[root URLByAppendingPathComponent:@"Applications"] URLByAppendingPathComponent:AppName];
        struct stat before,after;lstat(destination.fileSystemRepresentation,&before);
        check(Install(Payload(),root,manifest,&existing,&error) && existing,@"same version reuse");
        lstat(destination.fileSystemRepresentation,&after);check(before.st_ino==after.st_ino,@"existing app not replaced");
        NSURL *extra = [destination URLByAppendingPathComponent:@"extra.txt"];
        [@"fixture" writeToURL:extra atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        check(!Install(Payload(),root,manifest,NULL,&error) && Exists(extra),@"different installation preserved");
        [FM() removeItemAtURL:extra error:NULL];
        NSURL *damaged = [root URLByAppendingPathComponent:@"damaged.app"];
        [FM() copyItemAtURL:Payload() toURL:damaged error:NULL];
        [FM() removeItemAtURL:[damaged URLByAppendingPathComponent:@"Contents/Info.plist"] error:NULL];
        check(!Install(damaged,root,manifest,NULL,&error),@"damaged payload rejected");
        [FM() removeItemAtURL:destination error:NULL];
        if (previousPayload) {
            check(Verify(previousPayload,PreviousManifest(),&error),@"approved old version verifies");
            [FM() copyItemAtURL:previousPayload toURL:destination error:NULL];
            check(Install(Payload(),root,manifest,&existing,&error) && !existing,@"old-to-new atomic upgrade");
            check(Verify(destination,manifest,&error),@"upgraded payload readback");
            NSUInteger backups = 0;
            NSURL *apps = [root URLByAppendingPathComponent:@"Applications"];
            for (NSString *entry in [FM() contentsOfDirectoryAtPath:apps.path error:NULL]) {
                if ([entry hasPrefix:@".cpa-upgrade-backup-"]) {
                    backups++;
                    check(Verify([[apps URLByAppendingPathComponent:entry] URLByAppendingPathComponent:AppName],PreviousManifest(),&error),@"old version backup exact bytes and signature");
                }
            }
            check(backups == 1,@"one preserved upgrade backup");
            [FM() removeItemAtURL:destination error:NULL];
        }
        [FM() createSymbolicLinkAtURL:destination withDestinationURL:Payload() error:NULL];
        check(!Install(Payload(),root,manifest,NULL,&error),@"destination symlink rejected");
        [FM() removeItemAtURL:destination error:NULL];
        NSURL *applications = [root URLByAppendingPathComponent:@"Applications"];
        NSURL *lockURL = [applications URLByAppendingPathComponent:@".codex-prompt-assistant-install.lock"];
        int lock = open(lockURL.fileSystemRepresentation,O_RDWR);flock(lock,LOCK_EX|LOCK_NB);
        check(!Install(Payload(),root,manifest,NULL,&error),@"concurrent install rejected");flock(lock,LOCK_UN);close(lock);
        [FM() removeItemAtURL:lockURL error:NULL];
        [FM() createSymbolicLinkAtURL:lockURL withDestinationURL:[root URLByAppendingPathComponent:@"lock-target"] error:NULL];
        check(!Install(Payload(),root,manifest,NULL,&error),@"lock symlink rejected");
        [FM() removeItemAtURL:applications error:NULL];
        [FM() createSymbolicLinkAtURL:applications withDestinationURL:root error:NULL];
        check(!Install(Payload(),root,manifest,NULL,&error),@"applications directory symlink rejected");
        check(!Install(Payload(),root,@[],NULL,&error),@"missing manifest rejected");
    } @finally { [FM() removeItemAtURL:root error:NULL]; }
    fprintf(stderr,"%d checks, %d failures; temporary directory only, no launch or services.\n",count,failures);
    return failures ? 1 : 0;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if ((argc==2 || argc==3) && strcmp(argv[1],"--self-test")==0)
            return SelfTest(argc==3 ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] : nil);
        if (argc!=1) return 2;
        NSApplication *app = NSApplication.sharedApplication;
        InstallerDelegate *delegate = [InstallerDelegate new];app.delegate = delegate;[app run];
    }
    return 0;
}
