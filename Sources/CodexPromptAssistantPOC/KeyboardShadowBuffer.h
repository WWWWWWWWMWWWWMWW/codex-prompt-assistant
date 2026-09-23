#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A deliberately conservative text shadow used only when Codex's AX tree is
/// unavailable. It never reads or writes Codex; it only applies committed key
/// edits observed by the global event tap.
@interface CPAKeyboardShadowBuffer : NSObject

@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, readonly) NSUInteger cursorLocation;
@property(nonatomic, readonly) NSUInteger selectedLength;
@property(nonatomic, readonly) BOOL valid;

- (void)reset;
- (void)markUnknown;
- (void)replaceWithAuthoritativeText:(NSString *)text
                    cursorLocation:(NSUInteger)cursorLocation
                    selectedLength:(NSUInteger)selectedLength;
- (void)applyCommittedText:(NSString *)text;
- (void)applyBackspace;
- (void)applyDelete;
- (void)moveCursorLeftSelecting:(BOOL)selecting;
- (void)moveCursorRightSelecting:(BOOL)selecting;
- (void)moveCursorToStartSelecting:(BOOL)selecting;
- (void)moveCursorToEndSelecting:(BOOL)selecting;
- (void)selectAll;
- (void)clearAfterSubmit;
- (void)handleMouseDownInsideFallbackInput:(BOOL)insideFallbackInput;

@end

NS_ASSUME_NONNULL_END
