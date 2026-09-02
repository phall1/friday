const std = @import("std");
const objc = @import("objc.zig");
/// Narrow declarations for the C APIs used here. Xcode 26's CoreGraphics
/// umbrella headers expose block types that Zig 0.16 translate-c cannot parse.
const c = struct {
    const OpaqueCFType = opaque {};
    pub const CFTypeRef = ?*const OpaqueCFType;
    pub const CFAllocatorRef = ?*const OpaqueCFType;
    pub const CFMachPortRef = ?*OpaqueCFType;
    pub const CFRunLoopRef = ?*OpaqueCFType;
    pub const CFRunLoopSourceRef = ?*OpaqueCFType;
    pub const CFStringRef = ?*const OpaqueCFType;
    pub const CFRunLoopMode = CFStringRef;
    pub const CGEventRef = ?*OpaqueCFType;
    pub const CGEventTapProxy = ?*OpaqueCFType;
    pub const CGEventType = u32;
    pub const CGEventMask = u64;
    pub const CGEventFlags = u64;
    pub const CGEventField = u32;
    pub const UniChar = u16;
    pub const UniCharCount = usize;
    pub const DispatchQueue = ?*anyopaque;
    pub const DispatchFunction = *const fn (?*anyopaque) callconv(.c) void;
    pub const CGEventTapCallBack = *const fn (CGEventTapProxy, CGEventType, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef;

    pub const kCGSessionEventTap: u32 = 1;
    pub const kCGHeadInsertEventTap: u32 = 0;
    pub const kCGEventTapOptionListenOnly: u32 = 1;
    pub const kCGEventKeyDown: CGEventType = 10;
    pub const kCGEventKeyUp: CGEventType = 11;
    pub const kCGEventFlagsChanged: CGEventType = 12;
    pub const kCGEventTapDisabledByTimeout: CGEventType = 0xffff_fffe;
    pub const kCGEventTapDisabledByUserInput: CGEventType = 0xffff_ffff;
    pub const kCGKeyboardEventAutorepeat: CGEventField = 8;
    pub const kCGKeyboardEventKeycode: CGEventField = 9;
    pub const kCFStringEncodingUTF8: u32 = 0x0800_0100;

    pub extern "c" var kCFAllocatorDefault: CFAllocatorRef;
    pub extern "c" var kCFRunLoopCommonModes: CFRunLoopMode;
    pub extern "c" fn CFRelease(value: CFTypeRef) void;
    pub extern "c" fn CFMachPortCreateRunLoopSource(allocator: CFAllocatorRef, port: CFMachPortRef, order: isize) CFRunLoopSourceRef;
    pub extern "c" fn CFMachPortInvalidate(port: CFMachPortRef) void;
    pub extern "c" fn CFRunLoopGetMain() CFRunLoopRef;
    pub extern "c" fn CFRunLoopAddSource(run_loop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFRunLoopMode) void;
    pub extern "c" fn CFRunLoopRemoveSource(run_loop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFRunLoopMode) void;
    pub extern "c" fn CFStringCreateWithCharacters(allocator: CFAllocatorRef, characters: [*]const UniChar, count: isize) CFStringRef;

    pub extern "c" fn CGPreflightListenEventAccess() bool;
    pub extern "c" fn CGRequestListenEventAccess() bool;
    pub extern "c" fn CGEventTapCreate(location: u32, placement: u32, options: u32, events_of_interest: CGEventMask, callback: CGEventTapCallBack, context: ?*anyopaque) CFMachPortRef;
    pub extern "c" fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;
    pub extern "c" fn CGEventCreateKeyboardEvent(source: ?*anyopaque, key: u16, key_down: bool) CGEventRef;
    pub extern "c" fn CGEventSetFlags(event: CGEventRef, flags: CGEventFlags) void;
    pub extern "c" fn CGEventGetFlags(event: CGEventRef) CGEventFlags;
    pub extern "c" fn CGEventGetIntegerValueField(event: CGEventRef, field: CGEventField) i64;
    pub extern "c" fn CGEventGetTimestamp(event: CGEventRef) u64;
    pub extern "c" fn CGEventKeyboardGetUnicodeString(event: CGEventRef, max_length: usize, actual_length: *usize, characters: [*]UniChar) void;

    pub extern "c" var _dispatch_main_q: u8;
    pub fn dispatch_get_main_queue() DispatchQueue {
        return @ptrCast(&_dispatch_main_q);
    }
    pub extern "c" fn dispatch_async_f(queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void;
};

extern "c" var NSWorkspaceDidWakeNotification: objc.Id;
extern "c" var NSWorkspaceWillSleepNotification: objc.Id;
extern "c" fn arc4random_buf(buffer: *anyopaque, length: usize) void;

pub const EventSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, []const u8) void };
pub const AsyncCompletion = struct { context: *anyopaque, complete: *const fn (*anyopaque, bool, []const u8) void };

