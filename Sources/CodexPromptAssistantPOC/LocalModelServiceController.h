#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPALocalModelServiceController : NSObject

// A helper launched for an update may only connect to the resident model.
// This is a process-local launch constraint, never a persisted user setting.
@property(nonatomic, readonly) BOOL preservesResidentModel;
- (instancetype)initWithPreservesResidentModel:(BOOL)preservesResidentModel;

+ (NSArray<NSString *> *)printArgumentsForUserID:(uid_t)userID;
+ (NSArray<NSString *> *)bootstrapArgumentsForUserID:(uid_t)userID
                                      homeDirectory:(NSString *)homeDirectory;
+ (NSArray<NSString *> *)bootoutArgumentsForUserID:(uid_t)userID;

- (BOOL)ensureRunning;
- (BOOL)stop;

@end

NS_ASSUME_NONNULL_END
