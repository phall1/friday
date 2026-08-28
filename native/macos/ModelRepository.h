#import <Foundation/Foundation.h>
@class FridayNemoRecognizer;
NS_ASSUME_NONNULL_BEGIN
typedef void (^FridayModelProgressHandler)(uint64_t operationID,
                                           NSString *state,
                                           uint64_t downloadedBytes,
                                           uint64_t totalBytes);
@interface FridayModelRepository : NSObject
@property(nonatomic, readonly) uint64_t activeModelKey;
@property(nonatomic, readonly, copy, nullable) NSString *activeModelPath;
- (instancetype)initWithDataDirectory:(NSString *)dataDirectory
                           recognizer:(FridayNemoRecognizer *)recognizer
                             progress:(FridayModelProgressHandler)progress;
- (NSDictionary<NSString *, id> *)status;
- (void)downloadDefaultOperation:(uint64_t)operationID
                      completion:(void (^)(NSDictionary *result))completion;
- (void)cancelOperation:(uint64_t)operationID;
- (void)addLocalPath:(NSString *)path
                 key:(uint64_t)key
          generation:(uint64_t)generation
          completion:(void (^)(NSDictionary *result))completion;
- (void)addHuggingFaceID:(NSString *)identifier
               operation:(uint64_t)operation
              completion:(void (^)(NSDictionary *result))completion;
- (void)selectKey:(uint64_t)key
       generation:(uint64_t)generation
       completion:(void (^)(NSDictionary *result))completion;
- (NSDictionary<NSString *, id> *)removeKey:(uint64_t)key
                              deleteManaged:(BOOL)deleteManaged;
- (NSDictionary<NSString *, id> *)removeFailedDownloads;
+ (NSDictionary<NSString *, id> *)runRepositoryProbes;
@end
NS_ASSUME_NONNULL_END
