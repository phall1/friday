const std = @import("std");
const objc = @import("objc.zig");
const route_mod = @import("audio_route.zig");
const c = @import("audio_ffi.zig").api;

extern "c" var NSWorkspaceDidWakeNotification: objc.Id;
extern "c" var NSWorkspaceWillSleepNotification: objc.Id;

const callback_frames = 4096;

pub const Sink = struct {
    context: ?*anyopaque = null,
    accepting: *const fn (?*anyopaque) bool,
    push: *const fn (?*anyopaque, []const f32) void,
    drop: *const fn (?*anyopaque, u32) void,
    invalidate_route: *const fn (?*anyopaque, bool) void,
    fail: *const fn (?*anyopaque, i32) void,
};

/// Owns every CoreAudio resource and callback. The capture coordinator sees
/// only canonical samples, route invalidation, and failure facts.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    unit: c.AudioUnit = null,
    converter: c.AudioConverterRef = null,
    capture_buffer: []f32 = &.{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    device_id: c.AudioDeviceID = c.kAudioObjectUnknown,
    last_status: std.atomic.Value(i32) = std.atomic.Value(i32).init(c.noErr),
    system_listener: bool = false,
    device_listener: bool = false,
    rate_listener: bool = false,
    stream_listener: bool = false,
    power_observer: objc.Id = null,

    pub fn init(allocator: std.mem.Allocator, sink: Sink) Backend {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn bind(self: *Backend, context: *anyopaque) void {
        self.sink.context = context;
    }

    pub fn queryRoute(self: *Backend) !route_mod.Snapshot {
        var device = c.kAudioObjectUnknown;
        var size: u32 = @sizeOf(c.AudioDeviceID);
        var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.statusOk(c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &address, 0, null, &size, &device)) or size != @sizeOf(c.AudioDeviceID) or device == c.kAudioObjectUnknown)
            return error.AudioInputUnavailable;

        var alive: u32 = 0;
        size = @sizeOf(u32);
        address = .{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.statusOk(c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &alive)) or size != @sizeOf(u32) or alive == 0)
            return error.AudioInputUnavailable;

        var rate: f64 = 0;
        size = @sizeOf(f64);
        address = .{ .mSelector = c.kAudioDevicePropertyNominalSampleRate, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.statusOk(c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &rate)) or size != @sizeOf(f64) or !std.math.isFinite(rate) or rate < 8000 or rate > 384_000)
            return error.UnconvertibleInputFormat;

        address = .{ .mSelector = c.kAudioDevicePropertyStreamConfiguration, .mScope = c.kAudioObjectPropertyScopeInput, .mElement = c.kAudioObjectPropertyElementMain };
        size = 0;
        if (!self.statusOk(c.AudioObjectGetPropertyDataSize(device, &address, 0, null, &size)) or size == 0 or size > 4096)
            return error.UnconvertibleInputFormat;
        var bytes: [4096]u8 align(@alignOf(c.AudioBufferList)) = @splat(0);
        if (!self.statusOk(c.AudioObjectGetPropertyData(device, &address, 0, null, &size, &bytes)) or size == 0 or size > bytes.len)
            return error.UnconvertibleInputFormat;
        const stream = streamConfiguration(bytes[0..size]) orelse return error.UnconvertibleInputFormat;
        if (stream.channels == 0) return error.UnconvertibleInputFormat;
        return .{ .device = device, .sample_rate_bits = @bitCast(rate), .stream_hash = stream.hash, .channels = stream.channels };
    }

    pub fn deviceName(self: *Backend, device: c.AudioDeviceID, output: []u8) ?[]const u8 {
        var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioObjectPropertyName, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        var cf_name: c.CFStringRef = null;
        var size: u32 = @sizeOf(c.CFStringRef);
        if (!self.statusOk(c.AudioObjectGetPropertyData(device, &address, 0, null, &size, @ptrCast(&cf_name))) or size != @sizeOf(c.CFStringRef) or cf_name == null) return null;
        defer c.CFRelease(cf_name);
        if (c.CFStringGetCString(cf_name, output.ptr, @intCast(output.len), c.kCFStringEncodingUTF8) == 0) return null;
        return std.mem.sliceTo(output, 0);
    }

    pub fn ready(self: *const Backend) bool {
        return self.unit != null and self.converter != null and self.capture_buffer.len != 0;
    }

    pub fn build(self: *Backend, route: route_mod.Snapshot) !void {
        var description = c.AudioComponentDescription{ .componentType = c.kAudioUnitType_Output, .componentSubType = c.kAudioUnitSubType_HALOutput, .componentManufacturer = c.kAudioUnitManufacturer_Apple, .componentFlags = 0, .componentFlagsMask = 0 };
        const component = c.AudioComponentFindNext(null, &description) orelse return error.AudioInputUnavailable;
        if (!self.statusOk(c.AudioComponentInstanceNew(component, &self.unit)) or self.unit == null) return error.AudioInputUnavailable;
        var one: u32 = 1;
        var zero: u32 = 0;
        if (!self.statusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Input, 1, &one, @sizeOf(u32)))) return error.AudioInputUnavailable;
        if (!self.statusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Output, 0, &zero, @sizeOf(u32)))) return error.AudioInputUnavailable;
        self.device_id = route.device;
        if (!self.statusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_CurrentDevice, c.kAudioUnitScope_Global, 0, &self.device_id, @sizeOf(c.AudioDeviceID)))) return error.AudioInputUnavailable;
        var format = floatFormat();
        if (!self.statusOk(c.AudioUnitSetProperty(self.unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &format, @sizeOf(c.AudioStreamBasicDescription)))) return error.UnconvertibleInputFormat;
        self.capture_buffer = try self.allocator.alloc(f32, callback_frames);
        var callback = c.AURenderCallbackStruct{ .inputProc = audioCallback, .inputProcRefCon = self };
        if (!self.statusOk(c.AudioUnitSetProperty(self.unit, c.kAudioOutputUnitProperty_SetInputCallback, c.kAudioUnitScope_Global, 0, &callback, @sizeOf(c.AURenderCallbackStruct)))) return error.AudioInputUnavailable;
        if (!self.statusOk(c.AudioUnitInitialize(self.unit))) return error.AudioInputUnavailable;
        if (!self.statusOk(c.AudioConverterNew(&format, &format, &self.converter))) return error.ConverterUnavailable;
        try self.addRouteListeners();
    }

    pub fn start(self: *Backend) !void {
        const unit = self.unit orelse return error.AudioInputUnavailable;
        if (!self.statusOk(c.AudioOutputUnitStart(unit))) return error.AudioInputUnavailable;
        self.running.store(true, .release);
    }

    pub fn stop(self: *Backend) void {
        if (!self.running.load(.acquire)) return;
        const unit = self.unit orelse {
            self.running.store(false, .release);
            return;
        };
        if (self.statusOk(c.AudioOutputUnitStop(unit))) {
            self.running.store(false, .release);
        } else self.sink.fail(self.sink.context, self.last_status.load(.acquire));
    }

    pub fn convert(self: *Backend, input: []const f32, output: []f32) ![]const f32 {
        const converter = self.converter orelse return error.ConverterUnavailable;
        var input_list = monoList(@constCast(input.ptr), input.len);
        var output_list = monoList(output.ptr, output.len);
        if (!self.statusOk(c.AudioConverterConvertComplexBuffer(converter, @intCast(input.len), &input_list, &output_list))) return error.ConversionFailed;
        const output_frames = output_list.mBuffers[0].mDataByteSize / @sizeOf(f32);
        if (output_frames > output.len) return error.ConversionFailed;
        return output[0..output_frames];
    }

    pub fn dispose(self: *Backend) void {
        self.removeRouteListeners();
        if (self.unit) |unit| {
            _ = self.statusOk(c.AudioUnitUninitialize(unit));
            _ = self.statusOk(c.AudioComponentInstanceDispose(unit));
            self.unit = null;
        }
        if (self.converter) |converter| {
            _ = self.statusOk(c.AudioConverterDispose(converter));
            self.converter = null;
        }
        if (self.capture_buffer.len != 0) {
            self.allocator.free(self.capture_buffer);
            self.capture_buffer = &.{};
        }
        self.running.store(false, .release);
        self.device_id = c.kAudioObjectUnknown;
    }

    pub fn installPowerObserver(self: *Backend) !void {
        if (self.power_observer != null) return;
        const observer_class = ensurePowerObserverClass() orelse return error.RouteMonitoringUnavailable;
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

    pub fn removePowerObserver(self: *Backend) void {
        const observer = self.power_observer orelse return;
        const workspace = objc.send0(objc.Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const center = objc.send0(objc.Id, workspace, objc.selector("notificationCenter"));
        if (center != null) objc.send1(void, objc.Id, center, objc.selector("removeObserver:"), observer);
        objc.setPointerIvar(observer, "fridayContext", null);
        objc.release(observer);
        self.power_observer = null;
    }

    fn addRouteListeners(self: *Backend) !void {
        var system = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.statusOk(c.AudioObjectAddPropertyListener(c.kAudioObjectSystemObject, &system, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.system_listener = true;
        var alive = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.statusOk(c.AudioObjectAddPropertyListener(self.device_id, &alive, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.device_listener = true;
        var rate = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyNominalSampleRate, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.statusOk(c.AudioObjectAddPropertyListener(self.device_id, &rate, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.rate_listener = true;
        var stream = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyStreamConfiguration, .mScope = c.kAudioObjectPropertyScopeInput, .mElement = c.kAudioObjectPropertyElementMain };
        if (!self.statusOk(c.AudioObjectAddPropertyListener(self.device_id, &stream, routeListener, self))) return error.RouteMonitoringUnavailable;
        self.stream_listener = true;
    }

    fn removeRouteListeners(self: *Backend) void {
        if (self.system_listener) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioHardwarePropertyDefaultInputDevice, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.statusOk(c.AudioObjectRemovePropertyListener(c.kAudioObjectSystemObject, &address, routeListener, self));
            self.system_listener = false;
        }
        if (self.device_listener and self.device_id != c.kAudioObjectUnknown) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyDeviceIsAlive, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.statusOk(c.AudioObjectRemovePropertyListener(self.device_id, &address, routeListener, self));
            self.device_listener = false;
        }
        if (self.rate_listener and self.device_id != c.kAudioObjectUnknown) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyNominalSampleRate, .mScope = c.kAudioObjectPropertyScopeGlobal, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.statusOk(c.AudioObjectRemovePropertyListener(self.device_id, &address, routeListener, self));
            self.rate_listener = false;
        }
        if (self.stream_listener and self.device_id != c.kAudioObjectUnknown) {
            var address = c.AudioObjectPropertyAddress{ .mSelector = c.kAudioDevicePropertyStreamConfiguration, .mScope = c.kAudioObjectPropertyScopeInput, .mElement = c.kAudioObjectPropertyElementMain };
            _ = self.statusOk(c.AudioObjectRemovePropertyListener(self.device_id, &address, routeListener, self));
            self.stream_listener = false;
        }
    }

    fn statusOk(self: *Backend, status: c.OSStatus) bool {
        if (status == c.noErr) return true;
        self.last_status.store(status, .release);
        return false;
    }
};

fn audioCallback(context: ?*anyopaque, flags: [*c]c.AudioUnitRenderActionFlags, timestamp: ?*const c.AudioTimeStamp, bus: u32, frames: u32, ignored: [*c]c.AudioBufferList) callconv(.c) c.OSStatus {
    _ = bus;
    _ = ignored;
    const self: *Backend = @ptrCast(@alignCast(context orelse return c.noErr));
    if (!self.sink.accepting(self.sink.context)) return c.noErr;
    if (frames > self.capture_buffer.len) {
        self.sink.drop(self.sink.context, frames);
        return c.noErr;
    }
    var list = monoList(self.capture_buffer.ptr, frames);
    const status = c.AudioUnitRender(self.unit, flags, timestamp, 1, frames, &list);
    if (status != c.noErr) {
        self.last_status.store(status, .release);
        self.sink.fail(self.sink.context, status);
        return status;
    }
    self.sink.push(self.sink.context, self.capture_buffer[0..frames]);
    return c.noErr;
}

fn routeListener(object: c.AudioObjectID, count: u32, addresses: [*c]const c.AudioObjectPropertyAddress, context: ?*anyopaque) callconv(.c) c.OSStatus {
    const self: *Backend = @ptrCast(@alignCast(context orelse return c.noErr));
    _ = object;
    for (addresses[0..count]) |address| {
        if (address.mSelector == c.kAudioHardwarePropertyDefaultInputDevice or
            address.mSelector == c.kAudioDevicePropertyDeviceIsAlive or
            address.mSelector == c.kAudioDevicePropertyNominalSampleRate or
            address.mSelector == c.kAudioDevicePropertyStreamConfiguration)
        {
            self.sink.invalidate_route(self.sink.context, false);
            break;
        }
    }
    return c.noErr;
}

fn observerWake(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (objc.getPointerIvar(Backend, receiver, "fridayContext")) |self| self.sink.invalidate_route(self.sink.context, false);
}

fn observerSleep(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (objc.getPointerIvar(Backend, receiver, "fridayContext")) |self| self.sink.invalidate_route(self.sink.context, true);
}

fn ensurePowerObserverClass() objc.Class {
    if (objc.lookupClass("FridayZigAudioPowerObserver")) |existing| return existing;
    const cls = objc.allocateClassPair(objc.class("NSObject"), "FridayZigAudioPowerObserver") orelse return null;
    if (!objc.addPointerIvar(cls, "fridayContext")) return null;
    _ = objc.addMethod(cls, objc.selector("fridayAudioWake:"), &observerWake, "v@:@");
    _ = objc.addMethod(cls, objc.selector("fridayAudioSleep:"), &observerSleep, "v@:@");
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
        const shape = [2]u32{ buffer.mNumberChannels, buffer.mDataByteSize };
        hasher.update(std.mem.sliceAsBytes(&shape));
    }
    return .{ .channels = channels, .hash = hasher.final() };
}

pub fn testContracts() !void {
    var list = std.mem.zeroes(c.AudioBufferList);
    list.mNumberBuffers = 1;
    list.mBuffers[0] = .{ .mNumberChannels = 2, .mDataByteSize = 512, .mData = null };
    const first = streamConfiguration(std.mem.asBytes(&list)).?;
    try std.testing.expectEqual(@as(u32, 2), first.channels);

    list.mBuffers[0].mDataByteSize = 1024;
    const changed = streamConfiguration(std.mem.asBytes(&list)).?;
    try std.testing.expect(first.hash != changed.hash);

    list.mNumberBuffers = 2;
    try std.testing.expect(streamConfiguration(std.mem.asBytes(&list)) == null);
}

test "production backend validates route stream shape" {
    try testContracts();
}
