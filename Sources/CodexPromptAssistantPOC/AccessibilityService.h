#import <Foundation/Foundation.h>

@class CPAAccessibilitySnapshot;
@class CPASuggestionPolicyCoordinator;

NS_ASSUME_NONNULL_BEGIN

@interface CPAAccessibilityService : NSObject

/// Inject before use. Missing policy fails closed; the worker never reads AXValue.
@property(atomic, strong, nullable) CPASuggestionPolicyCoordinator *policyCoordinator;
@property(atomic) BOOL inputReadingPaused;
@property(atomic, readonly) NSUInteger inputReadingGeneration;

- (BOOL)isTrustedWithPrompt:(BOOL)prompt;
- (CPAAccessibilitySnapshot *)inspectFocusedElement;
- (CPAAccessibilitySnapshot *)
    inspectFocusedElementForCodexProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier;
- (BOOL)refreshCurrentCodexTextInput;
- (BOOL)refreshCurrentCodexTextInputForProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier;
- (BOOL)focusLastKnownTextInput;
- (BOOL)focusLastKnownTextInputForProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier;
/// Reads only the on-screen CGWindow metadata for the current frontmost Codex
/// process and returns a conservative composer-sized frame near its bottom.
- (BOOL)currentCodexFallbackInputFrame:(CGRect *)inputFrame;
- (BOOL)currentCodexFallbackInputFrame:(CGRect *)inputFrame
    forProcessIdentifier:(pid_t)processIdentifier
    frontmostProcessIdentifier:(pid_t)frontmostProcessIdentifier;
/// Best-effort runtime AX activation. This never launches, terminates, or
/// otherwise changes the Codex process; a failure is safe to ignore.
- (BOOL)tryEnableRuntimeAccessibility;
- (BOOL)tryEnableRuntimeAccessibilityForProcessIdentifier:(pid_t)processIdentifier;

@end

NS_ASSUME_NONNULL_END
