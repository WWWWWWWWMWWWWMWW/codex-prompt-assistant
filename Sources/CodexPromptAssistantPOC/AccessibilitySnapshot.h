#import <Foundation/Foundation.h>

#import "SuggestionPolicy.h"

NS_ASSUME_NONNULL_BEGIN

@interface CPAAccessibilitySnapshot : NSObject

@property(nonatomic) BOOL permissionGranted;
@property(nonatomic) BOOL codexIsRunning;
@property(nonatomic) BOOL codexIsFrontmost;
@property(nonatomic) BOOL targetApplicationIsFrontmost;
@property(nonatomic, copy) NSString *targetBundleIdentifier;
@property(nonatomic) pid_t targetProcessIdentifier;
@property(nonatomic) CPASuggestionPolicyOutcome suggestionPolicyOutcome;
@property(nonatomic) CPAContextAccessMode contextAccessMode;
@property(nonatomic) CPASuggestionPolicyReason suggestionPolicyReason;
@property(nonatomic, copy) NSString *targetFieldIdentity;
@property(nonatomic, copy) NSString *browserHost;
/// Verified Feishu document paragraph, distinct from a chat composer.
@property(nonatomic) BOOL documentContinuation;
@property(nonatomic) NSUInteger policyRuleVersion;
/// Verdict from the Codex read gate; contains no field labels or draft text.
@property(nonatomic, strong, nullable) CPASuggestionDecision *codexInputDecision;
@property(nonatomic) NSUInteger inputReadingGeneration;
/// Main-thread conversation/runtime generation when creating a candidate signature.
@property(nonatomic) NSUInteger candidateContextGeneration;
@property(nonatomic, copy) NSString *policyStatusText;
/// Several consecutive AX reads failed before any composer node was found.
/// This is a diagnostic hint for the known Chromium renderer accessibility
/// launch-mode issue; it is never treated as proof of a specific Codex build.
@property(nonatomic) BOOL rendererAccessibilitySuspected;
@property(nonatomic, copy, nullable) NSString *focusedRole;
@property(nonatomic, copy, nullable) NSString *focusedSubrole;
/// Opaque Chromium accessibility node identity for the active composer.
/// This is used only as an in-memory generation boundary and is never logged.
@property(nonatomic, copy, nullable) NSString *composerIdentifier;
/// Visible selected Codex conversation title. This is used only to resolve the
/// matching local rollout and is never included in diagnostics.
@property(nonatomic, copy, nullable) NSString *conversationTitle;
/// Live selected-row/window token; absent on cached title/unknown/overlay. Memory only.
@property(nonatomic, copy, nullable) NSString *conversationSelectionIdentity;
@property(nonatomic) BOOL hasSelectedRange;
@property(nonatomic) NSInteger selectedLocation;
@property(nonatomic) NSInteger selectedLength;
@property(nonatomic) NSInteger valueCharacterCount;
@property(nonatomic) BOOL hasValueCharacterCount;
@property(nonatomic, copy, nullable) NSString *inputText;
/// WorkBuddy rendered conversation ownership and messages; memory only.
@property(nonatomic, copy, nullable) NSArray *workBuddyContext;
/// An interrupted read is not an empty conversation; defer completion until a fresh read.
@property(nonatomic) BOOL workBuddyContextReadPending;
@property(nonatomic) BOOL writableTextInput;
@property(nonatomic) BOOL hasCaretBounds;
@property(nonatomic) CGRect caretBounds;
@property(nonatomic) BOOL hasElementFrame;
@property(nonatomic) CGRect elementFrame;
/// Conservative window-derived input frame collected off the main run loop.
/// It is separate from an AX element frame so callers can distinguish an
/// authoritative caret/element anchor from a cold-start fallback.
@property(nonatomic) BOOL hasFallbackInputFrame;
@property(nonatomic) CGRect fallbackInputFrame;
@property(nonatomic, copy) NSString *diagnostic;

+ (BOOL)isUsableCaretBounds:(CGRect)bounds;
+ (NSInteger)effectiveSelectedLocationForReportedLocation:(NSInteger)reportedLocation
    selectedLength:(NSInteger)selectedLength
    valueLength:(NSInteger)valueLength
    hasUsableCaretBounds:(BOOL)hasUsableCaretBounds;
- (BOOL)hasSuggestionAnchor;
+ (CGRect)conservativeInputFrameForWindowFrame:(CGRect)windowFrame;
+ (nullable CPAAccessibilitySnapshot *)shadowSnapshotFromInspection:
    (CPAAccessibilitySnapshot *)inspection
    shadowText:(NSString *)shadowText
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength
    fallbackInputFrame:(CGRect)fallbackInputFrame;

- (NSString *)summary;

@end

NS_ASSUME_NONNULL_END
