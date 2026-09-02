const std = @import("std");
const native_sdk = @import("native_sdk");
const objc = @import("objc.zig");
/// Narrow C ABI declarations. Xcode 26 umbrella headers expose block types
/// that Zig 0.16 translate-c cannot parse.
const c = struct {
    const OpaqueCFType = opaque {};
    pub const CFTypeRef = ?*const OpaqueCFType;
    pub const CFStringRef = ?*const OpaqueCFType;
    pub const CFRunLoopMode = CFStringRef;
    pub const AXUIElementRef = ?*OpaqueCFType;
    pub const CGEventRef = ?*OpaqueCFType;
    pub const CGEventSourceRef = ?*OpaqueCFType;
    pub const Boolean = u8;
    pub const CFTypeID = usize;
    pub const AXError = i32;
    pub const CGPoint = extern struct { x: f64, y: f64 };
    pub const CGSize = extern struct { width: f64, height: f64 };
    pub const CGRect = extern struct { origin: CGPoint, size: CGSize };
    pub const DispatchQueue = ?*anyopaque;
    pub const DispatchFunction = *const fn (?*anyopaque) callconv(.c) void;

    pub const kAXErrorSuccess: AXError = 0;
    pub const kCGEventSourceStateHIDSystemState: i32 = 1;
    pub const DISPATCH_TIME_NOW: u64 = 0;
    pub const NSEC_PER_MSEC: i64 = 1_000_000;
    pub const PROC_PIDPATHINFO_MAXSIZE: usize = 4096;

    pub extern "c" var kCFRunLoopDefaultMode: CFRunLoopMode;

    pub extern "c" fn CFRelease(value: CFTypeRef) void;
    pub extern "c" fn CFEqual(left: CFTypeRef, right: CFTypeRef) bool;
    pub extern "c" fn CFGetTypeID(value: CFTypeRef) CFTypeID;
    pub extern "c" fn CFStringGetTypeID() CFTypeID;
    pub extern "c" fn CFRunLoopRunInMode(mode: CFRunLoopMode, seconds: f64, return_after_source_handled: bool) i32;

    pub extern "c" fn AXIsProcessTrusted() bool;
    pub extern "c" fn AXIsProcessTrustedWithOptions(options: CFTypeRef) bool;
    pub extern "c" fn AXUIElementCreateApplication(pid: i32) AXUIElementRef;
    pub extern "c" fn AXUIElementCopyAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: *CFTypeRef) AXError;
    pub extern "c" fn AXUIElementIsAttributeSettable(element: AXUIElementRef, attribute: CFStringRef, settable: *Boolean) AXError;
    pub extern "c" fn AXUIElementSetAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: CFTypeRef) AXError;

    pub extern "c" fn CGEventSourceCreate(state: i32) CGEventSourceRef;
    pub extern "c" fn CGEventCreateKeyboardEvent(source: CGEventSourceRef, key: u16, key_down: bool) CGEventRef;
    pub extern "c" fn CGEventSetFlags(event: CGEventRef, flags: u64) void;
    pub extern "c" fn CGEventPostToPid(pid: i32, event: CGEventRef) void;

    pub extern "c" var _dispatch_main_q: u8;
    pub fn dispatch_get_main_queue() DispatchQueue {
        return @ptrCast(&_dispatch_main_q);
    }
    pub extern "c" fn dispatch_time(when: u64, delta: i64) u64;
    pub extern "c" fn dispatch_after_f(when: u64, queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void;

    pub extern "c" fn proc_pidpath(pid: i32, buffer: *anyopaque, buffer_size: u32) i32;
};

extern "c" var NSPasteboardTypeString: objc.Id;
extern "c" fn arc4random_buf(buffer: *anyopaque, length: usize) void;

fn cfString(comptime value: [:0]const u8) c.CFStringRef {
    const object = objc.send1(objc.Id, [*:0]const u8, objc.class("NSString"), objc.selector("stringWithUTF8String:"), value.ptr);
    return @ptrCast(object);
}

const PlatformServices = native_sdk.platform.PlatformServices;
const Error = error{ NoFrontmostApplication, OutOfMemory, ResultBufferTooSmall };

