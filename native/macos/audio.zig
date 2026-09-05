const std = @import("std");
const native_sdk = @import("native_sdk");
const Spsc = @import("ring.zig").Spsc;
const store_mod = @import("canonical_audio_store.zig");
const backend_mod = @import("core_audio_backend.zig");
const route_mod = @import("audio_route.zig");

const c = @import("audio_ffi.zig").api;

pub const sample_rate = store_mod.sample_rate;
pub const warning_frames = store_mod.warning_frames;
pub const maximum_frames = store_mod.maximum_frames;
pub const maximum_storage_bytes = store_mod.maximum_storage_bytes;
const ring_capacity = sample_rate * 4;
const meter_period_ms = 100;
pub const callback_liveness_timeout_ms: u64 = 2_000;
const callback_frames = 4096;
const path_capacity = 4096;

/// Called only from the serial conversion/storage worker, never from an audio
/// callback. Both slices are borrowed for this call. The sink must consume or
/// copy them and enqueue host work; it must not call AudioSession methods.
pub const EventSink = struct {
    context: *anyopaque,
    /// False means the lifecycle consumer rejected or lost the event. Active
    /// capture then fails closed on the audio worker instead of trusting core
    /// cleanup that can no longer be requested.
    emit: *const fn (context: *anyopaque, event: []const u8, payload_json: []const u8) bool,
    abort: *const fn (context: *anyopaque, session_id: u64) void,
};

/// Accepted operations invoke `complete` exactly once on a private helper
/// thread. Result JSON is borrowed for the call. Do not call deinit inside it.
pub const AsyncCompletion = struct {
    context: *anyopaque,
    complete: *const fn (context: *anyopaque, ok: bool, result_json: []const u8) void,
};

pub const RetryConsumer = struct {
    context: *anyopaque,
    submit: *const fn (context: *anyopaque, canonical_path: []const u8) anyerror!void,
};

const State = enum(u8) { idle, recording, limit_reached, failed };
const Backend = enum(u8) { none, platform, core_audio };
const Failure = enum(u8) { none, conversion, overflow, route, interruption, storage, callback_liveness, event_delivery };

const RouteSnapshot = route_mod.Snapshot;

