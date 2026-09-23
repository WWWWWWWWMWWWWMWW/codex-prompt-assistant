#import <Foundation/Foundation.h>

#import "SafeInputContextCollector.h"

NS_ASSUME_NONNULL_BEGIN

/// Reduces transient browser document metadata to a lowercase hostname. Full
/// URLs, paths, credentials, queries, and fragments must not leave the AX
/// inspection call.
FOUNDATION_EXPORT NSString *CPABrowserHostFromDocumentValue(
    NSString *documentValue
);

FOUNDATION_EXPORT BOOL CPAIsFeishuDocumentEditor(NSString *bundleIdentifier, NSString *browserHost, NSString *role, id _Nullable classes);

/// Removes only the known Lark accessibility wrapper and maps its selection.
FOUNDATION_EXPORT NSString *CPANormalizeLarkInput(NSString *text, NSRange * _Nullable selection);
/// Read and verify the logical text used by Lark's cursor range, bounded by AXValue.
/// The reader returns nil for a range past the end; caller must reject API errors.
FOUNDATION_EXPORT NSString * _Nullable CPALarkReadCursorText(NSUInteger maximumLength,
    NSRange selection, NSString * _Nullable (^readRange)(NSRange));

/// Resolves a Feishu document root to its unique active paragraph using metadata
/// only. Unknown, ambiguous, or over-budget trees return nil; never reads text.
FOUNDATION_EXPORT id _Nullable CPAFeishuFocusedTextEditor(id root,
    id _Nullable (^attribute)(id element, NSString *name));

@interface CPAGenericInputBody : NSObject

@property(nonatomic, copy, readonly) NSString *inputText;
@property(nonatomic, copy, readonly, nullable) NSArray *workBuddyContext;
@property(nonatomic, readonly) BOOL workBuddyContextReadPending;
@property(nonatomic, readonly) BOOL hasSelectedRange;
@property(nonatomic, readonly) NSInteger selectedLocation;
@property(nonatomic, readonly) NSInteger selectedLength;
@property(nonatomic, readonly) BOOL writableTextInput;
@property(nonatomic, readonly) BOOL hasCaretBounds;
@property(nonatomic, readonly) CGRect caretBounds;
@property(nonatomic, readonly) BOOL hasElementFrame;
@property(nonatomic, readonly) CGRect elementFrame;

@end

/// Two-stage generic AX reader. Metadata inspection never reads AXValue.
/// readInputBodyForMetadata: revalidates application and focused-field identity
/// before reading the value, selection, or geometry.
@interface CPAGenericAccessibilityService : NSObject <CPAInputBodyReading>

@property(nonatomic, copy, readonly) NSString *lastInspectionDiagnostic;
@property(nonatomic, strong) CPASuggestionPolicyCoordinator *policyCoordinator;
@property(nonatomic, copy) BOOL (^contextReadingPaused)(void);
- (nullable CPAFocusedInputMetadata *)inspectFocusedInputMetadata;
- (nullable CPAFocusedInputMetadata *)
    inspectFocusedInputMetadataForBundleIdentifier:(NSString *)bundleIdentifier
    processIdentifier:(pid_t)processIdentifier;
- (nullable CPAGenericInputBody *)readInputBodyForMetadata:
    (CPAFocusedInputMetadata *)metadata;

@end

NS_ASSUME_NONNULL_END
