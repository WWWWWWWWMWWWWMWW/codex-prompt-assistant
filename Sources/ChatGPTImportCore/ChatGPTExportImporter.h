#import <Foundation/Foundation.h>

@class CPALocalDataStore;

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^CPAChatGPTImportCancellationCheck)(void);

@interface CPAChatGPTImportLimits : NSObject

@property(nonatomic, readonly) uint64_t maximumArchiveBytes;
@property(nonatomic, readonly) NSUInteger maximumEntryCount;
@property(nonatomic, readonly) uint64_t maximumEntryUncompressedBytes;
@property(nonatomic, readonly) uint64_t maximumTotalUncompressedBytes;
@property(nonatomic, readonly) NSUInteger maximumConversationBytes;
@property(nonatomic, readonly) double maximumCompressionRatio;

- (instancetype)initWithMaximumArchiveBytes:(uint64_t)maximumArchiveBytes
    maximumEntryCount:(NSUInteger)maximumEntryCount
    maximumEntryUncompressedBytes:(uint64_t)maximumEntryUncompressedBytes
    maximumTotalUncompressedBytes:(uint64_t)maximumTotalUncompressedBytes
    maximumConversationBytes:(NSUInteger)maximumConversationBytes
    maximumCompressionRatio:(double)maximumCompressionRatio NS_DESIGNATED_INITIALIZER;
+ (instancetype)defaultLimits;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPAChatGPTExportImportResult : NSObject
@property(nonatomic, readonly) NSUInteger conversationCount;
@property(nonatomic, readonly) NSUInteger insertedMessageCount;
@property(nonatomic, readonly) NSUInteger existingMessageCount;
@end

@interface CPAChatGPTExportImporter : NSObject

- (instancetype)initWithLimits:(CPAChatGPTImportLimits *)limits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable CPAChatGPTExportImportResult *)importExportAtURL:(NSURL *)exportURL
    intoStore:(CPALocalDataStore *)store
    cancellationCheck:(nullable CPAChatGPTImportCancellationCheck)cancellationCheck
    error:(NSError **)error;

@end
NS_ASSUME_NONNULL_END