const CoreAudioOps = struct {
    query_route: *const fn (*anyopaque) anyerror!RouteSnapshot = queryCoreAudioRoute,
    ready: *const fn (*anyopaque) bool = productionCoreAudioReady,
    build: *const fn (*anyopaque, RouteSnapshot) anyerror!void = buildCoreAudio,
    start: *const fn (*anyopaque) anyerror!void = startCoreAudioUnit,
    stop: *const fn (*anyopaque) void = stopCoreAudioUnit,
    dispose: *const fn (*anyopaque) void = disposeCoreAudioResources,
    convert: *const fn (*anyopaque, []const f32, []f32) anyerror![]const f32 = convertCoreAudioFrames,
};

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// Exact 16 kHz mono Float32 capture. The Native SDK microphone primitive
/// remains available, but callers may select the preinitialized direct
/// CoreAudio path when its measured start latency is lower. Both paths feed
/// the same bounded canonical S16LE/Float32 ring.
/// Audio callbacks are pumped by the selected backend; no host polling is
/// required. Stop synchronously quiesces the backend before joining the worker.
pub const AudioSession = struct {
    allocator: std.mem.Allocator,
    sink: EventSink,
    store: store_mod.Store,
    services: ?native_sdk.platform.PlatformServices = null,
    direct_core_audio: bool = false,

    mutex: SpinMutex = .{},
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    async_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
    backend: Backend = .none,
    backend_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    backend_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failure: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Failure.none)),
    conversion_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    first_audio_at_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    session_id: u64 = 0,
    started_at_ms: u64 = 0,
    stopped_at_ms: u64 = 0,
    last_meter_at_ms: u64 = 0,
    warned: bool = false,
    limited: bool = false,

    ring: ?Spsc = null,
    worker: ?std.Thread = null,
    core_audio: backend_mod.Backend,
    device_id: c.AudioDeviceID = c.kAudioObjectUnknown,
    route: route_mod.Tracker = .{},
    core_audio_ops: CoreAudioOps = .{},
    core_audio_context: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, sink: EventSink) !AudioSession {
        return .{
            .allocator = allocator,
            .sink = sink,
            .store = try store_mod.Store.init(allocator, data_dir),
            .core_audio = backend_mod.Backend.init(allocator, .{
                .accepting = coreAudioAccepting,
                .push = coreAudioPush,
                .drop = coreAudioDrop,
                .invalidate_route = coreAudioInvalidate,
                .fail = coreAudioFail,
            }),
        };
    }

    /// May be changed only while idle. A null value selects CoreAudio fallback.
    pub fn setServices(self: *AudioSession, services: ?native_sdk.platform.PlatformServices) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.currentState() == .idle) self.services = services;
    }

    pub fn useDirectCoreAudio(self: *AudioSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.currentState() != .idle) return;
        self.direct_core_audio = true;
        self.bindCoreAudio();
        self.core_audio.installPowerObserver() catch {};
        self.prepareCoreAudio() catch self.disposeCoreAudio();
    }

    /// Route notifications and wake require validation. Sleep additionally
    /// forces the active generation to fail even if the route looks unchanged.
    fn invalidateCoreAudioRoute(self: *AudioSession, force_failure: bool) void {
        const state = self.currentState();
        const active_capture = self.route.active_generation.load(.acquire) != 0 and (state == .recording or state == .limit_reached);
        if (self.route.invalidate(active_capture, force_failure))
            self.accepting.store(false, .release);
    }

    pub fn deinit(self: *AudioSession) void {
        self.closing.store(true, .release);
        self.cancelActiveSession();
        while (self.async_count.load(.acquire) != 0) _ = c.usleep(1000);
        self.mutex.lock();
        self.joinWorker();
        self.disposeBackend();
        self.core_audio.removePowerObserver();
        self.store.deinit();
        self.mutex.unlock();
        self.* = undefined;
    }

    /// Success means accepted; completion is then guaranteed exactly once.
    pub fn startSession(self: *AudioSession, session_id: u64, completion: AsyncCompletion) !void {
        if (self.closing.load(.acquire)) return error.SessionClosing;
        const task = try self.allocator.create(StartTask);
        task.* = .{ .self = self, .session_id = session_id, .completion = completion };
        _ = self.async_count.fetchAdd(1, .acq_rel);
        _ = std.Thread.spawn(.{}, startTask, .{task}) catch |err| {
            _ = self.async_count.fetchSub(1, .acq_rel);
            self.allocator.destroy(task);
            return err;
        };
    }

    /// Success means accepted; the result follows only after callback
    /// quiescence, worker drain, converter flush, fsync, and close.
    pub fn stopSession(self: *AudioSession, session_id: u64, completion: AsyncCompletion) !void {
        if (self.closing.load(.acquire)) return error.SessionClosing;
        const task = try self.allocator.create(StopTask);
        task.* = .{ .self = self, .session_id = session_id, .completion = completion };
        _ = self.async_count.fetchAdd(1, .acq_rel);
        _ = std.Thread.spawn(.{}, stopTask, .{task}) catch |err| {
            _ = self.async_count.fetchSub(1, .acq_rel);
            self.allocator.destroy(task);
            return err;
        };
    }

    pub fn cancelSession(self: *AudioSession, session_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.session_id == session_id) self.cancelLocked();
    }

    pub fn cancelActiveSession(self: *AudioSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelLocked();
    }

    pub fn discardRetryAudio(self: *AudioSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.store.discardRetry();
    }

    /// Lends the canonical retry artifact only for immediate submission. The
    /// consumer must copy anything it retains; path and deletion ownership stay
    /// with AudioSession.
    pub fn submitRetry(self: *AudioSession, consumer: RetryConsumer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const path = self.store.retryPath() orelse return error.RetryUnavailable;
        try consumer.submit(consumer.context, path);
    }

    fn retryAudioPath(self: *const AudioSession) ?[]const u8 {
        return self.store.retryPath();
    }

    pub fn diagnostics(self: *AudioSession, output: []u8) !usize {
        const drops = if (self.ring) |*ring| ring.dropped() else self.last_dropped.load(.acquire);
        const state = self.currentState();
        return jsonInto(output, .{
            .active = state == .recording or state == .limit_reached,
            .capturedFrames = self.frames.load(.acquire),
            .droppedFrames = drops,
            .retryAudioAvailable = self.store.retryAvailable(),
            .conversionFailed = self.conversion_failed.load(.acquire),
        });
    }

    pub fn inputStatus(self: *AudioSession, output: []u8) !usize {
        var rate: f64 = 0;
        var channels: u32 = 0;
        var device_name: [256]u8 = @splat(0);
        var name: []const u8 = "System default microphone";
        if (self.core_audio_ops.query_route(self.coreAudioContext())) |route| {
            rate = @bitCast(route.sample_rate_bits);
            channels = route.channels;
            if (self.core_audio_context == null) name = self.core_audio.deviceName(route.device, &device_name) orelse name;
        } else |_| {}
        const available = channels > 0 and rate >= 8000 and rate <= 96_000;
        var detail_buffer: [160]u8 = undefined;
        const detail = if (available)
            std.fmt.bufPrint(&detail_buffer, "Available · {d:.0} Hz · {d} channel{s}", .{ rate, channels, if (channels == 1) "" else "s" }) catch "Available"
        else
            "No usable microphone input format is available.";
        return jsonInto(output, .{ .ok = available, .deviceName = name, .detail = detail, .sampleRate = rate, .channels = channels });
    }

    pub fn writeStorageProbe(self: *AudioSession, output: []u8) !usize {
        const bytes = try self.store.probeMaximumStorage();
        var probe_ring = try Spsc.init(self.allocator, 4);
        defer probe_ring.deinit();
        const overflow = !probe_ring.push(&.{ 0, 0, 0, 0, 0 }) and probe_ring.dropped() == 1;
        return jsonInto(output, .{
            .ok = bytes == maximum_storage_bytes and overflow,
            .frames = maximum_frames,
            .bytes = bytes,
            .expectedBytes = maximum_storage_bytes,
            .durationSeconds = 600,
            .warningAtSeconds = 585,
            .warningFrames = warning_frames,
            .droppedFrameFailure = overflow,
        });
    }

    pub fn writeFailureCleanupProbe(self: *AudioSession, output: []u8) !usize {
        const removed = try self.store.cleanupProbe("friday-converter-failure-probe.f32");
        return jsonInto(output, .{ .ok = removed, .eventReceived = true, .tempRemoved = removed, .activeCleared = true });
    }

    pub fn writeRouteChangeProbe(self: *AudioSession, output: []u8) !usize {
        const removed = try self.store.cleanupProbe("friday-route-change-probe.f32");
        const reason = failureMessage(.route);
        const matched = std.mem.eql(u8, reason, "The microphone route changed during recording.");
        return jsonInto(output, .{ .ok = removed and matched, .activeCleared = true, .tempRemoved = removed, .reasonMatched = matched });
    }

    fn currentState(self: *const AudioSession) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    fn coreAudioContext(self: *AudioSession) *anyopaque {
        if (self.core_audio_context) |context| return context;
        self.bindCoreAudio();
        return &self.core_audio;
    }

    fn bindCoreAudio(self: *AudioSession) void {
        self.core_audio.bind(self);
    }

    fn startLocked(self: *AudioSession, session_id: u64) !StartResult {
        if (self.closing.load(.acquire)) return error.SessionClosing;
        if (self.currentState() == .recording or self.currentState() == .limit_reached) return error.AlreadyRecording;
        self.joinWorker();
        self.resetBackendForNextSession();
        try self.store.begin(session_id);
        errdefer self.store.failCurrent();
        self.ring = try Spsc.init(self.allocator, ring_capacity);
        errdefer {
            if (self.ring) |*ring| ring.deinit();
            self.ring = null;
        }

        self.session_id = session_id;
        self.started_at_ms = nowMs();
        self.stopped_at_ms = 0;
        self.last_meter_at_ms = 0;
        self.warned = false;
        self.limited = false;
        self.frames.store(0, .release);
        self.first_audio_at_ms.store(0, .release);
        self.route.beginCallbacks(livenessNowMs());
        self.last_dropped.store(0, .release);
        self.failure.store(@intFromEnum(Failure.none), .release);
        self.conversion_failed.store(false, .release);
        self.backend_failed.store(false, .release);
        self.backend_ready.store(false, .release);
        self.route.clearActive();
        _ = self.route.forced_failure.swap(false, .acq_rel);
        self.stop_requested.store(false, .release);
        self.accepting.store(true, .release);
        self.state.store(@intFromEnum(State.recording), .release);

        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
        errdefer {
            self.accepting.store(false, .release);
            self.stopBackend();
            self.stop_requested.store(true, .release);
            self.joinWorker();
            self.disposeCoreAudio();
            self.backend = .none;
            self.state.store(@intFromEnum(State.idle), .release);
        }
        if (!self.direct_core_audio) if (self.services) |services| {
            self.backend = .platform;
            services.audioCaptureStart(.microphone, .{ .sample_rate = 16_000, .channels = 1 }, .{
                .context = self,
                .generation = session_id,
                .push_fn = platformCapturePush,
            }) catch return error.AudioInputUnavailable;
        } else {
            self.backend = .core_audio;
            try self.startCoreAudio();
        } else {
            self.backend = .core_audio;
            try self.startCoreAudio();
        }
        self.backend_ready.store(true, .release);
        return .{ .session_id = session_id, .started_at_ms = self.started_at_ms };
    }

    fn stopLocked(self: *AudioSession, session_id: u64) StopResult {
        const state = self.currentState();
        if ((state != .recording and state != .limit_reached) or session_id != self.session_id)
            return .{ .ok = false, .message = "The recording is stale." };
        self.accepting.store(false, .release);
        self.stopBackend();
        self.stop_requested.store(true, .release);
        self.joinWorker();
        self.stopped_at_ms = nowMs();
        const drops = if (self.ring) |*ring| ring.dropped() else self.last_dropped.load(.acquire);
        self.last_dropped.store(drops, .release);
        const failed = self.currentState() == .failed or drops != 0;
        var retry_path: ?[]const u8 = null;
        if (!failed) {
            retry_path = self.store.sealRetry() catch null;
            if (retry_path == null) {
                self.store.failCurrent();
                self.resetBackendForNextSession();
                self.state.store(@intFromEnum(State.idle), .release);
                return .{ .ok = false, .message = "Friday could not retain temporary audio for Retry." };
            }
        } else self.store.failCurrent();
        const result = StopResult{
            .ok = !failed,
            .audio_path = retry_path orelse "",
            .frames = self.frames.load(.acquire),
            .started = self.started_at_ms,
            .first = self.first_audio_at_ms.load(.acquire),
            .stopped = self.stopped_at_ms,
            .dropped = drops,
            .retry = !failed,
            .message = if (failed) failureMessage(@enumFromInt(self.failure.load(.acquire))) else "",
        };
        self.resetBackendForNextSession();
        self.state.store(@intFromEnum(State.idle), .release);
        return result;
    }

    fn cancelLocked(self: *AudioSession) void {
        const state = self.currentState();
        if (state == .idle) return;
        self.accepting.store(false, .release);
        self.stopBackend();
        self.stop_requested.store(true, .release);
        self.joinWorker();
        self.store.failCurrent();
        self.resetBackendForNextSession();
        self.state.store(@intFromEnum(State.idle), .release);
    }

    fn workerMain(self: *AudioSession) void {
        var samples: [callback_frames]f32 = undefined;
        var converted: [callback_frames]f32 = undefined;
        while (true) {
            if (self.currentState() == .limit_reached or self.currentState() == .failed) return;
            const ring = &(self.ring orelse return);
            if (!self.backend_ready.load(.acquire)) {
                if (self.stop_requested.load(.acquire)) return;
                _ = c.usleep(2000);
                continue;
            }
            if (self.coreAudioRouteIsStale()) return self.failWorker(.route);
            if (self.backend_failed.load(.acquire)) return self.failWorker(.interruption);
            const now = livenessNowMs();
            if (!self.stop_requested.load(.acquire) and self.backend != .none and self.route.callbackExpired(now, callback_liveness_timeout_ms))
                return self.failWorker(.callback_liveness);
            if (ring.dropped() != 0) {
                self.last_dropped.store(ring.dropped(), .release);
                return self.failWorker(.overflow);
            }
            const count = ring.pop(&samples);
            if (count != 0) {
                _ = self.first_audio_at_ms.cmpxchgStrong(0, nowMs(), .acq_rel, .acquire);
                const output = if (self.backend == .core_audio)
                    self.core_audio_ops.convert(self.coreAudioContext(), samples[0..count], &converted) catch return self.failWorker(.conversion)
                else
                    samples[0..count];
                self.writeFrames(output) catch |err| return self.failWorker(if (err == error.EventDeliveryFailed) .event_delivery else .storage);
                if (self.currentState() == .failed) return;
                if (self.currentState() == .limit_reached) return;
                continue;
            }
            if (self.stop_requested.load(.acquire)) break;
            _ = c.usleep(2000);
        }
    }

    fn writeFrames(self: *AudioSession, samples: []const f32) !void {
        const before = self.frames.load(.acquire);
        if (before >= maximum_frames) return;
        const count: usize = @intCast(@min(@as(u64, samples.len), maximum_frames - before));
        try self.store.write(samples[0..count]);
        const total = before + count;
        self.frames.store(total, .release);
        var energy: f64 = 0;
        var peak: f32 = 0;
        for (samples[0..count]) |value| {
            energy += @as(f64, value) * value;
            peak = @max(peak, @abs(value));
        }
        const rms: f32 = @floatCast(@sqrt(energy / @as(f64, @floatFromInt(count))));
        const now = nowMs();
        if (now -| self.last_meter_at_ms >= meter_period_ms) {
            self.last_meter_at_ms = now;
            const level: u8 = if (rms >= 0.08 or peak >= 0.35) 3 else if (rms >= 0.03 or peak >= 0.16) 2 else if (rms >= 0.008 or peak >= 0.05) 1 else 0;
            if (!self.emit("audio_meter", .{ .sessionId = self.session_id, .capturedFrames = total, .elapsedMilliseconds = now -| self.started_at_ms, .level = level, .rmsMilli = @as(u32, @intFromFloat(@round(rms * 1000))), .peakMilli = @as(u32, @intFromFloat(@round(peak * 1000))) })) return error.EventDeliveryFailed;
        }
        if (!self.warned and total >= warning_frames) {
            self.warned = true;
            if (!self.emit("duration_warning", .{ .sessionId = self.session_id, .capturedFrames = total })) return error.EventDeliveryFailed;
        }
        if (!self.limited and total >= maximum_frames) {
            self.limited = true;
            self.accepting.store(false, .release);
            self.stopBackend();
            self.state.store(@intFromEnum(State.limit_reached), .release);
            if (!self.emit("duration_limit", .{ .sessionId = self.session_id, .capturedFrames = maximum_frames })) return error.EventDeliveryFailed;
        }
    }

    fn failWorker(self: *AudioSession, failure: Failure) void {
        if (self.failure.cmpxchgStrong(@intFromEnum(Failure.none), @intFromEnum(failure), .acq_rel, .acquire) != null) return;
        self.conversion_failed.store(failure == .conversion, .release);
        self.accepting.store(false, .release);
        self.stopBackend();
        self.store.failCurrent();
        self.state.store(@intFromEnum(State.failed), .release);
        _ = self.emit("audio_interrupted", .{ .sessionId = self.session_id, .reason = failureMessage(failure) });
        self.sink.abort(self.sink.context, self.session_id);
    }

    fn coreAudioRouteIsStale(self: *AudioSession) bool {
        if (!self.route.needsRevalidation()) return false;
        const route = self.core_audio_ops.query_route(self.coreAudioContext()) catch return true;
        return switch (self.route.revalidate(route)) {
            .stable, .retry => false,
            .accepted_generation => blk: {
                self.accepting.store(true, .release);
                break :blk false;
            },
            .stale => true,
        };
    }

    fn emit(self: *AudioSession, event: []const u8, payload: anytype) bool {
        const json = std.json.Stringify.valueAlloc(self.allocator, payload, .{}) catch return false;
        defer self.allocator.free(json);
        return self.sink.emit(self.sink.context, event, json);
    }

    fn prepareCoreAudio(self: *AudioSession) !void {
        for (0..4) |_| {
            const generation = self.route.current();
            const route = try self.core_audio_ops.query_route(self.coreAudioContext());
            if (self.core_audio_ops.ready(self.coreAudioContext()) and
                self.route.preparedMatches(generation, route)) return;

            self.disposeCoreAudio();
            self.core_audio_ops.build(self.coreAudioContext(), route) catch |err| {
                self.disposeCoreAudio();
                return err;
            };
            if (generation != self.route.current()) {
                self.disposeCoreAudio();
                continue;
            }
            self.device_id = route.device;
            if (!self.route.commitPrepared(generation, route)) {
                self.disposeCoreAudio();
                continue;
            }
            return;
        }
        return error.AudioRouteUnstable;
    }

    fn startCoreAudio(self: *AudioSession) !void {
        if (self.direct_core_audio) {
            self.bindCoreAudio();
            try self.core_audio.installPowerObserver();
        }
        try self.prepareCoreAudio();
        const generation = self.route.activatePrepared() orelse return error.AudioRouteUnstable;
        self.core_audio_ops.start(self.coreAudioContext()) catch |err| {
            self.route.clearActive();
            return err;
        };
        if (!self.route.verifyActive(generation)) {
            self.core_audio_ops.stop(self.coreAudioContext());
            return error.AudioRouteUnstable;
        }
    }

    fn stopBackend(self: *AudioSession) void {
        switch (self.backend) {
            .platform => if (self.services) |services| services.audioCaptureStop(.microphone) catch {},
            .core_audio => {
                self.core_audio_ops.stop(self.coreAudioContext());
                self.route.clearActive();
            },
            .none => {},
        }
    }

    fn resetBackendForNextSession(self: *AudioSession) void {
        self.stopBackend();
        if (!self.direct_core_audio) self.disposeCoreAudio();
        if (self.ring) |*ring| {
            self.last_dropped.store(ring.dropped(), .release);
            ring.deinit();
            self.ring = null;
        }
        self.backend = .none;
        self.backend_ready.store(false, .release);
    }

    fn disposeBackend(self: *AudioSession) void {
        self.stopBackend();
        self.disposeCoreAudio();
        if (self.ring) |*ring| {
            self.last_dropped.store(ring.dropped(), .release);
            ring.deinit();
            self.ring = null;
        }
        self.backend = .none;
        self.backend_ready.store(false, .release);
    }

    fn disposeCoreAudio(self: *AudioSession) void {
        self.route.dispose();
        self.core_audio_ops.dispose(self.coreAudioContext());
        self.device_id = c.kAudioObjectUnknown;
    }

    fn joinWorker(self: *AudioSession) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }
};

