#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FridayOverlayHandler)(NSString *action);
@interface FridayOverlayWindow : NSObject
- (instancetype)initWithHandler:(FridayOverlayHandler)handler;
- (void)showLocked:(BOOL)locked elapsedMilliseconds:(uint64_t)elapsed;
- (void)showTranscribing;
- (void)hide;
- (NSDictionary<NSString *, id> *)runInteractionProbe;
@end

NS_ASSUME_NONNULL_END
