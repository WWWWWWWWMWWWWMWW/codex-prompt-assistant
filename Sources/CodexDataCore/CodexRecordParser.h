#import <Foundation/Foundation.h>

@class CPACodexMessage;
@class CPACodexSourceMetadata;

NS_ASSUME_NONNULL_BEGIN

@interface CPACodexRecordParser : NSObject

- (nullable CPACodexSourceMetadata *)parseMetadataLineData:(NSData *)lineData
    error:(NSError **)error;

- (nullable CPACodexMessage *)parseMessageLineData:(NSData *)lineData
    lineNumber:(NSUInteger)lineNumber
    lineStartOffset:(uint64_t)lineStartOffset
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
