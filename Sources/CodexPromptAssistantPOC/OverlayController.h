#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPAOverlayController : NSObject

@property(nonatomic, readonly) BOOL visible;

- (void)showSuggestion:(NSString *)suggestion atAccessibilityBounds:(CGRect)bounds;
- (void)showSuggestionBar:(NSString *)suggestion
    atAccessibilityInputFrame:(CGRect)inputFrame;
- (void)hide;

@end

NS_ASSUME_NONNULL_END
