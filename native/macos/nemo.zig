const std = @import("std");

const c = @cImport({
    @cInclude("nemo_speech/asr.h");
    @cInclude("sys/resource.h");
    @cInclude("pthread.h");
    @cInclude("fcntl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
});

extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;

/// Completion runs on the recognizer's serial worker. `json` is valid only for
/// the duration of the call and must be copied by a receiver that retains it.
/// `ok` is identical to the JSON object's `ok` field. Every successfully
/// submitted operation invokes its completion exactly once; no host run-loop
/// pumping is required. A completion may submit work, but must not call
/// `deinit` or `shutdownAndWait`, since those fence the worker.
pub const AsyncCompletion = struct {
    context: *anyopaque,
    complete: *const fn (context: *anyopaque, ok: bool, json: []const u8) void,
};

pub const NemoRecognizer = struct {
    const Self = @This();

    state: *State,

    pub const SubmitError = std.mem.Allocator.Error || error{ShuttingDown};

    /// Returns a movable value whose worker state has a stable heap address.
    pub fn init(allocator: std.mem.Allocator) !Self {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator };
        if (c.pthread_mutex_init(&state.mutex, null) != 0) return error.SystemResources;
        errdefer _ = c.pthread_mutex_destroy(&state.mutex);
        if (c.pthread_cond_init(&state.condition, null) != 0) return error.SystemResources;
        errdefer _ = c.pthread_cond_destroy(&state.condition);
        state.thread = try std.Thread.spawn(.{}, State.workerMain, .{state});
        return .{ .state = state };
    }

    pub fn deinit(self: *Self) void {
        self.shutdownAndWait();
        const allocator = self.state.allocator;
        _ = c.pthread_cond_destroy(&self.state.condition);
        _ = c.pthread_mutex_destroy(&self.state.mutex);
        allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Borrowed until the next successful activation, unload, or shutdown.
    pub fn activeModelPath(self: *Self) ?[]const u8 {
        const state = self.state;
        state.lock();
        defer state.unlock();
        const path = state.active_model_path orelse return null;
        return path;
    }

    pub fn isBusy(self: *const Self) bool {
        return self.state.pending_transcriptions.load(.acquire) != 0;
    }

    /// Runtime-probes and then activates a model on the serial worker.
    pub fn activateModel(self: *Self, path: []const u8, generation: u64, completion: AsyncCompletion) SubmitError!void {
        try self.state.submitActivation(path, generation, completion);
    }

    /// Transcribes a native-endian mono Float32 file at 16 kHz. The worker uses
    /// a read-only mmap so the audio hot path does not allocate or copy samples.
    pub fn transcribeAudio(self: *Self, path: []const u8, session_id: u64, generation: u64, completion: AsyncCompletion) SubmitError!void {
        try self.state.submitTranscription(path, session_id, generation, completion);
    }

    /// Generations are monotonic. Cancelling generation N suppresses callbacks
    /// from N and all older queued or in-flight operations as stale.
    pub fn cancelGeneration(self: *Self, generation: u64) void {
        const state = self.state;
        state.lock();
        defer state.unlock();
        if (!state.has_cancelled_generation or generation > state.cancelled_through_generation) {
            state.has_cancelled_generation = true;
            state.cancelled_through_generation = generation;
        }
    }

    /// Queues handle destruction behind all work already accepted by the worker.
    pub fn unload(self: *Self, completion: AsyncCompletion) SubmitError!void {
        try self.state.submitUnload(completion);
    }

    /// Stops submissions, drains accepted callbacks, destroys the handle on its
    /// owning worker, and waits for exit. Safe for concurrent non-worker calls.
    pub fn shutdownAndWait(self: *Self) void {
        self.state.shutdownAndWait();
    }

    /// Synchronous standalone runtime probe. The candidate is always destroyed.
    pub fn probeModel(path: []const u8) !bool {
        const terminated = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(terminated);
        var backend = std.mem.zeroes(c.nemo_speech_asr_backend_config);
        backend.size = @sizeOf(c.nemo_speech_asr_backend_config);
        backend.gpu = 0;
        var model = std.mem.zeroes(c.nemo_speech_asr_model_config);
        model.size = @sizeOf(c.nemo_speech_asr_model_config);
        model.path = terminated.ptr;
        var config = std.mem.zeroes(c.nemo_speech_asr_recognizer_config);
        config.size = @sizeOf(c.nemo_speech_asr_recognizer_config);
        config.backend = &backend;
        config.model = &model;
        var candidate: ?*c.nemo_speech_asr_recognizer = null;
        const status = c.nemo_speech_asr_create(&config, &candidate);
        defer if (candidate) |recognizer| c.nemo_speech_asr_destroy(recognizer);
        return status == c.NEMO_SPEECH_ASR_OK and candidate != null;
    }
};

const State = struct {
    const sample_rate: i32 = 16_000;
    const ActivateOperation = struct { path: ?[:0]u8, generation: u64, completion: AsyncCompletion };
    const TranscribeOperation = struct { path: [:0]u8, session_id: u64, generation: u64, completion: AsyncCompletion };
    const Operation = union(enum) { activate: ActivateOperation, transcribe: TranscribeOperation, unload: AsyncCompletion };
    const Request = struct { next: ?*Request = null, operation: Operation };

    allocator: std.mem.Allocator,
    mutex: c.pthread_mutex_t = undefined,
    condition: c.pthread_cond_t = undefined,
    head: ?*Request = null,
    tail: ?*Request = null,
    accepting: bool = true,
    closing: bool = false,
    shutdown_complete: bool = false,
    worker_id: ?std.Thread.Id = null,
    thread: ?std.Thread = null,
    recognizer: ?*c.nemo_speech_asr_recognizer = null,
    active_model_path: ?[:0]u8 = null,
    pending_transcriptions: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    has_cancelled_generation: bool = false,
    cancelled_through_generation: u64 = 0,

    fn submitActivation(state: *State, path: []const u8, generation: u64, completion: AsyncCompletion) NemoRecognizer.SubmitError!void {
        const owned_path = try state.allocator.dupeZ(u8, path);
        errdefer state.allocator.free(owned_path);
        const request = try state.allocator.create(Request);
        errdefer state.allocator.destroy(request);
        request.* = .{ .operation = .{ .activate = .{ .path = owned_path, .generation = generation, .completion = completion } } };
        try state.enqueue(request, false);
    }

    fn submitTranscription(state: *State, path: []const u8, session_id: u64, generation: u64, completion: AsyncCompletion) NemoRecognizer.SubmitError!void {
        const owned_path = try state.allocator.dupeZ(u8, path);
        errdefer state.allocator.free(owned_path);
        const request = try state.allocator.create(Request);
        errdefer state.allocator.destroy(request);
        request.* = .{ .operation = .{ .transcribe = .{ .path = owned_path, .session_id = session_id, .generation = generation, .completion = completion } } };
        try state.enqueue(request, true);
    }

    fn submitUnload(state: *State, completion: AsyncCompletion) NemoRecognizer.SubmitError!void {
        const request = try state.allocator.create(Request);
        errdefer state.allocator.destroy(request);
        request.* = .{ .operation = .{ .unload = completion } };
        try state.enqueue(request, false);
    }

    fn enqueue(state: *State, request: *Request, transcription: bool) error{ShuttingDown}!void {
        state.lock();
        defer state.unlock();
        if (!state.accepting) return error.ShuttingDown;
        if (state.tail) |tail| tail.next = request else state.head = request;
        state.tail = request;
        if (transcription) _ = state.pending_transcriptions.fetchAdd(1, .release);
        state.signal();
    }

    fn shutdownAndWait(state: *State) void {
        const current_id = std.Thread.getCurrentId();
        state.lock();
        if (state.worker_id != null and state.worker_id.? == current_id) {
            state.unlock();
            @panic("NemoRecognizer.shutdownAndWait cannot run on its completion worker");
        }
        if (state.shutdown_complete) {
            state.unlock();
            return;
        }
        if (state.closing) {
            while (!state.shutdown_complete) state.wait();
            state.unlock();
            return;
        }
        state.accepting = false;
        state.closing = true;
        const thread = state.thread.?;
        state.broadcast();
        state.unlock();
        thread.join();
        state.lock();
        state.thread = null;
        state.shutdown_complete = true;
        state.broadcast();
        state.unlock();
    }

    fn workerMain(state: *State) void {
        state.lock();
        state.worker_id = std.Thread.getCurrentId();
        state.unlock();
        while (true) {
            state.lock();
            while (state.head == null and !state.closing) state.wait();
            const request = state.head orelse {
                state.unlock();
                break;
            };
            state.head = request.next;
            if (state.head == null) state.tail = null;
            state.unlock();
            state.process(request);
        }
        state.destroyRecognizerOnWorker();
    }

    fn process(state: *State, request: *Request) void {
        defer state.allocator.destroy(request);
        switch (request.operation) {
            .activate => |*operation| {
                defer if (operation.path) |path| state.allocator.free(path);
                state.activateOnWorker(operation);
            },
            .transcribe => |operation| {
                defer state.allocator.free(operation.path);
                state.transcribeOnWorker(operation);
            },
            .unload => |completion| {
                state.destroyRecognizerOnWorker();
                state.deliver(completion, .unloaded);
            },
        }
    }

    fn activateOnWorker(state: *State, operation: *ActivateOperation) void {
        const started = nowMs();
        var backend = std.mem.zeroes(c.nemo_speech_asr_backend_config);
        backend.size = @sizeOf(c.nemo_speech_asr_backend_config);
        backend.gpu = 0;
        var model = std.mem.zeroes(c.nemo_speech_asr_model_config);
        model.size = @sizeOf(c.nemo_speech_asr_model_config);
        model.path = operation.path.?.ptr;
        var config = std.mem.zeroes(c.nemo_speech_asr_recognizer_config);
        config.size = @sizeOf(c.nemo_speech_asr_recognizer_config);
        config.backend = &backend;
        config.model = &model;
        var candidate: ?*c.nemo_speech_asr_recognizer = null;
        const status = c.nemo_speech_asr_create(&config, &candidate);
        if (state.isCancelled(operation.generation)) {
            if (candidate) |handle| c.nemo_speech_asr_destroy(handle);
            state.deliver(operation.completion, .{ .activation_cancelled = operation.generation });
            return;
        }
        if (status != c.NEMO_SPEECH_ASR_OK or candidate == null) {
            defer if (candidate) |handle| c.nemo_speech_asr_destroy(handle);
            state.deliver(operation.completion, .{ .activation_failed = .{ .generation = operation.generation, .message = lastError("The model failed its NeMo runtime probe.") } });
            return;
        }
        if (state.recognizer) |old| c.nemo_speech_asr_destroy(old);
        state.recognizer = candidate;
        state.lock();
        if (state.active_model_path) |old_path| state.allocator.free(old_path);
        state.active_model_path = operation.path.?;
        operation.path = null;
        state.unlock();
        const finished = nowMs();
        state.deliver(operation.completion, .{ .activation_succeeded = .{ .generation = operation.generation, .load_duration_ms = finished -| started, .resident_bytes = residentBytes() } });
    }

    fn transcribeOnWorker(state: *State, operation: TranscribeOperation) void {
        const started = nowMs();
        if (state.isCancelled(operation.generation)) {
            state.completeTranscription(operation, .{ .transcription_cancelled = ids(operation) });
            return;
        }
        const recognizer = state.recognizer orelse {
            state.completeTranscription(operation, .{ .model_unavailable = ids(operation) });
            return;
        };
        var audio = MappedAudio.open(operation.path) catch {
            state.completeTranscription(operation, .{ .audio_unavailable = ids(operation) });
            return;
        };
        defer audio.deinit();
        const samples = audio.samples();
        var energy: f64 = 0;
        var peak: f32 = 0;
        for (samples) |sample| {
            energy += @as(f64, sample) * @as(f64, sample);
            const magnitude = @abs(sample);
            if (magnitude > peak) peak = magnitude;
        }
        if (state.isCancelled(operation.generation)) {
            state.completeTranscription(operation, .{ .transcription_cancelled = ids(operation) });
            return;
        }
        const rms = @sqrt(energy / @as(f64, @floatFromInt(samples.len)));
        if (rms < 0.0015 or peak < 0.008) {
            state.completeTranscription(operation, .{ .silence = .{ .ids = ids(operation), .started = started, .finished = nowMs() } });
            return;
        }
        var options = c.nemo_speech_asr_recognition_options_default();
        options.interim_results = false;
        options.enable_automatic_punctuation = true;
        var native_result: ?*c.nemo_speech_asr_result = null;
        const status = c.nemo_speech_asr_recognize_f32(recognizer, &options, samples.ptr, samples.len, sample_rate, &native_result);
        const finished = nowMs();
        if (state.isCancelled(operation.generation)) {
            if (native_result) |result| c.nemo_speech_asr_result_destroy(result);
            state.completeTranscription(operation, .{ .transcription_cancelled = ids(operation) });
            return;
        }
        if (status != c.NEMO_SPEECH_ASR_OK or native_result == null) {
            defer if (native_result) |result| c.nemo_speech_asr_result_destroy(result);
            state.completeTranscription(operation, .{ .transcription_failed = .{ .ids = ids(operation), .message = lastError("Local transcription failed."), .started = started, .finished = finished } });
            return;
        }
        const result = native_result.?;
        defer c.nemo_speech_asr_result_destroy(result);
        var transcript: []const u8 = "";
        if (c.nemo_speech_asr_result_is_final(result) and c.nemo_speech_asr_result_alternative_count(result) != 0) {
            const raw = c.nemo_speech_asr_result_transcript(result, 0);
            if (raw != null) {
                const value = std.mem.span(raw);
                if (std.unicode.utf8ValidateSlice(value)) transcript = value;
            }
        }
        state.completeTranscription(operation, .{ .transcription_succeeded = .{ .ids = ids(operation), .text = transcript, .audio_duration_ms = @intCast(samples.len / 16), .started = started, .finished = finished, .resident_bytes = residentBytes() } });
    }

    fn completeTranscription(state: *State, operation: TranscribeOperation, result: Result) void {
        _ = state.pending_transcriptions.fetchSub(1, .release);
        if (state.isCancelled(operation.generation) and result != .transcription_cancelled) {
            state.deliver(operation.completion, .{ .transcription_cancelled = ids(operation) });
        } else state.deliver(operation.completion, result);
    }

    fn deliver(state: *State, completion: AsyncCompletion, result: Result) void {
        _ = state;
        var output: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer output.deinit();
        result.writeJson(&output.writer) catch {
            completion.complete(completion.context, false, "{\"ok\":false,\"code\":\"serialization_failed\",\"message\":\"The recognizer result could not be serialized.\"}");
            return;
        };
        completion.complete(completion.context, result.ok(), output.written());
    }

    fn isCancelled(state: *State, generation: u64) bool {
        state.lock();
        defer state.unlock();
        return state.has_cancelled_generation and generation <= state.cancelled_through_generation;
    }

    fn destroyRecognizerOnWorker(state: *State) void {
        if (state.recognizer) |recognizer| {
            c.nemo_speech_asr_destroy(recognizer);
            state.recognizer = null;
        }
        state.lock();
        if (state.active_model_path) |path| state.allocator.free(path);
        state.active_model_path = null;
        state.unlock();
    }
    fn lock(state: *State) void {
        if (c.pthread_mutex_lock(&state.mutex) != 0) @panic("pthread_mutex_lock failed");
    }

    fn unlock(state: *State) void {
        if (c.pthread_mutex_unlock(&state.mutex) != 0) @panic("pthread_mutex_unlock failed");
    }

    fn wait(state: *State) void {
        if (c.pthread_cond_wait(&state.condition, &state.mutex) != 0) @panic("pthread_cond_wait failed");
    }

    fn signal(state: *State) void {
        if (c.pthread_cond_signal(&state.condition) != 0) @panic("pthread_cond_signal failed");
    }

    fn broadcast(state: *State) void {
        if (c.pthread_cond_broadcast(&state.condition) != 0) @panic("pthread_cond_broadcast failed");
    }
};

const Ids = struct { session_id: u64, generation: u64 };
const TimedIds = struct { ids: Ids, started: u64, finished: u64 };
const Result = union(enum) {
    activation_cancelled: u64,
    activation_failed: struct { generation: u64, message: []const u8 },
    activation_succeeded: struct { generation: u64, load_duration_ms: u64, resident_bytes: u64 },
    transcription_cancelled: Ids,
    model_unavailable: Ids,
    audio_unavailable: Ids,
    transcription_failed: struct { ids: Ids, message: []const u8, started: u64, finished: u64 },
    silence: TimedIds,
    transcription_succeeded: struct { ids: Ids, text: []const u8, audio_duration_ms: u64, started: u64, finished: u64, resident_bytes: u64 },
    unloaded,

    fn ok(result: Result) bool {
        return switch (result) {
            .activation_succeeded, .silence, .transcription_succeeded, .unloaded => true,
            else => false,
        };
    }

    fn writeJson(result: Result, writer: *std.Io.Writer) !void {
        switch (result) {
            .activation_cancelled => |generation| try writer.print("{{\"ok\":false,\"cancelled\":true,\"generation\":{d},\"code\":\"cancelled\"}}", .{generation}),
            .activation_failed => |value| {
                try writer.print("{{\"ok\":false,\"generation\":{d},\"code\":\"model_probe_failed\",\"message\":", .{value.generation});
                try writeJsonString(writer, value.message);
                try writer.writeAll("}");
            },
            .activation_succeeded => |value| try writer.print("{{\"ok\":true,\"generation\":{d},\"loadDurationMs\":{d},\"residentBytes\":{d},\"message\":\"The model is warm and ready.\"}}", .{ value.generation, value.load_duration_ms, value.resident_bytes }),
            .transcription_cancelled => |value| try writer.print("{{\"ok\":false,\"cancelled\":true,\"sessionId\":{d},\"generation\":{d},\"code\":\"cancelled\"}}", .{ value.session_id, value.generation }),
            .model_unavailable => |value| try writer.print("{{\"ok\":false,\"sessionId\":{d},\"generation\":{d},\"code\":\"model_unavailable\",\"message\":\"The active model is not loaded.\"}}", .{ value.session_id, value.generation }),
            .audio_unavailable => |value| try writer.print("{{\"ok\":false,\"sessionId\":{d},\"generation\":{d},\"code\":\"audio_unavailable\",\"message\":\"Retry audio is unavailable.\"}}", .{ value.session_id, value.generation }),
            .transcription_failed => |value| {
                try writer.print("{{\"ok\":false,\"sessionId\":{d},\"generation\":{d},\"code\":\"transcription_failed\",\"message\":", .{ value.ids.session_id, value.ids.generation });
                try writeJsonString(writer, value.message);
                try writer.print(",\"retryAudioAvailable\":true,\"inferenceStartedAtMs\":{d},\"transcriptReadyAtMs\":{d}}}", .{ value.started, value.finished });
            },
            .silence => |value| try writer.print("{{\"ok\":true,\"sessionId\":{d},\"generation\":{d},\"text\":\"\",\"silence\":true,\"inferenceStartedAtMs\":{d},\"transcriptReadyAtMs\":{d}}}", .{ value.ids.session_id, value.ids.generation, value.started, value.finished }),
            .transcription_succeeded => |value| {
                try writer.print("{{\"ok\":true,\"sessionId\":{d},\"generation\":{d},\"text\":", .{ value.ids.session_id, value.ids.generation });
                try writeJsonString(writer, value.text);
                try writer.print(",\"silence\":{s},\"audioDurationMs\":{d},\"inferenceStartedAtMs\":{d},\"transcriptReadyAtMs\":{d},\"latencyMs\":{d},\"residentBytes\":{d},\"retryAudioAvailable\":true}}", .{ if (value.text.len == 0) "true" else "false", value.audio_duration_ms, value.started, value.finished, value.finished -| value.started, value.resident_bytes });
            },
            .unloaded => try writer.writeAll("{\"ok\":true,\"message\":\"NeMo recognizer unloaded.\"}"),
        }
    }
};

const MappedAudio = struct {
    address: *anyopaque,
    byte_count: usize,

    fn open(path: [:0]const u8) !MappedAudio {
        const fd = c.open(path.ptr, c.O_RDONLY);
        if (fd < 0) return error.AudioUnavailable;
        defer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0) return error.AudioUnavailable;
        const byte_count = std.math.cast(usize, stat.st_size) orelse return error.AudioUnavailable;
        if (byte_count % @sizeOf(f32) != 0) return error.AudioUnavailable;
        const mapped = c.mmap(null, byte_count, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (mapped == c.MAP_FAILED) return error.AudioUnavailable;
        return .{ .address = mapped.?, .byte_count = byte_count };
    }

    fn deinit(audio: *MappedAudio) void {
        _ = c.munmap(audio.address, audio.byte_count);
        audio.* = undefined;
    }

    fn samples(audio: *const MappedAudio) []const f32 {
        const pointer: [*]align(@alignOf(f32)) const f32 = @ptrCast(@alignCast(audio.address));
        return pointer[0 .. audio.byte_count / @sizeOf(f32)];
    }
};

fn ids(operation: State.TranscribeOperation) Ids {
    return .{ .session_id = operation.session_id, .generation = operation.generation };
}

fn nowMs() u64 {
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &time) != 0 or time.tv_sec < 0) return 0;
    const seconds: u64 = @intCast(time.tv_sec);
    const rounded_milliseconds: u64 = @intCast(@divTrunc(time.tv_nsec + 500_000, 1_000_000));
    return seconds * 1000 + rounded_milliseconds;
}

