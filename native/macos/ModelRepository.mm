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
                              (void)result;
                            }];
    }
  }
  return self;
}

- (void)dealloc {
  [self.task cancel];
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
      if ([recordCopy[@"engine"] isEqual:@"nemo_speech_cpp"] &&
          [recordCopy[@"family"] isEqual:@"parakeet_tdt"] &&
          [recordCopy[@"format"] isEqual:@"gguf"]) {
        recordCopy[@"compatibility"] = @"compatible";
        if (!recordCopy[@"languages"])
          recordCopy[@"languages"] = @[];
      }
      [self.models addObject:recordCopy];
    }
  }
  self.activeModelKey = [index[@"activeModelKey"] unsignedLongLongValue];
  NSMutableDictionary *active = [self modelForKey:self.activeModelKey];
  if ([NSFileManager.defaultManager fileExistsAtPath:active[@"path"]])
    self.activeModelPath = active[@"path"];
}

- (void)saveIndexDurably {
  NSDictionary *index = @{
    @"schemaVersion" : @1,
    @"activeModelKey" : @(self.activeModelKey),
    @"models" : self.models
  };
  NSData *data =
      [NSJSONSerialization dataWithJSONObject:index
                                      options:NSJSONWritingPrettyPrinted
                                        error:nil];
  NSString *temporary = [self.indexPath
      stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
  if (![data writeToFile:temporary options:0 error:nil])
    return;
  int descriptor = open(temporary.fileSystemRepresentation, O_RDONLY);
  if (descriptor >= 0) {
    fsync(descriptor);
    close(descriptor);
  }
  if (rename(temporary.fileSystemRepresentation,
             self.indexPath.fileSystemRepresentation) != 0) {
    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    return;
  }
  [self fsyncDirectory:self.modelsRoot];
}

- (void)fsyncDirectory:(NSString *)path {
  int descriptor = open(path.fileSystemRepresentation, O_RDONLY);
  if (descriptor >= 0) {
    fsync(descriptor);
    close(descriptor);
  }
}

- (NSMutableDictionary *)modelForKey:(uint64_t)key {
  for (NSMutableDictionary *model in self.models) {
    if ([model[@"modelKey"] unsignedLongLongValue] == key)
      return model;
  }
  return nil;
}

- (NSDictionary *)publicModel:(NSDictionary *)model {
  return @{
    @"modelKey" : model[@"modelKey"] ?: @0,
    @"displayName" : model[@"displayName"] ?: @"Model",
    @"source" : model[@"source"] ?: @"local",
    @"managed" : model[@"managed"] ?: @NO,
    @"installedBytes" : model[@"installedBytes"] ?: @0,
    @"license" : model[@"license"] ?: @"Unknown",
    @"languages" : model[@"languages"] ?: @[],
    @"compatibility" : model[@"compatibility"] ?: @"unknown",
    @"active" :
        @([model[@"modelKey"] unsignedLongLongValue] == self.activeModelKey)
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
    status = @{
      @"ok" : @YES,
      @"activeModelKey" : @(self.activeModelKey),
      @"models" : models,
      @"managedBytes" : @(usage),
      @"downloadActive" : @(self.task != nil),
      @"downloadedBytes" : @(self.downloaded),
      @"totalBytes" : @(self.total)
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
      [resume[@"url"] isEqual:FridayURL] &&
      [resume[@"revision"] isEqual:FridayRevision] &&
      [resume[@"artifact"] isEqual:FridayArtifact] &&
      [resume[@"expectedBytes"] unsignedLongLongValue] == FridayBytes &&
      [resume[@"partialBytes"] unsignedLongLongValue] == partialBytes &&
      partialBytes <= FridayBytes;
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
  self.resume[@"url"] = FridayURL;
  self.resume[@"revision"] = FridayRevision;
  self.resume[@"artifact"] = FridayArtifact;
  self.resume[@"expectedBytes"] = @(FridayBytes);
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

- (void)downloadDefaultOperation:(uint64_t)operationID
                      completion:(void (^)(NSDictionary *))completion {
  [self onQueue:^{
    NSMutableDictionary *installed = [self modelForKey:FridayDefaultKey];
    if (installed &&
        [NSFileManager.defaultManager fileExistsAtPath:installed[@"path"]]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @YES,
          @"modelKey" : @(FridayDefaultKey),
          @"message" : @"The verified default model is already installed."
        });
      });
      return;
    }
    if (self.task || self.completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"code" : @"download_active",
          @"message" : @"A model operation is already active."
        });
      });
      return;
    }
    self.operation = operationID;
    self.completion = completion;
    self.cancelled = NO;
    self.responseValid = NO;
    NSString *operationRoot =
        [self.downloadsRoot stringByAppendingPathComponent:@"default-v1"];
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
    self.total = FridayBytes;
    self.handle = [NSFileHandle fileHandleForWritingToURL:self.partialURL
                                                    error:nil];
    [self.handle seekToEndOfFile];
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:FridayURL]];
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

