const std = @import("std");
const delivery = @import("../macos/delivery.zig");

const source_capacity = 8;
const session_capacity = 128;

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const Transcript = struct {
    used: bool = false,
    session: u64 = 0,
    generation: u64 = 0,
    text: ?[]u8 = null,
};

const AudioGeneration = struct {
    used: bool = false,
    session: u64 = 0,
    generation: u64 = 0,
};

pub const DeliveryArtifacts = struct {
    source: ?*delivery.SourceTarget,
    transcript: ?[]u8,
};

/// Owns generation-scoped source, transcript, and audio identities. Callers
/// cannot enumerate transcript bytes or independently look up half of a
/// delivery transaction.
pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    generation: u64 = 0,
    sources: [source_capacity]?*delivery.SourceTarget = @splat(null),
    source_count: usize = 0,
    transcripts: [session_capacity]Transcript = @splat(.{}),
    audio_generations: [session_capacity]AudioGeneration = @splat(.{}),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.source_count > 0) self.destroySource(self.takeSourceLocked(0));
        for (&self.transcripts) |*entry| {
            if (entry.text) |text| self.allocator.free(text);
            entry.* = .{};
        }
        self.audio_generations = @splat(.{});
    }

    /// Takes ownership of `source` on success and advances source authority to
    /// `generation`. Failed retention leaves ownership with the caller.
    pub fn retainSource(self: *Store, source: delivery.SourceTarget, generation: u64) !*delivery.SourceTarget {
        if (generation == 0) return error.InvalidGeneration;
        const pointer = try self.allocator.create(delivery.SourceTarget);
        pointer.* = source;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (generation < self.generation) {
            self.allocator.destroy(pointer);
            return error.StaleGeneration;
        }
        if (self.source_count == self.sources.len) self.destroySource(self.takeSourceLocked(0));
        self.generation = generation;
        pointer.generation = generation;
        self.sources[self.source_count] = pointer;
        self.source_count += 1;
        return pointer;
    }

    pub fn currentGeneration(self: *Store) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.generation;
    }

    pub fn retainedSourceCount(self: *Store) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.source_count;
    }

    /// Consumes a token exactly once and rejects it if a newer generation has
    /// become authoritative.
    pub fn takeCurrentSource(self: *Store, token: []const u8) ?*delivery.SourceTarget {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.findSourceTokenLocked(token) orelse return null;
        const source = self.takeSourceLocked(index);
        if (source.generation != self.generation) {
            self.destroySource(source);
            return null;
        }
        return source;
    }

    pub fn discardToken(self: *Store, token: []const u8) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.findSourceTokenLocked(token) orelse return null;
        const source = self.takeSourceLocked(index);
        const generation = source.generation;
        self.destroySource(source);
        self.discardGenerationLocked(generation);
        return generation;
    }

    pub fn discardGeneration(self: *Store, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.discardGenerationLocked(generation);
    }

    pub fn storeFinal(self: *Store, session: u64, generation: u64, text: []const u8) bool {
        if (session == 0 or generation == 0 or text.len == 0) return false;
        const copy = self.allocator.dupe(u8, text) catch return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.takeTranscriptLocked(session, generation)) |old| self.allocator.free(old);
        for (&self.transcripts) |*entry| if (!entry.used) {
            entry.* = .{ .used = true, .session = session, .generation = generation, .text = copy };
            return true;
        };
        self.allocator.free(copy);
        return false;
    }

    /// Atomically consumes the only source/transcript pair eligible for one
    /// final delivery. Missing halves are still retired so stale data cannot
    /// be paired by a later request.
    pub fn takeForDelivery(self: *Store, session: u64, generation: u64) DeliveryArtifacts {
        self.mutex.lock();
        defer self.mutex.unlock();
        const source = if (self.findSourceGenerationLocked(generation)) |index| self.takeSourceLocked(index) else null;
        const transcript = self.takeTranscriptLocked(session, generation);
        return .{ .source = source, .transcript = transcript };
    }

    pub fn discardSession(self: *Store, session: u64, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.discardGenerationLocked(generation);
        if (self.takeTranscriptLocked(session, generation)) |text| self.allocator.free(text);
        self.clearAudioLocked(session);
    }

    pub fn bindAudio(self: *Store, session: u64, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearAudioLocked(session);
        for (&self.audio_generations) |*entry| if (!entry.used) {
            entry.* = .{ .used = true, .session = session, .generation = generation };
            return;
        };
    }

    pub fn clearAudio(self: *Store, session: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearAudioLocked(session);
    }

    pub fn generationForAudio(self: *Store, session: u64) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.audio_generations) |entry| if (entry.used and entry.session == session) return entry.generation;
        return 0;
    }

    pub fn releaseSource(self: *Store, source: *delivery.SourceTarget) void {
        self.destroySource(source);
    }

    pub fn releaseTranscript(self: *Store, text: []u8) void {
        self.allocator.free(text);
    }

    fn discardGenerationLocked(self: *Store, generation: u64) void {
        var index: usize = 0;
        while (index < self.source_count) {
            if (self.sources[index].?.generation == generation)
                self.destroySource(self.takeSourceLocked(index))
            else
                index += 1;
        }
        for (&self.transcripts) |*entry| if (entry.used and entry.generation == generation) {
            if (entry.text) |text| self.allocator.free(text);
            entry.* = .{};
        };
        for (&self.audio_generations) |*entry| {
            if (entry.used and entry.generation == generation) entry.* = .{};
        }
    }

    fn findSourceTokenLocked(self: *Store, token: []const u8) ?usize {
        for (self.sources[0..self.source_count], 0..) |entry, index|
            if (entry) |source| if (std.mem.eql(u8, &source.token, token)) return index;
        return null;
    }

    fn findSourceGenerationLocked(self: *Store, generation: u64) ?usize {
        for (self.sources[0..self.source_count], 0..) |entry, index|
            if (entry) |source| if (source.generation == generation) return index;
        return null;
    }

    fn takeSourceLocked(self: *Store, index: usize) *delivery.SourceTarget {
        const source = self.sources[index].?;
        var cursor = index;
        while (cursor + 1 < self.source_count) : (cursor += 1) self.sources[cursor] = self.sources[cursor + 1];
        self.source_count -= 1;
        self.sources[self.source_count] = null;
        return source;
    }

    fn takeTranscriptLocked(self: *Store, session: u64, generation: u64) ?[]u8 {
        for (&self.transcripts) |*entry| if (entry.used and entry.session == session and entry.generation == generation) {
            const text = entry.text;
            entry.* = .{};
            return text;
        };
        return null;
    }

    fn clearAudioLocked(self: *Store, session: u64) void {
        for (&self.audio_generations) |*entry| {
            if (entry.used and entry.session == session) entry.* = .{};
        }
    }

    fn destroySource(self: *Store, source: *delivery.SourceTarget) void {
        source.deinit(self.allocator);
        self.allocator.destroy(source);
    }
};