pub const SourceTarget = struct {
    token: [36]u8,
    pid: i32,
    bundle_id: []u8,
    app_name: []u8,
    generation: u64 = 0,
    launch_time: f64,
    process_path: []u8,
    captured_at_ms: i64,
    consumed: bool = false,
    captured_element: c.AXUIElementRef = null,
    captured_window: c.AXUIElementRef = null,
    source_screen_frame: ?c.CGRect = null,

    /// Frees all owned byte slices and releases both retained AX references.
    /// SourceTarget is move-only: do not bit-copy it after capture.
    pub fn deinit(self: *SourceTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.bundle_id);
        allocator.free(self.app_name);
        allocator.free(self.process_path);
        if (self.captured_element != null) c.CFRelease(self.captured_element);
        if (self.captured_window != null) c.CFRelease(self.captured_window);
        self.* = undefined;
    }
};

pub fn accessibilityTrusted() bool {
    return c.AXIsProcessTrusted();
}

pub fn requestAccessibilityPermission() void {
    const yes = objc.send1(objc.Id, bool, objc.class("NSNumber"), objc.selector("numberWithBool:"), true);
    const options = objc.send2(objc.Id, objc.Id, objc.Id, objc.class("NSDictionary"), objc.selector("dictionaryWithObject:forKey:"), yes, @ptrCast(@constCast(cfString("AXTrustedCheckOptionPrompt"))));
    _ = c.AXIsProcessTrustedWithOptions(@ptrCast(options));
}