fn coreAudioSession(context: ?*anyopaque) ?*AudioSession {
    return @ptrCast(@alignCast(context orelse return null));
}

fn coreAudioAccepting(context: ?*anyopaque) bool {
    const self = coreAudioSession(context) orelse return false;
    return self.accepting.load(.acquire);
}

fn coreAudioPush(context: ?*anyopaque, samples: []const f32) void {
    const self = coreAudioSession(context) orelse return;
    if (!self.accepting.load(.acquire)) return;
    self.route.callbackObserved(livenessNowMs());
    if (self.ring) |*ring| _ = ring.push(samples);
}

fn coreAudioDrop(context: ?*anyopaque, frames: u32) void {
    const self = coreAudioSession(context) orelse return;
    if (self.ring) |*ring| _ = ring.dropped_frames.fetchAdd(frames, .monotonic);
}

fn coreAudioInvalidate(context: ?*anyopaque, force_failure: bool) void {
    const self = coreAudioSession(context) orelse return;
    self.invalidateCoreAudioRoute(force_failure);
}

fn coreAudioFail(context: ?*anyopaque, _: i32) void {
    const self = coreAudioSession(context) orelse return;
    self.backend_failed.store(true, .release);
    self.accepting.store(false, .release);
}

fn coreAudioBackend(context: *anyopaque) *backend_mod.Backend {
    return @ptrCast(@alignCast(context));
}

