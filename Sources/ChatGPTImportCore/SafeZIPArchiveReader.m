#import "SafeZIPArchiveReader.h"

#import <string.h>
#import <sys/stat.h>
#import <zlib.h>

static NSString * const CPAZIPErrorDomain = @"CPASafeZIPArchiveReaderErrorDomain";

static void CPASetZIPError(NSError **error, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CPAZIPErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

static BOOL CPAHasBytes(NSData *data, NSUInteger offset, NSUInteger length) {
    return offset <= data.length && length <= data.length - offset;
}

static uint16_t CPAUInt16(NSData *data, NSUInteger offset) {
    const uint8_t *bytes = data.bytes;
    return (uint16_t)(bytes[offset] | ((uint16_t)bytes[offset + 1] << 8));
}

static uint32_t CPAUInt32(NSData *data, NSUInteger offset) {
    const uint8_t *bytes = data.bytes;
    return (uint32_t)bytes[offset]
        | ((uint32_t)bytes[offset + 1] << 8)
        | ((uint32_t)bytes[offset + 2] << 16)
        | ((uint32_t)bytes[offset + 3] << 24);
}

@interface CPASafeZIPEntry ()
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, readwrite) uint64_t compressedSize;
@property(nonatomic, readwrite) uint64_t uncompressedSize;
@property(nonatomic) uint16_t compressionMethod;
@property(nonatomic) uint16_t generalPurposeFlags;
@property(nonatomic) uint32_t checksum;
@property(nonatomic) uint64_t localHeaderOffset;
@property(nonatomic) uint64_t dataOffset;
@end

@implementation CPASafeZIPEntry
@end

@interface CPASafeZIPArchiveReader ()
@property(nonatomic, strong) NSData *archiveData;
@property(nonatomic, readwrite) NSUInteger entryCount;
@property(nonatomic, strong, readwrite) CPASafeZIPEntry *conversationsEntry;
@property(nonatomic) uint64_t centralDirectoryOffset;
@end

@implementation CPASafeZIPArchiveReader

- (instancetype)initWithURL:(NSURL *)url
    maximumArchiveBytes:(uint64_t)maximumArchiveBytes
    maximumEntryCount:(NSUInteger)maximumEntryCount
    maximumEntryUncompressedBytes:(uint64_t)maximumEntryUncompressedBytes
    maximumTotalUncompressedBytes:(uint64_t)maximumTotalUncompressedBytes
    maximumCompressionRatio:(double)maximumCompressionRatio
    error:(NSError **)error {
    if (error != NULL) {
        *error = nil;
    }
    struct stat status;
    if (lstat(url.fileSystemRepresentation, &status) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey: @"Unable to inspect ChatGPT export"}];
        }
        return nil;
    }
    if (!S_ISREG(status.st_mode)) {
        CPASetZIPError(error, @"ChatGPT export must be a regular ZIP file");
        return nil;
    }
    uint64_t fileSize = (uint64_t)status.st_size;
    if (fileSize < 22 || fileSize > maximumArchiveBytes || fileSize > UINT32_MAX) {
        CPASetZIPError(error, @"ChatGPT export archive size is unsupported");
        return nil;
    }
    dev_t initialDevice = status.st_dev;
    ino_t initialInode = status.st_ino;
    NSData *archiveData = [NSData dataWithContentsOfURL:url
        options:NSDataReadingMappedAlways error:error];
    if (archiveData == nil) {
        return nil;
    }
    struct stat finalStatus;
    if (lstat(url.fileSystemRepresentation, &finalStatus) != 0
        || !S_ISREG(finalStatus.st_mode)
        || finalStatus.st_dev != initialDevice
        || finalStatus.st_ino != initialInode
        || (uint64_t)finalStatus.st_size != fileSize
        || archiveData.length != fileSize) {
        CPASetZIPError(error, @"ChatGPT export changed while it was being opened");
        return nil;
    }
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _archiveData = archiveData;
    if (![self parseCentralDirectoryWithMaximumEntryCount:maximumEntryCount
            maximumEntryUncompressedBytes:maximumEntryUncompressedBytes
            maximumTotalUncompressedBytes:maximumTotalUncompressedBytes
            maximumCompressionRatio:maximumCompressionRatio error:error]) {
        return nil;
    }
    return self;
}

