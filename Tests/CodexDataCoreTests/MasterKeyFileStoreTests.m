#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/MasterKeyFileStore.h"

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
        Assert([fileManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700}
            error:&error], @"test directory should be created");
        NSURL *keyURL = [directory URLByAppendingPathComponent:@"master-key.bin"];
        CPAMasterKeyFileStore *store = [[CPAMasterKeyFileStore alloc] initWithURL:keyURL];
        NSData *first = [store keyData:&error];
        Assert(first.length == 64 && error == nil, @"missing key should be generated");
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:keyURL.path error:&error];
        Assert([attributes[NSFilePosixPermissions] unsignedShortValue] == 0600,
            @"key file should be owner-only");
        CPAMasterKeyFileStore *second = [[CPAMasterKeyFileStore alloc] initWithURL:keyURL];
        NSData *roundTrip = [second keyData:&error];
        Assert([roundTrip isEqualToData:first], @"key should persist without keychain access");

        NSURL *symlinkURL = [directory URLByAppendingPathComponent:@"symlink-key.bin"];
        Assert([fileManager createSymbolicLinkAtURL:symlinkURL withDestinationURL:keyURL
            error:&error], @"symlink fixture should be created");
        CPAMasterKeyFileStore *symlinkStore = [[CPAMasterKeyFileStore alloc]
            initWithURL:symlinkURL];
        error = nil;
        Assert([symlinkStore keyData:&error] == nil && error != nil,
            @"symlink key path should be rejected");
        [fileManager removeItemAtURL:directory error:nil];
        NSLog(@"PASS: MasterKeyFileStoreTests");
    }
    return 0;
}
