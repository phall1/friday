#import "AudioSession.h"
#import <AVFAudio/AVAudioBuffer.h>
#import <AVFAudio/AVAudioConverter.h>
#import <AVFAudio/AVAudioEngine.h>
#import <AVFAudio/AVAudioFormat.h>
#import <AVFAudio/AVAudioIONode.h>
#import <AVFAudio/AVAudioSinkNode.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <fcntl.h>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static constexpr uint64_t kFridayRate = 16000;
static constexpr uint64_t kFridayWarningFrames = kFridayRate * 585;
static constexpr uint64_t kFridayMaximumFrames = kFridayRate * 600;

class FridayRing {
public:
  explicit FridayRing(size_t capacity) : values_(capacity) {}

  bool push(float value) {
    const uint64_t write = write_.load(std::memory_order_relaxed);
    const uint64_t read = read_.load(std::memory_order_acquire);
    if (write - read >= values_.size()) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
    values_[write % values_.size()] = value;
    write_.store(write + 1, std::memory_order_release);
    return true;
  }

  size_t pop(float *output, size_t capacity) {
    const uint64_t read = read_.load(std::memory_order_relaxed);
    const uint64_t write = write_.load(std::memory_order_acquire);
    const size_t count =
        static_cast<size_t>(std::min<uint64_t>(write - read, capacity));
    for (size_t index = 0; index < count; ++index) {
      output[index] = values_[(read + index) % values_.size()];
    }
    read_.store(read + count, std::memory_order_release);
    return count;
  }

  uint64_t dropped() const { return dropped_.load(std::memory_order_acquire); }

private:
  std::vector<float> values_;
  std::atomic<uint64_t> write_{0};
  std::atomic<uint64_t> read_{0};
  std::atomic<uint64_t> dropped_{0};
};

struct FridayRealtimeCapture {
  explicit FridayRealtimeCapture(size_t capacity, uint32_t channels,
                                 bool interleaved)
      : ring(capacity), channel_count(channels), is_interleaved(interleaved) {}

  std::atomic<bool> accepting{true};
  FridayRing ring;
  const uint32_t channel_count;
  const bool is_interleaved;

  void push(const AudioBufferList *buffers, AVAudioFrameCount frame_count) {
    if (!accepting.load(std::memory_order_acquire) || buffers == nullptr)
      return;
    if (is_interleaved) {
      if (buffers->mNumberBuffers == 0 || buffers->mBuffers[0].mData == nullptr)
        return;
      const float *samples =
          static_cast<const float *>(buffers->mBuffers[0].mData);
      for (AVAudioFrameCount frame = 0; frame < frame_count; ++frame) {
        float mono = 0;
        for (uint32_t channel = 0; channel < channel_count; ++channel) {
          mono += samples[frame * channel_count + channel];
        }
        ring.push(
            std::clamp(mono / static_cast<float>(channel_count), -1.0f, 1.0f));
      }
      return;
    }
    if (buffers->mNumberBuffers < channel_count)
      return;
    for (AVAudioFrameCount frame = 0; frame < frame_count; ++frame) {
      float mono = 0;
      for (uint32_t channel = 0; channel < channel_count; ++channel) {
        const float *samples =
            static_cast<const float *>(buffers->mBuffers[channel].mData);
        if (samples != nullptr)
          mono += samples[frame];
      }
      ring.push(
          std::clamp(mono / static_cast<float>(channel_count), -1.0f, 1.0f));
    }
  }
};

@interface FridayAudioSession ()
@property(nonatomic, copy) FridayAudioEventHandler handler;
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioSinkNode *sink;
@property(nonatomic, strong) AVAudioConverter *converter;
@property(nonatomic, strong) AVAudioFormat *converterInputFormat;
@property(nonatomic, strong) AVAudioFormat *converterOutputFormat;
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@property(nonatomic, readwrite, strong, nullable) NSURL *retryAudioURL;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) FILE *file;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) uint64_t sessionID;
@property(nonatomic) uint64_t startedAtMs;
@property(nonatomic) uint64_t firstAudioAtMs;
@property(nonatomic) BOOL warned;
@end

