#import "AudioSession.h"
#import "GlobalInputMonitor.h"
#import "ModelRepository.h"
#import "NemoRecognizer.h"
#import "OverlayWindow.h"
#import "TextDelivery.h"
#import "friday_host.h"
#import <AVFAudio/AVAudioApplication.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

@interface FridayHostController : NSObject
@property(nonatomic) friday_host_event_callback eventCallback;
@property(nonatomic) void *eventContext;
@property(nonatomic, strong) FridayGlobalInputMonitor *input;
@property(nonatomic, strong) FridayTextDelivery *delivery;
@property(nonatomic, strong) FridayOverlayWindow *overlay;
@property(nonatomic, strong) FridayAudioSession *audio;
@property(nonatomic, strong) FridayNemoRecognizer *recognizer;
@property(nonatomic, strong) FridayModelRepository *models;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, FridaySourceTarget *> *sources;
@property(nonatomic, strong) NSMutableArray<NSString *> *sourceOrder;
@property(nonatomic) uint64_t generation;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSNumber *> *asyncGenerations;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSNumber *> *asyncSessions;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSNumber *> *audioGenerations;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, id> *asyncCompletions;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSString *> *transcripts;
@property(nonatomic) uint64_t currentAudioSession;
@property(nonatomic) uint64_t currentAudioGeneration;
@property(nonatomic, strong) NSTimer *permissionTimer;
@property(nonatomic) NSUInteger permissionPolls;
- (instancetype)initWithDataDirectory:(NSString *)directory
                             callback:(friday_host_event_callback)callback
                              context:(void *)context;
- (NSDictionary<NSString *, id> *)request:(NSString *)name
                                  payload:(NSString *)payload;
- (void)requestAsync:(NSString *)name
             payload:(NSString *)payload
                 key:(uint64_t)key
          completion:(void (^)(NSDictionary *result))completion;
- (void)cancelKey:(uint64_t)key;
- (NSString *)transcriptKeyForSession:(uint64_t)session
                           generation:(uint64_t)generation;
- (void)shutdown;
@end

