const std = @import("std");
const native_sdk = @import("native_sdk");

extern fn friday_host_spike_json(buffer: [*]u8, capacity: usize) callconv(.c) usize;

const completion_capacity = 128;
const result_capacity = 2048;

const Completion = struct {
    key: u64,
    ok: bool,
    length: usize,
    cancelled: bool,
    bytes: [result_capacity]u8,
};

pub const FridayHost = struct {
    allocator: std.mem.Allocator,
    completions: [completion_capacity]Completion = undefined,
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    in_flight_count: usize = 0,
    scratch: [result_capacity]u8 = undefined,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        app_data_dir: []const u8,
    ) !*FridayHost {
        _ = io;
        _ = app_data_dir;
        const self = try allocator.create(FridayHost);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *FridayHost) void {
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
        };
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        _ = context;
        _ = name;
        _ = payload;
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        _ = payload;
        const self: *FridayHost = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, name, "friday.spike")) {
            self.enqueue(key, false, "unknown_command");
            return;
        }
        const length = friday_host_spike_json(&self.scratch, self.scratch.len);
        if (length == 0 or length >= self.scratch.len) {
            self.enqueue(key, false, "bridge_failed");
            return;
        }
        self.enqueue(key, true, self.scratch[0..length]);
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
            if (slot.cancelled) continue;
            return .{ .key = slot.key, .ok = slot.ok, .bytes = slot.bytes[0..slot.length] };
        }
        return null;
    }

    fn pending(context: *anyopaque) bool {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        return self.completion_count > 0 or self.in_flight_count > 0;
    }
};