fn residentBytes() u64 {
    var info = std.mem.zeroes(c.struct_rusage_info_v4);
    const status = proc_pid_rusage(c.getpid(), c.RUSAGE_INFO_V4, @ptrCast(&info));
    return if (status == 0) info.ri_phys_footprint else 0;
}

fn lastError(fallback: []const u8) []const u8 {
    const raw = c.nemo_speech_asr_last_error();
    if (raw == null or raw[0] == 0) return fallback;
    const value = std.mem.span(raw);
    return if (std.unicode.utf8ValidateSlice(value)) value else fallback;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("\"");
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        const escape: ?[]const u8 = switch (byte) {
            '\"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0c => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escape) |sequence| {
            try writer.writeAll(value[start..index]);
            try writer.writeAll(sequence);
            start = index + 1;
        } else if (byte < 0x20) {
            try writer.writeAll(value[start..index]);
            try writer.print("\\u{x:0>4}", .{byte});
            start = index + 1;
        }
    }
    try writer.writeAll(value[start..]);
    try writer.writeAll("\"");
}

test "cancelled transcription JSON contract" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try (Result{ .transcription_cancelled = .{ .session_id = 42, .generation = 17 } }).writeJson(&output.writer);
    try std.testing.expectEqualStrings("{\"ok\":false,\"cancelled\":true,\"sessionId\":42,\"generation\":17,\"code\":\"cancelled\"}", output.written());
}

test "final transcript JSON escaping and metrics contract" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try (Result{ .transcription_succeeded = .{ .ids = .{ .session_id = 9, .generation = 3 }, .text = "say \"hello\"\n", .audio_duration_ms = 1000, .started = 10, .finished = 25, .resident_bytes = 4096 } }).writeJson(&output.writer);
    try std.testing.expectEqualStrings("{\"ok\":true,\"sessionId\":9,\"generation\":3,\"text\":\"say \\\"hello\\\"\\n\",\"silence\":false,\"audioDurationMs\":1000,\"inferenceStartedAtMs\":10,\"transcriptReadyAtMs\":25,\"latencyMs\":15,\"residentBytes\":4096,\"retryAudioAvailable\":true}", output.written());
}
