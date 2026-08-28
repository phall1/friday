#import "NemoRecognizer.h"
#include <atomic>
#include <cmath>
#import <mach/mach.h>
#import <nemo_speech/asr.h>

static const void *FridayNemoQueueKey = &FridayNemoQueueKey;

@interface FridayNemoRecognizer ()
@property(nonatomic, readwrite, copy, nullable) NSString *activeModelPath;
@property(nonatomic, readwrite, getter=isBusy) BOOL busy;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation FridayNemoRecognizer {
  nemo_speech_asr_recognizer *_recognizer;
  std::atomic<uint64_t> _cancelledGeneration;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue =
        dispatch_queue_create("com.phall.friday.nemo", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, FridayNemoQueueKey,
                                (void *)FridayNemoQueueKey, NULL);
    _recognizer = nullptr;
    _cancelledGeneration.store(UINT64_MAX);
  }
  return self;
}

- (void)dealloc {
  [self shutdownAndWait];
}
- (uint64_t)now {
  return (uint64_t)llround(NSDate.date.timeIntervalSince1970 * 1000);
}

- (uint64_t)residentBytes {
  task_vm_info_data_t info = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info,
                   &count) == KERN_SUCCESS
             ? info.phys_footprint
             : 0;
}

- (NSString *)lastError:(NSString *)fallback {
  const char *value = nemo_speech_asr_last_error();
  return value && value[0] ? [NSString stringWithUTF8String:value] ?: fallback
                           : fallback;
}

- (void)activateModelAtPath:(NSString *)path
                 generation:(uint64_t)generation
                 completion:(void (^)(NSDictionary *))completion {
  dispatch_async(self.queue, ^{
    uint64_t started = [self now];
    nemo_speech_asr_backend_config backend = {};
    backend.size = sizeof(backend);
    backend.gpu = 0;
    nemo_speech_asr_model_config model = {};
    model.size = sizeof(model);
    model.path = path.fileSystemRepresentation;
    nemo_speech_asr_recognizer_config config = {};
    config.size = sizeof(config);
    config.backend = &backend;
    config.model = &model;
    nemo_speech_asr_recognizer *candidate = nullptr;
    nemo_speech_asr_status status = nemo_speech_asr_create(&config, &candidate);
    if (self->_cancelledGeneration.load(std::memory_order_acquire) ==
        generation) {
      if (candidate)
        nemo_speech_asr_destroy(candidate);
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"cancelled" : @YES,
          @"generation" : @(generation),
          @"code" : @"cancelled"
        });
      });
      return;
    }
    if (status != NEMO_SPEECH_ASR_OK || !candidate) {
      NSString *message =
          [self lastError:@"The model failed its NeMo runtime probe."];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@{
          @"ok" : @NO,
          @"generation" : @(generation),
          @"code" : @"model_probe_failed",
          @"message" : message
        });
      });
      return;
    }
    if (self->_recognizer)
      nemo_speech_asr_destroy(self->_recognizer);
    self->_recognizer = candidate;
    self.activeModelPath = path;
    uint64_t finished = [self now];
    uint64_t resident = [self residentBytes];
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(@{
        @"ok" : @YES,
        @"generation" : @(generation),
        @"loadDurationMs" : @(finished - started),
        @"residentBytes" : @(resident),
        @"message" : @"The model is warm and ready."
      });
    });
  });
}