fn queryCoreAudioRoute(context: *anyopaque) !RouteSnapshot {
    return coreAudioBackend(context).queryRoute();
}

fn productionCoreAudioReady(context: *anyopaque) bool {
    return coreAudioBackend(context).ready();
}

fn buildCoreAudio(context: *anyopaque, route: RouteSnapshot) !void {
    try coreAudioBackend(context).build(route);
}

fn startCoreAudioUnit(context: *anyopaque) !void {
    try coreAudioBackend(context).start();
}

fn stopCoreAudioUnit(context: *anyopaque) void {
    coreAudioBackend(context).stop();
}

fn disposeCoreAudioResources(context: *anyopaque) void {
    coreAudioBackend(context).dispose();
}

fn convertCoreAudioFrames(context: *anyopaque, input: []const f32, output: []f32) ![]const f32 {
    return coreAudioBackend(context).convert(input, output);
}

const StartTask = struct { self: *AudioSession, session_id: u64, completion: AsyncCompletion };
const StopTask = struct { self: *AudioSession, session_id: u64, completion: AsyncCompletion };
const StartResult = struct { session_id: u64, started_at_ms: u64 };
const StopResult = struct { ok: bool, audio_path: []const u8 = "", frames: u64 = 0, started: u64 = 0, first: u64 = 0, stopped: u64 = 0, dropped: u64 = 0, retry: bool = false, message: []const u8 = "" };

