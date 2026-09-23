#import <AppKit/AppKit.h>
#import "KeyboardShadowBuffer.h"

NS_ASSUME_NONNULL_BEGIN

@protocol CPAKeyboardInterceptorDelegate <NSObject>

- (BOOL)keyboardInterceptorShouldObserveCurrentInput;
- (BOOL)keyboardInterceptorShouldHandleSuggestionKeys;
- (void)keyboardInterceptorDidRequestAccept;
- (void)keyboardInterceptorDidRequestDismiss;

@optional
/// The app delegate maintains this identity from workspace notifications so
/// the event-tap callback does not synchronously query LaunchServices.
- (NSString *)keyboardInterceptorCurrentFrontmostBundleIdentifier;
- (pid_t)keyboardInterceptorCurrentFrontmostProcessIdentifier;
/// Sent after an observed key or mouse event changes or invalidates the
/// lightweight input snapshot. The receiver must defer any AX/model work so
/// the global event-tap callback can return immediately.
- (void)keyboardInterceptorDidObserveInputEvent;
/// Non-edit navigation may recycle sidebar/composer nodes; invalidate task binding.
- (void)keyboardInterceptorDidObservePossibleTaskNavigation;

@end

@interface CPAKeyboardInterceptor : NSObject

@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) BOOL eventTapEnabled;
@property(nonatomic, readonly) BOOL mostRecentTextEditWasDeletion;
@property(nonatomic, readonly) BOOL shouldObserveCurrentInput;

- (instancetype)initWithDelegate:(id<CPAKeyboardInterceptorDelegate>)delegate;
- (BOOL)start;
- (void)stop;
- (void)postText:(NSString *)text;
/// Reports whether a paired Unicode event was posted to the still-frontmost
/// target process. Posting is not an acknowledgement from the host editor.
- (BOOL)postText:(NSString *)text toProcessIdentifier:(pid_t)processIdentifier;
- (void)resetShadowBuffer;
- (void)updateFallbackInputFrame:(CGRect)inputFrame available:(BOOL)available;
- (void)prepareShadowBufferForCodexActivation;
- (void)synchronizeShadowBufferWithText:(NSString *)text
                        cursorLocation:(NSUInteger)cursorLocation
                        selectedLength:(NSUInteger)selectedLength;
- (CPAKeyboardShadowBuffer *)shadowBuffer;
- (BOOL)inputMethodCompositionProbablyActive;
- (NSTimeInterval)inputMethodSuggestionDelayRemaining;

@end

NS_ASSUME_NONNULL_END
