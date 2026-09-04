const std = @import("std");
const json = @import("../macos/json.zig");

const sample_capacity = 64;

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const Samples = struct {
    values: [sample_capacity]u64 = @splat(0),
    count: usize = 0,

    fn append(self: *Samples, value: u64) void {
        if (self.count == self.values.len) {
            std.mem.copyForwards(u64, self.values[0 .. self.values.len - 1], self.values[1..]);
            self.count -= 1;
        }
        self.values[self.count] = value;
        self.count += 1;
    }
};

pub const Components = struct {
    app_version: []const u8,
    platform: []const u8,
    permissions: []const u8,
    model: []const u8,
    audio: []const u8,
    hotkey_running: bool,
    source_targets_retained: usize,
};

/// Privacy-reviewed diagnostics owner. Callers provide immutable, already
/// redacted component snapshots; this module never reaches into live audio,
/// model, source, or transcript state.
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: Mutex = .{},
    performance_output_path: ?[]u8 = null,
    event_post_failures: u64 = 0,
    last_inference_duration_ms: u64 = 0,
    last_audio_duration_ms: u64 = 0,
    last_error_code: [64]u8 = @splat(0),
    last_error_code_len: usize = 0,
    last_hotkey_received_at_ms: u64 = 0,
    last_stop_requested_at_ms: u64 = 0,
    last_resident_bytes: u64 = 0,
    hotkey_to_first_sample_ms: Samples = .{},
    stop_to_drain_ms: Samples = .{},
    stop_to_text_ms: Samples = .{},
    text_to_delivery_ms: Samples = .{},
    dropped_frames: Samples = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, performance_output_path: ?[]const u8) !Recorder {
        return .{
            .allocator = allocator,
            .io = io,
            .performance_output_path = if (performance_output_path) |path| try allocator.dupe(u8, path) else null,
        };
    }

    pub fn deinit(self: *Recorder) void {
        if (self.performance_output_path) |path| self.allocator.free(path);
        self.performance_output_path = null;
    }

    pub fn hotkeyReceived(self: *Recorder, now_ms: u64) void {
        self.mutex.lock();
        self.last_hotkey_received_at_ms = now_ms;
        self.mutex.unlock();
    }

    pub fn stopRequested(self: *Recorder, now_ms: u64) void {
        self.mutex.lock();
        self.last_stop_requested_at_ms = now_ms;
        self.mutex.unlock();
    }

    pub fn eventPostFailed(self: *Recorder) void {
        self.mutex.lock();
        self.event_post_failures += 1;
        self.mutex.unlock();
    }

    pub fn deliveryCompleted(self: *Recorder, elapsed_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.text_to_delivery_ms.append(elapsed_ms);
        self.writePerformanceLocked();
    }

    pub fn transcriptionCompleted(self: *Recorder, ok: bool, bytes: []const u8, now_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_inference_duration_ms = json.unsignedValue(bytes, "latencyMs") orelse 0;
        self.last_resident_bytes = json.unsignedValue(bytes, "residentBytes") orelse self.last_resident_bytes;
        if (self.last_stop_requested_at_ms > 0) {
            self.stop_to_text_ms.append(now_ms -| self.last_stop_requested_at_ms);
            self.last_stop_requested_at_ms = 0;
        }
        self.last_error_code_len = 0;
        if (!ok) {
            const code = json.stringAlloc(self.allocator, bytes, "code") catch null;
            defer if (code) |value| self.allocator.free(value);
            if (code) |value| {
                self.last_error_code_len = @min(value.len, self.last_error_code.len);
                @memcpy(self.last_error_code[0..self.last_error_code_len], value[0..self.last_error_code_len]);
            }
        }
        self.writePerformanceLocked();
    }

    pub fn audioStopped(self: *Recorder, bytes: []const u8, now_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_audio_duration_ms = json.unsignedValue(bytes, "audioDurationMs") orelse 0;
        const first = json.unsignedValue(bytes, "firstAudioAtMs") orelse 0;
        if (self.last_hotkey_received_at_ms > 0 and first >= self.last_hotkey_received_at_ms and first - self.last_hotkey_received_at_ms < 10_000)
            self.hotkey_to_first_sample_ms.append(first - self.last_hotkey_received_at_ms);
        self.last_hotkey_received_at_ms = 0;
        self.stop_to_drain_ms.append(now_ms -| self.last_stop_requested_at_ms);
        self.dropped_frames.append(json.unsignedValue(bytes, "droppedFrames") orelse 0);
        self.writePerformanceLocked();
    }

    pub fn write(self: *Recorder, components: Components, output: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, components.model, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidModelSnapshot;
        const model = parsed.value.object;
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("{\"ok\":true,\"appVersion\":");
        try json.writeString(&writer, components.app_version);
        try writer.writeAll(",\"nativeSdkVersion\":\"0.10.1\",\"nemoVersion\":\"0.1.0\",\"platform\":");
        try writer.writeAll(components.platform);
        try writer.writeAll(",\"permissions\":");
        try writer.writeAll(components.permissions);
        try writer.print(",\"hotkeyRunning\":{s},\"sourceTargetsRetained\":{d},\"audio\":", .{ if (components.hotkey_running) "true" else "false", components.source_targets_retained });
        try writer.writeAll(components.audio);
        try writer.writeAll(",\"modelReady\":");
        try writeObjectField(&writer, model, "activeModelReady", .bool, "false");
        try writer.writeAll(",\"activeModelName\":");
        try writeObjectField(&writer, model, "activeModelName", .string, "\"\"");
        try writer.writeAll(",\"activeModelLicense\":");
        try writeObjectField(&writer, model, "activeModelLicense", .string, "\"\"");
        try writer.writeAll(",\"activeModelBytes\":");
        try writeObjectField(&writer, model, "activeModelBytes", .integer, "0");
        try writer.writeAll(",\"managedModelBytes\":");
        try writeObjectField(&writer, model, "managedBytes", .integer, "0");
        try writer.print(",\"lastAudioDurationMs\":{d},\"lastInferenceDurationMs\":{d},\"performance\":", .{ self.last_audio_duration_ms, self.last_inference_duration_ms });
        try self.writePerformanceObject(&writer);
        try writer.writeAll(",\"lastErrorCode\":");
        try json.writeString(&writer, self.last_error_code[0..self.last_error_code_len]);
        try writer.writeAll(",\"transcriptIncluded\":false,\"audioIncluded\":false,\"rawPathsIncluded\":false}");
        return writer.buffered().len;
    }

    fn writePerformanceLocked(self: *Recorder) void {
        const path = self.performance_output_path orelse return;
        var bytes: [16 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        self.writePerformanceObject(&writer) catch return;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = writer.buffered() }) catch {};
    }

    fn writePerformanceObject(self: *Recorder, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"hotkeyToFirstSampleMs\":");
        try writeSamples(writer, self.hotkey_to_first_sample_ms);
        try writer.writeAll(",\"stopToDrainMs\":");
        try writeSamples(writer, self.stop_to_drain_ms);
        try writer.writeAll(",\"stopToTextMs\":");
        try writeSamples(writer, self.stop_to_text_ms);
        try writer.writeAll(",\"textToDeliveryMs\":");
        try writeSamples(writer, self.text_to_delivery_ms);
        try writer.writeAll(",\"droppedFrames\":");
        try writeSamples(writer, self.dropped_frames);
        try writer.print(",\"residentBytes\":{d},\"transcriptIncluded\":false,\"audioIncluded\":false,\"rawPathsIncluded\":false}}", .{self.last_resident_bytes});
    }
};