- (BOOL)parseCentralDirectoryWithMaximumEntryCount:(NSUInteger)maximumEntryCount
    maximumEntryUncompressedBytes:(uint64_t)maximumEntryUncompressedBytes
    maximumTotalUncompressedBytes:(uint64_t)maximumTotalUncompressedBytes
    maximumCompressionRatio:(double)maximumCompressionRatio
    error:(NSError **)error {
    NSData *data = self.archiveData;
    NSUInteger minimumOffset = data.length > 22 + UINT16_MAX
        ? data.length - 22 - UINT16_MAX
        : 0;
    NSUInteger eocdOffset = NSNotFound;
    for (NSUInteger offset = data.length - 22;; offset--) {
        if (CPAUInt32(data, offset) == 0x06054b50) {
            eocdOffset = offset;
            break;
        }
        if (offset == minimumOffset) {
            break;
        }
    }
    if (eocdOffset == NSNotFound || !CPAHasBytes(data, eocdOffset, 22)) {
        CPASetZIPError(error, @"ZIP end record is missing");
        return NO;
    }
    uint16_t diskNumber = CPAUInt16(data, eocdOffset + 4);
    uint16_t centralDisk = CPAUInt16(data, eocdOffset + 6);
    uint16_t diskEntries = CPAUInt16(data, eocdOffset + 8);
    uint16_t totalEntries = CPAUInt16(data, eocdOffset + 10);
    uint32_t centralSize = CPAUInt32(data, eocdOffset + 12);
    uint32_t centralOffset = CPAUInt32(data, eocdOffset + 16);
    uint16_t commentLength = CPAUInt16(data, eocdOffset + 20);
    if (diskNumber != 0 || centralDisk != 0 || diskEntries != totalEntries
        || totalEntries == UINT16_MAX || centralSize == UINT32_MAX
        || centralOffset == UINT32_MAX) {
        CPASetZIPError(error, @"Multi-disk and ZIP64 exports are not supported in version 1");
        return NO;
    }
    if (totalEntries > maximumEntryCount
        || !CPAHasBytes(data, eocdOffset, 22 + commentLength)
        || eocdOffset + 22 + commentLength != data.length
        || (uint64_t)centralOffset + centralSize > eocdOffset) {
        CPASetZIPError(error, @"ZIP directory bounds are invalid or exceed limits");
        return NO;
    }
    self.entryCount = totalEntries;
    self.centralDirectoryOffset = centralOffset;
    NSUInteger offset = centralOffset;
    uint64_t totalUncompressed = 0;
    NSUInteger conversationsCount = 0;
    for (NSUInteger i = 0; i < totalEntries; i++) {
        if (!CPAHasBytes(data, offset, 46) || CPAUInt32(data, offset) != 0x02014b50) {
            CPASetZIPError(error, @"ZIP central directory entry is invalid");
            return NO;
        }
        uint16_t madeBy = CPAUInt16(data, offset + 4);
        uint16_t flags = CPAUInt16(data, offset + 8);
        uint16_t method = CPAUInt16(data, offset + 10);
        uint32_t checksum = CPAUInt32(data, offset + 16);
        uint32_t compressedSize = CPAUInt32(data, offset + 20);
        uint32_t uncompressedSize = CPAUInt32(data, offset + 24);
        uint16_t nameLength = CPAUInt16(data, offset + 28);
        uint16_t extraLength = CPAUInt16(data, offset + 30);
        uint16_t entryCommentLength = CPAUInt16(data, offset + 32);
        uint16_t startingDisk = CPAUInt16(data, offset + 34);
        uint32_t externalAttributes = CPAUInt32(data, offset + 38);
        uint32_t localOffset = CPAUInt32(data, offset + 42);
        NSUInteger recordLength = 46 + nameLength + extraLength + entryCommentLength;
        if (startingDisk != 0 || compressedSize == UINT32_MAX
            || uncompressedSize == UINT32_MAX || localOffset == UINT32_MAX
            || !CPAHasBytes(data, offset, recordLength)) {
            CPASetZIPError(error, @"ZIP64 or malformed entry is unsupported");
            return NO;
        }
        NSData *nameData = [data subdataWithRange:NSMakeRange(offset + 46, nameLength)];
        NSString *name = [[NSString alloc] initWithData:nameData
            encoding:NSUTF8StringEncoding];
        if (name == nil || ![self isSafeEntryName:name]) {
            CPASetZIPError(error, @"ZIP contains an unsafe entry path");
            return NO;
        }
        uint16_t creatorSystem = madeBy >> 8;
        mode_t unixMode = (mode_t)(externalAttributes >> 16);
        if ((flags & 0x2041) != 0
            || (creatorSystem == 3 && (unixMode & S_IFMT) == S_IFLNK)) {
            CPASetZIPError(error, @"Encrypted or symbolic-link ZIP entries are not allowed");
            return NO;
        }
        if (uncompressedSize > maximumEntryUncompressedBytes
            || uncompressedSize > maximumTotalUncompressedBytes
            || totalUncompressed > maximumTotalUncompressedBytes - uncompressedSize) {
            CPASetZIPError(error, @"ZIP uncompressed size exceeds the configured limit");
            return NO;
        }
        totalUncompressed += uncompressedSize;
        if (uncompressedSize > 0) {
            if (compressedSize == 0
                || (double)uncompressedSize / (double)compressedSize
                    > maximumCompressionRatio) {
                CPASetZIPError(error, @"ZIP compression ratio exceeds the configured limit");
                return NO;
            }
        }

        if ([name isEqualToString:@"conversations.json"]) {
            conversationsCount++;
            if (method != 0 && method != 8) {
                CPASetZIPError(error, @"conversations.json uses an unsupported compression method");
                return NO;
            }
            CPASafeZIPEntry *entry = [[CPASafeZIPEntry alloc] init];
            entry.name = name;
            entry.compressedSize = compressedSize;
            entry.uncompressedSize = uncompressedSize;
            entry.compressionMethod = method;
            entry.generalPurposeFlags = flags;
            entry.checksum = checksum;
            entry.localHeaderOffset = localOffset;
            if (![self resolveDataOffsetForEntry:entry nameData:nameData error:error]) {
                return NO;
            }
            self.conversationsEntry = entry;
        }
        offset += recordLength;
    }
    if (offset != (uint64_t)centralOffset + centralSize || conversationsCount != 1) {
        CPASetZIPError(error, @"ZIP must contain exactly one root conversations.json entry");
        return NO;
    }
    return YES;
}

