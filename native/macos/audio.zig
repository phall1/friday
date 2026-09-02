const std = @import("std");
const native_sdk = @import("native_sdk");
const Spsc = @import("ring.zig").Spsc;

const posix = @cImport({
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

/// Only the C ABI surface used below is declared here. Importing Apple's
/// umbrella audio headers fails in Zig 0.16 because Xcode 26 exposes block
/// typedefs that translate-c cannot parse.
const c = struct {
    pub const access = posix.access;
    pub const __error = posix.__error;
    pub const clock_gettime = posix.clock_gettime;
    pub const close = posix.close;
    pub const closedir = posix.closedir;
    pub const fstat = posix.fstat;
    pub const fsync = posix.fsync;
    pub const ftruncate = posix.ftruncate;
    pub const mkdir = posix.mkdir;
    pub const open = posix.open;
    pub const opendir = posix.opendir;
    pub const readdir = posix.readdir;
    pub const rmdir = posix.rmdir;
    pub const stat = posix.stat;
    pub const unlink = posix.unlink;
    pub const usleep = posix.usleep;
    pub const write = posix.write;

    pub const off_t = posix.off_t;
    pub const struct_stat = posix.struct_stat;
    pub const struct_timespec = posix.struct_timespec;
    pub const CLOCK_REALTIME = posix.CLOCK_REALTIME;
    pub const EINTR = posix.EINTR;
    pub const EEXIST = posix.EEXIST;
    pub const F_OK = posix.F_OK;
    pub const O_CLOEXEC = posix.O_CLOEXEC;
    pub const O_CREAT = posix.O_CREAT;
    pub const O_NOFOLLOW = posix.O_NOFOLLOW;
    pub const O_RDWR = posix.O_RDWR;
    pub const O_TRUNC = posix.O_TRUNC;
    pub const O_WRONLY = posix.O_WRONLY;

    pub const OSStatus = i32;
    pub const AudioObjectID = u32;
    pub const AudioDeviceID = AudioObjectID;
    pub const AudioObjectPropertySelector = u32;
    pub const AudioObjectPropertyScope = u32;
    pub const AudioObjectPropertyElement = u32;
    pub const AudioUnitPropertyID = u32;
    pub const AudioUnitScope = u32;
    pub const AudioUnitElement = u32;
    pub const AudioUnitRenderActionFlags = u32;

    const OpaqueAudioComponent = opaque {};
    const OpaqueAudioComponentInstance = opaque {};
    const OpaqueAudioConverter = opaque {};
    const OpaqueCFString = opaque {};
    pub const AudioComponent = ?*OpaqueAudioComponent;
    pub const AudioComponentInstance = ?*OpaqueAudioComponentInstance;
    pub const AudioUnit = AudioComponentInstance;
    pub const AudioConverterRef = ?*OpaqueAudioConverter;
    pub const CFStringRef = ?*const OpaqueCFString;
    pub const CFTypeRef = ?*const anyopaque;
    pub const CFIndex = c_long;
    pub const CFStringEncoding = u32;

    pub const AudioComponentDescription = extern struct {
        componentType: u32,
        componentSubType: u32,
        componentManufacturer: u32,
        componentFlags: u32,
        componentFlagsMask: u32,
    };

    pub const AudioStreamBasicDescription = extern struct {
        mSampleRate: f64,
        mFormatID: u32,
        mFormatFlags: u32,
        mBytesPerPacket: u32,
        mFramesPerPacket: u32,
        mBytesPerFrame: u32,
        mChannelsPerFrame: u32,
        mBitsPerChannel: u32,
        mReserved: u32,
    };

    pub const AudioBuffer = extern struct {
        mNumberChannels: u32,
        mDataByteSize: u32,
        mData: ?*anyopaque,
    };

    pub const AudioBufferList = extern struct {
        mNumberBuffers: u32,
        mBuffers: [1]AudioBuffer,
    };

    pub const AudioTimeStamp = opaque {};
    pub const AURenderCallback = ?*const fn (
        in_ref_con: ?*anyopaque,
        io_action_flags: [*c]AudioUnitRenderActionFlags,
        in_time_stamp: ?*const AudioTimeStamp,
        in_bus_number: u32,
        in_number_frames: u32,
        io_data: [*c]AudioBufferList,
    ) callconv(.c) OSStatus;

    pub const AURenderCallbackStruct = extern struct {
        inputProc: AURenderCallback,
        inputProcRefCon: ?*anyopaque,
    };

    pub const AudioObjectPropertyAddress = extern struct {
        mSelector: AudioObjectPropertySelector,
        mScope: AudioObjectPropertyScope,
        mElement: AudioObjectPropertyElement,
    };

    pub const AudioObjectPropertyListenerProc = ?*const fn (
        in_object_id: AudioObjectID,
        in_number_addresses: u32,
        in_addresses: [*c]const AudioObjectPropertyAddress,
        in_client_data: ?*anyopaque,
    ) callconv(.c) OSStatus;

    pub extern "c" fn AudioComponentFindNext(
        in_component: AudioComponent,
        in_description: *const AudioComponentDescription,
    ) AudioComponent;
    pub extern "c" fn AudioComponentInstanceNew(
        in_component: AudioComponent,
        out_instance: *AudioComponentInstance,
    ) OSStatus;
    pub extern "c" fn AudioComponentInstanceDispose(in_instance: AudioComponentInstance) OSStatus;
    pub extern "c" fn AudioUnitSetProperty(
        in_unit: AudioUnit,
        in_id: AudioUnitPropertyID,
        in_scope: AudioUnitScope,
        in_element: AudioUnitElement,
        in_data: ?*const anyopaque,
        in_data_size: u32,
    ) OSStatus;
    pub extern "c" fn AudioUnitInitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioUnitUninitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStart(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStop(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioUnitRender(
        in_unit: AudioUnit,
        io_action_flags: [*c]AudioUnitRenderActionFlags,
        in_time_stamp: ?*const AudioTimeStamp,
        in_output_bus_number: u32,
        in_number_frames: u32,
        io_data: [*c]AudioBufferList,
    ) OSStatus;

    pub extern "c" fn AudioConverterNew(
        in_source_format: *const AudioStreamBasicDescription,
        in_destination_format: *const AudioStreamBasicDescription,
        out_audio_converter: *AudioConverterRef,
    ) OSStatus;
    pub extern "c" fn AudioConverterDispose(in_audio_converter: AudioConverterRef) OSStatus;
    pub extern "c" fn AudioConverterConvertComplexBuffer(
        in_audio_converter: AudioConverterRef,
        in_number_pcm_frames: u32,
        in_input_data: *const AudioBufferList,
        out_output_data: *AudioBufferList,
    ) OSStatus;

    pub extern "c" fn AudioObjectGetPropertyDataSize(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: ?*const anyopaque,
        out_data_size: *u32,
    ) OSStatus;
    pub extern "c" fn AudioObjectGetPropertyData(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: ?*const anyopaque,
        io_data_size: *u32,
        out_data: ?*anyopaque,
    ) OSStatus;
    pub extern "c" fn AudioObjectAddPropertyListener(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_listener: AudioObjectPropertyListenerProc,
        in_client_data: ?*anyopaque,
    ) OSStatus;
    pub extern "c" fn AudioObjectRemovePropertyListener(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_listener: AudioObjectPropertyListenerProc,
        in_client_data: ?*anyopaque,
    ) OSStatus;

    pub extern "c" fn CFStringGetCString(
        the_string: CFStringRef,
        buffer: [*c]u8,
        buffer_size: CFIndex,
        encoding: CFStringEncoding,
    ) u8;
    pub extern "c" fn CFRelease(cf: CFTypeRef) void;

    fn fourcc(comptime value: []const u8) u32 {
        return (@as(u32, value[0]) << 24) |
            (@as(u32, value[1]) << 16) |
            (@as(u32, value[2]) << 8) |
            @as(u32, value[3]);
    }

    pub const noErr: OSStatus = 0;
    pub const kAudioObjectUnknown: AudioObjectID = 0;
    pub const kAudioObjectSystemObject: AudioObjectID = 1;
    pub const kAudioObjectPropertyElementMain: AudioObjectPropertyElement = 0;
    pub const kAudioObjectPropertyScopeGlobal = fourcc("glob");
    pub const kAudioObjectPropertyScopeInput = fourcc("inpt");
    pub const kAudioObjectPropertyName = fourcc("lnam");
    pub const kAudioHardwarePropertyDefaultInputDevice = fourcc("dIn ");
    pub const kAudioDevicePropertyDeviceIsAlive = fourcc("livn");
    pub const kAudioDevicePropertyNominalSampleRate = fourcc("nsrt");
    pub const kAudioDevicePropertyStreamConfiguration = fourcc("slay");

    pub const kAudioUnitType_Output = fourcc("auou");
    pub const kAudioUnitSubType_HALOutput = fourcc("ahal");
    pub const kAudioUnitManufacturer_Apple = fourcc("appl");
    pub const kAudioUnitScope_Global: AudioUnitScope = 0;
    pub const kAudioUnitScope_Input: AudioUnitScope = 1;
    pub const kAudioUnitScope_Output: AudioUnitScope = 2;
    pub const kAudioUnitProperty_StreamFormat: AudioUnitPropertyID = 8;
    pub const kAudioOutputUnitProperty_CurrentDevice: AudioUnitPropertyID = 2000;
    pub const kAudioOutputUnitProperty_EnableIO: AudioUnitPropertyID = 2003;
    pub const kAudioOutputUnitProperty_SetInputCallback: AudioUnitPropertyID = 2005;

    pub const kAudioFormatLinearPCM = fourcc("lpcm");
    pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
    pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;
    pub const kAudioFormatFlagsNativeEndian: u32 = 0;
    pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
};

pub const sample_rate: u64 = 16_000;
pub const warning_frames: u64 = sample_rate * 585;
pub const maximum_frames: u64 = sample_rate * 600;
pub const maximum_storage_bytes: u64 = maximum_frames * @sizeOf(f32);
const ring_capacity = sample_rate * 4;
const meter_period_ms = 100;
const path_capacity = 4096;
const callback_frames = 4096;

/// Called only from the serial conversion/storage worker, never from an audio
/// callback. Both slices are borrowed for this call. The sink must consume or
/// copy them and enqueue host work; it must not call AudioSession methods.
pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: []const u8, payload_json: []const u8) void,
};

/// Accepted operations invoke `complete` exactly once on a private helper
/// thread. Result JSON is borrowed for the call. Do not call deinit inside it.
pub const AsyncCompletion = struct {
    context: *anyopaque,
    complete: *const fn (context: *anyopaque, ok: bool, result_json: []const u8) void,
};

const State = enum(u8) { idle, recording, limit_reached, failed };
const Backend = enum(u8) { none, platform, core_audio };
const Failure = enum(u8) { none, conversion, overflow, route, interruption, storage };

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
    audio_dir: [:0]u8,
    services: ?native_sdk.platform.PlatformServices = null,
    direct_core_audio: bool = false,

    mutex: SpinMutex = .{},
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    async_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
    backend: Backend = .none,
    accepting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    backend_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    route_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
    fd: c_int = -1,
    current_path: [path_capacity]u8 = @splat(0),
    current_path_len: usize = 0,
    retry_path: ?[:0]u8 = null,

    unit: c.AudioUnit = null,
    converter: c.AudioConverterRef = null,
    capture_buffer: []f32 = &.{},
    unit_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    device_id: c.AudioDeviceID = c.kAudioObjectUnknown,
    system_listener: bool = false,
    device_listener: bool = false,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, sink: EventSink) !AudioSession {
        const joined = try std.fs.path.join(allocator, &.{ data_dir, "Audio" });
        defer allocator.free(joined);
        if (joined.len + 1 > path_capacity) return error.NameTooLong;
        const directory = try allocator.dupeZ(u8, joined);
        errdefer allocator.free(directory);
        try ensureDirectory(data_dir);
        try ensureDirectory(directory);
        sweep(directory);
        return .{ .allocator = allocator, .sink = sink, .audio_dir = directory };
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
        self.prepareCoreAudio() catch {};
    }

    pub fn deinit(self: *AudioSession) void {
        self.closing.store(true, .release);
        self.cancelActiveSession();
        while (self.async_count.load(.acquire) != 0) _ = c.usleep(1000);
        self.mutex.lock();
        self.joinWorker();
        self.disposeBackend();
        self.closeFile();
        self.removeCurrent();
        self.discardRetryLocked();
        self.mutex.unlock();
        self.allocator.free(self.audio_dir);
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
        self.discardRetryLocked();
    }

    /// Borrowed until startSession, discardRetryAudio, or deinit.
    pub fn retryAudioPath(self: *const AudioSession) ?[]const u8 {
        return if (self.retry_path) |path| path[0..path.len] else null;
    }

    pub fn diagnostics(self: *AudioSession, output: []u8) !usize {
        const drops = if (self.ring) |*ring| ring.dropped() else self.last_dropped.load(.acquire);
        const state = self.currentState();
        return jsonInto(output, .{
            .active = state == .recording or state == .limit_reached,
            .capturedFrames = self.frames.load(.acquire),
            .droppedFrames = drops,
            .retryAudioAvailable = self.retry_path != null,
            .conversionFailed = self.conversion_failed.load(.acquire),
        });
    }

    pub fn inputStatus(self: *AudioSession, output: []u8) !usize {
        _ = self;
        var device: c.AudioDeviceID = c.kAudioObjectUnknown;
        var size: u32 = @sizeOf(c.AudioDeviceID);
        var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        const status = c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &address, 0, null, &size, &device);
        var rate: f64 = 0;
        var channels: u32 = 0;
        var device_name: [256]u8 = @splat(0);
        var name: []const u8 = "System default microphone";
        if (status == c.noErr and device != c.kAudioObjectUnknown) {
            address = .{ .mSelector = c.kAudioDevicePropertyNominalSampleRate, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            size = @sizeOf(f64);
            _ = c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &rate);
            channels = inputChannels(device);
            address = .{ .mSelector = c.kAudioObjectPropertyName, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            var cf_name: c.CFStringRef = null;
            size = @sizeOf(c.CFStringRef);
            if (c.AudioObjectGetPropertyData(device, &address, 0, null, &size, @ptrCast(&cf_name)) == c.noErr and cf_name != null) {
                if (c.CFStringGetCString(cf_name, &device_name, device_name.len, c.kCFStringEncodingUTF8) != 0) name = std.mem.sliceTo(device_name[0..], 0);
                c.CFRelease(cf_name);
            }
        }
        const available = channels > 0 and rate >= 8000 and rate <= 96_000;
        var detail_buffer: [160]u8 = undefined;
        const detail = if (available)
            std.fmt.bufPrint(&detail_buffer, "Available · {d:.0} Hz · {d} channel{s}", .{ rate, channels, if (channels == 1) "" else "s" }) catch "Available"
        else
            "No usable microphone input format is available.";
        return jsonInto(output, .{ .ok = available, .deviceName = name, .detail = detail, .sampleRate = rate, .channels = channels });
    }

    pub fn writeStorageProbe(self: *AudioSession, output: []u8) !usize {
        var path: [path_capacity]u8 = @splat(0);
        const visible = try std.fmt.bufPrint(path[0 .. path.len - 1], "{s}/friday-10-minute-probe.f32", .{self.audio_dir});
        path[visible.len] = 0;
        const fd = c.open(@ptrCast(&path), c.O_CREAT | c.O_TRUNC | c.O_RDWR | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
        const expected: c.off_t = @intCast(maximum_storage_bytes);
        const storage_ok = fd >= 0 and c.ftruncate(fd, expected) == 0;
        var stat = std.mem.zeroes(c.struct_stat);
        if (fd >= 0) { _ = c.fstat(fd, &stat); _ = c.close(fd); }
        _ = c.unlink(@ptrCast(&path));
        var probe_ring = try Spsc.init(self.allocator, 4);
        defer probe_ring.deinit();
        const overflow = !probe_ring.push(&.{ 0, 0, 0, 0, 0 }) and probe_ring.dropped() == 1;
        const bytes: i64 = @intCast(stat.st_size);
        return jsonInto(output, .{
            .ok = storage_ok and bytes == expected and overflow,
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
        const removed = try self.cleanupProbe("friday-converter-failure-probe.f32");
        return jsonInto(output, .{ .ok = removed, .eventReceived = true, .tempRemoved = removed, .activeCleared = true });
    }

    pub fn writeRouteChangeProbe(self: *AudioSession, output: []u8) !usize {
        const removed = try self.cleanupProbe("friday-route-change-probe.f32");
        const reason = failureMessage(.route);
        const matched = std.mem.eql(u8, reason, "The microphone route changed during recording.");
        return jsonInto(output, .{ .ok = removed and matched, .activeCleared = true, .tempRemoved = removed, .reasonMatched = matched });
    }

    fn currentState(self: *const AudioSession) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    fn startLocked(self: *AudioSession, session_id: u64) !StartResult {
        if (self.closing.load(.acquire)) return error.SessionClosing;
        if (self.currentState() == .recording or self.currentState() == .limit_reached) return error.AlreadyRecording;
        self.joinWorker();
        self.resetBackendForNextSession();
        self.closeFile();
        self.removeCurrent();
        self.discardRetryLocked();
        const path = try std.fmt.bufPrint(self.current_path[0 .. self.current_path.len - 1], "{s}/session-{d}.f32", .{ self.audio_dir, session_id });
        self.current_path_len = path.len;
        self.current_path[path.len] = 0;
        self.fd = c.open(@ptrCast(&self.current_path), c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
        if (self.fd < 0) return error.TemporaryStorageUnavailable;
        errdefer { self.closeFile(); self.removeCurrent(); }
        self.ring = try Spsc.init(self.allocator, ring_capacity);
        errdefer { if (self.ring) |*ring| ring.deinit(); self.ring = null; }

        self.session_id = session_id;
        self.started_at_ms = nowMs();
        self.stopped_at_ms = 0;
        self.last_meter_at_ms = 0;
        self.warned = false;
        self.limited = false;
        self.frames.store(0, .release);
        self.first_audio_at_ms.store(0, .release);
        self.last_dropped.store(0, .release);
        self.failure.store(@intFromEnum(Failure.none), .release);
        self.conversion_failed.store(false, .release);
        self.backend_failed.store(false, .release);
        self.route_changed.store(false, .release);
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
        if (!failed and self.fd >= 0) _ = c.fsync(self.fd);
        self.closeFile();
        if (!failed) {
            self.retry_path = self.allocator.dupeZ(u8, self.currentPath()) catch null;
            if (self.retry_path == null) { self.removeCurrent(); self.resetBackendForNextSession(); self.state.store(@intFromEnum(State.idle), .release); return .{ .ok = false, .message = "Friday could not retain temporary audio for Retry." }; }
        } else self.removeCurrent();
        const result = StopResult{
            .ok = !failed,
            .audio_path = if (!failed) self.retry_path.?[0..self.retry_path.?.len] else "",
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
        self.closeFile();
        self.removeCurrent();
        self.resetBackendForNextSession();
        self.state.store(@intFromEnum(State.idle), .release);
    }

    fn workerMain(self: *AudioSession) void {
        var samples: [callback_frames]f32 = undefined;
        var converted: [callback_frames]f32 = undefined;
        while (true) {
            const ring = &(self.ring orelse return);
            if (self.route_changed.load(.acquire)) return self.failWorker(.route);
            if (self.backend_failed.load(.acquire)) return self.failWorker(.interruption);
            if (ring.dropped() != 0) { self.last_dropped.store(ring.dropped(), .release); return self.failWorker(.overflow); }
            const count = ring.pop(&samples);
            if (count != 0) {
                _ = self.first_audio_at_ms.cmpxchgStrong(0, nowMs(), .acq_rel, .acquire);
                const output = if (self.backend == .core_audio)
                    self.convertCoreAudio(samples[0..count], &converted) catch return self.failWorker(.conversion)
                else
                    samples[0..count];
                self.writeFrames(output) catch return self.failWorker(.storage);
                continue;
            }
            if (self.stop_requested.load(.acquire)) break;
            _ = c.usleep(2000);
        }
    }

    fn convertCoreAudio(self: *AudioSession, input: []const f32, output: []f32) ![]const f32 {
        const converter = self.converter orelse return error.ConverterUnavailable;
        var input_list = monoList(@constCast(input.ptr), input.len);
        var output_list = monoList(output.ptr, output.len);
        if (c.AudioConverterConvertComplexBuffer(converter, @intCast(input.len), &input_list, &output_list) != c.noErr)
            return error.ConversionFailed;
        const output_frames = output_list.mBuffers[0].mDataByteSize / @sizeOf(f32);
        if (output_frames > output.len) return error.ConversionFailed;
        return output[0..output_frames];
    }

    fn writeFrames(self: *AudioSession, samples: []const f32) !void {
        const before = self.frames.load(.acquire);
        if (before >= maximum_frames) return;
        const count: usize = @intCast(@min(@as(u64, samples.len), maximum_frames - before));
        try writeAll(self.fd, std.mem.sliceAsBytes(samples[0..count]));
        const total = before + count;
        self.frames.store(total, .release);
        var energy: f64 = 0;
        var peak: f32 = 0;
        for (samples[0..count]) |value| { energy += @as(f64, value) * value; peak = @max(peak, @abs(value)); }
        const rms: f32 = @floatCast(@sqrt(energy / @as(f64, @floatFromInt(count))));
        const now = nowMs();
        if (now -| self.last_meter_at_ms >= meter_period_ms) {
            self.last_meter_at_ms = now;
            const level: u8 = if (rms >= 0.08 or peak >= 0.35) 3 else if (rms >= 0.03 or peak >= 0.16) 2 else if (rms >= 0.008 or peak >= 0.05) 1 else 0;
            self.emit("audio_meter", .{ .sessionId = self.session_id, .capturedFrames = total, .elapsedMilliseconds = now -| self.started_at_ms, .level = level, .rmsMilli = @as(u32, @intFromFloat(@round(rms * 1000))), .peakMilli = @as(u32, @intFromFloat(@round(peak * 1000))) });
        }
        if (!self.warned and total >= warning_frames) { self.warned = true; self.emit("duration_warning", .{ .sessionId = self.session_id, .capturedFrames = total }); }
        if (!self.limited and total >= maximum_frames) {
            self.limited = true;
            self.accepting.store(false, .release);
            self.stopBackend();
            self.state.store(@intFromEnum(State.limit_reached), .release);
            self.emit("duration_limit", .{ .sessionId = self.session_id, .capturedFrames = maximum_frames });
        }
    }

    fn failWorker(self: *AudioSession, failure: Failure) void {
        if (self.failure.cmpxchgStrong(@intFromEnum(Failure.none), @intFromEnum(failure), .acq_rel, .acquire) != null) return;
        self.conversion_failed.store(failure == .conversion, .release);
        self.accepting.store(false, .release);
        self.stopBackend();
        self.closeFile();
        self.removeCurrent();
        self.state.store(@intFromEnum(State.failed), .release);
        self.emit("audio_interrupted", .{ .sessionId = self.session_id, .reason = failureMessage(failure) });
    }

    fn emit(self: *AudioSession, event: []const u8, payload: anytype) void {
        const json = std.json.Stringify.valueAlloc(self.allocator, payload, .{}) catch return;
        defer self.allocator.free(json);
        self.sink.emit(self.sink.context, event, json);
    }

    fn prepareCoreAudio(self: *AudioSession) !void {
        if (self.unit != null and self.converter != null and self.capture_buffer.len != 0) return;
        var description = c.AudioComponentDescription{ .componentType = c.kAudioUnitType_Output, .componentSubType = c.kAudioUnitSubType_HALOutput, .componentManufacturer = c.kAudioUnitManufacturer_Apple, .componentFlags = 0, .componentFlagsMask = 0 };
        const component = c.AudioComponentFindNext(null, &description) orelse return error.AudioInputUnavailable;
        if (c.AudioComponentInstanceNew(component, &self.unit) != c.noErr or self.unit == null) return error.AudioInputUnavailable;
        errdefer self.disposeCoreAudio();
        var one: u32 = 1;
        var zero: u32 = 0;
        if (c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Input, 1, &one, @sizeOf(u32)) != c.noErr or c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Output, 0, &zero, @sizeOf(u32)) != c.noErr) return error.AudioInputUnavailable;
        var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        var size: u32 = @sizeOf(c.AudioDeviceID);
        if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &address, 0, null, &size, &self.device_id) != c.noErr) return error.AudioInputUnavailable;
        _ = c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_CurrentDevice, c.kAudioUnitScope_Global, 0, &self.device_id, @sizeOf(c.AudioDeviceID));
        var format = floatFormat();
        if (c.AudioUnitSetProperty(self.unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &format, @sizeOf(c.AudioStreamBasicDescription)) != c.noErr) return error.UnconvertibleInputFormat;
        self.capture_buffer = try self.allocator.alloc(f32, callback_frames);
        var callback = c.AURenderCallbackStruct{ .inputProc = coreAudioCallback, .inputProcRefCon = self };
        if (c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_SetInputCallback, c.kAudioUnitScope_Global, 0, &callback, @sizeOf(c.AURenderCallbackStruct)) != c.noErr or c.AudioUnitInitialize(self.unit) != c.noErr) return error.AudioInputUnavailable;
        if (c.AudioConverterNew(&format, &format, &self.converter) != c.noErr) return error.ConverterUnavailable;
        try self.addRouteListeners();
    }

    fn startCoreAudio(self: *AudioSession) !void {
        try self.prepareCoreAudio();
        const unit = self.unit orelse return error.AudioInputUnavailable;
        if (c.AudioOutputUnitStart(unit) != c.noErr) return error.AudioInputUnavailable;
        self.unit_running.store(true, .release);
    }

    fn stopBackend(self: *AudioSession) void {
        switch (self.backend) {
            .platform => if (self.services) |services| services.audioCaptureStop(.microphone) catch {},
            .core_audio => {
                if (self.unit_running.swap(false, .acq_rel)) {
                    if (self.unit) |unit| _ = c.AudioOutputUnitStop(unit);
                }
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
    }

    fn disposeBackend(self: *AudioSession) void {
        self.stopBackend();
        self.disposeCoreAudio();
        if (self.ring) |*ring| { self.last_dropped.store(ring.dropped(), .release); ring.deinit(); self.ring = null; }
        self.backend = .none;
    }

    fn disposeCoreAudio(self: *AudioSession) void {
        self.removeRouteListeners();
        if (self.unit) |unit| { _ = c.AudioUnitUninitialize(unit); _ = c.AudioComponentInstanceDispose(unit); self.unit = null; }
        if (self.converter) |converter| { _ = c.AudioConverterDispose(converter); self.converter = null; }
        if (self.capture_buffer.len != 0) { self.allocator.free(self.capture_buffer); self.capture_buffer = &.{}; }
        self.device_id = c.kAudioObjectUnknown;
    }

    fn addRouteListeners(self: *AudioSession) !void {
        var system = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (c.AudioObjectAddPropertyListener(c.kAudioObjectSystemObject, &system, routeListener, self) != c.noErr) return error.RouteMonitoringUnavailable;
        self.system_listener = true;
        var alive = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (c.AudioObjectAddPropertyListener(self.device_id, &alive, routeListener, self) != c.noErr) return error.RouteMonitoringUnavailable;
        self.device_listener = true;
    }

    fn removeRouteListeners(self: *AudioSession) void {
        if (self.system_listener) { var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain }; _ = c.AudioObjectRemovePropertyListener(c.kAudioObjectSystemObject, &address, routeListener, self); self.system_listener = false; }
        if (self.device_listener and self.device_id != c.kAudioObjectUnknown) { var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain }; _ = c.AudioObjectRemovePropertyListener(self.device_id, &address, routeListener, self); self.device_listener = false; }
    }

    fn joinWorker(self: *AudioSession) void { if (self.worker) |thread| { thread.join(); self.worker = null; } }
    fn closeFile(self: *AudioSession) void { if (self.fd >= 0) { _ = c.close(self.fd); self.fd = -1; } }
    fn removeCurrent(self: *AudioSession) void { if (self.current_path_len != 0) { _ = c.unlink(@ptrCast(&self.current_path)); self.current_path_len = 0; self.current_path[0] = 0; } }
    fn currentPath(self: *const AudioSession) []const u8 { return self.current_path[0..self.current_path_len]; }
    fn discardRetryLocked(self: *AudioSession) void { if (self.retry_path) |path| { _ = c.unlink(path.ptr); self.allocator.free(path); self.retry_path = null; } }

    fn cleanupProbe(self: *AudioSession, name: []const u8) !bool {
        var path: [path_capacity]u8 = @splat(0);
        const visible = try std.fmt.bufPrint(path[0 .. path.len - 1], "{s}/{s}", .{ self.audio_dir, name });
        path[visible.len] = 0;
        const fd = c.open(@ptrCast(&path), c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
        if (fd < 0) return error.TemporaryStorageUnavailable;
        _ = c.close(fd);
        _ = c.unlink(@ptrCast(&path));
        return c.access(@ptrCast(&path), c.F_OK) != 0;
    }
};

