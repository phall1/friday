const std = @import("std");
const native_sdk = @import("native_sdk");

pub const capacity = 128;
pub const result_capacity = 64 * 1024;

pub const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

pub const Kind = enum {
    hotkey_capture,
    audio_start,
    audio_stop,
    audio_finish,
    audio_retry,
    transcribe_capture,
    transcribe_path,
    nemo_unload,
    model_download,
    model_resume,
    model_pick_local,
    model_resolve_hf,
    model_download_hf,
    model_add_local,
    model_add_hf,
    model_select,
    debug_contracts,
    debug_fixture_delivery,
    debug_performance,
};

pub const Stage = enum { initial, stopping, activating, transcribing };

pub const Operation = struct {
    context: *anyopaque = undefined,
    used: bool = false,
    pending: bool = false,
    cancelled: bool = false,
    cancelling: bool = false,
    callback_retired: bool = false,
    completion_queued: bool = false,
    key: u64 = 0,
    kind: Kind = .hotkey_capture,
    stage: Stage = .initial,
    generation: u64 = 0,
    model_epoch: u64 = 0,
    session: u64 = 0,
    saved: ?[]u8 = null,
    path: [4096]u8 = undefined,
    path_len: usize = 0,
    output_path: [4096]u8 = undefined,
    output_path_len: usize = 0,
    iterations: usize = 0,
    completed_iterations: usize = 0,
    inference: [50]u64 = @splat(0),
    stop_to_text: [50]u64 = @splat(0),
    delivery: [50]u64 = @splat(0),
    resident: [50]u64 = @splat(0),
};

pub const Cancellation = struct {
    operation: *Operation,
    key: u64,
    kind: Kind,
    stage: Stage,
    generation: u64,
    model_epoch: u64,
    session: u64,
    callback_retired: bool,

    pub fn cleanup(self: Cancellation) Cleanup {
        if (self.callback_retired) return switch (self.kind) {
            .audio_start => .{ .audio = true, .session_state = true },
            else => .{},
        };
        return switch (self.kind) {
            .hotkey_capture => .{ .input = true, .callback_suppressed = true },
            .audio_start, .audio_stop => .{ .audio = true, .session_state = true },
            .audio_finish => if (self.stage == .transcribing)
                .{ .recognizer = true, .session_state = true }
            else
                .{ .audio = true, .session_state = true },
            .audio_retry, .transcribe_capture => .{ .recognizer = true, .session_state = true },
            .transcribe_path => .{ .recognizer = true },
            .model_download, .model_resume, .model_resolve_hf, .model_download_hf, .model_add_hf => if (self.stage == .activating)
                .{ .activation = true }
            else
                .{ .model = true },
            .model_add_local, .model_select, .model_pick_local => if (self.stage == .activating)
                .{ .activation = true }
            else
                .{ .model = true },
            .debug_fixture_delivery => if (self.stage == .activating)
                .{ .activation = true, .session_state = true }
            else
                .{ .recognizer = true, .session_state = true },
            .debug_performance => if (self.stage == .activating) .{ .activation = true } else .{ .recognizer = true },
            .nemo_unload, .debug_contracts => .{},
        };
    }
};

pub const Cleanup = struct {
    input: bool = false,
    audio: bool = false,
    recognizer: bool = false,
    activation: bool = false,
    model: bool = false,
    session_state: bool = false,
    callback_suppressed: bool = false,
};

pub const Finish = struct {
    queued: bool,
    delivery_failed: bool,
    kind: Kind,
    session: u64,
    generation: u64,
};

