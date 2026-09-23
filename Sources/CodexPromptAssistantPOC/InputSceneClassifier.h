#import <Foundation/Foundation.h>

#import "SuggestionPolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// Metadata-only evidence collected from Accessibility roles and an app
/// adapter. It deliberately has no input-value or field-label property.
@interface CPAInputSceneEvidence : NSObject

@property(nonatomic, copy, readonly) NSString *role;
@property(nonatomic, copy, readonly) NSString *subrole;
@property(nonatomic) BOOL secureTextEntry;
@property(nonatomic) BOOL searchHint;
@property(nonatomic) BOOL oneTimeCodeHint;
@property(nonatomic) BOOL paymentHint;
@property(nonatomic) BOOL loginHint;
@property(nonatomic) BOOL chatComposerHint;
@property(nonatomic) BOOL longFormEditorHint;
@property(nonatomic) BOOL ordinaryTextHint;

- (instancetype)initWithRole:(NSString *)role
    subrole:(NSString *)subrole NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CPAInputSceneClassification : NSObject

@property(nonatomic, readonly) CPAInputScene scene;
@property(nonatomic, readonly) BOOL confidenceHigh;

@end

@interface CPAInputSceneClassifier : NSObject

- (CPAInputSceneClassification *)classifyEvidence:
    (CPAInputSceneEvidence *)evidence;

@end

NS_ASSUME_NONNULL_END