@implementation FridayHostController
- (instancetype)initWithDataDirectory:(NSString *)directory
                             callback:(friday_host_event_callback)callback
                              context:(void *)context {
  if ((self = [super init])) {
    _eventCallback = callback;
    _eventContext = context;
    _sources = [NSMutableDictionary dictionary];
    _sourceOrder = [NSMutableArray array];
    _asyncGenerations = [NSMutableDictionary dictionary];
    _asyncSessions = [NSMutableDictionary dictionary];
    _transcripts = [NSMutableDictionary dictionary];
    _audioGenerations = [NSMutableDictionary dictionary];
    _asyncCompletions = [NSMutableDictionary dictionary];
    _delivery = [FridayTextDelivery new];
    _recognizer = [FridayNemoRecognizer new];
    __weak FridayHostController *weak = self;
    _audio = [[FridayAudioSession alloc]
        initWithEventHandler:^(NSString *event, NSDictionary *payload) {
          FridayHostController *strong = weak;
          if (!strong)
            return;
          uint64_t session = [payload[@"sessionId"] unsignedLongLongValue];
          uint64_t generation =
              [strong.audioGenerations[@(session)] unsignedLongLongValue];
          [strong
              emit:[NSString
                       stringWithFormat:@"%@|%llu|%llu|%@", event, generation,
                                        session,
                                        [strong b64:[strong json:payload]]]];
        }];
    _models = [[FridayModelRepository alloc]
        initWithDataDirectory:directory
                   recognizer:_recognizer
                     progress:^(uint64_t operation, NSString *state,
                                uint64_t downloaded, uint64_t total) {
                       [weak emit:[NSString
                                      stringWithFormat:
                                          @"model_progress|%llu|%@|%llu|%llu",
                                          operation, state, downloaded, total]];
                     }];
    _input = [[FridayGlobalInputMonitor alloc] initWithHandler:^(
                                                   NSString *event,
                                                   NSDictionary *payload) {
      FridayHostController *strong = weak;
      if (!strong)
        return;
      if ([event isEqual:@"hotkey_down"]) {
        strong.generation += 1;
        FridaySourceTarget *source = [strong.delivery captureFrontmostSource];
        source.token = payload[@"token"];
        source.generation = strong.generation;
        strong.sources[source.token] = source;
        [strong.overlay setPreferredScreenFrame:source.sourceScreenFrame];
        [strong.sourceOrder addObject:source.token];
        while (strong.sourceOrder.count > 8) {
          NSString *expired = strong.sourceOrder.firstObject;
          [strong.sourceOrder removeObjectAtIndex:0];
          [strong.sources removeObjectForKey:expired];
        }
        [strong emit:[NSString
                         stringWithFormat:@"hotkey_down|%llu|%.0f|%@|%d|%@|%@",
                                          strong.generation,
                                          [payload[@"atMs"] doubleValue],
                                          [strong b64:source.token], source.pid,
                                          [strong b64:source.bundleID],
                                          [strong b64:source.appName]]];
      } else if ([event isEqual:@"hotkey_up"]) {
        [strong
            emit:[NSString stringWithFormat:@"hotkey_up|%llu|%.0f",
                                            strong.generation,
                                            [payload[@"atMs"] doubleValue]]];
      } else {
        [strong emit:[NSString stringWithFormat:@"hotkey_cancel|%llu|%.0f|%@",
                                                strong.generation,
                                                [payload[@"atMs"] doubleValue],
                                                payload[@"reason"]
                                                    ?: @"invalidated"]];
      }
    }];
    _overlay =
        [[FridayOverlayWindow alloc] initWithHandler:^(NSString *action) {
          [weak emit:[NSString
                         stringWithFormat:@"%@|%llu", action, weak.generation]];
        }];
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self
           selector:@selector(applicationActivated:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(applicationWillTerminate:)
               name:NSApplicationWillTerminateNotification
             object:nil];
  }
  return self;
}
- (void)dealloc {
  [self.input stop];
  [self.audio cancelActiveSession];
  [self.overlay hide];
  [self.recognizer shutdownAndWait];
  [self.permissionTimer invalidate];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (NSString *)json:(id)object {
  NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                 options:0
                                                   error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
             ?: @"{}";
}
- (NSString *)b64:(NSString *)text {
  return [[text dataUsingEncoding:NSUTF8StringEncoding]
      base64EncodedStringWithOptions:0];
}
- (NSString *)fromB64:(NSString *)text {
  NSData *data = [[NSData alloc] initWithBase64EncodedString:text options:0];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
             ?: @"";
}
- (void)emit:(NSString *)event {
  NSData *data = [event dataUsingEncoding:NSUTF8StringEncoding];
  if (self.eventCallback && data.length)
    self.eventCallback(self.eventContext, (const uint8_t *)data.bytes,
                       data.length);
}
- (NSDictionary *)permissions {
  AVAudioApplicationRecordPermission microphone =
      AVAudioApplication.sharedInstance.recordPermission;
  return @{
    @"ok" : @YES,
    @"microphone" : @(microphone == AVAudioApplicationRecordPermissionGranted),
    @"accessibility" : @(AXIsProcessTrusted()),
    @"inputMonitoring" : @(self.input.inputMonitoringUsable)
  };
}
- (void)applicationWillTerminate:(NSNotification *)note {
  (void)note;
  [self.audio cancelActiveSession];
  [self.recognizer shutdownAndWait];
}
- (void)applicationActivated:(NSNotification *)note {
  (void)note;
  [self emit:[NSString
                 stringWithFormat:@"permissions|%llu|%@", self.generation,
                                  [self b64:[self json:[self permissions]]]]];
}
- (void)pollPermissions {
  self.permissionPolls += 1;
  NSDictionary *permissions = [self permissions];
  [self emit:[NSString stringWithFormat:@"permissions|%llu|%@", self.generation,
                                        [self b64:[self json:permissions]]]];
  if (([permissions[@"accessibility"] boolValue] &&
       [permissions[@"inputMonitoring"] boolValue]) ||
      self.permissionPolls >= 20) {
    [self.permissionTimer invalidate];
    self.permissionTimer = nil;
  }
}
- (void)beginPermissionPolling {
  [self.permissionTimer invalidate];
  self.permissionPolls = 0;
  self.permissionTimer =
      [NSTimer scheduledTimerWithTimeInterval:.25
                                       target:self
                                     selector:@selector(pollPermissions)
                                     userInfo:nil
                                      repeats:YES];
}
- (NSDictionary *)fields:(NSString *)payload {
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  for (NSString *part in [payload componentsSeparatedByString:@";"]) {
    NSRange split = [part rangeOfString:@"="];
    if (split.location != NSNotFound)
      fields[[part substringToIndex:split.location]] =
          [part substringFromIndex:split.location + 1];
  }
  return fields;
}
- (NSString *)transcriptKeyForSession:(uint64_t)session
                           generation:(uint64_t)generation {
  return [NSString stringWithFormat:@"%llu:%llu", generation, session];
}
- (NSDictionary *)request:(NSString *)name payload:(NSString *)payload {
  if ([name isEqual:@"friday.spike"])
    return @{
      @"ok" : @YES,
      @"bridge" : @"ok",
      @"platform" : @"macos",
      @"bundleIdentifier" : NSBundle.mainBundle.bundleIdentifier
          ?: @"unbundled",
      @"permissions" : [self permissions]
    };
  if ([name isEqual:@"friday.permissions"])
    return [self permissions];
  if ([name isEqual:@"friday.permissions.request"]) {
    if ([payload isEqual:@"input"])
      [self.input requestPermission];
    if ([payload isEqual:@"accessibility"])
      AXIsProcessTrustedWithOptions(
          (__bridge CFDictionaryRef)
              @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES});
    if ([payload isEqual:@"microphone"])
      [AVAudioApplication
          requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
            (void)granted;
            dispatch_async(dispatch_get_main_queue(), ^{
              [self pollPermissions];
            });
          }];
    [self beginPermissionPolling];
    return [self permissions];
  }
  if ([name isEqual:@"friday.hotkey.configure"]) {
    NSError *error = nil;
    BOOL configured = [self.input configureFromString:payload error:&error],
         started = configured && [self.input start:&error];
    return @{
      @"ok" : @(started),
      @"configured" : @(configured),
      @"running" : @(self.input.running),
      @"message" : error.localizedDescription ?: @"Global shortcut active."
    };
  }
  if ([name isEqual:@"friday.hotkey.probe"])
    return [self.input runSyntheticProbe];
  if ([name isEqual:@"friday.source.capture"]) {
    self.generation += 1;
    FridaySourceTarget *source = [self.delivery captureFrontmostSource];
    source.generation = self.generation;
    self.sources[source.token] = source;
    [self.sourceOrder addObject:source.token];
    return @{
      @"ok" : @YES,
      @"generation" : @(self.generation),
      @"token" : [self b64:source.token],
      @"pid" : @(source.pid),
      @"bundleId" : [self b64:source.bundleID]
    };
  }
  if ([name isEqual:@"friday.source.discard"]) {
    NSString *token = [self fromB64:payload];
    if (token.length) {
      FridaySourceTarget *source = self.sources[token];
      if (source) {
        [self.sources removeObjectForKey:source.token];
        [self.sourceOrder removeObject:source.token];
      }
    } else {
      for (FridaySourceTarget *source in self.sources.allValues.copy) {
        if (source.generation == self.generation) {
          [self.sources removeObjectForKey:source.token];
          [self.sourceOrder removeObject:source.token];
        }
      }
    }
    return @{@"ok" : @YES};
  }
  if ([name isEqual:@"friday.deliver"]) {
    NSArray *parts = [payload componentsSeparatedByString:@"|"];
    if (parts.count != 2)
      return @{@"ok" : @NO, @"message" : @"Invalid delivery request."};
    NSString *token = [self fromB64:parts[0]];
    FridaySourceTarget *source = self.sources[token];
    [self.sources removeObjectForKey:token];
    [self.sourceOrder removeObject:token];
    if (!source || source.generation != self.generation)
      return @{
        @"ok" : @NO,
        @"message" : @"The source token expired, was consumed, or belongs to a "
                     @"stale generation."
      };
    NSDictionary *delivery = [self.delivery deliverText:[self fromB64:parts[1]]
                                               toSource:source
                                     pasteAutomatically:YES];
    [self.audio discardRetryAudio];
    return delivery;
  }
  if ([name isEqual:@"friday.deliver_session"]) {
    NSDictionary *fields = [self fields:payload];
    uint64_t session = (uint64_t)[fields[@"session"] longLongValue];
    uint64_t generation = (uint64_t)[fields[@"generation"] longLongValue];
    BOOL pasteAutomatically = [fields[@"paste"] boolValue];
    NSString *token = nil;
    for (FridaySourceTarget *candidate in self.sources.allValues) {
      if (candidate.generation == generation) {
        token = candidate.token;
        break;
      }
    }
    NSString *transcriptKey = [self transcriptKeyForSession:session
                                                 generation:generation];
    NSString *text = self.transcripts[transcriptKey];
    [self.transcripts removeObjectForKey:transcriptKey];
    FridaySourceTarget *source = token ? self.sources[token] : nil;
    if (token) {
      [self.sources removeObjectForKey:token];
      [self.sourceOrder removeObject:token];
    }
    if (!source || source.generation != generation || !text.length) {
      [self.audio discardRetryAudio];
      return @{
        @"ok" : @NO,
        @"sessionId" : @(session),
        @"generation" : @(generation),
        @"message" : @"The final transcript or exact source is stale."
      };
    }
    NSMutableDictionary *delivery =
        [[self.delivery deliverText:text
                           toSource:source
                 pasteAutomatically:pasteAutomatically] mutableCopy];
    delivery[@"sessionId"] = @(session);
    delivery[@"generation"] = @(generation);
    [self.audio discardRetryAudio];
    return delivery;
  }
  if ([name isEqual:@"friday.delivery.probe"])
    return [self.delivery
        runProbeForApplication:payload.length ? payload : @"TextEdit"];
  if ([name isEqual:@"friday.overlay.show"]) {
    [self.overlay showLocked:[payload isEqual:@"locked"] elapsedMilliseconds:0];
    return @{@"ok" : @YES};
  }
  if ([name isEqual:@"friday.overlay.transcribing"]) {
    [self.overlay showTranscribing];
    return @{@"ok" : @YES};
  }
  if ([name isEqual:@"friday.overlay.hide"]) {
    [self.overlay hide];
    return @{@"ok" : @YES};
  }
  if ([name isEqual:@"friday.overlay.probe"])
    return [self.overlay runInteractionProbe];
  if ([name isEqual:@"friday.audio.discard"]) {
    [self.audio discardRetryAudio];
    return @{@"ok" : @YES};
  }
  if ([name isEqual:@"friday.audio.storage_probe"])
    return [FridayAudioSession runStorageProbe];
  if ([name isEqual:@"friday.model.status"])
    return [self.models status];
  if ([name isEqual:@"friday.model.probes"])
    return [FridayModelRepository runRepositoryProbes];
  if ([name isEqual:@"friday.model.cancel"]) {
    [self.models cancelOperation:payload.longLongValue];
    return @{@"ok" : @YES};
  }
  if ([name isEqual:@"friday.model.cleanup"]) {
    [self.models removeFailedDownloads];
    return @{@"ok" : @YES};
  }
  if ([name isEqual:@"friday.diagnostics"])
    return @{
      @"ok" : @YES,
      @"generation" : @(self.generation),
      @"permissions" : [self permissions],
      @"hotkeyRunning" : @(self.input.running),
      @"sourceCount" : @(self.sources.count),
      @"audioActive" : @(self.audio.active),
      @"model" : [self.models status],
      @"transcriptIncluded" : @NO,
      @"audioIncluded" : @NO
    };
  return @{@"ok" : @NO, @"message" : @"Unknown FridayHost command."};
}
- (void)requestAsync:(NSString *)name
             payload:(NSString *)payload
                 key:(uint64_t)key
          completion:(void (^)(NSDictionary *))completion {
  NSDictionary *fields = [self fields:payload];
  uint64_t generation =
      [fields[@"generation"] longLongValue] ?: self.generation;
  self.asyncGenerations[@(key)] = @(generation);
  __weak FridayHostController *weakSelf = self;
  void (^finish)(NSDictionary *) = ^(NSDictionary *result) {
    FridayHostController *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.asyncCompletions[@(key)])
      return;
    [strongSelf.asyncCompletions removeObjectForKey:@(key)];
    [strongSelf.asyncGenerations removeObjectForKey:@(key)];
    [strongSelf.asyncSessions removeObjectForKey:@(key)];
    completion(result);
  };
  self.asyncCompletions[@(key)] = [finish copy];
  if ([name isEqual:@"friday.audio.start"]) {
    uint64_t session = [fields[@"session"] longLongValue];
    if (session == 0)
      session = generation;
    self.currentAudioSession = session;
    self.currentAudioGeneration = generation;
    self.asyncSessions[@(key)] = @(session);
    self.audioGenerations[@(session)] = @(generation);
    NSError *error = nil;
    NSDictionary *result = [self.audio startSession:session error:&error];
    finish(result ?: @{
      @"ok" : @NO,
      @"generation" : @(generation),
      @"message" : error.localizedDescription ?: @"Capture failed."
    });
    return;
  }
  if ([name isEqual:@"friday.audio.finish"]) {
    uint64_t session = [fields[@"session"] longLongValue];
    if (session == 0)
      session = self.currentAudioSession;
    if (![fields[@"generation"] longLongValue])
      generation = self.currentAudioGeneration;
    self.asyncSessions[@(key)] = @(session);
    [self.audio
        stopSession:session
         completion:^(NSDictionary *capture) {
           if (![capture[@"ok"] boolValue]) {
             finish(capture);
             return;
           }
           if (!self.models.activeModelPath) {
             [self.audioGenerations removeObjectForKey:@(session)];
             finish(@{
               @"ok" : @NO,
               @"generation" : @(generation),
               @"sessionId" : @(session),
               @"code" : @"model_unavailable",
               @"capture" : capture,
               @"retryAudioAvailable" : @YES
             });
             return;
           }
           [self.recognizer
               transcribeAudioAtURL:[NSURL
                                        fileURLWithPath:capture[@"audioPath"]]
                          sessionID:session
                         generation:generation
                         completion:^(NSDictionary *result) {
                           if ([result[@"ok"] boolValue]) {
                             if (![result[@"silence"] boolValue] &&
                                 [result[@"text"] length] > 0) {
                               NSString *transcriptKey =
                                   [self transcriptKeyForSession:session
                                                      generation:generation];
                               self.transcripts[transcriptKey] =
                                   result[@"text"];
                             }
                             [self.audio discardRetryAudio];
                           }
                           NSMutableDictionary *merged = [result mutableCopy];
                           merged[@"capture"] = capture;
                           [self.audioGenerations
                               removeObjectForKey:@(session)];
                           finish(merged);
                         }];
         }];
    return;
  }
  if ([name isEqual:@"friday.audio.retry"]) {
    uint64_t session = (uint64_t)[fields[@"session"] longLongValue];
    if (session == 0)
      session = self.currentAudioSession;
    if (![fields[@"generation"] longLongValue])
      generation = self.currentAudioGeneration;
    NSURL *retryURL = self.audio.retryAudioURL;
    if (!retryURL) {
      finish(@{
        @"ok" : @NO,
        @"sessionId" : @(session),
        @"generation" : @(generation),
        @"code" : @"retry_unavailable"
      });
      return;
    }
    [self.recognizer transcribeAudioAtURL:retryURL
                                sessionID:session
                               generation:generation
                               completion:^(NSDictionary *result) {
                                 if ([result[@"ok"] boolValue]) {
                                   if (![result[@"silence"] boolValue] &&
                                       [result[@"text"] length] > 0) {
                                     NSString *transcriptKey = [self
                                         transcriptKeyForSession:session
                                                      generation:generation];
                                     self.transcripts[transcriptKey] =
                                         result[@"text"];
                                   }
                                   [self.audio discardRetryAudio];
                                 }
                                 finish(result);
                               }];
    return;
  }
  if ([name isEqual:@"friday.debug.fixture_delivery"]) {
    NSString *modelPath = self.models.activeModelPath;
    if (!modelPath.length || !payload.length) {
      finish(@{
        @"ok" : @NO,
        @"code" : @"fixture_prerequisite_missing",
        @"message" : @"The automation fixture and an active model are required."
      });
      return;
    }
    self.generation += 1;
    generation = self.generation;
    uint64_t session = generation;
    self.asyncGenerations[@(key)] = @(generation);
    self.asyncSessions[@(key)] = @(session);
    FridaySourceTarget *source = [self.delivery captureFrontmostSource];
    source.generation = generation;
    self.sources[source.token] = source;
    [self.sourceOrder addObject:source.token];
    [self.recognizer
        activateModelAtPath:modelPath
                 generation:generation
                 completion:^(NSDictionary *activation) {
                   if (![activation[@"ok"] boolValue]) {
                     [self.sources removeObjectForKey:source.token];
                     [self.sourceOrder removeObject:source.token];
                     finish(activation);
                     return;
                   }
                   [self.recognizer
                       transcribeAudioAtURL:[NSURL fileURLWithPath:payload]
                                  sessionID:session
                                 generation:generation
                                 completion:^(NSDictionary *transcription) {
                                   NSString *text = transcription[@"text"];
                                   if (![transcription[@"ok"] boolValue] ||
                                       [transcription[@"silence"] boolValue] ||
                                       !text.length) {
                                     [self.sources
                                         removeObjectForKey:source.token];
                                     [self.sourceOrder
                                         removeObject:source.token];
                                     finish(transcription);
                                     return;
                                   }
                                   NSString *transcriptKey = [self
                                       transcriptKeyForSession:session
                                                    generation:generation];
                                   self.transcripts[transcriptKey] = text;
                                   NSString *deliveryPayload =
                                       [NSString stringWithFormat:
                                                     @"session=%llu;generation="
                                                     @"%llu;paste=0",
                                                     session, generation];
                                   NSMutableDictionary *delivery = [[self
                                       request:@"friday.deliver_session"
                                       payload:deliveryPayload] mutableCopy];
                                   delivery[@"fixture"] = payload;
                                   delivery[@"recognizedText"] = text;
                                   finish(delivery);
                                 }];
                 }];
    return;
  }
  if ([name isEqual:@"friday.nemo.unload"]) {
    [self.recognizer unloadWithCompletion:finish];
    return;
  }
  if ([name isEqual:@"friday.nemo.transcribe_path"]) {
    uint64_t session = [fields[@"session"] longLongValue];
    NSString *path = [self fromB64:fields[@"path"] ?: @""];
    [self.recognizer transcribeAudioAtURL:[NSURL fileURLWithPath:path]
                                sessionID:session
                               generation:generation
                               completion:finish];
    return;
  }
  if ([name isEqual:@"friday.model.download"]) {
    [self.models downloadDefaultOperation:key completion:finish];
    return;
  }
  if ([name isEqual:@"friday.model.add_local"]) {
    [self.models addLocalPath:[self fromB64:fields[@"path"] ?: @""]
                          key:[fields[@"modelKey"] longLongValue]
                   generation:generation
                   completion:finish];
    return;
  }
  if ([name isEqual:@"friday.model.add_hf"]) {
    [self.models addHuggingFaceID:[self fromB64:fields[@"id"] ?: @""]
                        operation:key
                       completion:finish];
    return;
  }
  if ([name isEqual:@"friday.model.select"]) {
    [self.models selectKey:[fields[@"modelKey"] longLongValue]
                generation:generation
                completion:finish];
    return;
  }
  finish(@{@"ok" : @NO, @"code" : @"unknown_async_command"});
}
- (void)cancelKey:(uint64_t)key {
  void (^finish)(NSDictionary *) = self.asyncCompletions[@(key)];
  if (!finish)
    return;
  uint64_t generation = [self.asyncGenerations[@(key)] unsignedLongLongValue];
  uint64_t session = [self.asyncSessions[@(key)] unsignedLongLongValue];
  [self.recognizer cancelGeneration:generation];
  [self.models cancelOperation:key];
  [self.audio cancelSession:session];
  for (FridaySourceTarget *source in self.sources.allValues.copy) {
    if (source.generation == generation) {
      [self.sources removeObjectForKey:source.token];
      [self.sourceOrder removeObject:source.token];
    }
  }
  if (session)
    [self.transcripts
        removeObjectForKey:[self transcriptKeyForSession:session
                                              generation:generation]];
  [self.audioGenerations removeObjectForKey:@(session)];
  finish(@{
    @"ok" : @NO,
    @"cancelled" : @YES,
    @"generation" : @(generation),
    @"code" : @"cancelled"
  });
}
- (void)shutdown {
  NSArray<NSNumber *> *keys = self.asyncCompletions.allKeys.copy;
  for (NSNumber *key in keys)
    [self cancelKey:key.unsignedLongLongValue];
  [self.input stop];
  [self.audio cancelActiveSession];
  self.eventCallback = NULL;
}
@end

