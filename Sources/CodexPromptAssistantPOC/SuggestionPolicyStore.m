#import "SuggestionPolicyStore.h"

NSString *const CPASuggestionPolicyStoreDefaultsKey =
    @"SuggestionPolicyStore.v1";

static const NSInteger CPASuggestionPolicySchemaVersion = 1;

@interface CPASuggestionPolicyStore ()
@property(nonatomic, strong) NSUserDefaults *userDefaults;
@property(atomic, readwrite) NSUInteger ruleVersion;
@end

@implementation CPASuggestionPolicyStore

+ (NSArray<NSDictionary *> *)onlineScopeTargets {
    return @[
        @{@"bundle":@"com.apple.Stickies", @"host":@"", @"title":@"便笺（Stickies）"},
        @{@"bundle":@"com.apple.Terminal", @"host":@"", @"title":@"终端"},
        @{@"bundle":@"com.apple.TextEdit", @"host":@"", @"title":@"文本编辑"},
        @{@"bundle":@"com.apple.freeform", @"host":@"", @"title":@"无边记"},
        @{@"bundle":@"com.electron.lark", @"host":@"", @"title":@"飞书（含网页版）"},
        @{@"bundle":@"com.kingsoft.wpsoffice.mac", @"host":@"", @"title":@"WPS Office"},
        @{@"bundle":@"com.openai.codex", @"host":@"", @"title":@"Codex"},
        @{@"bundle":@"com.tencent.workbuddy.mac", @"host":@"", @"title":@"WorkBuddy"},
        @{@"bundle":@"com.tencent.codebuddy", @"host":@"", @"title":@"CodeBuddy"},
        @{@"bundle":@"com.tencent.xinWeChat", @"host":@"", @"title":@"微信"},
    ];
}
+ (BOOL)allowsOnlineScopeBundleIdentifier:(NSString *)bundle {
    for (NSDictionary *target in self.onlineScopeTargets)
        if ([target[@"bundle"] isEqual:bundle]) return YES;
    return NO;
}