const Error = error{ InvalidShortcut, InputMonitoringPermissionRequired, EventTapUnavailable, ResultBufferTooSmall };

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};
const command_flag: u64 = 1 << 20;
const shift_flag: u64 = 1 << 17;
const option_flag: u64 = 1 << 19;
const control_flag: u64 = 1 << 18;
const function_flag: u64 = 1 << 23;
const relevant_flags = command_flag | shift_flag | option_flag | control_flag | function_flag;
const fn_synthetic_key_code: i64 = 179;

const Candidate = struct {
    key: i64,
    flags: u64,
    display: [96]u8 = undefined,
    display_len: usize = 0,
    code: []const u8 = "ok",
    warning: []const u8 = "",
    fn valid(self: Candidate) bool { return self.warning.len == 0; }
};
const EventKind = enum { down, up, cancel };
const QueuedEvent = struct {
    kind: EventKind,
    at_ms: f64,
    token: [36]u8 = @splat(0),
    pid: i32 = 0,
    bundle_id: [256]u8 = @splat(0),
    bundle_len: usize = 0,
    app_name: [256]u8 = @splat(0),
    app_len: usize = 0,
    reason: []const u8 = "",
};

pub const GlobalInputMonitor = struct {
    allocator: std.mem.Allocator,
    sink: EventSink,
    tap: c.CFMachPortRef = null,
    source: c.CFRunLoopSourceRef = null,
    is_running: bool = false,
    key_code: i64 = -1,
    required_flags: u64 = command_flag | shift_flag,
    chord_down: bool = false,
    accepted_down: bool = false,
    probe_down: usize = 0,
    probe_up: usize = 0,
    capture: ?AsyncCompletion = null,
    capture_modifier_flags: u64 = 0,
    capture_bytes: [768]u8 = undefined,
    capture_length: usize = 0,
    capture_pending: bool = false,
    observer: objc.Id = null,
    mutex: SpinMutex = .{},
    events: [16]QueuedEvent = undefined,
    event_head: usize = 0,
    event_tail: usize = 0,
    event_count: usize = 0,
    drain_scheduled: bool = false,

    pub fn init(allocator: std.mem.Allocator, sink: EventSink) !GlobalInputMonitor { return .{ .allocator = allocator, .sink = sink }; }
    pub fn deinit(self: *GlobalInputMonitor) void {
        self.stop();
        if (self.observer) |observer| {
            objc.send1(void, objc.Id, workspaceNotificationCenter(), objc.selector("removeObserver:"), observer);
            objc.release(observer);
            self.observer = null;
        }
    }
    pub fn usable(_: *const GlobalInputMonitor) bool { return c.CGPreflightListenEventAccess(); }
    pub fn running(self: *const GlobalInputMonitor) bool { return self.is_running; }
    pub fn requestPermission(_: *GlobalInputMonitor) void { _ = c.CGRequestListenEventAccess(); }

    pub fn configure(self: *GlobalInputMonitor, configuration: []const u8) Error!void {
        const parsed = parseConfiguration(configuration);
        const candidate = makeCandidate(parsed.key, parsed.flags, "");
        if (!candidate.valid() or parsed.key < -1 or parsed.key > 127 or (parsed.key == -1 and parsed.flags == 0)) return error.InvalidShortcut;
        self.invalidateActive("reconfigured");
        self.key_code = parsed.key;
        self.required_flags = parsed.flags;
        self.chord_down = false;
    }

    pub fn start(self: *GlobalInputMonitor) Error!void {
        if (self.is_running) return;
        if (!self.usable()) return error.InputMonitoringPermissionRequired;
        try self.installObserver();
        const mask: c.CGEventMask = (@as(c.CGEventMask, 1) << @intCast(c.kCGEventFlagsChanged)) | (@as(c.CGEventMask, 1) << @intCast(c.kCGEventKeyDown)) | (@as(c.CGEventMask, 1) << @intCast(c.kCGEventKeyUp));
        self.tap = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, c.kCGEventTapOptionListenOnly, mask, eventTap, self);
        if (self.tap == null) return error.EventTapUnavailable;
        self.source = c.CFMachPortCreateRunLoopSource(c.kCFAllocatorDefault, self.tap, 0);
        if (self.source == null) {
            c.CFRelease(self.tap);
            self.tap = null;
            return error.EventTapUnavailable;
        }
        c.CFRunLoopAddSource(c.CFRunLoopGetMain(), self.source, c.kCFRunLoopCommonModes);
        c.CGEventTapEnable(self.tap, true);
        self.is_running = true;
    }

    pub fn stop(self: *GlobalInputMonitor) void {
        self.invalidateActive("stopped");
        if (self.source != null) {
            c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), self.source, c.kCFRunLoopCommonModes);
            c.CFRelease(self.source);
            self.source = null;
        }
        if (self.tap != null) {
            c.CFMachPortInvalidate(self.tap);
            c.CFRelease(self.tap);
            self.tap = null;
        }
        self.is_running = false;
        self.chord_down = false;
        self.capture = null;
        self.capture_modifier_flags = 0;
        self.capture_pending = false;
    }

    pub fn beginShortcutCapture(self: *GlobalInputMonitor, completion: AsyncCompletion) void {
        if (self.capture != null or self.capture_pending) {
            completion.complete(completion.context, false, "{\"ok\":false,\"code\":\"capture_active\",\"message\":\"Shortcut recording is already active.\"}");
            return;
        }
        self.start() catch |failure| {
            const message = switch (failure) {
                error.InputMonitoringPermissionRequired => "Input Monitoring permission is required for the global shortcut.",
                else => "Friday could not create the global event monitor.",
            };
            self.capture_length = writeCaptureFailure(&self.capture_bytes, "monitor_unavailable", message) catch 0;
            completion.complete(completion.context, false, self.capture_bytes[0..self.capture_length]);
            return;
        };
        self.capture_modifier_flags = 0;
        self.capture = completion;
    }
    pub fn cancelShortcutCapture(self: *GlobalInputMonitor) void { self.capture = null; self.capture_modifier_flags = 0; }

    pub fn writeSyntheticProbe(self: *GlobalInputMonitor, output: []u8) Error!usize {
        const before_down = self.probe_down;
        const before_up = self.probe_up;
        try self.configure("key=-1;command=1;shift=1;option=0;control=0;fn=0");
        try self.start();
        for (0..2) |_| {
            const down = c.CGEventCreateKeyboardEvent(null, 56, true);
            if (down != null) { c.CGEventSetFlags(down, command_flag | shift_flag); self.handle(c.kCGEventFlagsChanged, down); c.CFRelease(down); }
            const up = c.CGEventCreateKeyboardEvent(null, 56, false);
            if (up != null) { c.CGEventSetFlags(up, 0); self.handle(c.kCGEventFlagsChanged, up); c.CFRelease(up); }
        }
        const downs = self.probe_down - before_down;
        const ups = self.probe_up - before_up;
        return print(output, "{{\"ok\":{s},\"downs\":{d},\"ups\":{d},\"modifierOnly\":true,\"doubleTapInputs\":{s}}}", .{ jsonBool(downs == 2 and ups == 2), downs, ups, jsonBool(downs == 2) });
    }

    pub fn writeContractProbes(output: []u8) Error!usize {
        const modifier = makeCandidate(-1, command_flag | shift_flag, "").valid();
        const key_based = makeCandidate(0, command_flag | shift_flag, "").valid();
        const function_key = makeCandidate(96, 0, "").valid();
        const fn_only = makeCandidate(-1, function_flag, "").valid();
        const fn_synthetic_ignored = isFnSyntheticKey(179);
        const reserved = !makeCandidate(49, command_flag, "").valid();
        const bare = !makeCandidate(0, 0, "").valid();
        var emitted: usize = 0;
        const Probe = struct { fn emit(context: *anyopaque, _: []const u8) void { const count: *usize = @ptrCast(@alignCast(context)); count.* += 1; } };
        var monitor = GlobalInputMonitor.init(std.heap.page_allocator, .{ .context = &emitted, .emit = Probe.emit }) catch unreachable;
        // The contract probe observes transition counters synchronously; it
        // deliberately suppresses the main-queue sink drain for this
        // stack-owned monitor.
        monitor.drain_scheduled = true;
        monitor.key_code = 0;
        monitor.required_flags = command_flag | shift_flag;
        const down = c.CGEventCreateKeyboardEvent(null, 0, true);
        const up = c.CGEventCreateKeyboardEvent(null, 0, false);
        if (down != null and up != null) { c.CGEventSetFlags(down, command_flag | shift_flag); c.CGEventSetFlags(up, command_flag | shift_flag); monitor.handle(c.kCGEventKeyDown, down); monitor.handle(c.kCGEventKeyUp, up); }
        if (down != null) c.CFRelease(down);
        if (up != null) c.CFRelease(up);
        const key_events = monitor.probe_down == 1 and monitor.probe_up == 1;
        monitor.probe_down = 0; monitor.probe_up = 0; monitor.accepted_down = false; monitor.key_code = 96; monitor.required_flags = 0;
        const function_down = c.CGEventCreateKeyboardEvent(null, 96, true);
        const function_up = c.CGEventCreateKeyboardEvent(null, 96, false);
        if (function_down != null and function_up != null) { monitor.handle(c.kCGEventKeyDown, function_down); monitor.handle(c.kCGEventKeyUp, function_up); }
        if (function_down != null) c.CFRelease(function_down);
        if (function_up != null) c.CFRelease(function_up);
        const function_events = monitor.probe_down == 1 and monitor.probe_up == 1;
        const ok = modifier and key_based and function_key and fn_only and fn_synthetic_ignored and reserved and bare and key_events and function_events;
        return print(output, "{{\"ok\":{s},\"modifierSafe\":{s},\"keyBasedSafe\":{s},\"functionKeySafe\":{s},\"fnOnlySafe\":{s},\"fnSyntheticIgnored\":{s},\"reservedRejected\":{s},\"bareTypingRejected\":{s},\"keyDownUp\":{s},\"functionDownUp\":{s}}}", .{ jsonBool(ok), jsonBool(modifier), jsonBool(key_based), jsonBool(function_key), jsonBool(fn_only), jsonBool(fn_synthetic_ignored), jsonBool(reserved), jsonBool(bare), jsonBool(key_events), jsonBool(function_events) });
    }

    fn installObserver(self: *GlobalInputMonitor) Error!void {
        if (self.observer != null) return;
        const observer_class = ensureObserverClass() orelse return error.EventTapUnavailable;
        const observer = objc.send0(objc.Id, observer_class, objc.selector("new"));
        if (observer == null) return error.EventTapUnavailable;
        objc.setPointerIvar(observer, "fridayContext", self);
        const center = workspaceNotificationCenter();
        objc.send4(void, objc.Id, objc.Sel, objc.Id, objc.Id, center, objc.selector("addObserver:selector:name:object:"), observer, objc.selector("fridayWake:"), NSWorkspaceDidWakeNotification, null);
        objc.send4(void, objc.Id, objc.Sel, objc.Id, objc.Id, center, objc.selector("addObserver:selector:name:object:"), observer, objc.selector("fridaySleep:"), NSWorkspaceWillSleepNotification, null);
        self.observer = observer;
    }

    fn handle(self: *GlobalInputMonitor, event_type: c.CGEventType, event: c.CGEventRef) void {
        const flags = @as(u64, @intCast(c.CGEventGetFlags(event))) & relevant_flags;
        if (self.capture_pending) return;
        if (self.capture) |completion| {
            if (event_type == c.kCGEventFlagsChanged) {
                if (flags != 0) {
                    self.capture_modifier_flags |= flags;
                } else if (self.capture_modifier_flags != 0) {
                    const candidate = makeCandidate(-1, self.capture_modifier_flags, "");
                    self.queueCapturedCandidate(candidate, completion);
                }
                return;
            }
            if (event_type == c.kCGEventKeyDown and c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventAutorepeat) == 0) {
                const key = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
                if (isFnSyntheticKey(key)) return;
                var fallback_bytes: [32]u8 = undefined;
                const candidate = makeCandidate(key, flags, unicodeFallback(event, &fallback_bytes));
                self.queueCapturedCandidate(candidate, completion);
            }
            return;
        }
        if (self.key_code == -1) {
            if (event_type != c.kCGEventFlagsChanged) return;
            const down = flags == self.required_flags;
            if (down and !self.chord_down) self.emitDown(event);
            if (!down and self.chord_down) self.emitUp(event);
            self.chord_down = down;
            return;
        }
        const key = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
        if (event_type == c.kCGEventKeyDown and key == self.key_code and flags == self.required_flags and c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventAutorepeat) == 0) self.emitDown(event);
        if (event_type == c.kCGEventKeyUp and key == self.key_code and self.accepted_down) self.emitUp(event);
    }
    fn queueCapturedCandidate(self: *GlobalInputMonitor, candidate: Candidate, completion: AsyncCompletion) void {
        self.capture_length = writeCandidate(&self.capture_bytes, candidate) catch 0;
        self.capture_modifier_flags = 0;
        self.capture = null;
        self.capture_pending = true;
        self.mutex.lock();
        self.capture = completion;
        self.mutex.unlock();
        c.dispatch_async_f(c.dispatch_get_main_queue(), self, drainCapture);
    }

    fn emitDown(self: *GlobalInputMonitor, event: c.CGEventRef) void {
        if (self.accepted_down) return;
        self.accepted_down = true; self.probe_down += 1;
        var queued: QueuedEvent = .{ .kind = .down, .at_ms = @as(f64, @floatFromInt(c.CGEventGetTimestamp(event))) / 1_000_000.0 };
        makeUuid(&queued.token);
        const workspace = objc.send0(objc.Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const app = objc.send0(objc.Id, workspace, objc.selector("frontmostApplication"));
        if (app != null) {
            queued.pid = objc.send0(i32, app, objc.selector("processIdentifier"));
            queued.bundle_len = objc.copyUtf8Into(objc.send0(objc.Id, app, objc.selector("bundleIdentifier")), &queued.bundle_id).len;
            queued.app_len = objc.copyUtf8Into(objc.send0(objc.Id, app, objc.selector("localizedName")), &queued.app_name).len;
        }
        if (queued.app_len == 0) { @memcpy(queued.app_name[0..11], "Application"); queued.app_len = 11; }
        self.enqueue(queued);
    }
    fn emitUp(self: *GlobalInputMonitor, event: c.CGEventRef) void {
        if (!self.accepted_down) return;
        self.accepted_down = false; self.probe_up += 1;
        self.enqueue(.{ .kind = .up, .at_ms = @as(f64, @floatFromInt(c.CGEventGetTimestamp(event))) / 1_000_000.0 });
    }
    fn invalidateActive(self: *GlobalInputMonitor, reason: []const u8) void {
        if (!self.accepted_down) return;
        self.accepted_down = false; self.chord_down = false;
        self.enqueue(.{ .kind = .cancel, .at_ms = wallMilliseconds(), .reason = reason });
    }
    fn enqueue(self: *GlobalInputMonitor, event: QueuedEvent) void {
        self.mutex.lock(); defer self.mutex.unlock();
        if (self.event_count == self.events.len) return;
        self.events[self.event_tail] = event;
        self.event_tail = (self.event_tail + 1) % self.events.len;
        self.event_count += 1;
        if (!self.drain_scheduled) { self.drain_scheduled = true; c.dispatch_async_f(c.dispatch_get_main_queue(), self, drainEvents); }
    }
    fn drainEvents(context: ?*anyopaque) callconv(.c) void {
        const self: *GlobalInputMonitor = @ptrCast(@alignCast(context.?));
        while (true) {
            self.mutex.lock();
            if (self.event_count == 0) { self.drain_scheduled = false; self.mutex.unlock(); return; }
            const event = self.events[self.event_head];
            self.event_head = (self.event_head + 1) % self.events.len; self.event_count -= 1;
            self.mutex.unlock();
            var bytes: [1024]u8 = undefined;
            const length = writeEvent(&bytes, event) catch continue;
            self.sink.emit(self.sink.context, bytes[0..length]);
        }
    }
    fn drainCapture(context: ?*anyopaque) callconv(.c) void {
        const self: *GlobalInputMonitor = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        const completion = self.capture; self.capture = null;
        const length = self.capture_length; self.capture_pending = false;
        self.mutex.unlock();
        if (completion) |value| value.complete(value.context, true, self.capture_bytes[0..length]);
    }
};