@implementation FridayAudioSession {
  std::unique_ptr<FridayRealtimeCapture> _realtime;
  std::atomic<uint64_t> _frames;
  std::atomic<bool> _conversionFailure;
}

- (instancetype)initWithEventHandler:(FridayAudioEventHandler)handler {
  self = [super init];
  if (self) {
    _handler = [handler copy];
    _conversionFailure.store(false, std::memory_order_relaxed);
    _queue =
        dispatch_queue_create("com.phall.friday.audio", DISPATCH_QUEUE_SERIAL);
    NSString *root =
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"Friday/Audio"];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(configurationChanged:)
               name:AVAudioEngineConfigurationChangeNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self cancelActiveSession];
  [self discardRetryAudio];
}

- (uint64_t)now {
  return (uint64_t)llround(NSDate.date.timeIntervalSince1970 * 1000);
}

- (NSDictionary *)startSession:(uint64_t)sessionID error:(NSError **)error {
  if (self.active) {
    if (error)
      *error = [NSError
          errorWithDomain:@"com.phall.friday.audio"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"A recording is already active."
                 }];
    return nil;
  }
  [self discardRetryAudio];
  NSString *root =
      [NSTemporaryDirectory() stringByAppendingPathComponent:@"Friday/Audio"];
  [NSFileManager.defaultManager createDirectoryAtPath:root
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  self.url = [NSURL
      fileURLWithPath:[root stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"session-%llu.f32",
                                                           sessionID]]];
  self.file = fopen(self.url.fileSystemRepresentation, "wb");
  if (!self.file) {
    if (error)
      *error = [NSError
          errorWithDomain:@"com.phall.friday.audio"
                     code:2
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"Friday could not create temporary audio storage."
                 }];
    return nil;
  }

  self.engine = [AVAudioEngine new];
  AVAudioInputNode *input = self.engine.inputNode;
  AVAudioFormat *hardware = [input outputFormatForBus:0];
  if (hardware.commonFormat != AVAudioPCMFormatFloat32 ||
      hardware.sampleRate < 8000 || hardware.sampleRate > 96000 ||
      hardware.channelCount == 0) {
    fclose(self.file);
    self.file = NULL;
    [NSFileManager.defaultManager removeItemAtURL:self.url error:nil];
    if (error)
      *error = [NSError
          errorWithDomain:@"com.phall.friday.audio"
                     code:3
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"The microphone format cannot be converted safely."
                 }];
    return nil;
  }

  self.converterInputFormat = [[AVAudioFormat alloc]
      initStandardFormatWithSampleRate:hardware.sampleRate
                              channels:1];
  self.converterOutputFormat =
      [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kFridayRate
                                                     channels:1];
  self.converter =
      [[AVAudioConverter alloc] initFromFormat:self.converterInputFormat
                                      toFormat:self.converterOutputFormat];
  if (!self.converter) {
    fclose(self.file);
    self.file = NULL;
    [NSFileManager.defaultManager removeItemAtURL:self.url error:nil];
    if (error)
      *error =
          [NSError errorWithDomain:@"com.phall.friday.audio"
                              code:4
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Friday could not create the audio converter."
                          }];
    return nil;
  }
  self.converter.sampleRateConverterQuality = AVAudioQualityMax;

  _realtime = std::make_unique<FridayRealtimeCapture>(
      static_cast<size_t>(hardware.sampleRate * 4), hardware.channelCount,
      hardware.interleaved);
  FridayRealtimeCapture *realtime = _realtime.get();
  self.sink = [[AVAudioSinkNode alloc]
      initWithReceiverBlock:^OSStatus(const AudioTimeStamp *timestamp,
                                      AVAudioFrameCount frameCount,
                                      const AudioBufferList *audioData) {
        (void)timestamp;
        realtime->push(audioData, frameCount);
        return noErr;
      }];
  [self.engine attachNode:self.sink];
  [self.engine connect:input to:self.sink format:hardware];

  self.sessionID = sessionID;
  self.startedAtMs = [self now];
  self.firstAudioAtMs = 0;
  self.warned = NO;
  _conversionFailure.store(false, std::memory_order_release);
  _frames.store(0, std::memory_order_release);
  self.active = YES;

  __weak FridayAudioSession *weakSelf = self;
  self.timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
  dispatch_source_set_timer(
      self.timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
      10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(self.timer, ^{
    [weakSelf drainConverter];
  });
  dispatch_resume(self.timer);

  NSError *startError = nil;
  if (![self.engine startAndReturnError:&startError]) {
    self.active = NO;
    realtime->accepting.store(false, std::memory_order_release);
    [self.engine disconnectNodeOutput:input];
    [self.engine detachNode:self.sink];
    dispatch_source_cancel(self.timer);
    self.timer = nil;
    fclose(self.file);
    self.file = NULL;
    _realtime.reset();
    [NSFileManager.defaultManager removeItemAtURL:self.url error:nil];
    if (error)
      *error = startError;
    return nil;
  }
  return @{
    @"ok" : @YES,
    @"sessionId" : @(sessionID),
    @"captureStartedAtMs" : @(self.startedAtMs),
    @"sampleRate" : @(kFridayRate),
    @"channels" : @1
  };
}

