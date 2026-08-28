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
@property(nonatomic, copy, nullable) void (^captureCompletion)
    (NSDictionary<NSString *, id> *);
@end

@implementation FridayGlobalInputMonitor
- (instancetype)initWithHandler:(FridayInputEventHandler)handler {
  if ((self = [super init])) {
    _handler = [handler copy];
    _keyCode = -1;
    _requiredFlags = kCGEventFlagMaskCommand | kCGEventFlagMaskShift;
    NSNotificationCenter *center =
        NSWorkspace.sharedWorkspace.notificationCenter;
    [center addObserver:self
               selector:@selector(wake:)
                   name:NSWorkspaceDidWakeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sleep:)
                   name:NSWorkspaceWillSleepNotification
                 object:nil];
  }
  return self;
}
- (void)dealloc {
  [self stop];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
- (BOOL)inputMonitoringUsable {
  return CGPreflightListenEventAccess();
}
- (void)requestPermission {
  CGRequestListenEventAccess();
}
- (BOOL)isFunctionKeyCode:(NSInteger)key {
  switch (key) {
  case 122:
  case 120:
  case 99:
  case 118:
  case 96:
  case 97:
  case 98:
  case 100:
  case 101:
  case 109:
  case 103:
  case 111:
  case 105:
  case 107:
  case 113:
  case 106:
  case 64:
  case 79:
  case 80:
  case 90:
    return YES;
  default:
    return NO;
  }
}

- (NSString *)nameForKeyCode:(NSInteger)key fallback:(NSString *)fallback {
  NSDictionary<NSNumber *, NSString *> *names = @{
    @0 : @"A",
    @1 : @"S",
    @2 : @"D",
    @3 : @"F",
    @4 : @"H",
    @5 : @"G",
    @6 : @"Z",
    @7 : @"X",
    @8 : @"C",
    @9 : @"V",
    @11 : @"B",
    @12 : @"Q",
    @13 : @"W",
    @14 : @"E",
    @15 : @"R",
    @16 : @"Y",
    @17 : @"T",
    @31 : @"O",
    @32 : @"U",
    @34 : @"I",
    @35 : @"P",
    @37 : @"L",
    @38 : @"J",
    @40 : @"K",
    @45 : @"N",
    @46 : @"M",
    @48 : @"Tab",
    @49 : @"Space",
    @36 : @"Return",
    @53 : @"Escape",
    @123 : @"Left Arrow",
    @124 : @"Right Arrow",
    @125 : @"Down Arrow",
    @126 : @"Up Arrow",
    @122 : @"F1",
    @120 : @"F2",
    @99 : @"F3",
    @118 : @"F4",
    @96 : @"F5",
    @97 : @"F6",
    @98 : @"F7",
    @100 : @"F8",
    @101 : @"F9",
    @109 : @"F10",
    @103 : @"F11",
    @111 : @"F12",
    @105 : @"F13",
    @107 : @"F14",
    @113 : @"F15",
    @106 : @"F16",
    @64 : @"F17",
    @79 : @"F18",
    @80 : @"F19",
    @90 : @"F20"
  };
  NSString *known = names[@(key)];
  if (known.length)
    return known;
  if (fallback.length)
    return fallback.uppercaseString;
  return [NSString stringWithFormat:@"Key %ld", (long)key];
}

- (NSDictionary *)shortcutCandidateForKey:(NSInteger)key
                                    flags:(CGEventFlags)flags
                                 fallback:(NSString *)fallback {
  flags = [self relevant:flags];
  BOOL command = (flags & kCGEventFlagMaskCommand) != 0;
  BOOL shift = (flags & kCGEventFlagMaskShift) != 0;
  BOOL option = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL control = (flags & kCGEventFlagMaskControl) != 0;
  BOOL function = (flags & kCGEventFlagMaskSecondaryFn) != 0;
  NSUInteger modifierCount = (command ? 1 : 0) + (shift ? 1 : 0) +
                             (option ? 1 : 0) + (control ? 1 : 0) +
                             (function ? 1 : 0);
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  if (control)
    [parts addObject:@"Control"];
  if (option)
    [parts addObject:@"Option"];
  if (shift)
    [parts addObject:@"Shift"];
  if (command)
    [parts addObject:@"Command"];
  if (function)
    [parts addObject:@"Fn"];
  if (key >= 0)
    [parts addObject:[self nameForKeyCode:key fallback:fallback]];
  NSString *display = [parts componentsJoinedByString:@" + "];
  NSString *warning = @"";
  NSString *code = @"ok";
  BOOL reserved =
      command && (key == 49 || key == 48 || key == 12 || key == 13 ||
                  key == 4 || key == 46 || (option && key == 53));
  if (reserved) {
    code = @"system_reserved";
    warning =
        @"That shortcut is reserved by macOS or a standard app command. Choose "
         "another shortcut.";
  } else if (key == -1 && modifierCount < 2) {
    code = @"unreliable_modifier_only";
    warning = @"Use at least two modifiers so Friday can distinguish the "
              @"shortcut reliably.";
  } else if (key >= 0 && modifierCount == 0 && ![self isFunctionKeyCode:key]) {
    code = @"ordinary_typing";
    warning = @"A bare typing key would trigger while you type. Add a modifier "
              @"or choose a function key.";
  } else if (key < -1 || key > 127 || display.length == 0) {
    code = @"undistinguishable";
    warning = @"Friday could not distinguish that shortcut globally.";
  }
  NSString *configuration =
      [NSString stringWithFormat:
                    @"key=%ld;command=%d;shift=%d;option=%d;control=%d;fn=%d",
                    (long)key, command, shift, option, control, function];
  return @{
    @"ok" : @YES,
    @"valid" : @(warning.length == 0),
    @"code" : code,
    @"config" : configuration,
    @"display" : display,
    @"warning" : warning
  };
}

- (NSDictionary *)validateShortcutString:(NSString *)configuration {
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *part in [configuration componentsSeparatedByString:@";"]) {
    NSArray *pair = [part componentsSeparatedByString:@"="];
    if (pair.count == 2)
      values[pair[0]] = pair[1];
  }
  NSInteger key = [values[@"key"] integerValue];
  CGEventFlags flags = 0;
  if ([values[@"command"] boolValue])
    flags |= kCGEventFlagMaskCommand;
  if ([values[@"shift"] boolValue])
    flags |= kCGEventFlagMaskShift;
  if ([values[@"option"] boolValue])
    flags |= kCGEventFlagMaskAlternate;
  if ([values[@"control"] boolValue])
    flags |= kCGEventFlagMaskControl;
  if ([values[@"fn"] boolValue])
    flags |= kCGEventFlagMaskSecondaryFn;
  return [self shortcutCandidateForKey:key flags:flags fallback:@""];
}
- (BOOL)configureFromString:(NSString *)configuration error:(NSError **)error {
  NSDictionary *validation = [self validateShortcutString:configuration];
  if (![validation[@"valid"] boolValue]) {
    if (error)
      *error = [NSError
          errorWithDomain:@"com.phall.friday.input"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : validation[@"warning"]
                       ?: @"The shortcut is not globally distinguishable."
                 }];
    return NO;
  }
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *part in [configuration componentsSeparatedByString:@";"]) {
    NSArray *pair = [part componentsSeparatedByString:@"="];
    if (pair.count == 2)
      values[pair[0]] = pair[1];
  }
  NSInteger key = [values[@"key"] integerValue];
  CGEventFlags flags = 0;
  if ([values[@"command"] boolValue])
    flags |= kCGEventFlagMaskCommand;
  if ([values[@"shift"] boolValue])
    flags |= kCGEventFlagMaskShift;
  if ([values[@"option"] boolValue])
    flags |= kCGEventFlagMaskAlternate;
  if ([values[@"control"] boolValue])
    flags |= kCGEventFlagMaskControl;
  if ([values[@"fn"] boolValue])
    flags |= kCGEventFlagMaskSecondaryFn;
  if (key < -1 || key > 127 || (key == -1 && flags == 0)) {
    if (error)
      *error =
          [NSError errorWithDomain:@"com.phall.friday.input"
                              code:1
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"The shortcut is not globally distinguishable."
                          }];
    return NO;
  }
  [self invalidateActive:@"reconfigured"];
  self.keyCode = key;
  self.requiredFlags = flags;
  self.chordDown = NO;
  return YES;
}
static CGEventRef FridayTap(CGEventTapProxy proxy, CGEventType type,
                            CGEventRef event, void *context) {
  (void)proxy;
  FridayGlobalInputMonitor *monitor =
      (__bridge FridayGlobalInputMonitor *)context;
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    [monitor invalidateActive:@"tap_disabled"];
    if (monitor.tap)
      CGEventTapEnable(monitor.tap, true);
    return event;
  }
  [monitor handleType:type event:event];
  return event;
}
- (BOOL)start:(NSError **)error {
  if (self.running)
    return YES;
  if (!self.inputMonitoringUsable) {
    if (error)
      *error = [NSError errorWithDomain:@"com.phall.friday.input"
                                   code:2
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Input Monitoring permission is required "
                                     @"for the global shortcut."
                               }];
    return NO;
  }
  CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) |
                     CGEventMaskBit(kCGEventKeyDown) |
                     CGEventMaskBit(kCGEventKeyUp);
  self.tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                              kCGEventTapOptionListenOnly, mask, FridayTap,
                              (__bridge void *)self);
  if (!self.tap) {
    if (error)
      *error = [NSError
          errorWithDomain:@"com.phall.friday.input"
                     code:3
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"Friday could not create the global event monitor."
                 }];
    return NO;
  }
  self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.tap, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
  CGEventTapEnable(self.tap, true);
  self.running = YES;
  return YES;
}
- (void)stop {
  [self invalidateActive:@"stopped"];
  if (self.source) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), self.source,
                          kCFRunLoopCommonModes);
    CFRelease(self.source);
    self.source = NULL;
  }
  if (self.tap) {
    CFMachPortInvalidate(self.tap);
    CFRelease(self.tap);
    self.tap = NULL;
  }
  self.running = NO;
  self.chordDown = NO;
  self.captureCompletion = nil;
}
- (CGEventFlags)relevant:(CGEventFlags)flags {
  return flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskShift |
                  kCGEventFlagMaskAlternate | kCGEventFlagMaskControl |
                  kCGEventFlagMaskSecondaryFn);
}
- (void)handleType:(CGEventType)type event:(CGEventRef)event {
  CGEventFlags flags = [self relevant:CGEventGetFlags(event)];
  if (self.captureCompletion) {
    if (type == kCGEventKeyDown &&
        CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) == 0) {
      NSInteger key =
          CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
      UniChar characters[8] = {};
      UniCharCount count = 0;
      CGEventKeyboardGetUnicodeString(event, 8, &count, characters);
      NSString *fallback = count > 0 ? [NSString stringWithCharacters:characters
                                                               length:count]
                                     : @"";
      NSDictionary *candidate = [self shortcutCandidateForKey:key
                                                        flags:flags
                                                     fallback:fallback];
      void (^completion)(NSDictionary *) = self.captureCompletion;
      self.captureCompletion = nil;
      completion(candidate);
    }
    return;
  }
  if (self.keyCode == -1) {
    if (type != kCGEventFlagsChanged)
      return;
    BOOL down = flags == self.requiredFlags;
    if (down && !self.chordDown)
      [self emitDown:event];
    if (!down && self.chordDown)
      [self emitUp:event];
    self.chordDown = down;
    return;
  }
  NSInteger key = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
  if (type == kCGEventKeyDown && key == self.keyCode &&
      flags == self.requiredFlags &&
      CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) == 0)
    [self emitDown:event];
  if (type == kCGEventKeyUp && key == self.keyCode && self.acceptedDown)
    [self emitUp:event];
}
- (void)emitDown:(CGEventRef)event {
  if (self.acceptedDown)
    return;
  self.acceptedDown = YES;
  self.probeDown += 1;
  NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
  self.handler(@"hotkey_down", @{
    @"atMs" : @((double)CGEventGetTimestamp(event) / 1e6),
    @"token" : NSUUID.UUID.UUIDString,
    @"pid" : @(app.processIdentifier),
    @"bundleId" : app.bundleIdentifier ?: @"",
    @"appName" : app.localizedName ?: @"Application"
  });
}
- (void)emitUp:(CGEventRef)event {
  if (!self.acceptedDown)
    return;
  self.acceptedDown = NO;
  self.probeUp += 1;
  self.handler(@"hotkey_up",
               @{@"atMs" : @((double)CGEventGetTimestamp(event) / 1e6)});
}
- (void)invalidateActive:(NSString *)reason {
  if (!self.acceptedDown)
    return;
  self.acceptedDown = NO;
  self.chordDown = NO;
  self.handler(@"hotkey_cancel", @{
    @"atMs" : @((uint64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0)),
    @"reason" : reason
  });
}
- (void)sleep:(NSNotification *)note {
  (void)note;
  [self invalidateActive:@"sleep"];
  self.chordDown = NO;
}
- (void)wake:(NSNotification *)note {
  (void)note;
  if (self.tap)
    CGEventTapEnable(self.tap, true);
}
- (void)beginShortcutCapture:(void (^)(NSDictionary *))completion {
  if (self.captureCompletion) {
    completion(@{
      @"ok" : @NO,
      @"code" : @"capture_active",
      @"message" : @"Shortcut recording is already active."
    });
    return;
  }
  NSError *error = nil;
  if (![self start:&error]) {
    completion(@{
      @"ok" : @NO,
      @"code" : @"monitor_unavailable",
      @"message" : error.localizedDescription
          ?: @"Friday could not start shortcut recording."
    });
    return;
  }
  self.captureCompletion = [completion copy];
}