const Completion = struct {
    key: u64 = 0,
    ok: bool = false,
    length: usize = 0,
    cancelled: bool = false,
    operation: ?*Operation = null,
    bytes: [result_capacity]u8 = undefined,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: SpinMutex = .{},
    completions: [capacity]Completion = @splat(.{}),
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    operations: [capacity]Operation = @splat(.{}),
    pending_count: usize = 0,
    closing: bool = false,
    retired_lifecycle_generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closing = true;
        for (&self.operations) |*operation| {
            if (operation.saved) |saved| self.allocator.free(saved);
            operation.* = .{};
        }
        self.completions = @splat(.{});
        self.completion_count = 0;
        self.pending_count = 0;
    }

    pub fn close(self: *Registry) void {
        self.mutex.lock();
        self.closing = true;
        self.mutex.unlock();
    }

    pub fn isClosing(self: *Registry) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closing;
    }

    pub fn retireGeneration(self: *Registry, generation: u64) void {
        self.mutex.lock();
        self.retired_lifecycle_generation = @max(self.retired_lifecycle_generation, generation);
        self.mutex.unlock();
    }

    pub fn begin(self: *Registry, context: *anyopaque, key: u64, kind: Kind) ?*Operation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return null;
        for (&self.operations) |*operation| if (operation.used and operation.key == key) return null;
        for (&self.operations) |*operation| if (!operation.used) {
            operation.* = .{ .context = context, .used = true, .pending = true, .key = key, .kind = kind };
            self.pending_count += 1;
            return operation;
        };
        return null;
    }

    pub fn finish(self: *Registry, operation: *Operation, ok: bool, bytes: []const u8) Finish {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!operation.used or operation.callback_retired) return .{ .queued = false, .delivery_failed = false, .kind = operation.kind, .session = operation.session, .generation = operation.generation };
        operation.callback_retired = true;
        const should_deliver = operation.pending and !operation.cancelled and !self.closing and
            (!isLifecycleOperation(operation.kind) or operation.generation > self.retired_lifecycle_generation);
        if (operation.pending) {
            operation.pending = false;
            if (self.pending_count > 0) self.pending_count -= 1;
        }
        if (should_deliver) operation.completion_queued = self.enqueueLocked(operation.key, ok, bytes, operation);
        const result = Finish{
            .queued = operation.completion_queued,
            .delivery_failed = should_deliver and !operation.completion_queued and operation.generation != 0,
            .kind = operation.kind,
            .session = operation.session,
            .generation = operation.generation,
        };
        self.releaseIfRetiredLocked(operation);
        return result;
    }

    pub fn save(self: *Registry, operation: *Operation, bytes: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!operation.used) return false;
        const replacement = self.allocator.dupe(u8, bytes) catch return false;
        if (operation.saved) |saved| self.allocator.free(saved);
        operation.saved = replacement;
        return true;
    }

    pub fn operationPending(self: *Registry, operation: *Operation) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return operation.used and operation.pending and !self.closing and
            (!isLifecycleOperation(operation.kind) or operation.generation > self.retired_lifecycle_generation);
    }

    pub fn transition(self: *Registry, operation: *Operation, stage: Stage) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!operation.used or !operation.pending or self.closing) return false;
        operation.stage = stage;
        return true;
    }

    pub fn modelEpochForKey(self: *Registry, key: u64) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.operations) |*operation| if (operation.used and operation.key == key) return operation.model_epoch;
        return 0;
    }

    pub fn claimCancellation(self: *Registry, key: u64) ?Cancellation {
        self.mutex.lock();
        defer self.mutex.unlock();
        var ticket: ?Cancellation = null;
        for (&self.operations) |*operation| if (operation.used and operation.key == key and !operation.cancelled) {
            operation.cancelled = true;
            operation.cancelling = true;
            if (operation.pending) {
                operation.pending = false;
                if (self.pending_count > 0) self.pending_count -= 1;
            }
            ticket = .{
                .operation = operation,
                .key = operation.key,
                .kind = operation.kind,
                .stage = operation.stage,
                .generation = operation.generation,
                .model_epoch = operation.model_epoch,
                .session = operation.session,
                .callback_retired = operation.callback_retired,
            };
            break;
        };
        var offset: usize = 0;
        while (offset < self.completion_count) : (offset += 1) {
            const index = (self.completion_head + offset) % self.completions.len;
            if (self.completions[index].key == key) self.completions[index].cancelled = true;
        }
        return ticket;
    }

    pub fn retireCancellation(self: *Registry, ticket: Cancellation, callback_suppressed: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const operation = ticket.operation;
        if (!operation.used or operation.key != ticket.key) return;
        if (callback_suppressed) operation.callback_retired = true;
        operation.cancelling = false;
        self.releaseIfRetiredLocked(operation);
    }

    pub fn enqueue(self: *Registry, key: u64, ok: bool, bytes: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.enqueueLocked(key, ok, bytes, null);
    }

    pub fn poll(self: *Registry) ?native_sdk.HostCallCompletion {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.completion_count > 0) {
            const slot = &self.completions[self.completion_head];
            self.completion_head = (self.completion_head + 1) % self.completions.len;
            self.completion_count -= 1;
            if (slot.operation) |operation| {
                operation.completion_queued = false;
                self.releaseIfRetiredLocked(operation);
                slot.operation = null;
            }
            if (!slot.cancelled) return .{ .key = slot.key, .ok = slot.ok, .bytes = slot.bytes[0..slot.length] };
        }
        return null;
    }

    pub fn pending(self: *Registry) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.completion_count > 0 or self.pending_count > 0;
    }

    fn enqueueLocked(self: *Registry, key: u64, ok: bool, bytes: []const u8, operation: ?*Operation) bool {
        if (self.closing or self.completion_count == self.completions.len or bytes.len > result_capacity) return false;
        const slot = &self.completions[self.completion_tail];
        @memcpy(slot.bytes[0..bytes.len], bytes);
        slot.key = key;
        slot.ok = ok;
        slot.length = bytes.len;
        slot.cancelled = false;
        slot.operation = operation;
        self.completion_tail = (self.completion_tail + 1) % self.completions.len;
        self.completion_count += 1;
        return true;
    }

    fn releaseIfRetiredLocked(self: *Registry, operation: *Operation) void {
        if (!operation.used or !operation.callback_retired or operation.cancelling or operation.completion_queued) return;
        if (operation.saved) |saved| self.allocator.free(saved);
        operation.* = .{};
    }
};

