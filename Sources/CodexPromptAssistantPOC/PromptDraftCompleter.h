#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Produces conservative, deterministic AI-prompt suffixes while the remote
/// model is still running. It returns nil outside explicitly recognized task
/// language so ordinary writing is never filled with a generic template.
@interface CPAPromptDraftCompleter : NSObject

- (nullable NSString *)suggestionForInput:(NSString *)input
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength;

@end

NS_ASSUME_NONNULL_END
