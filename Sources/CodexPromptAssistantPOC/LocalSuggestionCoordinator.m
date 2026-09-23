#import "LocalSuggestionCoordinator.h"

#import "AccessibilitySnapshot.h"
#import <CommonCrypto/CommonHMAC.h>

@interface CPALocalSuggestionCoordinator ()
@property(nonatomic, copy) CPALocalSuggestionLookup lookup;
@property(nonatomic, copy) NSData *signatureKey;
@property(nonatomic, copy, nullable) NSString *pendingInsertionText;
@property(nonatomic, copy, nullable) NSString *pendingSignature;
@end

@implementation CPALocalSuggestionCoordinator

- (instancetype)initWithLookup:(CPALocalSuggestionLookup)lookup {
    self = [super init];
    if (self != nil) {
        _lookup = [lookup copy];
        _signatureKey = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    }
    return self;
}

- (NSString *)inputSignatureForSnapshot:(CPAAccessibilitySnapshot *)snapshot {
    if (!snapshot.writableTextInput || !snapshot.hasSuggestionAnchor
        || snapshot.inputText == nil || !snapshot.hasValueCharacterCount
        || snapshot.valueCharacterCount != (NSInteger)snapshot.inputText.length
        || !snapshot.hasSelectedRange || snapshot.selectedLocation < 0
        || snapshot.selectedLength < 0
        || snapshot.selectedLocation > snapshot.valueCharacterCount
        || snapshot.selectedLength > snapshot.valueCharacterCount - snapshot.selectedLocation) {
        return @"";
    }
    // A per-coordinator random key prevents signatures becoming stable draft
    // fingerprints. Include the whole value, including text after the caret.
    NSArray *identity = @[
        snapshot.inputText, @(snapshot.selectedLocation), @(snapshot.selectedLength),
        snapshot.targetBundleIdentifier ?: @"", @(snapshot.targetProcessIdentifier),
        snapshot.targetFieldIdentity ?: @"", snapshot.composerIdentifier ?: @"",
        snapshot.conversationTitle ?: @"", snapshot.conversationSelectionIdentity ?: @"",
        snapshot.browserHost ?: @"", @(snapshot.policyRuleVersion),
        @(snapshot.suggestionPolicyOutcome), @(snapshot.contextAccessMode), @(snapshot.documentContinuation),
        @(snapshot.inputReadingGeneration), @(snapshot.candidateContextGeneration),
        snapshot.workBuddyContext ?: @[], @(snapshot.workBuddyContextReadPending)
    ];
    NSData *data = [NSJSONSerialization dataWithJSONObject:identity options:NSJSONWritingSortedKeys error:nil];
    if (data == nil) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, self.signatureKey.bytes, self.signatureKey.length,
        data.bytes, data.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

- (NSString *)prepareAutomaticSuggestionForSnapshot:
    (CPAAccessibilitySnapshot *)snapshot signature:(NSString *)signature {
    [self clear];
    NSString *insertion = [self automaticInsertionForSnapshot:snapshot signature:signature];
    if (insertion.length > 0) [self prepareManualInsertion:insertion signature:signature];
    return insertion;
}

- (NSString *)automaticInsertionForSnapshot:(CPAAccessibilitySnapshot *)snapshot
    signature:(NSString *)signature {
    NSString *currentSignature = [self inputSignatureForSnapshot:snapshot];
    if (snapshot.inputText == nil || !snapshot.hasValueCharacterCount
        || !snapshot.hasSelectedRange || snapshot.selectedLocation < 0
        || snapshot.selectedLength < 0 || signature.length == 0
        || ![currentSignature isEqualToString:signature]) {
        return nil;
    }
    NSString *insertion = self.lookup(snapshot.inputText,
        (NSUInteger)snapshot.selectedLocation,
        (NSUInteger)snapshot.selectedLength);
    if (insertion.length == 0) {
        return nil;
    }
    return insertion;
}

- (void)prepareManualInsertion:(NSString *)insertionText
    signature:(NSString *)signature {
    [self clear];
    if (insertionText.length == 0 || signature.length == 0) {
        return;
    }
    self.pendingInsertionText = insertionText;
    self.pendingSignature = signature;
}

- (void)prepareRemoteInsertion:(NSString *)insertionText
    signature:(NSString *)signature {
    [self prepareManualInsertion:insertionText signature:signature];
}

- (NSString *)consumeInsertionForSignature:(NSString *)signature {
    if (self.pendingInsertionText == nil
        || ![self.pendingSignature isEqualToString:signature]) {
        [self clear];
        return nil;
    }
    NSString *insertion = self.pendingInsertionText;
    [self clear];
    return insertion;
}

- (void)clear {
    self.pendingInsertionText = nil;
    self.pendingSignature = nil;
}

@end
