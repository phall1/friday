#import "ModelRepository.h"
#import "NemoRecognizer.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *const FridayModelID = @"nvidia/parakeet-tdt-0.6b-v3";
static NSString *const FridayRevision =
    @"541d1f99c6b0c3cd0b11a95167540bb8edefd82b";
static NSString *const FridayArtifact = @"parakeet-tdt-0.6b-v3.q8_0.gguf";
static NSString *const FridaySHA =
    @"e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e";
static NSString *const FridayURL =
    @"https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/"
    @"541d1f99c6b0c3cd0b11a95167540bb8edefd82b/parakeet-tdt-0.6b-v3.q8_0.gguf";
static const uint64_t FridayBytes = 713975456;
static const uint64_t FridayDefaultKey = 1;
static const void *FridayRepositoryQueueKey = &FridayRepositoryQueueKey;

@interface FridayModelRepository () <NSURLSessionDataDelegate>
@property(nonatomic, copy) NSString *dataDirectory;
@property(nonatomic, strong) FridayNemoRecognizer *recognizer;
@property(nonatomic, copy) FridayModelProgressHandler progress;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *models;
@property(nonatomic, readwrite) uint64_t activeModelKey;
@property(nonatomic, readwrite, copy, nullable) NSString *activeModelPath;
@property(nonatomic) BOOL activeRuntimeReady;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property(nonatomic, strong, nullable) NSFileHandle *handle;
@property(nonatomic, strong, nullable) NSURL *partialURL;
@property(nonatomic, strong, nullable) NSURL *resumeURL;
@property(nonatomic, strong) NSMutableDictionary *resume;
@property(nonatomic) uint64_t operation;
@property(nonatomic) uint64_t downloaded;
@property(nonatomic) uint64_t total;
@property(nonatomic) uint64_t lastResumePersisted;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL responseValid;
@property(nonatomic, copy, nullable) void (^completion)(NSDictionary *);
@property(nonatomic, strong, nullable) NSMutableDictionary *downloadManifest;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableDictionary *> *pendingHFManifests;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *metadataTask;
@property(nonatomic) uint64_t metadataOperation;
@property(nonatomic, copy, nullable) void (^metadataCompletion)(NSDictionary *);
@end

@implementation FridayModelRepository

- (instancetype)initWithDataDirectory:(NSString *)dataDirectory
                           recognizer:(FridayNemoRecognizer *)recognizer
                             progress:(FridayModelProgressHandler)progress {
  self = [super init];
  if (self) {
    _dataDirectory = [dataDirectory copy];
    _recognizer = recognizer;
    _progress = [progress copy];
    _models = [NSMutableArray array];
    _pendingHFManifests = [NSMutableDictionary dictionary];
    _queue =
        dispatch_queue_create("com.phall.friday.models", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, FridayRepositoryQueueKey,
                                (void *)FridayRepositoryQueueKey, NULL);
    NSOperationQueue *delegateQueue = [NSOperationQueue new];
    delegateQueue.maxConcurrentOperationCount = 1;
    delegateQueue.underlyingQueue = _queue;
    _session =
        [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration
                                                   .defaultSessionConfiguration
                                      delegate:self
                                 delegateQueue:delegateQueue];
    dispatch_sync(_queue, ^{
      [self prepareDirectories];
      [self loadIndex];
    });
    if (_activeModelPath) {
      [_recognizer activateModelAtPath:_activeModelPath
                            generation:0
                            completion:^(NSDictionary *result) {
                              [self onQueue:^{
                                self.activeRuntimeReady =
                                    [result[@"ok"] boolValue];
                                if (!self.activeRuntimeReady) {
                                  self.activeModelKey = 0;
                                  self.activeModelPath = nil;
                                  [self saveIndexDurably];
                                }
                              }];
                            }];
    }
  }
  return self;
}

- (void)dealloc {
  [self.task cancel];
  [self.metadataTask cancel];
  [self.session invalidateAndCancel];
}

- (NSString *)modelsRoot {
  return [self.dataDirectory stringByAppendingPathComponent:@"Models"];
}
- (NSString *)downloadsRoot {
  return [self.dataDirectory stringByAppendingPathComponent:@"ModelDownloads"];
}
- (NSString *)indexPath {
  return [[self modelsRoot] stringByAppendingPathComponent:@"index.json"];
}

- (void)prepareDirectories {
  NSFileManager *manager = NSFileManager.defaultManager;
  [manager createDirectoryAtPath:self.modelsRoot
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  [manager createDirectoryAtPath:self.downloadsRoot
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
}

- (void)onQueue:(dispatch_block_t)block {
  if (dispatch_get_specific(FridayRepositoryQueueKey))
    block();
  else
    dispatch_async(self.queue, block);
}

- (void)complete:(NSDictionary *)result {
  void (^completion)(NSDictionary *) = self.completion;
  self.completion = nil;
  if (completion)
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(result);
    });
}

- (void)publishProgress:(NSString *)state
             downloaded:(uint64_t)downloaded

                  total:(uint64_t)total {
  if (!self.progress)
    return;
  const uint64_t operation = self.operation;
  dispatch_async(dispatch_get_main_queue(), ^{
    self.progress(operation, state, downloaded, total);
  });
}
- (BOOL)isPinnedDefaultIdentity:(NSDictionary *)manifest {
  return [manifest[@"id"] isEqual:FridayModelID] &&
         [manifest[@"revision"] isEqual:FridayRevision] &&
         [manifest[@"sha256"] isEqual:FridaySHA] &&
         [manifest[@"expectedBytes"] unsignedLongLongValue] == FridayBytes &&
         [manifest[@"modelKey"] unsignedLongLongValue] == FridayDefaultKey;
}

- (BOOL)validateManagedDirectory:(NSString *)directory
                        expected:(nullable NSDictionary *)expected {
  NSString *modelPath =
      [directory stringByAppendingPathComponent:@"model.gguf"];
  NSString *manifestPath =
      [directory stringByAppendingPathComponent:@"manifest.json"];
  NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
  NSDictionary *manifest =
      manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData
                                                     options:0
                                                       error:nil]
                   : nil;
  uint64_t size =
      [[[NSFileManager.defaultManager attributesOfItemAtPath:modelPath
                                                       error:nil]
          objectForKey:NSFileSize] unsignedLongLongValue];
  BOOL verifiedFamily = [manifest[@"family"] isEqual:@"parakeet_tdt"] ||
                        [manifest[@"family"] isEqual:@"runtime_verified_asr"];
  BOOL verifiedCompatibility =
      [manifest[@"compatibility"] isEqual:@"compatible"] ||
      [self isPinnedDefaultIdentity:manifest];
  BOOL shape = [manifest[@"engine"] isEqual:@"nemo_speech_cpp"] &&
               verifiedFamily && verifiedCompatibility &&
               [manifest[@"format"] isEqual:@"gguf"] &&
               [manifest[@"managed"] boolValue] &&
               [self isLowerHex:manifest[@"revision"] length:40] &&
               [self isLowerHex:manifest[@"sha256"] length:64] &&
               [manifest[@"expectedBytes"] unsignedLongLongValue] > 0 &&
               size == [manifest[@"expectedBytes"] unsignedLongLongValue] &&
               [[self sha256:modelPath] isEqual:manifest[@"sha256"]];
  if (!shape)
    return NO;
  if (!expected)
    return YES;
  return [manifest[@"id"] isEqual:expected[@"id"]] &&
         [manifest[@"revision"] isEqual:expected[@"revision"]] &&
         [manifest[@"sha256"] isEqual:expected[@"sha256"]] &&
         [manifest[@"expectedBytes"] unsignedLongLongValue] ==
             [expected[@"expectedBytes"] unsignedLongLongValue] &&
         [manifest[@"modelKey"] unsignedLongLongValue] ==
             [expected[@"modelKey"] unsignedLongLongValue];
}

- (BOOL)validateDefaultDirectory:(NSString *)directory {
  return [self validateManagedDirectory:directory
                               expected:[self defaultManifest:0]];
}

- (void)loadIndex {
  NSData *data = [NSData dataWithContentsOfFile:self.indexPath];
  NSDictionary *index = data ? [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil]
                             : nil;
  if ([index[@"models"] isKindOfClass:NSArray.class]) {
    for (NSDictionary *record in index[@"models"]) {
      if (![record isKindOfClass:NSDictionary.class])
        continue;
      NSString *path = record[@"path"];
      if (![path isKindOfClass:NSString.class])
        continue;
      NSMutableDictionary *recordCopy = [record mutableCopy];
      BOOL verifiedFamily =
          [recordCopy[@"family"] isEqual:@"parakeet_tdt"] ||
          [recordCopy[@"family"] isEqual:@"runtime_verified_asr"];
      BOOL verifiedCompatibility =
          [recordCopy[@"compatibility"] isEqual:@"compatible"] ||
          [self isPinnedDefaultIdentity:recordCopy];
      if ([recordCopy[@"engine"] isEqual:@"nemo_speech_cpp"] &&
          verifiedFamily &&
          [recordCopy[@"format"] isEqual:@"gguf"] &&
          verifiedCompatibility) {
        recordCopy[@"compatibility"] = @"compatible";
        if (!recordCopy[@"languages"])
          recordCopy[@"languages"] = @[];
      }
      [self.models addObject:recordCopy];
    }
  }
  self.activeModelKey = [index[@"activeModelKey"] unsignedLongLongValue];
  NSMutableDictionary *active = [self modelForKey:self.activeModelKey];
  NSString *activePath = active[@"path"];
  BOOL activeValid = NO;
  if ([active[@"managed"] boolValue]) {
    activeValid = [self
        validateManagedDirectory:[activePath stringByDeletingLastPathComponent]
                        expected:active];
  } else if (activePath.length) {
    activeValid = [self validatedLocalManifestForModel:activePath
                                                 error:nil] != nil;
  }
  if (activeValid) {
    self.activeModelPath = activePath;
  } else {
    self.activeModelKey = 0;
    self.activeModelPath = nil;
    [self saveIndexDurably];
  }
}