- (void)failConversion:(NSError *)error {
  if (_conversionFailure.exchange(true, std::memory_order_acq_rel))
    return;
  if (_realtime)
    _realtime->accepting.store(false, std::memory_order_release);
  uint64_t session = self.sessionID;
  NSString *reason = error.localizedDescription ?: @"Audio conversion failed.";
  dispatch_async(dispatch_get_main_queue(), ^{
    self.active = NO;
    [self.engine stop];
    [self.engine disconnectNodeOutput:self.engine.inputNode];
    if (self.sink)
      [self.engine detachNode:self.sink];
    if (self.timer) {
      dispatch_source_cancel(self.timer);
      self.timer = nil;
    }
    dispatch_async(self.queue, ^{
      if (self.file) {
        fclose(self.file);
        self.file = NULL;
      }
      [NSFileManager.defaultManager removeItemAtURL:self.url error:nil];
      self.retryAudioURL = nil;
      self->_realtime.reset();
      dispatch_async(dispatch_get_main_queue(), ^{
        self.handler(
            @"audio_interrupted",
            @{@"sessionId" : @(session),
              @"reason" : reason});
      });
    });
  });
}

- (void)drainConverter {
  if (!_realtime || !self.file || !self.converter)
    return;
  float samples[4096];
  size_t count = 0;
  while ((count = _realtime->ring.pop(samples, 4096)) > 0 &&
         _frames.load(std::memory_order_acquire) < kFridayMaximumFrames) {
    if (self.firstAudioAtMs == 0)
      self.firstAudioAtMs = [self now];
    AVAudioPCMBuffer *input =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.converterInputFormat
                                      frameCapacity:(AVAudioFrameCount)count];
    input.frameLength = (AVAudioFrameCount)count;
    memcpy(input.floatChannelData[0], samples, count * sizeof(float));
    const AVAudioFrameCount capacity =
        (AVAudioFrameCount)ceil((double)count * kFridayRate /
                                self.converterInputFormat.sampleRate) +
        64;
    AVAudioPCMBuffer *output =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.converterOutputFormat
                                      frameCapacity:capacity];
    __block BOOL supplied = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status =
        [self.converter convertToBuffer:output
                                  error:&error
                     withInputFromBlock:^AVAudioBuffer *(
                         AVAudioPacketCount requested,
                         AVAudioConverterInputStatus *inputStatus) {
                       (void)requested;
                       if (supplied) {
                         *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                         return nil;
                       }
                       supplied = YES;
                       *inputStatus = AVAudioConverterInputStatus_HaveData;
                       return input;
                     }];
    if (status == AVAudioConverterOutputStatus_Error || error) {
      [self failConversion:error];
      return;
    }
    uint64_t remaining =
        kFridayMaximumFrames - _frames.load(std::memory_order_acquire);
    AVAudioFrameCount frames =
        (AVAudioFrameCount)std::min<uint64_t>(output.frameLength, remaining);
    if (frames > 0) {
      fwrite(output.floatChannelData[0], sizeof(float), frames, self.file);
      _frames.fetch_add(frames, std::memory_order_release);
    }
  }
  const uint64_t frames = _frames.load(std::memory_order_acquire);
  if (frames >= kFridayWarningFrames && !self.warned) {
    self.warned = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      self.handler(
          @"duration_warning",
          @{@"sessionId" : @(self.sessionID),
            @"capturedFrames" : @(frames)});
    });
  }
  if (frames >= kFridayMaximumFrames) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.active)
        self.handler(
            @"duration_limit", @{
              @"sessionId" : @(self.sessionID),
              @"capturedFrames" : @(kFridayMaximumFrames)
            });
    });
  }
}