struct friday_host_native {
  void *controller;
};
static NSData *FridayJSON(NSDictionary *result) {
  return [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
}
extern "C" friday_host_native *
friday_host_native_create(const char *dataDir,
                          friday_host_event_callback callback, void *context) {
  friday_host_native *host = new friday_host_native;
  NSString *directory = dataDir ? [NSString stringWithUTF8String:dataDir] : @"";
  host->controller = (__bridge_retained void *)[[FridayHostController alloc]
      initWithDataDirectory:directory
                   callback:callback
                    context:context];
  return host;
}
extern "C" void friday_host_native_destroy(friday_host_native *host) {
  if (!host)
    return;
  FridayHostController *controller =
      (__bridge FridayHostController *)host->controller;
  [controller shutdown];
  CFBridgingRelease(host->controller);
  delete host;
}
extern "C" size_t friday_host_native_request(friday_host_native *host,
                                             const char *name,
                                             size_t nameLength,
                                             const uint8_t *payload,
                                             size_t payloadLength, bool *ok,
                                             uint8_t *output, size_t capacity) {
  if (!host || !output || !capacity)
    return 0;
  FridayHostController *controller =
      (__bridge FridayHostController *)host->controller;
  NSString *command = [[NSString alloc] initWithBytes:name
                                               length:nameLength
                                             encoding:NSUTF8StringEncoding]
                          ?: @"";
  NSString *body = [[NSString alloc] initWithBytes:payload
                                            length:payloadLength
                                          encoding:NSUTF8StringEncoding]
                       ?: @"";
  NSDictionary *result = [controller request:command payload:body];
  if (ok)
    *ok = [result[@"ok"] boolValue];
  NSData *json = FridayJSON(result);
  if (!json || json.length >= capacity)
    return 0;
  memcpy(output, (const uint8_t *)json.bytes, json.length);
  return json.length;
}
extern "C" void friday_host_native_request_async(
    friday_host_native *host, uint64_t key, const char *name, size_t nameLength,
    const uint8_t *payload, size_t payloadLength,
    friday_host_completion_callback callback, void *context) {
  if (!host || !callback)
    return;
  FridayHostController *controller =
      (__bridge FridayHostController *)host->controller;
  NSString *command = [[NSString alloc] initWithBytes:name
                                               length:nameLength
                                             encoding:NSUTF8StringEncoding]
                          ?: @"";
  NSString *body = [[NSString alloc] initWithBytes:payload
                                            length:payloadLength
                                          encoding:NSUTF8StringEncoding]
                       ?: @"";
  [controller requestAsync:command
                   payload:body
                       key:key
                completion:^(NSDictionary *result) {
                  NSData *json = FridayJSON(result);
                  callback(context, key, [result[@"ok"] boolValue],
                           (const uint8_t *)json.bytes, json.length);
                }];
}
extern "C" void friday_host_native_cancel(friday_host_native *host,
                                          uint64_t key) {
  if (host)
    [(__bridge FridayHostController *)host->controller cancelKey:key];
}
extern "C" size_t friday_host_native_contract_probes(uint8_t *output,
                                                     size_t capacity) {
  if (!output || capacity == 0)
    return 0;
  @autoreleasepool {
    FridaySourceTarget *copyOnlySource = [FridaySourceTarget new];
    copyOnlySource.token = @"contract-copy-only";
    copyOnlySource.capturedAt = [NSDate date];
    NSDictionary *copyOnly = [[FridayTextDelivery new]
               deliverText:@"Friday copy-only delivery contract"
                  toSource:copyOnlySource
        pasteAutomatically:NO];
    NSDictionary *result = @{
      @"audio" : [FridayAudioSession runStorageProbe],
      @"converterFailure" : [FridayAudioSession runFailureCleanupProbe],
      @"models" : [FridayModelRepository runRepositoryProbes],
      @"copyOnlyDelivery" : copyOnly
    };
    NSData *json = FridayJSON(result);
    if (!json || json.length >= capacity)
      return 0;
    memcpy(output, json.bytes, json.length);
    return json.length;
  }
}