pub const TextDelivery = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TextDelivery {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *TextDelivery) void {}

    pub fn captureFrontmostSource(self: *TextDelivery) !SourceTarget {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const workspace = sharedWorkspace();
        const app = objc.send0(objc.Id, workspace, objc.selector("frontmostApplication"));
        if (app == null) return error.NoFrontmostApplication;
        const pid = objc.send0(i32, app, objc.selector("processIdentifier"));
        const bundle = try copyStringOr(self.allocator, objc.send0(objc.Id, app, objc.selector("bundleIdentifier")), "");
        errdefer self.allocator.free(bundle);
        const name = try copyStringOr(self.allocator, objc.send0(objc.Id, app, objc.selector("localizedName")), "Application");
        errdefer self.allocator.free(name);
        const path = try processPath(self.allocator, pid);
        errdefer self.allocator.free(path);
        const launch_date = objc.send0(objc.Id, app, objc.selector("launchDate"));
        const launch_time = if (launch_date != null) objc.send0(f64, launch_date, objc.selector("timeIntervalSince1970")) else wallSeconds();
        const app_element = c.AXUIElementCreateApplication(pid);
        var focused: c.CFTypeRef = null;
        var window: c.CFTypeRef = null;
        if (app_element != null) {
            _ = c.AXUIElementCopyAttributeValue(app_element, cfString("AXFocusedUIElement"), &focused);
            _ = c.AXUIElementCopyAttributeValue(app_element, cfString("AXFocusedWindow"), &window);
            c.CFRelease(app_element);
        }
        var token: [36]u8 = undefined;
        makeUuid(&token);
        return .{
            .token = token,
            .pid = pid,
            .bundle_id = bundle,
            .app_name = name,
            .launch_time = launch_time,
            .process_path = path,
            .captured_at_ms = wallMilliseconds(),
            .captured_element = @ptrCast(@constCast(focused)),
            .captured_window = @ptrCast(@constCast(window)),
            .source_screen_frame = screenUnderMouse(),
        };
    }

    pub fn deliverText(self: *TextDelivery, text: []const u8, source: *SourceTarget, paste_automatically: bool, services: ?PlatformServices, output: []u8) Error!usize {
        _ = services;
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        if (text.len == 0) return writeDelivery(output, "shown", false, "There is no final transcript to deliver.");
        if (source.consumed or wallMilliseconds() > source.captured_at_ms + 900_000) return writeDelivery(output, "shown", false, "The source token expired or was already consumed.");
        source.consumed = true;
        const ns_text = objc.nsString(text);
        defer objc.release(ns_text);
        if (!paste_automatically) {
            const copied = copyText(self.allocator, ns_text, null);
            return writeDelivery(output, if (copied) "clipboard" else "shown", copied, if (copied) "Paste is disabled. The transcript was copied to the clipboard." else "Paste is disabled and the clipboard could not be updated.");
        }
        const app = liveApplication(source);
        if (app == null) {
            const copied = copyText(self.allocator, ns_text, null);
            return writeDelivery(output, if (copied) "clipboard" else "shown", copied, if (copied) "The source app closed. The transcript was copied to the clipboard." else "The source app closed and the clipboard could not be updated.");
        }
        _ = objc.send1(bool, usize, app, objc.selector("activateWithOptions:"), 1 << 1);
        waitForFrontmost(source.pid, 0.5);
        if (frontmostPid() != source.pid) {
            const copied = copyText(self.allocator, ns_text, null);
            return writeDelivery(output, if (copied) "clipboard" else "shown", copied, if (copied) "Friday could not focus the exact source app. The transcript was copied." else "Friday could not focus the exact source app or update the clipboard.");
        }
        if (accessibilityInsert(ns_text, source)) return writeDelivery(output, "pasted", true, "Pasted into the exact source app with Accessibility.");

        const pasteboard = generalPasteboard();
        const snapshot = snapshotPasteboard(pasteboard);
        var transcript_change: isize = 0;
        if (!copyText(self.allocator, ns_text, &transcript_change)) {
            objc.release(snapshot);
            return writeDelivery(output, "shown", false, "Friday could not update the clipboard.");
        }
        if (frontmostPid() != source.pid) {
            objc.release(snapshot);
            return writeDelivery(output, "clipboard", true, "Source focus changed before Paste. The transcript remains on the clipboard.");
        }
        const event_source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
        const down = if (event_source != null) c.CGEventCreateKeyboardEvent(event_source, 9, true) else null;
        const up = if (event_source != null) c.CGEventCreateKeyboardEvent(event_source, 9, false) else null;
        if (event_source == null or down == null or up == null) {
            if (down != null) c.CFRelease(down);
            if (up != null) c.CFRelease(up);
            if (event_source != null) c.CFRelease(event_source);
            objc.release(snapshot);
            return writeDelivery(output, "clipboard", true, "Friday could not synthesize Paste. The transcript remains on the clipboard.");
        }
        c.CGEventSetFlags(down, 1 << 20);
        c.CGEventSetFlags(up, 1 << 20);
        c.CGEventPostToPid(source.pid, down);
        c.CGEventPostToPid(source.pid, up);
        c.CFRelease(down);
        c.CFRelease(up);
        c.CFRelease(event_source);
        runLoopFor(0.2);
        const accepted = frontmostPid() == source.pid and focusedValueContains(source.pid, text);
        if (accepted) {
            scheduleRestore(self.allocator, snapshot, transcript_change);
            return writeDelivery(output, "pasted", true, "Pasted into the exact source app.");
        }
        objc.release(snapshot);
        return writeDelivery(output, "clipboard", true, "The exact source app did not confirm Paste. The transcript remains on the clipboard.");
    }

    pub fn writeProbe(self: *TextDelivery, application_name: []const u8, services: ?PlatformServices, output: []u8) Error!usize {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const terminal_probe = std.ascii.eqlIgnoreCase(application_name, "terminal");
        const bundle_id = if (terminal_probe) "com.apple.Terminal" else "com.apple.TextEdit";
        const app = findOrLaunchApplication(bundle_id, if (terminal_probe) "Terminal" else "TextEdit") orelse return writeSimpleFailure(output, "The probe application is unavailable.");
        _ = objc.send1(bool, usize, app, objc.selector("activateWithOptions:"), 1 << 1);
        const pid = objc.send0(i32, app, objc.selector("processIdentifier"));
        waitForFrontmost(pid, 0.75);
        var target = self.captureFrontmostSource() catch return writeSimpleFailure(output, "The probe application could not open.");
        defer target.deinit(self.allocator);
        const source_capture_verified = frontmostPid() == target.pid and target.pid == pid;
        postCommandKey(pid, 45);
        runLoopFor(0.35);
        var displaced_pid: i32 = 0;
        if (!terminal_probe) {
            if (findRunningApplication("com.apple.Terminal")) |terminal| {
                _ = objc.send1(bool, usize, terminal, objc.selector("activateWithOptions:"), 1 << 1);
                waitForFrontmost(objc.send0(i32, terminal, objc.selector("processIdentifier")), 0.5);
                displaced_pid = frontmostPid();
            }
        }
        var uuid: [36]u8 = undefined;
        makeUuid(&uuid);
        var probe_text: [96]u8 = undefined;
        const probe = std.fmt.bufPrint(&probe_text, "Friday exact-source probe {s}", .{uuid}) catch unreachable;
        var delivery_bytes: [512]u8 = undefined;
        const delivery_length = try self.deliverText(probe, &target, true, services, &delivery_bytes);
        runLoopFor(0.25);
        const delivery = delivery_bytes[0..delivery_length];
        const pasted_verified = focusedValueContains(target.pid, probe);
        const clipboard_verified = pasteboardStringEquals(probe);
        const final_pid = frontmostPid();
        const is_clipboard = std.mem.indexOf(u8, delivery, "\"kind\":\"clipboard\"") != null;
        const is_pasted = std.mem.indexOf(u8, delivery, "\"kind\":\"pasted\"") != null;
        const wrong_app_excluded = is_clipboard or (final_pid == target.pid and final_pid != displaced_pid);
        const ok = (is_pasted and pasted_verified and wrong_app_excluded) or (is_clipboard and clipboard_verified and wrong_app_excluded);
        const message = jsonField(delivery, "message") orelse "";
        return writeProbeResult(output, ok, application_name, if (is_pasted) "pasted" else if (is_clipboard) "clipboard" else "shown", target.pid, source_capture_verified, displaced_pid, final_pid, pasted_verified, clipboard_verified, wrong_app_excluded, message);
    }
};

