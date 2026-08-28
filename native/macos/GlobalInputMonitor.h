#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FridayInputEventHandler)(NSString *event,
                                        NSDictionary<NSString *, id> *payload);

@interface FridayGlobalInputMonitor : NSObject
@property(nonatomic, readonly) BOOL inputMonitoringUsable;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
- (instancetype)initWithHandler:(FridayInputEventHandler)handler;
- (BOOL)configureFromString:(NSString *)configuration error:(NSError **)error;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)requestPermission;
- (NSDictionary<NSString *, id> *)runSyntheticProbe;
@end

NS_ASSUME_NONNULL_END