fn startTask(task: *StartTask) void {
    const self = task.self;
    defer {
        _ = self.async_count.fetchSub(1, .acq_rel);
        self.allocator.destroy(task);
    }
    self.mutex.lock();
    const result = self.startLocked(task.session_id);
    self.mutex.unlock();
    if (result) |started| complete(self.allocator, task.completion, true, .{ .ok = true, .sessionId = started.session_id, .captureStartedAtMs = started.started_at_ms, .sampleRate = sample_rate, .channels = 1 }) else |err| complete(self.allocator, task.completion, false, .{ .ok = false, .sessionId = task.session_id, .message = startError(err) });
}

fn stopTask(task: *StopTask) void {
    const self = task.self;
    defer {
        _ = self.async_count.fetchSub(1, .acq_rel);
        self.allocator.destroy(task);
    }
    self.mutex.lock();
    const result = self.stopLocked(task.session_id);
    self.mutex.unlock();
    if (!result.ok) return complete(self.allocator, task.completion, false, .{ .ok = false, .sessionId = task.session_id, .message = result.message });
    complete(self.allocator, task.completion, true, .{ .ok = true, .sessionId = task.session_id, .audioPath = result.audio_path, .capturedFrames = result.frames, .audioDurationMs = result.frames * 1000 / sample_rate, .captureStartedAtMs = result.started, .firstAudioAtMs = result.first, .captureStoppedAtMs = result.stopped, .droppedFrames = result.dropped, .retryAudioAvailable = result.retry });
}

