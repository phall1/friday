const std = @import("std");
const native_sdk = @import("native_sdk");

const NativeHost = opaque {};
const EventCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
extern fn friday_host_native_create([*:0]const u8, EventCallback, ?*anyopaque) ?*NativeHost;
extern fn friday_host_native_destroy(*NativeHost) void;
extern fn friday_host_native_request(*NativeHost, [*]const u8, usize, [*]const u8, usize, *bool, [*]u8, usize) usize;

const completion_capacity = 128;
const result_capacity = 4096;
const event_channel_key: u64 = 7001;

const Completion = struct { key: u64, ok: bool, length: usize, cancelled: bool, bytes: [result_capacity]u8 };

pub const FridayHost = struct {
    allocator: std.mem.Allocator,
    native: *NativeHost,
    completions: [completion_capacity]Completion = undefined,
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    channels: ?native_sdk.HostChannelBinding = null,
    event_handle: ?native_sdk.ChannelHandle = null,
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
        return .{ .context = self, .send_fn = send, .request_fn = request, .cancel_fn = cancel, .poll_fn = poll, .pending_fn = pending, .bind_channels_fn = bindChannels };
    }

    fn bindChannels(context: *anyopaque, channels: native_sdk.HostChannelBinding) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.channels = channels;
    }

    fn nativeEvent(context: ?*anyopaque, bytes: [*]const u8, length: usize) callconv(.c) void {
        const self: *FridayHost = @ptrCast(@alignCast(context.?));
        if (self.event_handle) |handle| _ = handle.post(bytes[0..length]);
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        var ok = false;
        _ = friday_host_native_request(self.native, name.ptr, name.len, payload.ptr, payload.len, &ok, &self.scratch, self.scratch.len);
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
        var ok = false;
        const length = friday_host_native_request(self.native, name.ptr, name.len, payload.ptr, payload.len, &ok, &self.scratch, self.scratch.len);
        if (length == 0) {
            self.enqueue(key, false, "native_response_failed");
            return;
        }
        self.enqueue(key, ok, self.scratch[0..length]);
    }

    fn enqueue(self: *FridayHost, key: u64, ok: bool, bytes: []const u8) void {
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
        var offset: usize = 0;
        while (offset < self.completion_count) : (offset += 1) {
            const index = (self.completion_head + offset) % self.completions.len;
            if (self.completions[index].key == key) self.completions[index].cancelled = true;
        }
    }

    fn poll(context: *anyopaque) ?native_sdk.HostCallCompletion {
        const self: *FridayHost = @ptrCast(@alignCast(context));
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
        return self.completion_count > 0;
    }
};

test "completion queue preserves order and cancellation" {
    var host: FridayHost = undefined;
    host.allocator = std.testing.allocator;
    host.completion_head = 0;
    host.completion_tail = 0;
    host.completion_count = 0;
    host.enqueue(1, true, "first");
    host.enqueue(2, true, "second");
    FridayHost.cancel(&host, 1);
    const result = FridayHost.poll(&host).?;
    try std.testing.expectEqualStrings("second", result.bytes);
    try std.testing.expect(FridayHost.poll(&host) == null);
}
