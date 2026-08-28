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
@property(nonatomic, strong) NSView *statusDot;
@property(nonatomic, strong) NSArray<NSView *> *bars;
@property(nonatomic, strong) NSButton *stop;
@property(nonatomic, strong) NSButton *dismiss;
@property(nonatomic, strong) NSButton *cancel;
@property(nonatomic, strong) NSTimer *elapsedTimer;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) uint64_t elapsedSeed;
@property(nonatomic, strong) NSDate *shownAt;
@property(nonatomic, copy) NSString *lastAction;
@property(nonatomic, strong, nullable) NSValue *preferredScreenFrame;
@property(nonatomic) BOOL restoredPosition;
@end

@implementation FridayOverlayWindow
- (instancetype)initWithHandler:(FridayOverlayHandler)handler {
  if ((self = [super init])) {
    _handler = [handler copy];
    _mode = @"held";
    [self build];
  }
  return self;
}

- (void)dealloc {
  [self.elapsedTimer invalidate];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)build {
  self.panel = [[FridayPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, 264, 52)
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
  self.panel.accessibilityLabel = @"Friday dictation controls";
  self.restoredPosition = [self.panel setFrameUsingName:@"FridayOverlayPosition"
                                                  force:NO];
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(panelMoved:)
                                             name:NSWindowDidMoveNotification
                                           object:self.panel];
  [NSNotificationCenter.defaultCenter
      addObserver:self
         selector:@selector(accessibilityDisplayChanged:)
             name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
           object:nil];

  NSVisualEffectView *view =
      [[NSVisualEffectView alloc] initWithFrame:self.panel.contentView.bounds];
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.state = NSVisualEffectStateActive;
  view.wantsLayer = YES;
  view.layer.cornerRadius = 16;
  view.layer.masksToBounds = YES;
  self.panel.contentView = view;

  self.statusDot = [[NSView alloc] initWithFrame:NSMakeRect(12, 21, 10, 10)];
  self.statusDot.wantsLayer = YES;
  self.statusDot.layer.cornerRadius = 5;
  [view addSubview:self.statusDot];

  NSMutableArray<NSView *> *bars = [NSMutableArray array];
  const CGFloat heights[] = {6, 12, 18, 10, 7};
  for (NSUInteger index = 0; index < 5; ++index) {
    NSView *bar = [[NSView alloc]
        initWithFrame:NSMakeRect(31 + index * 6, 26 - heights[index] / 2, 3,
                                 heights[index])];
    bar.wantsLayer = YES;
    bar.layer.cornerRadius = 1.5;
    [view addSubview:bar];
    [bars addObject:bar];
  }
  self.bars = bars;

  self.label = [NSTextField labelWithString:@"Listening 0:00"];
  self.label.font =
      [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
  self.label.frame = NSMakeRect(67, 17, 96, 18);
  self.label.lineBreakMode = NSLineBreakByTruncatingTail;
  self.label.accessibilityLabel = @"Recording elapsed time";
  [view addSubview:self.label];

  self.stop = [NSButton buttonWithTitle:@"Stop"
                                 target:self
                                 action:@selector(stop:)];
  self.stop.bezelStyle = NSBezelStyleInline;
  self.stop.refusesFirstResponder = YES;
  self.stop.frame = NSMakeRect(158, 12, 48, 28);
  self.stop.accessibilityLabel = @"Stop recording";
  [view addSubview:self.stop];

  self.dismiss = [NSButton buttonWithTitle:@"–"
                                    target:self
                                    action:@selector(dismiss:)];
  self.dismiss.bezelStyle = NSBezelStyleInline;
  self.dismiss.refusesFirstResponder = YES;
  self.dismiss.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
  self.dismiss.frame = NSMakeRect(206, 12, 26, 28);
  self.dismiss.accessibilityLabel = @"Hide recording capsule";
  [view addSubview:self.dismiss];

  self.cancel = [NSButton buttonWithTitle:@"×"
                                   target:self
                                   action:@selector(cancel:)];
  self.cancel.bezelStyle = NSBezelStyleInline;
  self.cancel.refusesFirstResponder = YES;
  self.cancel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
  self.cancel.frame = NSMakeRect(234, 12, 26, 28);
  self.cancel.accessibilityLabel = @"Cancel dictation";
  [view addSubview:self.cancel];
  [self updateVisualStyle];
  [self applyMeterLevel:0];
}

- (void)accessibilityDisplayChanged:(NSNotification *)note {
  (void)note;
  [self updateVisualStyle];
}

- (void)updateVisualStyle {
  NSVisualEffectView *view = (NSVisualEffectView *)self.panel.contentView;
  view.material =
      NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency
          ? NSVisualEffectMaterialWindowBackground
          : NSVisualEffectMaterialHUDWindow;
  BOOL contrast =
      NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
  view.layer.borderWidth = contrast ? 1.5 : .5;
  view.layer.borderColor =
      [NSColor.separatorColor colorWithAlphaComponent:contrast ? 1 : .55]
          .CGColor;
  NSColor *coral = [NSColor colorWithSRGBRed:.91 green:.35 blue:.31 alpha:1];
  self.statusDot.layer.backgroundColor = coral.CGColor;
  for (NSView *bar in self.bars)
    bar.layer.backgroundColor = coral.CGColor;
}

- (void)setPreferredScreenFrame:(NSValue *)screenFrame {
  self.preferredScreenFrame = screenFrame;
}

- (void)panelMoved:(NSNotification *)note {
  (void)note;
  if (self.panel.visible) {
    [self.panel saveFrameUsingName:@"FridayOverlayPosition"];
    self.restoredPosition = YES;
  }
}

- (void)position {
  if (self.panel.visible || self.restoredPosition)
    return;
  NSRect visible =
      self.preferredScreenFrame
          ? self.preferredScreenFrame.rectValue
          : (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
  NSRect frame = self.panel.frame;
  frame.origin =
      NSMakePoint(NSMidX(visible) - NSWidth(frame) / 2, NSMinY(visible) + 36);
  [self.panel setFrame:frame display:NO];
}

- (void)showLocked:(BOOL)locked elapsedMilliseconds:(uint64_t)elapsed {
  [self position];
  self.mode = locked ? @"locked" : @"held";
  self.stop.hidden = !locked;
  self.cancel.hidden = NO;
  self.dismiss.hidden = NO;
  self.elapsedSeed = elapsed;
  self.shownAt = [NSDate date];
  [self updateElapsed:elapsed];
  [self.elapsedTimer invalidate];
  self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:.25
                                                       target:self
                                                     selector:@selector(tick:)
                                                     userInfo:nil
                                                      repeats:YES];
  [self.panel orderFrontRegardless];
}

- (void)tick:(NSTimer *)timer {
  (void)timer;
  uint64_t elapsed =
      self.elapsedSeed +
      (uint64_t)llround(-self.shownAt.timeIntervalSinceNow * 1000);
  [self updateElapsed:elapsed];
}

- (void)updateElapsed:(uint64_t)elapsed {
  NSString *prefix = [self.mode isEqual:@"locked"] ? @"Locked" : @"Listening";
  self.label.stringValue =
      [NSString stringWithFormat:@"%@ %llu:%02llu", prefix, elapsed / 60000,
                                 (elapsed / 1000) % 60];
  self.label.accessibilityValue = self.label.stringValue;
}

- (void)applyMeterLevel:(NSUInteger)level {
  const CGFloat quiet[] = {4, 7, 9, 7, 4};
  const CGFloat low[] = {5, 10, 15, 10, 6};
  const CGFloat medium[] = {7, 15, 23, 16, 9};
  const CGFloat high[] = {10, 22, 30, 25, 13};
  const CGFloat *heights = level >= 3   ? high
                           : level == 2 ? medium
                           : level == 1 ? low
                                        : quiet;
  for (NSUInteger index = 0; index < self.bars.count; ++index) {
    NSView *bar = self.bars[index];
    NSRect frame = bar.frame;
    frame.size.height = heights[index];
    frame.origin.y = 26 - heights[index] / 2;
    bar.frame = frame;
  }
}

- (void)updateMeterLevel:(NSUInteger)level
     elapsedMilliseconds:(uint64_t)elapsed {
  if (![self.mode isEqual:@"transcribing"]) {
    [self applyMeterLevel:level];
    [self updateElapsed:elapsed];
  }
}

- (void)showTranscribing {
  [self position];
  [self.elapsedTimer invalidate];
  self.elapsedTimer = nil;
  self.mode = @"transcribing";
  self.stop.hidden = YES;
  self.cancel.hidden = NO;
  self.dismiss.hidden = NO;
  self.label.stringValue = @"Transcribing";
  self.label.accessibilityValue = @"Transcribing locally";
  [self applyMeterLevel:1];
  [self.panel orderFrontRegardless];
}

- (void)hide {
  [self.elapsedTimer invalidate];
  self.elapsedTimer = nil;
  [self.panel orderOut:nil];
}

- (void)stop:(id)sender {
  (void)sender;
  self.lastAction = @"stop";
  self.handler(@"overlay_stop");
}

- (void)dismiss:(id)sender {
  (void)sender;
  self.lastAction = @"dismiss";
  [self hide];
  self.handler(@"overlay_dismiss");
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
  NSString *lockedLabel = self.label.stringValue;
  [self updateMeterLevel:3 elapsedMilliseconds:4321];
  NSString *meterLabel = self.label.stringValue;
  [self showTranscribing];
  NSString *transcribingLabel = self.label.stringValue;
  BOOL controlsCorrect =
      self.stop.hidden && !self.cancel.hidden && !self.dismiss.hidden;
  BOOL reducedMotionContract = self.elapsedTimer == nil;
  NSVisualEffectView *view = (NSVisualEffectView *)self.panel.contentView;
  BOOL reduceTransparency =
      NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
  BOOL increaseContrast =
      NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
  BOOL appearanceContract =
      view.material == (reduceTransparency
                            ? NSVisualEffectMaterialWindowBackground
                            : NSVisualEffectMaterialHUDWindow) &&
      view.layer.borderWidth == (increaseContrast ? 1.5 : .5);
  [self dismiss:nil];
  BOOL dismissContract =
      !self.panel.visible && [self.lastAction isEqual:@"dismiss"];
  return @{
    @"ok" : @(ok),
    @"sourcePid" : @(before),
    @"frontmostPid" :
        @(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),
    @"fridayActive" : @(NSApp.active),
    @"style" : @"nonactivatingPanel",
    @"positionAutosave" : @"FridayOverlayPosition",
    @"statesComplete" :
        @([lockedLabel hasPrefix:@"Locked"] &&
          [meterLabel isEqual:@"Locked 0:04"] &&
          [transcribingLabel isEqual:@"Transcribing"] && controlsCorrect),
    @"dismissContract" : @(dismissContract),
    @"appearanceContract" : @(appearanceContract),
    @"reducedMotionContract" : @(reducedMotionContract),
    @"buttonRect" : @{
      @"x" : @(buttonRect.origin.x),
      @"y" : @(buttonRect.origin.y),
      @"width" : @(buttonRect.size.width),
      @"height" : @(buttonRect.size.height)
    }
  };
}
@end