- (BOOL)saveIndexDurably {
  NSDictionary *index = @{
    @"schemaVersion" : @1,
    @"activeModelKey" : @(self.activeModelKey),
    @"models" : self.models
  };
  NSData *data =
      [NSJSONSerialization dataWithJSONObject:index
                                      options:NSJSONWritingPrettyPrinted
                                        error:nil];
  if (!data)
    return NO;
  NSString *temporary = [self.indexPath
      stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
  if (![data writeToFile:temporary options:0 error:nil])
    return NO;
  int descriptor = open(temporary.fileSystemRepresentation, O_RDONLY);
  if (descriptor < 0 || fsync(descriptor) != 0) {
    if (descriptor >= 0)
      close(descriptor);
    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    return NO;
  }
  close(descriptor);
  if (rename(temporary.fileSystemRepresentation,
             self.indexPath.fileSystemRepresentation) != 0) {
    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    return NO;
  }
  return [self fsyncDirectory:self.modelsRoot];
}

- (BOOL)fsyncDirectory:(NSString *)path {
  int descriptor = open(path.fileSystemRepresentation, O_RDONLY);
  if (descriptor < 0)
    return NO;
  BOOL ok = fsync(descriptor) == 0;
  close(descriptor);
  return ok;
}

- (NSMutableDictionary *)modelForKey:(uint64_t)key {
  for (NSMutableDictionary *model in self.models) {
    if ([model[@"modelKey"] unsignedLongLongValue] == key)
      return model;
  }
  return nil;
}

- (NSDictionary *)publicModel:(NSDictionary *)model {
  NSArray *languages = model[@"languages"];
  NSString *sourceLabel = [model[@"source"] isEqual:@"local"]
                              ? @"Local file · reference only"
                              : @"Hugging Face · managed by Friday";
  NSString *sizeText = [NSByteCountFormatter
      stringFromByteCount:[model[@"installedBytes"] longLongValue]
               countStyle:NSByteCountFormatterCountStyleFile];
  return @{
    @"modelKey" : model[@"modelKey"] ?: @0,
    @"displayName" : model[@"displayName"] ?: @"Model",
    @"source" : model[@"source"] ?: @"local",
    @"sourceLabel" : sourceLabel,
    @"languageSummary" : [NSString
        stringWithFormat:@"%lu languages", (unsigned long)languages.count],
    @"sizeText" : sizeText,
    @"managed" : model[@"managed"] ?: @NO,
    @"installedBytes" : model[@"installedBytes"] ?: @0,
    @"license" : model[@"license"] ?: @"Unknown",
    @"languages" : model[@"languages"] ?: @[],
    @"compatibility" : model[@"compatibility"] ?: @"unknown",
    @"active" :
        @([model[@"modelKey"] unsignedLongLongValue] == self.activeModelKey)
  };
}

- (BOOL)isLowerHex:(NSString *)value length:(NSUInteger)length {
  if (value.length != length)
    return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
  return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

- (NSDictionary *)pendingResumeStatus {
  NSArray<NSString *> *directories =
      [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.downloadsRoot
                                                        error:nil]
          ?: @[];
  NSUInteger inspected = 0;
  for (NSString *directoryName in directories) {
    if (inspected >= 32)
      break;
    inspected += 1;
    NSString *directory =
        [self.downloadsRoot stringByAppendingPathComponent:directoryName];
    NSString *resumePath =
        [directory stringByAppendingPathComponent:@"resume.json"];
    NSString *partialPath =
        [directory stringByAppendingPathComponent:@"download.partial"];
    NSData *data = [NSData dataWithContentsOfFile:resumePath];
    NSDictionary *resume = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                  options:0
                                                                    error:nil]
                                : nil;
    uint64_t partialBytes =
        [[[NSFileManager.defaultManager attributesOfItemAtPath:partialPath
                                                         error:nil]
            objectForKey:NSFileSize] unsignedLongLongValue];
    uint64_t expected = [resume[@"expectedBytes"] unsignedLongLongValue];
    NSString *url = resume[@"url"];
    NSString *revision = resume[@"revision"];
    NSString *artifact = resume[@"artifact"];
    NSString *sha = resume[@"sha256"];
    BOOL safeArtifact = artifact.length > 0 && artifact.length <= 256 &&
                        [artifact isEqual:artifact.lastPathComponent];
    BOOL valid =
        [resume isKindOfClass:NSDictionary.class] &&
        [url hasPrefix:@"https://huggingface.co/"] &&
        [self isLowerHex:revision length:40] &&
        [self isLowerHex:sha length:64] && safeArtifact && expected > 0 &&
        expected <= 8ULL * 1024 * 1024 * 1024 && partialBytes > 0 &&
        partialBytes < expected &&
        [resume[@"partialBytes"] unsignedLongLongValue] == partialBytes;
    if (valid)
      return @{
        @"available" : @YES,
        @"downloadedBytes" : @(partialBytes),
        @"totalBytes" : @(expected),
        @"modelName" : resume[@"displayName"] ?: @"Parakeet model",
        @"repository" : resume[@"repository"] ?: @""
      };
  }
  return @{
    @"available" : @NO,
    @"downloadedBytes" : @0,
    @"totalBytes" : @0,
    @"modelName" : @""
  };
}

- (NSDictionary *)status {
  __block NSDictionary *status;
  dispatch_block_t read = ^{
    NSMutableArray *models = [NSMutableArray array];
    uint64_t usage = 0;
    for (NSDictionary *model in self.models) {
      [models addObject:[self publicModel:model]];
      if ([model[@"managed"] boolValue])
        usage += [model[@"installedBytes"] unsignedLongLongValue];
    }
    NSDictionary *active = [self modelForKey:self.activeModelKey];
    NSArray *languages = active[@"languages"];
    NSString *source = [active[@"source"] isEqual:@"local"]
                           ? @"Local file · reference only"
                           : @"Hugging Face · managed by Friday";
    NSString *activeSize =
        active
            ? [NSByteCountFormatter
                  stringFromByteCount:[active[@"installedBytes"] longLongValue]
                           countStyle:NSByteCountFormatterCountStyleFile]
            : @"";
    NSString *managedSize = [NSByteCountFormatter
        stringFromByteCount:(long long)usage
                 countStyle:NSByteCountFormatterCountStyleFile];
    NSDictionary *pending = [self pendingResumeStatus];
    status = @{
      @"ok" : @YES,
      @"activeModelKey" : @(self.activeModelKey),
      @"activeModelReady" :
          @(self.activeModelKey != 0 && self.activeModelPath.length > 0 &&
            self.activeRuntimeReady),
      @"activeModelName" : active[@"displayName"] ?: @"",
      @"activeModelSource" : active ? source : @"",
      @"activeModelLicense" : active[@"license"] ?: @"",
      @"activeModelLanguages" : active
          ? [NSString stringWithFormat:@"%lu languages",
                                       (unsigned long)languages.count]
          : @"",
      @"activeModelBytes" : active[@"installedBytes"] ?: @0,
      @"activeModelSizeText" : activeSize,
      @"managedModelSizeText" : managedSize,
      @"models" : models,
      @"modelCount" : @(models.count),
      @"managedBytes" : @(usage),
      @"downloadActive" : @(self.task != nil),
      @"downloadedBytes" : @(self.downloaded),
      @"totalBytes" : @(self.total),
      @"pendingResumeAvailable" : pending[@"available"],
      @"pendingDownloadedBytes" : pending[@"downloadedBytes"],
      @"pendingTotalBytes" : pending[@"totalBytes"],
      @"pendingModelName" : pending[@"modelName"]
    };
  };
  if (dispatch_get_specific(FridayRepositoryQueueKey))
    read();
  else
    dispatch_sync(self.queue, read);
  return status;
}

- (NSDictionary *)defaultManifest:(uint64_t)installedBytes {
  return @{
    @"downloadURL" : FridayURL,
    @"provider" : @"Hugging Face",
    @"attribution" : @"NVIDIA Parakeet TDT 0.6B v3",
    @"schemaVersion" : @1,
    @"modelKey" : @(FridayDefaultKey),
    @"id" : FridayModelID,
    @"displayName" : @"Parakeet TDT 0.6B v3",
    @"repository" : FridayModelID,
    @"revision" : FridayRevision,
    @"artifact" : FridayArtifact,
    @"sha256" : FridaySHA,
    @"expectedBytes" : @(FridayBytes),
    @"installedBytes" : @(installedBytes),
    @"engine" : @"nemo_speech_cpp",
    @"family" : @"parakeet_tdt",
    @"format" : @"gguf",
    @"languages" : @[
      @"bg", @"cs", @"da", @"de", @"el", @"en", @"es", @"et", @"fi",
      @"fr", @"hr", @"hu", @"it", @"lt", @"lv", @"mt", @"nl", @"pl",
      @"pt", @"ro", @"ru", @"sk", @"sl", @"sv", @"uk"
    ],
    @"license" : @"CC-BY-4.0",
    @"source" : @"hugging_face",
    @"managed" : @YES,
    @"compatibility" : @"compatible"
  };
}

- (BOOL)loadResumeForPartial:(NSString *)partialPath {
  NSData *data = [NSData dataWithContentsOfURL:self.resumeURL];
  NSDictionary *resume = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                options:0
                                                                  error:nil]
                              : nil;
  uint64_t partialBytes =
      [[[NSFileManager.defaultManager attributesOfItemAtPath:partialPath
                                                       error:nil]
          objectForKey:NSFileSize] unsignedLongLongValue];
  BOOL valid =
      [resume[@"url"] isEqual:self.downloadManifest[@"downloadURL"]] &&
      [resume[@"revision"] isEqual:self.downloadManifest[@"revision"]] &&
      [resume[@"artifact"] isEqual:self.downloadManifest[@"artifact"]] &&
      [resume[@"sha256"] isEqual:self.downloadManifest[@"sha256"]] &&
      [resume[@"repository"] isEqual:self.downloadManifest[@"repository"]] &&
      [resume[@"expectedBytes"] unsignedLongLongValue] ==
          [self.downloadManifest[@"expectedBytes"] unsignedLongLongValue] &&
      [resume[@"partialBytes"] unsignedLongLongValue] == partialBytes &&
      partialBytes <=
          [self.downloadManifest[@"expectedBytes"] unsignedLongLongValue];
  self.resume = valid ? [resume mutableCopy] : [NSMutableDictionary dictionary];
  if (!valid) {
    [NSFileManager.defaultManager removeItemAtPath:partialPath error:nil];
    [NSData.data writeToFile:partialPath atomically:YES];
    partialBytes = 0;
  }
  self.downloaded = partialBytes;
  return valid;
}

