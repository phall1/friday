#import "GlobalInputMonitor.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

@interface FridayGlobalInputMonitor ()
@property(nonatomic, copy) FridayInputEventHandler handler;
@property(nonatomic) CFMachPortRef tap;
@property(nonatomic) CFRunLoopSourceRef source;
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@property(nonatomic) NSInteger keyCode;
@property(nonatomic) CGEventFlags requiredFlags;
@property(nonatomic) BOOL chordDown;
@property(nonatomic) BOOL acceptedDown;
@property(nonatomic) NSUInteger probeDown;
@property(nonatomic) NSUInteger probeUp;
@end

@implementation FridayGlobalInputMonitor
- (instancetype)initWithHandler:(FridayInputEventHandler)handler {
    if ((self=[super init])) {
        _handler=[handler copy]; _keyCode=-1; _requiredFlags=kCGEventFlagMaskCommand|kCGEventFlagMaskShift;
        NSNotificationCenter *center=NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserver:self selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
        [center addObserver:self selector:@selector(sleep:) name:NSWorkspaceWillSleepNotification object:nil];
    }
    return self;
}
- (void)dealloc { [self stop]; [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self]; }
- (BOOL)inputMonitoringUsable { return CGPreflightListenEventAccess(); }
- (void)requestPermission { CGRequestListenEventAccess(); }
- (BOOL)configureFromString:(NSString *)configuration error:(NSError **)error {
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for(NSString *part in [configuration componentsSeparatedByString:@";"]) { NSArray *pair=[part componentsSeparatedByString:@"="]; if(pair.count==2) values[pair[0]]=pair[1]; }
    NSInteger key=[values[@"key"] integerValue]; CGEventFlags flags=0;
    if([values[@"command"] boolValue])flags|=kCGEventFlagMaskCommand; if([values[@"shift"] boolValue])flags|=kCGEventFlagMaskShift;
    if([values[@"option"] boolValue])flags|=kCGEventFlagMaskAlternate; if([values[@"control"] boolValue])flags|=kCGEventFlagMaskControl; if([values[@"fn"] boolValue])flags|=kCGEventFlagMaskSecondaryFn;
    if(key < -1 || key > 127 || (key == -1 && flags == 0)) { if(error)*error=[NSError errorWithDomain:@"com.phall.friday.input" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The shortcut is not globally distinguishable."}]; return NO; }
    [self invalidateActive:@"reconfigured"]; self.keyCode=key; self.requiredFlags=flags; self.chordDown=NO; return YES;
}
static CGEventRef FridayTap(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy; FridayGlobalInputMonitor *monitor=(__bridge FridayGlobalInputMonitor *)context;
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput) { [monitor invalidateActive:@"tap_disabled"]; if(monitor.tap)CGEventTapEnable(monitor.tap,true); return event; }
    [monitor handleType:type event:event]; return event;
}
- (BOOL)start:(NSError **)error {
    if(self.running)return YES;
    if(!self.inputMonitoringUsable){if(error)*error=[NSError errorWithDomain:@"com.phall.friday.input" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Input Monitoring permission is required for the global shortcut."}];return NO;}
    CGEventMask mask=CGEventMaskBit(kCGEventFlagsChanged)|CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp);
    self.tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,FridayTap,(__bridge void *)self);
    if(!self.tap){if(error)*error=[NSError errorWithDomain:@"com.phall.friday.input" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Friday could not create the global event monitor."}];return NO;}
    self.source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,self.tap,0); CFRunLoopAddSource(CFRunLoopGetMain(),self.source,kCFRunLoopCommonModes); CGEventTapEnable(self.tap,true); self.running=YES; return YES;
}
- (void)stop {
    [self invalidateActive:@"stopped"];
    if(self.source){CFRunLoopRemoveSource(CFRunLoopGetMain(),self.source,kCFRunLoopCommonModes);CFRelease(self.source);self.source=NULL;}
    if(self.tap){CFMachPortInvalidate(self.tap);CFRelease(self.tap);self.tap=NULL;} self.running=NO; self.chordDown=NO;
}
- (CGEventFlags)relevant:(CGEventFlags)flags { return flags&(kCGEventFlagMaskCommand|kCGEventFlagMaskShift|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl|kCGEventFlagMaskSecondaryFn); }
- (void)handleType:(CGEventType)type event:(CGEventRef)event {
    CGEventFlags flags=[self relevant:CGEventGetFlags(event)];
    if(self.keyCode==-1){
        if(type!=kCGEventFlagsChanged)return; BOOL down=flags==self.requiredFlags;
        if(down&&!self.chordDown)[self emitDown:event]; if(!down&&self.chordDown)[self emitUp:event]; self.chordDown=down; return;
    }
    NSInteger key=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
    if(type==kCGEventKeyDown&&key==self.keyCode&&flags==self.requiredFlags&&CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)==0)[self emitDown:event];
    if(type==kCGEventKeyUp&&key==self.keyCode&&self.acceptedDown)[self emitUp:event];
}
- (void)emitDown:(CGEventRef)event {
    if(self.acceptedDown)return; self.acceptedDown=YES; self.probeDown+=1; NSRunningApplication *app=NSWorkspace.sharedWorkspace.frontmostApplication;
    self.handler(@"hotkey_down",@{@"atMs":@((double)CGEventGetTimestamp(event)/1e6),@"token":NSUUID.UUID.UUIDString,@"pid":@(app.processIdentifier),@"bundleId":app.bundleIdentifier?:@"",@"appName":app.localizedName?:@"Application"});
}
- (void)emitUp:(CGEventRef)event {
    if(!self.acceptedDown)return; self.acceptedDown=NO; self.probeUp+=1; self.handler(@"hotkey_up",@{@"atMs":@((double)CGEventGetTimestamp(event)/1e6)});
}
- (void)invalidateActive:(NSString *)reason {
    if(!self.acceptedDown)return; self.acceptedDown=NO; self.chordDown=NO;
    self.handler(@"hotkey_cancel",@{@"atMs":@((uint64_t)llround(NSDate.date.timeIntervalSince1970*1000.0)),@"reason":reason});
}
- (void)sleep:(NSNotification *)note { (void)note; [self invalidateActive:@"sleep"]; self.chordDown=NO; }
- (void)wake:(NSNotification *)note { (void)note; if(self.tap)CGEventTapEnable(self.tap,true); }
- (NSDictionary<NSString *,id> *)runSyntheticProbe {
    NSUInteger down=self.probeDown,up=self.probeUp; NSError *error=nil; [self configureFromString:@"key=-1;command=1;shift=1;option=0;control=0;fn=0" error:&error];
    if(![self start:&error])return @{@"ok":@NO,@"message":error.localizedDescription?:@"Global monitor unavailable."};
    for(NSInteger tap=0;tap<2;tap++){CGEventRef d=CGEventCreateKeyboardEvent(NULL,56,true);CGEventSetFlags(d,kCGEventFlagMaskCommand|kCGEventFlagMaskShift);CGEventPost(kCGHIDEventTap,d);CFRelease(d);CGEventRef u=CGEventCreateKeyboardEvent(NULL,56,false);CGEventSetFlags(u,0);CGEventPost(kCGHIDEventTap,u);CFRelease(u);}
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1]; while(deadline.timeIntervalSinceNow>0&&(self.probeDown-down<2||self.probeUp-up<2))[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return @{@"ok":@(self.probeDown-down==2&&self.probeUp-up==2),@"downs":@(self.probeDown-down),@"ups":@(self.probeUp-up),@"modifierOnly":@YES,@"doubleTapInputs":@(self.probeDown-down==2)};
}
@end
