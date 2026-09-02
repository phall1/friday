const std = @import("std");

/// Allocation occurs only in init/deinit. One producer and one consumer may
/// call push/pop concurrently; neither operation allocates, locks, or performs
/// I/O. Overflow is rejected and counted instead of overwriting ordered data.
pub const Spsc = struct {
    allocator: std.mem.Allocator,
    values: []f32,
    write_index: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_index: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator, requested_capacity: usize) !Spsc {
        if (requested_capacity == 0) return error.InvalidCapacity;
        return .{ .allocator = allocator, .values = try allocator.alloc(f32, requested_capacity) };
    }

    pub fn deinit(self: *Spsc) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }

    pub fn capacity(self: *const Spsc) usize {
        return self.values.len;
    }

    pub fn pending(self: *const Spsc) u64 {
        return self.write_index.load(.acquire) - self.read_index.load(.acquire);
    }

    pub fn dropped(self: *const Spsc) u64 {
        return self.dropped_frames.load(.acquire);
    }

    /// Pushes normalized Float32 frames. Values are clamped to [-1, 1].
    /// Returns false if any frame was rejected; rejected frames are counted.
    pub fn push(self: *Spsc, samples: []const f32) bool {
        const write = self.write_index.load(.monotonic);
        const read = self.read_index.load(.acquire);
        const occupied = write - read;
        const free: usize = if (occupied >= self.values.len) 0 else self.values.len - @as(usize, @intCast(occupied));
        const accepted = @min(samples.len, free);
        const start: usize = @intCast(write % self.values.len);
        const first = @min(accepted, self.values.len - start);
        for (samples[0..first], self.values[start .. start + first]) |sample, *slot| slot.* = std.math.clamp(sample, -1.0, 1.0);
        const second = accepted - first;
        for (samples[first .. first + second], self.values[0..second]) |sample, *slot| slot.* = std.math.clamp(sample, -1.0, 1.0);
        if (accepted != 0) self.write_index.store(write + accepted, .release);
        const rejected = samples.len - accepted;
        if (rejected != 0) _ = self.dropped_frames.fetchAdd(rejected, .monotonic);
        return rejected == 0;
    }

    pub fn pop(self: *Spsc, output: []f32) usize {
        const read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        const count = @min(output.len, @as(usize, @intCast(write - read)));
        const start: usize = @intCast(read % self.values.len);
        const first = @min(count, self.values.len - start);
        @memcpy(output[0..first], self.values[start .. start + first]);
        const second = count - first;
        @memcpy(output[first .. first + second], self.values[0..second]);
        if (count != 0) self.read_index.store(read + count, .release);
        return count;
    }
};

test "SPSC preserves order and reports overflow" {
    var ring = try Spsc.init(std.testing.allocator, 4);
    defer ring.deinit();
    try std.testing.expect(!ring.push(&.{ -2, -0.5, 0.5, 2, 0 }));
    try std.testing.expectEqual(@as(u64, 1), ring.dropped());
    var output: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), ring.pop(&output));
    try std.testing.expectEqualSlices(f32, &.{ -1, -0.5, 0.5, 1 }, &output);
}
