#import "TextDelivery.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>

@implementation FridaySourceTarget
@end

@implementation FridayTextDelivery

- (FridaySourceTarget *)captureFrontmostSource {
  NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
  FridaySourceTarget *source = [FridaySourceTarget new];
  source.token = NSUUID.UUID.UUIDString;
  source.pid = app.processIdentifier;
  source.bundleID = app.bundleIdentifier ?: @"";
  source.appName = app.localizedName ?: @"Application";
  source.launchDate = app.launchDate ?: NSDate.date;
  source.capturedAt = NSDate.date;
  char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {};
  int pathLength = proc_pidpath(source.pid, pathBuffer, sizeof(pathBuffer));
  source.processPath =
      pathLength > 0 ? [NSString stringWithUTF8String:pathBuffer] : @"";
  AXUIElementRef appElement = AXUIElementCreateApplication(source.pid);
  CFTypeRef focused = NULL, window = NULL;
  AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute,
                                &focused);
  AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute, &window);
  CFRelease(appElement);
  source.capturedElement = CFBridgingRelease(focused);
  source.capturedWindow = CFBridgingRelease(window);
  NSPoint mouse = NSEvent.mouseLocation;
  for (NSScreen *screen in NSScreen.screens)
    if (NSPointInRect(mouse, screen.frame)) {
      source.sourceScreenFrame = [NSValue valueWithRect:screen.visibleFrame];
      break;
    }
  return source;
}

- (NSRunningApplication *)liveApplication:(FridaySourceTarget *)source {
  for (NSRunningApplication *app in NSWorkspace.sharedWorkspace
           .runningApplications) {
    if (app.processIdentifier != source.pid || app.terminated)
      continue;
    if (![app.bundleIdentifier ?: @"" isEqualToString:source.bundleID])
      return nil;
    if (fabs([app.launchDate timeIntervalSinceDate:source.launchDate]) > 0.001)
      return nil;
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {};
    int length = proc_pidpath(source.pid, pathBuffer, sizeof(pathBuffer));
    NSString *path =
        length > 0 ? [NSString stringWithUTF8String:pathBuffer] : @"";
    return [path isEqualToString:source.processPath] ? app : nil;
  }
  return nil;
}

- (BOOL)accessibilityInsert:(NSString *)text
                     source:(FridaySourceTarget *)source {
  if (!AXIsProcessTrusted() || !source.capturedElement)
    return NO;
  AXUIElementRef element = (__bridge AXUIElementRef)source.capturedElement;
  AXUIElementRef app = AXUIElementCreateApplication(source.pid);
  CFTypeRef currentWindow = NULL;
  AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &currentWindow);
  CFRelease(app);
  BOOL sameWindow =
      source.capturedWindow && currentWindow &&
      CFEqual((__bridge CFTypeRef)source.capturedWindow, currentWindow);
  if (currentWindow)
    CFRelease(currentWindow);
  if (!sameWindow)
    return NO;
  Boolean settable = false;
  AXError canSet = AXUIElementIsAttributeSettable(
      element, kAXSelectedTextAttribute, &settable);
  return canSet == kAXErrorSuccess && settable &&
         AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute,
                                      (__bridge CFStringRef)text) ==
             kAXErrorSuccess;
}

- (NSArray<NSDictionary<NSPasteboardType, NSData *> *> *)snapshot:
    (NSPasteboard *)pasteboard {
  NSMutableArray *snapshot = [NSMutableArray array];
  for (NSPasteboardItem *item in pasteboard.pasteboardItems ?: @[]) {
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    for (NSPasteboardType type in item.types) {
      NSData *value = [item dataForType:type];
      if (value)
        data[type] = value;
    }
    [snapshot addObject:data];
  }
  return snapshot;
}

- (void)restore:(NSArray<NSDictionary<NSPasteboardType, NSData *> *> *)snapshot
    changeCount:(NSInteger)changeCount {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
                   if (pasteboard.changeCount != changeCount)
                     return;
                   [pasteboard clearContents];
                   NSMutableArray *items = [NSMutableArray array];
                   for (NSDictionary *representations in snapshot) {
                     NSPasteboardItem *item = [NSPasteboardItem new];
                     for (NSPasteboardType type in representations)
                       [item setData:representations[type] forType:type];
                     [items addObject:item];
                   }
                   if (items.count)
                     [pasteboard writeObjects:items];
                 });
}

- (BOOL)copyText:(NSString *)text changeCount:(NSInteger *)changeCount {
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  NSArray *snapshot = [self snapshot:pasteboard];
  [pasteboard clearContents];
  BOOL ok = [pasteboard setString:text forType:NSPasteboardTypeString];
  if (!ok)
    [self restore:snapshot changeCount:pasteboard.changeCount];
  if (ok && changeCount)
    *changeCount = pasteboard.changeCount;
  return ok;
}

