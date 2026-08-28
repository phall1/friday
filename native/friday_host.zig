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
        friday_host_native_destroy(self.native);
        self.event_handle = null;
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
        self.services = services.*;
    }

    fn bindChannels(context: *anyopaque, channels: native_sdk.HostChannelBinding) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.channels = channels;
    }

    fn nativeEvent(context: ?*anyopaque, bytes: [*]const u8, length: usize) callconv(.c) void {
        const self: *FridayHost = @ptrCast(@alignCast(context.?));
        if (self.event_handle) |handle| switch (handle.post(bytes[0..length])) {
            .accepted => {},
            .dropped_full, .dropped_oversized, .closed => {
                self.event_post_failures += 1;
                std.log.err("FridayHost event channel rejected post; failures={d}", .{self.event_post_failures});
            },
        };
    }

    fn nativeCompletion(context: ?*anyopaque, key: u64, ok: bool, bytes: [*]const u8, length: usize) callconv(.c) void {
        const self: *FridayHost = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.in_flight_count > 0) self.in_flight_count -= 1;
        self.enqueueLocked(key, ok, bytes[0..length]);
        if (self.services) |services| services.wake() catch {};
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        var ok = false;
        _ = friday_host_native_request(self.native, name.ptr, name.len, payload.ptr, payload.len, &ok, &self.scratch, self.scratch.len);
    }

    fn isAsync(name: []const u8) bool {
        return std.mem.eql(u8, name, "friday.audio.start") or std.mem.eql(u8, name, "friday.audio.finish") or
            std.mem.eql(u8, name, "friday.nemo.transcribe_path") or std.mem.eql(u8, name, "friday.model.download") or
            std.mem.eql(u8, name, "friday.model.add_local") or std.mem.eql(u8, name, "friday.model.add_hf") or
            std.mem.eql(u8, name, "friday.model.select");
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, "friday.subscribe")) {
            const channels = self.channels orelse {
                self.enqueue(key, false, "channel_binding_unavailable");
                return;
            };
            self.event_handle = channels.acquire_fn(channels.context, event_channel_key);
            self.enqueue(key, self.event_handle != null, if (self.event_handle != null) "{\"ok\":true,\"subscribed\":true}" else "channel_unavailable");
            return;
        }
        if (isAsync(name)) {
            self.mutex.lock();
            self.in_flight_count += 1;
            self.mutex.unlock();
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
    host.enqueue(1, true, "first");
    host.enqueue(2, true, "second");
    host.markCancelled(1);
    const result = FridayHost.poll(&host).?;
    try std.testing.expectEqual(@as(u64, 2), result.key);
    try std.testing.expectEqualStrings("second", result.bytes);
    try std.testing.expect(!FridayHost.pending(&host));
}
