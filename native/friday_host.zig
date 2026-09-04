const std = @import("std");
const native_sdk = @import("native_sdk");
const audio_mod = @import("macos/audio.zig");
const delivery_mod = @import("macos/delivery.zig");
const input_mod = @import("macos/input.zig");
const json = @import("macos/json.zig");
const models_mod = @import("macos/models.zig");
const nemo_mod = @import("macos/nemo.zig");
const objc = @import("macos/objc.zig");
const overlay_mod = @import("macos/overlay.zig");
const system = @import("macos/system.zig");

extern "c" var NSApplicationWillTerminateNotification: objc.Id;
extern "c" var NSWindowDidChangeOcclusionStateNotification: objc.Id;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const completion_capacity = 128;
const result_capacity = 64 * 1024;
const event_channel_key: u64 = 7001;
const source_capacity = 8;
const sample_capacity = 64;

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

const Completion = struct {
    key: u64 = 0,
    ok: bool = false,
    length: usize = 0,
    cancelled: bool = false,
    bytes: [result_capacity]u8 = undefined,
};

const AsyncKind = enum {
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

const AsyncStage = enum { initial, stopping, activating, transcribing };

const Operation = struct {
    host: *FridayHost = undefined,
    used: bool = false,
    pending: bool = false,
    key: u64 = 0,
    kind: AsyncKind = .hotkey_capture,
    stage: AsyncStage = .initial,
    generation: u64 = 0,
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

const Transcript = struct {
    used: bool = false,
    session: u64 = 0,
    generation: u64 = 0,
    text: ?[]u8 = null,
};

const SessionGeneration = struct { used: bool = false, session: u64 = 0, generation: u64 = 0 };

const Samples = struct {
    values: [sample_capacity]u64 = @splat(0),
    count: usize = 0,

    fn append(self: *Samples, value: u64) void {
        if (self.count == self.values.len) {
            std.mem.copyForwards(u64, self.values[0 .. self.values.len - 1], self.values[1..]);
            self.count -= 1;
        }
        self.values[self.count] = value;
        self.count += 1;
    }
};

pub const FridayHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_directory: []u8,

    input: input_mod.GlobalInputMonitor,
    delivery: delivery_mod.TextDelivery,
    overlay: overlay_mod.Overlay,
    audio: audio_mod.AudioSession,
    recognizer: nemo_mod.NemoRecognizer,
    models: models_mod.ModelRepository,

    mutex: SpinMutex = .{},
    request_mutex: SpinMutex = .{},
    completions: [completion_capacity]Completion = @splat(.{}),
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    operations: [completion_capacity]Operation = @splat(.{}),
    pending_count: usize = 0,
    closing: bool = false,

    channels: ?native_sdk.HostChannelBinding = null,
    event_handle: ?native_sdk.ChannelHandle = null,
    services: ?native_sdk.platform.PlatformServices = null,
    termination_observer: objc.Id = null,
    metrics_mutex: SpinMutex = .{},
    performance_output_path: ?[]u8 = null,
    event_post_failures: u64 = 0,
    microphone_permission_probe_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    microphone_permission_probe_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    generation: u64 = 0,
    current_audio_session: u64 = 0,
    current_audio_generation: u64 = 0,
    audio_start_key: u64 = 0,
    sources: [source_capacity]?*delivery_mod.SourceTarget = @splat(null),
    source_count: usize = 0,
    transcripts: [completion_capacity]Transcript = @splat(.{}),
    audio_generations: [completion_capacity]SessionGeneration = @splat(.{}),

    last_inference_duration_ms: u64 = 0,
    last_audio_duration_ms: u64 = 0,
    last_error_code: [64]u8 = @splat(0),
    last_error_code_len: usize = 0,
    last_hotkey_received_at_ms: u64 = 0,
    last_stop_requested_at_ms: u64 = 0,
    last_resident_bytes: u64 = 0,
    hotkey_to_first_sample_ms: Samples = .{},
    stop_to_drain_ms: Samples = .{},
    stop_to_text_ms: Samples = .{},
    text_to_delivery_ms: Samples = .{},
    dropped_frames: Samples = .{},

    scratch: [result_capacity]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, app_data_dir: []const u8) !*FridayHost {
        const self = try allocator.create(FridayHost);
        errdefer allocator.destroy(self);
        const directory = try allocator.dupe(u8, app_data_dir);
        errdefer allocator.free(directory);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .data_directory = directory,
            .input = undefined,
            .delivery = undefined,
            .overlay = undefined,
            .audio = undefined,
            .recognizer = undefined,
            .models = undefined,
        };

        if (getenv("FRIDAY_AUTOMATION_METRICS_OUTPUT")) |path| {
            const value = std.mem.span(path);
            if (value.len > 0) self.performance_output_path = try allocator.dupe(u8, value);
        }
        errdefer if (self.performance_output_path) |path| allocator.free(path);
        self.delivery = try delivery_mod.TextDelivery.init(allocator);
        errdefer self.delivery.deinit();
        self.recognizer = try nemo_mod.NemoRecognizer.init(allocator);
        errdefer self.recognizer.deinit();
        self.audio = try audio_mod.AudioSession.init(allocator, app_data_dir, .{ .context = self, .emit = audioEvent });
        errdefer self.audio.deinit();
        self.overlay = try overlay_mod.Overlay.init(allocator, .{ .context = self, .emit = overlayEvent });
        errdefer self.overlay.deinit();
        self.input = try input_mod.GlobalInputMonitor.init(allocator, .{ .context = self, .emit = inputEvent });
        errdefer self.input.deinit();
        self.models = try models_mod.ModelRepository.init(allocator, app_data_dir, .{ .context = self, .probe = probeRecognizer }, .{ .context = self, .emit = modelProgress });
        errdefer self.models.deinit();
        try self.installTerminationObserver();

        if (self.models.activeModelPath()) |path| {
            self.recognizer.activateModel(path, 0, .{ .context = self, .complete = startupActivation }) catch {};
        }
        return self;
    }

    pub fn destroy(self: *FridayHost) void {
        self.mutex.lock();
        self.closing = true;
        self.event_handle = null;
        self.channels = null;
        const services = self.services;
        self.services = null;
        self.mutex.unlock();
        if (self.microphone_permission_probe_active.swap(false, .acq_rel))
            if (services) |live| live.audioCaptureStop(.microphone) catch {};
        self.removeTerminationObserver();

        self.input.stop();
        self.audio.cancelActiveSession();
        self.recognizer.deinit();
        self.models.deinit();
        self.audio.deinit();
        self.input.deinit();
        self.overlay.hide();
        self.overlay.deinit();
        self.delivery.deinit();

        for (self.sources[0..self.source_count]) |entry| if (entry) |source| self.destroySource(source);
        for (&self.transcripts) |*entry| if (entry.text) |text| self.allocator.free(text);
        for (&self.operations) |*operation| if (operation.saved) |saved| self.allocator.free(saved);
        self.allocator.free(self.data_directory);
        if (self.performance_output_path) |path| self.allocator.free(path);
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
            .bind_services_fn = bindServices,
            .bind_channels_fn = bindChannels,
        };
    }

    fn bindServices(context: *anyopaque, services: *const native_sdk.platform.PlatformServices) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        if (self.closing) {
            self.mutex.unlock();
            return;
        }
        self.services = services.*;
        self.mutex.unlock();

        self.audio.setServices(services.*);
        self.audio.useDirectCoreAudio();
        self.overlay.setServices(services.*);
    }
    fn installTerminationObserver(self: *FridayHost) !void {
        const observer_class = ensureTerminationObserverClass() orelse return error.TerminationObserverUnavailable;
        const observer = objc.send0(objc.Id, observer_class, objc.selector("new"));
        if (observer == null) return error.TerminationObserverUnavailable;
        objc.setPointerIvar(observer, "fridayContext", self);
        const center = objc.send0(objc.Id, objc.class("NSNotificationCenter"), objc.selector("defaultCenter"));
        objc.send4(void, objc.Id, objc.Sel, objc.Id, objc.Id, center, objc.selector("addObserver:selector:name:object:"), observer, objc.selector("fridayWillTerminate:"), NSApplicationWillTerminateNotification, null);
        // Dock presence follows real window visibility, not just core-driven
        // show/hide commands: the close_policy=hide red button orders the
        // main window out without any core message, and this notification is
        // the only signal that reaches Friday. Panels (the capsule, open
        // panels, menus) never count as a Dock-worthy window.
        objc.send4(void, objc.Id, objc.Sel, objc.Id, objc.Id, center, objc.selector("addObserver:selector:name:object:"), observer, objc.selector("fridayWindowOcclusionChanged:"), NSWindowDidChangeOcclusionStateNotification, null);
        self.termination_observer = observer;
    }

    fn syncDockPresence(self: *FridayHost) void {
        _ = self;
        const app = objc.send0(objc.Id, objc.class("NSApplication"), objc.selector("sharedApplication"));
        const windows = objc.send0(objc.Id, app, objc.selector("windows"));
        const count = objc.send0(usize, windows, objc.selector("count"));
        var any_visible_main = false;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const window = objc.send1(objc.Id, usize, windows, objc.selector("objectAtIndex:"), index);
            if (!objc.send0(bool, window, objc.selector("isVisible"))) continue;
            if (objc.isKindOfClass(window, objc.class("NSPanel"))) continue;
            if (objc.send0(isize, window, objc.selector("level")) != 0) continue;
            any_visible_main = true;
            break;
        }
        // NSApplicationActivationPolicyRegular = 0, Accessory = 1.
        objc.send1(void, isize, app, objc.selector("setActivationPolicy:"), if (any_visible_main) 0 else 1);
    }

    fn removeTerminationObserver(self: *FridayHost) void {
        const observer = self.termination_observer orelse return;
        const center = objc.send0(objc.Id, objc.class("NSNotificationCenter"), objc.selector("defaultCenter"));
        objc.send1(void, objc.Id, center, objc.selector("removeObserver:"), observer);
        objc.setPointerIvar(observer, "fridayContext", null);
        objc.release(observer);
        self.termination_observer = null;
    }

    fn bindChannels(context: *anyopaque, channels: native_sdk.HostChannelBinding) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing) self.channels = channels;
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        _ = self.syncRequest(name, payload, &self.scratch);
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, "friday.subscribe")) return self.subscribe(key);
        if (asyncKind(name)) |kind| {
            const operation = self.beginOperation(key, kind) orelse {
                self.enqueue(key, false, "{\"ok\":false,\"code\":\"async_key_unavailable\"}");
                return;
            };
            self.startAsync(operation, payload);
            return;
        }
        self.request_mutex.lock();
        const length = self.syncRequest(name, payload, &self.scratch);
        const ok = length > 0 and json.objectOk(self.scratch[0..length]);
        self.enqueue(key, ok, if (length > 0) self.scratch[0..length] else "{\"ok\":false,\"message\":\"FridayHost response failed.\"}");
        self.request_mutex.unlock();
    }

    fn subscribe(self: *FridayHost, key: u64) void {
        self.mutex.lock();
        const channels = if (!self.closing) self.channels else null;
        self.mutex.unlock();
        const binding_value = channels orelse return self.enqueue(key, false, "{\"ok\":false,\"code\":\"channel_binding_unavailable\"}");
        const handle = binding_value.acquire_fn(binding_value.context, event_channel_key);
        self.mutex.lock();
        if (!self.closing) self.event_handle = handle;
        self.mutex.unlock();
        self.enqueue(key, handle != null, if (handle != null) "{\"ok\":true,\"subscribed\":true}" else "{\"ok\":false,\"code\":\"channel_unavailable\"}");
    }

    fn syncRequest(self: *FridayHost, name: []const u8, payload: []const u8, output: []u8) usize {
        if (std.mem.eql(u8, name, "friday.spike")) return self.writeSpike(output) catch 0;
        if (std.mem.eql(u8, name, "friday.platform")) return system.writePlatformStatus(output) catch 0;
        if (std.mem.eql(u8, name, "friday.permissions")) return self.writePermissions(output);
        if (std.mem.eql(u8, name, "friday.permissions.request")) return self.requestPermission(payload, output);
        if (std.mem.eql(u8, name, "friday.login.status")) return system.writeLoginStatus(output, self.services) catch 0;
        if (std.mem.eql(u8, name, "friday.login.set")) return system.setLoginEnabled(output, self.services, std.mem.eql(u8, payload, "enabled")) catch 0;
        if (std.mem.eql(u8, name, "friday.login.cycle_test")) return system.writeLoginCycle(output, self.services) catch 0;
        if (std.mem.eql(u8, name, "friday.hotkey.configure")) return self.configureHotkey(payload, output);
        if (std.mem.eql(u8, name, "friday.hotkey.probe")) return self.input.writeSyntheticProbe(output) catch json.writeError(output, "hotkey_probe_failed", "The global shortcut probe failed.");
        if (std.mem.eql(u8, name, "friday.performance.mark_hotkey")) {
            self.last_hotkey_received_at_ms = system.wallMs();
            return copyResult(output, "{\"ok\":true,\"marked\":true}");
        }
        if (std.mem.eql(u8, name, "friday.source.capture")) return self.captureSource(output);
        if (std.mem.eql(u8, name, "friday.source.discard")) return self.discardSource(payload, output);
        if (std.mem.eql(u8, name, "friday.deliver")) return self.deliver(payload, output);
        if (std.mem.eql(u8, name, "friday.deliver_session")) return self.deliverSession(payload, output);
        if (std.mem.eql(u8, name, "friday.delivery.probe")) return self.delivery.writeProbe(if (payload.len > 0) payload else "TextEdit", self.services, output) catch json.writeError(output, "delivery_probe_failed", "The exact-source delivery probe failed.");
        if (std.mem.eql(u8, name, "friday.overlay.show")) {
            self.overlay.showLocked(std.mem.eql(u8, payload, "locked"), 0);
            return copyResult(output, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "friday.overlay.transcribing")) {
            self.overlay.showTranscribing();
            return copyResult(output, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "friday.overlay.hide")) {
            self.overlay.hide();
            return copyResult(output, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "friday.overlay.probe")) return self.overlay.writeInteractionProbe(output) catch 0;
        if (std.mem.eql(u8, name, "friday.audio.input_status")) return self.audio.inputStatus(output) catch 0;
        if (std.mem.eql(u8, name, "friday.audio.discard")) {
            self.audio.discardRetryAudio();
            return copyResult(output, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "friday.audio.storage_probe")) return self.audio.writeStorageProbe(output) catch 0;
        if (std.mem.eql(u8, name, "friday.model.status")) return self.models.writeStatus(output) catch 0;
        if (std.mem.eql(u8, name, "friday.model.probes")) return models_mod.ModelRepository.writeContractProbes(output) catch 0;
        if (std.mem.eql(u8, name, "friday.model.cancel")) {
            self.models.cancel(std.fmt.parseUnsigned(u64, payload, 10) catch 0);
            return copyResult(output, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "friday.model.remove")) {
            const old_active = self.models.activeModelKey();
            const model_key = json.unsignedField(payload, "modelKey");
            const length = self.models.remove(model_key, json.boolField(payload, "delete"), output) catch 0;
            if (model_key == old_active and length > 0 and json.objectOk(output[0..length])) self.recognizer.unload(.{ .context = self, .complete = startupActivation }) catch {};
            return length;
        }
        if (std.mem.eql(u8, name, "friday.model.cleanup")) return self.models.removeFailed(output) catch 0;
        if (std.mem.eql(u8, name, "friday.diagnostics")) return self.writeDiagnostics(output) catch 0;
        if (std.mem.eql(u8, name, "friday.diagnostics.export")) return self.exportDiagnostics(output);
        if (std.mem.eql(u8, name, "friday.diagnostics.reveal")) return self.revealDiagnostics(output);
        return json.writeError(output, "unknown_command", "Unknown FridayHost command.");
    }

    fn writeSpike(self: *FridayHost, output: []u8) !usize {
        var bundle_buffer: [512]u8 = undefined;
        const bundle = system.copyBundleIdentifier(&bundle_buffer);
        var permissions: [256]u8 = undefined;
        const permission_length = self.writePermissions(&permissions);
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("{\"ok\":true,\"bridge\":\"ok\",\"platform\":\"macos\",\"bundleIdentifier\":");
        try json.writeString(&writer, bundle);
        try writer.writeAll(",\"permissions\":");
        try writer.writeAll(permissions[0..permission_length]);
        try writer.writeByte('}');
        return writer.buffered().len;
    }

    fn writePermissions(self: *FridayHost, output: []u8) usize {
        return system.writePermissions(output, system.microphoneGranted(), self.input.usable()) catch 0;
    }

    fn requestPermission(self: *FridayHost, payload: []const u8, output: []u8) usize {
        if (std.mem.eql(u8, payload, "input")) self.input.requestPermission();
        if (std.mem.eql(u8, payload, "accessibility")) system.requestAccessibility();
        if (std.mem.eql(u8, payload, "microphone")) self.requestMicrophonePermission();
        const length = self.writePermissions(output);
        self.emitPermissions();
        return length;
    }

    fn requestMicrophonePermission(self: *FridayHost) void {
        if (system.microphoneGranted() or self.microphone_permission_probe_active.swap(true, .acq_rel)) return;
        self.microphone_permission_probe_finished.store(false, .release);
        const services = self.services orelse {
            self.microphone_permission_probe_active.store(false, .release);
            return;
        };
        services.audioCaptureStart(.microphone, .{ .sample_rate = 16_000, .channels = 1 }, .{
            .context = self,
            .push_fn = microphonePermissionProbe,
        }) catch self.microphone_permission_probe_active.store(false, .release);
    }

    fn configureHotkey(self: *FridayHost, payload: []const u8, output: []u8) usize {
        self.input.configure(payload) catch |failure| return json.writeError(output, "invalid_shortcut", switch (failure) {
            error.InvalidShortcut => "Choose a shortcut that does not collide with ordinary typing or a reserved macOS command.",
            else => "Friday could not configure the global shortcut.",
        });
        self.input.start() catch |failure| return json.writeError(output, "hotkey_unavailable", switch (failure) {
            error.InputMonitoringPermissionRequired => "Input Monitoring permission is required for the global shortcut.",
            else => "Friday could not create the global event monitor.",
        });
        return copyResult(output, "{\"ok\":true,\"configured\":true,\"running\":true,\"message\":\"Global shortcut active.\"}");
    }

    fn captureSource(self: *FridayHost, output: []u8) usize {
        var source = self.delivery.captureFrontmostSource() catch return json.writeError(output, "source_unavailable", "Friday could not capture the frontmost application.");
        self.generation += 1;
        source.generation = self.generation;
        const pointer = self.allocator.create(delivery_mod.SourceTarget) catch {
            source.deinit(self.allocator);
            return json.writeError(output, "out_of_memory", "Friday could not retain the source application.");
        };
        pointer.* = source;
        self.addSource(pointer);
        self.setPreferredSourceFrame(pointer.source_screen_frame);
        var writer = std.Io.Writer.fixed(output);
        writer.print("{{\"ok\":true,\"generation\":{d},\"token\":\"", .{self.generation}) catch return 0;
        json.writeBase64(&writer, &pointer.token) catch return 0;
        writer.print("\",\"pid\":{d},\"bundleId\":\"", .{pointer.pid}) catch return 0;
        json.writeBase64(&writer, pointer.bundle_id) catch return 0;
        writer.writeAll("\"}") catch return 0;
        return writer.buffered().len;
    }

    fn discardSource(self: *FridayHost, payload: []const u8, output: []u8) usize {
        const token = json.decodeBase64Alloc(self.allocator, payload) catch null;
        defer if (token) |bytes| self.allocator.free(bytes);
        if (token != null and token.?.len > 0) {
            if (self.findSource(token.?)) |index| self.removeSource(index);
        } else self.removeSourcesForGeneration(self.generation);
        return copyResult(output, "{\"ok\":true}");
    }

    fn deliver(self: *FridayHost, payload: []const u8, output: []u8) usize {
        const split = std.mem.indexOfScalar(u8, payload, '|') orelse return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        if (std.mem.indexOfScalar(u8, payload[split + 1 ..], '|') != null) return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        const token = json.decodeBase64Alloc(self.allocator, payload[0..split]) catch return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        defer self.allocator.free(token);
        const text = json.decodeBase64Alloc(self.allocator, payload[split + 1 ..]) catch return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        defer self.allocator.free(text);
        const index = self.findSource(token) orelse return json.writeError(output, "source_stale", "The source token expired, was consumed, or belongs to a stale generation.");
        const source = self.takeSource(index);
        defer self.destroySource(source);
        if (source.generation != self.generation) return json.writeError(output, "source_stale", "The source token expired, was consumed, or belongs to a stale generation.");
        const length = self.delivery.deliverText(text, source, true, self.services, output) catch json.writeError(output, "delivery_failed", "Friday could not deliver the transcript.");
        self.audio.discardRetryAudio();
        return length;
    }

    fn deliverSession(self: *FridayHost, payload: []const u8, output: []u8) usize {
        const session = json.unsignedField(payload, "session");
        const generation = json.unsignedField(payload, "generation");
        const paste = json.boolField(payload, "paste");
        const transcript = self.takeTranscript(session, generation);
        defer if (transcript) |text| self.allocator.free(text);
        const source_index = self.findSourceGeneration(generation);
        const source = if (source_index) |index| self.takeSource(index) else null;
        defer if (source) |value| self.destroySource(value);
        if (source == null or transcript == null or transcript.?.len == 0 or source.?.generation != generation) {
            self.audio.discardRetryAudio();
            var writer = std.Io.Writer.fixed(output);
            writer.print("{{\"ok\":false,\"sessionId\":{d},\"generation\":{d},\"message\":\"The final transcript or exact source is stale.\"}}", .{ session, generation }) catch return 0;
            return writer.buffered().len;
        }
        var delivery_bytes: [result_capacity]u8 = undefined;
        const started = system.wallMs();
        const delivery_length = self.delivery.deliverText(transcript.?, source.?, paste, self.services, &delivery_bytes) catch json.writeError(&delivery_bytes, "delivery_failed", "Friday could not deliver the transcript.");
        self.appendPerformanceSample(&self.text_to_delivery_ms, system.wallMs() -| started);
        const delivery_result = delivery_bytes[0..delivery_length];
        var writer = std.Io.Writer.fixed(output);
        writer.writeAll(delivery_result[0 .. delivery_result.len - 1]) catch return 0;
        writer.print(",\"sessionId\":{d},\"generation\":{d}", .{ session, generation }) catch return 0;
        if (!json.objectOk(delivery_result) or std.mem.indexOf(u8, delivery_result, "\"kind\":\"shown\"") != null) {
            writer.writeAll(",\"text\":") catch return 0;
            json.writeString(&writer, transcript.?) catch return 0;
        }
        writer.writeByte('}') catch return 0;
        self.audio.discardRetryAudio();
        return writer.buffered().len;
    }

    fn writeDiagnostics(self: *FridayHost, output: []u8) !usize {
        var model_bytes: [result_capacity]u8 = undefined;
        const model_length = try self.models.writeStatus(&model_bytes);
        var audio_bytes: [2048]u8 = undefined;
        const audio_length = try self.audio.diagnostics(&audio_bytes);
        var platform_bytes: [1024]u8 = undefined;
        const platform_length = try system.writePlatformStatus(&platform_bytes);
        var permission_bytes: [256]u8 = undefined;
        const permission_length = self.writePermissions(&permission_bytes);
        var version_buffer: [128]u8 = undefined;
        const app_version = system.copyAppVersion(&version_buffer);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, model_bytes[0..model_length], .{}) catch null;
        defer if (parsed) |*value| value.deinit();
        const model = if (parsed) |*value| value.value.object else null;
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("{\"ok\":true,\"appVersion\":");
        try json.writeString(&writer, app_version);
        try writer.writeAll(",\"nativeSdkVersion\":\"0.10.1\",\"nemoVersion\":\"0.1.0\",\"platform\":");
        try writer.writeAll(platform_bytes[0..platform_length]);
        try writer.writeAll(",\"permissions\":");
        try writer.writeAll(permission_bytes[0..permission_length]);
        try writer.print(",\"hotkeyRunning\":{s},\"sourceTargetsRetained\":{d},\"audio\":", .{ if (self.input.running()) "true" else "false", self.source_count });
        try writer.writeAll(audio_bytes[0..audio_length]);
        try writer.writeAll(",\"modelReady\":");
        try writeObjectField(&writer, model, "activeModelReady", .bool, "false");
        try writer.writeAll(",\"activeModelName\":");
        try writeObjectField(&writer, model, "activeModelName", .string, "\"\"");
        try writer.writeAll(",\"activeModelLicense\":");
        try writeObjectField(&writer, model, "activeModelLicense", .string, "\"\"");
        try writer.writeAll(",\"activeModelBytes\":");
        try writeObjectField(&writer, model, "activeModelBytes", .integer, "0");
        try writer.writeAll(",\"managedModelBytes\":");
        try writeObjectField(&writer, model, "managedBytes", .integer, "0");
        try writer.print(",\"lastAudioDurationMs\":{d},\"lastInferenceDurationMs\":{d},\"performance\":", .{ self.last_audio_duration_ms, self.last_inference_duration_ms });
        try self.writePerformanceObject(&writer);
        try writer.writeAll(",\"lastErrorCode\":");
        try json.writeString(&writer, self.last_error_code[0..self.last_error_code_len]);
        try writer.writeAll(",\"transcriptIncluded\":false,\"audioIncluded\":false,\"rawPathsIncluded\":false}");
        return writer.buffered().len;
    }

    fn writePerformanceObject(self: *FridayHost, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"hotkeyToFirstSampleMs\":");
        try writeSamples(writer, self.hotkey_to_first_sample_ms);
        try writer.writeAll(",\"stopToDrainMs\":");
        try writeSamples(writer, self.stop_to_drain_ms);
        try writer.writeAll(",\"stopToTextMs\":");
        try writeSamples(writer, self.stop_to_text_ms);
        try writer.writeAll(",\"textToDeliveryMs\":");
        try writeSamples(writer, self.text_to_delivery_ms);
        try writer.writeAll(",\"droppedFrames\":");
        try writeSamples(writer, self.dropped_frames);
        try writer.print(",\"residentBytes\":{d},\"transcriptIncluded\":false,\"audioIncluded\":false,\"rawPathsIncluded\":false}}", .{self.last_resident_bytes});
    }

    fn appendPerformanceSample(self: *FridayHost, samples: *Samples, value: u64) void {
        self.metrics_mutex.lock();
        defer self.metrics_mutex.unlock();
        samples.append(value);
        self.writePerformanceSnapshotLocked();
    }

    fn writePerformanceSnapshotLocked(self: *FridayHost) void {
        const path = self.performance_output_path orelse return;
        var bytes: [16 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        self.writePerformanceObject(&writer) catch return;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = writer.buffered() }) catch {};
    }

    fn exportDiagnostics(self: *FridayHost, output: []u8) usize {
        var diagnostics: [result_capacity]u8 = undefined;
        const length = self.writeDiagnostics(&diagnostics) catch return json.writeError(output, "diagnostics_failed", "Friday could not prepare diagnostics.");
        const directory = std.fs.path.join(self.allocator, &.{ self.data_directory, "Diagnostics" }) catch return json.writeError(output, "diagnostics_export_failed", "Friday could not export diagnostics.");
        defer self.allocator.free(directory);
        std.Io.Dir.cwd().createDirPath(self.io, directory) catch return json.writeError(output, "diagnostics_export_failed", "Friday could not export diagnostics.");
        const path = std.fs.path.join(self.allocator, &.{ directory, "friday-diagnostics.json" }) catch return json.writeError(output, "diagnostics_export_failed", "Friday could not export diagnostics.");
        defer self.allocator.free(path);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = diagnostics[0..length] }) catch return json.writeError(output, "diagnostics_export_failed", "Friday could not export diagnostics.");
        return copyResult(output, "{\"ok\":true,\"exported\":true}");
    }

    fn revealDiagnostics(self: *FridayHost, output: []u8) usize {
        const path = std.fs.path.join(self.allocator, &.{ self.data_directory, "Diagnostics", "friday-diagnostics.json" }) catch return json.writeError(output, "diagnostics_reveal_failed", "Export diagnostics before revealing them.");
        defer self.allocator.free(path);
        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return json.writeError(output, "diagnostics_missing", "Export diagnostics before revealing them.");
        file.close(self.io);
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const ns_path = objc.nsString(path);
        defer objc.release(ns_path);
        const url = objc.send1(objc.Id, objc.Id, objc.class("NSURL"), objc.selector("fileURLWithPath:"), ns_path);
        const urls = objc.send1(objc.Id, objc.Id, objc.class("NSArray"), objc.selector("arrayWithObject:"), url);
        const workspace = objc.send0(objc.Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        objc.send1(void, objc.Id, workspace, objc.selector("activateFileViewerSelectingURLs:"), urls);
        return copyResult(output, "{\"ok\":true,\"message\":\"Revealed the diagnostics export.\"}");
    }

    fn startAsync(self: *FridayHost, operation: *Operation, payload: []const u8) void {
        operation.generation = blk: {
            const supplied = json.unsignedField(payload, "generation");
            break :blk if (supplied != 0) supplied else self.generation;
        };
        switch (operation.kind) {
            .hotkey_capture => self.input.beginShortcutCapture(inputCompletion(operation)),
            .debug_contracts => self.finishContracts(operation),
            .audio_start => {
                operation.session = json.unsignedField(payload, "session");
                if (operation.session == 0) operation.session = operation.generation;
                self.current_audio_session = operation.session;
                self.current_audio_generation = operation.generation;
                self.audio_start_key = operation.key;
                self.setAudioGeneration(operation.session, operation.generation);
                self.audio.startSession(operation.session, audioCompletion(operation)) catch self.finishError(operation, "capture_failed", "Capture failed.");
            },
            .audio_stop => {
                operation.session = json.unsignedField(payload, "session");
                if (operation.session == 0) operation.session = self.current_audio_session;
                if (json.unsignedField(payload, "generation") == 0) operation.generation = self.current_audio_generation;
                self.last_stop_requested_at_ms = system.wallMs();
                self.audio.stopSession(operation.session, audioCompletion(operation)) catch self.finishError(operation, "capture_failed", "Capture failed.");
            },
            .transcribe_capture => {
                operation.session = json.unsignedField(payload, "session");
                if (operation.session == 0) operation.session = self.current_audio_session;
                if (json.unsignedField(payload, "generation") == 0) operation.generation = self.current_audio_generation;
                const path = self.audio.retryAudioPath() orelse return self.finishUnavailable(operation, "audio_unavailable", "Captured audio is unavailable.", false);
                if (self.models.activeModelPath() == null) return self.finishUnavailable(operation, "model_unavailable", "The active model is unavailable.", true);
                self.recognizer.transcribeAudio(path, operation.session, operation.generation, transcribeCompletion(operation)) catch self.finishError(operation, "transcription_failed", "Local transcription could not start.");
            },
            .audio_finish => {
                operation.session = json.unsignedField(payload, "session");
                if (operation.session == 0) operation.session = self.current_audio_session;
                if (json.unsignedField(payload, "generation") == 0) operation.generation = self.current_audio_generation;
                operation.stage = .stopping;
                self.audio.stopSession(operation.session, finishCompletion(operation)) catch self.finishError(operation, "capture_failed", "Capture failed.");
            },
            .audio_retry => {
                operation.session = json.unsignedField(payload, "session");
                if (operation.session == 0) operation.session = self.current_audio_session;
                if (json.unsignedField(payload, "generation") == 0) operation.generation = self.current_audio_generation;
                const path = self.audio.retryAudioPath() orelse return self.finishUnavailable(operation, "retry_unavailable", "Retry audio is unavailable.", false);
                self.recognizer.transcribeAudio(path, operation.session, operation.generation, transcribeCompletion(operation)) catch self.finishError(operation, "transcription_failed", "Local transcription could not start.");
            },
            .transcribe_path => {
                operation.session = json.unsignedField(payload, "session");
                const decoded = json.decodeBase64Alloc(self.allocator, json.field(payload, "path")) catch return self.finishError(operation, "audio_unavailable", "The audio path is invalid.");
                defer self.allocator.free(decoded);
                self.recognizer.transcribeAudio(decoded, operation.session, operation.generation, genericCompletion(operation)) catch self.finishError(operation, "transcription_failed", "Local transcription could not start.");
            },
            .nemo_unload => self.recognizer.unload(genericCompletion(operation)) catch self.finishError(operation, "unload_failed", "The recognizer could not unload."),
            .model_download => self.models.downloadDefault(operation.key, modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_resume => self.models.resumePending(operation.key, modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_resolve_hf => self.models.resolveHF(payload, operation.key, modelGenericCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_download_hf => self.models.downloadResolvedHF(payload, operation.key, modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_add_local => {
                const path = json.decodeBase64Alloc(self.allocator, json.field(payload, "path")) catch return self.finishError(operation, "invalid_path", "The local model path is invalid.");
                defer self.allocator.free(path);
                self.models.addLocal(path, json.unsignedField(payload, "modelKey"), operation.generation, modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start.");
            },
            .model_add_hf => {
                const identifier = json.decodeBase64Alloc(self.allocator, json.field(payload, "id")) catch return self.finishError(operation, "invalid_identifier", "The Hugging Face identifier is invalid.");
                defer self.allocator.free(identifier);
                self.models.resolveHF(identifier, operation.key, modelGenericCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start.");
            },
            .model_select => self.models.select(json.unsignedField(payload, "modelKey"), operation.generation, modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_pick_local => self.pickLocalModel(operation),
            .debug_fixture_delivery => self.startFixture(operation, payload),
            .debug_performance => self.startPerformance(operation, payload),
        }
    }

    fn finishContracts(self: *FridayHost, operation: *Operation) void {
        var output: [result_capacity]u8 = undefined;
        var audio_storage: [2048]u8 = undefined;
        var audio_input: [2048]u8 = undefined;
        var converter: [1024]u8 = undefined;
        var route: [1024]u8 = undefined;
        var models: [8192]u8 = undefined;
        var hotkey: [2048]u8 = undefined;
        var overlay: [2048]u8 = undefined;
        var copy_only: [1024]u8 = undefined;
        const a = self.audio.writeStorageProbe(&audio_storage) catch 0;
        const ai = self.audio.inputStatus(&audio_input) catch 0;
        const c = self.audio.writeFailureCleanupProbe(&converter) catch 0;
        const r = self.audio.writeRouteChangeProbe(&route) catch 0;
        const m = models_mod.ModelRepository.writeContractProbes(&models) catch 0;
        const h = input_mod.GlobalInputMonitor.writeContractProbes(&hotkey) catch 0;
        const o = self.overlay.writeInteractionProbe(&overlay) catch 0;
        var empty_bundle: [0]u8 = .{};
        var empty_name: [0]u8 = .{};
        var empty_path: [0]u8 = .{};
        var source = delivery_mod.SourceTarget{
            .token = @splat(0),
            .pid = 0,
            .bundle_id = empty_bundle[0..],
            .app_name = empty_name[0..],
            .launch_time = 0,
            .process_path = empty_path[0..],
            .captured_at_ms = @intCast(system.wallMs()),
        };
        const d = self.delivery.deliverText("Friday copy-only delivery contract", &source, false, self.services, &copy_only) catch 0;
        const platform = system.platformStatus();
        var writer = std.Io.Writer.fixed(&output);
        writer.print("{{\"ok\":true,\"currentPlatformSupported\":{s},\"architecture\":", .{if (platform.supported) "true" else "false"}) catch return self.finishError(operation, "serialization_failed", "Contract probes could not be serialized.");
        json.writeString(&writer, platform.architecture) catch return self.finishError(operation, "serialization_failed", "Contract probes could not be serialized.");
        writer.print(",\"processTranslated\":{s},\"audio\":", .{if (platform.translated) "true" else "false"}) catch return;
        writer.writeAll(audio_storage[0..a]) catch return;
        writer.writeAll(",\"audioInput\":") catch return;
        writer.writeAll(audio_input[0..ai]) catch return;
        writer.writeAll(",\"converterFailure\":") catch return;
        writer.writeAll(converter[0..c]) catch return;
        writer.writeAll(",\"routeChange\":") catch return;
        writer.writeAll(route[0..r]) catch return;
        writer.writeAll(",\"models\":") catch return;
        writer.writeAll(models[0..m]) catch return;
        writer.writeAll(",\"hotkey\":") catch return;
        writer.writeAll(hotkey[0..h]) catch return;
        writer.writeAll(",\"overlay\":") catch return;
        writer.writeAll(overlay[0..o]) catch return;
        writer.writeAll(",\"copyOnlyDelivery\":") catch return;
        writer.writeAll(copy_only[0..d]) catch return;
        writer.writeAll(",\"loginStatusKnown\":true}") catch return;
        self.finishOperation(operation, true, writer.buffered());
    }

    fn pickLocalModel(self: *FridayHost, operation: *Operation) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const panel = objc.send0(objc.Id, objc.class("NSOpenPanel"), objc.selector("openPanel"));
        const title = objc.nsString("Choose a compatible Parakeet TDT GGUF model");
        const prompt = objc.nsString("Add Model");
        const message = objc.nsString("Choose a GGUF file with a matching Friday manifest sidecar.");
        const gguf = objc.nsString("gguf");
        defer {
            objc.release(title);
            objc.release(prompt);
            objc.release(message);
            objc.release(gguf);
        }
        objc.send1(void, objc.Id, panel, objc.selector("setTitle:"), title);
        objc.send1(void, objc.Id, panel, objc.selector("setPrompt:"), prompt);
        objc.send1(void, objc.Id, panel, objc.selector("setMessage:"), message);
        objc.send1(void, bool, panel, objc.selector("setCanChooseDirectories:"), false);
        objc.send1(void, bool, panel, objc.selector("setCanChooseFiles:"), true);
        objc.send1(void, bool, panel, objc.selector("setAllowsMultipleSelection:"), false);
        const types = objc.send1(objc.Id, objc.Id, objc.class("NSArray"), objc.selector("arrayWithObject:"), gguf);
        objc.send1(void, objc.Id, panel, objc.selector("setAllowedFileTypes:"), types);
        if (objc.send0(isize, panel, objc.selector("runModal")) != 1) return self.finishError(operation, "user_cancelled", "No local model was selected.");
        const url = objc.send0(objc.Id, panel, objc.selector("URL"));
        const path_value = objc.send0(objc.Id, url, objc.selector("path"));
        const path = objc.copyUtf8Into(path_value, &operation.path);
        if (path.len == 0) return self.finishError(operation, "user_cancelled", "No local model was selected.");
        operation.path_len = path.len;
        self.generation += 1;
        operation.generation = self.generation;
        self.models.addLocal(operation.path[0..operation.path_len], 1000 + self.generation, operation.generation, modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The local model could not be added.");
    }

    fn startFixture(self: *FridayHost, operation: *Operation, payload: []const u8) void {
        const model_path = self.models.activeModelPath() orelse return self.finishError(operation, "fixture_prerequisite_missing", "The automation fixture and an active model are required.");
        if (payload.len == 0 or payload.len > operation.path.len) return self.finishError(operation, "fixture_prerequisite_missing", "The automation fixture and an active model are required.");
        @memcpy(operation.path[0..payload.len], payload);
        operation.path_len = payload.len;
        self.generation += 1;
        operation.generation = self.generation;
        operation.session = operation.generation;
        var source = self.delivery.captureFrontmostSource() catch return self.finishError(operation, "source_unavailable", "Friday could not capture the source application.");
        source.generation = operation.generation;
        const pointer = self.allocator.create(delivery_mod.SourceTarget) catch {
            source.deinit(self.allocator);
            return self.finishError(operation, "out_of_memory", "Friday could not retain the source application.");
        };
        pointer.* = source;
        self.addSource(pointer);
        operation.stage = .activating;
        self.recognizer.activateModel(model_path, operation.generation, fixtureCompletion(operation)) catch self.finishError(operation, "model_probe_failed", "The active model could not be loaded.");
    }

    fn startPerformance(self: *FridayHost, operation: *Operation, payload: []const u8) void {
        var parts = std.mem.splitScalar(u8, payload, '|');
        const count_text = parts.next() orelse "";
        const fixture = parts.next() orelse "";
        const output = parts.next() orelse "";
        if (parts.next() != null or fixture.len == 0 or output.len == 0 or fixture.len > operation.path.len or output.len > operation.output_path.len or self.models.activeModelPath() == null) return self.finishError(operation, "performance_prerequisite_missing", "Use <iterations>|<raw-f32-path>|<output-json-path> with 5–50 iterations and an active model.");
        operation.iterations = std.fmt.parseUnsigned(usize, count_text, 10) catch 0;
        if (operation.iterations < 5 or operation.iterations > 50) return self.finishError(operation, "performance_prerequisite_missing", "Use <iterations>|<raw-f32-path>|<output-json-path> with 5–50 iterations and an active model.");
        @memcpy(operation.path[0..fixture.len], fixture);
        operation.path_len = fixture.len;
        @memcpy(operation.output_path[0..output.len], output);
        operation.output_path_len = output.len;
        self.generation += 1;
        operation.generation = self.generation;
        operation.stage = .activating;
        self.recognizer.activateModel(self.models.activeModelPath().?, operation.generation, performanceCompletion(operation)) catch self.finishError(operation, "model_probe_failed", "The active model could not be loaded.");
    }

    fn runPerformanceSample(self: *FridayHost, operation: *Operation) void {
        if (!self.operationPending(operation)) return;
        if (operation.completed_iterations >= operation.iterations) return self.finishPerformance(operation);
        const sample_generation = operation.generation + operation.completed_iterations + 1;
        operation.stage = .transcribing;
        self.recognizer.transcribeAudio(operation.path[0..operation.path_len], sample_generation, sample_generation, performanceCompletion(operation)) catch self.finishError(operation, "transcription_failed", "The performance fixture could not be transcribed.");
    }

    fn finishPerformance(self: *FridayHost, operation: *Operation) void {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        const value = .{
            .ok = true,
            .iterations = operation.iterations,
            .inferenceMs = operation.inference[0..operation.iterations],
            .warmFiveSecondStopToTextMs = operation.stop_to_text[0..operation.iterations],
            .textToDeliveryMs = operation.delivery[0..operation.iterations],
            .residentBytes = operation.resident[0..operation.iterations],
            .presentationFenceMs = 250,
            .transcriptIncluded = false,
            .fixturePathIncluded = false,
        };
        std.json.Stringify.value(value, .{}, &writer.writer) catch return self.finishError(operation, "serialization_failed", "Performance evidence could not be serialized.");
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = operation.output_path[0..operation.output_path_len], .data = writer.written() }) catch return self.finishError(operation, "performance_evidence_write_failed", "Performance evidence could not be written.");
        self.finishOperation(operation, true, writer.written());
    }

    fn beginOperation(self: *FridayHost, key: u64, kind: AsyncKind) ?*Operation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return null;
        for (&self.operations) |*operation| if (operation.used and operation.key == key) return null;
        for (&self.operations) |*operation| if (!operation.used) {
            operation.* = .{ .host = self, .used = true, .pending = true, .key = key, .kind = kind };
            self.pending_count += 1;
            return operation;
        };
        return null;
    }

    fn finishOperation(self: *FridayHost, operation: *Operation, ok: bool, bytes: []const u8) void {
        self.mutex.lock();
        if (!operation.used or !operation.pending) {
            if (operation.used and !operation.pending) self.releaseOperationLocked(operation);
            self.mutex.unlock();
            return;
        }
        operation.pending = false;
        if (self.pending_count > 0) self.pending_count -= 1;
        const should_deliver = !self.closing;
        if (should_deliver) self.enqueueLocked(operation.key, ok, bytes);
        const services = if (should_deliver) self.services else null;
        self.releaseOperationLocked(operation);
        self.mutex.unlock();
        if (services) |live| live.wake() catch {};
    }

    fn finishError(self: *FridayHost, operation: *Operation, code: []const u8, message: []const u8) void {
        var output: [2048]u8 = undefined;
        const length = json.writeError(&output, code, message);
        self.finishOperation(operation, false, output[0..length]);
    }

    fn finishUnavailable(self: *FridayHost, operation: *Operation, code: []const u8, message: []const u8, retry: bool) void {
        var output: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        writer.print("{{\"ok\":false,\"sessionId\":{d},\"generation\":{d},\"code\":", .{ operation.session, operation.generation }) catch return;
        json.writeString(&writer, code) catch return;
        writer.writeAll(",\"message\":") catch return;
        json.writeString(&writer, message) catch return;
        writer.print(",\"retryAudioAvailable\":{s}}}", .{if (retry) "true" else "false"}) catch return;
        self.finishOperation(operation, false, writer.buffered());
    }

    fn saveOperationResult(self: *FridayHost, operation: *Operation, bytes: []const u8) bool {
        if (operation.saved) |saved| self.allocator.free(saved);
        operation.saved = self.allocator.dupe(u8, bytes) catch return false;
        return true;
    }

    fn releaseOperationLocked(self: *FridayHost, operation: *Operation) void {
        if (operation.saved) |saved| self.allocator.free(saved);
        operation.* = .{};
    }

    fn operationPending(self: *FridayHost, operation: *Operation) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return operation.used and operation.pending and !self.closing;
    }

    fn cancel(context: *anyopaque, key: u64) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        var selected: ?*Operation = null;
        for (&self.operations) |*operation| if (operation.used and operation.key == key and operation.pending) {
            operation.pending = false;
            if (self.pending_count > 0) self.pending_count -= 1;
            selected = operation;
            break;
        };
        var offset: usize = 0;
        while (offset < self.completion_count) : (offset += 1) {
            const index = (self.completion_head + offset) % self.completions.len;
            if (self.completions[index].key == key) self.completions[index].cancelled = true;
        }
        self.mutex.unlock();
        const operation = selected orelse {
            // The start request may already have finished host-side while
            // its completion was still queued for the core. A cancel that
            // arrives in that window finds no pending operation, but the
            // capture it began is live — kill it or the microphone stays
            // hot with no owning session.
            if (key == self.audio_start_key and self.current_audio_session != 0) self.audio.cancelSession(self.current_audio_session);
            return;
        };
        self.input.cancelShortcutCapture();
        self.recognizer.cancelGeneration(operation.generation);
        self.models.cancel(key);
        self.audio.cancelSession(operation.session);
        self.removeSourcesForGeneration(operation.generation);
        if (self.takeTranscript(operation.session, operation.generation)) |text| self.allocator.free(text);
        self.clearAudioGeneration(operation.session);
        if (operation.kind == .hotkey_capture) {
            self.mutex.lock();
            self.releaseOperationLocked(operation);
            self.mutex.unlock();
        }
    }

    fn enqueue(self: *FridayHost, key: u64, ok: bool, bytes: []const u8) void {
        self.mutex.lock();
        self.enqueueLocked(key, ok, bytes);
        const services = self.services;
        self.mutex.unlock();
        if (services) |live| live.wake() catch {};
    }

    fn enqueueLocked(self: *FridayHost, key: u64, ok: bool, bytes: []const u8) void {
        if (self.closing or self.completion_count == self.completions.len) return;
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

    fn poll(context: *anyopaque) ?native_sdk.HostCallCompletion {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.finishMicrophonePermissionProbe();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.completion_count > 0) {
            const slot = &self.completions[self.completion_head];
            self.completion_head = (self.completion_head + 1) % self.completions.len;
            self.completion_count -= 1;
            if (!slot.cancelled) return .{ .key = slot.key, .ok = slot.ok, .bytes = slot.bytes[0..slot.length] };
        }
        return null;
    }

    fn finishMicrophonePermissionProbe(self: *FridayHost) void {
        if (!self.microphone_permission_probe_finished.swap(false, .acq_rel)) return;
        self.microphone_permission_probe_active.store(false, .release);
        const services = self.services orelse return;
        services.audioCaptureStop(.microphone) catch {};
        self.emitPermissions();
    }

    fn pending(context: *anyopaque) bool {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.completion_count > 0 or self.pending_count > 0;
    }

    fn inputEvent(context: *anyopaque, bytes: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const event_value = parsed.value.object.get("event") orelse return;
        const payload_value = parsed.value.object.get("payload") orelse return;
        if (event_value != .string or payload_value != .object) return;
        const event = event_value.string;
        const at_ms = valueUnsigned(payload_value.object.get("atMs")) orelse 0;
        if (std.mem.eql(u8, event, "hotkey_down")) {
            self.last_hotkey_received_at_ms = system.wallMs();
            self.generation += 1;
            var source = self.delivery.captureFrontmostSource() catch return;
            source.generation = self.generation;
            if (valueString(payload_value.object.get("token"))) |token| if (token.len == source.token.len) @memcpy(&source.token, token);
            const pointer = self.allocator.create(delivery_mod.SourceTarget) catch {
                source.deinit(self.allocator);
                return;
            };
            pointer.* = source;
            self.addSource(pointer);
            self.setPreferredSourceFrame(pointer.source_screen_frame);
            var output: [2048]u8 = undefined;
            var writer = std.Io.Writer.fixed(&output);
            writer.print("hotkey_down|{d}|{d}|", .{ self.generation, at_ms }) catch return;
            json.writeBase64(&writer, &pointer.token) catch return;
            writer.print("|{d}|", .{pointer.pid}) catch return;
            json.writeBase64(&writer, pointer.bundle_id) catch return;
            writer.writeByte('|') catch return;
            json.writeBase64(&writer, pointer.app_name) catch return;
            self.emit(writer.buffered());
        } else if (std.mem.eql(u8, event, "hotkey_up")) {
            var output: [128]u8 = undefined;
            const wire = std.fmt.bufPrint(&output, "hotkey_up|{d}|{d}", .{ self.generation, at_ms }) catch return;
            self.emit(wire);
        } else {
            const reason = valueString(payload_value.object.get("reason")) orelse "invalidated";
            var output: [256]u8 = undefined;
            const wire = std.fmt.bufPrint(&output, "hotkey_cancel|{d}|{d}|{s}", .{ self.generation, at_ms, reason }) catch return;
            self.emit(wire);
        }
    }

    fn microphonePermissionProbe(context: ?*anyopaque, _: u64, event: native_sdk.AudioCaptureEvent) native_sdk.AudioCapturePushResult {
        const self: *FridayHost = @ptrCast(@alignCast(context.?));
        if (event.kind != .data and self.microphone_permission_probe_active.load(.acquire)) {
            self.microphone_permission_probe_finished.store(true, .release);
            self.mutex.lock();
            const services = self.services;
            self.mutex.unlock();
            if (services) |live| live.wake() catch {};
        }
        return .closed;
    }

    fn audioEvent(context: *anyopaque, event: []const u8, payload: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        const session = json.unsignedValue(payload, "sessionId") orelse 0;
        const generation = self.generationForSession(session);
        if (std.mem.eql(u8, event, "audio_meter")) {
            const elapsed = json.unsignedValue(payload, "elapsedMilliseconds") orelse 0;
            const level = json.unsignedValue(payload, "level") orelse 0;
            const rms = @min(json.unsignedValue(payload, "rmsMilli") orelse 0, 1000);
            const peak = @min(json.unsignedValue(payload, "peakMilli") orelse 0, 1000);
            const frames = json.unsignedValue(payload, "capturedFrames") orelse 0;
            self.overlay.updateMeter(@intCast(@min(rms * 5 + peak, 1000)), elapsed);
            var output: [256]u8 = undefined;
            const wire = std.fmt.bufPrint(&output, "audio_meter|{d}|{d}|{d}|{d}|{d}", .{ generation, session, elapsed, level, frames }) catch return;
            self.emit(wire);
            return;
        }
        var output: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        writer.print("{s}|{d}|{d}|", .{ event, generation, session }) catch return;
        json.writeBase64(&writer, payload) catch return;
        self.emit(writer.buffered());
    }

    fn modelProgress(context: *anyopaque, operation: u64, state: []const u8, downloaded: u64, total: u64) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        var output: [256]u8 = undefined;
        const wire = std.fmt.bufPrint(&output, "model_progress|{d}|{s}|{d}|{d}", .{ operation, state, downloaded, total }) catch return;
        self.emit(wire);
    }

    fn overlayEvent(context: *anyopaque, action: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        var output: [256]u8 = undefined;
        const wire = std.fmt.bufPrint(&output, "{s}|{d}", .{ action, self.generation }) catch return;
        self.emit(wire);
    }

    fn emitPermissions(self: *FridayHost) void {
        var permissions: [256]u8 = undefined;
        const length = self.writePermissions(&permissions);
        var output: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        writer.print("permissions|{d}|", .{self.generation}) catch return;

        json.writeBase64(&writer, permissions[0..length]) catch return;
        self.emit(writer.buffered());
    }
    fn setPreferredSourceFrame(self: *FridayHost, frame: anytype) void {
        const preferred: ?overlay_mod.ScreenFrame = if (frame) |value|
            overlay_mod.ScreenFrame.init(value.origin.x, value.origin.y, value.size.width, value.size.height)
        else
            null;
        self.overlay.setPreferredScreenFrame(preferred);
    }

    fn emit(self: *FridayHost, bytes: []const u8) void {
        self.mutex.lock();
        const handle = if (!self.closing) self.event_handle else null;
        self.mutex.unlock();
        if (handle) |live| switch (live.post(bytes)) {
            .accepted => {},
            .dropped_full, .dropped_oversized, .closed => {
                self.mutex.lock();
                self.event_post_failures += 1;
                self.mutex.unlock();
            },
        };
    }

    fn addSource(self: *FridayHost, source: *delivery_mod.SourceTarget) void {
        if (self.source_count == self.sources.len) self.removeSource(0);
        self.sources[self.source_count] = source;
        self.source_count += 1;
    }

    fn findSource(self: *FridayHost, token: []const u8) ?usize {
        for (self.sources[0..self.source_count], 0..) |entry, index| if (entry) |source| if (std.mem.eql(u8, &source.token, token)) return index;
        return null;
    }

    fn findSourceGeneration(self: *FridayHost, generation: u64) ?usize {
        for (self.sources[0..self.source_count], 0..) |entry, index| if (entry) |source| if (source.generation == generation) return index;
        return null;
    }

    fn takeSource(self: *FridayHost, index: usize) *delivery_mod.SourceTarget {
        const source = self.sources[index].?;
        var cursor = index;
        while (cursor + 1 < self.source_count) : (cursor += 1) self.sources[cursor] = self.sources[cursor + 1];
        self.source_count -= 1;
        self.sources[self.source_count] = null;
        return source;
    }

    fn removeSource(self: *FridayHost, index: usize) void {
        self.destroySource(self.takeSource(index));
    }

    fn removeSourcesForGeneration(self: *FridayHost, generation: u64) void {
        var index: usize = 0;
        while (index < self.source_count) {
            if (self.sources[index].?.generation == generation) self.removeSource(index) else index += 1;
        }
    }

    fn destroySource(self: *FridayHost, source: *delivery_mod.SourceTarget) void {
        source.deinit(self.allocator);
        self.allocator.destroy(source);
    }

    fn storeTranscript(self: *FridayHost, session: u64, generation: u64, text: []const u8) void {
        if (self.takeTranscript(session, generation)) |old| self.allocator.free(old);
        for (&self.transcripts) |*entry| if (!entry.used) {
            entry.* = .{ .used = true, .session = session, .generation = generation, .text = self.allocator.dupe(u8, text) catch return };
            return;
        };
    }

    fn takeTranscript(self: *FridayHost, session: u64, generation: u64) ?[]u8 {
        for (&self.transcripts) |*entry| if (entry.used and entry.session == session and entry.generation == generation) {
            const text = entry.text;
            entry.* = .{};
            return text;
        };
        return null;
    }

    fn setAudioGeneration(self: *FridayHost, session: u64, generation: u64) void {
        self.clearAudioGeneration(session);
        for (&self.audio_generations) |*entry| if (!entry.used) {
            entry.* = .{ .used = true, .session = session, .generation = generation };
            return;
        };
    }

    fn clearAudioGeneration(self: *FridayHost, session: u64) void {
        for (&self.audio_generations) |*entry| {
            if (entry.used and entry.session == session) entry.* = .{};
        }
    }

    fn generationForSession(self: *FridayHost, session: u64) u64 {
        for (self.audio_generations) |entry| if (entry.used and entry.session == session) return entry.generation;
        return 0;
    }

    fn updateTranscriptionState(self: *FridayHost, operation: *Operation, ok: bool, bytes: []const u8) void {
        self.last_inference_duration_ms = json.unsignedValue(bytes, "latencyMs") orelse 0;
        self.last_resident_bytes = json.unsignedValue(bytes, "residentBytes") orelse self.last_resident_bytes;
        if (self.last_stop_requested_at_ms > 0) {
            self.appendPerformanceSample(&self.stop_to_text_ms, system.wallMs() -| self.last_stop_requested_at_ms);
            self.last_stop_requested_at_ms = 0;
        }
        const code = if (ok) "" else (json.stringAlloc(self.allocator, bytes, "code") catch null) orelse null;
        defer if (code) |value| self.allocator.free(value);
        self.last_error_code_len = 0;
        if (code) |value| {
            self.last_error_code_len = @min(value.len, self.last_error_code.len);
            @memcpy(self.last_error_code[0..self.last_error_code_len], value[0..self.last_error_code_len]);
        }
        if (ok) {
            const silence = json.boolValue(bytes, "silence") orelse false;
            const text = json.stringAlloc(self.allocator, bytes, "text") catch null;
            defer if (text) |value| self.allocator.free(value);
            if (!silence and text != null and text.?.len > 0) self.storeTranscript(operation.session, operation.generation, text.?);
            self.audio.discardRetryAudio();
        }
    }

    fn probeRecognizer(_: *anyopaque, path: []const u8, _: u64) models_mod.ProbeResult {
        const capabilities = nemo_mod.NemoRecognizer.probeModel(path) catch
            return .{ .ok = false, .code = "model_probe_failed", .message = "The model failed its NeMo runtime probe." };
        return if (capabilities.offline)
            .{ .ok = true, .streaming = capabilities.streaming }
        else
            .{ .ok = false, .code = "model_probe_failed", .message = "The model failed its NeMo runtime probe." };
    }

    fn startupActivation(context: *anyopaque, ok: bool, _: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.models.markRuntimeReady(self.models.activeModelKey(), ok);
    }

    fn inputCompletion(operation: *Operation) input_mod.AsyncCompletion {
        return .{ .context = operation, .complete = genericCallback };
    }
    fn audioCompletion(operation: *Operation) audio_mod.AsyncCompletion {
        return .{ .context = operation, .complete = audioCallback };
    }
    fn finishCompletion(operation: *Operation) audio_mod.AsyncCompletion {
        return .{ .context = operation, .complete = finishCallback };
    }
    fn genericCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = genericCallback };
    }
    fn transcribeCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = transcribeCallback };
    }
    fn fixtureCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = fixtureCallback };
    }
    fn performanceCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = performanceCallback };
    }
    fn modelCompletion(operation: *Operation) models_mod.AsyncCompletion {
        return .{ .context = operation, .complete = modelCallback };
    }
    fn modelGenericCompletion(operation: *Operation) models_mod.AsyncCompletion {
        return .{ .context = operation, .complete = genericCallback };
    }

    fn genericCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        operation.host.finishOperation(operation, ok, bytes);
    }

    fn audioCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) {
            self.audio.cancelSession(operation.session);
            self.finishOperation(operation, ok, bytes);
            return;
        }
        if (operation.kind == .audio_stop) {
            var output: [result_capacity]u8 = undefined;
            const length = json.addGeneration(&output, bytes, operation.generation) catch return self.finishError(operation, "serialization_failed", "The capture result could not be serialized.");
            if (ok) {
                self.last_audio_duration_ms = json.unsignedValue(bytes, "audioDurationMs") orelse 0;
                const first = json.unsignedValue(bytes, "firstAudioAtMs") orelse 0;
                if (self.last_hotkey_received_at_ms > 0 and first >= self.last_hotkey_received_at_ms and first - self.last_hotkey_received_at_ms < 10_000) self.appendPerformanceSample(&self.hotkey_to_first_sample_ms, first - self.last_hotkey_received_at_ms);
                self.last_hotkey_received_at_ms = 0;
                self.appendPerformanceSample(&self.stop_to_drain_ms, system.wallMs() -| self.last_stop_requested_at_ms);
                self.appendPerformanceSample(&self.dropped_frames, json.unsignedValue(bytes, "droppedFrames") orelse 0);
            }
            self.finishOperation(operation, ok, output[0..length]);
            return;
        }
        self.finishOperation(operation, ok, bytes);
    }

    fn transcribeCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        self.updateTranscriptionState(operation, ok, bytes);
        self.clearAudioGeneration(operation.session);
        self.finishOperation(operation, ok, bytes);
    }

    fn finishCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        if (operation.stage == .stopping) {
            if (!ok) return self.finishOperation(operation, false, bytes);
            _ = self.models.activeModelPath() orelse {
                self.clearAudioGeneration(operation.session);
                var output: [4096]u8 = undefined;
                var writer = std.Io.Writer.fixed(&output);
                writer.print("{{\"ok\":false,\"generation\":{d},\"sessionId\":{d},\"code\":\"model_unavailable\",\"capture\":{s},\"retryAudioAvailable\":true}}", .{ operation.generation, operation.session, bytes }) catch return;
                return self.finishOperation(operation, false, writer.buffered());
            };
            const path = json.stringAlloc(self.allocator, bytes, "audioPath") catch null orelse return self.finishError(operation, "audio_unavailable", "Captured audio is unavailable.");
            defer self.allocator.free(path);
            if (!self.saveOperationResult(operation, bytes)) return self.finishError(operation, "out_of_memory", "The capture result could not be retained.");
            operation.stage = .transcribing;
            self.recognizer.transcribeAudio(path, operation.session, operation.generation, finishNemoCompletion(operation)) catch self.finishError(operation, "transcription_failed", "Local transcription could not start.");
        }
    }

    fn finishNemoCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = finishNemoCallback };
    }

    fn finishNemoCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        self.updateTranscriptionState(operation, ok, bytes);
        var output: [result_capacity]u8 = undefined;
        const capture = operation.saved orelse "{}";
        const length = json.mergeNamed(&output, bytes, "capture", capture) catch return self.finishError(operation, "serialization_failed", "The transcription result could not be serialized.");
        self.clearAudioGeneration(operation.session);
        self.finishOperation(operation, ok, output[0..length]);
    }

    fn modelCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        if (!ok) return self.finishOperation(operation, false, bytes);
        const path = self.models.activeModelPath() orelse return self.finishOperation(operation, true, bytes);
        if (!self.saveOperationResult(operation, bytes)) return self.finishError(operation, "out_of_memory", "The model result could not be retained.");
        operation.stage = .activating;
        self.recognizer.activateModel(path, operation.generation, modelActivationCompletion(operation)) catch self.finishError(operation, "model_probe_failed", "The selected model could not be loaded.");
    }

    fn modelActivationCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = modelActivationCallback };
    }

    fn modelActivationCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        self.models.markRuntimeReady(self.models.activeModelKey(), ok);
        if (!ok) return self.finishOperation(operation, false, bytes);
        self.finishOperation(operation, true, operation.saved orelse bytes);
    }

    fn fixtureCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        if (!ok) {
            self.removeSourcesForGeneration(operation.generation);
            return self.finishOperation(operation, false, bytes);
        }
        if (operation.stage == .activating) {
            operation.stage = .transcribing;
            self.recognizer.transcribeAudio(operation.path[0..operation.path_len], operation.session, operation.generation, fixtureCompletion(operation)) catch self.finishError(operation, "transcription_failed", "The fixture could not be transcribed.");
            return;
        }
        const silence = json.boolValue(bytes, "silence") orelse false;
        const text = json.stringAlloc(self.allocator, bytes, "text") catch null;
        defer if (text) |value| self.allocator.free(value);
        if (silence or text == null or text.?.len == 0) {
            self.removeSourcesForGeneration(operation.generation);
            return self.finishOperation(operation, false, bytes);
        }
        self.storeTranscript(operation.session, operation.generation, text.?);
        var payload: [160]u8 = undefined;
        const request_bytes = std.fmt.bufPrint(&payload, "session={d};generation={d};paste=0", .{ operation.session, operation.generation }) catch return self.finishError(operation, "delivery_failed", "The fixture could not be delivered.");
        var output: [result_capacity]u8 = undefined;
        const length = self.deliverSession(request_bytes, &output);
        self.finishOperation(operation, length > 0 and json.objectOk(output[0..length]), output[0..length]);
    }

    fn performanceCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operation.host;
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        if (!ok) return self.finishOperation(operation, false, bytes);
        if (operation.stage == .activating) return self.runPerformanceSample(operation);
        if ((json.boolValue(bytes, "silence") orelse false)) return self.finishOperation(operation, false, bytes);
        const text = json.stringAlloc(self.allocator, bytes, "text") catch null;
        defer if (text) |value| self.allocator.free(value);
        if (text == null or text.?.len == 0) return self.finishOperation(operation, false, bytes);
        const index = operation.completed_iterations;
        const latency = json.unsignedValue(bytes, "latencyMs") orelse 0;
        operation.inference[index] = latency;
        operation.stop_to_text[index] = latency + 250;
        operation.resident[index] = json.unsignedValue(bytes, "residentBytes") orelse 0;
        var empty_bundle: [0]u8 = .{};
        var empty_name: [0]u8 = .{};
        var empty_path: [0]u8 = .{};
        var source = delivery_mod.SourceTarget{
            .token = @splat(0),
            .pid = 0,
            .bundle_id = empty_bundle[0..],
            .app_name = empty_name[0..],
            .launch_time = 0,
            .process_path = empty_path[0..],
            .captured_at_ms = @intCast(system.wallMs()),
        };
        var delivery_bytes: [1024]u8 = undefined;
        const started = system.wallMs();
        const length = self.delivery.deliverText(text.?, &source, false, self.services, &delivery_bytes) catch return self.finishError(operation, "performance_delivery_failed", "Copy-only delivery failed.");
        operation.delivery[index] = system.wallMs() -| started;
        if (!json.objectOk(delivery_bytes[0..length]) or std.mem.indexOf(u8, delivery_bytes[0..length], "\"kind\":\"clipboard\"") == null) return self.finishError(operation, "performance_delivery_failed", "Copy-only delivery failed.");
        operation.completed_iterations += 1;
        self.runPerformanceSample(operation);
    }
};