- (void)persistResumeDurably {
  self.resume[@"schemaVersion"] = @1;
  self.resume[@"url"] = self.downloadManifest[@"downloadURL"];
  self.resume[@"revision"] = self.downloadManifest[@"revision"];
  self.resume[@"artifact"] = self.downloadManifest[@"artifact"];
  self.resume[@"sha256"] = self.downloadManifest[@"sha256"];
  self.resume[@"repository"] = self.downloadManifest[@"repository"];
  self.resume[@"displayName"] = self.downloadManifest[@"displayName"];
  self.resume[@"expectedBytes"] = self.downloadManifest[@"expectedBytes"];
  self.resume[@"manifest"] = self.downloadManifest;
  self.resume[@"partialBytes"] = @(self.downloaded);
  NSData *data =
      [NSJSONSerialization dataWithJSONObject:self.resume
                                      options:NSJSONWritingPrettyPrinted
                                        error:nil];
  NSString *temporary = [self.resumeURL.path stringByAppendingString:@".tmp"];
  if (![data writeToFile:temporary options:0 error:nil])
    return;
  int descriptor = open(temporary.fileSystemRepresentation, O_RDONLY);
  if (descriptor >= 0) {
    fsync(descriptor);
    close(descriptor);
  }
  rename(temporary.fileSystemRepresentation,
         self.resumeURL.path.fileSystemRepresentation);
  [self fsyncDirectory:self.resumeURL.path.stringByDeletingLastPathComponent];
  self.lastResumePersisted = self.downloaded;
}

- (void)beginDownloadManifest:(NSDictionary *)manifest
                    operation:(uint64_t)operationID
                   completion:(void (^)(NSDictionary *))completion {
  [self onQueue:^{
    uint64_t modelKey = [manifest[@"modelKey"] unsignedLongLongValue];
    NSMutableDictionary *installed = [self modelForKey:modelKey];
    if (installed &&
        [self validateManagedDirectory:[installed[@"path"]
                                           stringByDeletingLastPathComponent]
                              expected:installed]) {
      [self selectKey:modelKey generation:operationID completion:completion];
      return;
    }
    if (self.task || self.completion || self.metadataTask) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"code" : @"download_active",
          @"message" : @"A model operation is already active."
        });
      });
      return;
    }
    self.downloadManifest = [manifest mutableCopy];
    self.operation = operationID;
    self.completion = completion;
    self.cancelled = NO;
    self.responseValid = NO;
    NSString *operationRoot = [self.downloadsRoot
        stringByAppendingPathComponent:[NSString stringWithFormat:@"model-%llu",
                                                                  modelKey]];
    [NSFileManager.defaultManager createDirectoryAtPath:operationRoot
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    self.partialURL = [NSURL
        fileURLWithPath:
            [operationRoot stringByAppendingPathComponent:@"download.partial"]];
    self.resumeURL = [NSURL
        fileURLWithPath:[operationRoot
                            stringByAppendingPathComponent:@"resume.json"]];
    if (![NSFileManager.defaultManager fileExistsAtPath:self.partialURL.path])
      [NSData.data writeToURL:self.partialURL atomically:YES];
    [self loadResumeForPartial:self.partialURL.path];
    self.total = [manifest[@"expectedBytes"] unsignedLongLongValue];
    self.handle = [NSFileHandle fileHandleForWritingToURL:self.partialURL
                                                    error:nil];
    [self.handle seekToEndOfFile];
    NSURL *downloadURL = [NSURL URLWithString:manifest[@"downloadURL"]];
    if (!downloadURL) {
      [self fail:@"The resolved model download address is invalid."
            code:@"invalid_download_url"];
      return;
    }
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:downloadURL];
    request.timeoutInterval = 120;
    if (self.downloaded > 0) {
      [request setValue:[NSString
                            stringWithFormat:@"bytes=%llu-", self.downloaded]
          forHTTPHeaderField:@"Range"];
      NSString *validator =
          self.resume[@"etag"] ?: self.resume[@"lastModified"];
      if (validator.length)
        [request setValue:validator forHTTPHeaderField:@"If-Range"];
    }
    self.task = [self.session dataTaskWithRequest:request];
    [self publishProgress:@"downloading"
               downloaded:self.downloaded
                    total:self.total];
    [self.task resume];
  }];
}

- (void)downloadDefaultOperation:(uint64_t)operationID
                      completion:(void (^)(NSDictionary *))completion {
  [self beginDownloadManifest:[self defaultManifest:0]
                    operation:operationID
                   completion:completion];
}

- (void)resumePendingOperation:(uint64_t)operationID
                    completion:(void (^)(NSDictionary *))completion {
  [self onQueue:^{
    NSArray<NSString *> *directories =
        [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:self.downloadsRoot
                                error:nil]
            ?: @[];
    for (NSString *directoryName in directories) {
      NSString *resumePath =
          [[self.downloadsRoot stringByAppendingPathComponent:directoryName]
              stringByAppendingPathComponent:@"resume.json"];
      NSData *data = [NSData dataWithContentsOfFile:resumePath];
      NSDictionary *resume = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                    options:0
                                                                      error:nil]
                                  : nil;
      NSDictionary *manifest =
          [resume[@"manifest"] isKindOfClass:NSDictionary.class]
              ? resume[@"manifest"]
              : nil;
      if (!manifest)
        continue;
      NSString *partialPath = [resumePath.stringByDeletingLastPathComponent
          stringByAppendingPathComponent:@"download.partial"];
      uint64_t partialBytes =
          [[[NSFileManager.defaultManager attributesOfItemAtPath:partialPath
                                                           error:nil]
              objectForKey:NSFileSize] unsignedLongLongValue];
      uint64_t expected = [manifest[@"expectedBytes"] unsignedLongLongValue];
      BOOL verifiedShape =
          [manifest[@"engine"] isEqual:@"nemo_speech_cpp"] &&
          ([manifest[@"family"] isEqual:@"parakeet_tdt"] ||
           [manifest[@"family"] isEqual:@"runtime_verified_asr"]) &&
          [manifest[@"compatibility"] isEqual:@"compatible"];
      BOOL candidateShape =
          [manifest[@"engine"] isEqual:@"unverified"] &&
          [manifest[@"family"] isEqual:@"unverified"] &&
          [manifest[@"compatibility"] isEqual:@"unverified_candidate"];
      BOOL valid = (verifiedShape || candidateShape) &&
          [manifest[@"format"] isEqual:@"gguf"] &&
          [manifest[@"managed"] boolValue] &&
          [self isLowerHex:manifest[@"revision"] length:40] &&
          [self isLowerHex:manifest[@"sha256"] length:64] &&
          [resume[@"partialBytes"] unsignedLongLongValue] == partialBytes &&
          partialBytes > 0 && partialBytes < expected &&
          [resume[@"url"] isEqual:manifest[@"downloadURL"]];
      if (valid) {
        [self beginDownloadManifest:manifest
                          operation:operationID
                         completion:completion];
        return;
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(@{
        @"ok" : @NO,
        @"code" : @"resume_unavailable",
        @"message" : @"No valid partial model download is available to resume."
      });
    });
  }];
}

- (void)cancelOperation:(uint64_t)operationID {
  [self onQueue:^{
    if (self.metadataTask && operationID == self.metadataOperation) {
      [self.metadataTask cancel];
      self.metadataTask = nil;
      self.metadataCompletion = nil;
    }
    if (!self.task || operationID != self.operation)
      return;
    self.cancelled = YES;
    [self.task cancel];
  }];
}