fn contractExactDelivery() !void {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var source = std.mem.zeroes(delivery.SourceTarget);
    @memset(&source.token, 7);
    const retained = try store.retainSource(source, 1);
    const generation = retained.generation;
    try std.testing.expect(store.storeFinal(3, generation, "exact final"));

    const first = store.takeForDelivery(3, generation);
    defer if (first.source) |value| store.releaseSource(value);
    defer if (first.transcript) |value| store.releaseTranscript(value);
    try std.testing.expect(first.source != null);
    try std.testing.expectEqualStrings("exact final", first.transcript.?);

    const stale = store.takeForDelivery(3, generation);
    try std.testing.expect(stale.source == null);
    try std.testing.expect(stale.transcript == null);
}

fn contractStaleSource() !void {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var first = std.mem.zeroes(delivery.SourceTarget);
    @memset(&first.token, 1);
    const retained_first = try store.retainSource(first, 1);
    const old_token = retained_first.token;
    var second = std.mem.zeroes(delivery.SourceTarget);
    @memset(&second.token, 2);
    _ = try store.retainSource(second, 2);
    try std.testing.expect(store.takeCurrentSource(&old_token) == null);

    store.bindAudio(70, 71);
    try std.testing.expectEqual(@as(u64, 71), store.generationForAudio(70));
    store.bindAudio(70, 81);
    try std.testing.expectEqual(@as(u64, 81), store.generationForAudio(70));
    store.discardSession(70, 81);
    try std.testing.expectEqual(@as(u64, 0), store.generationForAudio(70));
}

pub fn testContracts() !void {
    try contractExactDelivery();
    try contractStaleSource();
}

test "session artifact contracts" {
    try testContracts();
}
