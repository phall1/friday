#import "OverlayWindow.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

@interface FridayPanel : NSPanel @end
@implementation FridayPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface FridayOverlayWindow ()
@property(nonatomic, copy) FridayOverlayHandler handler;
@property(nonatomic, strong) FridayPanel *panel;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSButton *stop;
@property(nonatomic, strong) NSButton *cancel;
@property(nonatomic, copy) NSString *lastAction;
@end

@implementation FridayOverlayWindow
- (instancetype)initWithHandler:(FridayOverlayHandler)handler {
    if ((self=[super init])) { _handler=[handler copy]; [self build]; }
    return self;
}
- (void)build {
    self.panel=[[FridayPanel alloc] initWithContentRect:NSMakeRect(0,0,176,44) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.panel.level=NSFloatingWindowLevel; self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=YES; self.panel.hidesOnDeactivate=NO; self.panel.becomesKeyOnlyIfNeeded=YES; self.panel.movableByWindowBackground=YES;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSVisualEffectView *view=[[NSVisualEffectView alloc] initWithFrame:self.panel.contentView.bounds]; view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; view.material=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency?NSVisualEffectMaterialWindowBackground:NSVisualEffectMaterialHUDWindow; view.state=NSVisualEffectStateActive; view.wantsLayer=YES; view.layer.cornerRadius=14; view.layer.masksToBounds=YES; self.panel.contentView=view;
    self.label=[NSTextField labelWithString:@"Recording 0:00"]; self.label.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold]; self.label.frame=NSMakeRect(12,14,91,18); self.label.accessibilityLabel=@"Recording elapsed time"; [view addSubview:self.label];
    self.stop=[NSButton buttonWithTitle:@"Stop" target:self action:@selector(stop:)]; self.stop.bezelStyle=NSBezelStyleInline; self.stop.frame=NSMakeRect(104,8,45,28); self.stop.accessibilityLabel=@"Stop recording"; [view addSubview:self.stop];
    self.cancel=[NSButton buttonWithTitle:@"×" target:self action:@selector(cancel:)]; self.cancel.bezelStyle=NSBezelStyleInline; self.cancel.font=[NSFont systemFontOfSize:16]; self.cancel.frame=NSMakeRect(148,8,24,28); self.cancel.accessibilityLabel=@"Cancel dictation"; [view addSubview:self.cancel];
}
- (void)position { if(self.panel.visible)return; NSScreen *screen=NSScreen.mainScreen?:NSScreen.screens.firstObject; NSRect f=self.panel.frame,v=screen.visibleFrame; f.origin=NSMakePoint(NSMidX(v)-NSWidth(f)/2,NSMinY(v)+36); [self.panel setFrame:f display:NO]; }
- (void)showLocked:(BOOL)locked elapsedMilliseconds:(uint64_t)elapsed { [self position]; self.stop.hidden=!locked; self.label.stringValue=[NSString stringWithFormat:@"Recording %llu:%02llu",elapsed/60000,(elapsed/1000)%60]; [self.panel orderFrontRegardless]; }
- (void)showTranscribing { [self position]; self.stop.hidden=YES; self.label.stringValue=@"Transcribing"; [self.panel orderFrontRegardless]; }
- (void)hide { [self.panel orderOut:nil]; }
- (void)stop:(id)sender { (void)sender; self.lastAction=@"stop"; self.handler(@"overlay_stop"); }
- (void)cancel:(id)sender { (void)sender; self.lastAction=@"cancel"; self.handler(@"overlay_cancel"); }
- (NSDictionary<NSString *,id> *)runInteractionProbe {
    NSRunningApplication *target=[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TextEdit"].firstObject ?: [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Terminal"].firstObject;
    if(!target) target=NSWorkspace.sharedWorkspace.frontmostApplication;
    [target activateWithOptions:NSApplicationActivateIgnoringOtherApps]; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:.5]; while(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=target.processIdentifier&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    pid_t before=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; self.lastAction=@""; [self showLocked:YES elapsedMilliseconds:1234]; [self.panel displayIfNeeded];
    NSRect buttonRect=[self.stop convertRect:self.stop.bounds toView:nil]; buttonRect=[self.panel convertRectToScreen:buttonRect];
    [self.stop performClick:nil];
    pid_t after=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; BOOL ok=before!=0&&before==after&&!NSApp.active&&[self.lastAction isEqualToString:@"stop"]; [self hide];
    return @{@"ok":@(ok),@"sourcePid":@(before),@"frontmostPid":@(after),@"fridayActive":@(NSApp.active),@"action":self.lastAction,@"style":@"nonactivatingPanel",@"buttonRect":@{@"x":@(buttonRect.origin.x),@"y":@(buttonRect.origin.y),@"width":@(buttonRect.size.width),@"height":@(buttonRect.size.height)}};
}
@end