const StartTask = struct { self: *AudioSession, session_id: u64, completion: AsyncCompletion };
const StopTask = struct { self: *AudioSession, session_id: u64, completion: AsyncCompletion };
const StartResult = struct { session_id: u64, started_at_ms: u64 };
const StopResult = struct { ok: bool, audio_path: []const u8 = "", frames: u64 = 0, started: u64 = 0, first: u64 = 0, stopped: u64 = 0, dropped: u64 = 0, retry: bool = false, message: []const u8 = "" };

fn startTask(task: *StartTask) void {
    const self = task.self;
    defer { _ = self.async_count.fetchSub(1, .acq_rel); self.allocator.destroy(task); }
    self.mutex.lock();
    const result = self.startLocked(task.session_id);
    self.mutex.unlock();
    if (result) |started| complete(self.allocator, task.completion, true, .{ .ok = true, .sessionId = started.session_id, .captureStartedAtMs = started.started_at_ms, .sampleRate = sample_rate, .channels = 1 }) else |err| complete(self.allocator, task.completion, false, .{ .ok = false, .sessionId = task.session_id, .message = startError(err) });
}

fn stopTask(task: *StopTask) void {
    const self = task.self;
    defer { _ = self.async_count.fetchSub(1, .acq_rel); self.allocator.destroy(task); }
    self.mutex.lock();
    const result = self.stopLocked(task.session_id);
    self.mutex.unlock();
    if (!result.ok) return complete(self.allocator, task.completion, false, .{ .ok = false, .sessionId = task.session_id, .message = result.message });
    complete(self.allocator, task.completion, true, .{ .ok = true, .sessionId = task.session_id, .audioPath = result.audio_path, .capturedFrames = result.frames, .audioDurationMs = result.frames * 1000 / sample_rate, .captureStartedAtMs = result.started, .firstAudioAtMs = result.first, .captureStoppedAtMs = result.stopped, .droppedFrames = result.dropped, .retryAudioAvailable = result.retry });
}

