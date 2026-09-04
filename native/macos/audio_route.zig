const std = @import("std");

pub const Snapshot = struct {
    device: u32,
    sample_rate_bits: u64,
    stream_hash: u64,
    channels: u32,

    pub fn eql(a: Snapshot, b: Snapshot) bool {
        return a.device == b.device and
            a.sample_rate_bits == b.sample_rate_bits and
            a.stream_hash == b.stream_hash and
            a.channels == b.channels;
    }
};

pub const Revalidation = enum { stable, accepted_generation, retry, stale };

/// Owns route authority independently of CoreAudio resource construction.
/// Notifications only invalidate a generation; callback code can then
/// revalidate equivalent hardware without accepting a stale device.
pub const Tracker = struct {
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    active_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    forced_failure: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_callback_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    prepared_generation: u64 = 0,
    prepared: Snapshot = .{ .device = 0, .sample_rate_bits = 0, .stream_hash = 0, .channels = 0 },

    pub fn invalidate(self: *Tracker, active_capture: bool, force_failure: bool) bool {
        if (active_capture and force_failure) self.forced_failure.store(true, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
        return active_capture;
    }

    pub fn current(self: *const Tracker) u64 {
        return self.generation.load(.acquire);
    }

    pub fn preparedMatches(self: *const Tracker, generation: u64, snapshot: Snapshot) bool {
        return self.prepared_generation == generation and self.prepared.eql(snapshot);
    }

    pub fn commitPrepared(self: *Tracker, generation: u64, snapshot: Snapshot) bool {
        if (generation != self.current()) return false;
        self.prepared_generation = generation;
        self.prepared = snapshot;
        return true;
    }

    pub fn activatePrepared(self: *Tracker) ?u64 {
        const generation = self.prepared_generation;
        if (generation == 0 or generation != self.current()) return null;
        self.active_generation.store(generation, .release);
        return generation;
    }

    pub fn verifyActive(self: *Tracker, generation: u64) bool {
        if (generation == self.current()) return true;
        self.active_generation.store(0, .release);
        return false;
    }

    pub fn revalidate(self: *Tracker, snapshot: Snapshot) Revalidation {
        const active = self.active_generation.load(.acquire);
        const current_generation = self.current();
        if (active == 0 or active == current_generation) return .stable;
        if (self.forced_failure.swap(false, .acq_rel)) return .stale;
        if (!self.prepared.eql(snapshot)) return .stale;
        if (current_generation != self.current()) return .retry;
        self.active_generation.store(current_generation, .release);
        return .accepted_generation;
    }

    pub fn needsRevalidation(self: *const Tracker) bool {
        const active = self.active_generation.load(.acquire);
        return active != 0 and active != self.current();
    }

    pub fn beginCallbacks(self: *Tracker, now_ms: u64) void {
        self.last_callback_ms.store(now_ms, .release);
    }

    pub fn callbackObserved(self: *Tracker, now_ms: u64) void {
        self.last_callback_ms.store(now_ms, .release);
    }

    pub fn callbackExpired(self: *const Tracker, now_ms: u64, timeout_ms: u64) bool {
        const last = self.last_callback_ms.load(.acquire);
        return last != 0 and now_ms > last and now_ms - last >= timeout_ms;
    }

    pub fn clearActive(self: *Tracker) void {
        self.active_generation.store(0, .release);
    }

    pub fn dispose(self: *Tracker) void {
        self.clearActive();
        self.prepared_generation = 0;
        self.prepared = .{ .device = 0, .sample_rate_bits = 0, .stream_hash = 0, .channels = 0 };
    }
};

pub fn testContracts() !void {
    var tracker = Tracker{};
    const route = Snapshot{ .device = 4, .sample_rate_bits = @bitCast(@as(f64, 48_000)), .stream_hash = 9, .channels = 2 };
    const generation = tracker.current();
    try std.testing.expect(tracker.commitPrepared(generation, route));
    const active = tracker.activatePrepared().?;
    try std.testing.expect(tracker.verifyActive(active));

    try std.testing.expect(tracker.invalidate(true, false));
    try std.testing.expectEqual(Revalidation.accepted_generation, tracker.revalidate(route));
    try std.testing.expect(tracker.invalidate(true, true));
    try std.testing.expectEqual(Revalidation.stale, tracker.revalidate(route));

    tracker.beginCallbacks(100);
    try std.testing.expect(!tracker.callbackExpired(2_099, 2_000));
    try std.testing.expect(tracker.callbackExpired(2_100, 2_000));
}

test "route generation and callback liveness contracts" {
    try testContracts();
}
