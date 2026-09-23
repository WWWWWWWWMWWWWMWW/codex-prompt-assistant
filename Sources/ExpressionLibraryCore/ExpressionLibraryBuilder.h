#import <Foundation/Foundation.h>

@class CPALocalDataStore;
@class CPALocalExpressionBuildResult;

NS_ASSUME_NONNULL_BEGIN

@interface CPAExpressionLibraryBuilder : NSObject

- (nullable CPALocalExpressionBuildResult *)rebuildStore:(CPALocalDataStore *)store
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