fn eventTap(_: c.CGEventTapProxy, event_type: c.CGEventType, event: c.CGEventRef, context: ?*anyopaque) callconv(.c) c.CGEventRef {
    const self: *GlobalInputMonitor = @ptrCast(@alignCast(context.?));
    if (event_type == c.kCGEventTapDisabledByTimeout or event_type == c.kCGEventTapDisabledByUserInput) {
        self.invalidateActive("tap_disabled");
        if (self.tap != null) c.CGEventTapEnable(self.tap, true);
        return event;
    }
    self.handle(event_type, event);
    return event;
}
fn observerWake(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void { if (objc.getPointerIvar(GlobalInputMonitor, receiver, "fridayContext")) |self| if (self.tap != null) c.CGEventTapEnable(self.tap, true); }
fn observerSleep(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void { if (objc.getPointerIvar(GlobalInputMonitor, receiver, "fridayContext")) |self| { self.invalidateActive("sleep"); self.chord_down = false; } }
fn ensureObserverClass() objc.Class {
    if (objc.lookupClass("FridayZigInputObserver")) |existing| return existing;
    const cls = objc.allocateClassPair(objc.class("NSObject"), "FridayZigInputObserver") orelse return null;
    if (!objc.addPointerIvar(cls, "fridayContext")) return null;
    _ = objc.addMethod(cls, objc.selector("fridayWake:"), &observerWake, "v@:@");
    _ = objc.addMethod(cls, objc.selector("fridaySleep:"), &observerSleep, "v@:@");
    objc.registerClassPair(cls);
    return cls;
}
fn workspaceNotificationCenter() objc.Id { const workspace = objc.send0(objc.Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace")); return objc.send0(objc.Id, workspace, objc.selector("notificationCenter")); }

const ParsedConfiguration = struct { key: i64 = 0, flags: u64 = 0 };
fn parseConfiguration(configuration: []const u8) ParsedConfiguration {
    var result: ParsedConfiguration = .{};
    var parts = std.mem.splitScalar(u8, configuration, ';');
    while (parts.next()) |part| {
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const name = part[0..equals]; const value = part[equals + 1 ..];
        if (std.mem.eql(u8, name, "key")) result.key = std.fmt.parseInt(i64, value, 10) catch 0 else if (truthy(value)) {
            if (std.mem.eql(u8, name, "command")) result.flags |= command_flag;
            if (std.mem.eql(u8, name, "shift")) result.flags |= shift_flag;
            if (std.mem.eql(u8, name, "option")) result.flags |= option_flag;
            if (std.mem.eql(u8, name, "control")) result.flags |= control_flag;
            if (std.mem.eql(u8, name, "fn")) result.flags |= function_flag;
        }
    }
    return result;
}
fn truthy(value: []const u8) bool { return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes"); }
fn isFnSyntheticKey(key: i64) bool { return key == fn_synthetic_key_code; }
fn isFunctionKey(key: i64) bool { return switch (key) { 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90 => true, else => false }; }
fn keyName(key: i64) ?[]const u8 { return switch (key) {
    0 => "A", 1 => "S", 2 => "D", 3 => "F", 4 => "H", 5 => "G", 6 => "Z", 7 => "X", 8 => "C", 9 => "V", 11 => "B", 12 => "Q", 13 => "W", 14 => "E", 15 => "R", 16 => "Y", 17 => "T", 31 => "O", 32 => "U", 34 => "I", 35 => "P", 37 => "L", 38 => "J", 40 => "K", 45 => "N", 46 => "M", 48 => "Tab", 49 => "Space", 36 => "Return", 53 => "Escape", 123 => "Left Arrow", 124 => "Right Arrow", 125 => "Down Arrow", 126 => "Up Arrow", 122 => "F1", 120 => "F2", 99 => "F3", 118 => "F4", 96 => "F5", 97 => "F6", 98 => "F7", 100 => "F8", 101 => "F9", 109 => "F10", 103 => "F11", 111 => "F12", 105 => "F13", 107 => "F14", 113 => "F15", 106 => "F16", 64 => "F17", 79 => "F18", 80 => "F19", 90 => "F20", else => null,
}; }
fn makeCandidate(key: i64, flags: u64, fallback: []const u8) Candidate {
    var result: Candidate = .{ .key = key, .flags = flags };
    const command = flags & command_flag != 0; const shift = flags & shift_flag != 0; const option = flags & option_flag != 0; const control = flags & control_flag != 0; const function = flags & function_flag != 0;
    appendPart(&result, if (control) "Control" else ""); appendPart(&result, if (option) "Option" else ""); appendPart(&result, if (shift) "Shift" else ""); appendPart(&result, if (command) "Command" else ""); appendPart(&result, if (function) "Fn" else "");
    if (key >= 0) if (keyName(key)) |known| appendPart(&result, known) else if (fallback.len > 0) appendPart(&result, fallback) else { var temporary: [24]u8 = undefined; appendPart(&result, std.fmt.bufPrint(&temporary, "Key {d}", .{key}) catch "Key"); };
    const modifier_count: usize = @intFromBool(command) + @intFromBool(shift) + @intFromBool(option) + @intFromBool(control) + @intFromBool(function);
    const reserved = command and (key == 49 or key == 48 or key == 12 or key == 13 or key == 4 or key == 46 or (option and key == 53));
    if (reserved) { result.code = "system_reserved"; result.warning = "That shortcut is reserved by macOS or a standard app command. Choose another shortcut."; }
    else if (key == -1 and modifier_count < 2 and !function) { result.code = "unreliable_modifier_only"; result.warning = "Use at least two modifiers, or use Fn/Globe by itself, so Friday can distinguish the shortcut reliably."; }
    else if (key >= 0 and modifier_count == 0 and !isFunctionKey(key)) { result.code = "ordinary_typing"; result.warning = "A bare typing key would trigger while you type. Add a modifier or choose a function key."; }
    else if (key < -1 or key > 127 or result.display_len == 0) { result.code = "undistinguishable"; result.warning = "Friday could not distinguish that shortcut globally."; }
    return result;
}
fn appendPart(candidate: *Candidate, part: []const u8) void {
    if (part.len == 0) return;
    if (candidate.display_len > 0) { const separator = " + "; if (candidate.display_len + separator.len > candidate.display.len) return; @memcpy(candidate.display[candidate.display_len..][0..separator.len], separator); candidate.display_len += separator.len; }
    const count = @min(part.len, candidate.display.len - candidate.display_len); @memcpy(candidate.display[candidate.display_len..][0..count], part[0..count]); candidate.display_len += count;
}
fn unicodeFallback(event: c.CGEventRef, output: []u8) []const u8 {
    var characters: [8]c.UniChar = @splat(0); var count: c.UniCharCount = 0;
    c.CGEventKeyboardGetUnicodeString(event, characters.len, &count, &characters);
    if (count == 0) return output[0..0];
    const string = c.CFStringCreateWithCharacters(c.kCFAllocatorDefault, &characters, @intCast(count));
    if (string == null) return output[0..0];
    defer c.CFRelease(string);
    return objc.copyUtf8Into(@ptrCast(@constCast(string)), output);
}
fn writeCandidate(output: []u8, candidate: Candidate) Error!usize {
    var index: usize = 0;
    try append(&index, output, "{\"ok\":true,\"valid\":"); try append(&index, output, jsonBool(candidate.valid())); try append(&index, output, ",\"code\":"); try appendJsonString(&index, output, candidate.code); try append(&index, output, ",\"config\":");
    var config: [128]u8 = undefined; const flags = candidate.flags;
    const bytes = std.fmt.bufPrint(&config, "key={d};command={d};shift={d};option={d};control={d};fn={d}", .{ candidate.key, @intFromBool(flags & command_flag != 0), @intFromBool(flags & shift_flag != 0), @intFromBool(flags & option_flag != 0), @intFromBool(flags & control_flag != 0), @intFromBool(flags & function_flag != 0) }) catch return error.ResultBufferTooSmall;
    try appendJsonString(&index, output, bytes); try append(&index, output, ",\"display\":"); try appendJsonString(&index, output, candidate.display[0..candidate.display_len]); try append(&index, output, ",\"warning\":"); try appendJsonString(&index, output, candidate.warning); try append(&index, output, "}"); return index;
}
fn writeCaptureFailure(output: []u8, code: []const u8, message: []const u8) Error!usize { var index: usize = 0; try append(&index, output, "{\"ok\":false,\"code\":"); try appendJsonString(&index, output, code); try append(&index, output, ",\"message\":"); try appendJsonString(&index, output, message); try append(&index, output, "}"); return index; }
fn writeEvent(output: []u8, event: QueuedEvent) Error!usize {
    var index: usize = 0;
    switch (event.kind) {
        .down => { try append(&index, output, "{\"event\":\"hotkey_down\",\"payload\":{\"atMs\":"); try appendNumber(&index, output, event.at_ms); try append(&index, output, ",\"token\":"); try appendJsonString(&index, output, &event.token); const suffix = std.fmt.bufPrint(output[index..], ",\"pid\":{d},\"bundleId\":", .{event.pid}) catch return error.ResultBufferTooSmall; index += suffix.len; try appendJsonString(&index, output, event.bundle_id[0..event.bundle_len]); try append(&index, output, ",\"appName\":"); try appendJsonString(&index, output, event.app_name[0..event.app_len]); try append(&index, output, "}}"); },
        .up => { try append(&index, output, "{\"event\":\"hotkey_up\",\"payload\":{\"atMs\":"); try appendNumber(&index, output, event.at_ms); try append(&index, output, "}}"); },
        .cancel => { try append(&index, output, "{\"event\":\"hotkey_cancel\",\"payload\":{\"atMs\":"); try appendNumber(&index, output, event.at_ms); try append(&index, output, ",\"reason\":"); try appendJsonString(&index, output, event.reason); try append(&index, output, "}}"); },
    }
    return index;
}
fn appendNumber(index: *usize, output: []u8, number: f64) Error!void { const bytes = std.fmt.bufPrint(output[index.*..], "{d:.0}", .{number}) catch return error.ResultBufferTooSmall; index.* += bytes.len; }
fn appendJsonString(index: *usize, output: []u8, value: []const u8) Error!void {
    try append(index, output, "\"");
    for (value) |byte| switch (byte) { '"' => try append(index, output, "\\\""), '\\' => try append(index, output, "\\\\"), '\n' => try append(index, output, "\\n"), '\r' => try append(index, output, "\\r"), '\t' => try append(index, output, "\\t"), else => if (byte < 0x20) { const encoded = std.fmt.bufPrint(output[index.*..], "\\u00{x:0>2}", .{byte}) catch return error.ResultBufferTooSmall; index.* += encoded.len; } else try appendByte(index, output, byte) };
    try append(index, output, "\"");
}
fn append(index: *usize, output: []u8, bytes: []const u8) Error!void { if (bytes.len > output.len -| index.*) return error.ResultBufferTooSmall; @memcpy(output[index.*..][0..bytes.len], bytes); index.* += bytes.len; }
fn appendByte(index: *usize, output: []u8, byte: u8) Error!void { if (index.* >= output.len) return error.ResultBufferTooSmall; output[index.*] = byte; index.* += 1; }
fn print(output: []u8, comptime format: []const u8, args: anytype) Error!usize { const bytes = std.fmt.bufPrint(output, format, args) catch return error.ResultBufferTooSmall; return bytes.len; }
fn jsonBool(value: bool) []const u8 { return if (value) "true" else "false"; }
fn makeUuid(output: *[36]u8) void {
    var bytes: [16]u8 = undefined; arc4random_buf(&bytes, bytes.len); bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80;
    _ = std.fmt.bufPrint(output, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] }) catch unreachable;
}
fn wallMilliseconds() f64 {
    var value: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &value))) {
        .SUCCESS => @as(f64, @floatFromInt(value.sec)) * 1000.0 + @as(f64, @floatFromInt(value.nsec)) / 1_000_000.0,
        else => 0,
    };
}

test "Fn or Globe is a valid modifier-only shortcut" {
    const candidate = makeCandidate(-1, function_flag, "");
    try std.testing.expect(candidate.valid());
    try std.testing.expectEqualStrings("Fn", candidate.display[0..candidate.display_len]);

    var output: [256]u8 = undefined;
    const length = try writeCandidate(&output, candidate);
    try std.testing.expect(std.mem.indexOf(u8, output[0..length], "\"config\":\"key=-1;command=0;shift=0;option=0;control=0;fn=1\"") != null);
}

test "single ordinary modifier remains invalid" {
    try std.testing.expect(!makeCandidate(-1, command_flag, "").valid());
}

test "Fn synthetic key-down waits for modifier release" {
    try std.testing.expect(isFnSyntheticKey(179));
    try std.testing.expect(!isFnSyntheticKey(96));
}