- (BOOL)validateContentRange:(NSString *)value start:(uint64_t)expectedStart {
  if (![value hasPrefix:@"bytes "])
    return NO;
  NSArray<NSString *> *parts =
      [[value substringFromIndex:6] componentsSeparatedByString:@"/"];
  if (parts.count != 2 ||
      [(NSString *)parts[1] longLongValue] != (long long)self.total)
    return NO;
  NSArray<NSString *> *range =
      [(NSString *)parts[0] componentsSeparatedByString:@"-"];
  return range.count == 2 &&
         [(NSString *)range[0] longLongValue] == (long long)expectedStart;
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))reply {
  (void)session;
  if (task != self.task) {
    reply(NSURLSessionResponseCancel);
    return;
  }
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
  NSInteger status = http.statusCode;
  NSString *etag =
      http.allHeaderFields[@"Etag"] ?: http.allHeaderFields[@"ETag"];
  NSString *lastModified = http.allHeaderFields[@"Last-Modified"];
  BOOL validatorMatches = YES;
  if (self.resume[@"etag"] && etag)
    validatorMatches = [self.resume[@"etag"] isEqual:etag];
  else if (self.resume[@"lastModified"] && lastModified)
    validatorMatches = [self.resume[@"lastModified"] isEqual:lastModified];
  BOOL rangeValid =
      status == 206 &&
      [self validateContentRange:http.allHeaderFields[@"Content-Range"]
                           start:self.downloaded];
  if (status == 200) {
    [self.handle truncateFileAtOffset:0];
    self.downloaded = 0;
    rangeValid = YES;
    validatorMatches = YES;
  }
  self.responseValid = rangeValid && validatorMatches;
  if (etag)
    self.resume[@"etag"] = etag;
  if (lastModified)
    self.resume[@"lastModified"] = lastModified;
  [self persistResumeDurably];
  reply(self.responseValid ? NSURLSessionResponseAllow
                           : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
  (void)session;
  if (task != self.task || self.cancelled)
    return;
  [self.handle writeData:data];
  self.downloaded += data.length;
  if (self.downloaded - self.lastResumePersisted >= 1024 * 1024)
    [self persistResumeDurably];
  [self publishProgress:@"downloading"
             downloaded:self.downloaded
                  total:self.total];
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  (void)session;
  if (task != self.task)
    return;
  [self.handle synchronizeFile];
  [self.handle closeFile];
  self.handle = nil;
  self.task = nil;
  [self persistResumeDurably];
  if (self.cancelled) {
    [self publishProgress:@"cancelled"
               downloaded:self.downloaded
                    total:self.total];
    [self complete:@{
      @"ok" : @NO,
      @"cancelled" : @YES,
      @"resumeBytes" : @(self.downloaded),
      @"code" : @"cancelled"
    }];
    return;
  }
  if (error || !self.responseValid) {
    [self fail:error.localizedDescription
                   ?: @"The server returned an invalid resume response."
          code:@"download_failed"];
    return;
  }
  [self publishProgress:@"verifying"
             downloaded:self.downloaded
                  total:self.total];
  [self verifyAndInstall];
}

- (NSString *)sha256:(NSString *)path {
  NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!handle)
    return @"";
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  while (YES) {
    @autoreleasepool {
      NSData *data = [handle readDataOfLength:1024 * 1024];
      if (!data.length)
        break;
      CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
    }
  }
  [handle closeFile];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString *hex =

      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < sizeof(digest); ++index)
    [hex appendFormat:@"%02x", digest[index]];
  return hex;
}
- (nullable NSString *)boundedGGUFFamilyHint:(NSString *)path {
  NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!handle)
    return nil;
  NSData *header = [handle readDataOfLength:24];
  [handle closeFile];
  if (header.length != 24 || memcmp(header.bytes, "GGUF", 4) != 0)
    return nil;
  const uint8_t *bytes = static_cast<const uint8_t *>(header.bytes);
  uint32_t version = (uint32_t)bytes[4] | ((uint32_t)bytes[5] << 8) |
                     ((uint32_t)bytes[6] << 16) |
                     ((uint32_t)bytes[7] << 24);
  uint64_t tensorCount = 0;
  uint64_t metadataCount = 0;
  for (NSUInteger index = 0; index < 8; ++index) {
    tensorCount |= ((uint64_t)bytes[8 + index]) << (index * 8);
    metadataCount |= ((uint64_t)bytes[16 + index]) << (index * 8);
  }
  if ((version != 2 && version != 3) || tensorCount == 0 ||
      tensorCount > 1000000 || metadataCount == 0 ||
      metadataCount > 100000)
    return nil;
  // A valid GGUF header does not prove an ASR architecture. The successful
  // runtime probe below proves usability, but the family remains generic.
  return @"runtime_verified_asr";
}
- (void)finishPublicationAtDirectory:(NSString *)directory
                            manifest:(NSDictionary *)manifest
                                size:(uint64_t)size {
  NSString *finalModel =
      [directory stringByAppendingPathComponent:@"model.gguf"];
  [self.recognizer
      activateModelAtPath:finalModel
               generation:self.operation
               completion:^(NSDictionary *finalProbe) {
                 [self onQueue:^{
                   if (![finalProbe[@"ok"] boolValue]) {
                     [self fail:finalProbe[@"message"]
                                    ?: @"The published model failed its final "
                                       @"runtime probe."
                           code:@"published_model_probe_failed"];
                     return;
                   }
                   NSMutableDictionary *record = [manifest mutableCopy];
                   uint64_t modelKey =
                       [manifest[@"modelKey"] unsignedLongLongValue];
                   record[@"path"] = finalModel;
                   record[@"installedBytes"] = @(size);
                   NSMutableDictionary *old = [self modelForKey:modelKey];
                   uint64_t previousKey = self.activeModelKey;
                   NSString *previousPath = self.activeModelPath;
                   if (old)
                     [self.models removeObject:old];
                   [self.models addObject:record];
                   self.activeModelKey = modelKey;
                   self.activeModelPath = finalModel;
                   self.activeRuntimeReady = YES;
                   if (![self saveIndexDurably]) {
                     [self.models removeObject:record];
                     if (old)
                       [self.models addObject:old];
                     self.activeModelKey = previousKey;
                     self.activeModelPath = previousPath;
                     self.activeRuntimeReady = previousPath.length > 0;
                     [self fail:@"The verified model was published, but the "
                                @"durable index update failed."
                           code:@"index_publication_failed"];
                     return;
                   }
                   [NSFileManager.defaultManager removeItemAtURL:self.resumeURL
                                                           error:nil];
                   [NSFileManager.defaultManager
                       removeItemAtPath:self.partialURL.path
                                            .stringByDeletingLastPathComponent
                                  error:nil];
                   [self publishProgress:@"installed"
                              downloaded:size
                                   total:size];
                   [self complete:@{
                     @"ok" : @YES,
                     @"modelKey" : @(modelKey),
                     @"message" : [NSString
                         stringWithFormat:@"%@ is verified, warm, and active.",
                                          manifest[@"displayName"]
                                              ?: @"The model"],
                     @"probe" : finalProbe
                   }];
                 }];
               }];
}

