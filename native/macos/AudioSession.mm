#import "AudioSession.h"
#import <AVFAudio/AVAudioEngine.h>
#import <AVFAudio/AVAudioNode.h>
#import <AVFAudio/AVAudioBuffer.h>
#import <AVFAudio/AVAudioFormat.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static constexpr uint64_t kFridayRate=16000;
static constexpr uint64_t kFridayWarningFrames=kFridayRate*585;
static constexpr uint64_t kFridayMaximumFrames=kFridayRate*600;

class FridayRing {
public:
    explicit FridayRing(size_t capacity):values(capacity){}
    bool push(float value){uint64_t w=write.load(std::memory_order_relaxed),r=read.load(std::memory_order_acquire);if(w-r>=values.size()){dropped.fetch_add(1);return false;}values[w%values.size()]=value;write.store(w+1,std::memory_order_release);return true;}
    size_t pop(float *out,size_t capacity){uint64_t r=read.load(std::memory_order_relaxed),w=write.load(std::memory_order_acquire);size_t count=(size_t)std::min<uint64_t>(w-r,capacity);for(size_t i=0;i<count;i++)out[i]=values[(r+i)%values.size()];read.store(r+count,std::memory_order_release);return count;}
    uint64_t drops()const{return dropped.load(std::memory_order_acquire);}
private:
    std::vector<float> values; std::atomic<uint64_t> write{0},read{0},dropped{0};
};

@interface FridayAudioSession ()
@property(nonatomic,copy) FridayAudioEventHandler handler;
@property(nonatomic,strong) AVAudioEngine *engine;
@property(nonatomic,readwrite,getter=isActive) BOOL active;
@property(nonatomic,readwrite,strong,nullable) NSURL *retryAudioURL;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) FILE *file;
@property(nonatomic,strong) NSURL *url;
@property(nonatomic) uint64_t sessionID;
@property(nonatomic) double hardwareRate;
@property(nonatomic) double accumulator;
@property(nonatomic) uint64_t startedAtMs;
@property(nonatomic) uint64_t firstAudioAtMs;
@property(nonatomic) BOOL warned;
@end