- (void)cancelShortcutCapture {
  self.captureCompletion = nil;
}

+ (NSDictionary *)runShortcutContractProbes {
  __block NSUInteger events = 0;
  FridayGlobalInputMonitor *monitor = [[FridayGlobalInputMonitor alloc]
      initWithHandler:^(NSString *event, NSDictionary *payload) {
        (void)event;
        (void)payload;
        events += 1;
      }];
  NSDictionary *modifier =
      [monitor validateShortcutString:
                   @"key=-1;command=1;shift=1;option=0;control=0;fn=0"];
  NSDictionary *keyBased =
      [monitor validateShortcutString:
                   @"key=0;command=1;shift=1;option=0;control=0;fn=0"];
  NSDictionary *functionKey =
      [monitor validateShortcutString:
                   @"key=96;command=0;shift=0;option=0;control=0;fn=0"];
  NSDictionary *reserved =
      [monitor validateShortcutString:
                   @"key=49;command=1;shift=0;option=0;control=0;fn=0"];
  NSDictionary *bare =
      [monitor validateShortcutString:
                   @"key=0;command=0;shift=0;option=0;control=0;fn=0"];
  NSError *error = nil;
  [monitor
      configureFromString:@"key=0;command=1;shift=1;option=0;control=0;fn=0"
                    error:&error];
  CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
  CGEventSetFlags(keyDown, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
  CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, 0, false);
  CGEventSetFlags(keyUp, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
  [monitor handleType:kCGEventKeyDown event:keyDown];
  [monitor handleType:kCGEventKeyUp event:keyUp];
  CFRelease(keyDown);
  CFRelease(keyUp);
  BOOL keyEvents = events == 2;
  events = 0;
  [monitor
      configureFromString:@"key=96;command=0;shift=0;option=0;control=0;fn=0"
                    error:&error];
  CGEventRef functionDown = CGEventCreateKeyboardEvent(NULL, 96, true);
  CGEventRef functionUp = CGEventCreateKeyboardEvent(NULL, 96, false);
  [monitor handleType:kCGEventKeyDown event:functionDown];
  [monitor handleType:kCGEventKeyUp event:functionUp];
  CFRelease(functionDown);
  CFRelease(functionUp);
  BOOL functionEvents = events == 2;
  return @{
    @"ok" : @(
        [modifier[@"valid"] boolValue] && [keyBased[@"valid"] boolValue] &&
        [functionKey[@"valid"] boolValue] && ![reserved[@"valid"] boolValue] &&
        ![bare[@"valid"] boolValue] && keyEvents && functionEvents),
    @"modifierSafe" : modifier[@"valid"],
    @"keyBasedSafe" : keyBased[@"valid"],
    @"functionKeySafe" : functionKey[@"valid"],
    @"reservedRejected" : @(![reserved[@"valid"] boolValue]),
    @"bareTypingRejected" : @(![bare[@"valid"] boolValue]),
    @"keyDownUp" : @(keyEvents),
    @"functionDownUp" : @(functionEvents)
  };
}

- (NSDictionary<NSString *, id> *)runSyntheticProbe {
  NSUInteger down = self.probeDown, up = self.probeUp;
  NSError *error = nil;
  [self configureFromString:@"key=-1;command=1;shift=1;option=0;control=0;fn=0"
                      error:&error];
  if (![self start:&error])
    return @{
      @"ok" : @NO,
      @"message" : error.localizedDescription ?: @"Global monitor unavailable."
    };
  for (NSInteger tap = 0; tap < 2; tap++) {
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, 56, true);
    CGEventSetFlags(d, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
    [self handleType:kCGEventFlagsChanged event:d];
    CFRelease(d);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, 56, false);
    CGEventSetFlags(u, 0);
    [self handleType:kCGEventFlagsChanged event:u];
    CFRelease(u);
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
  while (deadline.timeIntervalSinceNow > 0 &&
         (self.probeDown - down < 2 || self.probeUp - up < 2))
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  return @{
    @"ok" : @(self.probeDown - down == 2 && self.probeUp - up == 2),
    @"downs" : @(self.probeDown - down),
    @"ups" : @(self.probeUp - up),
    @"modifierOnly" : @YES,
    @"doubleTapInputs" : @(self.probeDown - down == 2)
  };
}
@end