- (void)verifyAndInstall {
  uint64_t size = [[[NSFileManager.defaultManager
      attributesOfItemAtPath:self.partialURL.path
                       error:nil] objectForKey:NSFileSize]
      unsignedLongLongValue];
  NSString *digest = [self sha256:self.partialURL.path];
  if (size != [self.downloadManifest[@"expectedBytes"] unsignedLongLongValue] ||
      ![digest isEqual:self.downloadManifest[@"sha256"]]) {
    [self fail:@"The model failed exact size/SHA-256 verification."
          code:@"integrity_failed"];
    return;
  }
  NSString *boundedFamilyHint =
      [self boundedGGUFFamilyHint:self.partialURL.path];
  if (!boundedFamilyHint) {
    [self fail:@"The artifact is not a bounded, readable GGUF candidate."
          code:@"gguf_metadata_invalid"];
    return;
  }
  NSString *staging = [self.modelsRoot
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@".install-%@",
                                                          NSUUID.UUID
                                                              .UUIDString]];
  [NSFileManager.defaultManager createDirectoryAtPath:staging
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString *stagedModel =
      [staging stringByAppendingPathComponent:@"model.gguf"];
  if (![NSFileManager.defaultManager moveItemAtPath:self.partialURL.path
                                             toPath:stagedModel
                                              error:nil]) {
    [self fail:@"The verified model could not be staged."
          code:@"install_failed"];
    return;
  }
  NSMutableDictionary *manifest = [self.downloadManifest mutableCopy];
  manifest[@"installedBytes"] = @(size);
  NSString *manifestPath =
      [staging stringByAppendingPathComponent:@"manifest.json"];
  NSData *manifestData =
      [NSJSONSerialization dataWithJSONObject:manifest
                                      options:NSJSONWritingPrettyPrinted
                                        error:nil];
  [manifestData writeToFile:manifestPath options:0 error:nil];
  for (NSString *path in @[ stagedModel, manifestPath ]) {
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY);
    if (descriptor >= 0) {
      fsync(descriptor);
      close(descriptor);
    }
  }
  [self fsyncDirectory:staging];
  [self.recognizer
      activateModelAtPath:stagedModel
               generation:self.operation
               completion:^(NSDictionary *probe) {
                 [self onQueue:^{
                   if (![probe[@"ok"] boolValue]) {
                     [NSFileManager.defaultManager removeItemAtPath:staging
                                                              error:nil];
                     [self fail:probe[@"message"]
                                    ?: @"The model failed its runtime probe."
                           code:@"model_probe_failed"];
                     return;
                   }
                   if ([manifest[@"compatibility"]
                           isEqual:@"unverified_candidate"]) {
                     manifest[@"engine"] = @"nemo_speech_cpp";
                     manifest[@"family"] = boundedFamilyHint;
                     manifest[@"compatibility"] = @"compatible";
                     manifest[@"verification"] =
                         @"exact_integrity_and_runtime_probe";
                     NSData *verifiedManifestData =
                         [NSJSONSerialization
                             dataWithJSONObject:manifest
                                        options:NSJSONWritingPrettyPrinted
                                          error:nil];
                     if (!verifiedManifestData ||
                         ![verifiedManifestData writeToFile:manifestPath
                                                    options:0
                                                      error:nil]) {
                       [NSFileManager.defaultManager
                           removeItemAtPath:staging
                                      error:nil];
                       [self fail:@"The runtime-verified manifest could not be "
                                  @"written durably."
                             code:@"verified_manifest_write_failed"];
                       return;
                     }
                     int descriptor =
                         open(manifestPath.fileSystemRepresentation, O_RDONLY);
                     if (descriptor >= 0) {
                       fsync(descriptor);
                       close(descriptor);
                     }
                     [self fsyncDirectory:staging];
                   }
                   NSString *idRoot = [self.modelsRoot
                       stringByAppendingPathComponent:manifest[@"id"]];
                   if (![NSFileManager.defaultManager
                                 createDirectoryAtPath:idRoot
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil]) {
                     [self fail:@"The verified model root could not be created."
                           code:@"publication_root_failed"];
                     return;
                   }
                   NSString *revision = manifest[@"revision"];
                   NSString *finalDirectory =
                       [idRoot stringByAppendingPathComponent:revision];
                   BOOL reuseExisting =
                       [NSFileManager.defaultManager
                           fileExistsAtPath:finalDirectory] &&
                       [self validateManagedDirectory:finalDirectory
                                             expected:manifest];
                   if (reuseExisting) {
                     [NSFileManager.defaultManager removeItemAtPath:staging
                                                              error:nil];
                   } else {
                     if ([NSFileManager.defaultManager
                             fileExistsAtPath:finalDirectory]) {
                       finalDirectory = [idRoot
                           stringByAppendingPathComponent:
                               [NSString
                                   stringWithFormat:@"%@-verified-%@", revision,
                                                    NSUUID.UUID.UUIDString]];
                     }
                     if (rename(staging.fileSystemRepresentation,
                                finalDirectory.fileSystemRepresentation) != 0) {
                       [self fail:@"The verified staging model could not be "
                                  @"atomically published; staging was retained."
                             code:@"atomic_publication_failed"];
                       return;
                     }
                   }
                   if (![self fsyncDirectory:idRoot] ||
                       ![self fsyncDirectory:self.modelsRoot]) {
                     [self fail:@"The model directory publication could not be "
                                @"made durable."
                           code:@"publication_fsync_failed"];
                     return;
                   }
                   if (![self validateManagedDirectory:finalDirectory
                                              expected:manifest]) {
                     [self fail:@"The published final model failed "
                                @"manifest/size/SHA validation."
                           code:@"published_model_invalid"];
                     return;
                   }
                   [self finishPublicationAtDirectory:finalDirectory
                                             manifest:manifest
                                                 size:size];
                 }];
               }];
}

- (void)fail:(NSString *)message code:(NSString *)code {
  [self publishProgress:@"failed" downloaded:self.downloaded total:self.total];
  [self complete:@{@"ok" : @NO, @"code" : code, @"message" : message}];
}

- (NSDictionary *)validatedLocalManifestForModel:(NSString *)path
                                           error:(NSString **)error {
  NSString *manifestPath = [[path stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"manifest.json"];
  NSData *data = [NSData dataWithContentsOfFile:manifestPath];
  NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                  options:0
                                                                    error:nil]
                                : nil;
  BOOL shape = [manifest[@"engine"] isEqual:@"nemo_speech_cpp"] &&
               [manifest[@"family"] isEqual:@"parakeet_tdt"] &&
               [manifest[@"format"] isEqual:@"gguf"] &&
               [manifest[@"license"] isKindOfClass:NSString.class] &&
               [manifest[@"languages"] isKindOfClass:NSArray.class] &&
               [manifest[@"sha256"] isKindOfClass:NSString.class] &&
               [manifest[@"expectedBytes"] unsignedLongLongValue] > 0;
  if (!shape) {
    if (error)
      *error =
          @"A local model requires a complete Friday manifest proving Parakeet "
          @"TDT GGUF compatibility, integrity, languages, and license.";
    return nil;
  }
  uint64_t size = [[[NSFileManager.defaultManager attributesOfItemAtPath:path
                                                                   error:nil]
      objectForKey:NSFileSize] unsignedLongLongValue];
  if (size != [manifest[@"expectedBytes"] unsignedLongLongValue] ||
      ![[self sha256:path] isEqual:manifest[@"sha256"]]) {
    if (error)
      *error =
          @"The local model does not match its sidecar size/SHA-256 metadata.";
    return nil;
  }
  return manifest;
}

- (void)addLocalPath:(NSString *)path
                 key:(uint64_t)key
          generation:(uint64_t)generation
          completion:(void (^)(NSDictionary *))completion {
  [self onQueue:^{
    if (![path.pathExtension.lowercaseString isEqual:@"gguf"]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"code" : @"incompatible",
          @"message" :
              @"Friday accepts manifest-backed Parakeet TDT GGUF files only."
        });
      });
      return;
    }
    NSData *magic =
        [[NSFileHandle fileHandleForReadingAtPath:path] readDataOfLength:4];
    if (magic.length != 4 || memcmp(magic.bytes, "GGUF", 4) != 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"code" : @"malformed_gguf",
          @"message" : @"The selected file is not GGUF."
        });
      });
      return;
    }
    NSString *metadataError = nil;
    NSDictionary *manifest =
        [self validatedLocalManifestForModel:path error:&metadataError];
    if (!manifest) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"code" : @"metadata_required",
          @"message" : metadataError
        });
      });
      return;
    }
    [self.recognizer
        activateModelAtPath:path
                 generation:generation
                 completion:^(NSDictionary *probe) {
                   [self onQueue:^{
                     if (![probe[@"ok"] boolValue]) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                         completion(probe);
                       });
                       return;
                     }
                     NSMutableDictionary *record = [manifest mutableCopy];
                     record[@"modelKey"] = @(key);
                     record[@"displayName"] =
                         manifest[@"displayName"]
                             ?: path.lastPathComponent
                                    .stringByDeletingPathExtension;
                     record[@"path"] = path;
                     record[@"source"] = @"local";
                     record[@"managed"] = @NO;
                     record[@"installedBytes"] = manifest[@"expectedBytes"];
                     record[@"compatibility"] = @"compatible";
                     NSMutableDictionary *old = [self modelForKey:key];
                     if (old)
                       [self.models removeObject:old];
                     [self.models addObject:record];
                     self.activeModelKey = key;
                     self.activeModelPath = path;
                     self.activeRuntimeReady = YES;
                     if (![self saveIndexDurably]) {
                       self.activeRuntimeReady = NO;
                       dispatch_async(dispatch_get_main_queue(), ^{
                         completion(@{
                           @"ok" : @NO,
                           @"code" : @"index_publication_failed"
                         });
                       });
                       return;
                     }
                     dispatch_async(dispatch_get_main_queue(), ^{
                       completion(@{
                         @"ok" : @YES,
                         @"modelKey" : @(key),
                         @"probe" : probe
                       });
                     });
                   }];
                 }];
  }];
}

- (BOOL)isSafeHuggingFaceIdentifier:(NSString *)identifier {
  if (identifier.length < 3 || identifier.length > 128)
    return NO;
  NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"/"];
  if (parts.count != 2)
    return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"]
      invertedSet];
  for (NSString *part in parts)
    if (part.length == 0 || part.length > 64 ||
        [part rangeOfCharacterFromSet:invalid].location != NSNotFound ||
        [part isEqual:@"."] || [part isEqual:@".."])
      return NO;
  return YES;
}

- (uint64_t)modelKeyForIdentifier:(NSString *)identifier {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  NSData *data = [identifier dataUsingEncoding:NSUTF8StringEncoding];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  uint32_t prefix = 0;
  memcpy(&prefix, digest, sizeof(prefix));
  return 1000 + ((uint64_t)prefix % 1000000000ULL);
}