@implementation FridayAudioSession { std::unique_ptr<FridayRing> _ring; std::atomic<uint64_t> _frames; }
- (instancetype)initWithEventHandler:(FridayAudioEventHandler)handler {
    if((self=[super init])){_handler=[handler copy];_queue=dispatch_queue_create("com.phall.friday.audio",DISPATCH_QUEUE_SERIAL);[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(configurationChanged:) name:AVAudioEngineConfigurationChangeNotification object:nil];}
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; if(self.active)[self cancelSession:self.sessionID]; }
- (uint64_t)now { return (uint64_t)llround(NSDate.date.timeIntervalSince1970*1000); }
- (NSDictionary *)startSession:(uint64_t)sessionID error:(NSError **)error {
    if(self.active){if(error)*error=[NSError errorWithDomain:@"com.phall.friday.audio" code:1 userInfo:@{NSLocalizedDescriptionKey:@"A recording is already active."}];return nil;}
    [self discardRetryAudio]; NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:@"Friday/Audio"];[NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    self.url=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"session-%llu.f32",sessionID]]];self.file=fopen(self.url.fileSystemRepresentation,"wb");if(!self.file){if(error)*error=[NSError errorWithDomain:@"com.phall.friday.audio" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Friday could not create temporary audio storage."}];return nil;}
    self.engine=[AVAudioEngine new];AVAudioInputNode *input=self.engine.inputNode;AVAudioFormat *format=[input inputFormatForBus:0];if(format.sampleRate<8000||format.sampleRate>96000||format.channelCount==0){fclose(self.file);self.file=NULL;if(error)*error=[NSError errorWithDomain:@"com.phall.friday.audio" code:3 userInfo:@{NSLocalizedDescriptionKey:@"The microphone format is unsupported."}];return nil;}
    self.sessionID=sessionID;self.hardwareRate=format.sampleRate;self.accumulator=0;_frames.store(0);self.startedAtMs=[self now];self.firstAudioAtMs=0;self.warned=NO;_ring=std::make_unique<FridayRing>((size_t)format.sampleRate*4);self.active=YES;
    __weak FridayAudioSession *weak=self;
    [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer,AVAudioTime *when){(void)when;FridayAudioSession *strong=weak;if(!strong||!strong.active||!buffer.floatChannelData)return;uint32_t channels=buffer.format.channelCount;for(uint32_t i=0;i<buffer.frameLength;i++){float sample=0;for(uint32_t c=0;c<channels;c++)sample+=buffer.floatChannelData[c][i];strong->_ring->push(std::clamp(sample/(float)channels,-1.0f,1.0f));}if(strong.firstAudioAtMs==0&&buffer.frameLength)strong.firstAudioAtMs=[strong now];}];
    self.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),10*NSEC_PER_MSEC,2*NSEC_PER_MSEC);dispatch_source_set_event_handler(self.timer,^{[weak drain];});dispatch_resume(self.timer);
    NSError *startError=nil;if(![self.engine startAndReturnError:&startError]){self.active=NO;[input removeTapOnBus:0];dispatch_source_cancel(self.timer);self.timer=nil;fclose(self.file);self.file=NULL;[NSFileManager.defaultManager removeItemAtURL:self.url error:nil];if(error)*error=startError;return nil;}
    return @{@"ok":@YES,@"sessionId":@(sessionID),@"captureStartedAtMs":@(self.startedAtMs),@"sampleRate":@(kFridayRate),@"channels":@1};
}
- (void)drain {
    if(!_ring||!self.file)return;float input[4096],output[4096];size_t count=0;
    while((count=_ring->pop(input,4096))>0){size_t out=0;double step=(double)kFridayRate/self.hardwareRate;for(size_t i=0;i<count&&_frames.load()<kFridayMaximumFrames;i++){self.accumulator+=step;while(self.accumulator>=1&&out<4096){output[out++]=input[i];self.accumulator-=1;_frames.fetch_add(1);}}if(out)fwrite(output,sizeof(float),out,self.file);}
    uint64_t frames=_frames.load();if(frames>=kFridayWarningFrames&&!self.warned){self.warned=YES;dispatch_async(dispatch_get_main_queue(),^{self.handler(@"duration_warning",@{@"sessionId":@(self.sessionID),@"capturedFrames":@(frames)});});}
    if(frames>=kFridayMaximumFrames)dispatch_async(dispatch_get_main_queue(),^{if(self.active)self.handler(@"duration_limit",@{@"sessionId":@(self.sessionID),@"capturedFrames":@(kFridayMaximumFrames)});});
}
- (void)stopSession:(uint64_t)sessionID completion:(void (^)(NSDictionary<NSString *,id> *))completion {
    if(!self.active||sessionID!=self.sessionID){completion(@{@"ok":@NO,@"sessionId":@(sessionID),@"message":@"The recording is stale."});return;}self.active=NO;[self.engine.inputNode removeTapOnBus:0];[self.engine stop];if(self.timer){dispatch_source_cancel(self.timer);self.timer=nil;}
    dispatch_async(self.queue,^{[self drain];if(self.file){fflush(self.file);fsync(fileno(self.file));fclose(self.file);self.file=NULL;}uint64_t drops=self->_ring?self->_ring->drops():0;self->_ring.reset();self.retryAudioURL=self.url;uint64_t frames=_frames.load();NSDictionary *result=@{@"ok":@(drops==0),@"sessionId":@(sessionID),@"audioPath":self.url.path,@"capturedFrames":@(frames),@"audioDurationMs":@(frames*1000/kFridayRate),@"captureStartedAtMs":@(self.startedAtMs),@"firstAudioAtMs":@(self.firstAudioAtMs),@"captureStoppedAtMs":@([self now]),@"droppedFrames":@(drops),@"retryAudioAvailable":@YES};dispatch_async(dispatch_get_main_queue(),^{completion(result);});});
}
- (void)cancelActiveSession { if(self.active)[self cancelSession:self.sessionID]; }
- (void)cancelSession:(uint64_t)sessionID { if(!self.active||sessionID!=self.sessionID)return;self.active=NO;[self.engine.inputNode removeTapOnBus:0];[self.engine stop];if(self.timer){dispatch_source_cancel(self.timer);self.timer=nil;}dispatch_sync(self.queue,^{if(self.file){fclose(self.file);self.file=NULL;}self->_ring.reset();});[NSFileManager.defaultManager removeItemAtURL:self.url error:nil]; }
- (void)discardRetryAudio { if(self.retryAudioURL)[NSFileManager.defaultManager removeItemAtURL:self.retryAudioURL error:nil];self.retryAudioURL=nil; }
- (void)configurationChanged:(NSNotification *)note { (void)note;if(self.active){uint64_t session=self.sessionID;[self cancelSession:session];self.handler(@"audio_interrupted",@{@"sessionId":@(session),@"reason":@"The microphone route changed during recording."});} }
+ (NSDictionary *)runStorageProbe {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"friday-10-minute-probe.f32"];
    int fd=open(path.fileSystemRepresentation,O_CREAT|O_TRUNC|O_RDWR,0600);
    off_t expected=(off_t)kFridayMaximumFrames*sizeof(float);
    BOOL storageOK=fd>=0&&ftruncate(fd,expected)==0;
    struct stat st={};
    if(fd>=0){fstat(fd,&st);close(fd);}
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    FridayRing ring(4);
    ring.push(0);ring.push(0);ring.push(0);ring.push(0);BOOL overflowRejected=!ring.push(0);
    BOOL ok=storageOK&&st.st_size==expected&&overflowRejected&&ring.drops()==1;
    return @{@"ok":@(ok),@"frames":@(kFridayMaximumFrames),@"bytes":@(st.st_size),@"expectedBytes":@(expected),@"durationSeconds":@600,@"warningAtSeconds":@585,@"warningFrames":@(kFridayWarningFrames),@"droppedFrameFailure":@(overflowRejected&&ring.drops()==1)};
}
@end
