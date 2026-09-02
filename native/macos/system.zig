const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const objc = @import("objc.zig");
const json = @import("json.zig");

extern "c" fn sysctlbyname(name: [*:0]const u8, old_value: ?*anyopaque, old_length: ?*usize, new_value: ?*anyopaque, new_length: usize) c_int;
extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn AXIsProcessTrustedWithOptions(options: objc.Id) bool;

const OperatingSystemVersion = extern struct {
    major: isize,
    minor: isize,
    patch: isize,
};

pub const PlatformStatus = struct {
    supported: bool,
    architecture: []const u8,
    translated: bool,
    version: OperatingSystemVersion,
};

pub fn monotonicMs() u64 {
    var value: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &value))) {
        .SUCCESS => @intCast(@as(i128, value.sec) * std.time.ms_per_s + @divTrunc(value.nsec, std.time.ns_per_ms)),
        else => 0,
    };
}

pub fn wallMs() u64 {
    var value: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &value))) {
        .SUCCESS => @intCast(@max(0, @as(i128, value.sec) * std.time.ms_per_s + @divTrunc(value.nsec, std.time.ns_per_ms))),
        else => 0,
    };
}

pub fn platformStatus() PlatformStatus {
    var arm64: c_int = if (builtin.cpu.arch == .aarch64) 1 else 0;
    var arm64_size: usize = @sizeOf(c_int);
    _ = sysctlbyname("hw.optional.arm64", &arm64, &arm64_size, null, 0);
    var translated: c_int = 0;
    var translated_size: usize = @sizeOf(c_int);
    if (sysctlbyname("sysctl.proc_translated", &translated, &translated_size, null, 0) != 0) translated = 0;
    const process = objc.send0(objc.Id, objc.class("NSProcessInfo"), objc.selector("processInfo"));
    const version = if (process != null)
        objc.send0(OperatingSystemVersion, process, objc.selector("operatingSystemVersion"))
    else
        OperatingSystemVersion{ .major = 0, .minor = 0, .patch = 0 };
    const is_arm64 = arm64 == 1;
    const is_translated = translated == 1;
    return .{
        .supported = is_arm64 and !is_translated and version.major >= 14,
        .architecture = if (is_translated) "x86_64 (Rosetta)" else if (is_arm64) "arm64" else "x86_64",
        .translated = is_translated,
        .version = version,
    };
}

pub fn writePlatformStatus(output: []u8) !usize {
    const status = platformStatus();
    const message = if (status.supported)
        "Apple Silicon and macOS 14 or later detected."
    else if (status.translated)
        "Friday cannot run through Rosetta."
    else if (!std.mem.eql(u8, status.architecture, "arm64"))
        "Friday requires an Apple Silicon Mac."
    else
        "Friday requires macOS 14 or later.";
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"ok\":true,\"supported\":");
    try writer.writeAll(if (status.supported) "true" else "false");
    try writer.writeAll(",\"architecture\":");
    try json.writeString(&writer, status.architecture);
    try writer.writeAll(",\"processTranslated\":");
    try writer.writeAll(if (status.translated) "true" else "false");
    try writer.print(",\"osVersion\":\"{d}.{d}.{d}\",\"minimumOS\":\"14.0\",\"message\":", .{ status.version.major, status.version.minor, status.version.patch });
    try json.writeString(&writer, message);
    try writer.writeByte('}');
    return writer.buffered().len;
}

pub fn microphoneGranted() bool {
    const application = objc.send0(objc.Id, objc.class("AVAudioApplication"), objc.selector("sharedInstance"));
    if (application == null) return false;
    return objc.send0(isize, application, objc.selector("recordPermission")) == 1_735_552_628;
}

pub fn accessibilityTrusted() bool {
    return AXIsProcessTrusted();
}

pub fn requestAccessibility() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const key = objc.nsString("AXTrustedCheckOptionPrompt");
    defer objc.release(key);
    const yes = objc.send1(objc.Id, bool, objc.class("NSNumber"), objc.selector("numberWithBool:"), true);
    const dictionary = objc.send2(objc.Id, objc.Id, objc.Id, objc.class("NSDictionary"), objc.selector("dictionaryWithObject:forKey:"), yes, key);
    _ = AXIsProcessTrustedWithOptions(dictionary);
}

pub fn writePermissions(output: []u8, microphone: bool, input_monitoring: bool) !usize {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":true,\"microphone\":{s},\"accessibility\":{s},\"inputMonitoring\":{s}}}", .{
        if (microphone) "true" else "false",
        if (accessibilityTrusted()) "true" else "false",
        if (input_monitoring) "true" else "false",
    });
    return writer.buffered().len;
}

