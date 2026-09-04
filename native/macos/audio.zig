const std = @import("std");
const native_sdk = @import("native_sdk");
const objc = @import("objc.zig");
const Spsc = @import("ring.zig").Spsc;

extern "c" var NSWorkspaceDidWakeNotification: objc.Id;
extern "c" var NSWorkspaceWillSleepNotification: objc.Id;

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
    pub const CLOCK_MONOTONIC = posix.CLOCK_MONOTONIC;
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
pub const callback_liveness_timeout_ms: u64 = 2_000;
const path_capacity = 4096;
const callback_frames = 4096;

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

const State = enum(u8) { idle, recording, limit_reached, failed };
const Backend = enum(u8) { none, platform, core_audio };
const Failure = enum(u8) { none, conversion, overflow, route, interruption, storage, callback_liveness, event_delivery };

const RouteSnapshot = struct {
    device: c.AudioDeviceID,
    sample_rate_bits: u64,
    stream_hash: u64,
    channels: u32,

    fn eql(a: RouteSnapshot, b: RouteSnapshot) bool {
        return a.device == b.device and
            a.sample_rate_bits == b.sample_rate_bits and
            a.stream_hash == b.stream_hash and
            a.channels == b.channels;
    }
};

const CoreAudioOps = struct {
    query_route: *const fn (*AudioSession) anyerror!RouteSnapshot = queryCoreAudioRoute,
    ready: *const fn (*AudioSession) bool = productionCoreAudioReady,
    build: *const fn (*AudioSession, RouteSnapshot) anyerror!void = buildCoreAudio,
    start: *const fn (*AudioSession) anyerror!void = startCoreAudioUnit,
    stop: *const fn (*AudioSession) void = stopCoreAudioUnit,
    dispose: *const fn (*AudioSession) void = disposeCoreAudioResources,
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
    audio_dir: [:0]u8,
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
    last_callback_at_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
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
    route_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    active_route_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    forced_route_failure: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    prepared_route_generation: u64 = 0,
    prepared_route: RouteSnapshot = .{ .device = c.kAudioObjectUnknown, .sample_rate_bits = 0, .stream_hash = 0, .channels = 0 },
    last_core_audio_status: std.atomic.Value(i32) = std.atomic.Value(i32).init(c.noErr),
    core_audio_ops: CoreAudioOps = .{},
    core_audio_test_context: ?*anyopaque = null,
    system_listener: bool = false,
    device_listener: bool = false,
    rate_listener: bool = false,
    stream_listener: bool = false,
    power_observer: objc.Id = null,

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
        self.installPowerObserver() catch {};
        self.prepareCoreAudio() catch self.disposeCoreAudio();
    }

    /// Route notifications and wake require validation. Sleep additionally
    /// forces the active generation to fail even if the route looks unchanged.
    fn invalidateCoreAudioRoute(self: *AudioSession, force_failure: bool) void {
        const state = self.currentState();
        if (self.active_route_generation.load(.acquire) != 0 and (state == .recording or state == .limit_reached)) {
            if (force_failure) self.forced_route_failure.store(true, .release);
            self.accepting.store(false, .release);
        }
        _ = self.route_generation.fetchAdd(1, .acq_rel);
    }

    pub fn deinit(self: *AudioSession) void {
        self.closing.store(true, .release);
        self.cancelActiveSession();
        while (self.async_count.load(.acquire) != 0) _ = c.usleep(1000);
        self.mutex.lock();
        self.joinWorker();
        self.disposeBackend();
        self.removePowerObserver();
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
        var rate: f64 = 0;
        var channels: u32 = 0;
        var device_name: [256]u8 = @splat(0);
        var name: []const u8 = "System default microphone";
        if (self.core_audio_ops.query_route(self)) |route| {
            rate = @bitCast(route.sample_rate_bits);
            channels = route.channels;
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioObjectPropertyName, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            var cf_name: c.CFStringRef = null;
            var size: u32 = @sizeOf(c.CFStringRef);
            if (self.coreAudioStatusOk(c.AudioObjectGetPropertyData(route.device, &address, 0, null, &size, @ptrCast(&cf_name))) and size == @sizeOf(c.CFStringRef) and cf_name != null) {
                if (c.CFStringGetCString(cf_name, &device_name, device_name.len, c.kCFStringEncodingUTF8) != 0) name = std.mem.sliceTo(device_name[0..], 0);
                c.CFRelease(cf_name);
            }
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
        var path: [path_capacity]u8 = @splat(0);
        const visible = try std.fmt.bufPrint(path[0 .. path.len - 1], "{s}/friday-10-minute-probe.f32", .{self.audio_dir});
        path[visible.len] = 0;
        const fd = c.open(@ptrCast(&path), c.O_CREAT | c.O_TRUNC | c.O_RDWR | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
        const expected: c.off_t = @intCast(maximum_storage_bytes);
        const storage_ok = fd >= 0 and c.ftruncate(fd, expected) == 0;
        var stat = std.mem.zeroes(c.struct_stat);
        if (fd >= 0) {
            _ = c.fstat(fd, &stat);
            _ = c.close(fd);
        }
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
        errdefer {
            self.closeFile();
            self.removeCurrent();
        }
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
        self.last_callback_at_ms.store(livenessNowMs(), .release);
        self.last_dropped.store(0, .release);
        self.failure.store(@intFromEnum(Failure.none), .release);
        self.conversion_failed.store(false, .release);
        self.backend_failed.store(false, .release);
        self.backend_ready.store(false, .release);
        self.active_route_generation.store(0, .release);
        self.forced_route_failure.store(false, .release);
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
        if (!failed and self.fd >= 0) _ = c.fsync(self.fd);
        self.closeFile();
        if (!failed) {
            self.retry_path = self.allocator.dupeZ(u8, self.currentPath()) catch null;
            if (self.retry_path == null) {
                self.removeCurrent();
                self.resetBackendForNextSession();
                self.state.store(@intFromEnum(State.idle), .release);
                return .{ .ok = false, .message = "Friday could not retain temporary audio for Retry." };
            }
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
            if (self.currentState() == .limit_reached or self.currentState() == .failed) return;
            const ring = &(self.ring orelse return);
            if (!self.backend_ready.load(.acquire)) {
                if (self.stop_requested.load(.acquire)) return;
                _ = c.usleep(2000);
                continue;
            }
            if (self.coreAudioRouteIsStale()) return self.failWorker(.route);
            if (self.backend_failed.load(.acquire)) return self.failWorker(.interruption);
            const last_callback = self.last_callback_at_ms.load(.acquire);
            const now = livenessNowMs();
            if (!self.stop_requested.load(.acquire) and self.backend != .none and last_callback != 0 and now > last_callback and now - last_callback >= callback_liveness_timeout_ms)
                return self.failWorker(.callback_liveness);
            if (ring.dropped() != 0) {
                self.last_dropped.store(ring.dropped(), .release);
                return self.failWorker(.overflow);
            }
            const count = ring.pop(&samples);
            if (count != 0) {
                _ = self.first_audio_at_ms.cmpxchgStrong(0, nowMs(), .acq_rel, .acquire);
                const output = if (self.backend == .core_audio)
                    self.convertCoreAudio(samples[0..count], &converted) catch return self.failWorker(.conversion)
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

    fn convertCoreAudio(self: *AudioSession, input: []const f32, output: []f32) ![]const f32 {
        const converter = self.converter orelse return error.ConverterUnavailable;
        var input_list = monoList(@constCast(input.ptr), input.len);
        var output_list = monoList(output.ptr, output.len);
        if (!self.coreAudioStatusOk(c.AudioConverterConvertComplexBuffer(converter, @intCast(input.len), &input_list, &output_list)))
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
        self.closeFile();
        self.removeCurrent();
        self.state.store(@intFromEnum(State.failed), .release);
        _ = self.emit("audio_interrupted", .{ .sessionId = self.session_id, .reason = failureMessage(failure) });
        self.sink.abort(self.sink.context, self.session_id);
    }

    fn coreAudioRouteIsStale(self: *AudioSession) bool {
        const active_route = self.active_route_generation.load(.acquire);
        const current_route = self.route_generation.load(.acquire);
        if (active_route == 0 or active_route == current_route) return false;
        if (self.forced_route_failure.swap(false, .acq_rel)) return true;
        const route = self.core_audio_ops.query_route(self) catch return true;
        if (!self.prepared_route.eql(route)) return true;
        if (current_route != self.route_generation.load(.acquire)) return false;
        self.active_route_generation.store(current_route, .release);
        self.accepting.store(true, .release);
        return false;
    }

    fn emit(self: *AudioSession, event: []const u8, payload: anytype) bool {
        const json = std.json.Stringify.valueAlloc(self.allocator, payload, .{}) catch return false;
        defer self.allocator.free(json);
        return self.sink.emit(self.sink.context, event, json);
    }

    fn prepareCoreAudio(self: *AudioSession) !void {
        for (0..4) |_| {
            const generation = self.route_generation.load(.acquire);
            const route = try self.core_audio_ops.query_route(self);
            if (self.core_audio_ops.ready(self) and
                self.prepared_route_generation == generation and
                self.prepared_route.eql(route)) return;

            self.disposeCoreAudio();
            self.core_audio_ops.build(self, route) catch |err| {
                self.disposeCoreAudio();
                return err;
            };
            if (generation != self.route_generation.load(.acquire)) {
                self.disposeCoreAudio();
                continue;
            }
            self.device_id = route.device;
            self.prepared_route = route;
            self.prepared_route_generation = generation;
            return;
        }
        return error.AudioRouteUnstable;
    }

    fn buildCoreAudio(self: *AudioSession, route: RouteSnapshot) !void {
        var description = c.AudioComponentDescription{ .componentType = c.kAudioUnitType_Output, .componentSubType = c.kAudioUnitSubType_HALOutput, .componentManufacturer = c.kAudioUnitManufacturer_Apple, .componentFlags = 0, .componentFlagsMask = 0 };
        const component = c.AudioComponentFindNext(null, &description) orelse return error.AudioInputUnavailable;
        const instance_status = c.AudioComponentInstanceNew(component, &self.unit);
        if (!self.coreAudioStatusOk(instance_status) or self.unit == null) return error.AudioInputUnavailable;
        var one: u32 = 1;
        var zero: u32 = 0;
        if (!self.coreAudioStatusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Input, 1, &one, @sizeOf(u32)))) return error.AudioInputUnavailable;
        if (!self.coreAudioStatusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Output, 0, &zero, @sizeOf(u32)))) return error.AudioInputUnavailable;
        self.device_id = route.device;
        if (!self.coreAudioStatusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_CurrentDevice, c.kAudioUnitScope_Global, 0, &self.device_id, @sizeOf(c.AudioDeviceID)))) return error.AudioInputUnavailable;
        var format = floatFormat();
        if (!self.coreAudioStatusOk(c.AudioUnitSetProperty(self.unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &format, @sizeOf(c.AudioStreamBasicDescription)))) return error.UnconvertibleInputFormat;
        self.capture_buffer = try self.allocator.alloc(f32, callback_frames);
        var callback = c.AURenderCallbackStruct{ .inputProc = coreAudioCallback, .inputProcRefCon = self };
        if (!self.coreAudioStatusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_SetInputCallback, c.kAudioUnitScope_Global, 0, &callback, @sizeOf(c.AURenderCallbackStruct)))) return error.AudioInputUnavailable;
        if (!self.coreAudioStatusOk(c.AudioUnitInitialize(self.unit))) return error.AudioInputUnavailable;
        if (!self.coreAudioStatusOk(c.AudioConverterNew(&format, &format, &self.converter))) return error.ConverterUnavailable;
        try self.addRouteListeners();
    }

    fn startCoreAudio(self: *AudioSession) !void {
        if (self.direct_core_audio and self.power_observer == null) try self.installPowerObserver();
        try self.prepareCoreAudio();
        const generation = self.prepared_route_generation;
        self.active_route_generation.store(generation, .release);
        if (generation != self.route_generation.load(.acquire)) {
            self.active_route_generation.store(0, .release);
            return error.AudioRouteUnstable;
        }
        self.core_audio_ops.start(self) catch |err| {
            self.active_route_generation.store(0, .release);
            return err;
        };
        if (generation != self.route_generation.load(.acquire)) {
            self.core_audio_ops.stop(self);
            self.active_route_generation.store(0, .release);
            return error.AudioRouteUnstable;
        }
    }

    fn stopBackend(self: *AudioSession) void {
        switch (self.backend) {
            .platform => if (self.services) |services| services.audioCaptureStop(.microphone) catch {},
            .core_audio => {
                self.core_audio_ops.stop(self);
                self.active_route_generation.store(0, .release);
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
        self.active_route_generation.store(0, .release);
        self.core_audio_ops.dispose(self);
        self.prepared_route_generation = 0;
        self.prepared_route = .{ .device = c.kAudioObjectUnknown, .sample_rate_bits = 0, .stream_hash = 0, .channels = 0 };
        self.device_id = c.kAudioObjectUnknown;
    }

    fn disposeCoreAudioResources(self: *AudioSession) void {
        self.removeRouteListeners();
        if (self.unit) |unit| {
            _ = self.coreAudioStatusOk(c.AudioUnitUninitialize(unit));
            _ = self.coreAudioStatusOk(c.AudioComponentInstanceDispose(unit));
            self.unit = null;
        }
        if (self.converter) |converter| {
            _ = self.coreAudioStatusOk(c.AudioConverterDispose(converter));
            self.converter = null;
        }
        if (self.capture_buffer.len != 0) {
            self.allocator.free(self.capture_buffer);
            self.capture_buffer = &.{};
        }
        self.unit_running.store(false, .release);
    }

    fn addRouteListeners(self: *AudioSession) !void {
        var system = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.coreAudioStatusOk(c.AudioObjectAddPropertyListener(c.kAudioObjectSystemObject, &system, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.system_listener = true;
        var alive = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.coreAudioStatusOk(c.AudioObjectAddPropertyListener(self.device_id, &alive, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.device_listener = true;
        var rate = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyNominalSampleRate, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.coreAudioStatusOk(c.AudioObjectAddPropertyListener(self.device_id, &rate, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.rate_listener = true;
        var stream = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyStreamConfiguration, .mScope = c.kAudioObjectPropertyScopeInput, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.coreAudioStatusOk(c.AudioObjectAddPropertyListener(self.device_id, &stream, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.stream_listener = true;
    }

    fn removeRouteListeners(self: *AudioSession) void {
        if (self.system_listener) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.coreAudioStatusOk(c.AudioObjectRemovePropertyListener(c.kAudioObjectSystemObject, &address, routeListener, self));
            self.system_listener = false;
        }
        if (self.device_listener and self.device_id != c.kAudioObjectUnknown) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.coreAudioStatusOk(c.AudioObjectRemovePropertyListener(self.device_id, &address, routeListener, self));
            self.device_listener = false;
        }
        if (self.rate_listener and self.device_id != c.kAudioObjectUnknown) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyNominalSampleRate, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.coreAudioStatusOk(c.AudioObjectRemovePropertyListener(self.device_id, &address, routeListener, self));
            self.rate_listener = false;
        }
        if (self.stream_listener and self.device_id != c.kAudioObjectUnknown) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyStreamConfiguration, .mScope = c.kAudioObjectPropertyScopeInput, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.coreAudioStatusOk(c.AudioObjectRemovePropertyListener(self.device_id, &address, routeListener, self));
            self.stream_listener = false;
        }
    }

    fn coreAudioStatusOk(self: *AudioSession, status: c.OSStatus) bool {
        if (status == c.noErr) return true;
        self.last_core_audio_status.store(status, .release);
        return false;
    }

    fn installPowerObserver(self: *AudioSession) !void {
        if (self.power_observer != null) return;
        const observer_class = ensureAudioPowerObserverClass() orelse return error.RouteMonitoringUnavailable;
        const observer = objc.send0(objc.Id, observer_class, objc.selector("new"));
        if (observer == null) return error.RouteMonitoringUnavailable;
        errdefer objc.release(observer);
        objc.setPointerIvar(observer, "fridayContext", self);
        const workspace = objc.send0(objc.Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const center = objc.send0(objc.Id, workspace, objc.selector("notificationCenter"));
        if (center == null) return error.RouteMonitoringUnavailable;
        objc.send4(void, objc.Id, objc.Sel, objc.Id, objc.Id, center, objc.selector("addObserver:selector:name:object:"), observer, objc.selector("fridayAudioWake:"), NSWorkspaceDidWakeNotification, null);
        objc.send4(void, objc.Id, objc.Sel, objc.Id, objc.Id, center, objc.selector("addObserver:selector:name:object:"), observer, objc.selector("fridayAudioSleep:"), NSWorkspaceWillSleepNotification, null);
        self.power_observer = observer;
    }

    fn removePowerObserver(self: *AudioSession) void {
        const observer = self.power_observer orelse return;
        const workspace = objc.send0(objc.Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const center = objc.send0(objc.Id, workspace, objc.selector("notificationCenter"));
        if (center != null) objc.send1(void, objc.Id, center, objc.selector("removeObserver:"), observer);
        objc.setPointerIvar(observer, "fridayContext", null);
        objc.release(observer);
        self.power_observer = null;
    }

    fn joinWorker(self: *AudioSession) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }
    fn closeFile(self: *AudioSession) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
    fn removeCurrent(self: *AudioSession) void {
        if (self.current_path_len != 0) {
            _ = c.unlink(@ptrCast(&self.current_path));
            self.current_path_len = 0;
            self.current_path[0] = 0;
        }
    }
    fn currentPath(self: *const AudioSession) []const u8 {
        return self.current_path[0..self.current_path_len];
    }
    fn discardRetryLocked(self: *AudioSession) void {
        if (self.retry_path) |path| {
            _ = c.unlink(path.ptr);
            self.allocator.free(path);
            self.retry_path = null;
        }
    }

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

fn queryCoreAudioRoute(self: *AudioSession) !RouteSnapshot {
    var device = c.kAudioObjectUnknown;
    var size: u32 = @sizeOf(c.AudioDeviceID);
    var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
    if (!self.coreAudioStatusOk(c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &address, 0, null, &size, &device)) or size != @sizeOf(c.AudioDeviceID) or device == c.kAudioObjectUnknown)
        return error.AudioInputUnavailable;

    var alive: u32 = 0;
    size = @sizeOf(u32);
    address = .{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
    if (!self.coreAudioStatusOk(c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &alive)) or size != @sizeOf(u32) or alive == 0)
        return error.AudioInputUnavailable;

    var rate: f64 = 0;
    size = @sizeOf(f64);
    address = .{ .mSelector = c.kAudioDevicePropertyNominalSampleRate, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
    if (!self.coreAudioStatusOk(c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &rate)) or size != @sizeOf(f64) or !std.math.isFinite(rate) or rate < 8000 or rate > 384_000)
        return error.UnconvertibleInputFormat;

    address = .{ .mSelector = c.kAudioDevicePropertyStreamConfiguration, .mScope = c.kAudioObjectPropertyScopeInput, .mElement = c.kAudioObjectPropertyElementMain };
    size = 0;
    if (!self.coreAudioStatusOk(c.AudioObjectGetPropertyDataSize(device, &address, 0, null, &size)) or size == 0 or size > 4096)
        return error.UnconvertibleInputFormat;
    var bytes: [4096]u8 align(@alignOf(c.AudioBufferList)) = @splat(0);
    if (!self.coreAudioStatusOk(c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &bytes)) or size == 0 or size > bytes.len)
        return error.UnconvertibleInputFormat;
    const stream = streamConfiguration(bytes[0..size]) orelse return error.UnconvertibleInputFormat;
    if (stream.channels == 0) return error.UnconvertibleInputFormat;
    return .{
        .device = device,
        .sample_rate_bits = @bitCast(rate),
        .stream_hash = stream.hash,
        .channels = stream.channels,
    };
}

fn productionCoreAudioReady(self: *AudioSession) bool {
    return self.unit != null and self.converter != null and self.capture_buffer.len != 0;
}

fn buildCoreAudio(self: *AudioSession, route: RouteSnapshot) !void {
    return self.buildCoreAudio(route);
}

fn startCoreAudioUnit(self: *AudioSession) !void {
    const unit = self.unit orelse return error.AudioInputUnavailable;
    if (!self.coreAudioStatusOk(c.AudioOutputUnitStart(unit))) return error.AudioInputUnavailable;
    self.unit_running.store(true, .release);
}

fn stopCoreAudioUnit(self: *AudioSession) void {
    if (!self.unit_running.load(.acquire)) return;
    const unit = self.unit orelse {
        self.unit_running.store(false, .release);
        return;
    };
    if (self.coreAudioStatusOk(c.AudioOutputUnitStop(unit))) {
        self.unit_running.store(false, .release);
    } else {
        self.backend_failed.store(true, .release);
    }
}

fn disposeCoreAudioResources(self: *AudioSession) void {
    self.disposeCoreAudioResources();
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
    self.last_callback_at_ms.store(livenessNowMs(), .release);
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

fn coreAudioCallback(context: ?*anyopaque, flags: [*c]c.AudioUnitRenderActionFlags, timestamp: ?*const c.AudioTimeStamp, bus: u32, frames: u32, ignored: [*c]c.AudioBufferList) callconv(.c) c.OSStatus {
    _ = bus;
    _ = ignored;
    const self: *AudioSession = @ptrCast(@alignCast(context orelse return c.noErr));
    if (!self.accepting.load(.acquire)) return c.noErr;
    self.last_callback_at_ms.store(livenessNowMs(), .release);
    if (frames > self.capture_buffer.len) {
        if (self.ring) |*ring| _ = ring.dropped_frames.fetchAdd(frames, .monotonic);
        return c.noErr;
    }
    var list = monoList(self.capture_buffer.ptr, frames);
    const status = c.AudioUnitRender(self.unit, flags, timestamp, 1, frames, &list);
    if (status != c.noErr) {
        self.last_core_audio_status.store(status, .release);
        self.backend_failed.store(true, .release);
        self.accepting.store(false, .release);
        return status;
    }
    if (self.ring) |*ring| _ = ring.push(self.capture_buffer[0..frames]);
    return c.noErr;
}

fn routeListener(object: c.AudioObjectID, count: u32, addresses: [*c]const c.AudioObjectPropertyAddress, context: ?*anyopaque) callconv(.c) c.OSStatus {
    const self: *AudioSession = @ptrCast(@alignCast(context orelse return c.noErr));
    _ = object;
    var relevant = false;
    for (addresses[0..count]) |address| {
        relevant = relevant or address.mSelector == c.kAudioHardwarePropertyDefaultInputDevice or
            address.mSelector == c.kAudioDevicePropertyDeviceIsAlive or
            address.mSelector == c.kAudioDevicePropertyNominalSampleRate or
            address.mSelector == c.kAudioDevicePropertyStreamConfiguration;
    }
    if (relevant) self.invalidateCoreAudioRoute(false);
    return c.noErr;
}

fn audioObserverWake(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (objc.getPointerIvar(AudioSession, receiver, "fridayContext")) |self| self.invalidateCoreAudioRoute(false);
}

fn audioObserverSleep(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (objc.getPointerIvar(AudioSession, receiver, "fridayContext")) |self| self.invalidateCoreAudioRoute(true);
}

fn ensureAudioPowerObserverClass() objc.Class {
    if (objc.lookupClass("FridayZigAudioPowerObserver")) |existing| return existing;
    const cls = objc.allocateClassPair(objc.class("NSObject"), "FridayZigAudioPowerObserver") orelse return null;
    if (!objc.addPointerIvar(cls, "fridayContext")) return null;
    _ = objc.addMethod(cls, objc.selector("fridayAudioWake:"), &audioObserverWake, "v@:@");
    _ = objc.addMethod(cls, objc.selector("fridayAudioSleep:"), &audioObserverSleep, "v@:@");
    objc.registerClassPair(cls);
    return cls;
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

const StreamConfiguration = struct { channels: u32, hash: u64 };

fn streamConfiguration(bytes: []align(@alignOf(c.AudioBufferList)) const u8) ?StreamConfiguration {
    if (bytes.len < @offsetOf(c.AudioBufferList, "mBuffers")) return null;
    const list: *const c.AudioBufferList = @ptrCast(bytes.ptr);
    const buffer_offset = @offsetOf(c.AudioBufferList, "mBuffers");
    const available_buffers = (bytes.len - buffer_offset) / @sizeOf(c.AudioBuffer);
    if (list.mNumberBuffers > available_buffers) return null;
    const buffers: [*]const c.AudioBuffer = @ptrCast(&list.mBuffers);
    var channels: u32 = 0;
    var hasher = std.hash.Wyhash.init(0);
    const buffer_count = list.mNumberBuffers;
    hasher.update(std.mem.asBytes(&buffer_count));
    for (buffers[0..buffer_count]) |buffer| {
        channels += buffer.mNumberChannels;
        const buffer_shape = [2]u32{ buffer.mNumberChannels, buffer.mDataByteSize };
        hasher.update(std.mem.sliceAsBytes(&buffer_shape));
    }
    return .{ .channels = channels, .hash = hasher.final() };
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

fn livenessNowMs() u64 {
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &time) != 0) return 0;
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

fn noFollow() c_int {
    return if (@hasDecl(c, "O_NOFOLLOW")) c.O_NOFOLLOW else 0;
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

    fn from(session: *AudioSession) *TestCoreAudio {
        return @ptrCast(@alignCast(session.core_audio_test_context.?));
    }

    fn query(session: *AudioSession) anyerror!RouteSnapshot {
        return from(session).route;
    }

    fn ready(session: *AudioSession) bool {
        return from(session).built;
    }

    fn build(session: *AudioSession, route: RouteSnapshot) anyerror!void {
        const self = from(session);
        self.builds += 1;
        if (self.bind_failure) return error.AudioInputUnavailable;
        self.bound_device = route.device;
        self.built = true;
    }

    fn start(session: *AudioSession) anyerror!void {
        const self = from(session);
        if (!self.built) return error.AudioInputUnavailable;
        self.starts += 1;
        self.running = true;
    }

    fn stop(session: *AudioSession) void {
        const self = from(session);
        if (!self.running) return;
        self.stops += 1;
        self.running = false;
    }

    fn dispose(session: *AudioSession) void {
        const self = from(session);
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
    return .{
        .allocator = std.testing.allocator,
        .sink = .{ .context = log, .emit = TestEventLog.emit, .abort = TestEventLog.abort },
        .audio_dir = try std.testing.allocator.dupeZ(u8, "/tmp"),
        .core_audio_ops = TestCoreAudio.ops(),
        .core_audio_test_context = fake,
    };
}

fn deinitTestCoreAudioSession(session: *AudioSession) void {
    session.disposeBackend();
    std.testing.allocator.free(session.audio_dir);
}

test "idle default input A to B rebuilds and starts only B" {
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
    try std.testing.expectEqual(session.route_generation.load(.acquire), session.active_route_generation.load(.acquire));
}

test "active route loss fails the generation and removes partial audio" {
    const path: [:0]const u8 = "/tmp/friday-coreaudio-route-loss-test.f32";
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.startCoreAudio();
    session.backend = .core_audio;
    session.backend_ready.store(true, .release);
    session.ring = try Spsc.init(std.testing.allocator, 16);
    session.state.store(@intFromEnum(State.recording), .release);
    session.accepting.store(true, .release);
    session.session_id = 91;
    session.fd = c.open(path.ptr, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
    try std.testing.expect(session.fd >= 0);
    @memcpy(session.current_path[0..path.len], path[0..path.len]);
    session.current_path[path.len] = 0;
    session.current_path_len = path.len;
    session.worker = try std.Thread.spawn(.{}, AudioSession.workerMain, .{&session});

    fake.route = testRoute(20, 48_000, 2);
    session.invalidateCoreAudioRoute(false);
    try std.testing.expect(!session.accepting.load(.acquire));
    try std.testing.expect(session.coreAudioRouteIsStale());
    var attempts: usize = 0;
    while (session.currentState() != .failed and attempts < 250) : (attempts += 1) _ = c.usleep(1000);
    session.joinWorker();

    try std.testing.expectEqual(State.failed, session.currentState());
    try std.testing.expect(attempts < 250);
    try std.testing.expectEqual(@as(c_int, -1), session.fd);
    try std.testing.expectEqual(@as(c_int, -1), c.access(path.ptr, c.F_OK));
    try std.testing.expect(session.retry_path == null);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expectEqualStrings("audio_interrupted", log.event[0..log.event_len]);
    try std.testing.expect(std.mem.indexOf(u8, log.payload[0..log.payload_len], "\"sessionId\":91") != null);
}

test "callback liveness loss stops capture and removes partial audio within worker deadline" {
    const path: [:0]const u8 = "/tmp/friday-coreaudio-callback-stall-test.f32";
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.startCoreAudio();
    session.backend = .core_audio;
    session.backend_ready.store(true, .release);
    session.ring = try Spsc.init(std.testing.allocator, 16);
    session.state.store(@intFromEnum(State.recording), .release);
    session.accepting.store(true, .release);
    session.session_id = 92;
    session.last_callback_at_ms.store(livenessNowMs() -| (callback_liveness_timeout_ms + 1), .release);
    session.fd = c.open(path.ptr, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
    try std.testing.expect(session.fd >= 0);
    @memcpy(session.current_path[0..path.len], path[0..path.len]);
    session.current_path[path.len] = 0;
    session.current_path_len = path.len;

    const started = nowMs();
    session.worker = try std.Thread.spawn(.{}, AudioSession.workerMain, .{&session});
    session.joinWorker();

    try std.testing.expect(nowMs() -| started < 250);
    try std.testing.expectEqual(State.failed, session.currentState());
    try std.testing.expectEqual(Failure.callback_liveness, @as(Failure, @enumFromInt(session.failure.load(.acquire))));
    try std.testing.expectEqual(@as(c_int, -1), session.fd);
    try std.testing.expectEqual(@as(c_int, -1), c.access(path.ptr, c.F_OK));
    try std.testing.expect(session.retry_path == null);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try std.testing.expectEqualStrings("audio_interrupted", log.event[0..log.event_len]);
    try std.testing.expectEqual(@as(usize, 1), log.abort_count);
}

test "sleep invalidation cleans active capture without a core held or locked transition" {
    const path: [:0]const u8 = "/tmp/friday-coreaudio-sleep-test.f32";
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.startCoreAudio();
    session.backend = .core_audio;
    session.backend_ready.store(true, .release);
    session.ring = try Spsc.init(std.testing.allocator, 16);
    session.state.store(@intFromEnum(State.recording), .release);
    session.accepting.store(true, .release);
    session.session_id = 93;
    session.last_callback_at_ms.store(livenessNowMs(), .release);
    session.fd = c.open(path.ptr, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
    try std.testing.expect(session.fd >= 0);
    @memcpy(session.current_path[0..path.len], path[0..path.len]);
    session.current_path[path.len] = 0;
    session.current_path_len = path.len;
    session.invalidateCoreAudioRoute(true);

    const started = nowMs();
    session.worker = try std.Thread.spawn(.{}, AudioSession.workerMain, .{&session});
    session.joinWorker();

    try std.testing.expect(nowMs() -| started < 250);
    try std.testing.expectEqual(State.failed, session.currentState());
    try std.testing.expectEqual(@as(c_int, -1), c.access(path.ptr, c.F_OK));
    try std.testing.expect(session.retry_path == null);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try std.testing.expectEqual(@as(usize, 1), log.abort_count);
}

test "rejected lifecycle event fails capture closed and removes partial audio" {
    const path: [:0]const u8 = "/tmp/friday-coreaudio-event-rejection-test.f32";
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    var fake = TestCoreAudio{};
    var log = TestEventLog{ .accepted = false };
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.startCoreAudio();
    session.backend = .core_audio;
    session.backend_ready.store(true, .release);
    session.ring = try Spsc.init(std.testing.allocator, 16);
    session.state.store(@intFromEnum(State.recording), .release);
    session.accepting.store(true, .release);
    session.session_id = 94;
    session.started_at_ms = nowMs();
    session.last_callback_at_ms.store(livenessNowMs(), .release);
    session.fd = c.open(path.ptr, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
    try std.testing.expect(session.fd >= 0);
    @memcpy(session.current_path[0..path.len], path[0..path.len]);
    session.current_path[path.len] = 0;
    session.current_path_len = path.len;
    try std.testing.expectError(error.EventDeliveryFailed, session.writeFrames(&.{0.25}));
    session.failWorker(.event_delivery);

    try std.testing.expectEqual(State.failed, session.currentState());
    try std.testing.expectEqual(Failure.event_delivery, @as(Failure, @enumFromInt(session.failure.load(.acquire))));
    try std.testing.expectEqual(@as(c_int, -1), c.access(path.ptr, c.F_OK));
    try std.testing.expect(session.retry_path == null);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try std.testing.expectEqual(@as(usize, 1), log.abort_count);
}

test "duration limit stops the backend and exits before stop handoff" {
    const path: [:0]const u8 = "/tmp/friday-coreaudio-duration-limit-test.f32";
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer deinitTestCoreAudioSession(&session);

    try session.startCoreAudio();
    session.backend = .core_audio;
    session.backend_ready.store(true, .release);
    session.ring = try Spsc.init(std.testing.allocator, 16);
    session.state.store(@intFromEnum(State.recording), .release);
    session.accepting.store(true, .release);
    session.session_id = 95;
    session.started_at_ms = nowMs() -| 600_000;
    session.last_callback_at_ms.store(livenessNowMs(), .release);
    session.frames.store(maximum_frames - 1, .release);
    session.fd = c.open(path.ptr, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
    try std.testing.expect(session.fd >= 0);
    @memcpy(session.current_path[0..path.len], path[0..path.len]);
    session.current_path[path.len] = 0;
    session.current_path_len = path.len;
    try session.writeFrames(&.{0.25});
    var attempts: usize = 0;
    while (session.currentState() != .limit_reached and attempts < 250) : (attempts += 1) _ = c.usleep(1000);
    try std.testing.expect(attempts < 250);
    try std.testing.expect(!session.accepting.load(.acquire));
    try std.testing.expect(!fake.running);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);

    session.worker = try std.Thread.spawn(.{}, AudioSession.workerMain, .{&session});
    const handoff_started = nowMs();
    const result = session.stopLocked(95);
    try std.testing.expect(nowMs() -| handoff_started < 250);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(maximum_frames, result.frames);
    try std.testing.expectEqual(State.idle, session.currentState());
    try std.testing.expect(session.retryAudioPath() != null);
    session.discardRetryAudio();
    try std.testing.expectEqual(@as(c_int, -1), c.access(path.ptr, c.F_OK));
}

test "device bind failure disposes the stale unit and fails closed" {
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
    try std.testing.expectEqual(@as(u64, 0), session.prepared_route_generation);
    try std.testing.expectEqual(@as(u64, 0), session.active_route_generation.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fake.starts);
}

test "repeated wake invalidation rebuilds without retaining stale units" {
    var fake = TestCoreAudio{};
    var log = TestEventLog{};
    var session = try initTestCoreAudioSession(&fake, &log);
    defer std.testing.allocator.free(session.audio_dir);

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

test "PlatformServices capture drains canonical Float32 and retains retry audio" {
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