const ExpectedJsonKind = enum { bool, string, integer };

fn writeObjectField(writer: *std.Io.Writer, object: std.json.ObjectMap, name: []const u8, expected: ExpectedJsonKind, fallback: []const u8) !void {
    const value = object.get(name) orelse return writer.writeAll(fallback);
    switch (expected) {
        .bool => if (value == .bool) return writer.writeAll(if (value.bool) "true" else "false"),
        .string => if (value == .string) return json.writeString(writer, value.string),
        .integer => if (value == .integer) return writer.print("{d}", .{value.integer}),
    }
    try writer.writeAll(fallback);
}

fn writeSamples(writer: *std.Io.Writer, samples: Samples) !void {
    try writer.writeByte('[');
    for (samples.values[0..samples.count], 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{d}", .{value});
    }
    try writer.writeByte(']');
}

fn contractPrivacy() !void {
    var recorder = try Recorder.init(std.testing.allocator, std.testing.io, null);
    defer recorder.deinit();
    recorder.hotkeyReceived(100);
    recorder.stopRequested(200);
    recorder.audioStopped("{\"audioDurationMs\":50,\"firstAudioAtMs\":140,\"droppedFrames\":0}", 220);
    recorder.transcriptionCompleted(true, "{\"latencyMs\":80,\"residentBytes\":1024}", 280);
    recorder.deliveryCompleted(20);
    var output: [8192]u8 = undefined;
    const length = try recorder.write(.{
        .app_version = "test",
        .platform = "{}",
        .permissions = "{}",
        .model = "{\"activeModelReady\":true}",
        .audio = "{}",
        .hotkey_running = true,
        .source_targets_retained = 1,
    }, &output);
    const result = output[0..length];
    try std.testing.expect(std.mem.indexOf(u8, result, "\"transcriptIncluded\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"audioIncluded\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"rawPathsIncluded\":false") != null);
}

pub fn testContracts() !void {
    try contractPrivacy();
}

test "diagnostics contracts" {
    try testContracts();
}