- (void)cancelOperation:(uint64_t)operationID {
  [self onQueue:^{
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
      [(NSString *)parts[1] longLongValue] != (long long)FridayBytes)
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

- (void)verifyAndInstall {
  uint64_t size = [[[NSFileManager.defaultManager
      attributesOfItemAtPath:self.partialURL.path
                       error:nil] objectForKey:NSFileSize]
      unsignedLongLongValue];
  NSString *digest = [self sha256:self.partialURL.path];
  if (size != FridayBytes || ![digest isEqual:FridaySHA]) {
    [self fail:@"The model failed exact size/SHA-256 verification."
          code:@"integrity_failed"];
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
  NSDictionary *manifest = [self defaultManifest:size];
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
                   NSString *idRoot = [self.modelsRoot
                       stringByAppendingPathComponent:FridayModelID];
                   NSString *finalDirectory =
                       [idRoot stringByAppendingPathComponent:FridayRevision];
                   [NSFileManager.defaultManager createDirectoryAtPath:idRoot
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil];
                   if ([NSFileManager.defaultManager
                           fileExistsAtPath:finalDirectory]) {
                     [NSFileManager.defaultManager removeItemAtPath:staging
                                                              error:nil];
                   } else if (rename(staging.fileSystemRepresentation,
                                     finalDirectory.fileSystemRepresentation) !=
                              0) {
                     [NSFileManager.defaultManager removeItemAtPath:staging
                                                              error:nil];
                     [self fail:@"Atomic model publication failed."
                           code:@"install_failed"];
                     return;
                   }
                   [self fsyncDirectory:idRoot];
                   [self fsyncDirectory:self.modelsRoot];
                   NSString *finalModel = [finalDirectory
                       stringByAppendingPathComponent:@"model.gguf"];
                   NSMutableDictionary *record = [manifest mutableCopy];
                   record[@"path"] = finalModel;
                   NSMutableDictionary *old =
                       [self modelForKey:FridayDefaultKey];
                   if (old)
                     [self.models removeObject:old];
                   [self.models addObject:record];
                   self.activeModelKey = FridayDefaultKey;
                   self.activeModelPath = finalModel;
                   [self saveIndexDurably];
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
                     @"modelKey" : @(FridayDefaultKey),
                     @"message" :
                         @"Parakeet TDT v3 is verified, warm, and active.",
                     @"probe" : probe
                   }];
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
                     [self saveIndexDurably];
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

- (void)addHuggingFaceID:(NSString *)identifier
               operation:(uint64_t)operation
              completion:(void (^)(NSDictionary *))completion {
  NSString *normalized = [identifier
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (![normalized isEqual:FridayModelID]) {
    completion(@{
      @"ok" : @NO,
      @"code" : @"unsupported_repository",
      @"message" : @"The repository is not an immutable verified Parakeet TDT "
                   @"GGUF source."
    });
    return;
  }
  [self downloadDefaultOperation:operation completion:completion];
}

- (void)selectKey:(uint64_t)key
       generation:(uint64_t)generation
       completion:(void (^)(NSDictionary *))completion {
  [self onQueue:^{
    NSMutableDictionary *model = [self modelForKey:key];
    NSString *path = model[@"path"];
    if (!model || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
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
                                  [self saveIndexDurably];
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

- (void)removeFailedDownloads {
  [self onQueue:^{
    if (self.task)
      return;
    [NSFileManager.defaultManager removeItemAtPath:self.downloadsRoot
                                             error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:self.downloadsRoot
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  }];
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
  [NSFileManager.defaultManager removeItemAtPath:root error:nil];
  return @{
    @"ok" : @(resume == 4096 && malformed && shaFailed),
    @"resumeOffset" : @(resume),
    @"malformedRejected" : @(malformed),
    @"shaFailed" : @(shaFailed),
    @"sidecarRequired" : @YES,
    @"managedDeleteBounded" : @(unsafeDeleteRejected)
  };
}
@end