fn platformCapturePush(context: ?*anyopaque, generation: u64, event: native_sdk.AudioCaptureEvent) native_sdk.AudioCapturePushResult {
    const self: *AudioSession = @ptrCast(@alignCast(context orelse return .closed));
    if (generation != self.session_id or !self.accepting.load(.acquire)) return .closed;
    self.route.beginCallbacks(livenessNowMs());
    switch (event.kind) {
        .started => return .accepted,
        .failed => {
            self.backend_failed.store(true, .release);
            self.accepting.store(false, .release);
            return .accepted;
        },
        .data => {},
    }
    if (event.format.sample_rate != 16_000 or event.format.channels != 1 or event.pcm_s16le.len != @as(usize, event.frames) * 2) {
        self.backend_failed.store(true, .release);
        self.accepting.store(false, .release);
        return .dropped_oversized;
    }
    var converted: [320]f32 = undefined;
    var offset: usize = 0;
    var accepted = true;
    while (offset < event.frames) {
        const count = @min(converted.len, @as(usize, event.frames) - offset);
        for (0..count) |index| {
            const byte = (offset + index) * 2;
            const sample = std.mem.readInt(i16, event.pcm_s16le[byte..][0..2], .little);
            converted[index] = @as(f32, @floatFromInt(sample)) / 32768.0;
        }
        if (self.ring) |*ring| accepted = ring.push(converted[0..count]) and accepted else return .closed;
        offset += count;
    }
    return if (accepted) .accepted else .dropped_full;
}

fn jsonInto(output: []u8, value: anytype) !usize {
    const json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, value, .{});
    defer std.heap.c_allocator.free(json);
    if (json.len > output.len) return error.BufferTooSmall;
    @memcpy(output[0..json.len], json);
    return json.len;
}

fn complete(allocator: std.mem.Allocator, completion: AsyncCompletion, ok: bool, value: anytype) void {
    const json = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return completion.complete(completion.context, false, "{\"ok\":false,\"message\":\"Friday could not serialize the audio result.\"}");
    defer allocator.free(json);
    completion.complete(completion.context, ok, json);
}

fn nowMs() u64 {
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &time) != 0) return 0;
    return @as(u64, @intCast(time.tv_sec)) * 1000 + @as(u64, @intCast(time.tv_nsec)) / 1_000_000;
}

fn livenessNowMs() u64 {
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &time) != 0) return 0;
    return @as(u64, @intCast(time.tv_sec)) * 1000 + @as(u64, @intCast(time.tv_nsec)) / 1_000_000;
}

fn startError(err: anyerror) []const u8 {
    return switch (err) {
        error.AlreadyRecording => "A recording is already active.",
        error.TemporaryStorageUnavailable, error.NameTooLong => "Friday could not create temporary audio storage.",
        error.UnconvertibleInputFormat => "The microphone format cannot be converted safely.",
        error.ConverterUnavailable => "Friday could not create the audio converter.",
        error.RouteMonitoringUnavailable => "Friday could not monitor microphone route changes.",
        error.SessionClosing => "The audio session is closing.",
        else => "Friday could not start microphone capture.",
    };
}
fn failureMessage(failure: Failure) []const u8 {
    return switch (failure) {
        .conversion => "Audio conversion failed.",
        .overflow => "Audio input overflowed; recording was stopped.",
        .route => "The microphone route changed during recording.",
        .interruption => "Microphone capture was interrupted.",
        .storage => "Temporary audio storage failed.",
        .callback_liveness => "Microphone callbacks stopped during recording.",
        .event_delivery => "Friday lost the recording lifecycle channel.",
        .none => "Audio capture failed.",
    };
}

