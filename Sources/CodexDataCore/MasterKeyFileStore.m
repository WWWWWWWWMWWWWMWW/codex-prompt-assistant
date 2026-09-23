#import "MasterKeyFileStore.h"

#import "MessageCrypto.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const CPAMasterKeyFileStoreErrorDomain =
    @"CPAMasterKeyFileStoreErrorDomain";
static const NSUInteger CPAMasterKeyFileLength = 64;

@interface CPAMasterKeyFileStore ()
@property(nonatomic, strong) NSURL *url;
@end

@implementation CPAMasterKeyFileStore

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self != nil) {
        _url = [url URLByStandardizingPath];
    }
    return self;
}

- (NSData *)keyData:(NSError **)error {
    if (self.url.path.length == 0) {
        [self setError:error code:EINVAL description:@"Master key path is empty"];
        return nil;
    }
    int descriptor = open(self.url.fileSystemRepresentation,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor >= 0) {
        return [self readKeyFromDescriptor:descriptor error:error];
    }
    int openError = errno;
    if (openError != ENOENT) {
        [self setError:error code:openError description:@"Unable to open local master key"];
        return nil;
    }
    return [self createKeyFile:error];
}

- (NSData *)createKeyFile:(NSError **)error {
    CPAMessageCrypto *crypto = [[CPAMessageCrypto alloc] init];
    NSError *generationError = nil;
    NSData *key = [crypto generateRandomMasterKey:&generationError];
    if (key == nil) {
        if (error != NULL) {
            *error = generationError;
        }
        return nil;
    }
    int descriptor = open(self.url.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        int openError = errno;
        if (openError == EEXIST) {
            return [self keyData:error];
        }
        [self setError:error code:openError description:@"Unable to create local master key"];
        return nil;
    }

    const uint8_t *bytes = key.bytes;
    NSUInteger remaining = key.length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written <= 0) {
            int writeError = errno;
            close(descriptor);
            unlink(self.url.fileSystemRepresentation);
            [self setError:error code:writeError description:@"Unable to write local master key"];
            return nil;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    int syncStatus = fsync(descriptor);
    int syncError = syncStatus == 0 ? 0 : errno;
    int closeStatus = close(descriptor);
    int closeError = closeStatus == 0 ? 0 : errno;
    if (syncStatus != 0 || closeStatus != 0) {
        unlink(self.url.fileSystemRepresentation);
        [self setError:error
            code:syncStatus != 0 ? syncError : closeError
            description:@"Unable to finalize local master key"];
        return nil;
    }
    return key;
}

- (NSData *)readKeyFromDescriptor:(int)descriptor error:(NSError **)error {
    struct stat status;
    BOOL valid = fstat(descriptor, &status) == 0;
    int validationError = valid ? 0 : errno;
    if (valid && (!S_ISREG(status.st_mode) || status.st_uid != geteuid()
            || status.st_nlink != 1 || status.st_size != (off_t)CPAMasterKeyFileLength)) {
        valid = NO;
        validationError = EPERM;
    }
    if (!valid) {
        close(descriptor);
        [self setError:error code:validationError description:@"Local master key file failed safety checks"];
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:CPAMasterKeyFileLength];
    uint8_t *bytes = data.mutableBytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t readCount = read(descriptor, bytes, remaining);
        if (readCount <= 0) {
            int readError = readCount == 0 ? EIO : errno;
            close(descriptor);
            [self setError:error code:readError description:@"Unable to read local master key"];
            return nil;
        }
        bytes += readCount;
        remaining -= (NSUInteger)readCount;
    }
    if (close(descriptor) != 0) {
        [self setError:error code:errno description:@"Unable to close local master key"];
        return nil;
    }
    return data;
}

- (BOOL)setError:(NSError **)error code:(NSInteger)code description:(NSString *)description {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPAMasterKeyFileStoreErrorDomain
            code:code userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

@end