- (nullable NSMutableDictionary *)
    manifestFromHuggingFaceMetadata:(NSDictionary *)metadata
                         identifier:(NSString *)identifier
                              error:(NSString **)error {
  id privateValue = metadata[@"private"];
  if ([privateValue isKindOfClass:NSNumber.class] &&
      [(NSNumber *)privateValue boolValue]) {
    if (error)
      *error = @"That Hugging Face repository is private.";
    return nil;
  }
  id gated = metadata[@"gated"];
  if (([gated isKindOfClass:NSNumber.class] &&
       [(NSNumber *)gated boolValue]) ||
      ([gated isKindOfClass:NSString.class] &&
                            ![(NSString *)gated isEqual:@"false"] &&
                            [(NSString *)gated length] > 0)) {
    if (error)
      *error = @"That Hugging Face repository requires gated access.";
    return nil;
  }
  id rawRevision = metadata[@"sha"];
  NSString *revision = [rawRevision isKindOfClass:NSString.class]
                           ? [(NSString *)rawRevision lowercaseString]
                           : @"";
  if (![self isLowerHex:revision length:40]) {
    if (error)
      *error = @"Hugging Face did not return an immutable revision.";
    return nil;
  }
  NSArray *tags =
      [metadata[@"tags"] isKindOfClass:NSArray.class] ? metadata[@"tags"] : @[];
  BOOL asr =
      [metadata[@"pipeline_tag"] isEqual:@"automatic-speech-recognition"];
  NSString *license = nil;
  for (id value in tags) {
    if (![value isKindOfClass:NSString.class])
      continue;
    NSString *tag = [(NSString *)value lowercaseString];
    if ([tag isEqual:@"automatic-speech-recognition"])
      asr = YES;
    if ([tag hasPrefix:@"license:"])
      license = [(NSString *)value substringFromIndex:8];
  }
  NSDictionary *cardData =
      [metadata[@"cardData"] isKindOfClass:NSDictionary.class]
          ? metadata[@"cardData"]
          : @{};
  if ([cardData[@"license"] isKindOfClass:NSString.class])
    license = cardData[@"license"];
  if (!asr) {
    if (error)
      *error = @"The repository does not advertise speech-recognition metadata.";
    return nil;
  }
  if (license.length == 0 || license.length > 64) {
    if (error)
      *error = @"The repository does not provide bounded license metadata.";
    return nil;
  }
  NSArray *siblings = [metadata[@"siblings"] isKindOfClass:NSArray.class]
                          ? metadata[@"siblings"]
                          : @[];
  NSMutableArray<NSDictionary *> *gguf = [NSMutableArray array];
  for (id value in siblings) {
    if (![value isKindOfClass:NSDictionary.class])
      continue;
    id rawName = value[@"rfilename"];
    if (![rawName isKindOfClass:NSString.class])
      continue;
    NSString *name = rawName;
    if ([name.pathExtension.lowercaseString isEqual:@"gguf"] &&
        [name isEqual:name.lastPathComponent] && name.length <= 256)
      [gguf addObject:value];
  }
  if (gguf.count != 1) {
    if (error)
      *error = gguf.count == 0
                   ? @"The repository has no top-level GGUF candidate."
                   : @"The repository has multiple top-level GGUF artifacts; "
                     @"choose an unambiguous source.";
    return nil;
  }
  NSDictionary *sibling = gguf.firstObject;
  NSDictionary *lfs = [sibling[@"lfs"] isKindOfClass:NSDictionary.class]
                          ? sibling[@"lfs"]
                          : @{};
  id rawSHA = lfs[@"sha256"];
  NSString *sha = [rawSHA isKindOfClass:NSString.class]
                      ? [(NSString *)rawSHA lowercaseString]
                      : @"";
  if (!sha.length && [lfs[@"oid"] isKindOfClass:NSString.class]) {
    sha = [lfs[@"oid"] lowercaseString];
    if ([sha hasPrefix:@"sha256:"])
      sha = [sha substringFromIndex:7];
  }
  id rawSize = lfs[@"size"];
  uint64_t expected = [rawSize isKindOfClass:NSNumber.class]
                          ? [(NSNumber *)rawSize unsignedLongLongValue]
                          : 0;
  if (![self isLowerHex:sha length:64] || expected < 1024 * 1024 ||
      expected > 8ULL * 1024 * 1024 * 1024) {
    if (error)
      *error = @"The GGUF artifact is missing a valid LFS SHA-256 or size.";
    return nil;
  }
  NSString *artifact = sibling[@"rfilename"];
  NSString *encodedID =
      [identifier stringByAddingPercentEncodingWithAllowedCharacters:
                      NSCharacterSet.URLPathAllowedCharacterSet];
  NSMutableCharacterSet *artifactAllowed =
      [NSCharacterSet.alphanumericCharacterSet mutableCopy];
  [artifactAllowed addCharactersInString:@"-._~"];
  NSString *encodedArtifact =
      [artifact stringByAddingPercentEncodingWithAllowedCharacters:
                    artifactAllowed];
  NSString *downloadURL =
      [NSString stringWithFormat:@"https://huggingface.co/%@/resolve/%@/%@",
                                 encodedID, revision, encodedArtifact];
  id languages = cardData[@"language"];
  NSArray *languageList = [languages isKindOfClass:NSArray.class] ? languages
                          : [languages isKindOfClass:NSString.class]
                              ? @[ languages ]
                              : @[];
  return [@{
    @"schemaVersion" : @1,
    @"modelKey" : @([self modelKeyForIdentifier:identifier]),
    @"id" : identifier,
    @"displayName" : [metadata[@"modelId"] isKindOfClass:NSString.class]
        ? metadata[@"modelId"]
        : identifier.lastPathComponent,
    @"repository" : identifier,
    @"revision" : revision,
    @"artifact" : artifact,
    @"sha256" : sha,
    @"expectedBytes" : @(expected),
    @"installedBytes" : @0,
    @"downloadURL" : downloadURL,
    @"engine" : @"unverified",
    @"family" : @"unverified",
    @"format" : @"gguf",
    @"languages" : languageList,
    @"license" : license,
    @"provider" : @"Hugging Face",
    @"attribution" : [metadata[@"author"] isKindOfClass:NSString.class]
        ? metadata[@"author"]
        : [[identifier componentsSeparatedByString:@"/"] firstObject],
    @"source" : @"hugging_face",
    @"managed" : @YES,
    @"compatibility" : @"unverified_candidate",
    @"candidateHints" : @[ @"automatic-speech-recognition", @"gguf" ]
  } mutableCopy];
}

- (void)resolveHuggingFaceID:(NSString *)identifier
                   operation:(uint64_t)operation
                  completion:(void (^)(NSDictionary *))completion {
  NSString *normalized = [identifier
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (![self isSafeHuggingFaceIdentifier:normalized]) {
    completion(@{
      @"ok" : @NO,
      @"code" : @"invalid_identifier",
      @"message" : @"Use a public Hugging Face identifier in owner/repository "
                   @"form."
    });
    return;
  }
  [self onQueue:^{
    if (self.task || self.metadataTask || self.completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"code" : @"model_operation_active",
          @"message" : @"Another model operation is active."
        });
      });
      return;
    }
    NSString *encoded =
        [normalized stringByAddingPercentEncodingWithAllowedCharacters:
                        NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *urlString = [NSString
        stringWithFormat:
            @"https://huggingface.co/api/models/%@?blobs=true&"
             "expand%%5B%%5D=siblings&expand%%5B%%5D=cardData&"
             "expand%%5B%%5D=tags&expand%%5B%%5D=sha&"
             "expand%%5B%%5D=gated&expand%%5B%%5D=private&"
             "expand%%5B%%5D=pipeline_tag&expand%%5B%%5D=author",
            encoded];
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 30;
    self.metadataOperation = operation;
    self.metadataCompletion = [completion copy];
    __weak FridayModelRepository *weakSelf = self;
    self.metadataTask = [NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *networkError) {
            FridayModelRepository *strongSelf = weakSelf;
            if (!strongSelf)
              return;
            [strongSelf onQueue:^{
              void (^done)(NSDictionary *) = strongSelf.metadataCompletion;
              strongSelf.metadataCompletion = nil;
              strongSelf.metadataTask = nil;
              if (!done)
                return;
              NSInteger status = [(NSHTTPURLResponse *)response statusCode];
              if (status == 401 || status == 403) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  done(@{
                    @"ok" : @NO,
                    @"code" : @"gated_or_private",
                    @"message" : @"That repository is private or requires "
                                 @"gated access."
                  });
                });
                return;
              }
              if (networkError || status != 200 || data.length == 0 ||
                  data.length > 2 * 1024 * 1024) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  done(@{
                    @"ok" : @NO,
                    @"code" : @"metadata_unavailable",
                    @"message" : networkError.localizedDescription
                        ?: @"Hugging Face metadata is unavailable."
                  });
                });
                return;
              }
              id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil];
              NSDictionary *metadata =
                  [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
              NSString *validationError = nil;
              NSMutableDictionary *manifest =
                  [strongSelf manifestFromHuggingFaceMetadata:metadata
                                                   identifier:normalized
                                                        error:&validationError];
              if (!manifest) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  done(@{
                    @"ok" : @NO,
                    @"code" : @"metadata_candidate_rejected",
                    @"message" : validationError
                        ?: @"The repository is not a safe download candidate."
                  });
                });
                return;
              }
              strongSelf.pendingHFManifests[normalized] = manifest;
              NSString *sizeText = [NSByteCountFormatter
                  stringFromByteCount:[manifest[@"expectedBytes"] longLongValue]
                           countStyle:NSByteCountFormatterCountStyleFile];
              dispatch_async(dispatch_get_main_queue(), ^{
                done(@{
                  @"ok" : @YES,
                  @"identifier" : normalized,
                  @"revision" : manifest[@"revision"],
                  @"artifact" : manifest[@"artifact"],
                  @"expectedBytes" : manifest[@"expectedBytes"],
                  @"sizeText" : sizeText,
                  @"license" : manifest[@"license"],
                  @"provider" : manifest[@"provider"],
                  @"attribution" : manifest[@"attribution"],
                  @"verificationStatus" : @"unverified_candidate"
                });
              });
            }];
          }];
    [self.metadataTask resume];
  }];
}

