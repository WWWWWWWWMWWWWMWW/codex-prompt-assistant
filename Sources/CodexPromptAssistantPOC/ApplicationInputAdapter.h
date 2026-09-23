#import <Foundation/Foundation.h>

#import "InputSceneClassifier.h"

NS_ASSUME_NONNULL_BEGIN

/// Converts application identity plus non-value AX semantics into a scene.
/// semanticMetadata is used transiently and is never retained or logged.
@interface CPAApplicationInputAdapter : NSObject

- (CPAInputSceneClassification *)classificationForBundleIdentifier:
    (NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata;

- (CPAInputSceneClassification *)classificationForBundleIdentifier:
    (NSString *)bundleIdentifier
    role:(NSString *)role
    subrole:(NSString *)subrole
    semanticMetadata:(NSArray<NSString *> *)semanticMetadata
    allowOrdinaryTextInference:(BOOL)allowOrdinaryTextInference;

@end

NS_ASSUME_NONNULL_END
