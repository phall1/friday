#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface FridayNemoRecognizer : NSObject
@property(nonatomic, readonly, copy, nullable) NSString *activeModelPath;
@property(nonatomic, readonly, getter=isBusy) BOOL busy;
- (void)activateModelAtPath:(NSString *)path generation:(uint64_t)generation completion:(void (^)(NSDictionary *result))completion;
- (void)transcribeAudioAtURL:(NSURL *)url sessionID:(uint64_t)sessionID generation:(uint64_t)generation completion:(void (^)(NSDictionary *result))completion;
- (void)cancelGeneration:(uint64_t)generation;
- (void)unload;
@end
NS_ASSUME_NONNULL_END
