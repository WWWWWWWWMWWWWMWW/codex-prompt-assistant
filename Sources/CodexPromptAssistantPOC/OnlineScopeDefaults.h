#pragma once
#import <Foundation/Foundation.h>

// Applied by the installer after the user supplies a key. Missing selections
// get defaults; explicit choices (including NO) always survive upgrades/reuse.
static inline NSDictionary *CPAOnlineScopesWithInstallationDefaults(id previous) {
    NSMutableDictionary *root = [previous isKindOfClass:NSDictionary.class]
        ? [previous mutableCopy] : [NSMutableDictionary new];
    id stored = root[@"applications"];
    NSMutableDictionary *applications = [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary new];
    for (NSString *bundle in @[@"com.openai.codex", @"com.tencent.workbuddy.mac"])
        if (applications[bundle] == nil) applications[bundle] = @YES;
    root[@"applications"] = applications;
    return root;
}
