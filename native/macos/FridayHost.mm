#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFAudio/AVAudioApplication.h>

#import "friday_host.h"
#import "GlobalInputMonitor.h"
#import "OverlayWindow.h"
#import "TextDelivery.h"

@interface FridayHostController : NSObject
@property(nonatomic) friday_host_event_callback callback;
@property(nonatomic) void *callbackContext;
@property(nonatomic, strong) FridayGlobalInputMonitor *input;
@property(nonatomic, strong) FridayTextDelivery *delivery;
@property(nonatomic, strong) FridayOverlayWindow *overlay;
@property(nonatomic, strong) NSMutableDictionary<NSString *, FridaySourceTarget *> *sources;
- (NSDictionary<NSString *, id> *)request:(NSString *)name payload:(NSString *)payload;
@end

@implementation FridayHostController
- (instancetype)initWithCallback:(friday_host_event_callback)callback context:(void *)context {
    if ((self=[super init])) {
        _callback=callback; _callbackContext=context; _sources=[NSMutableDictionary dictionary]; _delivery=[FridayTextDelivery new];
        __weak FridayHostController *weak=self;
        _input=[[FridayGlobalInputMonitor alloc] initWithHandler:^(NSString *event, NSDictionary<NSString *,id> *payload) {
            FridayHostController *strong=weak; if(!strong)return;
            if([event isEqualToString:@"hotkey_down"]) {
                FridaySourceTarget *source=[FridaySourceTarget new]; source.token=payload[@"token"]; source.pid=[payload[@"pid"] intValue]; source.bundleID=payload[@"bundleId"]; source.appName=payload[@"appName"]; strong.sources[source.token]=source;
                [strong emit:[NSString stringWithFormat:@"hotkey_down|%.0f|%@|%d|%@|%@",[payload[@"atMs"] doubleValue],[strong b64:source.token],source.pid,[strong b64:source.bundleID],[strong b64:source.appName]]];
            } else [strong emit:[NSString stringWithFormat:@"hotkey_up|%.0f",[payload[@"atMs"] doubleValue]]];
        }];
        _overlay=[[FridayOverlayWindow alloc] initWithHandler:^(NSString *action){ [weak emit:action]; }];
    }
    return self;
}
- (void)dealloc { [self.input stop]; [self.overlay hide]; }
- (NSString *)b64:(NSString *)text { return [[text dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]; }
- (NSString *)fromB64:(NSString *)text { NSData *data=[[NSData alloc] initWithBase64EncodedString:text options:0]; return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""; }
- (void)emit:(NSString *)event { NSData *bytes=[event dataUsingEncoding:NSUTF8StringEncoding]; if(self.callback&&bytes.length)self.callback(self.callbackContext,(const uint8_t *)bytes.bytes,bytes.length); }
- (NSDictionary *)permissions {
    AVAudioApplicationRecordPermission microphone=AVAudioApplication.sharedInstance.recordPermission;
    return @{@"ok":@YES,@"microphone":@(microphone==AVAudioApplicationRecordPermissionGranted),@"accessibility":@(AXIsProcessTrusted()),@"inputMonitoring":@(self.input.inputMonitoringUsable)};
}
- (NSDictionary<NSString *,id> *)request:(NSString *)name payload:(NSString *)payload {
    if([name isEqualToString:@"friday.spike"]) return @{@"ok":@YES,@"bridge":@"ok",@"platform":@"macos",@"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier ?: @"unbundled",@"permissions":[self permissions]};
    if([name isEqualToString:@"friday.permissions"]) return [self permissions];
    if([name isEqualToString:@"friday.permissions.request"]) {
        if([payload isEqualToString:@"input"]) [self.input requestPermission];
        if([payload isEqualToString:@"accessibility"]) AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
        if([payload isEqualToString:@"microphone"]) [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted){ [self emit:[NSString stringWithFormat:@"permissions|%d|%d|%d",granted,AXIsProcessTrusted(),self.input.inputMonitoringUsable]]; }];
        return [self permissions];
    }
    if([name isEqualToString:@"friday.hotkey.configure"]) {
        NSError *error=nil; BOOL configured=[self.input configureFromString:payload error:&error]; BOOL started=configured&&[self.input start:&error];
        return @{@"ok":@(started),@"configured":@(configured),@"running":@(self.input.running),@"message":error.localizedDescription ?: @"Global shortcut is active."};
    }
    if([name isEqualToString:@"friday.hotkey.probe"]) return [self.input runSyntheticProbe];
    if([name isEqualToString:@"friday.source.capture"]) {
        FridaySourceTarget *source=[self.delivery captureFrontmostSource]; self.sources[source.token]=source;
        return @{@"ok":@YES,@"token":[self b64:source.token],@"pid":@(source.pid),@"bundleId":[self b64:source.bundleID],@"appName":[self b64:source.appName]};
    }
    if([name isEqualToString:@"friday.deliver"]) {
        NSArray *parts=[payload componentsSeparatedByString:@"|"]; if(parts.count!=2)return @{@"ok":@NO,@"message":@"Invalid delivery request."};
        FridaySourceTarget *source=self.sources[[self fromB64:parts[0]]]; if(!source)return @{@"ok":@NO,@"message":@"The exact source target is no longer available."};
        return [self.delivery deliverText:[self fromB64:parts[1]] toSource:source];
    }
    if([name isEqualToString:@"friday.delivery.probe"]) return [self.delivery runProbeForApplication:payload.length?payload:@"TextEdit"];
    if([name isEqualToString:@"friday.overlay.show"]) { [self.overlay showLocked:[payload isEqualToString:@"locked"] elapsedMilliseconds:0]; return @{@"ok":@YES,@"message":@"Overlay shown without activation."}; }
    if([name isEqualToString:@"friday.overlay.transcribing"]) { [self.overlay showTranscribing]; return @{@"ok":@YES}; }
    if([name isEqualToString:@"friday.overlay.hide"]) { [self.overlay hide]; return @{@"ok":@YES}; }
    if([name isEqualToString:@"friday.overlay.probe"]) return [self.overlay runInteractionProbe];
    if([name isEqualToString:@"friday.diagnostics"]) return @{@"ok":@YES,@"permissions":[self permissions],@"hotkeyRunning":@(self.input.running),@"sourceCount":@(self.sources.count),@"transcriptIncluded":@NO,@"audioIncluded":@NO};
    return @{@"ok":@NO,@"message":@"Unknown FridayHost command."};
}
@end

struct friday_host_native { void *controller; };

extern "C" friday_host_native *friday_host_native_create(const char *data_dir, friday_host_event_callback callback, void *context) {
    (void)data_dir; friday_host_native *host=new friday_host_native; host->controller=(__bridge_retained void *)[[FridayHostController alloc] initWithCallback:callback context:context]; return host;
}
extern "C" void friday_host_native_destroy(friday_host_native *host) { if(!host)return; CFBridgingRelease(host->controller); delete host; }
extern "C" size_t friday_host_native_request(friday_host_native *host,const char *name,size_t nameLength,const uint8_t *payload,size_t payloadLength,bool *ok,uint8_t *output,size_t capacity) {
    if(!host||!output||capacity==0)return 0; FridayHostController *controller=(__bridge FridayHostController *)host->controller;
    NSString *command=[[NSString alloc] initWithBytes:name length:nameLength encoding:NSUTF8StringEncoding] ?: @""; NSString *body=[[NSString alloc] initWithBytes:payload length:payloadLength encoding:NSUTF8StringEncoding] ?: @"";
    NSDictionary *result=[controller request:command payload:body]; if(ok)*ok=[result[@"ok"] boolValue]; NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]; if(!json||json.length>=capacity)return 0; memcpy(output,json.bytes,json.length); return json.length;
}