fn terminationObserverCallback(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const host = objc.getPointerIvar(FridayHost, receiver, "fridayContext") orelse return;
    host.input.stop();
    host.audio.cancelActiveSession();
    host.recognizer.shutdownAndWait();
}

fn windowOcclusionObserverCallback(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const host = objc.getPointerIvar(FridayHost, receiver, "fridayContext") orelse return;
    host.syncDockPresence();
}

fn ensureTerminationObserverClass() objc.Class {
    if (objc.lookupClass("FridayZigTerminationObserver")) |existing| return existing;
    const observer_class = objc.allocateClassPair(objc.class("NSObject"), "FridayZigTerminationObserver") orelse return null;
    if (!objc.addPointerIvar(observer_class, "fridayContext")) return null;
    if (!objc.addMethod(observer_class, objc.selector("fridayWillTerminate:"), &terminationObserverCallback, "v@:@")) return null;
    if (!objc.addMethod(observer_class, objc.selector("fridayWindowOcclusionChanged:"), &windowOcclusionObserverCallback, "v@:@")) return null;
    objc.registerClassPair(observer_class);
    return observer_class;
}

fn asyncKind(name: []const u8) ?AsyncKind {
    const commands = .{
        .{ "friday.hotkey.capture", AsyncKind.hotkey_capture },
        .{ "friday.audio.start", AsyncKind.audio_start },
        .{ "friday.audio.stop", AsyncKind.audio_stop },
        .{ "friday.audio.finish", AsyncKind.audio_finish },
        .{ "friday.audio.retry", AsyncKind.audio_retry },
        .{ "friday.nemo.transcribe_capture", AsyncKind.transcribe_capture },
        .{ "friday.nemo.transcribe_path", AsyncKind.transcribe_path },
        .{ "friday.nemo.unload", AsyncKind.nemo_unload },
        .{ "friday.model.download", AsyncKind.model_download },
        .{ "friday.model.resume", AsyncKind.model_resume },
        .{ "friday.model.pick_local", AsyncKind.model_pick_local },
        .{ "friday.model.resolve_hf", AsyncKind.model_resolve_hf },
        .{ "friday.model.download_hf", AsyncKind.model_download_hf },
        .{ "friday.model.add_local", AsyncKind.model_add_local },
        .{ "friday.model.add_hf", AsyncKind.model_add_hf },
        .{ "friday.model.select", AsyncKind.model_select },
        .{ "friday.debug.contracts", AsyncKind.debug_contracts },
        .{ "friday.debug.fixture_delivery", AsyncKind.debug_fixture_delivery },
        .{ "friday.debug.performance", AsyncKind.debug_performance },
    };
    inline for (commands) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

fn copyResult(output: []u8, bytes: []const u8) usize {
    if (bytes.len > output.len) return 0;
    @memcpy(output[0..bytes.len], bytes);
    return bytes.len;
}

fn writeSamples(writer: *std.Io.Writer, samples: Samples) !void {
    try writer.writeByte('[');
    for (samples.values[0..samples.count], 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{d}", .{value});
    }
    try writer.writeByte(']');
}

const ExpectedJsonKind = enum { bool, string, integer };
fn writeObjectField(writer: *std.Io.Writer, object: ?std.json.ObjectMap, name: []const u8, expected: ExpectedJsonKind, fallback: []const u8) !void {
    if (object) |map| if (map.get(name)) |value| switch (expected) {
        .bool => if (value == .bool) return writer.writeAll(if (value.bool) "true" else "false"),
        .string => if (value == .string) return json.writeString(writer, value.string),
        .integer => if (value == .integer) return writer.print("{d}", .{value.integer}),
    };
    try writer.writeAll(fallback);
}

fn valueString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return if (actual == .string) actual.string else null;
}