const RestoreContext = struct { allocator: std.mem.Allocator, snapshot: objc.Id, change_count: isize };
fn scheduleRestore(allocator: std.mem.Allocator, snapshot: objc.Id, change_count: isize) void {
    const context = allocator.create(RestoreContext) catch { objc.release(snapshot); return; };
    context.* = .{ .allocator = allocator, .snapshot = snapshot, .change_count = change_count };
    c.dispatch_after_f(c.dispatch_time(c.DISPATCH_TIME_NOW, 350 * c.NSEC_PER_MSEC), c.dispatch_get_main_queue(), context, restoreCallback);
}
fn restoreCallback(raw: ?*anyopaque) callconv(.c) void {
    const context: *RestoreContext = @ptrCast(@alignCast(raw.?));
    defer { objc.release(context.snapshot); context.allocator.destroy(context); }
    const pasteboard = generalPasteboard();
    if (objc.send0(isize, pasteboard, objc.selector("changeCount")) != context.change_count) return;
    _ = objc.send0(isize, pasteboard, objc.selector("clearContents"));
    const items = objc.send0(objc.Id, objc.class("NSMutableArray"), objc.selector("array"));
    const count = objc.send0(usize, context.snapshot, objc.selector("count"));
    for (0..count) |index| {
        const representations = objc.send1(objc.Id, usize, context.snapshot, objc.selector("objectAtIndex:"), index);
        const item = objc.send0(objc.Id, objc.class("NSPasteboardItem"), objc.selector("new"));
        const keys = objc.send0(objc.Id, representations, objc.selector("allKeys"));
        const key_count = objc.send0(usize, keys, objc.selector("count"));
        for (0..key_count) |key_index| {
            const kind = objc.send1(objc.Id, usize, keys, objc.selector("objectAtIndex:"), key_index);
            const data = objc.send1(objc.Id, objc.Id, representations, objc.selector("objectForKey:"), kind);
            _ = objc.send2(bool, objc.Id, objc.Id, item, objc.selector("setData:forType:"), data, kind);
        }
        objc.send1(void, objc.Id, items, objc.selector("addObject:"), item);
        objc.release(item);
    }
    if (count > 0) _ = objc.send1(bool, objc.Id, pasteboard, objc.selector("writeObjects:"), items);
}

fn snapshotPasteboard(pasteboard: objc.Id) objc.Id {
    const snapshot = objc.send0(objc.Id, objc.class("NSMutableArray"), objc.selector("new"));
    const items = objc.send0(objc.Id, pasteboard, objc.selector("pasteboardItems"));
    const count = objc.send0(usize, items, objc.selector("count"));
    for (0..count) |index| {
        const item = objc.send1(objc.Id, usize, items, objc.selector("objectAtIndex:"), index);
        const representations = objc.send0(objc.Id, objc.class("NSMutableDictionary"), objc.selector("new"));
        const types = objc.send0(objc.Id, item, objc.selector("types"));
        const type_count = objc.send0(usize, types, objc.selector("count"));
        for (0..type_count) |type_index| {
            const kind = objc.send1(objc.Id, usize, types, objc.selector("objectAtIndex:"), type_index);
            const data = objc.send1(objc.Id, objc.Id, item, objc.selector("dataForType:"), kind);
            if (data != null) objc.send2(void, objc.Id, objc.Id, representations, objc.selector("setObject:forKey:"), data, kind);
        }
        objc.send1(void, objc.Id, snapshot, objc.selector("addObject:"), representations);
        objc.release(representations);
    }
    return snapshot;
}