- (void)transcribeAudioAtURL:(NSURL *)url
                   sessionID:(uint64_t)sessionID
                  generation:(uint64_t)generation
                  completion:(void (^)(NSDictionary *))completion {
  self.busy = YES;
  dispatch_async(self.queue, ^{
    uint64_t started = [self now];
    if (!self->_recognizer) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = NO;
        completion(@{
          @"ok" : @NO,
          @"sessionId" : @(sessionID),
          @"generation" : @(generation),
          @"code" : @"model_unavailable",
          @"message" : @"The active model is not loaded."
        });
      });
      return;
    }
    NSError *readError = nil;
    NSData *audio = [NSData dataWithContentsOfURL:url
                                          options:NSDataReadingMappedIfSafe
                                            error:&readError];
    if (!audio || audio.length == 0 || audio.length % sizeof(float) != 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = NO;
        completion(@{
          @"ok" : @NO,
          @"sessionId" : @(sessionID),
          @"generation" : @(generation),
          @"code" : @"audio_unavailable",
          @"message" : readError.localizedDescription
              ?: @"Retry audio is unavailable."
        });
      });
      return;
    }
    const float *samples = static_cast<const float *>(audio.bytes);
    size_t sampleCount = audio.length / sizeof(float);
    double energy = 0;
    float peak = 0;
    for (size_t index = 0; index < sampleCount; ++index) {
      energy += static_cast<double>(samples[index]) * samples[index];
      peak = fmaxf(peak, fabsf(samples[index]));
    }
    if (sqrt(energy / sampleCount) < .0015 || peak < .008) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = NO;
        completion(@{
          @"ok" : @YES,
          @"sessionId" : @(sessionID),
          @"generation" : @(generation),
          @"text" : @"",
          @"silence" : @YES,
          @"inferenceStartedAtMs" : @(started),
          @"transcriptReadyAtMs" : @([self now])
        });
      });
      return;
    }
    nemo_speech_asr_recognition_options options =
        nemo_speech_asr_recognition_options_default();
    options.interim_results = false;
    options.enable_automatic_punctuation = true;
    nemo_speech_asr_result *result = nullptr;
    nemo_speech_asr_status status = nemo_speech_asr_recognize_f32(
        self->_recognizer, &options, samples, sampleCount, 16000, &result);
    uint64_t finished = [self now];
    if (self->_cancelledGeneration.load(std::memory_order_acquire) ==
        generation) {
      if (result)
        nemo_speech_asr_result_destroy(result);
      dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = NO;
        completion(@{
          @"ok" : @NO,
          @"cancelled" : @YES,
          @"sessionId" : @(sessionID),
          @"generation" : @(generation),
          @"code" : @"cancelled"
        });
      });
      return;
    }
    if (status != NEMO_SPEECH_ASR_OK || !result) {
      NSString *message = [self lastError:@"Local transcription failed."];
      if (result)
        nemo_speech_asr_result_destroy(result);
      dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = NO;
        completion(@{
          @"ok" : @NO,
          @"sessionId" : @(sessionID),
          @"generation" : @(generation),
          @"code" : @"transcription_failed",
          @"message" : message,
          @"retryAudioAvailable" : @YES,
          @"inferenceStartedAtMs" : @(started),
          @"transcriptReadyAtMs" : @(finished)
        });
      });
      return;
    }
    NSString *text = @"";
    if (nemo_speech_asr_result_alternative_count(result)) {
      const char *raw = nemo_speech_asr_result_transcript(result, 0);
      if (raw)
        text = [NSString stringWithUTF8String:raw] ?: @"";
    }
    nemo_speech_asr_result_destroy(result);
    uint64_t resident = [self residentBytes];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.busy = NO;
      completion(@{
        @"ok" : @YES,
        @"sessionId" : @(sessionID),
        @"generation" : @(generation),
        @"text" : text,
        @"silence" : @(text.length == 0),
        @"audioDurationMs" : @(sampleCount * 1000 / 16000),
        @"inferenceStartedAtMs" : @(started),
        @"transcriptReadyAtMs" : @(finished),
        @"latencyMs" : @(finished - started),
        @"residentBytes" : @(resident),
        @"retryAudioAvailable" : @YES
      });
    });
  });
}

- (void)cancelGeneration:(uint64_t)generation {
  _cancelledGeneration.store(generation, std::memory_order_release);
}

- (void)destroyRecognizerOnQueue {
  if (_recognizer) {
    nemo_speech_asr_destroy(_recognizer);
    _recognizer = nullptr;
  }
  self.activeModelPath = nil;
}

- (void)unloadWithCompletion:(void (^)(NSDictionary *))completion {
  dispatch_async(self.queue, ^{
    [self destroyRecognizerOnQueue];
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(@{@"ok" : @YES, @"message" : @"NeMo recognizer unloaded."});
    });
  });
}

- (void)shutdownAndWait {
  if (dispatch_get_specific(FridayNemoQueueKey))
    [self destroyRecognizerOnQueue];
  else
    dispatch_sync(self.queue, ^{
      [self destroyRecognizerOnQueue];
    });
}
@end