fn valueUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0) @intFromFloat(number) else null,
        else => null,
    };
}

test "completion queue preserves order cancellation and pending state" {
    var host: FridayHost = undefined;
    host.mutex = .{};
    host.completion_head = 0;
    host.completion_tail = 0;
    host.completion_count = 0;
    host.pending_count = 0;
    host.closing = false;
    host.services = null;
    host.microphone_permission_probe_active = std.atomic.Value(bool).init(false);
    host.microphone_permission_probe_finished = std.atomic.Value(bool).init(false);
    host.completions = @splat(.{});
    host.enqueue(1, true, "first");
    host.enqueue(2, true, "second");
    FridayHost.cancel(&host, 1);
    const first = FridayHost.poll(&host).?;
    try std.testing.expectEqual(@as(u64, 2), first.key);
    try std.testing.expectEqualStrings("second", first.bytes);
    try std.testing.expect(!FridayHost.pending(&host));
}

test "operation completion is consumed once and closing suppresses late delivery" {
    var host: FridayHost = undefined;
    host.mutex = .{};
    host.completion_head = 0;
    host.completion_tail = 0;
    host.completion_count = 0;
    host.pending_count = 0;
    host.closing = false;
    host.services = null;
    host.microphone_permission_probe_active = std.atomic.Value(bool).init(false);
    host.microphone_permission_probe_finished = std.atomic.Value(bool).init(false);
    host.completions = @splat(.{});
    host.operations = @splat(.{});
    const operation = host.beginOperation(77, .audio_start).?;
    host.finishOperation(operation, true, "done");
    try std.testing.expectEqual(@as(usize, 1), host.completion_count);

    const late = host.beginOperation(78, .audio_start).?;
    host.closing = true;
    host.finishOperation(late, false, "late");
    try std.testing.expectEqual(@as(usize, 1), host.completion_count);
}

test "microphone permission probe closes capture and schedules a refresh" {
    var host: FridayHost = undefined;
    host.mutex = .{};
    host.services = null;
    host.microphone_permission_probe_active = std.atomic.Value(bool).init(true);
    host.microphone_permission_probe_finished = std.atomic.Value(bool).init(false);

    const result = FridayHost.microphonePermissionProbe(&host, 0, .{
        .kind = .started,
        .source = .microphone,
        .format = .{ .sample_rate = 16_000, .channels = 1 },
    });
    try std.testing.expectEqual(native_sdk.AudioCapturePushResult.closed, result);
    try std.testing.expect(host.microphone_permission_probe_finished.load(.acquire));
}