fn copyText(allocator: std.mem.Allocator, text: objc.Id, change_count: ?*isize) bool {
    const pasteboard = generalPasteboard();
    const snapshot = snapshotPasteboard(pasteboard);
    _ = objc.send0(isize, pasteboard, objc.selector("clearContents"));
    const ok = objc.send2(bool, objc.Id, objc.Id, pasteboard, objc.selector("setString:forType:"), text, NSPasteboardTypeString);
    if (!ok) scheduleRestore(allocator, snapshot, objc.send0(isize, pasteboard, objc.selector("changeCount"))) else objc.release(snapshot);
    if (ok and change_count != null) change_count.?.* = objc.send0(isize, pasteboard, objc.selector("changeCount"));
    return ok;
}

fn accessibilityInsert(text: objc.Id, source: *SourceTarget) bool {
    if (!accessibilityTrusted() or source.captured_element == null) return false;
    const app = c.AXUIElementCreateApplication(source.pid);
    var current_window: c.CFTypeRef = null;
    if (app != null) {
        _ = c.AXUIElementCopyAttributeValue(app, cfString("AXFocusedWindow"), &current_window);
        c.CFRelease(app);
    }
    const same_window = source.captured_window != null and current_window != null and c.CFEqual(source.captured_window, current_window);
    if (current_window != null) c.CFRelease(current_window);
    if (!same_window) return false;
    var settable: c.Boolean = 0;
    return c.AXUIElementIsAttributeSettable(source.captured_element, cfString("AXSelectedText"), &settable) == c.kAXErrorSuccess and settable != 0 and c.AXUIElementSetAttributeValue(source.captured_element, cfString("AXSelectedText"), @ptrCast(text)) == c.kAXErrorSuccess;
}

fn liveApplication(source: *const SourceTarget) objc.Id {
    const apps = objc.send0(objc.Id, sharedWorkspace(), objc.selector("runningApplications"));
    const count = objc.send0(usize, apps, objc.selector("count"));
    for (0..count) |index| {
        const app = objc.send1(objc.Id, usize, apps, objc.selector("objectAtIndex:"), index);
        if (objc.send0(i32, app, objc.selector("processIdentifier")) != source.pid or objc.send0(bool, app, objc.selector("isTerminated"))) continue;
        var buffer: [512]u8 = undefined;
        const bundle = objc.copyUtf8Into(objc.send0(objc.Id, app, objc.selector("bundleIdentifier")), &buffer);
        if (!std.mem.eql(u8, bundle, source.bundle_id)) return null;
        const date = objc.send0(objc.Id, app, objc.selector("launchDate"));
        if (date == null or @abs(objc.send0(f64, date, objc.selector("timeIntervalSince1970")) - source.launch_time) > 0.001) return null;
        var path_buffer: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = @splat(0);
        const length = c.proc_pidpath(source.pid, &path_buffer, @intCast(path_buffer.len));
        if (length <= 0 or !std.mem.eql(u8, path_buffer[0..@intCast(length)], source.process_path)) return null;
        return app;
    }
    return null;
}

fn focusedValueContains(pid: i32, needle: []const u8) bool {
    const app = c.AXUIElementCreateApplication(pid);
    if (app == null) return false;
    defer c.CFRelease(app);
    var focused: c.CFTypeRef = null;
    var value: c.CFTypeRef = null;
    _ = c.AXUIElementCopyAttributeValue(app, cfString("AXFocusedUIElement"), &focused);
    if (focused != null) _ = c.AXUIElementCopyAttributeValue(@ptrCast(@constCast(focused)), cfString("AXValue"), &value);
    if (focused != null) c.CFRelease(focused);
    if (value == null) return false;
    defer c.CFRelease(value);
    var buffer: [8192]u8 = undefined;
    var bytes: []const u8 = &.{};
    if (c.CFGetTypeID(value) == c.CFStringGetTypeID()) bytes = objc.copyUtf8Into(@ptrCast(@constCast(value)), &buffer)
    else if (objc.isKindOfClass(@ptrCast(@constCast(value)), objc.class("NSAttributedString"))) bytes = objc.copyUtf8Into(objc.send0(objc.Id, @ptrCast(@constCast(value)), objc.selector("string")), &buffer);
    return std.mem.indexOf(u8, bytes, needle) != null;
}