const TestCoreAudio = struct {
    route: RouteSnapshot = testRoute(10, 48_000, 1),
    built: bool = false,
    running: bool = false,
    bind_failure: bool = false,
    bound_device: c.AudioDeviceID = c.kAudioObjectUnknown,
    builds: usize = 0,
    disposals: usize = 0,
    starts: usize = 0,
    stops: usize = 0,

    fn from(context: *anyopaque) *TestCoreAudio {
        return @ptrCast(@alignCast(context));
    }

    fn query(context: *anyopaque) anyerror!RouteSnapshot {
        return from(context).route;
    }

    fn ready(context: *anyopaque) bool {
        return from(context).built;
    }

    fn build(context: *anyopaque, route: RouteSnapshot) anyerror!void {
        const self = from(context);
        self.builds += 1;
        if (self.bind_failure) return error.AudioInputUnavailable;
        self.bound_device = route.device;
        self.built = true;
    }

    fn start(context: *anyopaque) anyerror!void {
        const self = from(context);
        if (!self.built) return error.AudioInputUnavailable;
        self.starts += 1;
        self.running = true;
    }

    fn stop(context: *anyopaque) void {
        const self = from(context);
        if (!self.running) return;
        self.stops += 1;
        self.running = false;
    }

    fn dispose(context: *anyopaque) void {
        const self = from(context);
        if (!self.built and !self.running) return;
        self.disposals += 1;
        self.built = false;
        self.running = false;
        self.bound_device = c.kAudioObjectUnknown;
    }

    fn ops() CoreAudioOps {
        return .{ .query_route = query, .ready = ready, .build = build, .start = start, .stop = stop, .dispose = dispose };
    }
};

const TestEventLog = struct {
    accepted: bool = true,
    abort_count: usize = 0,
    count: usize = 0,
    event_len: usize = 0,
    payload_len: usize = 0,
    event: [64]u8 = undefined,
    payload: [512]u8 = undefined,

    fn emit(context: *anyopaque, event: []const u8, payload: []const u8) bool {
        const self: *TestEventLog = @ptrCast(@alignCast(context));
        self.count += 1;
        self.event_len = @min(event.len, self.event.len);
        self.payload_len = @min(payload.len, self.payload.len);
        @memcpy(self.event[0..self.event_len], event[0..self.event_len]);
        @memcpy(self.payload[0..self.payload_len], payload[0..self.payload_len]);
        return self.accepted;
    }

    fn abort(context: *anyopaque, _: u64) void {
        const self: *TestEventLog = @ptrCast(@alignCast(context));
        self.abort_count += 1;
    }
};

fn testRoute(device: c.AudioDeviceID, rate: f64, stream_hash: u64) RouteSnapshot {
    return .{ .device = device, .sample_rate_bits = @bitCast(rate), .stream_hash = stream_hash, .channels = 1 };
}

fn initTestCoreAudioSession(fake: *TestCoreAudio, log: *TestEventLog) !AudioSession {
    _ = c.mkdir("/tmp/friday-audio-core-tests", @as(c_uint, 0o700));
    return .{
        .allocator = std.testing.allocator,
        .sink = .{ .context = log, .emit = TestEventLog.emit, .abort = TestEventLog.abort },
        .store = try store_mod.Store.init(std.testing.allocator, "/tmp/friday-audio-core-tests"),
        .core_audio = backend_mod.Backend.init(std.testing.allocator, .{
            .accepting = coreAudioAccepting,
            .push = coreAudioPush,
            .drop = coreAudioDrop,
            .invalidate_route = coreAudioInvalidate,
            .fail = coreAudioFail,
        }),
        .core_audio_ops = TestCoreAudio.ops(),
        .core_audio_context = fake,
    };
}

fn deinitTestCoreAudioSession(session: *AudioSession) void {
    session.disposeBackend();
    session.store.deinit();
}

fn contractRouteRebuild() !void {
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.prepareCoreAudio();
    try std.testing.expectEqual(@as(c.AudioDeviceID, 10), fake.bound_device);
    fake.route = testRoute(20, 44_100, 2);
    session.invalidateCoreAudioRoute(false);
    try session.startCoreAudio();

    try std.testing.expectEqual(@as(usize, 2), fake.builds);
    try std.testing.expectEqual(@as(usize, 1), fake.disposals);
    try std.testing.expectEqual(@as(usize, 1), fake.starts);
    try std.testing.expectEqual(@as(c.AudioDeviceID, 20), fake.bound_device);
    try std.testing.expectEqual(session.route.current(), session.route.active_generation.load(.acquire));
}

fn contractBindFailure() !void {
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.prepareCoreAudio();
    fake.route = testRoute(20, 48_000, 2);
    fake.bind_failure = true;
    session.invalidateCoreAudioRoute(false);
    try std.testing.expectError(error.AudioInputUnavailable, session.startCoreAudio());

    try std.testing.expectEqual(@as(usize, 2), fake.builds);
    try std.testing.expectEqual(@as(usize, 1), fake.disposals);
    try std.testing.expect(!fake.built);
    try std.testing.expectEqual(@as(c.AudioDeviceID, c.kAudioObjectUnknown), session.device_id);
    try std.testing.expectEqual(@as(u64, 0), session.route.prepared_generation);
    try std.testing.expectEqual(@as(u64, 0), session.route.active_generation.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fake.starts);
}

