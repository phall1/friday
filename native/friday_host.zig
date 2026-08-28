const std = @import("std");
const native_sdk = @import("native_sdk");

const NativeHost = opaque {};
const EventCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
const CompletionCallback = *const fn (?*anyopaque, u64, bool, [*]const u8, usize) callconv(.c) void;
extern fn friday_host_native_create([*:0]const u8, EventCallback, ?*anyopaque) ?*NativeHost;
extern fn friday_host_native_destroy(*NativeHost) void;
extern fn friday_host_native_request(*NativeHost, [*]const u8, usize, [*]const u8, usize, *bool, [*]u8, usize) usize;
extern fn friday_host_native_request_async(*NativeHost, u64, [*]const u8, usize, [*]const u8, usize, CompletionCallback, ?*anyopaque) void;
extern fn friday_host_native_cancel(*NativeHost, u64) void;
extern fn friday_host_native_contract_probes([*]u8, usize) usize;

const completion_capacity = 128;

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};
const result_capacity = 64 * 1024;
const event_channel_key: u64 = 7001;
const Completion = struct { key: u64, ok: bool, length: usize, cancelled: bool, bytes: [result_capacity]u8 };

pub const FridayHost = struct {
    allocator: std.mem.Allocator,
    native: *NativeHost,
    mutex: SpinMutex = .{},
    completions: [completion_capacity]Completion = undefined,
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    in_flight_count: usize = 0,
    in_flight_keys: [completion_capacity]u64 = @splat(0),
    in_flight_used: [completion_capacity]bool = @splat(false),
    closing: bool = false,
    channels: ?native_sdk.HostChannelBinding = null,
    event_handle: ?native_sdk.ChannelHandle = null,
    services: ?native_sdk.platform.PlatformServices = null,
    event_post_failures: u64 = 0,
    scratch: [result_capacity]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, app_data_dir: []const u8) !*FridayHost {
        _ = io;
        const self = try allocator.create(FridayHost);
        const directory = try allocator.dupeZ(u8, app_data_dir);
        defer allocator.free(directory);
        const native = friday_host_native_create(directory, nativeEvent, self) orelse {
            allocator.destroy(self);
            return error.FridayHostUnavailable;
        };
        self.* = .{ .allocator = allocator, .native = native };
        return self;
    }

    pub fn destroy(self: *FridayHost) void {
        self.mutex.lock();
        self.closing = true;
        self.event_handle = null;
        self.channels = null;
        self.services = null;
        self.mutex.unlock();
        friday_host_native_destroy(self.native);
        self.mutex.lock();
        const safe_to_free = self.in_flight_count == 0;
        self.mutex.unlock();
        if (!safe_to_free) {
            std.log.err("FridayHost teardown retained callback context for {d} unfinished operation(s)", .{self.in_flight_count});
            return;
        }
        self.allocator.destroy(self);
    }

    pub fn binding(self: *FridayHost) native_sdk.HostCallBinding {
        return .{
            .context = self,
            .send_fn = send,
            .request_fn = request,
            .cancel_fn = cancel,
            .poll_fn = poll,
            .pending_fn = pending,
            .bind_services_fn = bindServices,
            .bind_channels_fn = bindChannels,
        };
    }

    fn bindServices(context: *anyopaque, services: *const native_sdk.platform.PlatformServices) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing) self.services = services.*;
    }

    fn bindChannels(context: *anyopaque, channels: native_sdk.HostChannelBinding) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing) self.channels = channels;
    }

    fn nativeEvent(context: ?*anyopaque, bytes: [*]const u8, length: usize) callconv(.c) void {
        const self: *FridayHost = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        const handle = if (!self.closing) self.event_handle else null;
        self.mutex.unlock();
        if (handle) |live_handle| switch (live_handle.post(bytes[0..length])) {
            .accepted => {},
            .dropped_full, .dropped_oversized, .closed => {
                self.mutex.lock();
                self.event_post_failures += 1;
                const failures = self.event_post_failures;
                self.mutex.unlock();
                std.log.err("FridayHost event channel rejected post; failures={d}", .{failures});
            },
        };
    }

    fn nativeCompletion(context: ?*anyopaque, key: u64, ok: bool, bytes: [*]const u8, length: usize) callconv(.c) void {
        const self: *FridayHost = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        const known = self.takeInFlightLocked(key);
        const should_deliver = known and !self.closing;
        if (should_deliver) self.enqueueLocked(key, ok, bytes[0..length]);
        const services = if (should_deliver) self.services else null;
        self.mutex.unlock();
        if (services) |live_services| live_services.wake() catch {};
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        var ok = false;
        _ = friday_host_native_request(self.native, name.ptr, name.len, payload.ptr, payload.len, &ok, &self.scratch, self.scratch.len);
    }

    fn isAsync(name: []const u8) bool {
        return std.mem.eql(u8, name, "friday.hotkey.capture") or std.mem.eql(u8, name, "friday.audio.start") or
            std.mem.eql(u8, name, "friday.audio.stop") or std.mem.eql(u8, name, "friday.audio.finish") or
            std.mem.eql(u8, name, "friday.nemo.transcribe_capture") or std.mem.eql(u8, name, "friday.audio.retry") or std.mem.eql(u8, name, "friday.debug.fixture_delivery") or
            std.mem.eql(u8, name, "friday.nemo.transcribe_path") or std.mem.eql(u8, name, "friday.nemo.unload") or
            std.mem.eql(u8, name, "friday.model.download") or std.mem.eql(u8, name, "friday.model.resume") or std.mem.eql(u8, name, "friday.model.pick_local") or
            std.mem.eql(u8, name, "friday.model.resolve_hf") or std.mem.eql(u8, name, "friday.model.download_hf") or std.mem.eql(u8, name, "friday.model.add_local") or
            std.mem.eql(u8, name, "friday.model.add_hf") or std.mem.eql(u8, name, "friday.model.select");
    }

    fn addInFlightLocked(self: *FridayHost, key: u64) bool {
        for (self.in_flight_used, 0..) |used, index| {
            if (used and self.in_flight_keys[index] == key) return false;
        }
        for (&self.in_flight_used, 0..) |*used, index| {
            if (!used.*) {
                used.* = true;
                self.in_flight_keys[index] = key;
                self.in_flight_count += 1;
                return true;
            }
        }
        return false;
    }

    fn takeInFlightLocked(self: *FridayHost, key: u64) bool {
        for (&self.in_flight_used, 0..) |*used, index| {
            if (used.* and self.in_flight_keys[index] == key) {
                used.* = false;
                self.in_flight_keys[index] = 0;
                if (self.in_flight_count > 0) self.in_flight_count -= 1;
                return true;
            }
        }
        return false;
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, "friday.subscribe")) {
            self.mutex.lock();
            const channels = if (!self.closing) self.channels else null;
            self.mutex.unlock();
            const channel_binding = channels orelse {
                self.enqueue(key, false, "channel_binding_unavailable");
                return;
            };
            const handle = channel_binding.acquire_fn(channel_binding.context, event_channel_key);
            self.mutex.lock();
            if (!self.closing) self.event_handle = handle;
            self.mutex.unlock();
            self.enqueue(key, handle != null, if (handle != null) "{\"ok\":true,\"subscribed\":true}" else "channel_unavailable");
            return;
        }
        if (isAsync(name)) {
            self.mutex.lock();
            const accepted = !self.closing and self.addInFlightLocked(key);
            self.mutex.unlock();
            if (!accepted) {
                self.enqueue(key, false, "async_key_unavailable");
                return;
            }
            friday_host_native_request_async(self.native, key, name.ptr, name.len, payload.ptr, payload.len, nativeCompletion, self);
            return;
        }
        var ok = false;
        const length = friday_host_native_request(self.native, name.ptr, name.len, payload.ptr, payload.len, &ok, &self.scratch, self.scratch.len);
        self.enqueue(key, if (length > 0) ok else false, if (length > 0) self.scratch[0..length] else "native_response_failed");
    }

    fn enqueue(self: *FridayHost, key: u64, ok: bool, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enqueueLocked(key, ok, bytes);
    }

    fn enqueueLocked(self: *FridayHost, key: u64, ok: bool, bytes: []const u8) void {
        if (self.completion_count == self.completions.len) {
            std.log.err("FridayHost completion queue exhausted; key={d}", .{key});
            return;
        }
        const slot = &self.completions[self.completion_tail];
        const length = @min(bytes.len, slot.bytes.len);
        @memcpy(slot.bytes[0..length], bytes[0..length]);
        slot.key = key;
        slot.ok = ok;
        slot.length = length;
        slot.cancelled = false;
        self.completion_tail = (self.completion_tail + 1) % self.completions.len;
        self.completion_count += 1;
    }

    fn cancel(context: *anyopaque, key: u64) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        friday_host_native_cancel(self.native, key);
        self.markCancelled(key);
    }

    fn markCancelled(self: *FridayHost, key: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var offset: usize = 0;
        while (offset < self.completion_count) : (offset += 1) {
            const index = (self.completion_head + offset) % self.completions.len;
            if (self.completions[index].key == key) self.completions[index].cancelled = true;
        }
    }

    fn poll(context: *anyopaque) ?native_sdk.HostCallCompletion {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.completion_count > 0) {
            const slot = &self.completions[self.completion_head];
            self.completion_head = (self.completion_head + 1) % self.completions.len;
            self.completion_count -= 1;
            if (!slot.cancelled) return .{ .key = slot.key, .ok = slot.ok, .bytes = slot.bytes[0..slot.length] };
        }
        return null;
    }

    fn pending(context: *anyopaque) bool {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.completion_count > 0 or self.in_flight_count > 0;
    }
};

