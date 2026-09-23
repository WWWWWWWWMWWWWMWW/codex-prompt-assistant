#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^CPAJSONObjectHandler)(NSData *objectData, NSError **error);

@interface CPAJSONArrayObjectStreamParser : NSObject

- (instancetype)initWithMaximumObjectBytes:(NSUInteger)maximumObjectBytes
    objectHandler:(CPAJSONObjectHandler)objectHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)consumeData:(NSData *)data error:(NSError **)error;
- (BOOL)finish:(NSError **)error;

@end
NS_ASSUME_NONNULL_END
