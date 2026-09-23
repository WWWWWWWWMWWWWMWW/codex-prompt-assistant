#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/RemoteAPIKeyFileStore.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *directory = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
            isDirectory:YES];
        NSError *error = nil;
        CPARemoteAPIKeyFileStore *store = [[CPARemoteAPIKeyFileStore alloc]
            initWithDirectoryURL:directory];
        Assert([store keyData:&error] == nil && error == nil,
            @"missing remote key should not be an error");
        NSData *key = [@"synthetic-api-key" dataUsingEncoding:NSUTF8StringEncoding];
        Assert([store storeKeyData:key error:&error] && error == nil,
            @"remote key should save");
        NSURL *payloadURL = [directory URLByAppendingPathComponent:@"remote-api-key-v1.bin"];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:payloadURL.path error:&error];
        Assert([attributes[NSFilePosixPermissions] unsignedShortValue] == 0600,
            @"remote key payload should be owner-only");
        NSData *raw = [NSData dataWithContentsOfURL:payloadURL];
        Assert(raw.length > 0 && ![raw isEqualToData:key],
            @"remote key payload should not be plaintext");
        CPARemoteAPIKeyFileStore *second = [[CPARemoteAPIKeyFileStore alloc]
            initWithDirectoryURL:directory];
        Assert([[second keyData:&error] isEqualToData:key] && error == nil,
            @"remote key should round trip without keychain access");

        NSURL *symlinkURL = [directory URLByAppendingPathComponent:@"remote-api-key-v1.bin.link"];
        Assert([fileManager createSymbolicLinkAtURL:symlinkURL withDestinationURL:payloadURL
            error:&error], @"symlink fixture should be created");
        [fileManager removeItemAtURL:directory error:nil];
        NSLog(@"PASS: RemoteAPIKeyFileStoreTests");
    }
    return 0;
}