test "completion queue preserves order cancellation and pending state" {
    var host: FridayHost = undefined;
    host.mutex = .{};
    host.completion_head = 0;
    host.completion_tail = 0;
    host.completion_count = 0;
    host.in_flight_count = 0;
    host.in_flight_used = @splat(false);
    host.in_flight_keys = @splat(0);
    host.closing = false;
    try std.testing.expect(host.addInFlightLocked(77));
    try std.testing.expect(!host.addInFlightLocked(77));
    try std.testing.expectEqual(@as(usize, 1), host.in_flight_count);
    try std.testing.expect(host.takeInFlightLocked(77));
    try std.testing.expect(!host.takeInFlightLocked(77));
    try std.testing.expectEqual(@as(usize, 0), host.in_flight_count);
    host.enqueue(1, true, "first");
    host.enqueue(2, true, "second");
    host.markCancelled(1);
    const result = FridayHost.poll(&host).?;
    try std.testing.expectEqual(@as(u64, 2), result.key);

    try std.testing.expectEqualStrings("second", result.bytes);
    try std.testing.expect(!FridayHost.pending(&host));
}
test "native completion is consumed once and closing suppresses late delivery" {
    var host: FridayHost = undefined;
    host.mutex = .{};
    host.completion_head = 0;
    host.completion_tail = 0;
    host.completion_count = 0;
    host.in_flight_count = 0;
    host.in_flight_used = @splat(false);
    host.in_flight_keys = @splat(0);
    host.closing = false;
    host.services = null;
    try std.testing.expect(host.addInFlightLocked(77));
    FridayHost.nativeCompletion(&host, 77, true, "done".ptr, "done".len);
    try std.testing.expectEqual(@as(usize, 0), host.in_flight_count);
    try std.testing.expectEqual(@as(usize, 1), host.completion_count);
    FridayHost.nativeCompletion(&host, 77, true, "duplicate".ptr, "duplicate".len);
    try std.testing.expectEqual(@as(usize, 1), host.completion_count);

    try std.testing.expect(host.addInFlightLocked(78));
    host.closing = true;
    FridayHost.nativeCompletion(&host, 78, false, "late".ptr, "late".len);
    try std.testing.expectEqual(@as(usize, 0), host.in_flight_count);
    try std.testing.expectEqual(@as(usize, 1), host.completion_count);
}

test "native audio and model contracts reject unsafe states" {
    var buffer: [16 * 1024]u8 = undefined;
    const length = friday_host_native_contract_probes(&buffer, buffer.len);
    try std.testing.expect(length > 0);
    const result = buffer[0..length];
    try std.testing.expect(std.mem.indexOf(u8, result, "\"expectedBytes\":38400000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"droppedFrameFailure\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"tempRemoved\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"activeCleared\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"malformedRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"shaFailed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sidecarRequired\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"missingActiveReset\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"finalCollisionCorruptionRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"hfCompatibleFixture\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"hfPrivateRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"hfAmbiguousRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"hfNoHashRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"hfIncompatibleRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"pendingResumeHydrated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"cleanupTruthful\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"loginStatusKnown\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"audioInput\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"statesComplete\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"positionAutosave\":\"FridayOverlayPosition\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"dismissContract\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"currentPlatformSupported\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"architecture\":\"arm64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"reservedRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"bareTypingRejected\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"keyDownUp\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"functionDownUp\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"appearanceContract\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"reducedMotionContract\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"copyOnlyDelivery\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"kind\":\"clipboard\"") != null);
}