fn screenUnderMouse() ?c.CGRect {
    const point = objc.send0(c.CGPoint, objc.class("NSEvent"), objc.selector("mouseLocation"));
    const screens = objc.send0(objc.Id, objc.class("NSScreen"), objc.selector("screens"));
    const count = objc.send0(usize, screens, objc.selector("count"));
    for (0..count) |index| {
        const screen = objc.send1(objc.Id, usize, screens, objc.selector("objectAtIndex:"), index);
        const frame = objc.send0(c.CGRect, screen, objc.selector("frame"));
        if (point.x >= frame.origin.x and point.x <= frame.origin.x + frame.size.width and point.y >= frame.origin.y and point.y <= frame.origin.y + frame.size.height) return objc.send0(c.CGRect, screen, objc.selector("visibleFrame"));
    }
    return null;
}

fn findOrLaunchApplication(bundle_id: []const u8, name: []const u8) objc.Id {
    if (findRunningApplication(bundle_id)) |app| return app;
    const ns_name = objc.nsString(name); defer objc.release(ns_name);
    _ = objc.send1(bool, objc.Id, sharedWorkspace(), objc.selector("launchApplication:"), ns_name);
    const deadline = wallSeconds() + 2.0;
    while (wallSeconds() < deadline) { if (findRunningApplication(bundle_id)) |app| return app; runLoopFor(0.01); }
    return null;
}
fn findRunningApplication(bundle_id: []const u8) objc.Id {
    const string = objc.nsString(bundle_id); defer objc.release(string);
    const apps = objc.send1(objc.Id, objc.Id, objc.class("NSRunningApplication"), objc.selector("runningApplicationsWithBundleIdentifier:"), string);
    if (objc.send0(usize, apps, objc.selector("count")) == 0) return null;
    return objc.send1(objc.Id, usize, apps, objc.selector("objectAtIndex:"), 0);
}
fn postCommandKey(pid: i32, key: u16) void {
    const source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (source == null) return;
    defer c.CFRelease(source);
    const down = c.CGEventCreateKeyboardEvent(source, key, true); const up = c.CGEventCreateKeyboardEvent(source, key, false);
    if (down != null) { c.CGEventSetFlags(down, 1 << 20); c.CGEventPostToPid(pid, down); c.CFRelease(down); }
    if (up != null) { c.CGEventSetFlags(up, 1 << 20); c.CGEventPostToPid(pid, up); c.CFRelease(up); }
}
fn pasteboardStringEquals(expected: []const u8) bool {
    const value = objc.send1(objc.Id, objc.Id, generalPasteboard(), objc.selector("stringForType:"), NSPasteboardTypeString);
    var buffer: [8192]u8 = undefined;
    return std.mem.eql(u8, objc.copyUtf8Into(value, &buffer), expected);
}
fn generalPasteboard() objc.Id { return objc.send0(objc.Id, objc.class("NSPasteboard"), objc.selector("generalPasteboard")); }
fn sharedWorkspace() objc.Id { return objc.send0(objc.Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace")); }
fn frontmostPid() i32 { const app = objc.send0(objc.Id, sharedWorkspace(), objc.selector("frontmostApplication")); return if (app == null) 0 else objc.send0(i32, app, objc.selector("processIdentifier")); }
fn waitForFrontmost(pid: i32, seconds: f64) void { const deadline = wallSeconds() + seconds; while (frontmostPid() != pid and wallSeconds() < deadline) runLoopFor(0.01); }
fn runLoopFor(seconds: f64) void { _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, seconds, false); }
fn processPath(allocator: std.mem.Allocator, pid: i32) ![]u8 { var buffer: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = @splat(0); const length = c.proc_pidpath(pid, &buffer, @intCast(buffer.len)); return allocator.dupe(u8, if (length > 0) buffer[0..@intCast(length)] else ""); }
fn copyStringOr(allocator: std.mem.Allocator, value: objc.Id, fallback: []const u8) ![]u8 { if (value == null) return allocator.dupe(u8, fallback); const copied = objc.copyUtf8Alloc(allocator, value) catch return allocator.dupe(u8, fallback); if (copied.len == 0 and fallback.len > 0) { allocator.free(copied); return allocator.dupe(u8, fallback); } return copied; }
fn wallSeconds() f64 {
    var value: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &value))) {
        .SUCCESS => @as(f64, @floatFromInt(value.sec)) + @as(f64, @floatFromInt(value.nsec)) / 1_000_000_000.0,
        else => 0,
    };
}
fn wallMilliseconds() i64 { return @intFromFloat(wallSeconds() * 1000.0); }
fn makeUuid(output: *[36]u8) void { var bytes: [16]u8 = undefined; arc4random_buf(&bytes, bytes.len); bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80; _ = std.fmt.bufPrint(output, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] }) catch unreachable; }