- (void)downloadResolvedHuggingFaceID:(NSString *)identifier
                            operation:(uint64_t)operation
                           completion:(void (^)(NSDictionary *))completion {
  NSString *normalized = [identifier
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  [self onQueue:^{
    NSDictionary *manifest = self.pendingHFManifests[normalized];
    if (!manifest) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"code" : @"resolution_required",
          @"message" : @"Resolve and confirm this Hugging Face source first."
        });
      });
      return;
    }
    [self beginDownloadManifest:manifest
                      operation:operation
                     completion:completion];
  }];
}

- (void)selectKey:(uint64_t)key
       generation:(uint64_t)generation
       completion:(void (^)(NSDictionary *))completion {
  [self onQueue:^{
    NSMutableDictionary *model = [self modelForKey:key];
    NSString *path = model[@"path"];
    BOOL valid = NO;
    if ([model[@"managed"] boolValue])
      valid = [self
          validateManagedDirectory:[path stringByDeletingLastPathComponent]
                          expected:model];
    else
      valid = [self validatedLocalManifestForModel:path error:nil] != nil;
    if (!model || !valid) {
      self.activeRuntimeReady = NO;
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{@"ok" : @NO, @"code" : @"model_unavailable"});
      });
      return;
    }
    [self.recognizer activateModelAtPath:path
                              generation:generation
                              completion:^(NSDictionary *probe) {
                                [self onQueue:^{
                                  if (![probe[@"ok"] boolValue]) {
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                      completion(probe);
                                    });
                                    return;
                                  }
                                  self.activeModelKey = key;
                                  self.activeModelPath = path;
                                  self.activeRuntimeReady = YES;
                                  if (![self saveIndexDurably]) {
                                    self.activeRuntimeReady = NO;
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                      completion(@{
                                        @"ok" : @NO,
                                        @"code" : @"index_publication_failed"
                                      });
                                    });
                                    return;
                                  }
                                  dispatch_async(dispatch_get_main_queue(), ^{
                                    completion(@{
                                      @"ok" : @YES,
                                      @"modelKey" : @(key),
                                      @"probe" : probe
                                    });
                                  });
                                }];
                              }];
  }];
}

- (BOOL)isSafeManagedDirectory:(NSString *)directory {
  NSString *root =
      [NSURL fileURLWithPath:self.modelsRoot]
          .URLByStandardizingPath.URLByResolvingSymlinksInPath.path;
  NSString *target =
      [NSURL fileURLWithPath:directory]
          .URLByStandardizingPath.URLByResolvingSymlinksInPath.path;
  return [target hasPrefix:[root stringByAppendingString:@"/"]] &&
         ![target isEqual:root];
}

