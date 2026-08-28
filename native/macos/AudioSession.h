#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FridayAudioEventHandler)(NSString *event,
                                        NSDictionary<NSString *, id> *payload);
@interface FridayAudioSession : NSObject
@property(nonatomic, readonly, getter=isActive) BOOL active;
@property(nonatomic, readonly, nullable) NSURL *retryAudioURL;
- (instancetype)initWithEventHandler:(FridayAudioEventHandler)handler;
- (nullable NSDictionary<NSString *, id> *)startSession:(uint64_t)sessionID
                                                  error:(NSError **)error;
- (void)stopSession:(uint64_t)sessionID
         completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
- (void)cancelSession:(uint64_t)sessionID;
- (void)cancelActiveSession;
- (void)discardRetryAudio;
+ (NSDictionary<NSString *, id> *)runStorageProbe;
@end

NS_ASSUME_NONNULL_END
