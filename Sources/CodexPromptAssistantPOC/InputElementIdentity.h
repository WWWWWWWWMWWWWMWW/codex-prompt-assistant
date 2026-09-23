#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Serial-reader helper. Tokens are valid only while the same element, window
/// and renderer identifier remain observed. Never persist or log these tokens.
@interface CPAInputElementIdentity : NSObject
- (NSString *)tokenForElement:(id)element
    window:(nullable id)window rendererIdentifier:(NSString *)rendererIdentifier;
@end

NS_ASSUME_NONNULL_END