- (void)stopSession:(uint64_t)sessionID
         completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (!self.active || sessionID != self.sessionID) {
    completion(@{
      @"ok" : @NO,
      @"sessionId" : @(sessionID),
      @"message" : @"The recording is stale."
    });
    return;
  }
  self.active = NO;
  _realtime->accepting.store(false, std::memory_order_release);
  [self.engine stop];
  [self.engine disconnectNodeOutput:self.engine.inputNode];
  [self.engine detachNode:self.sink];
  if (self.timer) {
    dispatch_source_cancel(self.timer);
    self.timer = nil;
  }
  dispatch_async(self.queue, ^{
    [self drainConverter];
    [self flushConverter];
    if (self.file) {
      fflush(self.file);
      fsync(fileno(self.file));
      fclose(self.file);
      self.file = NULL;
    }
    const uint64_t drops =
        self->_realtime ? self->_realtime->ring.dropped() : 0;
    self->_realtime.reset();
    const uint64_t frames = self->_frames.load(std::memory_order_acquire);
    const BOOL retry = drops == 0;
    if (retry)
      self.retryAudioURL = self.url;
    else {
      [NSFileManager.defaultManager removeItemAtURL:self.url error:nil];
      self.retryAudioURL = nil;
    }
    NSDictionary *result = @{
      @"ok" : @(drops == 0),
      @"sessionId" : @(sessionID),
      @"audioPath" : retry ? self.url.path : @"",
      @"capturedFrames" : @(frames),
      @"audioDurationMs" : @(frames * 1000 / kFridayRate),
      @"captureStartedAtMs" : @(self.startedAtMs),
      @"firstAudioAtMs" : @(self.firstAudioAtMs),
      @"captureStoppedAtMs" : @([self now]),
      @"droppedFrames" : @(drops),
      @"retryAudioAvailable" : @(retry)
    };
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(result);
    });
  });
}

- (void)cancelActiveSession {
  if (self.active)
    [self cancelSession:self.sessionID];
}
- (void)flushConverter {
  if (!self.converter || !self.file)
    return;
  while (_frames.load(std::memory_order_acquire) < kFridayMaximumFrames) {
    AVAudioPCMBuffer *output =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.converterOutputFormat
                                      frameCapacity:1024];
    NSError *error = nil;
    AVAudioConverterOutputStatus status =
        [self.converter convertToBuffer:output
                                  error:&error
                     withInputFromBlock:^AVAudioBuffer *(
                         AVAudioPacketCount requested,
                         AVAudioConverterInputStatus *inputStatus) {
                       (void)requested;
                       *inputStatus = AVAudioConverterInputStatus_EndOfStream;
                       return nil;
                     }];
    if (status != AVAudioConverterOutputStatus_HaveData ||
        output.frameLength == 0 || error)
      break;
    uint64_t remaining =
        kFridayMaximumFrames - _frames.load(std::memory_order_acquire);
    AVAudioFrameCount frames =
        (AVAudioFrameCount)std::min<uint64_t>(output.frameLength, remaining);
    fwrite(output.floatChannelData[0], sizeof(float), frames, self.file);
    _frames.fetch_add(frames, std::memory_order_release);
  }
}