- (NSDictionary *)removeKey:(uint64_t)key deleteManaged:(BOOL)deleteManaged {
  __block NSDictionary *result;
  dispatch_block_t mutation = ^{
    NSMutableDictionary *model = [self modelForKey:key];
    if (!model) {
      result = @{@"ok" : @NO, @"code" : @"not_found"};
      return;
    }
    if ([model[@"managed"] boolValue] && deleteManaged) {
      NSString *directory = [model[@"path"] stringByDeletingLastPathComponent];
      if (![self isSafeManagedDirectory:directory]) {
        result = @{@"ok" : @NO, @"code" : @"unsafe_managed_path"};
        return;
      }
      [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
    [self.models removeObject:model];
    if (self.activeModelKey == key) {
      self.activeModelKey = 0;
      self.activeModelPath = nil;
      self.activeRuntimeReady = NO;
    }
    [self saveIndexDurably];
    result = @{@"ok" : @YES};
  };
  if (dispatch_get_specific(FridayRepositoryQueueKey))
    mutation();
  else
    dispatch_sync(self.queue, mutation);
  return result;
}

- (NSDictionary *)removeFailedDownloads {
  __block NSDictionary *result = nil;
  dispatch_block_t mutation = ^{
    if (self.task) {
      result = @{
        @"ok" : @NO,
        @"code" : @"download_active",
        @"message" :
            @"Cancel the active download before cleaning partial files."
      };
      return;
    }
    NSError *error = nil;
    NSArray *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:self.downloadsRoot
                            error:&error];
    if (error) {
      result = @{
        @"ok" : @NO,
        @"code" : @"cleanup_failed",
        @"message" : error.localizedDescription
            ?: @"Friday could not inspect partial downloads."
      };
      return;
    }
    BOOL removed = entries.count > 0;
    if (removed &&
        ![NSFileManager.defaultManager removeItemAtPath:self.downloadsRoot
                                                  error:&error]) {
      result = @{
        @"ok" : @NO,
        @"code" : @"cleanup_failed",
        @"message" : error.localizedDescription
            ?: @"Friday could not remove partial downloads."
      };
      return;
    }
    if (removed &&
        ![NSFileManager.defaultManager createDirectoryAtPath:self.downloadsRoot
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error]) {
      result = @{
        @"ok" : @NO,
        @"code" : @"cleanup_failed",
        @"message" : error.localizedDescription
            ?: @"Friday could not prepare the download folder."
      };
      return;
    }
    result = @{
      @"ok" : @YES,
      @"removed" : @(removed),
      @"message" : removed ? @"Failed and partial downloads removed."
                           : @"No failed or partial downloads were present."
    };
  };
  if (dispatch_get_specific(FridayRepositoryQueueKey))
    mutation();
  else
    dispatch_sync(self.queue, mutation);
  return result;
}

+ (NSDictionary *)runRepositoryProbes {
  NSString *root = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString
              stringWithFormat:@"FridayModelProbe-%@", NSUUID.UUID.UUIDString]];
  [NSFileManager.defaultManager createDirectoryAtPath:root
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString *partial = [root stringByAppendingPathComponent:@"download.partial"];
  NSMutableData *data = [NSMutableData dataWithLength:4096];
  [data writeToFile:partial atomically:YES];
  uint64_t resume =
      [[[NSFileManager.defaultManager attributesOfItemAtPath:partial error:nil]
          objectForKey:NSFileSize] unsignedLongLongValue];
  NSString *bad = [root stringByAppendingPathComponent:@"bad.gguf"];
  [@"NOPE" writeToFile:bad
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:nil];
  NSData *magic =
      [[NSFileHandle fileHandleForReadingAtPath:bad] readDataOfLength:4];
  BOOL malformed = memcmp(magic.bytes, "GGUF", 4) != 0;
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString *hex = [NSMutableString string];
  for (NSUInteger index = 0; index < sizeof(digest); ++index)
    [hex appendFormat:@"%02x", digest[index]];
  BOOL shaFailed = ![hex isEqual:FridaySHA];
  NSString *outside = [[root stringByAppendingPathComponent:@"../outside"]
      stringByStandardizingPath];
  BOOL unsafeDeleteRejected =
      ![outside hasPrefix:[root stringByAppendingString:@"/"]];
  NSString *dataRoot = [root stringByAppendingPathComponent:@"AppData"];
  NSString *modelsRoot = [dataRoot stringByAppendingPathComponent:@"Models"];
  [NSFileManager.defaultManager createDirectoryAtPath:modelsRoot
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString *missingPath =
      [modelsRoot stringByAppendingPathComponent:@"missing/model.gguf"];
  NSDictionary *missingRecord = @{
    @"modelKey" : @1,
    @"path" : missingPath,
    @"managed" : @YES,
    @"engine" : @"nemo_speech_cpp",
    @"family" : @"parakeet_tdt",
    @"format" : @"gguf",
    @"compatibility" : @"compatible"
  };
  NSDictionary *index = @{
    @"schemaVersion" : @1,
    @"activeModelKey" : @1,
    @"models" : @[ missingRecord ]
  };
  NSData *indexData = [NSJSONSerialization dataWithJSONObject:index
                                                      options:0
                                                        error:nil];
  [indexData
      writeToFile:[modelsRoot stringByAppendingPathComponent:@"index.json"]
          options:0
            error:nil];
  FridayNemoRecognizer *recognizer = nil;
  FridayModelRepository *repository = [[FridayModelRepository alloc]
      initWithDataDirectory:dataRoot
                 recognizer:recognizer
                   progress:^(uint64_t operation, NSString *state,
                              uint64_t downloaded, uint64_t total) {
                     (void)operation;
                     (void)state;
                     (void)downloaded;
                     (void)total;
                   }];
  NSDictionary *missingStatus = [repository status];
  BOOL missingActiveReset =
      [missingStatus[@"activeModelKey"] unsignedLongLongValue] == 0 &&
      ![missingStatus[@"activeModelReady"] boolValue];
  NSString *corruptDirectory =
      [modelsRoot stringByAppendingPathComponent:@"corrupt-final"];
  [NSFileManager.defaultManager createDirectoryAtPath:corruptDirectory
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  [data writeToFile:[corruptDirectory
                        stringByAppendingPathComponent:@"model.gguf"]
            options:0
              error:nil];
  NSDictionary *corruptManifest = @{
    @"engine" : @"nemo_speech_cpp",
    @"family" : @"parakeet_tdt",
    @"format" : @"gguf",
    @"revision" : FridayRevision,
    @"sha256" : FridaySHA,
    @"expectedBytes" : @(FridayBytes)
  };
  [[NSJSONSerialization dataWithJSONObject:corruptManifest options:0 error:nil]
      writeToFile:[corruptDirectory
                      stringByAppendingPathComponent:@"manifest.json"]
          options:0
            error:nil];
  BOOL finalCollisionCorruptionRejected =
      ![repository validateDefaultDirectory:corruptDirectory];
  NSDictionary *emptyCleanup = [repository removeFailedDownloads];
  NSString *cleanupMarker =
      [[repository downloadsRoot] stringByAppendingPathComponent:@"partial"];
  [@"partial" writeToFile:cleanupMarker
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
  NSDictionary *removedCleanup = [repository removeFailedDownloads];
  BOOL cleanupTruthful = [emptyCleanup[@"ok"] boolValue] &&
                         ![emptyCleanup[@"removed"] boolValue] &&
                         [removedCleanup[@"ok"] boolValue] &&
                         [removedCleanup[@"removed"] boolValue];
  NSDictionary *compatibleMetadata = @{
    @"modelId" : @"community/parakeet-tdt-gguf",
    @"author" : @"community",
    @"private" : @NO,
    @"gated" : @NO,
    @"sha" : FridayRevision,
    @"pipeline_tag" : @"automatic-speech-recognition",
    @"tags" : @[ @"gguf", @"parakeet", @"license:cc-by-4.0" ],
    @"cardData" : @{@"license" : @"cc-by-4.0", @"language" : @[ @"en" ]},
    @"siblings" : @[ @{
      @"rfilename" : @"parakeet-tdt-q8.gguf",
      @"lfs" : @{@"sha256" : FridaySHA, @"size" : @(FridayBytes)}
    } ]
  };
  NSString *metadataError = nil;
  NSDictionary *candidateHF =
      [repository manifestFromHuggingFaceMetadata:compatibleMetadata
                                       identifier:@"community/parakeet-tdt-gguf"
                                            error:&metadataError];
  BOOL candidateUnverified =
      [candidateHF[@"compatibility"] isEqual:@"unverified_candidate"] &&
      [candidateHF[@"family"] isEqual:@"unverified"] &&
      ![candidateHF[@"compatibility"] isEqual:@"compatible"];
  NSMutableDictionary *maliciousMetadata = [compatibleMetadata mutableCopy];
  maliciousMetadata[@"modelId"] = @"attacker/parakeet-asr";
  maliciousMetadata[@"siblings"] = @[ @{
    @"rfilename" : @"unrelated.gguf",
    @"lfs" : @{@"sha256" : FridaySHA, @"size" : @(FridayBytes)}
  } ];
  NSDictionary *maliciousCandidate =
      [repository manifestFromHuggingFaceMetadata:maliciousMetadata
                                       identifier:@"attacker/parakeet-asr"
                                            error:&metadataError];
  BOOL maliciousCandidateUnverified =
      [maliciousCandidate[@"compatibility"] isEqual:@"unverified_candidate"] &&
      [maliciousCandidate[@"family"] isEqual:@"unverified"] &&
      ![maliciousCandidate[@"family"] isEqual:@"parakeet_tdt"];
  BOOL maliciousPublicationRejected =
      maliciousCandidateUnverified &&
      ![repository validateManagedDirectory:corruptDirectory
                                    expected:maliciousCandidate];
  NSMutableDictionary *privateMetadata = [compatibleMetadata mutableCopy];
  privateMetadata[@"private"] = @YES;
  BOOL privateRejected =
      [repository manifestFromHuggingFaceMetadata:privateMetadata
                                       identifier:@"community/private-parakeet"
                                            error:&metadataError] == nil;
  NSMutableDictionary *ambiguousMetadata = [compatibleMetadata mutableCopy];
  ambiguousMetadata[@"siblings"] = @[
    compatibleMetadata[@"siblings"][0], @{
      @"rfilename" : @"parakeet-tdt-q4.gguf",
      @"lfs" : @{@"sha256" : FridaySHA, @"size" : @(FridayBytes)}
    }
  ];
  BOOL ambiguousRejected =
      [repository manifestFromHuggingFaceMetadata:ambiguousMetadata
                                       identifier:@"community/parakeet-many"
                                            error:&metadataError] == nil;
  NSMutableDictionary *noHashMetadata = [compatibleMetadata mutableCopy];
  noHashMetadata[@"siblings"] = @[
    @{@"rfilename" : @"parakeet-tdt.gguf", @"lfs" : @{@"size" : @(FridayBytes)}}
  ];
  BOOL noHashRejected =
      [repository manifestFromHuggingFaceMetadata:noHashMetadata
                                       identifier:@"community/parakeet-nohash"
                                            error:&metadataError] == nil;
  NSMutableDictionary *incompatibleMetadata = [compatibleMetadata mutableCopy];
  incompatibleMetadata[@"pipeline_tag"] = @"text-classification";
  incompatibleMetadata[@"tags"] = @[ @"gguf", @"license:cc-by-4.0" ];
  BOOL incompatibleRejected =
      [repository manifestFromHuggingFaceMetadata:incompatibleMetadata
                                       identifier:@"community/speech-model"
                                            error:&metadataError] == nil;
  BOOL identifierValidation =
      [repository isSafeHuggingFaceIdentifier:@"community/parakeet-tdt-gguf"] &&
      ![repository isSafeHuggingFaceIdentifier:@"https://example.com/model"] &&
      ![repository isSafeHuggingFaceIdentifier:@"../escape"];
  NSString *pendingRoot =
      [[repository downloadsRoot] stringByAppendingPathComponent:@"model-1"];
  [NSFileManager.defaultManager createDirectoryAtPath:pendingRoot
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString *pendingPartial =
      [pendingRoot stringByAppendingPathComponent:@"download.partial"];
  [data writeToFile:pendingPartial atomically:YES];
  NSMutableDictionary *pendingManifest =
      [[repository defaultManifest:0] mutableCopy];
  NSDictionary *pendingResume = @{
    @"schemaVersion" : @1,
    @"url" : pendingManifest[@"downloadURL"],
    @"revision" : pendingManifest[@"revision"],
    @"artifact" : pendingManifest[@"artifact"],
    @"sha256" : pendingManifest[@"sha256"],
    @"repository" : pendingManifest[@"repository"],
    @"displayName" : pendingManifest[@"displayName"],
    @"expectedBytes" : pendingManifest[@"expectedBytes"],
    @"partialBytes" : @(data.length),
    @"manifest" : pendingManifest
  };
  NSData *pendingResumeData =
      [NSJSONSerialization dataWithJSONObject:pendingResume
                                      options:0
                                        error:nil];
  [pendingResumeData
      writeToFile:[pendingRoot stringByAppendingPathComponent:@"resume.json"]
          options:0
            error:nil];
  NSDictionary *pendingStatus = [repository status];
  BOOL pendingResumeHydrated =
      [pendingStatus[@"pendingResumeAvailable"] boolValue] &&
      [pendingStatus[@"pendingDownloadedBytes"] unsignedLongLongValue] ==
          data.length &&
      [pendingStatus[@"pendingTotalBytes"] unsignedLongLongValue] ==
          FridayBytes;
  uint8_t ggufHeader[24] = {'G', 'G', 'U', 'F', 3, 0, 0, 0,
                            1,   0,   0,   0,   0, 0, 0, 0,
                            1,   0,   0,   0,   0, 0, 0, 0};
  NSString *genericGGUF = [root stringByAppendingPathComponent:@"generic.gguf"];
  [[NSData dataWithBytes:ggufHeader length:sizeof(ggufHeader)]
      writeToFile:genericGGUF
          options:0
            error:nil];
  BOOL unknownFamilyFallback =
      [[repository boundedGGUFFamilyHint:genericGGUF]
          isEqual:@"runtime_verified_asr"] &&
      [repository boundedGGUFFamilyHint:bad] == nil;
  [NSFileManager.defaultManager removeItemAtPath:root error:nil];
  return @{
    @"ok" : @(resume == 4096 && malformed && shaFailed && missingActiveReset &&
              finalCollisionCorruptionRejected && cleanupTruthful &&
              candidateUnverified && maliciousCandidateUnverified &&
              maliciousPublicationRejected && privateRejected &&
              ambiguousRejected && noHashRejected && incompatibleRejected &&
              identifierValidation && pendingResumeHydrated &&
              unknownFamilyFallback),
    @"resumeOffset" : @(resume),
    @"malformedRejected" : @(malformed),
    @"shaFailed" : @(shaFailed),
    @"sidecarRequired" : @YES,
    @"managedDeleteBounded" : @(unsafeDeleteRejected),
    @"missingActiveReset" : @(missingActiveReset),
    @"finalCollisionCorruptionRejected" : @(finalCollisionCorruptionRejected),
    @"cleanupTruthful" : @(cleanupTruthful),
    @"hfCandidateFixture" : @(candidateHF != nil),
    @"hfCandidateUnverified" : @(candidateUnverified),
    @"hfMaliciousCandidateUnverified" : @(maliciousCandidateUnverified),
    @"hfMaliciousPublicationRejected" : @(maliciousPublicationRejected),
    @"hfRuntimeProbeRequired" : @YES,
    @"hfUnknownFamilyFallback" : @(unknownFamilyFallback),
    @"hfPrivateRejected" : @(privateRejected),
    @"hfAmbiguousRejected" : @(ambiguousRejected),
    @"hfNoHashRejected" : @(noHashRejected),
    @"hfIncompatibleRejected" : @(incompatibleRejected),
    @"hfIdentifierValidation" : @(identifierValidation),
    @"pendingResumeHydrated" : @(pendingResumeHydrated)
  };
}
@end