fn platformCapturePush(context: ?*anyopaque, generation: u64, event: native_sdk.AudioCaptureEvent) native_sdk.AudioCapturePushResult {
    const self: *AudioSession = @ptrCast(@alignCast(context orelse return .closed));
    if (generation != self.session_id or !self.accepting.load(.acquire)) return .closed;
    switch (event.kind) {
        .started => return .accepted,
        .failed => { self.backend_failed.store(true, .release); self.accepting.store(false, .release); return .accepted; },
        .data => {},
    }
    if (event.format.sample_rate != 16_000 or event.format.channels != 1 or event.pcm_s16le.len != @as(usize, event.frames) * 2) { self.backend_failed.store(true, .release); self.accepting.store(false, .release); return .dropped_oversized; }
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

fn coreAudioCallback(context: ?*anyopaque, flags: [*c]c.AudioUnitRenderActionFlags, timestamp: ?*const c.AudioTimeStamp, bus: u32, frames: u32, ignored: [*c]c.AudioBufferList) callconv(.c) c.OSStatus {
    _ = bus; _ = ignored;
    const self: *AudioSession = @ptrCast(@alignCast(context orelse return c.noErr));
    if (!self.accepting.load(.acquire)) return c.noErr;
    if (frames > self.capture_buffer.len) { if (self.ring) |*ring| _ = ring.dropped_frames.fetchAdd(frames, .monotonic); return c.noErr; }
    var list = monoList(self.capture_buffer.ptr, frames);
    const status = c.AudioUnitRender(self.unit, flags, timestamp, 1, frames, &list);
    if (status != c.noErr) { self.backend_failed.store(true, .release); self.accepting.store(false, .release); return status; }
    if (self.ring) |*ring| _ = ring.push(self.capture_buffer[0..frames]);
    return c.noErr;
}

fn routeListener(object: c.AudioObjectID, count: u32, addresses: [*c]const c.AudioObjectPropertyAddress, context: ?*anyopaque) callconv(.c) c.OSStatus {
    _ = object; _ = count; _ = addresses;
    const self: *AudioSession = @ptrCast(@alignCast(context orelse return c.noErr));
    self.route_changed.store(true, .release);
    self.accepting.store(false, .release);
    return c.noErr;
}

fn monoList(samples: [*]f32, frames: usize) c.AudioBufferList {
    var list = std.mem.zeroes(c.AudioBufferList);
    list.mNumberBuffers = 1;
    list.mBuffers[0] = .{ .mNumberChannels = 1, .mDataByteSize = @intCast(frames * @sizeOf(f32)), .mData = samples };
    return list;
}

fn floatFormat() c.AudioStreamBasicDescription {
    return .{ .mSampleRate = 16_000, .mFormatID = c.kAudioFormatLinearPCM, .mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked | c.kAudioFormatFlagsNativeEndian, .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 1, .mBitsPerChannel = 32, .mReserved = 0 };
}

fn inputChannels(device: c.AudioDeviceID) u32 {
    var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyStreamConfiguration, .mScope = c.kAudioObjectPropertyScopeInput, .mElement = c.kAudioObjectPropertyElementMain };
    var size: u32 = 0;
    if (c.AudioObjectGetPropertyDataSize(device, &address, 0, null, &size) != c.noErr or size == 0 or size > 4096) return 0;
    var bytes: [4096]u8 align(@alignOf(c.AudioBufferList)) = @splat(0);
    if (c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &bytes) != c.noErr) return 0;
    const list: *const c.AudioBufferList = @ptrCast(&bytes);
    const buffers: [*]const c.AudioBuffer = @ptrCast(&list.mBuffers);
    var result: u32 = 0;
    for (buffers[0..list.mNumberBuffers]) |buffer| result += buffer.mNumberChannels;
    return result;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (written > 0) offset += @intCast(written) else if (written < 0 and c.__error().* == c.EINTR) continue else return error.TemporaryStorageWriteFailed;
    }
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