- (instancetype)init {
    self = [self initWithUserDefaults:NSUserDefaults.standardUserDefaults];
    if (self) _onlineScopesOnly = YES;
    return self;
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults {
    self = [super init];
    if (self != nil) {
        _userDefaults = userDefaults;
        _ruleVersion = 1;
    }
    return self;
}

- (NSArray<NSString *> *)storedApplicationIdentifiers {
    id value = self.onlineScopesOnly ? [self onlineScopes][@"applications"] : [self validRootDictionary][@"applications"];
    if (![value isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray *keys = [NSMutableArray array];
    for (id key in [value allKeys]) {
        if ([key isKindOfClass:NSString.class] && [key length] > 0 && [key length] <= 255
            && (!self.onlineScopesOnly || [CPASuggestionPolicyStore allowsOnlineScopeBundleIdentifier:key]))
            [keys addObject:key];
    }
    return [keys sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray<NSString *> *)storedBrowserHosts {
    if (self.onlineScopesOnly) return @[];
    id value = self.onlineScopesOnly ? [self onlineScopes][@"sites"] : [self validRootDictionary][@"sites"];
    if (![value isKindOfClass:NSDictionary.class]) return @[];
    NSMutableSet *hosts = [NSMutableSet set];
    for (id key in [value allKeys]) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSString *host = [CPASuggestionPolicyStore normalizedBrowserHost:key];
        if (host.length) [hosts addObject:host];
    }
    return [hosts.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (NSDictionary *)onlineScopes {
    id value = [self.userDefaults objectForKey:@"OnlineCompletionScopes.v1"];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

- (CPAApplicationRule *)onlineRuleForKey:(NSString *)key group:(NSString *)group {
    id entries = [self onlineScopes][group];
    id value = [entries isKindOfClass:NSDictionary.class] ? entries[key] : nil;
    BOOL selected = [group isEqual:@"applications"]
        && [CPASuggestionPolicyStore allowsOnlineScopeBundleIdentifier:key]
        && [value isKindOfClass:NSNumber.class] && [value boolValue];
    return [[CPAApplicationRule alloc] initWithMode:selected
        ? CPAApplicationPolicyModeEnableOrdinaryInputs : CPAApplicationPolicyModeDisabled
        searchExceptionEnabled:NO remoteCompletionAuthorized:selected];
}

- (void)setOnlineScopeSelected:(BOOL)selected bundleIdentifier:(NSString *)bundle host:(NSString *)host {
    if (host.length || ![CPASuggestionPolicyStore allowsOnlineScopeBundleIdentifier:bundle]) return;
    BOOL browser = CPASuggestionPolicyApplicationIsBrowser(bundle);
    if (CPASuggestionPolicyDefaultClassForApplication(bundle) == CPAApplicationDefaultPolicyClassPermanentlyBlocked
        || bundle.length > 255 || (browser && !host.length) || (!browser && host.length)) return;
    NSString *key = browser ? [CPASuggestionPolicyStore normalizedBrowserHost:host] : bundle;
    if (!key.length) return;
    NSString *group = browser ? @"sites" : @"applications";
    NSMutableDictionary *root = [[self onlineScopes] mutableCopy];
    id previous = root[group];
    NSMutableDictionary *entries = [previous isKindOfClass:NSDictionary.class] ? [previous mutableCopy] : [NSMutableDictionary new];
    entries[key] = @(selected);
    root[group] = entries;
    [self.userDefaults setObject:root forKey:@"OnlineCompletionScopes.v1"];
    self.ruleVersion++;
}

- (CPAApplicationRule *)recommendedRule {
    return [[CPAApplicationRule alloc]
        initWithMode:CPAApplicationPolicyModeRecommended
        searchExceptionEnabled:NO
        remoteCompletionAuthorized:NO];
}

- (nullable NSDictionary *)validRootDictionary {
    id value = [self.userDefaults objectForKey:CPASuggestionPolicyStoreDefaultsKey];
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary *root = value;
    id schemaVersion = root[@"schemaVersion"];
    if (![schemaVersion isKindOfClass:NSNumber.class]
        || [schemaVersion integerValue] != CPASuggestionPolicySchemaVersion) {
        return nil;
    }
    return root;
}

- (NSMutableDictionary *)mutableRootDictionary {
    NSDictionary *validRoot = [self validRootDictionary];
    NSMutableDictionary *root = validRoot != nil
        ? [validRoot mutableCopy] : [NSMutableDictionary dictionary];
    root[@"schemaVersion"] = @(CPASuggestionPolicySchemaVersion);
    return root;
}

- (CPAApplicationRule *)ruleFromValue:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) {
        return [self recommendedRule];
    }
    NSDictionary *entry = value;
    id modeValue = entry[@"mode"];
    if (![modeValue isKindOfClass:NSNumber.class]) {
        return [self recommendedRule];
    }
    NSInteger mode = [modeValue integerValue];
    if (mode < CPAApplicationPolicyModeRecommended
        || mode > CPAApplicationPolicyModeDisabled) {
        return [self recommendedRule];
    }
    id searchValue = entry[@"searchException"];
    id remoteValue = entry[@"remoteAuthorized"];
    BOOL searchException = [searchValue isKindOfClass:NSNumber.class]
        && [searchValue boolValue];
    BOOL remoteAuthorized = [remoteValue isKindOfClass:NSNumber.class]
        && [remoteValue boolValue];
    return [[CPAApplicationRule alloc]
        initWithMode:(CPAApplicationPolicyMode)mode
        searchExceptionEnabled:searchException
        remoteCompletionAuthorized:remoteAuthorized];
}

- (NSDictionary *)storedValueForRule:(CPAApplicationRule *)rule {
    return @{
        @"mode": @(rule.mode),
        @"searchException": @(rule.searchExceptionEnabled),
        @"remoteAuthorized": @(rule.remoteCompletionAuthorized),
    };
}

- (CPAApplicationRule *)ruleForBundleIdentifier:(NSString *)bundleIdentifier {
    if (self.onlineScopesOnly) return [self onlineRuleForKey:bundleIdentifier group:@"applications"];
    if (bundleIdentifier.length == 0) {
        return [self recommendedRule];
    }
    NSDictionary *applications = [self validRootDictionary][@"applications"];
    if (![applications isKindOfClass:NSDictionary.class]) {
        return [self recommendedRule];
    }
    return [self ruleFromValue:applications[bundleIdentifier]];
}

- (void)setRule:(CPAApplicationRule *)rule
    forBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0 || bundleIdentifier.length > 255
        || [bundleIdentifier rangeOfCharacterFromSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].location
            != NSNotFound) {
        return;
    }
    NSMutableDictionary *root = [self mutableRootDictionary];
    id existingApplications = root[@"applications"];
    NSMutableDictionary *applications =
        [existingApplications isKindOfClass:NSDictionary.class]
            ? [existingApplications mutableCopy]
            : [NSMutableDictionary dictionary];
    applications[bundleIdentifier] = [self storedValueForRule:rule];
    root[@"applications"] = applications;
    [self.userDefaults setObject:root forKey:CPASuggestionPolicyStoreDefaultsKey];
    self.ruleVersion += 1;
}

- (CPAApplicationRule *)ruleForBrowserHost:(NSString *)hostOrURL {
    if (self.onlineScopesOnly) {
        NSString *host = [CPASuggestionPolicyStore normalizedBrowserHost:hostOrURL];
        return [CPASuggestionPolicyStore isFeishuDocumentHost:host]
            ? [self onlineRuleForKey:@"com.electron.lark" group:@"applications"]
            : [self onlineRuleForKey:host group:@"sites"];
    }
    NSString *host = [CPASuggestionPolicyStore normalizedBrowserHost:hostOrURL];
    if (host.length == 0) {
        return [self recommendedRule];
    }
    NSDictionary *sites = [self validRootDictionary][@"sites"];
    if (![sites isKindOfClass:NSDictionary.class]) {
        return [self recommendedRule];
    }
    return [self ruleFromValue:sites[host]];
}

- (BOOL)setRule:(CPAApplicationRule *)rule
    forBrowserHost:(NSString *)hostOrURL {
    NSString *host = [CPASuggestionPolicyStore normalizedBrowserHost:hostOrURL];
    if (host.length == 0) {
        return NO;
    }
    NSMutableDictionary *root = [self mutableRootDictionary];
    id existingSites = root[@"sites"];
    NSMutableDictionary *sites = [existingSites isKindOfClass:NSDictionary.class]
        ? [existingSites mutableCopy] : [NSMutableDictionary dictionary];
    sites[host] = [self storedValueForRule:rule];
    root[@"sites"] = sites;
    [self.userDefaults setObject:root forKey:CPASuggestionPolicyStoreDefaultsKey];
    self.ruleVersion += 1;
    return YES;
}

// Only a single tenant label on the service's own domain, never lookalikes.
+ (BOOL)isFeishuDocumentHost:(NSString *)host {
    return host.length > 0 && [host.lowercaseString rangeOfString:@"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.feishu\\.cn$"
        options:NSRegularExpressionSearch].location != NSNotFound;
}

+ (NSString *)normalizedBrowserHost:(NSString *)hostOrURL {
    NSString *trimmed = [hostOrURL stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || trimmed.length > 2048) {
        return @"";
    }
    NSString *candidate = [trimmed rangeOfString:@"://"].location != NSNotFound
        ? trimmed : [@"https://" stringByAppendingString:trimmed];
    NSURLComponents *components = [NSURLComponents componentsWithString:candidate];
    NSString *host = components.host.lowercaseString ?: @"";
    while ([host hasSuffix:@"."]) {
        host = [host substringToIndex:host.length - 1];
    }
    if (host.length == 0 || host.length > 253
        || [host rangeOfString:@"."].location == NSNotFound) {
        return @"";
    }
    NSCharacterSet *invalidCharacters = [[NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-."]
        invertedSet];
    if ([host rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound
        || [host hasPrefix:@"."] || [host containsString:@".."]
        || [host hasPrefix:@"-"] || [host hasSuffix:@"-"]) {
        return @"";
    }
    return host;
}

@end
