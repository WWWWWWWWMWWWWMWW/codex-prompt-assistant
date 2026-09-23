#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Metadata attributes are read first. AXValue is requested only inside a
/// recognized message body, after the caller's input policy gate.
@protocol CPAWorkBuddyTreeReading <NSObject>
- (nullable id)workBuddyAttribute:(NSString *)attribute element:(id)element;
@optional
/// One metadata-only AX round trip. A fresh wrapper is used for each structural pass.
- (nullable NSDictionary *)workBuddyStructureAttributesForElement:(id)element;
@end

@interface CPAWorkBuddyContextReader : NSObject
@property(nonatomic, copy, readonly) NSString *diagnostic;
/// Interrupted scan or recognized conversation whose history cannot yet be validated.
/// A composer with no conversation root keeps the existing draft-only path.
@property(nonatomic, readonly) BOOL readPending;
/// Returns immutable in-memory [ownership, messages]. No file or network I/O.
/// Nil means unknown structure, changed focus, ambiguity or exhausted traversal.
- (nullable NSArray *)readComposer:(id)composer tree:(id<CPAWorkBuddyTreeReading>)tree
    stillCurrent:(BOOL (^)(void))stillCurrent;
@end
NS_ASSUME_NONNULL_END