pub fn isLifecycleOperation(kind: Kind) bool {
    return switch (kind) {
        .audio_start, .audio_stop, .audio_finish, .audio_retry, .transcribe_capture, .debug_fixture_delivery => true,
        else => false,
    };
}

test "registry keeps cancellation completion and slot reuse exact" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var context: u8 = 0;
    const operation = registry.begin(&context, 41, .audio_start).?;
    operation.session = 9;
    operation.generation = 11;
    const finished = registry.finish(operation, true, "started");
    try std.testing.expect(finished.queued);
    try std.testing.expect(registry.begin(&context, 41, .model_download) == null);

    const ticket = registry.claimCancellation(41).?;
    try std.testing.expect(ticket.cleanup().audio);
    registry.retireCancellation(ticket, ticket.cleanup().callback_suppressed);
    try std.testing.expect(registry.poll() == null);
    try std.testing.expect(registry.begin(&context, 41, .model_download) != null);
}

test "registry rejects oversized results rather than truncating JSON" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const oversized = try std.testing.allocator.alloc(u8, result_capacity + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expect(!registry.enqueue(1, true, oversized));
}

const CancellationStress = struct {
    registry: *Registry,
    operation: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    requested: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *CancellationStress) void {
        var iteration: usize = 0;
        while (iteration < 10_000 and !self.stop.load(.acquire)) {
            const requested = self.requested.load(.acquire);
            if (requested == iteration) {
                std.atomic.spinLoopHint();
                continue;
            }
            const operation: *Operation = @ptrFromInt(self.operation.load(.acquire));
            _ = self.registry.finish(operation, true, "late");
            iteration = requested;
            self.completed.store(iteration, .release);
        }
    }
};

test "concurrent cancellation completion and reallocation keep one owner" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var context: u8 = 0;
    var stress = CancellationStress{ .registry = &registry };
    const worker = try std.Thread.spawn(.{}, CancellationStress.run, .{&stress});
    defer {
        stress.stop.store(true, .release);
        worker.join();
    }

    var stable_slot: ?*Operation = null;
    for (1..10_001) |iteration| {
        const key: u64 = @intCast(iteration);
        const operation = registry.begin(&context, key, .transcribe_path).?;
        if (stable_slot) |slot| try std.testing.expectEqual(slot, operation) else stable_slot = operation;
        const ticket = registry.claimCancellation(key).?;
        stress.operation.store(@intFromPtr(operation), .release);
        stress.requested.store(iteration, .release);
        if (iteration % 2 == 0) {
            while (stress.completed.load(.acquire) != iteration) std.atomic.spinLoopHint();
            try std.testing.expect(operation.used);
            registry.retireCancellation(ticket, false);
        } else {
            registry.retireCancellation(ticket, false);
            while (stress.completed.load(.acquire) != iteration) std.atomic.spinLoopHint();
        }
        try std.testing.expect(!operation.used);
        try std.testing.expectEqual(@as(usize, 0), registry.pending_count);
        try std.testing.expectEqual(@as(usize, 0), registry.completion_count);
    }
}
