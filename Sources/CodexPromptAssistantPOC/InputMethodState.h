#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPAInputMethodState : NSObject

@property(nonatomic, readonly) BOOL potentialComposition;

- (void)noteKeyCode:(CGKeyCode)keyCode
    commandModified:(BOOL)commandModified
    usesChineseInput:(BOOL)usesChineseInput;
- (void)noteMouseDown;
- (BOOL)shouldPassThroughSuggestionKeyCode:(CGKeyCode)keyCode;
- (NSTimeInterval)suggestionDelayRemainingForElapsedSinceLastTextKey:
    (NSTimeInterval)elapsed;

@end

NS_ASSUME_NONNULL_END
