#import "RemoteAPIKeyFileStore.h"

#import "MasterKeyFileStore.h"
#import "MessageCrypto.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const CPARemoteAPIKeyFileStoreErrorDomain =
    @"CPARemoteAPIKeyFileStoreErrorDomain";
static NSString *const CPARemoteMasterKeyFileName = @"remote-master-key-v1.bin";
static NSString *const CPARemoteAPIKeyFileName = @"remote-api-key-v1.bin";
static const NSUInteger CPARemoteAPIKeyMaximumEnvelopeLength = 16384;

@interface CPARemoteAPIKeyFileStore ()
@property(nonatomic, strong) NSURL *directoryURL;
@property(nonatomic, strong) CPAMasterKeyFileStore *masterKeyStore;
@property(nonatomic, strong) CPAMessageCrypto *crypto;
@end

@implementation CPARemoteAPIKeyFileStore

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL {
    self = [super init];
    if (self != nil) {
        _directoryURL = [directoryURL URLByStandardizingPath];
        NSURL *masterKeyURL = [_directoryURL URLByAppendingPathComponent:
            CPARemoteMasterKeyFileName];
        _masterKeyStore = [[CPAMasterKeyFileStore alloc] initWithURL:masterKeyURL];
        _crypto = [[CPAMessageCrypto alloc] init];
    }
    return self;
}

- (NSData *)keyData:(NSError **)error {
    if (![self ensureDirectory:error]) {
        return nil;
    }
    NSURL *keyURL = [self.directoryURL URLByAppendingPathComponent:CPARemoteAPIKeyFileName];
    NSData *envelope = [self readSecureFile:keyURL error:error];
    if (envelope == nil) {
        return nil;
    }
    NSData *masterKey = [self.masterKeyStore keyData:error];
    if (masterKey == nil) {
        return nil;
    }
    return [self.crypto decryptEnvelope:envelope masterKey:masterKey error:error];
}

- (BOOL)storeKeyData:(NSData *)keyData error:(NSError **)error {
    if (keyData.length == 0) {
        [self setError:error code:EINVAL description:@"API key is empty"];
        return NO;
    }
    if (![self ensureDirectory:error]) {
        return NO;
    }
    NSData *masterKey = [self.masterKeyStore keyData:error];
    if (masterKey == nil) {
        return NO;
    }
    NSData *envelope = [self.crypto encryptData:keyData masterKey:masterKey error:error];
    if (envelope == nil) {
        return NO;
    }
    NSURL *keyURL = [self.directoryURL URLByAppendingPathComponent:CPARemoteAPIKeyFileName];
    return [self writeSecureFile:envelope toURL:keyURL error:error];
}

- (BOOL)ensureDirectory:(NSError **)error {
    if (self.directoryURL.path.length == 0) {
        [self setError:error code:EINVAL description:@"Remote key directory is empty"];
        return NO;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *directoryError = nil;
    BOOL created = [fileManager createDirectoryAtURL:self.directoryURL
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700}
        error:&directoryError];
    if (!created && ![fileManager fileExistsAtPath:self.directoryURL.path]) {
        if (error != NULL) {
            *error = directoryError;
        }
        return NO;
    }

    struct stat status;
    if (lstat(self.directoryURL.fileSystemRepresentation, &status) != 0
        || !S_ISDIR(status.st_mode) || status.st_uid != geteuid()) {
        [self setError:error code:EPERM description:@"Remote key directory failed safety checks"];
        return NO;
    }
    if ((status.st_mode & 077) != 0
        && chmod(self.directoryURL.fileSystemRepresentation, S_IRWXU) != 0) {
        [self setError:error code:errno description:@"Unable to secure remote key directory"];
        return NO;
    }
    return YES;
}

- (NSData *)readSecureFile:(NSURL *)url error:(NSError **)error {
    int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        if (errno == ENOENT) {
            return nil;
        }
        [self setError:error code:errno description:@"Unable to open encrypted API key"];
        return nil;
    }
    struct stat status;
    BOOL valid = fstat(descriptor, &status) == 0;
    int validationError = valid ? 0 : errno;
    if (valid && (!S_ISREG(status.st_mode) || status.st_uid != geteuid()
            || status.st_nlink != 1 || (status.st_mode & 077) != 0
            || status.st_size <= 0
            || status.st_size > (off_t)CPARemoteAPIKeyMaximumEnvelopeLength)) {
        valid = NO;
        validationError = EPERM;
    }
    if (!valid) {
        close(descriptor);
        [self setError:error code:validationError description:@"Encrypted API key file failed safety checks"];
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    uint8_t *bytes = data.mutableBytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t readCount = read(descriptor, bytes, remaining);
        if (readCount <= 0) {
            int readError = readCount == 0 ? EIO : errno;
            close(descriptor);
            [self setError:error code:readError description:@"Unable to read encrypted API key"];
            return nil;
        }
        bytes += readCount;
        remaining -= (NSUInteger)readCount;
    }
    if (close(descriptor) != 0) {
        [self setError:error code:errno description:@"Unable to close encrypted API key"];
        return nil;
    }
    return data;
}

- (BOOL)writeSecureFile:(NSData *)data toURL:(NSURL *)url error:(NSError **)error {
    NSString *temporaryName = [NSString stringWithFormat:@".%@.%@.tmp",
        url.lastPathComponent, NSUUID.UUID.UUIDString];
    NSURL *temporaryURL = [url.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:temporaryName];
    int descriptor = open(temporaryURL.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        [self setError:error code:errno description:@"Unable to create encrypted API key"];
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    BOOL success = YES;
    int writeError = 0;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written <= 0) {
            success = NO;
            writeError = errno;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    if (success && fsync(descriptor) != 0) {
        success = NO;
        writeError = errno;
    }
    if (close(descriptor) != 0 && success) {
        success = NO;
        writeError = errno;
    }
    if (!success) {
        unlink(temporaryURL.fileSystemRepresentation);
        [self setError:error code:writeError description:@"Unable to finalize encrypted API key"];
        return NO;
    }
    if (rename(temporaryURL.fileSystemRepresentation, url.fileSystemRepresentation) != 0) {
        int renameError = errno;
        unlink(temporaryURL.fileSystemRepresentation);
        [self setError:error code:renameError description:@"Unable to publish encrypted API key"];
        return NO;
    }
    return YES;
}

- (BOOL)setError:(NSError **)error code:(NSInteger)code description:(NSString *)description {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPARemoteAPIKeyFileStoreErrorDomain
            code:code userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

@end
