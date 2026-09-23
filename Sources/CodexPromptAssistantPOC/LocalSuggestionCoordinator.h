#import <Foundation/Foundation.h>

@class CPAAccessibilitySnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef NSString * _Nullable (^CPALocalSuggestionLookup)(NSString *input,
    NSUInteger cursorLocation, NSUInteger selectedLength);

@interface CPALocalSuggestionCoordinator : NSObject

- (instancetype)initWithLookup:(CPALocalSuggestionLookup)lookup
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSString *)inputSignatureForSnapshot:(CPAAccessibilitySnapshot *)snapshot;
/// Read-only proposal. Production commits only after the common display gate.
- (nullable NSString *)automaticInsertionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature;
- (nullable NSString *)prepareAutomaticSuggestionForSnapshot:
    (CPAAccessibilitySnapshot *)snapshot signature:(NSString *)signature;
- (void)prepareManualInsertion:(NSString *)insertionText
    signature:(NSString *)signature;
- (void)prepareRemoteInsertion:(NSString *)insertionText
    signature:(NSString *)signature;
- (nullable NSString *)consumeInsertionForSignature:(NSString *)signature;
- (void)clear;

@end
NS_ASSUME_NONNULL_END