- (void)cancelSession:(uint64_t)sessionID {
  if (!self.active || sessionID != self.sessionID)
    return;
  self.active = NO;
  _realtime->accepting.store(false, std::memory_order_release);
  [self.engine stop];
  [self.engine disconnectNodeOutput:self.engine.inputNode];
  [self.engine detachNode:self.sink];
  if (self.timer) {
    dispatch_source_cancel(self.timer);
    self.timer = nil;
  }
  dispatch_sync(self.queue, ^{
    if (self.file) {
      fclose(self.file);
      self.file = NULL;
    }
    self->_realtime.reset();
  });
  [NSFileManager.defaultManager removeItemAtURL:self.url error:nil];
}

- (void)discardRetryAudio {
  if (self.retryAudioURL)
    [NSFileManager.defaultManager removeItemAtURL:self.retryAudioURL error:nil];
  self.retryAudioURL = nil;
}

- (void)configurationChanged:(NSNotification *)note {
  (void)note;
  if (!self.active)
    return;
  const uint64_t session = self.sessionID;
  [self cancelSession:session];
  self.handler(@"audio_interrupted", @{
    @"sessionId" : @(session),
    @"reason" : @"The microphone route changed during recording."
  });
}

+ (NSDictionary *)runStorageProbe {
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"friday-10-minute-probe.f32"];
  int fd =
      open(path.fileSystemRepresentation, O_CREAT | O_TRUNC | O_RDWR, 0600);
  off_t expected = (off_t)kFridayMaximumFrames * sizeof(float);
  BOOL storageOK = fd >= 0 && ftruncate(fd, expected) == 0;
  struct stat attributes = {};
  if (fd >= 0) {
    fstat(fd, &attributes);
    close(fd);
  }
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  FridayRing ring(4);
  ring.push(0);
  ring.push(0);
  ring.push(0);
  ring.push(0);
  BOOL overflowRejected = !ring.push(0);
  BOOL ok = storageOK && attributes.st_size == expected && overflowRejected &&
            ring.dropped() == 1;
  return @{
    @"ok" : @(ok),
    @"frames" : @(kFridayMaximumFrames),
    @"bytes" : @(attributes.st_size),
    @"expectedBytes" : @(expected),
    @"durationSeconds" : @600,
    @"warningAtSeconds" : @585,
    @"warningFrames" : @(kFridayWarningFrames),
    @"droppedFrameFailure" : @(overflowRejected && ring.dropped() == 1)
  };
}
+ (NSDictionary *)runFailureCleanupProbe {
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"friday-converter-failure-probe.f32"];
  __block BOOL eventReceived = NO;
  FridayAudioSession *session = [[FridayAudioSession alloc]
      initWithEventHandler:^(NSString *event, NSDictionary *payload) {
        (void)payload;
        eventReceived = [event isEqual:@"audio_interrupted"];
      }];
  session.url = [NSURL fileURLWithPath:path];
  session.file = fopen(path.fileSystemRepresentation, "wb");
  session.sessionID = 42;
  session.active = YES;
  [session failConversion:[NSError errorWithDomain:@"com.phall.friday.audio"
                                              code:99
                                          userInfo:nil]];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
  while (!eventReceived && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  BOOL removed = ![NSFileManager.defaultManager fileExistsAtPath:path];
  return @{
    @"ok" : @(eventReceived && removed && !session.active &&
              session.retryAudioURL == nil),
    @"eventReceived" : @(eventReceived),
    @"tempRemoved" : @(removed),
    @"activeCleared" : @(!session.active)
  };
}
@end