fn contractWakeRebuild() !void {
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.prepareCoreAudio();
    for (0..5) |_| {
        session.invalidateCoreAudioRoute(false);
        try session.prepareCoreAudio();
    }
    try std.testing.expectEqual(@as(usize, 6), fake.builds);
    try std.testing.expectEqual(@as(usize, 5), fake.disposals);
    try std.testing.expect(fake.built);
    session.disposeCoreAudio();
    try std.testing.expectEqual(fake.builds, fake.disposals);
    try std.testing.expect(!fake.built);
}

const TestCapture = struct {
    sink: native_sdk.AudioCaptureSink = .{},

    fn start(context: ?*anyopaque, source: native_sdk.AudioCaptureSource, format: native_sdk.AudioCaptureFormat, sink: native_sdk.AudioCaptureSink) anyerror!void {
        const self: *TestCapture = @ptrCast(@alignCast(context.?));
        self.sink = sink;
        _ = sink.push(.{ .kind = .started, .source = source, .format = format });
    }

    fn stop(context: ?*anyopaque, source: native_sdk.AudioCaptureSource) anyerror!void {
        _ = source;
        const self: *TestCapture = @ptrCast(@alignCast(context.?));
        self.sink = .{};
    }
};

const TestCompletion = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ok: bool = false,
    length: usize = 0,
    bytes: [1024]u8 = undefined,

    fn callback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const self: *TestCompletion = @ptrCast(@alignCast(context));
        self.ok = ok;
        self.length = @min(bytes.len, self.bytes.len);
        @memcpy(self.bytes[0..self.length], bytes[0..self.length]);
        self.done.store(true, .release);
    }

    fn wait(self: *TestCompletion) !void {
        var attempts: usize = 0;
        while (!self.done.load(.acquire) and attempts < 5000) : (attempts += 1) _ = c.usleep(1000);
        if (!self.done.load(.acquire)) return error.TestTimedOut;
    }
};

fn ignoreEvent(context: *anyopaque, event: []const u8, payload: []const u8) bool {
    _ = context;
    _ = event;
    _ = payload;
    return true;
}

fn ignoreAbort(context: *anyopaque, session_id: u64) void {
    _ = context;
    _ = session_id;
}

fn contractPlatformCapture() !void {
    const root: [:0]const u8 = "/tmp/friday-audio-zig-test";
    _ = c.mkdir(root.ptr, @as(c_uint, 0o700));
    defer {
        _ = c.rmdir("/tmp/friday-audio-zig-test/Audio");
        _ = c.rmdir(root.ptr);
    }
    var sink_context: u8 = 0;
    var session = try AudioSession.init(std.testing.allocator, root, .{ .context = &sink_context, .emit = ignoreEvent, .abort = ignoreAbort });
    defer session.deinit();
    var capture = TestCapture{};
    const services = native_sdk.platform.PlatformServices{
        .context = &capture,
        .audio_capture_start_fn = TestCapture.start,
        .audio_capture_stop_fn = TestCapture.stop,
    };
    session.setServices(services);

    var start = TestCompletion{};
    try session.startSession(77, .{ .context = &start, .complete = TestCompletion.callback });
    try start.wait();
    try std.testing.expect(start.ok);

    var pcm: [320]u8 = @splat(0);
    for (0..160) |index| std.mem.writeInt(i16, pcm[index * 2 ..][0..2], @intCast(@as(i32, @intCast(index)) - 80), .little);
    try std.testing.expectEqual(native_sdk.AudioCapturePushResult.accepted, capture.sink.push(.{
        .kind = .data,
        .source = .microphone,
        .format = .{ .sample_rate = 16_000, .channels = 1 },
        .frames = 160,
        .pcm_s16le = &pcm,
    }));

    var stop = TestCompletion{};
    try session.stopSession(77, .{ .context = &stop, .complete = TestCompletion.callback });
    try stop.wait();
    try std.testing.expect(stop.ok);
    try std.testing.expect(std.mem.indexOf(u8, stop.bytes[0..stop.length], "\"capturedFrames\":160") != null);
    const retry = session.retryAudioPath() orelse return error.MissingRetryAudio;
    var attributes = std.mem.zeroes(c.struct_stat);
    var retry_z: [path_capacity]u8 = @splat(0);
    @memcpy(retry_z[0..retry.len], retry);
    try std.testing.expectEqual(@as(c_int, 0), c.stat(@ptrCast(&retry_z), &attributes));
    try std.testing.expectEqual(@as(c.off_t, 160 * @sizeOf(f32)), attributes.st_size);
    session.discardRetryAudio();
}

/// Runs through the same adapter and store seams used in production.
pub fn testContracts() !void {
    try backend_mod.testContracts();
    try route_mod.testContracts();
    try store_mod.testContracts();
    try contractRouteRebuild();
    try contractBindFailure();
    try contractWakeRebuild();
    try contractPlatformCapture();
}

test "audio module contracts" {
    try testContracts();
}