- (BOOL)isSafeEntryName:(NSString *)name {
    if (name.length == 0 || [name hasPrefix:@"/"] || [name containsString:@"\\"]
        || [name rangeOfString:@"\0"].location != NSNotFound) {
        return NO;
    }
    NSArray<NSString *> *components = [name componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0, len = components.count; i < len; i++) {
        NSString *component = components[i];
        BOOL finalDirectoryMarker = i == len - 1 && component.length == 0;
        if ((!finalDirectoryMarker && component.length == 0)
            || [component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)resolveDataOffsetForEntry:(CPASafeZIPEntry *)entry
    nameData:(NSData *)centralNameData
    error:(NSError **)error {
    NSData *data = self.archiveData;
    NSUInteger offset = (NSUInteger)entry.localHeaderOffset;
    if (!CPAHasBytes(data, offset, 30) || CPAUInt32(data, offset) != 0x04034b50) {
        CPASetZIPError(error, @"ZIP local entry header is invalid");
        return NO;
    }
    uint16_t flags = CPAUInt16(data, offset + 6);
    uint16_t method = CPAUInt16(data, offset + 8);
    uint16_t nameLength = CPAUInt16(data, offset + 26);
    uint16_t extraLength = CPAUInt16(data, offset + 28);
    uint64_t dataOffset = (uint64_t)offset + 30 + nameLength + extraLength;
    if (flags != entry.generalPurposeFlags || method != entry.compressionMethod
        || !CPAHasBytes(data, offset + 30, nameLength + extraLength)
        || ![[data subdataWithRange:NSMakeRange(offset + 30, nameLength)]
            isEqualToData:centralNameData]
        || dataOffset + entry.compressedSize > self.centralDirectoryOffset) {
        CPASetZIPError(error, @"ZIP local and central entry metadata do not match");
        return NO;
    }
    entry.dataOffset = dataOffset;
    return YES;
}

- (BOOL)streamEntry:(CPASafeZIPEntry *)entry
    chunkSize:(NSUInteger)chunkSize
    chunkHandler:(CPAZIPChunkHandler)chunkHandler
    error:(NSError **)error {
    if (entry != self.conversationsEntry || chunkSize == 0) {
        CPASetZIPError(error, @"ZIP entry stream request is invalid");
        return NO;
    }
    const uint8_t *bytes = self.archiveData.bytes;
    const uint8_t *compressed = bytes + entry.dataOffset;
    if (entry.compressionMethod == 0) {
        if (entry.compressedSize != entry.uncompressedSize) {
            CPASetZIPError(error, @"Stored ZIP entry size is inconsistent");
            return NO;
        }
        uint32_t checksum = (uint32_t)crc32(0, Z_NULL, 0);
        uint64_t consumed = 0;
        while (consumed < entry.uncompressedSize) {
            NSUInteger length = (NSUInteger)MIN((uint64_t)chunkSize,
                entry.uncompressedSize - consumed);
            NSData *chunk = [NSData dataWithBytes:compressed + consumed length:length];
            checksum = (uint32_t)crc32(checksum, chunk.bytes, (uInt)chunk.length);
            if (!chunkHandler(chunk, error)) {
                return NO;
            }
            consumed += length;
        }
        if (checksum != entry.checksum) {
            CPASetZIPError(error, @"ZIP entry checksum verification failed");
            return NO;
        }
        return YES;
    }
    return [self inflateEntry:entry compressedBytes:compressed
        chunkSize:chunkSize chunkHandler:chunkHandler error:error];
}

- (BOOL)inflateEntry:(CPASafeZIPEntry *)entry
    compressedBytes:(const uint8_t *)compressedBytes
    chunkSize:(NSUInteger)chunkSize
    chunkHandler:(CPAZIPChunkHandler)chunkHandler
    error:(NSError **)error {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        CPASetZIPError(error, @"Unable to initialize ZIP decompression");
        return NO;
    }
    NSMutableData *output = [NSMutableData dataWithLength:chunkSize];
    uint64_t inputOffset = 0;
    uint64_t outputCount = 0;
    uint32_t checksum = (uint32_t)crc32(0, Z_NULL, 0);
    BOOL reachedEnd = NO;
    BOOL succeeded = YES;
    while (!reachedEnd) {
        if (stream.avail_in == 0 && inputOffset < entry.compressedSize) {
            uInt length = (uInt)MIN((uint64_t)UINT_MAX,
                entry.compressedSize - inputOffset);
            stream.next_in = (Bytef *)(compressedBytes + inputOffset);
            stream.avail_in = length;
            inputOffset += length;
        }
        stream.next_out = output.mutableBytes;
        stream.avail_out = (uInt)MIN((NSUInteger)UINT_MAX, output.length);
        int status = inflate(&stream, Z_NO_FLUSH);
        NSUInteger produced = output.length - stream.avail_out;
        if (produced > 0) {
            if (produced > entry.uncompressedSize
                || outputCount > entry.uncompressedSize - produced) {
                CPASetZIPError(error, @"ZIP entry expanded beyond its declared size");
                succeeded = NO;
                break;
            }
            NSData *chunk = [NSData dataWithBytes:output.bytes length:produced];
            checksum = (uint32_t)crc32(checksum, chunk.bytes, (uInt)chunk.length);
            outputCount += produced;
            if (!chunkHandler(chunk, error)) {
                succeeded = NO;
                break;
            }
        }
        if (status == Z_STREAM_END) {
            reachedEnd = YES;
        } else if (status != Z_OK
            || (stream.avail_in == 0 && inputOffset >= entry.compressedSize
                && produced == 0)) {
            CPASetZIPError(error, @"ZIP deflate stream is malformed or truncated");
            succeeded = NO;
            break;
        }
    }
    uint64_t consumedInput = inputOffset - stream.avail_in;
    inflateEnd(&stream);
    if (!succeeded) {
        return NO;
    }
    if (outputCount != entry.uncompressedSize || consumedInput != entry.compressedSize
        || checksum != entry.checksum) {
        CPASetZIPError(error, @"ZIP decompressed size or checksum is inconsistent");
        return NO;
    }
    return YES;
}

@end
