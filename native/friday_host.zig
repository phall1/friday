const std = @import("std");
const native_sdk = @import("native_sdk");
const diagnostics_mod = @import("host/diagnostics.zig");
const operations_mod = @import("host/operation_registry.zig");
const artifacts_mod = @import("host/session_artifacts.zig");
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

const result_capacity = operations_mod.result_capacity;
const event_channel_key: u64 = 7001;
const lifecycle_poll_us: c_uint = 10_000;
const lifecycle_handoff_timeout_ms: u64 = 1_000;

extern "c" fn usleep(useconds: c_uint) c_int;

const SpinMutex = operations_mod.SpinMutex;
const AsyncKind = operations_mod.Kind;
const AsyncStage = operations_mod.Stage;
const Operation = operations_mod.Operation;
const CancellationTicket = operations_mod.Cancellation;

const LifecycleIdentity = struct { session: u64, generation: u64 };

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
    operation_registry: operations_mod.Registry,
    artifacts: artifacts_mod.Store,
    diagnostics: diagnostics_mod.Recorder,

    channels: ?native_sdk.HostChannelBinding = null,
    event_handle: ?native_sdk.ChannelHandle = null,
    services: ?native_sdk.platform.PlatformServices = null,
    termination_observer: objc.Id = null,
    microphone_permission_probe_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    microphone_permission_probe_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    lifecycle_thread: ?std.Thread = null,
    lifecycle_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    lifecycle_abort_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lifecycle_active: bool = false,
    lifecycle_deadline_ms: u64 = 0,
    retired_lifecycle_generation: u64 = 0,

    generation: u64 = 0,
    current_audio_session: u64 = 0,
    current_audio_generation: u64 = 0,

    scratch: [result_capacity]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, app_data_dir: []const u8) !*FridayHost {
        const self = try allocator.create(FridayHost);
        errdefer allocator.destroy(self);
        const directory = try allocator.dupe(u8, app_data_dir);
        errdefer allocator.free(directory);
        const performance_output_path: ?[]const u8 = if (getenv("FRIDAY_AUTOMATION_METRICS_OUTPUT")) |path| blk: {
            const value = std.mem.span(path);
            break :blk if (value.len > 0) value else null;
        } else null;
        var diagnostics = try diagnostics_mod.Recorder.init(allocator, io, performance_output_path);
        errdefer diagnostics.deinit();
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
            .operation_registry = operations_mod.Registry.init(allocator),
            .artifacts = artifacts_mod.Store.init(allocator),
            .diagnostics = diagnostics,
        };
        self.delivery = try delivery_mod.TextDelivery.init(allocator);
        errdefer self.delivery.deinit();
        self.recognizer = try nemo_mod.NemoRecognizer.init(allocator);
        errdefer self.recognizer.deinit();
        self.audio = try audio_mod.AudioSession.init(allocator, app_data_dir, .{ .context = self, .emit = audioEvent, .abort = audioAbort });
        errdefer self.audio.deinit();
        self.overlay = try overlay_mod.Overlay.init(allocator, .{ .context = self, .emit = overlayEvent });
        errdefer self.overlay.deinit();
        self.input = try input_mod.GlobalInputMonitor.init(allocator, .{ .context = self, .emit = inputEvent });
        errdefer self.input.deinit();
        self.models = try models_mod.ModelRepository.init(allocator, app_data_dir, .{ .context = self, .probe = probeRecognizer }, .{ .context = self, .emit = modelProgress });
        errdefer self.models.deinit();
        try self.installTerminationObserver();
        self.lifecycle_thread = try std.Thread.spawn(.{}, lifecycleMain, .{self});
        errdefer {
            self.lifecycle_stop.store(true, .release);
            self.lifecycle_thread.?.join();
            self.lifecycle_thread = null;
        }

        if (self.models.activeModelPath()) |path| {
            self.recognizer.activateModel(path, self.models.beginOperation(), .{ .context = self, .complete = startupActivation }) catch {};
        }
        return self;
    }

    pub fn destroy(self: *FridayHost) void {
        self.lifecycle_stop.store(true, .release);
        if (self.lifecycle_thread) |thread| thread.join();
        self.lifecycle_thread = null;
        self.operation_registry.close();
        self.mutex.lock();
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

        self.artifacts.deinit();
        self.operation_registry.deinit();
        self.diagnostics.deinit();
        self.allocator.free(self.data_directory);
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
        if (self.operation_registry.isClosing()) return;
        self.mutex.lock();
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
        if (self.operation_registry.isClosing()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.channels = channels;
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
        const queued = self.enqueueResult(key, ok, if (length > 0) self.scratch[0..length] else "{\"ok\":false,\"message\":\"FridayHost response failed.\"}");
        self.request_mutex.unlock();
        if (!queued) self.requestCurrentLifecycleAbort();
    }

    fn subscribe(self: *FridayHost, key: u64) void {
        if (self.operation_registry.isClosing()) return self.enqueue(key, false, "{\"ok\":false,\"code\":\"channel_binding_unavailable\"}");
        self.mutex.lock();
        const channels = self.channels;
        self.mutex.unlock();
        const binding_value = channels orelse return self.enqueue(key, false, "{\"ok\":false,\"code\":\"channel_binding_unavailable\"}");
        const handle = binding_value.acquire_fn(binding_value.context, event_channel_key);
        if (self.operation_registry.isClosing()) return self.enqueue(key, false, "{\"ok\":false,\"code\":\"channel_unavailable\"}");
        self.mutex.lock();
        self.event_handle = handle;
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
            self.diagnostics.hotkeyReceived(system.wallMs());
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
            self.cancelModelRequest(std.fmt.parseUnsigned(u64, payload, 10) catch 0);
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
        const pointer = self.artifacts.retainSource(source, self.generation) catch {
            source.deinit(self.allocator);
            return json.writeError(output, "out_of_memory", "Friday could not retain the source application.");
        };
        self.activateLifecycle(self.generation, self.generation);
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
        var discarded_generation: u64 = 0;
        if (token != null and token.?.len > 0) {
            discarded_generation = self.artifacts.discardToken(token.?) orelse 0;
        } else {
            discarded_generation = self.generation;
            self.artifacts.discardGeneration(discarded_generation);
        }
        self.completeLifecycleGeneration(discarded_generation);
        return copyResult(output, "{\"ok\":true}");
    }

    fn deliver(self: *FridayHost, payload: []const u8, output: []u8) usize {
        const split = std.mem.indexOfScalar(u8, payload, '|') orelse return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        if (std.mem.indexOfScalar(u8, payload[split + 1 ..], '|') != null) return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        const token = json.decodeBase64Alloc(self.allocator, payload[0..split]) catch return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        defer self.allocator.free(token);
        const text = json.decodeBase64Alloc(self.allocator, payload[split + 1 ..]) catch return json.writeError(output, "invalid_delivery", "Invalid delivery request.");
        defer self.allocator.free(text);
        const source = self.artifacts.takeCurrentSource(token) orelse return json.writeError(output, "source_stale", "The source token expired, was consumed, or belongs to a stale generation.");
        defer self.artifacts.releaseSource(source);
        const length = self.delivery.deliverText(text, source, true, self.services, output) catch json.writeError(output, "delivery_failed", "Friday could not deliver the transcript.");
        self.audio.discardRetryAudio();
        return length;
    }

    fn deliverSession(self: *FridayHost, payload: []const u8, output: []u8) usize {
        const session = json.unsignedField(payload, "session");
        const generation = json.unsignedField(payload, "generation");
        const paste = json.boolField(payload, "paste");
        const artifacts = self.artifacts.takeForDelivery(session, generation);
        const transcript = artifacts.transcript;
        defer if (transcript) |text| self.artifacts.releaseTranscript(text);
        const source = artifacts.source;
        defer if (source) |value| self.artifacts.releaseSource(value);
        if (source == null or transcript == null or transcript.?.len == 0 or source.?.generation != generation) {
            self.audio.discardRetryAudio();
            self.completeLifecycle(session, generation);
            var writer = std.Io.Writer.fixed(output);
            writer.print("{{\"ok\":false,\"sessionId\":{d},\"generation\":{d},\"message\":\"The final transcript or exact source is stale.\"}}", .{ session, generation }) catch return 0;
            return writer.buffered().len;
        }
        var delivery_bytes: [result_capacity]u8 = undefined;
        const started = system.wallMs();
        const delivery_length = self.delivery.deliverText(transcript.?, source.?, paste, self.services, &delivery_bytes) catch json.writeError(&delivery_bytes, "delivery_failed", "Friday could not deliver the transcript.");
        self.diagnostics.deliveryCompleted(system.wallMs() -| started);
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
        self.completeLifecycle(session, generation);
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
        return self.diagnostics.write(.{
            .app_version = app_version,
            .platform = platform_bytes[0..platform_length],
            .permissions = permission_bytes[0..permission_length],
            .model = model_bytes[0..model_length],
            .audio = audio_bytes[0..audio_length],
            .hotkey_running = self.input.running(),
            .source_targets_retained = self.artifacts.retainedSourceCount(),
        }, output);
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
                if (operation.session == 0 or operation.generation == 0) return self.finishUnavailable(operation, "capture_identity_missing", "Capture requires a nonzero session and generation.", false);
                self.activateLifecycle(operation.session, operation.generation);
                self.artifacts.bindAudio(operation.session, operation.generation);
                self.audio.startSession(operation.session, audioCompletion(operation)) catch self.finishError(operation, "capture_failed", "Capture failed.");
            },
            .audio_stop => {
                const identity = self.resolveLifecycleIdentity(json.unsignedField(payload, "session"), json.unsignedField(payload, "generation"));
                operation.session = identity.session;
                operation.generation = identity.generation;
                self.diagnostics.stopRequested(system.wallMs());
                self.audio.stopSession(operation.session, audioCompletion(operation)) catch self.finishError(operation, "capture_failed", "Capture failed.");
            },
            .transcribe_capture => {
                const identity = self.resolveLifecycleIdentity(json.unsignedField(payload, "session"), json.unsignedField(payload, "generation"));
                operation.session = identity.session;
                operation.generation = identity.generation;
                if (self.models.activeModelPath() == null) return self.finishUnavailable(operation, "model_unavailable", "The active model is unavailable.", true);
                self.audio.submitRetry(.{ .context = operation, .submit = submitRetryTranscription }) catch |failure| switch (failure) {
                    error.RetryUnavailable => self.finishUnavailable(operation, "audio_unavailable", "Captured audio is unavailable.", false),
                    else => self.finishError(operation, "transcription_failed", "Local transcription could not start."),
                };
            },
            .audio_finish => {
                const identity = self.resolveLifecycleIdentity(json.unsignedField(payload, "session"), json.unsignedField(payload, "generation"));
                operation.session = identity.session;
                operation.generation = identity.generation;
                if (!self.transitionOperation(operation, .stopping)) return self.finishOperation(operation, false, "");
                self.audio.stopSession(operation.session, finishCompletion(operation)) catch self.finishError(operation, "capture_failed", "Capture failed.");
            },
            .audio_retry => {
                const identity = self.resolveLifecycleIdentity(json.unsignedField(payload, "session"), json.unsignedField(payload, "generation"));
                operation.session = identity.session;
                operation.generation = identity.generation;
                self.audio.submitRetry(.{ .context = operation, .submit = submitRetryTranscription }) catch |failure| switch (failure) {
                    error.RetryUnavailable => self.finishUnavailable(operation, "retry_unavailable", "Retry audio is unavailable.", false),
                    else => self.finishError(operation, "transcription_failed", "Local transcription could not start."),
                };
            },
            .transcribe_path => {
                operation.session = json.unsignedField(payload, "session");
                const decoded = json.decodeBase64Alloc(self.allocator, json.field(payload, "path")) catch return self.finishError(operation, "audio_unavailable", "The audio path is invalid.");
                defer self.allocator.free(decoded);
                self.recognizer.transcribeAudio(decoded, operation.session, operation.generation, genericCompletion(operation)) catch self.finishError(operation, "transcription_failed", "Local transcription could not start.");
            },
            .nemo_unload => self.recognizer.unload(genericCompletion(operation)) catch self.finishError(operation, "unload_failed", "The recognizer could not unload."),
            .model_download => self.models.downloadDefault(operation.key, self.assignModelEpoch(operation), modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_resume => self.models.resumePending(operation.key, self.assignModelEpoch(operation), modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_resolve_hf => self.models.resolveHF(payload, operation.key, self.assignModelEpoch(operation), modelGenericCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_download_hf => self.models.downloadResolvedHF(payload, operation.key, self.assignModelEpoch(operation), modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
            .model_add_local => {
                const path = json.decodeBase64Alloc(self.allocator, json.field(payload, "path")) catch return self.finishError(operation, "invalid_path", "The local model path is invalid.");
                defer self.allocator.free(path);
                self.models.addLocal(path, json.unsignedField(payload, "modelKey"), operation.key, self.assignModelEpoch(operation), modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start.");
            },
            .model_add_hf => {
                const identifier = json.decodeBase64Alloc(self.allocator, json.field(payload, "id")) catch return self.finishError(operation, "invalid_identifier", "The Hugging Face identifier is invalid.");
                defer self.allocator.free(identifier);
                self.models.resolveHF(identifier, operation.key, self.assignModelEpoch(operation), modelGenericCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start.");
            },
            .model_select => self.models.select(json.unsignedField(payload, "modelKey"), operation.key, self.assignModelEpoch(operation), modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The model operation could not start."),
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
        self.models.addLocal(operation.path[0..operation.path_len], 1000 + self.generation, operation.key, self.assignModelEpoch(operation), modelCompletion(operation)) catch self.finishError(operation, "model_operation_failed", "The local model could not be added.");
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
        _ = self.artifacts.retainSource(source, operation.generation) catch {
            source.deinit(self.allocator);
            return self.finishError(operation, "out_of_memory", "Friday could not retain the source application.");
        };
        if (!self.transitionOperation(operation, .activating)) return self.finishOperation(operation, false, "");
        self.recognizer.activateModel(model_path, self.assignModelEpoch(operation), fixtureCompletion(operation)) catch self.finishError(operation, "model_probe_failed", "The active model could not be loaded.");
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
        if (!self.transitionOperation(operation, .activating)) return self.finishOperation(operation, false, "");
        self.recognizer.activateModel(self.models.activeModelPath().?, self.assignModelEpoch(operation), performanceCompletion(operation)) catch self.finishError(operation, "model_probe_failed", "The active model could not be loaded.");
    }

    fn runPerformanceSample(self: *FridayHost, operation: *Operation) void {
        if (!self.operationPending(operation)) return;
        if (operation.completed_iterations >= operation.iterations) return self.finishPerformance(operation);
        const sample_generation = operation.generation + operation.completed_iterations + 1;
        if (!self.transitionOperation(operation, .transcribing)) return self.finishOperation(operation, false, "");
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
        return self.operation_registry.begin(self, key, kind);
    }

    fn finishOperation(self: *FridayHost, operation: *Operation, ok: bool, bytes: []const u8) void {
        const result = self.operation_registry.finish(operation, ok, bytes);
        var wake_failed = false;
        if (result.queued) {
            self.mutex.lock();
            const services = self.services;
            self.mutex.unlock();
            if (services) |live| live.wake() catch {
                wake_failed = true;
            };
        }
        if (result.kind == .audio_stop and result.queued)
            self.clearLifecycleDeadline(result.session, result.generation);
        if (result.delivery_failed or wake_failed) self.requestLifecycleAbort(result.generation);
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
        return self.operation_registry.save(operation, bytes);
    }

    fn operationPending(self: *FridayHost, operation: *Operation) bool {
        return self.operation_registry.operationPending(operation);
    }

    fn transitionOperation(self: *FridayHost, operation: *Operation, stage: AsyncStage) bool {
        return self.operation_registry.transition(operation, stage);
    }

    fn assignModelEpoch(self: *FridayHost, operation: *Operation) u64 {
        const epoch = self.models.beginOperation();
        operation.model_epoch = epoch;
        return epoch;
    }

    fn cancelModelRequest(self: *FridayHost, request_key: u64) void {
        self.models.cancel(self.operation_registry.modelEpochForKey(request_key));
    }

    fn cancel(context: *anyopaque, key: u64) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        const ticket = self.operation_registry.claimCancellation(key) orelse return;
        const cleanup = ticket.cleanup();
        if (cleanup.input) self.input.cancelShortcutCapture();
        if (cleanup.audio) self.audio.cancelSession(ticket.session);
        if (cleanup.recognizer) self.recognizer.cancelGeneration(ticket.generation);
        if (cleanup.activation) self.recognizer.cancelActivation(ticket.model_epoch);
        if (cleanup.model) self.models.cancel(ticket.model_epoch);
        if (cleanup.session_state) {
            self.artifacts.discardSession(ticket.session, ticket.generation);
            self.completeLifecycle(ticket.session, ticket.generation);
        }
        self.operation_registry.retireCancellation(ticket, cleanup.callback_suppressed);
    }

    fn enqueue(self: *FridayHost, key: u64, ok: bool, bytes: []const u8) void {
        _ = self.enqueueResult(key, ok, bytes);
    }

    fn enqueueResult(self: *FridayHost, key: u64, ok: bool, bytes: []const u8) bool {
        const queued = self.operation_registry.enqueue(key, ok, bytes);
        self.mutex.lock();
        const services = self.services;
        self.mutex.unlock();
        if (queued) if (services) |live| live.wake() catch self.requestCurrentLifecycleAbort();
        return queued;
    }

    fn poll(context: *anyopaque) ?native_sdk.HostCallCompletion {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        self.finishMicrophonePermissionProbe();
        return self.operation_registry.poll();
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
        return self.operation_registry.pending();
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
            self.diagnostics.hotkeyReceived(system.wallMs());
            self.generation += 1;
            var source = self.delivery.captureFrontmostSource() catch return;
            if (valueString(payload_value.object.get("token"))) |token| if (token.len == source.token.len) @memcpy(&source.token, token);
            const pointer = self.artifacts.retainSource(source, self.generation) catch {
                source.deinit(self.allocator);
                return;
            };
            self.activateLifecycle(self.generation, self.generation);
            self.setPreferredSourceFrame(pointer.source_screen_frame);
            var output: [2048]u8 = undefined;
            var writer = std.Io.Writer.fixed(&output);
            writer.print("hotkey_down|{d}|{d}|", .{ self.generation, at_ms }) catch return;
            json.writeBase64(&writer, &pointer.token) catch return;
            writer.print("|{d}|", .{pointer.pid}) catch return;
            json.writeBase64(&writer, pointer.bundle_id) catch return;
            writer.writeByte('|') catch return;
            json.writeBase64(&writer, pointer.app_name) catch return;
            if (!self.emit(writer.buffered())) self.requestLifecycleAbort(self.generation);
        } else if (std.mem.eql(u8, event, "hotkey_up")) {
            const generation = self.currentLifecycleGeneration();
            if (generation == 0) return;
            var output: [128]u8 = undefined;
            const wire = std.fmt.bufPrint(&output, "hotkey_up|{d}|{d}", .{ generation, at_ms }) catch return;
            if (!self.emit(wire)) self.requestLifecycleAbort(generation);
        } else {
            const generation = self.currentLifecycleGeneration();
            if (generation == 0) return;
            const reason = valueString(payload_value.object.get("reason")) orelse "invalidated";
            var output: [256]u8 = undefined;
            const wire = std.fmt.bufPrint(&output, "hotkey_cancel|{d}|{d}|{s}", .{ generation, at_ms, reason }) catch return;
            if (!self.emit(wire)) self.requestLifecycleAbort(generation);
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

    fn audioEvent(context: *anyopaque, event: []const u8, payload: []const u8) bool {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        const session = json.unsignedValue(payload, "sessionId") orelse 0;
        const generation = self.artifacts.generationForAudio(session);
        if (session == 0 or generation == 0 or !self.lifecycleMatches(session, generation)) return false;
        if (std.mem.eql(u8, event, "audio_meter")) {
            const elapsed = json.unsignedValue(payload, "elapsedMilliseconds") orelse 0;
            const level = json.unsignedValue(payload, "level") orelse 0;
            const rms = @min(json.unsignedValue(payload, "rmsMilli") orelse 0, 1000);
            const peak = @min(json.unsignedValue(payload, "peakMilli") orelse 0, 1000);
            const frames = json.unsignedValue(payload, "capturedFrames") orelse 0;
            self.overlay.updateMeter(@intCast(@min(rms * 5 + peak, 1000)), elapsed);
            var output: [256]u8 = undefined;
            const wire = std.fmt.bufPrint(&output, "audio_meter|{d}|{d}|{d}|{d}|{d}", .{ generation, session, elapsed, level, frames }) catch return false;
            const accepted = self.emit(wire);
            if (!accepted) self.requestLifecycleAbort(generation);
            return accepted;
        }
        if (std.mem.eql(u8, event, "duration_limit")) self.setLifecycleDeadline(session, generation, system.monotonicMs() +| lifecycle_handoff_timeout_ms);
        var output: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        writer.print("{s}|{d}|{d}|", .{ event, generation, session }) catch return false;
        json.writeBase64(&writer, payload) catch return false;
        const accepted = self.emit(writer.buffered());
        if (!accepted or std.mem.eql(u8, event, "audio_interrupted")) self.requestLifecycleAbort(generation);
        return accepted;
    }

    fn audioAbort(context: *anyopaque, session: u64) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        const generation = self.artifacts.generationForAudio(session);
        if (generation != 0 and self.lifecycleMatches(session, generation)) self.requestLifecycleAbort(generation);
    }

    fn modelProgress(context: *anyopaque, operation: u64, state: []const u8, downloaded: u64, total: u64) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        var output: [256]u8 = undefined;
        const wire = std.fmt.bufPrint(&output, "model_progress|{d}|{s}|{d}|{d}", .{ operation, state, downloaded, total }) catch return;
        _ = self.emit(wire);
    }

    fn overlayEvent(context: *anyopaque, action: []const u8) void {
        const self: *FridayHost = @ptrCast(@alignCast(context));
        const generation = self.currentLifecycleGeneration();
        if (generation == 0) return;
        var output: [256]u8 = undefined;
        const wire = std.fmt.bufPrint(&output, "{s}|{d}", .{ action, generation }) catch return;
        if (!self.emit(wire)) self.requestLifecycleAbort(generation);
    }

    fn emitPermissions(self: *FridayHost) void {
        var permissions: [256]u8 = undefined;
        const length = self.writePermissions(&permissions);
        var output: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        writer.print("permissions|{d}|", .{self.generation}) catch return;

        json.writeBase64(&writer, permissions[0..length]) catch return;
        _ = self.emit(writer.buffered());
    }
    fn setPreferredSourceFrame(self: *FridayHost, frame: anytype) void {
        const preferred: ?overlay_mod.ScreenFrame = if (frame) |value|
            overlay_mod.ScreenFrame.init(value.origin.x, value.origin.y, value.size.width, value.size.height)
        else
            null;
        self.overlay.setPreferredScreenFrame(preferred);
    }

    fn emit(self: *FridayHost, bytes: []const u8) bool {
        const closing = self.operation_registry.isClosing();
        self.mutex.lock();
        const handle = if (!closing) self.event_handle else null;
        self.mutex.unlock();
        const outcome = if (handle) |live| live.post(bytes) else native_sdk.ChannelHandle.PostResult.closed;
        return switch (outcome) {
            .accepted => true,
            .dropped_full, .dropped_oversized, .closed => {
                self.mutex.lock();
                self.diagnostics.eventPostFailed();
                self.event_handle = null;
                self.mutex.unlock();
                return false;
            },
        };
    }

    fn activateLifecycle(self: *FridayHost, session: u64, generation: u64) void {
        if (session == 0 or generation == 0) return;
        if (self.operation_registry.isClosing()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (generation <= self.retired_lifecycle_generation) return;
        self.current_audio_session = session;
        self.current_audio_generation = generation;
        self.lifecycle_deadline_ms = 0;
        self.lifecycle_active = true;
    }

    fn resolveLifecycleIdentity(self: *FridayHost, supplied_session: u64, supplied_generation: u64) LifecycleIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .session = if (supplied_session != 0) supplied_session else self.current_audio_session,
            .generation = if (supplied_generation != 0) supplied_generation else self.current_audio_generation,
        };
    }

    fn lifecycleMatches(self: *FridayHost, session: u64, generation: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.lifecycle_active and generation != 0 and self.current_audio_session == session and self.current_audio_generation == generation;
    }

    fn setLifecycleDeadline(self: *FridayHost, session: u64, generation: u64, deadline_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.lifecycle_active and self.current_audio_session == session and self.current_audio_generation == generation)
            self.lifecycle_deadline_ms = deadline_ms;
    }

    fn clearLifecycleDeadline(self: *FridayHost, session: u64, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.lifecycle_active and self.current_audio_session == session and self.current_audio_generation == generation)
            self.lifecycle_deadline_ms = 0;
    }

    fn requestLifecycleAbort(self: *FridayHost, generation: u64) void {
        if (generation == 0) return;
        var observed = self.lifecycle_abort_generation.load(.acquire);
        while (generation > observed) {
            observed = self.lifecycle_abort_generation.cmpxchgWeak(observed, generation, .acq_rel, .acquire) orelse return;
        }
    }

    fn requestCurrentLifecycleAbort(self: *FridayHost) void {
        self.mutex.lock();
        const generation = if (self.lifecycle_active) self.current_audio_generation else 0;
        self.mutex.unlock();
        self.requestLifecycleAbort(generation);
    }

    fn currentLifecycleGeneration(self: *FridayHost) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.lifecycle_active) self.current_audio_generation else 0;
    }

    fn failClosedLifecycle(self: *FridayHost, session: u64, generation: u64) void {
        if (session == 0 or generation == 0) return;
        self.mutex.lock();
        if (!self.lifecycle_active or self.current_audio_session != session or self.current_audio_generation != generation) {
            self.mutex.unlock();
            return;
        }
        self.lifecycle_active = false;
        self.lifecycle_deadline_ms = 0;
        self.current_audio_session = 0;
        self.current_audio_generation = 0;
        self.retired_lifecycle_generation = @max(self.retired_lifecycle_generation, generation);
        self.mutex.unlock();
        self.operation_registry.retireGeneration(generation);

        // The watchdog is the single teardown owner. Producers only request
        // revocation, so audio callbacks never join their own worker and no
        // lossy event is needed to finish native cleanup.
        self.audio.cancelSession(session);
        self.recognizer.cancelGeneration(generation);
        self.artifacts.discardSession(session, generation);
        self.audio.discardRetryAudio();
        self.overlay.hide();
    }

    fn completeLifecycle(self: *FridayHost, session: u64, generation: u64) void {
        self.mutex.lock();
        if (!self.lifecycle_active or self.current_audio_session != session or self.current_audio_generation != generation) {
            self.mutex.unlock();
            return;
        }
        self.lifecycle_active = false;
        self.lifecycle_deadline_ms = 0;
        self.current_audio_session = 0;
        self.current_audio_generation = 0;
        self.retired_lifecycle_generation = @max(self.retired_lifecycle_generation, generation);
        self.mutex.unlock();
        self.operation_registry.retireGeneration(generation);
    }

    fn completeLifecycleGeneration(self: *FridayHost, generation: u64) void {
        if (generation == 0) return;
        self.mutex.lock();
        const session = if (self.lifecycle_active and self.current_audio_generation == generation) self.current_audio_session else 0;
        self.mutex.unlock();
        if (session != 0) self.completeLifecycle(session, generation);
    }

    fn updateTranscriptionState(self: *FridayHost, operation: *Operation, ok: bool, bytes: []const u8) void {
        self.diagnostics.transcriptionCompleted(ok, bytes, system.wallMs());
        if (ok) {
            const silence = json.boolValue(bytes, "silence") orelse false;
            const text = json.stringAlloc(self.allocator, bytes, "text") catch null;
            defer if (text) |value| self.allocator.free(value);
            if (!silence and text != null and text.?.len > 0)
                _ = self.artifacts.storeFinal(operation.session, operation.generation, text.?);
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

    fn operationHost(operation: *Operation) *FridayHost {
        return @ptrCast(@alignCast(operation.context));
    }

    fn submitRetryTranscription(context: *anyopaque, path: []const u8) !void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        try self.recognizer.transcribeAudio(path, operation.session, operation.generation, transcribeCompletion(operation));
    }

    fn genericCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        operationHost(operation).finishOperation(operation, ok, bytes);
    }

    fn audioCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        if (!self.operationPending(operation)) {
            self.audio.cancelSession(operation.session);
            self.finishOperation(operation, ok, bytes);
            return;
        }
        if (operation.kind == .audio_stop) {
            var output: [result_capacity]u8 = undefined;
            const length = json.addGeneration(&output, bytes, operation.generation) catch return self.finishError(operation, "serialization_failed", "The capture result could not be serialized.");
            if (ok) self.diagnostics.audioStopped(bytes, system.wallMs());
            self.finishOperation(operation, ok, output[0..length]);
            return;
        }
        self.finishOperation(operation, ok, bytes);
    }

    fn transcribeCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        self.updateTranscriptionState(operation, ok, bytes);
        self.artifacts.clearAudio(operation.session);
        self.finishOperation(operation, ok, bytes);
    }

    fn finishCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        if (operation.stage == .stopping) {
            if (!ok) return self.finishOperation(operation, false, bytes);
            _ = self.models.activeModelPath() orelse {
                self.artifacts.clearAudio(operation.session);
                var output: [4096]u8 = undefined;
                var writer = std.Io.Writer.fixed(&output);
                writer.print("{{\"ok\":false,\"generation\":{d},\"sessionId\":{d},\"code\":\"model_unavailable\",\"capture\":{s},\"retryAudioAvailable\":true}}", .{ operation.generation, operation.session, bytes }) catch return;
                return self.finishOperation(operation, false, writer.buffered());
            };
            const path = json.stringAlloc(self.allocator, bytes, "audioPath") catch null orelse return self.finishError(operation, "audio_unavailable", "Captured audio is unavailable.");
            defer self.allocator.free(path);
            if (!self.saveOperationResult(operation, bytes)) return self.finishError(operation, "out_of_memory", "The capture result could not be retained.");
            if (!self.transitionOperation(operation, .transcribing)) return self.finishOperation(operation, false, "");
            self.recognizer.transcribeAudio(path, operation.session, operation.generation, finishNemoCompletion(operation)) catch self.finishError(operation, "transcription_failed", "Local transcription could not start.");
        }
    }

    fn finishNemoCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = finishNemoCallback };
    }

    fn finishNemoCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        self.updateTranscriptionState(operation, ok, bytes);
        var output: [result_capacity]u8 = undefined;
        const capture = operation.saved orelse "{}";
        const length = json.mergeNamed(&output, bytes, "capture", capture) catch return self.finishError(operation, "serialization_failed", "The transcription result could not be serialized.");
        self.artifacts.clearAudio(operation.session);
        self.finishOperation(operation, ok, output[0..length]);
    }

    fn modelCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        if (!ok) return self.finishOperation(operation, false, bytes);
        const path = self.models.activeModelPath() orelse return self.finishOperation(operation, true, bytes);
        if (!self.saveOperationResult(operation, bytes)) return self.finishError(operation, "out_of_memory", "The model result could not be retained.");
        if (!self.transitionOperation(operation, .activating)) return self.finishOperation(operation, false, "");
        self.recognizer.activateModel(path, operation.model_epoch, modelActivationCompletion(operation)) catch self.finishError(operation, "model_probe_failed", "The selected model could not be loaded.");
    }

    fn modelActivationCompletion(operation: *Operation) nemo_mod.AsyncCompletion {
        return .{ .context = operation, .complete = modelActivationCallback };
    }

    fn modelActivationCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        self.models.markRuntimeReady(self.models.activeModelKey(), ok);
        if (!ok) return self.finishOperation(operation, false, bytes);
        self.finishOperation(operation, true, operation.saved orelse bytes);
    }

    fn fixtureCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
        if (!self.operationPending(operation)) return self.finishOperation(operation, ok, bytes);
        if (!ok) {
            self.artifacts.discardGeneration(operation.generation);
            return self.finishOperation(operation, false, bytes);
        }
        if (operation.stage == .activating) {
            if (!self.transitionOperation(operation, .transcribing)) return self.finishOperation(operation, false, "");
            self.recognizer.transcribeAudio(operation.path[0..operation.path_len], operation.session, operation.generation, fixtureCompletion(operation)) catch self.finishError(operation, "transcription_failed", "The fixture could not be transcribed.");
            return;
        }
        const silence = json.boolValue(bytes, "silence") orelse false;
        const text = json.stringAlloc(self.allocator, bytes, "text") catch null;
        defer if (text) |value| self.allocator.free(value);
        if (silence or text == null or text.?.len == 0) {
            self.artifacts.discardGeneration(operation.generation);
            return self.finishOperation(operation, false, bytes);
        }
        _ = self.artifacts.storeFinal(operation.session, operation.generation, text.?);
        var payload: [160]u8 = undefined;
        const request_bytes = std.fmt.bufPrint(&payload, "session={d};generation={d};paste=0", .{ operation.session, operation.generation }) catch return self.finishError(operation, "delivery_failed", "The fixture could not be delivered.");
        var output: [result_capacity]u8 = undefined;
        const length = self.deliverSession(request_bytes, &output);
        self.finishOperation(operation, length > 0 and json.objectOk(output[0..length]), output[0..length]);
    }

    fn performanceCallback(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const operation: *Operation = @ptrCast(@alignCast(context));
        const self = operationHost(operation);
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

const LifecycleSnapshot = struct {
    active: bool,
    session: u64,
    generation: u64,
    deadline_ms: u64,
    channel_live: bool,
};

fn lifecycleMustAbort(snapshot: LifecycleSnapshot, requested_generation: u64, now_ms: u64) bool {
    if (!snapshot.active or snapshot.session == 0 or snapshot.generation == 0) return false;
    return requested_generation == snapshot.generation or
        !snapshot.channel_live or
        (snapshot.deadline_ms != 0 and now_ms >= snapshot.deadline_ms);
}

fn lifecycleMain(self: *FridayHost) void {
    while (!self.lifecycle_stop.load(.acquire)) {
        const requested_generation = self.lifecycle_abort_generation.swap(0, .acq_rel);
        const closing = self.operation_registry.isClosing();
        self.mutex.lock();
        const handle = if (!closing and self.lifecycle_active) self.event_handle else null;
        var snapshot = LifecycleSnapshot{
            .active = !closing and self.lifecycle_active,
            .session = self.current_audio_session,
            .generation = self.current_audio_generation,
            .deadline_ms = self.lifecycle_deadline_ms,
            .channel_live = false,
        };
        self.mutex.unlock();
        snapshot.channel_live = if (handle) |live| live.live() else false;
        if (lifecycleMustAbort(snapshot, requested_generation, system.monotonicMs()))
            self.failClosedLifecycle(snapshot.session, snapshot.generation);
        _ = usleep(lifecycle_poll_us);
    }
}

/// App-extension lifecycle consumed by the stock Native SDK TypeScript runner.
pub const Host = FridayHost;

pub fn testExtension() !void {
    try operations_mod.testContracts();
    try artifacts_mod.testContracts();
    try diagnostics_mod.testContracts();
    try audio_mod.testContracts();
    const live = LifecycleSnapshot{ .active = true, .session = 31, .generation = 32, .deadline_ms = 0, .channel_live = true };
    try std.testing.expect(!lifecycleMustAbort(live, 0, 100));
    try std.testing.expect(!lifecycleMustAbort(live, 31, 100));
    try std.testing.expect(lifecycleMustAbort(live, 32, 100));
    var closed = live;
    closed.channel_live = false;
    try std.testing.expect(lifecycleMustAbort(closed, 0, 100));
    var deadline = live;
    deadline.deadline_ms = 500;
    try std.testing.expect(!lifecycleMustAbort(deadline, 0, 499));
    try std.testing.expect(lifecycleMustAbort(deadline, 0, 500));
    var generation_zero = live;
    generation_zero.generation = 0;
    try std.testing.expect(!lifecycleMustAbort(generation_zero, 0, 1_000));
}

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
