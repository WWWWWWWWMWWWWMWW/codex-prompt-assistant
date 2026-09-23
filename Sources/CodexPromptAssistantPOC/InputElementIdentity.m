#import "InputElementIdentity.h"

@interface CPAInputElementIdentity ()
@property(nonatomic, strong) id element;
@property(nonatomic, strong, nullable) id window;
@property(nonatomic, copy) NSString *rendererIdentifier;
@property(nonatomic, copy) NSString *token;
@end

@implementation CPAInputElementIdentity
- (NSString *)tokenForElement:(id)element
    window:(id)window rendererIdentifier:(NSString *)rendererIdentifier {
    BOOL sameElement = self.element != nil
        && CFEqual((__bridge CFTypeRef)self.element, (__bridge CFTypeRef)element);
    BOOL sameWindow = (self.window == nil && window == nil)
        || (self.window != nil && window != nil
            && CFEqual((__bridge CFTypeRef)self.window, (__bridge CFTypeRef)window));
    if (!sameElement || !sameWindow
        || ![self.rendererIdentifier isEqualToString:rendererIdentifier]) {
        self.element = element;
        self.window = window;
        self.rendererIdentifier = rendererIdentifier;
        self.token = NSUUID.UUID.UUIDString;
    }
    return self.token;
}
@end
