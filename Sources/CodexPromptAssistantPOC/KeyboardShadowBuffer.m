#import "KeyboardShadowBuffer.h"

@interface CPAKeyboardShadowBuffer ()
@property(nonatomic, copy, readwrite) NSString *text;
@property(nonatomic, readwrite) NSUInteger cursorLocation;
@property(nonatomic, readwrite) NSUInteger selectedLength;
@property(nonatomic, readwrite) BOOL valid;
/// Keep directional selection endpoints separately. The public range remains
/// normalized for AX compatibility, while Shift+Arrow moves the active end.
@property(nonatomic) NSUInteger selectionAnchor;
@property(nonatomic) NSUInteger selectionExtent;
@end

@implementation CPAKeyboardShadowBuffer

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        [self reset];
    }
    return self;
}

- (void)reset {
    self.text = @"";
    self.cursorLocation = 0;
    self.selectedLength = 0;
    self.valid = YES;
    self.selectionAnchor = 0;
    self.selectionExtent = 0;
}

- (void)markUnknown {
    self.valid = NO;
}

- (void)replaceWithAuthoritativeText:(NSString *)text
                    cursorLocation:(NSUInteger)cursorLocation
                    selectedLength:(NSUInteger)selectedLength {
    self.text = text ?: @"";
    self.cursorLocation = MIN(cursorLocation, self.text.length);
    self.selectedLength = MIN(selectedLength, self.text.length - self.cursorLocation);
    self.selectionAnchor = self.cursorLocation;
    self.selectionExtent = self.cursorLocation + self.selectedLength;
    self.valid = YES;
}

- (void)updatePublicSelection {
    NSUInteger start = MIN(self.selectionAnchor, self.selectionExtent);
    NSUInteger end = MAX(self.selectionAnchor, self.selectionExtent);
    self.cursorLocation = start;
    self.selectedLength = end - start;
}

- (void)replaceSelectionWithText:(NSString *)replacement {
    if (replacement == nil) {
        return;
    }
    NSUInteger start = MIN(self.cursorLocation, self.text.length);
    NSUInteger length = MIN(self.selectedLength, self.text.length - start);
    NSString *prefix = [self.text substringToIndex:start];
    NSString *suffix = [self.text substringFromIndex:start + length];
    self.text = [NSString stringWithFormat:@"%@%@%@", prefix, replacement, suffix];
    self.cursorLocation = start + replacement.length;
    self.selectedLength = 0;
    self.selectionAnchor = self.cursorLocation;
    self.selectionExtent = self.cursorLocation;
}

- (void)applyCommittedText:(NSString *)text {
    if (text.length == 0) {
        return;
    }
    BOOL wasValid = self.valid;
    [self replaceSelectionWithText:text];
    if (!wasValid) {
        self.valid = NO;
    }
}

- (void)applyBackspace {
    if (self.selectedLength > 0) {
        [self replaceSelectionWithText:@""];
        return;
    }
    if (self.cursorLocation == 0 || self.text.length == 0) {
        return;
    }
    NSRange range = [self.text rangeOfComposedCharacterSequenceAtIndex:self.cursorLocation - 1];
    self.text = [self.text stringByReplacingCharactersInRange:range withString:@""];
    self.cursorLocation = range.location;
    self.selectionAnchor = self.cursorLocation;
    self.selectionExtent = self.cursorLocation;
}

- (void)applyDelete {
    if (self.selectedLength > 0) {
        [self replaceSelectionWithText:@""];
        return;
    }
    if (self.cursorLocation >= self.text.length) {
        return;
    }
    NSRange range = [self.text rangeOfComposedCharacterSequenceAtIndex:self.cursorLocation];
    self.text = [self.text stringByReplacingCharactersInRange:range withString:@""];
    self.selectionAnchor = self.cursorLocation;
    self.selectionExtent = self.cursorLocation;
}

- (void)setSelectionAnchor:(NSUInteger)anchor extent:(NSUInteger)extent {
    NSUInteger length = self.text.length;
    anchor = MIN(anchor, length);
    extent = MIN(extent, length);
    self.selectionAnchor = anchor;
    self.selectionExtent = extent;
    [self updatePublicSelection];
}

- (void)moveCursorLeftSelecting:(BOOL)selecting {
    NSUInteger old = selecting ? self.selectionExtent : self.cursorLocation;
    NSUInteger next = old > 0
        ? [self.text rangeOfComposedCharacterSequenceAtIndex:old - 1].location : 0;
    if (selecting) {
        [self setSelectionAnchor:self.selectionAnchor extent:next];
    } else {
        self.cursorLocation = self.selectedLength > 0 ? self.cursorLocation : next;
        self.selectedLength = 0;
        self.selectionAnchor = self.cursorLocation;
        self.selectionExtent = self.cursorLocation;
    }
}

- (void)moveCursorRightSelecting:(BOOL)selecting {
    NSUInteger old = selecting ? self.selectionExtent : self.cursorLocation;
    NSUInteger next = old < self.text.length
        ? NSMaxRange([self.text rangeOfComposedCharacterSequenceAtIndex:old])
        : self.text.length;
    if (selecting) {
        [self setSelectionAnchor:self.selectionAnchor extent:next];
    } else {
        self.cursorLocation = self.selectedLength > 0
            ? self.cursorLocation + self.selectedLength : next;
        self.selectedLength = 0;
        self.selectionAnchor = self.cursorLocation;
        self.selectionExtent = self.cursorLocation;
    }
}

- (void)moveCursorToStartSelecting:(BOOL)selecting {
    if (selecting) {
        [self setSelectionAnchor:self.selectionAnchor extent:0];
    } else {
        self.cursorLocation = 0;
        self.selectedLength = 0;
        self.selectionAnchor = 0;
        self.selectionExtent = 0;
    }
}

- (void)moveCursorToEndSelecting:(BOOL)selecting {
    if (selecting) {
        [self setSelectionAnchor:self.selectionAnchor extent:self.text.length];
    } else {
        self.cursorLocation = self.text.length;
        self.selectedLength = 0;
        self.selectionAnchor = self.text.length;
        self.selectionExtent = self.text.length;
    }
}

- (void)selectAll {
    self.cursorLocation = 0;
    self.selectedLength = self.text.length;
    self.selectionAnchor = 0;
    self.selectionExtent = self.text.length;
}

- (void)clearAfterSubmit {
    [self reset];
}

- (void)handleMouseDownInsideFallbackInput:(BOOL)insideFallbackInput {
    if (insideFallbackInput && self.text.length == 0) {
        [self reset];
        return;
    }
    [self markUnknown];
}

@end