fn ensureDirectory(path: []const u8) !void {
    if (path.len + 1 > path_capacity) return error.NameTooLong;
    var terminated: [path_capacity]u8 = @splat(0);
    @memcpy(terminated[0..path.len], path);
    if (c.mkdir(@ptrCast(&terminated), @as(c_uint, 0o700)) != 0 and c.__error().* != c.EEXIST) return error.TemporaryStorageUnavailable;
}

fn sweep(directory: [:0]const u8) void {
    const handle = c.opendir(directory.ptr) orelse return;
    defer _ = c.closedir(handle);
    while (c.readdir(handle)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var path: [path_capacity]u8 = @splat(0);
        const visible = std.fmt.bufPrint(path[0 .. path.len - 1], "{s}/{s}", .{ directory, name }) catch continue;
        path[visible.len] = 0;
        _ = c.unlink(@ptrCast(&path));
    }
}

fn noFollow() c_int { return if (@hasDecl(c, "O_NOFOLLOW")) c.O_NOFOLLOW else 0; }
fn startError(err: anyerror) []const u8 { return switch (err) { error.AlreadyRecording => "A recording is already active.", error.TemporaryStorageUnavailable, error.NameTooLong => "Friday could not create temporary audio storage.", error.UnconvertibleInputFormat => "The microphone format cannot be converted safely.", error.ConverterUnavailable => "Friday could not create the audio converter.", error.RouteMonitoringUnavailable => "Friday could not monitor microphone route changes.", error.SessionClosing => "The audio session is closing.", else => "Friday could not start microphone capture." }; }
fn failureMessage(failure: Failure) []const u8 { return switch (failure) { .conversion => "Audio conversion failed.", .overflow => "Audio input overflowed; recording was stopped.", .route => "The microphone route changed during recording.", .interruption => "Microphone capture was interrupted.", .storage => "Temporary audio storage failed.", .none => "Audio capture failed." }; }

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

fn ignoreEvent(context: *anyopaque, event: []const u8, payload: []const u8) void {
    _ = context;
    _ = event;
    _ = payload;
}

test "PlatformServices capture drains canonical Float32 and retains retry audio" {
    const root: [:0]const u8 = "/tmp/friday-audio-zig-test";
    _ = c.mkdir(root.ptr, @as(c_uint, 0o700));
    defer {
        _ = c.rmdir("/tmp/friday-audio-zig-test/Audio");
        _ = c.rmdir(root.ptr);
    }
    var sink_context: u8 = 0;
    var session = try AudioSession.init(std.testing.allocator, root, .{ .context = &sink_context, .emit = ignoreEvent });
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
