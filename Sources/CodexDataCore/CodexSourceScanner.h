#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPACodexScanReport : NSObject

@property(nonatomic, readonly) NSUInteger discoveredJSONLCount;
@property(nonatomic, readonly) NSUInteger rootThreadCount;
@property(nonatomic, readonly) NSUInteger subagentThreadCount;
@property(nonatomic, readonly) NSUInteger unsupportedSourceCount;
@property(nonatomic, readonly) NSUInteger duplicateThreadCount;
@property(nonatomic, readonly) NSUInteger visibleMessageCount;
@property(nonatomic, readonly) NSUInteger trailingPartialFileCount;
@property(nonatomic, readonly) NSUInteger messageParseErrorCount;
@property(nonatomic, readonly) uint64_t inspectedByteCount;

@end

@interface CPACodexSourceScanner : NSObject

- (nullable CPACodexScanReport *)scanActiveDirectory:(NSURL *)activeDirectory
    archivedDirectory:(NSURL *)archivedDirectory
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