fn loginStatus(services: ?native_sdk.platform.PlatformServices) native_sdk.platform.LaunchAtLoginStatus {
    const live = services orelse return .not_found;
    const query = live.launch_at_login_status_fn orelse return .not_found;
    return query(live.context) catch .not_found;
}

fn loginName(status: native_sdk.platform.LaunchAtLoginStatus) []const u8 {
    return switch (status) {
        .enabled => "enabled",
        .requires_approval => "requires_approval",
        .not_found => "unavailable",
        .disabled => "disabled",
    };
}

pub fn writeLoginStatus(output: []u8, services: ?native_sdk.platform.PlatformServices) !usize {
    const status = loginStatus(services);
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":true,\"enabled\":{s},\"requiresApproval\":{s},\"status\":\"{s}\"}}", .{
        if (status == .enabled) "true" else "false",
        if (status == .requires_approval) "true" else "false",
        loginName(status),
    });
    return writer.buffered().len;
}

pub fn setLoginEnabled(output: []u8, services: ?native_sdk.platform.PlatformServices, enabled: bool) !usize {
    const live = services orelse return json.writeError(output, "login_service_unavailable", "Friday must run from an installed application bundle to change Login Items.");
    const setter = live.set_launch_at_login_fn orelse return json.writeError(output, "login_service_unavailable", "Friday must run from an installed application bundle to change Login Items.");
    const status = setter(live.context, enabled) catch return json.writeError(output, "login_update_failed", "Friday could not update Login Items.");
    const message = if (status == .requires_approval)
        "Approve Friday in System Settings → General → Login Items."
    else if (enabled)
        "Friday will launch in the menu bar at login."
    else
        "Friday will not launch at login.";
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":true,\"enabled\":{s},\"requiresApproval\":{s},\"status\":\"{s}\",\"message\":", .{
        if (status == .enabled) "true" else "false",
        if (status == .requires_approval) "true" else "false",
        loginName(status),
    });
    try json.writeString(&writer, message);
    try writer.writeByte('}');
    return writer.buffered().len;
}

pub fn writeLoginCycle(output: []u8, services: ?native_sdk.platform.PlatformServices) !usize {
    const live = services orelse return json.writeError(output, "login_service_unavailable", "Friday must run from an installed application bundle to test Login Items.");
    const query = live.launch_at_login_status_fn orelse return json.writeError(output, "login_service_unavailable", "Friday must run from an installed application bundle to test Login Items.");
    const setter = live.set_launch_at_login_fn orelse return json.writeError(output, "login_service_unavailable", "Friday must run from an installed application bundle to test Login Items.");
    const original = query(live.context) catch return json.writeError(output, "login_status_failed", "Friday could not read Login Items.");
    const originally_enabled = original == .enabled;
    const changed = setter(live.context, !originally_enabled) catch return json.writeError(output, "login_update_failed", "Friday could not change Login Items.");
    const observed = query(live.context) catch changed;
    _ = setter(live.context, originally_enabled) catch return json.writeError(output, "login_restore_failed", "Friday could not restore Login Items.");
    const final = query(live.context) catch .not_found;
    const restored = (final == .enabled) == originally_enabled and final != .requires_approval;
    std.debug.print("FRIDAY_AUTOMATION_LOGIN original={s} changed={s} restored={s}\n", .{ if (originally_enabled) "enabled" else "disabled", loginName(observed), if (restored) "true" else "false" });
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":{s},\"originalEnabled\":{s},\"changedStatus\":\"{s}\",\"restored\":{s}}}", .{
        if (restored) "true" else "false",
        if (originally_enabled) "true" else "false",
        loginName(observed),
        if (restored) "true" else "false",
    });
    return writer.buffered().len;
}

pub fn copyBundleIdentifier(output: []u8) []const u8 {
    const bundle = objc.send0(objc.Id, objc.class("NSBundle"), objc.selector("mainBundle"));
    const identifier = objc.send0(objc.Id, bundle, objc.selector("bundleIdentifier"));
    const copied = objc.copyUtf8Into(identifier, output);
    return if (copied.len > 0) copied else "unbundled";
}

pub fn copyAppVersion(output: []u8) []const u8 {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const bundle = objc.send0(objc.Id, objc.class("NSBundle"), objc.selector("mainBundle"));
    const key = objc.nsString("CFBundleShortVersionString");
    defer objc.release(key);
    const value = objc.send1(objc.Id, objc.Id, bundle, objc.selector("objectForInfoDictionaryKey:"), key);
    const copied = objc.copyUtf8Into(value, output);
    return if (copied.len > 0) copied else "0.1.0";
}
