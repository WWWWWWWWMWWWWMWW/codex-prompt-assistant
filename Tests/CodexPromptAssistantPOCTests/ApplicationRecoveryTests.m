#import <Foundation/Foundation.h>

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSString *MethodBody(NSString *source, NSString *signature) {
    NSRange start = [source rangeOfString:signature];
    Assert(start.location != NSNotFound,
        [NSString stringWithFormat:@"missing method signature: %@", signature]);
    NSRange nextMethod = [source rangeOfString:@"\n- ("
        options:0
        range:NSMakeRange(NSMaxRange(start), source.length - NSMaxRange(start))];
    NSUInteger end = nextMethod.location == NSNotFound
        ? source.length : nextMethod.location;
    return [source substringWithRange:NSMakeRange(start.location, end - start.location)];
}

static NSInteger BraceDepthBeforeNeedle(NSString *source, NSString *needle) {
    NSRange needleRange = [source rangeOfString:needle];
    Assert(needleRange.location != NSNotFound,
        [NSString stringWithFormat:@"missing source needle: %@", needle]);
    NSInteger depth = 0;
    for (NSUInteger i = 0; i < needleRange.location; i++) {
        unichar character = [source characterAtIndex:i];
        if (character == '{') {
            depth++;
        } else if (character == '}') {
            depth--;
        }
    }
    return depth;
}

int main(void) {
    @autoreleasepool {
        NSString *plistPath =
            @"Resources/local.codex.prompt-assistant-app.plist";
        NSData *plistData = [NSData dataWithContentsOfFile:plistPath];
        Assert(plistData != nil, @"the assistant recovery LaunchAgent must exist");
        NSError *plistError = nil;
        NSDictionary *plist = [NSPropertyListSerialization
            propertyListWithData:plistData
            options:NSPropertyListImmutable
            format:nil
            error:&plistError];
        Assert([plist isKindOfClass:NSDictionary.class] && plistError == nil,
            @"the assistant recovery LaunchAgent must be a valid plist");
        Assert([plist[@"Label"] isEqualToString:
                @"local.codex.prompt-assistant-app"],
            @"the assistant recovery LaunchAgent must use the stable label");
        Assert([plist[@"RunAtLoad"] boolValue],
            @"the assistant should start with the user session");
        NSDictionary *keepAlive = plist[@"KeepAlive"];
        Assert([keepAlive isKindOfClass:NSDictionary.class]
                && keepAlive[@"SuccessfulExit"] != nil
                && ![keepAlive[@"SuccessfulExit"] boolValue],
            @"only abnormal assistant exits should trigger relaunch");
        Assert([plist[@"ThrottleInterval"] unsignedIntegerValue] == 30,
            @"relaunch attempts must be throttled for 30 seconds");
        NSArray<NSString *> *arguments = plist[@"ProgramArguments"];
        NSString *joinedArguments = [arguments componentsJoinedByString:@" "];
        Assert([joinedArguments rangeOfString:
                @"CodexPromptAssistantPOC.app/Contents/MacOS/CodexPromptAssistantPOC"]
                .location != NSNotFound,
            @"the LaunchAgent must launch only the installed assistant");
        Assert([joinedArguments rangeOfString:@"/Applications/ChatGPT.app"].location
                == NSNotFound
                && [joinedArguments rangeOfString:@"com.openai.codex"].location
                    == NSNotFound,
            @"assistant recovery must never launch or modify Codex");

        NSString *source = [NSString stringWithContentsOfFile:
            @"Sources/CodexPromptAssistantPOC/main.m"
            encoding:NSUTF8StringEncoding error:nil];
        Assert(source.length > 0, @"the application source must be readable");
        NSString *menuBody = MethodBody(source, @"- (void)configureStatusItem {");
        Assert([menuBody rangeOfString:@"高级"].location == NSNotFound
            && [menuBody rangeOfString:@"设置…"].location != NSNotFound,
            @"online edition exposes one settings entry without advanced controls");
        NSString *lifecycleBody = MethodBody(source,
            @"- (void)workspaceCodexProcessLifecycle:(NSNotification *)notification {");
        Assert([lifecycleBody rangeOfString:
                @"recoverSuggestionServiceWithReason:@\"codex_launch\""].location
                != NSNotFound,
            @"a newly launched Codex process should rebuild the assistant pipeline");
        Assert(BraceDepthBeforeNeedle(lifecycleBody,
                @"[self recoverSuggestionServiceWithReason:@\"codex_launch\"")
                <= 2,
            @"Codex launch recovery must not be gated by PID cache adoption");
        NSString *recoveryBody = MethodBody(source,
            @"- (void)recoverSuggestionServiceWithReason:(NSString *)reason\n"
            @"    resumeIfPaused:(BOOL)resumeIfPaused {");
        Assert([recoveryBody rangeOfString:
                @"self.suggestionsPaused && !resumeIfPaused"].location
                != NSNotFound,
            @"automatic recovery must respect an intentional user pause");
        NSArray<NSString *> *requiredRecoverySteps = @[
            @"cancelPendingSuggestionForReason:",
            @"[self.codexSnapshotBroker stop]",
            @"self.accessibilityService = [[CPAAccessibilityService alloc] init]",
            @"[self configureCodexSnapshotBroker]",
            @"self.codexProcessCacheInitialized = NO",
            @"[self.contextProvider invalidateCachedContext]",
            @"[self.keyboardInterceptor stop]",
            @"[self.keyboardInterceptor start]",
            @"CPAScheduleRepeatingTimer",
        ];
        for (NSUInteger i = 0, count = requiredRecoverySteps.count; i < count; i++) {
            Assert([recoveryBody rangeOfString:requiredRecoverySteps[i]].location
                    != NSNotFound,
                [NSString stringWithFormat:@"recovery is missing step: %@",
                    requiredRecoverySteps[i]]);
        }
        Assert([recoveryBody rangeOfString:@"terminateApplication"].location
                == NSNotFound
                && [recoveryBody rangeOfString:@"openApplication"].location
                    == NSNotFound,
            @"service recovery must not control the Codex process");
        NSLog(@"PASS: ApplicationRecoveryTests");
    }
    return 0;
}