- (NSDictionary<NSString *, id> *)deliverText:(NSString *)text
                                     toSource:(FridaySourceTarget *)source {
  if (!text.length)
    return @{
      @"kind" : @"shown",
      @"ok" : @NO,
      @"message" : @"There is no final transcript to deliver."
    };
  if (source.consumed || -[source.capturedAt timeIntervalSinceNow] > 900)
    return @{
      @"kind" : @"shown",
      @"ok" : @NO,
      @"message" : @"The source token expired or was already consumed."
    };
  source.consumed = YES;
  NSRunningApplication *app = [self liveApplication:source];
  if (!app) {
    BOOL copied = [self copyText:text changeCount:NULL];
    return @{
      @"kind" : copied ? @"clipboard" : @"shown",
      @"ok" : @(copied),
      @"message" : copied
          ? @"The source app closed. The transcript was copied to the "
            @"clipboard."
          : @"The source app closed and the clipboard could not be updated."
    };
  }
  [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
  while (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
             source.pid &&
         deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
      source.pid) {
    BOOL copied = [self copyText:text changeCount:NULL];
    return @{
      @"kind" : copied ? @"clipboard" : @"shown",
      @"ok" : @(copied),
      @"message" : copied ? @"Friday could not focus the exact source app. The "
                            @"transcript was copied."
                          : @"Friday could not focus the exact source app or "
                            @"update the clipboard."
    };
  }
  if ([self accessibilityInsert:text source:source])
    return @{
      @"kind" : @"pasted",
      @"ok" : @YES,
      @"message" : @"Pasted into the exact source app with Accessibility."
    };

  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  NSArray *snapshot = [self snapshot:pasteboard];
  NSInteger transcriptChange = 0;
  if (![self copyText:text changeCount:&transcriptChange])
    return @{
      @"kind" : @"shown",
      @"ok" : @NO,
      @"message" : @"Friday could not update the clipboard."
    };
  if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
      source.pid)
    return @{
      @"kind" : @"clipboard",
      @"ok" : @YES,
      @"message" : @"Source focus changed before Paste. The transcript remains "
                   @"on the clipboard."
    };
  CGEventSourceRef events =
      CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  CGEventRef down = events ? CGEventCreateKeyboardEvent(events, 9, true) : NULL;
  CGEventRef up = events ? CGEventCreateKeyboardEvent(events, 9, false) : NULL;
  if (!events || !down || !up) {
    if (down)
      CFRelease(down);
    if (up)
      CFRelease(up);
    if (events)
      CFRelease(events);
    return @{
      @"kind" : @"clipboard",
      @"ok" : @YES,
      @"message" : @"Friday could not synthesize Paste. The transcript remains "
                   @"on the clipboard."
    };
  }
  CGEventSetFlags(down, kCGEventFlagMaskCommand);
  CGEventSetFlags(up, kCGEventFlagMaskCommand);
  CGEventPostToPid(source.pid, down);
  CGEventPostToPid(source.pid, up);
  CFRelease(down);
  CFRelease(up);
  CFRelease(events);
  NSDate *deliveryWait = [NSDate dateWithTimeIntervalSinceNow:0.2];
  while (deliveryWait.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  BOOL accepted =
      NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier ==
          source.pid &&
      [[self focusedValueForPID:source.pid] containsString:text];
  if (accepted) {
    [self restore:snapshot changeCount:transcriptChange];
    return @{
      @"kind" : @"pasted",
      @"ok" : @YES,
      @"message" : @"Pasted into the exact source app."
    };
  }
  return @{
    @"kind" : @"clipboard",
    @"ok" : @YES,
    @"message" : @"The exact source app did not confirm Paste. The transcript "
                 @"remains on the clipboard."
  };
}

- (NSString *)focusedValueForPID:(pid_t)pid {
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  CFTypeRef focused = NULL;
  CFTypeRef value = NULL;
  AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
  if (focused)
    AXUIElementCopyAttributeValue((AXUIElementRef)focused, kAXValueAttribute,
                                  &value);
  if (focused)
    CFRelease(focused);
  CFRelease(app);
  id bridged = CFBridgingRelease(value);
  if ([bridged isKindOfClass:NSString.class])
    return bridged;
  if ([bridged isKindOfClass:NSAttributedString.class])
    return [bridged string];
  return @"";
}

- (NSDictionary<NSString *, id> *)runProbeForApplication:
    (NSString *)applicationName {
  NSString *bundleID =
      [applicationName.lowercaseString isEqualToString:@"terminal"]
          ? @"com.apple.Terminal"
          : @"com.apple.TextEdit";
  NSURL *url = [NSWorkspace.sharedWorkspace
      URLForApplicationWithBundleIdentifier:bundleID];
  if (!url)
    return
        @{@"ok" : @NO, @"message" : @"The probe application is unavailable."};
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block NSRunningApplication *application = nil;
  NSWorkspaceOpenConfiguration *configuration =
      [NSWorkspaceOpenConfiguration configuration];
  configuration.activates = YES;
  [NSWorkspace.sharedWorkspace
      openApplicationAtURL:url
             configuration:configuration
         completionHandler:^(NSRunningApplication *app, NSError *error) {
           (void)error;
           application = app;
           dispatch_semaphore_signal(semaphore);
         }];
  while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0)
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  if (!application)
    return
        @{@"ok" : @NO, @"message" : @"The probe application could not open."};

  [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
  NSDate *activationDeadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
  while (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
             application.processIdentifier &&
         activationDeadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  FridaySourceTarget *target = [FridaySourceTarget new];
  target.token = NSUUID.UUID.UUIDString;
  target.pid = application.processIdentifier;
  target.bundleID = application.bundleIdentifier ?: bundleID;
  target.appName = application.localizedName ?: applicationName;
  target.launchDate = application.launchDate ?: NSDate.date;
  target.capturedAt = NSDate.date;
  char targetPath[PROC_PIDPATHINFO_MAXSIZE] = {};
  int targetPathLength =
      proc_pidpath(target.pid, targetPath, sizeof(targetPath));
  target.processPath =
      targetPathLength > 0 ? [NSString stringWithUTF8String:targetPath] : @"";
  AXUIElementRef targetApp = AXUIElementCreateApplication(target.pid);
  CFTypeRef targetElement = NULL, targetWindow = NULL;
  AXUIElementCopyAttributeValue(targetApp, kAXFocusedUIElementAttribute,
                                &targetElement);
  AXUIElementCopyAttributeValue(targetApp, kAXFocusedWindowAttribute,
                                &targetWindow);
  CFRelease(targetApp);
  target.capturedElement = CFBridgingRelease(targetElement);
  target.capturedWindow = CFBridgingRelease(targetWindow);
  BOOL sourceCaptureVerified =
      NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier ==
      target.pid;

  CGEventSourceRef source =
      CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  CGEventRef down = CGEventCreateKeyboardEvent(source, 45, true);
  CGEventRef up = CGEventCreateKeyboardEvent(source, 45, false);
  CGEventSetFlags(down, kCGEventFlagMaskCommand);
  CGEventSetFlags(up, kCGEventFlagMaskCommand);
  CGEventPostToPid(application.processIdentifier, down);
  CGEventPostToPid(application.processIdentifier, up);
  CFRelease(down);
  CFRelease(up);
  CFRelease(source);
  NSDate *documentWait = [NSDate dateWithTimeIntervalSinceNow:0.35];
  while (documentWait.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];

  pid_t displacedPID = 0;
  if ([applicationName.lowercaseString isEqualToString:@"textedit"]) {
    NSRunningApplication *terminal =
        [NSRunningApplication
            runningApplicationsWithBundleIdentifier:@"com.apple.Terminal"]
            .firstObject;
    if (terminal) {
      [terminal activateWithOptions:NSApplicationActivateIgnoringOtherApps];
      NSDate *otherDeadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
      while (
          NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
              terminal.processIdentifier &&
          otherDeadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop
               runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
      displacedPID =
          NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    }
  }

  NSString *probe = [NSString
      stringWithFormat:@"Friday exact-source probe %@", NSUUID.UUID.UUIDString];
  NSDictionary *delivery = [self deliverText:probe toSource:target];
  NSDate *pasteWait = [NSDate dateWithTimeIntervalSinceNow:0.25];
  while (pasteWait.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  BOOL pastedVerified =
      [[self focusedValueForPID:target.pid] containsString:probe];
  BOOL clipboardVerified = [[NSPasteboard.generalPasteboard
      stringForType:NSPasteboardTypeString] isEqualToString:probe];
  pid_t finalPID =
      NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  BOOL wrongAppExcluded = [delivery[@"kind"] isEqual:@"clipboard"] ||
                          (finalPID == target.pid && finalPID != displacedPID);
  BOOL ok = ([delivery[@"kind"] isEqual:@"pasted"] && pastedVerified &&
             wrongAppExcluded) ||
            ([delivery[@"kind"] isEqual:@"clipboard"] && clipboardVerified &&
             wrongAppExcluded);
  return @{
    @"ok" : @(ok),
    @"application" : applicationName,
    @"kind" : delivery[@"kind"],
    @"sourcePid" : @(target.pid),
    @"sourceCaptureVerified" : @(sourceCaptureVerified),
    @"displacedPid" : @(displacedPID),
    @"frontmostPid" : @(finalPID),
    @"pastedVerified" : @(pastedVerified),
    @"clipboardVerified" : @(clipboardVerified),
    @"wrongAppExcluded" : @(wrongAppExcluded),
    @"message" : delivery[@"message"]
  };
}

@end