fn writeDelivery(output: []u8, kind: []const u8, ok: bool, message: []const u8) Error!usize { var index: usize = 0; try append(&index, output, "{\"kind\":"); try appendJsonString(&index, output, kind); try append(&index, output, ",\"ok\":"); try append(&index, output, if (ok) "true" else "false"); try append(&index, output, ",\"message\":"); try appendJsonString(&index, output, message); try append(&index, output, "}"); return index; }
fn writeSimpleFailure(output: []u8, message: []const u8) Error!usize { var index: usize = 0; try append(&index, output, "{\"ok\":false,\"message\":"); try appendJsonString(&index, output, message); try append(&index, output, "}"); return index; }
fn writeProbeResult(output: []u8, ok: bool, application: []const u8, kind: []const u8, source_pid: i32, source_capture: bool, displaced_pid: i32, frontmost_pid: i32, pasted: bool, clipboard: bool, wrong_app: bool, message: []const u8) Error!usize {
    var index: usize = 0; try append(&index, output, "{\"ok\":"); try append(&index, output, if (ok) "true" else "false"); try append(&index, output, ",\"application\":"); try appendJsonString(&index, output, application); try append(&index, output, ",\"kind\":"); try appendJsonString(&index, output, kind);
    const middle = std.fmt.bufPrint(output[index..], ",\"sourcePid\":{d},\"sourceCaptureVerified\":{s},\"displacedPid\":{d},\"frontmostPid\":{d},\"pastedVerified\":{s},\"clipboardVerified\":{s},\"wrongAppExcluded\":{s},\"message\":", .{ source_pid, if (source_capture) "true" else "false", displaced_pid, frontmost_pid, if (pasted) "true" else "false", if (clipboard) "true" else "false", if (wrong_app) "true" else "false" }) catch return error.ResultBufferTooSmall; index += middle.len; try appendJsonString(&index, output, message); try append(&index, output, "}"); return index;
}
fn jsonField(json: []const u8, field: []const u8) ?[]const u8 { var marker: [64]u8 = undefined; const prefix = std.fmt.bufPrint(&marker, "\"{s}\":\"", .{field}) catch return null; const start_marker = std.mem.indexOf(u8, json, prefix) orelse return null; const start = start_marker + prefix.len; const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null; return json[start..end]; }
fn appendJsonString(index: *usize, output: []u8, value: []const u8) Error!void { try append(index, output, "\""); for (value) |byte| switch (byte) { '"' => try append(index, output, "\\\""), '\\' => try append(index, output, "\\\\"), '\n' => try append(index, output, "\\n"), '\r' => try append(index, output, "\\r"), '\t' => try append(index, output, "\\t"), else => if (byte < 0x20) { const escaped = std.fmt.bufPrint(output[index.*..], "\\u00{x:0>2}", .{byte}) catch return error.ResultBufferTooSmall; index.* += escaped.len; } else { if (index.* >= output.len) return error.ResultBufferTooSmall; output[index.*] = byte; index.* += 1; } }; try append(index, output, "\""); }
fn append(index: *usize, output: []u8, bytes: []const u8) Error!void { if (bytes.len > output.len -| index.*) return error.ResultBufferTooSmall; @memcpy(output[index.*..][0..bytes.len], bytes); index.* += bytes.len; }
