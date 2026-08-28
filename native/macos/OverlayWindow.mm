#import "OverlayWindow.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

@interface FridayPanel : NSPanel
@end
@implementation FridayPanel
- (BOOL)canBecomeKeyWindow {
  return YES;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

@interface FridayOverlayWindow ()
@property(nonatomic, copy) FridayOverlayHandler handler;
@property(nonatomic, strong) FridayPanel *panel;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSButton *stop;
@property(nonatomic, strong) NSButton *cancel;
@property(nonatomic, copy) NSString *lastAction;
@property(nonatomic, strong, nullable) NSValue *preferredScreenFrame;
@end

@implementation FridayOverlayWindow
- (instancetype)initWithHandler:(FridayOverlayHandler)handler {
  if ((self = [super init])) {
    _handler = [handler copy];
    [self build];
  }
  return self;
}
- (void)build {
  self.panel = [[FridayPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, 176, 44)
                styleMask:NSWindowStyleMaskBorderless |
                          NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.panel.level = NSFloatingWindowLevel;
  self.panel.opaque = NO;
  self.panel.backgroundColor = NSColor.clearColor;
  self.panel.hasShadow = YES;
  self.panel.hidesOnDeactivate = NO;
  self.panel.becomesKeyOnlyIfNeeded = YES;
  self.panel.movableByWindowBackground = YES;
  self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary;
  NSVisualEffectView *view =
      [[NSVisualEffectView alloc] initWithFrame:self.panel.contentView.bounds];
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.material =
      NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency
          ? NSVisualEffectMaterialWindowBackground
          : NSVisualEffectMaterialHUDWindow;
  view.state = NSVisualEffectStateActive;
  view.wantsLayer = YES;
  view.layer.cornerRadius = 14;
  view.layer.masksToBounds = YES;
  self.panel.contentView = view;
  self.label = [NSTextField labelWithString:@"Recording 0:00"];
  self.label.font =
      [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
  self.label.frame = NSMakeRect(12, 14, 91, 18);
  self.label.accessibilityLabel = @"Recording elapsed time";
  [view addSubview:self.label];
  self.stop = [NSButton buttonWithTitle:@"Stop"
                                 target:self
                                 action:@selector(stop:)];
  self.stop.bezelStyle = NSBezelStyleInline;
  self.stop.refusesFirstResponder = YES;
  self.stop.frame = NSMakeRect(104, 8, 45, 28);
  self.stop.accessibilityLabel = @"Stop recording";
  [view addSubview:self.stop];
  self.cancel = [NSButton buttonWithTitle:@"×"
                                   target:self
                                   action:@selector(cancel:)];
  self.cancel.bezelStyle = NSBezelStyleInline;
  self.cancel.refusesFirstResponder = YES;
  self.cancel.font = [NSFont systemFontOfSize:16];
  self.cancel.frame = NSMakeRect(148, 8, 24, 28);
  self.cancel.accessibilityLabel = @"Cancel dictation";
  [view addSubview:self.cancel];
}
- (void)setPreferredScreenFrame:(NSValue *)screenFrame {
  self.preferredScreenFrame = screenFrame;
}
- (void)position {
  if (self.panel.visible)
    return;
  NSRect v =
      self.preferredScreenFrame
          ? self.preferredScreenFrame.rectValue
          : (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
  NSRect f = self.panel.frame;
  f.origin = NSMakePoint(NSMidX(v) - NSWidth(f) / 2, NSMinY(v) + 36);
  [self.panel setFrame:f display:NO];
}
- (void)showLocked:(BOOL)locked elapsedMilliseconds:(uint64_t)elapsed {
  [self position];
  self.stop.hidden = !locked;
  self.label.stringValue =
      [NSString stringWithFormat:@"Recording %llu:%02llu", elapsed / 60000,
                                 (elapsed / 1000) % 60];
  [self.panel orderFrontRegardless];
}
- (void)showTranscribing {
  [self position];
  self.stop.hidden = YES;
  self.label.stringValue = @"Transcribing";
  [self.panel orderFrontRegardless];
}
- (void)hide {
  [self.panel orderOut:nil];
}
- (void)stop:(id)sender {
  (void)sender;
  self.lastAction = @"stop";
  self.handler(@"overlay_stop");
}
- (void)cancel:(id)sender {
  (void)sender;
  self.lastAction = @"cancel";
  self.handler(@"overlay_cancel");
}
- (NSDictionary<NSString *, id> *)runInteractionProbe {
  pid_t before =
      NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  self.lastAction = @"";
  [self showLocked:YES elapsedMilliseconds:1234];
  [self.panel displayIfNeeded];
  NSRect buttonRect = [self.stop convertRect:self.stop.bounds toView:nil];
  buttonRect = [self.panel convertRectToScreen:buttonRect];
  NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
  buttonRect.origin.y = NSMaxY(screen.frame) - NSMaxY(buttonRect);
  BOOL ok = before != 0 && !NSApp.active;
  return @{
    @"ok" : @(ok),
    @"sourcePid" : @(before),
    @"frontmostPid" :
        @(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),
    @"fridayActive" : @(NSApp.active),
    @"style" : @"nonactivatingPanel",
    @"buttonRect" : @{
      @"x" : @(buttonRect.origin.x),
      @"y" : @(buttonRect.origin.y),
      @"width" : @(buttonRect.size.width),
      @"height" : @(buttonRect.size.height)
    }
  };
}
@end
