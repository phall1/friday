#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FridaySourceTarget : NSObject
@property(nonatomic, copy) NSString *token;
@property(nonatomic) pid_t pid;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *appName;
@end

@interface FridayTextDelivery : NSObject
- (FridaySourceTarget *)captureFrontmostSource;
- (NSDictionary<NSString *, id> *)deliverText:(NSString *)text toSource:(FridaySourceTarget *)source;
- (NSDictionary<NSString *, id> *)runProbeForApplication:(NSString *)applicationName;
@end

NS_ASSUME_NONNULL_END
