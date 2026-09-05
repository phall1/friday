const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const ProgressSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, u64, []const u8, u64, u64) void,
};

pub const Ticket = u64;

pub const AsyncCompletion = struct {
    context: *anyopaque,
    admit: ?*const fn (*anyopaque, Ticket) void = null,
    complete: *const fn (*anyopaque, bool, []const u8) void,
};

pub const ProbeResult = struct {
    ok: bool,
    streaming: bool = false,
    code: []const u8 = "",
    message: []const u8 = "",
};

/// Synchronous recognizer create/destroy seam. The repository invokes it only
/// on its serialized worker. Returned slices are borrowed until `probe` returns.
pub const RecognizerProbe = struct {
    context: *anyopaque,
    probe: *const fn (*anyopaque, []const u8, u64) ProbeResult,
};

const policy = @import("model_policy.zig");
const publication = @import("model_publication.zig");
const source_mod = @import("model_source.zig");
const fileSize = publication.fileSize;
const directoryExists = publication.directoryExists;
const syncFile = publication.syncFile;
const syncDirectory = publication.syncDirectory;
const hashFileHex = publication.hashFileHex;
const max_artifact_bytes = policy.max_artifact_bytes;
const TrustedManifestPin = policy.TrustedManifestPin;
const trusted_manifest_pins = policy.trusted_manifest_pins;
const default_pin = policy.default_pin;
const ModelSpec = policy.ModelSpec;
const Model = policy.Model;
const defaultModel = policy.defaultModel;
const trustedModel = policy.trustedModel;
const isLowerHex = policy.isLowerHex;
const hasExtension = policy.hasExtension;
const topLevelArtifact = policy.topLevelArtifact;
const safeHuggingFaceIdentifier = policy.safeHuggingFaceIdentifier;
const modelKeyForIdentifier = policy.modelKeyForIdentifier;
const sameIdentity = policy.sameIdentity;
const allowlistedArtifactIdentity = policy.allowlistedArtifactIdentity;
const allowlistedManifest = policy.allowlistedManifest;
const validInstalledRecord = policy.validInstalledRecord;
const legacyRecognitionMode = policy.legacyRecognitionMode;
const validCapabilities = policy.validCapabilities;
const probeMatchesManifest = policy.probeMatchesManifest;
const validDownloadManifest = policy.validDownloadManifest;
const max_json_bytes: usize = 2 * 1024 * 1024;
const resume_persist_interval: u64 = 1024 * 1024;

const AsyncOperation = struct { request_key: u64, epoch: u64, completion: AsyncCompletion };
const AddOperation = struct { path: []u8, key: u64, request_key: u64, epoch: u64, completion: AsyncCompletion };
const IdentifierOperation = struct { identifier: []u8, request_key: u64, epoch: u64, completion: AsyncCompletion };
const SelectOperation = struct { key: u64, request_key: u64, epoch: u64, completion: AsyncCompletion };

const SyncRequest = struct {
    kind: union(enum) {
        status: void,
        remove: struct { key: u64, delete_managed: bool },
        remove_failed: void,
    },
    output: []u8,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    done: bool = false,
    length: usize = 0,
    err: ?anyerror = null,
};

const Command = struct {
    next: ?*Command = null,
    payload: union(enum) {
        download_default: AsyncOperation,
        resume_pending: AsyncOperation,
        add_local: AddOperation,
        resolve_hf: IdentifierOperation,
        download_resolved_hf: IdentifierOperation,
        select: SelectOperation,
        sync: *SyncRequest,
    },
};

const Candidate = struct {
    identifier: []u8,
    model: Model,

    fn deinit(self: *Candidate, allocator: Allocator) void {
        allocator.free(self.identifier);
        self.model.deinit(allocator);
    }
};

const Resume = struct {
    model: Model,
    partial_bytes: u64,
    etag: []u8,
    last_modified: []u8,
    operation_root: []u8,

    fn deinit(self: *Resume, allocator: Allocator) void {
        self.model.deinit(allocator);
        allocator.free(self.etag);
        allocator.free(self.last_modified);
        allocator.free(self.operation_root);
    }
};

const CancelledEpochs = struct {
    slots: [128]u64 = @splat(0),

    fn insert(self: *CancelledEpochs, epoch: u64) bool {
        if (epoch == 0) return false;
        for (&self.slots) |*slot| {
            if (slot.* == epoch) return true;
            if (slot.* == 0) {
                slot.* = epoch;
                return true;
            }
        }
        return false;
    }

    fn contains(self: CancelledEpochs, epoch: u64) bool {
        for (self.slots) |slot| if (slot == epoch) return true;
        return false;
    }

    fn remove(self: *CancelledEpochs, epoch: u64) void {
        for (&self.slots) |*slot| if (slot.* == epoch) {
            slot.* = 0;
            return;
        };
    }
};

pub const Intent = union(enum) {
    download_default: struct { request_key: u64 },
    resume_pending: struct { request_key: u64 },
    add_local: struct { path: []const u8, key: u64, request_key: u64 },
    resolve_hf: struct { identifier: []const u8, request_key: u64 },
    download_resolved_hf: struct { identifier: []const u8, request_key: u64 },
    select: struct { key: u64, request_key: u64 },
};

pub const Snapshot = struct {
    active_key: u64,
    /// Borrowed until the next successful activation/publication or deinit.
    active_path: ?[]const u8,
    runtime_ready: bool,
};

pub const ModelRepository = struct {
    state: *State,

    pub fn init(
        allocator: Allocator,
        data_directory: []const u8,
        probe: RecognizerProbe,
        progress: ?ProgressSink,
    ) !ModelRepository {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = try State.init(allocator, data_directory, probe, progress);
        errdefer state.fini();
        state.thread = try std.Thread.spawn(.{}, State.run, .{state});
        return .{ .state = state };
    }

    pub fn deinit(self: *ModelRepository) void {
        const state = self.state;
        const io = state.threaded_io.io();
        state.mutex.lockUncancelable(io);
        state.stopping = true;
        state.condition.signal(io);
        state.mutex.unlock(io);
        state.thread.?.join();
        state.fini();
        state.threaded_io.deinit();
        state.allocator.destroy(state);
        self.* = undefined;
    }

    pub fn snapshot(self: *const ModelRepository) Snapshot {
        const io = self.state.threaded_io.io();
        self.state.snapshot_mutex.lockUncancelable(io);
        defer self.state.snapshot_mutex.unlock(io);
        return .{
            .active_key = self.state.active_key,
            .active_path = self.state.active_path,
            .runtime_ready = self.state.runtime_ready,
        };
    }

    pub fn markRuntimeReady(self: *ModelRepository, key: u64, ready: bool) void {
        const io = self.state.threaded_io.io();
        self.state.snapshot_mutex.lockUncancelable(io);
        defer self.state.snapshot_mutex.unlock(io);
        if (self.state.active_key == key) self.state.runtime_ready = ready;
    }

    pub fn writeStatus(self: *ModelRepository, output: []u8) !usize {
        return self.sync(.{ .status = {} }, output);
    }

    /// Allocates the cancellation identity and publishes its command while
    /// holding one repository lock, so callers cannot race an unqueued epoch.
    pub fn submit(self: *ModelRepository, intent: Intent, completion: AsyncCompletion) !Ticket {
        const state = self.state;
        const io = state.threaded_io.io();
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        if (state.stopping) return error.RepositoryClosed;

        const epoch = state.next_operation_epoch;
        state.next_operation_epoch +%= 1;
        if (state.next_operation_epoch == 0) state.next_operation_epoch = 1;
        const command = try state.allocator.create(Command);
        errdefer state.allocator.destroy(command);
        command.* = .{ .payload = switch (intent) {
            .download_default => |value| .{ .download_default = .{ .request_key = value.request_key, .epoch = epoch, .completion = completion } },
            .resume_pending => |value| .{ .resume_pending = .{ .request_key = value.request_key, .epoch = epoch, .completion = completion } },
            .add_local => |value| .{ .add_local = .{
                .path = try state.allocator.dupe(u8, value.path),
                .key = value.key,
                .request_key = value.request_key,
                .epoch = epoch,
                .completion = completion,
            } },
            .resolve_hf => |value| .{ .resolve_hf = .{
                .identifier = try state.allocator.dupe(u8, value.identifier),
                .request_key = value.request_key,
                .epoch = epoch,
                .completion = completion,
            } },
            .download_resolved_hf => |value| .{ .download_resolved_hf = .{
                .identifier = try state.allocator.dupe(u8, value.identifier),
                .request_key = value.request_key,
                .epoch = epoch,
                .completion = completion,
            } },
            .select => |value| .{ .select = .{
                .key = value.key,
                .request_key = value.request_key,
                .epoch = epoch,
                .completion = completion,
            } },
        } };
        if (completion.admit) |admit| admit(completion.context, epoch);
        if (state.tail) |tail| tail.next = command else state.head = command;
        state.tail = command;
        state.condition.signal(io);
        return epoch;
    }

    pub fn cancel(self: *ModelRepository, epoch: u64) void {
        if (epoch == 0) return;
        const state = self.state;
        const io = state.threaded_io.io();
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        if (state.stopping) return;
        _ = state.cancelled_epochs.insert(epoch);
    }

    pub fn remove(self: *ModelRepository, key: u64, delete_managed: bool, output: []u8) !usize {
        return self.sync(.{ .remove = .{ .key = key, .delete_managed = delete_managed } }, output);
    }

    pub fn removeFailed(self: *ModelRepository, output: []u8) !usize {
        return self.sync(.{ .remove_failed = {} }, output);
    }

    pub fn writeContractProbes(output: []u8) !usize {
        const probes = try runContractProbes();
        return stringifyFixed(output, probes);
    }

    pub fn testContracts() !void {
        try policy.testContracts();
        try source_mod.testContracts();
        try publication.testContracts();
        const probes = try runContractProbes();
        try std.testing.expect(probes.ok);
        try std.testing.expect(probes.cancellationCycles);
    }

    fn enqueue(self: *ModelRepository, payload: @FieldType(Command, "payload")) !void {
        const state = self.state;
        const io = state.threaded_io.io();
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        if (state.stopping) return error.RepositoryClosed;
        const command = try state.allocator.create(Command);
        command.* = .{ .payload = payload };
        if (state.tail) |tail| tail.next = command else state.head = command;
        state.tail = command;
        state.condition.signal(io);
    }

    fn sync(self: *ModelRepository, kind: @FieldType(SyncRequest, "kind"), output: []u8) !usize {
        var request = SyncRequest{ .kind = kind, .output = output };
        try self.enqueue(.{ .sync = &request });
        const io = self.state.threaded_io.io();
        request.mutex.lockUncancelable(io);
        while (!request.done) request.condition.waitUncancelable(io, &request.mutex);
        request.mutex.unlock(io);
        if (request.err) |err| return err;
        return request.length;
    }
};

const State = struct {
    allocator: Allocator,
    threaded_io: std.Io.Threaded,
    models_root: []u8,
    downloads_root: []u8,
    index_path: []u8,
    probe: RecognizerProbe,
    progress: ?ProgressSink,

    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    head: ?*Command = null,
    tail: ?*Command = null,
    stopping: bool = false,
    thread: ?std.Thread = null,
    next_operation_epoch: u64 = 1,
    cancelled_epochs: CancelledEpochs = .{},

    snapshot_mutex: Io.Mutex = .init,
    models: std.ArrayList(Model) = .empty,
    candidates: std.ArrayList(Candidate) = .empty,
    active_key: u64 = 0,
    active_path: ?[]u8 = null,
    runtime_ready: bool = false,
    download_active: bool = false,
    downloaded_bytes: u64 = 0,
    total_bytes: u64 = 0,

    fn init(
        allocator: Allocator,
        data_directory: []const u8,
        probe: RecognizerProbe,
        progress: ?ProgressSink,
    ) !State {
        var threaded_io = std.Io.Threaded.init(allocator, .{});
        errdefer threaded_io.deinit();
        const models_root = try std.fs.path.join(allocator, &.{ data_directory, "Models" });
        errdefer allocator.free(models_root);
        const downloads_root = try std.fs.path.join(allocator, &.{ data_directory, "ModelDownloads" });
        errdefer allocator.free(downloads_root);
        const index_path = try std.fs.path.join(allocator, &.{ models_root, "index.json" });
        errdefer allocator.free(index_path);

        try Dir.cwd().createDirPath(threaded_io.io(), models_root);
        try Dir.cwd().createDirPath(threaded_io.io(), downloads_root);

        var state = State{
            .allocator = allocator,
            .threaded_io = threaded_io,
            .models_root = models_root,
            .downloads_root = downloads_root,
            .index_path = index_path,
            .probe = probe,
            .progress = progress,
        };
        state.loadIndex();
        const migrated = state.migratePinnedDefaultIfNeeded() catch false;
        if (!migrated) state.revalidateActiveAtStartup();
        return state;
    }

    fn fini(self: *State) void {
        while (self.head) |command| {
            self.head = command.next;
            self.freeCommandPayload(command.payload);
            self.allocator.destroy(command);
        }
        for (self.models.items) |*model| model.deinit(self.allocator);
        self.models.deinit(self.allocator);
        for (self.candidates.items) |*candidate| candidate.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        if (self.active_path) |path| self.allocator.free(path);
        self.allocator.free(self.models_root);
        self.allocator.free(self.downloads_root);
        self.allocator.free(self.index_path);
    }

    fn run(self: *State) void {
        const io = self.threaded_io.io();
        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.head == null and !self.stopping) self.condition.waitUncancelable(io, &self.mutex);
            if (self.head == null and self.stopping) {
                self.mutex.unlock(io);
                return;
            }
            const command = self.head.?;
            self.head = command.next;
            if (self.head == null) self.tail = null;
            self.mutex.unlock(io);

            self.execute(command.payload);
            self.freeCommandPayload(command.payload);
            self.allocator.destroy(command);
        }
    }

    fn freeCommandPayload(self: *State, payload: @FieldType(Command, "payload")) void {
        switch (payload) {
            .add_local => |operation| self.allocator.free(operation.path),
            .resolve_hf, .download_resolved_hf => |operation| self.allocator.free(operation.identifier),
            else => {},
        }
    }

    fn execute(self: *State, payload: @FieldType(Command, "payload")) void {
        switch (payload) {
            .download_default => |operation| self.executeDownloadDefault(operation),
            .resume_pending => |operation| self.executeResume(operation),
            .add_local => |operation| self.executeAddLocal(operation),
            .resolve_hf => |operation| self.executeResolveHF(operation),
            .download_resolved_hf => |operation| self.executeDownloadResolvedHF(operation),
            .select => |operation| self.executeSelect(operation),
            .sync => |request| self.executeSync(request),
        }
    }

    fn executeSync(self: *State, request: *SyncRequest) void {
        const result = switch (request.kind) {
            .status => self.writeStatus(request.output),
            .remove => |remove| self.removeModel(remove.key, remove.delete_managed, request.output),
            .remove_failed => self.removeFailedDownloads(request.output),
        };
        const io = self.threaded_io.io();
        request.mutex.lockUncancelable(io);
        if (result) |length| request.length = length else |err| request.err = err;
        request.done = true;
        request.condition.signal(io);
        request.mutex.unlock(io);
    }

    fn completeValue(self: *State, completion: AsyncCompletion, ok: bool, value: anytype) void {
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        std.json.Stringify.value(value, .{}, &writer.writer) catch {
            completion.complete(completion.context, false, "{\"ok\":false,\"code\":\"serialization_failed\"}");
            return;
        };
        completion.complete(completion.context, ok, writer.written());
    }

    fn fail(self: *State, completion: AsyncCompletion, code: []const u8, message: []const u8) void {
        self.completeValue(completion, false, .{ .ok = false, .code = code, .message = message });
    }

    fn publishProgress(self: *State, operation: u64, state: []const u8, downloaded: u64, total: u64) void {
        if (self.progress) |progress| progress.emit(progress.context, operation, state, downloaded, total);
    }

    fn findModel(self: *State, key: u64) ?usize {
        for (self.models.items, 0..) |model, index| if (model.key == key) return index;
        return null;
    }

    fn setActiveSnapshot(self: *State, model: Model, runtime_ready: bool) !void {
        const path = try self.allocator.dupe(u8, model.path);
        const io = self.threaded_io.io();
        self.snapshot_mutex.lockUncancelable(io);
        defer self.snapshot_mutex.unlock(io);
        if (self.active_path) |old_path| self.allocator.free(old_path);
        self.active_path = path;
        self.active_key = model.key;
        self.runtime_ready = runtime_ready;
    }

    fn activateSnapshot(self: *State, model: Model) !void {
        try self.setActiveSnapshot(model, true);
    }

    fn restorePendingSnapshot(self: *State, model: Model) !void {
        try self.setActiveSnapshot(model, false);
    }

    fn clearActive(self: *State) void {
        const io = self.threaded_io.io();
        self.snapshot_mutex.lockUncancelable(io);
        defer self.snapshot_mutex.unlock(io);
        if (self.active_path) |path| self.allocator.free(path);
        self.active_path = null;
        self.active_key = 0;
        self.runtime_ready = false;
    }

    fn upsertAndActivate(self: *State, source: Model) !void {
        var copy = try source.clone(self.allocator);
        errdefer copy.deinit(self.allocator);
        if (self.findModel(copy.key)) |index| {
            self.models.items[index].deinit(self.allocator);
            self.models.items[index] = copy;
        } else {
            try self.models.append(self.allocator, copy);
        }
        const installed = &self.models.items[self.findModel(source.key).?];
        try self.activateSnapshot(installed.*);
        try self.saveIndex();
    }

    fn executeDownloadDefault(self: *State, operation: AsyncOperation) void {
        defer self.retireEpoch(operation.epoch);
        var model = defaultModel(self.allocator) catch {
            self.fail(operation.completion, "out_of_memory", "The model operation could not be prepared.");
            return;
        };
        defer model.deinit(self.allocator);
        self.downloadModel(&model, operation.request_key, operation.epoch, operation.completion);
    }

    fn executeResume(self: *State, operation: AsyncOperation) void {
        defer self.retireEpoch(operation.epoch);
        var pending_resume = self.findPendingResume() catch null;
        if (pending_resume == null) {
            self.fail(operation.completion, "resume_unavailable", "No valid partial model download is available to resume.");
            return;
        }
        defer pending_resume.?.deinit(self.allocator);
        self.downloadModel(&pending_resume.?.model, operation.request_key, operation.epoch, operation.completion);
    }

    fn executeAddLocal(self: *State, operation: AddOperation) void {
        defer self.retireEpoch(operation.epoch);
        if (self.cancelled(operation.epoch)) return self.completeCancelled(operation.completion, 0);
        if (!hasExtension(operation.path, ".gguf")) {
            self.fail(operation.completion, "not_allowlisted", "Friday can use only GGUF artifacts on its reviewed production allowlist.");
            return;
        }
        var model = self.loadLocalManifest(operation.path) catch {
            self.fail(operation.completion, "manifest_required", "A local model requires a matching Friday allowlist manifest.");
            return;
        };
        defer model.deinit(self.allocator);
        const pin = allowlistedManifest(model) orelse {
            self.fail(operation.completion, "not_allowlisted", "Friday inspected the sidecar metadata but will not open these model bytes because this immutable artifact is not on the production allowlist.");
            return;
        };
        const actual_size = fileSize(self.threaded_io.io(), operation.path) catch 0;
        const actual_sha = hashFileHex(self.threaded_io.io(), operation.path) catch {
            self.fail(operation.completion, "integrity_failed", "The local model could not be read for exact integrity verification.");
            return;
        };
        if (actual_size != pin.expected_bytes or !std.mem.eql(u8, &actual_sha, pin.sha256)) {
            self.fail(operation.completion, "integrity_failed", "The local model does not match the allowlisted size and SHA-256.");
            return;
        }
        // The bounded GGUF reader and external NeMo parser are reached only after compiled
        // allowlist admission and exact-byte verification.
        if (!validGgufHeader(self.threaded_io.io(), operation.path)) {
            self.fail(operation.completion, "allowlisted_artifact_invalid", "The allowlisted artifact failed its bounded GGUF check.");
            return;
        }
        const probe = self.probe.probe(self.probe.context, operation.path, operation.request_key);
        if (!probeMatchesManifest(&model, probe)) {
            self.fail(operation.completion, if (probe.code.len != 0) probe.code else "model_probe_failed", if (probe.message.len != 0) probe.message else "The allowlisted model failed its declared runtime capability probe.");
            return;
        }
        if (self.cancelled(operation.epoch)) return self.completeCancelled(operation.completion, 0);
        Model.replace(self.allocator, &model.verification, "production_allowlist_exact_integrity_and_runtime_probe") catch unreachable;
        model.key = operation.key;
        model.installed_bytes = model.expected_bytes;
        model.managed = false;
        Model.replace(self.allocator, &model.path, operation.path) catch {
            self.fail(operation.completion, "out_of_memory", "The local model record could not be prepared.");
            return;
        };
        Model.replace(self.allocator, &model.source, "local") catch unreachable;
        Model.replace(self.allocator, &model.compatibility, "compatible") catch unreachable;
        self.upsertAndActivate(model) catch {
            self.fail(operation.completion, "index_publication_failed", "");
            return;
        };
        self.completeValue(operation.completion, true, .{ .ok = true, .modelKey = operation.key, .probe = .{ .ok = true, .streaming = probe.streaming } });
    }

    fn executeSelect(self: *State, operation: SelectOperation) void {
        defer self.retireEpoch(operation.epoch);
        if (self.cancelled(operation.epoch)) return self.completeCancelled(operation.completion, 0);
        const index = self.findModel(operation.key) orelse {
            self.fail(operation.completion, "model_unavailable", "");
            return;
        };
        const model = &self.models.items[index];
        const valid = if (model.managed) self.validateManagedModel(model.*) else self.validateLocalModel(model.path);
        if (!valid) {
            self.runtime_ready = false;
            self.fail(operation.completion, "model_unavailable", "");
            return;
        }
        const probe = self.probe.probe(self.probe.context, model.path, operation.request_key);
        if (!probeMatchesManifest(model, probe)) {
            self.fail(operation.completion, if (probe.code.len != 0) probe.code else "model_probe_failed", probe.message);
            return;
        }
        if (self.cancelled(operation.epoch)) return self.completeCancelled(operation.completion, 0);
        self.activateSnapshot(model.*) catch {
            self.fail(operation.completion, "index_publication_failed", "");
            return;
        };
        self.saveIndex() catch {
            self.runtime_ready = false;
            self.fail(operation.completion, "index_publication_failed", "");
            return;
        };
        self.completeValue(operation.completion, true, .{ .ok = true, .modelKey = operation.key, .probe = .{ .ok = true, .streaming = probe.streaming } });
    }

    fn executeResolveHF(self: *State, operation: IdentifierOperation) void {
        defer self.retireEpoch(operation.epoch);
        const identifier = std.mem.trim(u8, operation.identifier, " \t\r\n");
        if (!safeHuggingFaceIdentifier(identifier)) {
            self.fail(operation.completion, "invalid_identifier", "Use a public Hugging Face identifier in owner/repository form.");
            return;
        }
        if (self.cancelled(operation.epoch)) {
            self.completeCancelled(operation.completion, 0);
            return;
        }

        const url = std.fmt.allocPrint(
            self.allocator,
            "https://huggingface.co/api/models/{s}?blobs=true&expand%5B%5D=siblings&expand%5B%5D=cardData&expand%5B%5D=tags&expand%5B%5D=sha&expand%5B%5D=gated&expand%5B%5D=private&expand%5B%5D=pipeline_tag&expand%5B%5D=author",
            .{identifier},
        ) catch {
            self.fail(operation.completion, "out_of_memory", "Hugging Face metadata is unavailable.");
            return;
        };
        defer self.allocator.free(url);

        const metadata = self.fetchMetadata(url) catch |err| {
            if (self.cancelled(operation.epoch)) {
                self.completeCancelled(operation.completion, 0);
            } else if (err == error.AccessDenied) {
                self.fail(operation.completion, "gated_or_private", "That repository is private or requires gated access.");
            } else {
                self.fail(operation.completion, "metadata_unavailable", "Hugging Face metadata is unavailable.");
            }
            return;
        };
        defer self.allocator.free(metadata);
        if (self.cancelled(operation.epoch)) {
            self.completeCancelled(operation.completion, 0);
            return;
        }

        var model = source_mod.parse(self.allocator, metadata, identifier) catch |err| {
            self.fail(operation.completion, "metadata_candidate_rejected", hfValidationMessage(err));
            return;
        };
        defer model.deinit(self.allocator);
        self.storeCandidate(identifier, model) catch {
            self.fail(operation.completion, "out_of_memory", "The resolved model candidate could not be retained.");
            return;
        };
        const allowlisted_pin = allowlistedArtifactIdentity(model);
        var size_buffer: [64]u8 = undefined;
        self.completeValue(operation.completion, true, .{
            .ok = true,
            .identifier = identifier,
            .revision = model.revision,
            .artifact = model.artifact,
            .expectedBytes = model.expected_bytes,
            .sizeText = formatByteCount(&size_buffer, model.expected_bytes),
            .license = if (allowlisted_pin) |pin| pin.license else model.license,
            .provider = "Hugging Face",
            .attribution = if (allowlisted_pin) |pin| pin.attribution else model.attribution,
            .verificationStatus = "unverified_candidate",
            .runtimeEligible = allowlisted_pin != null,
            .trustStatus = if (allowlisted_pin != null) "friday_allowlisted" else "metadata_only",
        });
    }

    fn executeDownloadResolvedHF(self: *State, operation: IdentifierOperation) void {
        defer self.retireEpoch(operation.epoch);
        if (self.cancelled(operation.epoch)) return self.completeCancelled(operation.completion, 0);
        const identifier = std.mem.trim(u8, operation.identifier, " \t\r\n");
        for (self.candidates.items) |candidate| {
            if (std.mem.eql(u8, candidate.identifier, identifier)) {
                const pin = allowlistedArtifactIdentity(candidate.model) orelse {
                    self.fail(operation.completion, "not_allowlisted", "Friday retained this repository as a metadata candidate only. Its GGUF bytes are not on the production parser allowlist and will not be downloaded or opened.");
                    return;
                };
                var model = trustedModel(self.allocator, pin, true, "hugging_face", pin.key) catch {
                    self.fail(operation.completion, "out_of_memory", "The allowlisted model could not be prepared.");
                    return;
                };
                defer model.deinit(self.allocator);
                self.downloadModel(&model, operation.request_key, operation.epoch, operation.completion);
                return;
            }
        }
        self.fail(operation.completion, "resolution_required", "Resolve and confirm this Hugging Face source first.");
    }

    fn storeCandidate(self: *State, identifier: []const u8, model: Model) !void {
        for (self.candidates.items, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate.identifier, identifier)) {
                const replacement = Candidate{
                    .identifier = try self.allocator.dupe(u8, identifier),
                    .model = try model.clone(self.allocator),
                };
                self.candidates.items[index].deinit(self.allocator);
                self.candidates.items[index] = replacement;
                return;
            }
        }
        const id_copy = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(id_copy);
        var model_copy = try model.clone(self.allocator);
        errdefer model_copy.deinit(self.allocator);
        try self.candidates.append(self.allocator, .{ .identifier = id_copy, .model = model_copy });
    }

    fn cancelled(self: *State, epoch: u64) bool {
        const io = self.threaded_io.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return true;
        return self.cancelled_epochs.contains(epoch);
    }

    fn retireEpoch(self: *State, epoch: u64) void {
        const io = self.threaded_io.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cancelled_epochs.remove(epoch);
    }

    fn completeCancelled(self: *State, completion: AsyncCompletion, resume_bytes: u64) void {
        self.completeValue(completion, false, .{ .ok = false, .cancelled = true, .resumeBytes = resume_bytes, .code = "cancelled" });
    }

    fn fetchMetadata(self: *State, url: []const u8) ![]u8 {
        const buffer = try self.allocator.alloc(u8, max_json_bytes);
        errdefer self.allocator.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        var client = std.http.Client{ .allocator = self.allocator, .io = self.threaded_io.io() };
        defer client.deinit();
        const response = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
        });
        if (response.status == .unauthorized or response.status == .forbidden) return error.AccessDenied;
        if (response.status != .ok or writer.end == 0) return error.MetadataUnavailable;
        return self.allocator.realloc(buffer, writer.end);
    }

    fn downloadModel(self: *State, model: *Model, request_key: u64, epoch: u64, completion: AsyncCompletion) void {
        if (self.cancelled(epoch)) return self.completeCancelled(completion, 0);
        if (allowlistedManifest(model.*) == null or !validDownloadManifest(model.*)) {
            self.fail(completion, "not_allowlisted", "Friday will download and open only immutable artifacts on its reviewed production allowlist.");
            return;
        }
        if (self.download_active) {
            self.fail(completion, "download_active", "A model operation is already active.");
            return;
        }
        if (self.findModel(model.key)) |index| {
            const installed = &self.models.items[index];
            if (installed.managed and sameIdentity(installed.*, model.*) and self.validateManagedModel(installed.*)) {
                const probe = self.probe.probe(self.probe.context, installed.path, request_key);
                if (probeMatchesManifest(installed, probe)) {
                    if (self.cancelled(epoch)) return self.completeCancelled(completion, 0);
                    self.activateSnapshot(installed.*) catch {
                        self.fail(completion, "index_publication_failed", "");
                        return;
                    };
                    self.saveIndex() catch {
                        self.fail(completion, "index_publication_failed", "");
                        return;
                    };
                    self.completeValue(completion, true, .{ .ok = true, .modelKey = installed.key, .probe = .{ .ok = true, .streaming = probe.streaming } });
                    return;
                }
            }
        }

        self.download_active = true;
        self.downloaded_bytes = 0;
        self.total_bytes = model.expected_bytes;
        defer self.download_active = false;

        const operation_root = std.fmt.allocPrint(self.allocator, "{s}/model-{d}", .{ self.downloads_root, model.key }) catch {
            self.fail(completion, "out_of_memory", "The model download could not be prepared.");
            return;
        };
        defer self.allocator.free(operation_root);
        Dir.cwd().createDirPath(self.threaded_io.io(), operation_root) catch {
            self.fail(completion, "install_failed", "The model download folder could not be prepared.");
            return;
        };
        const partial_path = std.fs.path.join(self.allocator, &.{ operation_root, "download.partial" }) catch {
            self.fail(completion, "out_of_memory", "The model download could not be prepared.");
            return;
        };
        defer self.allocator.free(partial_path);
        const resume_path = std.fs.path.join(self.allocator, &.{ operation_root, "resume.json" }) catch {
            self.fail(completion, "out_of_memory", "The model download could not be prepared.");
            return;
        };
        defer self.allocator.free(resume_path);

        var pending_resume = self.loadResumeAt(operation_root, model.*) catch null;
        defer if (pending_resume) |*value| value.deinit(self.allocator);
        var offset: u64 = 0;
        var etag: []const u8 = "";
        var last_modified: []const u8 = "";
        if (pending_resume) |value| {
            offset = value.partial_bytes;
            etag = value.etag;
            last_modified = value.last_modified;
        } else {
            const file = Dir.createFileAbsolute(self.threaded_io.io(), partial_path, .{}) catch {
                self.fail(completion, "install_failed", "The model partial file could not be prepared.");
                return;
            };
            file.close(self.threaded_io.io());
        }
        self.downloaded_bytes = offset;
        self.publishProgress(request_key, "downloading", offset, model.expected_bytes);

        const outcome = self.streamDownload(model.*, request_key, epoch, partial_path, resume_path, offset, etag, last_modified) catch |err| {
            self.publishProgress(request_key, "failed", self.downloaded_bytes, self.total_bytes);
            self.fail(completion, "download_failed", downloadErrorMessage(err));
            return;
        };
        defer {
            self.allocator.free(outcome.etag);
            self.allocator.free(outcome.last_modified);
        }
        if (outcome.cancelled) {
            self.publishProgress(request_key, "cancelled", self.downloaded_bytes, self.total_bytes);
            self.completeCancelled(completion, self.downloaded_bytes);
            return;
        }
        self.publishProgress(request_key, "verifying", self.downloaded_bytes, self.total_bytes);
        self.verifyAndPublish(model, request_key, epoch, completion, operation_root, partial_path, resume_path);
    }

    const DownloadOutcome = struct { cancelled: bool, etag: []u8, last_modified: []u8 };

    fn streamDownload(
        self: *State,
        model: Model,
        request_key: u64,
        epoch: u64,
        partial_path: []const u8,
        resume_path: []const u8,
        requested_offset: u64,
        previous_etag: []const u8,
        previous_last_modified: []const u8,
    ) !DownloadOutcome {
        var range_buffer: [64]u8 = undefined;
        const range = if (requested_offset != 0)
            try std.fmt.bufPrint(&range_buffer, "bytes={d}-", .{requested_offset})
        else
            "";
        const validator = if (previous_etag.len != 0) previous_etag else previous_last_modified;
        var headers_storage: [2]std.http.Header = undefined;
        var header_count: usize = 0;
        if (requested_offset != 0) {
            headers_storage[header_count] = .{ .name = "Range", .value = range };
            header_count += 1;
            headers_storage[header_count] = .{ .name = "If-Range", .value = validator };
            header_count += 1;
        }

        var client = std.http.Client{ .allocator = self.allocator, .io = self.threaded_io.io() };
        defer client.deinit();
        const uri = try std.Uri.parse(model.download_url);
        var request = try client.request(.GET, uri, .{ .extra_headers = headers_storage[0..header_count] });
        defer request.deinit();
        try request.sendBodiless();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);

        const response_etag = headerValue(response.head.bytes, "etag");
        const response_modified = headerValue(response.head.bytes, "last-modified");
        var start_offset = requested_offset;
        if (response.head.status == .ok) {
            start_offset = 0;
        } else if (response.head.status == .partial_content) {
            const content_range = headerValue(response.head.bytes, "content-range");
            if (requested_offset == 0 or !validContentRange(content_range, requested_offset, model.expected_bytes)) return error.InvalidContentRange;
            if (!validatorMatches(previous_etag, previous_last_modified, response_etag, response_modified)) return error.ResumeValidatorChanged;
        } else {
            return error.BadHttpStatus;
        }

        const etag = try self.allocator.dupe(u8, response_etag);
        errdefer self.allocator.free(etag);
        const last_modified = try self.allocator.dupe(u8, response_modified);
        errdefer self.allocator.free(last_modified);
        const has_validator = etag.len != 0 or last_modified.len != 0;

        const partial = try Dir.openFileAbsolute(self.threaded_io.io(), partial_path, .{ .mode = .read_write });
        defer partial.close(self.threaded_io.io());
        if (start_offset == 0) try partial.setLength(self.threaded_io.io(), 0);
        self.downloaded_bytes = start_offset;
        if (has_validator) try self.persistResume(resume_path, model, self.downloaded_bytes, etag, last_modified);
        var last_persisted = self.downloaded_bytes;

        var body = response.reader(&.{});
        var buffer: [256 * 1024]u8 = undefined;
        while (true) {
            if (self.cancelled(epoch)) {
                try partial.sync(self.threaded_io.io());
                if (has_validator) try self.persistResume(resume_path, model, self.downloaded_bytes, etag, last_modified);
                return .{ .cancelled = true, .etag = etag, .last_modified = last_modified };
            }
            const count = body.readSliceShort(&buffer) catch return error.DownloadReadFailed;
            if (count == 0) break;
            if (self.downloaded_bytes + count > model.expected_bytes) return error.DownloadTooLong;
            try partial.writePositionalAll(self.threaded_io.io(), buffer[0..count], self.downloaded_bytes);
            self.downloaded_bytes += count;
            if (has_validator and self.downloaded_bytes - last_persisted >= resume_persist_interval) {
                try partial.sync(self.threaded_io.io());
                try self.persistResume(resume_path, model, self.downloaded_bytes, etag, last_modified);
                last_persisted = self.downloaded_bytes;
            }
            self.publishProgress(request_key, "downloading", self.downloaded_bytes, self.total_bytes);
        }
        try partial.sync(self.threaded_io.io());
        if (has_validator) try self.persistResume(resume_path, model, self.downloaded_bytes, etag, last_modified);
        return .{ .cancelled = false, .etag = etag, .last_modified = last_modified };
    }

    fn persistResume(
        self: *State,
        resume_path: []const u8,
        model: Model,
        partial_bytes: u64,
        etag: []const u8,
        last_modified: []const u8,
    ) !void {
        if (etag.len == 0 and last_modified.len == 0) return error.MissingResumeValidator;
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        var json = std.json.Stringify{ .writer = &writer.writer };
        try json.beginObject();
        try jsonField(&json, "schemaVersion", 2);
        try jsonField(&json, "url", model.download_url);
        try jsonField(&json, "revision", model.revision);
        try jsonField(&json, "artifact", model.artifact);
        try jsonField(&json, "sha256", model.sha256);
        try jsonField(&json, "repository", model.repository);
        try jsonField(&json, "displayName", model.name);
        try jsonField(&json, "expectedBytes", model.expected_bytes);
        try jsonField(&json, "partialBytes", partial_bytes);
        if (etag.len != 0) try jsonField(&json, "etag", etag);
        if (last_modified.len != 0) try jsonField(&json, "lastModified", last_modified);
        try json.objectField("manifest");
        try writeModelJson(&json, model);
        try json.endObject();
        try publication.writeAtomic(self.allocator, self.threaded_io.io(), resume_path, writer.written());
    }

    fn verifyAndPublish(
        self: *State,
        model: *Model,
        request_key: u64,
        epoch: u64,
        completion: AsyncCompletion,
        operation_root: []const u8,
        partial_path: []const u8,
        resume_path: []const u8,
    ) void {
        if (self.cancelled(epoch)) return self.completeCancelled(completion, self.downloaded_bytes);
        if (allowlistedManifest(model.*) == null) {
            self.fail(completion, "not_allowlisted", "Friday refused parser access because the model is not on its production allowlist.");
            return;
        }
        const size = fileSize(self.threaded_io.io(), partial_path) catch 0;
        const digest = hashFileHex(self.threaded_io.io(), partial_path) catch {
            self.fail(completion, "integrity_failed", "The model failed exact size/SHA-256 verification.");
            return;
        };
        if (size != model.expected_bytes or !std.mem.eql(u8, &digest, model.sha256)) {
            self.fail(completion, "integrity_failed", "The model failed exact size/SHA-256 verification.");
            return;
        }
        // No GGUF parser receives bytes until the immutable allowlist identity,
        // exact length, and SHA-256 have all matched.
        if (!validGgufHeader(self.threaded_io.io(), partial_path)) {
            self.fail(completion, "allowlisted_artifact_invalid", "The allowlisted artifact failed its bounded GGUF check.");
            return;
        }

        const nonce = randomU64(self.threaded_io.io());
        const staging = std.fmt.allocPrint(self.allocator, "{s}/.install-{x}", .{ self.models_root, nonce }) catch {
            self.fail(completion, "out_of_memory", "The verified model could not be staged.");
            return;
        };
        defer self.allocator.free(staging);
        Dir.cwd().createDirPath(self.threaded_io.io(), staging) catch {
            self.fail(completion, "install_failed", "The verified model could not be staged.");
            return;
        };
        var staging_owned = true;
        defer if (staging_owned) Dir.cwd().deleteTree(self.threaded_io.io(), staging) catch {};

        const staged_model = std.fs.path.join(self.allocator, &.{ staging, "model.gguf" }) catch {
            self.fail(completion, "out_of_memory", "The verified model could not be staged.");
            return;
        };
        defer self.allocator.free(staged_model);
        Dir.renameAbsolute(partial_path, staged_model, self.threaded_io.io()) catch {
            self.fail(completion, "install_failed", "The verified model could not be staged.");
            return;
        };
        syncFile(self.threaded_io.io(), staged_model) catch {
            self.fail(completion, "install_failed", "The verified model could not be staged durably.");
            return;
        };

        model.installed_bytes = size;
        const initial_manifest = self.modelJsonAlloc(model.*) catch {
            self.fail(completion, "verified_manifest_write_failed", "The model manifest could not be written durably.");
            return;
        };
        defer self.allocator.free(initial_manifest);
        const staged_manifest = std.fs.path.join(self.allocator, &.{ staging, "manifest.json" }) catch {
            self.fail(completion, "out_of_memory", "The model manifest could not be prepared.");
            return;
        };
        defer self.allocator.free(staged_manifest);
        publication.writeAtomic(self.allocator, self.threaded_io.io(), staged_manifest, initial_manifest) catch {
            self.fail(completion, "verified_manifest_write_failed", "The model manifest could not be written durably.");
            return;
        };
        syncDirectory(self.threaded_io.io(), staging) catch {
            self.fail(completion, "publication_fsync_failed", "The model directory publication could not be made durable.");
            return;
        };

        const staged_probe = self.probe.probe(self.probe.context, staged_model, request_key);
        if (!probeMatchesManifest(model, staged_probe)) {
            self.fail(completion, if (staged_probe.code.len != 0) staged_probe.code else "model_probe_failed", if (staged_probe.message.len != 0) staged_probe.message else "The allowlisted model failed its declared runtime capability probe.");
            return;
        }
        if (self.cancelled(epoch)) return self.completeCancelled(completion, self.downloaded_bytes);
        Model.replace(self.allocator, &model.verification, "production_allowlist_exact_integrity_and_runtime_probe") catch unreachable;
        const verified_manifest = self.modelJsonAlloc(model.*) catch {
            self.fail(completion, "verified_manifest_write_failed", "The runtime-verified manifest could not be written durably.");
            return;
        };
        defer self.allocator.free(verified_manifest);
        publication.writeAtomic(self.allocator, self.threaded_io.io(), staged_manifest, verified_manifest) catch {
            self.fail(completion, "verified_manifest_write_failed", "The runtime-verified manifest could not be written durably.");
            return;
        };
        syncDirectory(self.threaded_io.io(), staging) catch {
            self.fail(completion, "publication_fsync_failed", "The model directory publication could not be made durable.");
            return;
        };

        const id_root = std.fs.path.join(self.allocator, &.{ self.models_root, model.id }) catch {
            self.fail(completion, "out_of_memory", "The verified model root could not be prepared.");
            return;
        };
        defer self.allocator.free(id_root);
        Dir.cwd().createDirPath(self.threaded_io.io(), id_root) catch {
            self.fail(completion, "publication_root_failed", "The verified model root could not be created.");
            return;
        };
        syncDirectory(self.threaded_io.io(), std.fs.path.dirname(id_root) orelse self.models_root) catch {
            self.fail(completion, "publication_fsync_failed", "The model directory publication could not be made durable.");
            return;
        };

        var final_directory = std.fs.path.join(self.allocator, &.{ id_root, model.revision }) catch {
            self.fail(completion, "out_of_memory", "The final model directory could not be prepared.");
            return;
        };
        defer self.allocator.free(final_directory);
        var reuse_existing = false;
        if (directoryExists(self.threaded_io.io(), final_directory)) {
            var existing = model.clone(self.allocator) catch {
                self.fail(completion, "out_of_memory", "The final model collision could not be checked.");
                return;
            };
            defer existing.deinit(self.allocator);
            Model.replace(self.allocator, &existing.path, std.fs.path.join(self.allocator, &.{ final_directory, "model.gguf" }) catch {
                self.fail(completion, "out_of_memory", "The final model collision could not be checked.");
                return;
            }) catch unreachable;
            reuse_existing = self.validateManagedModel(existing);
            if (!reuse_existing) {
                self.allocator.free(final_directory);
                final_directory = std.fmt.allocPrint(self.allocator, "{s}/{s}-verified-{x}", .{ id_root, model.revision, randomU64(self.threaded_io.io()) }) catch {
                    self.fail(completion, "out_of_memory", "The collision-safe model directory could not be prepared.");
                    return;
                };
            }
        }
        if (!reuse_existing) {
            Dir.renameAbsolute(staging, final_directory, self.threaded_io.io()) catch {
                staging_owned = false;
                self.fail(completion, "atomic_publication_failed", "The verified staging model could not be atomically published; staging was retained.");
                return;
            };
            staging_owned = false;
        }
        syncDirectory(self.threaded_io.io(), id_root) catch {
            self.fail(completion, "publication_fsync_failed", "The model directory publication could not be made durable.");
            return;
        };
        syncDirectory(self.threaded_io.io(), self.models_root) catch {
            self.fail(completion, "publication_fsync_failed", "The model directory publication could not be made durable.");
            return;
        };

        const final_model = std.fs.path.join(self.allocator, &.{ final_directory, "model.gguf" }) catch {
            self.fail(completion, "out_of_memory", "The published model path could not be prepared.");
            return;
        };
        defer self.allocator.free(final_model);
        Model.replace(self.allocator, &model.path, final_model) catch {
            self.fail(completion, "out_of_memory", "The published model record could not be prepared.");
            return;
        };
        if (!self.validateManagedModel(model.*)) {
            self.fail(completion, "published_model_invalid", "The published final model failed manifest/size/SHA validation.");
            return;
        }
        const final_probe = self.probe.probe(self.probe.context, final_model, request_key);
        if (!probeMatchesManifest(model, final_probe)) {
            self.fail(completion, "published_model_probe_failed", if (final_probe.message.len != 0) final_probe.message else "The published model failed its final runtime probe.");
            return;
        }
        if (self.cancelled(epoch)) return self.completeCancelled(completion, self.downloaded_bytes);
        if (final_probe.streaming != staged_probe.streaming) {
            self.fail(completion, "published_model_capability_changed", "The published model did not reproduce its staged runtime capabilities.");
            return;
        }
        self.upsertAndActivate(model.*) catch {
            self.fail(completion, "index_publication_failed", "The verified model was published, but the durable index update failed.");
            return;
        };
        Dir.cwd().deleteFile(self.threaded_io.io(), resume_path) catch {};
        Dir.cwd().deleteTree(self.threaded_io.io(), operation_root) catch {};
        self.publishProgress(request_key, "installed", size, size);
        const message = std.fmt.allocPrint(self.allocator, "{s} is verified, warm, and active.", .{model.name}) catch "The model is verified, warm, and active.";
        defer if (message.ptr != "The model is verified, warm, and active.".ptr) self.allocator.free(message);
        self.completeValue(completion, true, .{ .ok = true, .modelKey = model.key, .message = message, .probe = .{ .ok = true, .streaming = final_probe.streaming } });
    }

    fn removeModel(self: *State, key: u64, delete_managed: bool, output: []u8) !usize {
        const index = self.findModel(key) orelse return stringifyFixed(output, .{ .ok = false, .code = "not_found" });
        const model = &self.models.items[index];
        if (model.managed and delete_managed) {
            const directory = std.fs.path.dirname(model.path) orelse return stringifyFixed(output, .{ .ok = false, .code = "unsafe_managed_path" });
            const resolved = self.safeManagedDirectory(directory) catch return stringifyFixed(output, .{ .ok = false, .code = "unsafe_managed_path" });
            defer self.allocator.free(resolved);
            Dir.cwd().deleteTree(self.threaded_io.io(), resolved) catch return stringifyFixed(output, .{ .ok = false, .code = "cleanup_failed" });
            if (std.fs.path.dirname(resolved)) |parent| syncDirectory(self.threaded_io.io(), parent) catch return stringifyFixed(output, .{ .ok = false, .code = "cleanup_failed" });
        }
        model.deinit(self.allocator);
        _ = self.models.orderedRemove(index);
        if (self.active_key == key) self.clearActive();
        self.saveIndex() catch return stringifyFixed(output, .{ .ok = false, .code = "index_publication_failed" });
        return stringifyFixed(output, .{ .ok = true });
    }

    fn removeFailedDownloads(self: *State, output: []u8) !usize {
        if (self.download_active) return stringifyFixed(output, .{ .ok = false, .code = "download_active", .message = "Cancel the active download before cleaning partial files." });
        const directory = Dir.openDirAbsolute(self.threaded_io.io(), self.downloads_root, .{ .iterate = true }) catch
            return stringifyFixed(output, .{ .ok = false, .code = "cleanup_failed", .message = "Friday could not inspect partial downloads." });
        var iterator = directory.iterate();
        const removed = (iterator.next(self.threaded_io.io()) catch null) != null;
        directory.close(self.threaded_io.io());
        if (removed) {
            Dir.cwd().deleteTree(self.threaded_io.io(), self.downloads_root) catch
                return stringifyFixed(output, .{ .ok = false, .code = "cleanup_failed", .message = "Friday could not remove partial downloads." });
            Dir.cwd().createDirPath(self.threaded_io.io(), self.downloads_root) catch
                return stringifyFixed(output, .{ .ok = false, .code = "cleanup_failed", .message = "Friday could not prepare the download folder." });
            syncDirectory(self.threaded_io.io(), std.fs.path.dirname(self.downloads_root) orelse "/") catch
                return stringifyFixed(output, .{ .ok = false, .code = "cleanup_failed", .message = "Friday could not prepare the download folder." });
        }
        return if (removed)
            stringifyFixed(output, .{ .ok = true, .removed = true, .message = "Failed and partial downloads removed." })
        else
            stringifyFixed(output, .{ .ok = true, .removed = false, .message = "No failed or partial downloads were present." });
    }

    fn writeStatus(self: *State, output: []u8) !usize {
        var writer = std.Io.Writer.fixed(output);
        var json = std.json.Stringify{ .writer = &writer };
        try json.beginObject();
        try jsonField(&json, "ok", true);
        try jsonField(&json, "activeModelKey", self.active_key);
        try jsonField(&json, "activeModelReady", self.active_key != 0 and self.active_path != null and self.runtime_ready);
        const active = if (self.findModel(self.active_key)) |index| &self.models.items[index] else null;
        try jsonField(&json, "activeModelName", if (active) |model| model.name else "");
        try jsonField(&json, "activeModelSource", if (active) |model| sourceLabel(model.source) else "");
        try jsonField(&json, "activeModelLicense", if (active) |model| model.license else "");
        var text_buffer: [64]u8 = undefined;
        try jsonField(&json, "activeModelLanguages", if (active) |model| languageSummary(&text_buffer, model.languages.len) else "");
        try jsonField(&json, "activeRecognitionMode", if (active) |model| model.recognition_mode else "");
        try jsonField(&json, "activeModelHead", if (active) |model| model.head else "");
        try jsonField(&json, "activeStreamingProfile", if (active) |model| model.streaming_profile else "");
        try jsonField(&json, "activeModelBytes", if (active) |model| model.installed_bytes else 0);
        try jsonField(&json, "activeModelSizeText", if (active) |model| formatByteCount(&text_buffer, model.installed_bytes) else "");
        var managed_bytes: u64 = 0;
        for (self.models.items) |model| if (model.managed) {
            managed_bytes += model.installed_bytes;
        };
        try jsonField(&json, "managedModelSizeText", formatByteCount(&text_buffer, managed_bytes));
        try json.objectField("models");
        try json.beginArray();
        for (self.models.items) |model| {
            try json.beginObject();
            try jsonField(&json, "modelKey", model.key);
            try jsonField(&json, "displayName", model.name);
            try jsonField(&json, "source", model.source);
            try jsonField(&json, "sourceLabel", sourceLabel(model.source));
            try jsonField(&json, "languageSummary", languageSummary(&text_buffer, model.languages.len));
            try jsonField(&json, "sizeText", formatByteCount(&text_buffer, model.installed_bytes));
            try jsonField(&json, "managed", model.managed);
            try jsonField(&json, "installedBytes", model.installed_bytes);
            try jsonField(&json, "license", model.license);
            try json.objectField("languages");
            try json.write(model.languages);
            try jsonField(&json, "compatibility", model.compatibility);
            try jsonField(&json, "recognitionMode", model.recognition_mode);
            try jsonField(&json, "head", model.head);
            try jsonField(&json, "streamingProfile", model.streaming_profile);
            try jsonField(&json, "active", model.key == self.active_key);
            try json.endObject();
        }
        try json.endArray();
        try jsonField(&json, "modelCount", self.models.items.len);
        try jsonField(&json, "managedBytes", managed_bytes);
        try jsonField(&json, "downloadActive", self.download_active);
        try jsonField(&json, "downloadedBytes", self.downloaded_bytes);
        try jsonField(&json, "totalBytes", self.total_bytes);
        var pending = self.findPendingResume() catch null;
        defer if (pending) |*pending_resume| pending_resume.deinit(self.allocator);
        try jsonField(&json, "pendingResumeAvailable", pending != null);
        try jsonField(&json, "pendingDownloadedBytes", if (pending) |pending_resume| pending_resume.partial_bytes else 0);
        try jsonField(&json, "pendingTotalBytes", if (pending) |pending_resume| pending_resume.model.expected_bytes else 0);
        try jsonField(&json, "pendingModelName", if (pending) |pending_resume| pending_resume.model.name else "");
        try json.endObject();
        return writer.end;
    }

    fn loadIndex(self: *State) void {
        const bytes = Dir.cwd().readFileAlloc(self.threaded_io.io(), self.index_path, self.allocator, .limited(max_json_bytes)) catch return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return,
        };
        const models_value = object.get("models") orelse return;
        const records = switch (models_value) {
            .array => |value| value.items,
            else => return,
        };
        for (records[0..@min(records.len, 128)]) |record| {
            var model = self.modelFromJson(record, true) catch continue;
            if (!validInstalledRecord(model)) {
                model.deinit(self.allocator);
                continue;
            }
            self.models.append(self.allocator, model) catch {
                model.deinit(self.allocator);
                break;
            };
        }
        self.active_key = jsonUnsigned(object.get("activeModelKey")) orelse 0;
    }

    fn migratePinnedDefaultIfNeeded(self: *State) !bool {
        if (self.models.items.len != 0) return false;
        const model_path = try std.fs.path.join(self.allocator, &.{
            self.models_root,
            default_pin.id,
            default_pin.revision,
            "model.gguf",
        });
        defer self.allocator.free(model_path);
        const manifest_path = try std.fs.path.join(self.allocator, &.{
            self.models_root,
            default_pin.id,
            default_pin.revision,
            "manifest.json",
        });
        defer self.allocator.free(manifest_path);
        const size = fileSize(self.threaded_io.io(), model_path) catch return false;
        if (size != default_pin.expected_bytes) return false;
        const digest = hashFileHex(self.threaded_io.io(), model_path) catch return false;
        if (!std.mem.eql(u8, &digest, default_pin.sha256)) return false;
        if (!validGgufHeader(self.threaded_io.io(), model_path)) return false;

        var model = try defaultModel(self.allocator);
        var adopted = false;
        defer if (!adopted) model.deinit(self.allocator);
        model.installed_bytes = size;
        try Model.replace(self.allocator, &model.path, model_path);
        try Model.replace(self.allocator, &model.verification, "production_allowlist_exact_integrity_and_runtime_probe");
        const manifest = try self.modelJsonAlloc(model);
        defer self.allocator.free(manifest);
        try publication.writeAtomic(self.allocator, self.threaded_io.io(), manifest_path, manifest);
        try syncDirectory(self.threaded_io.io(), std.fs.path.dirname(manifest_path) orelse self.models_root);

        try self.models.append(self.allocator, model);
        adopted = true;
        self.active_key = default_pin.key;
        try self.restorePendingSnapshot(self.models.items[self.models.items.len - 1]);
        try self.saveIndex();
        return true;
    }

    fn revalidateActiveAtStartup(self: *State) void {
        const index = self.findModel(self.active_key) orelse {
            if (self.active_key != 0) {
                self.clearActive();
                self.saveIndex() catch {};
            }
            return;
        };
        const model = &self.models.items[index];
        const valid = if (model.managed) self.validateManagedModel(model.*) else self.validateLocalModel(model.path);
        if (!valid) {
            self.clearActive();
            self.saveIndex() catch {};
            return;
        }
        self.restorePendingSnapshot(model.*) catch {
            self.clearActive();
            self.saveIndex() catch {};
        };
    }

    fn saveIndex(self: *State) !void {
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        var json = std.json.Stringify{ .writer = &writer.writer };
        try json.beginObject();
        try jsonField(&json, "schemaVersion", 2);
        try jsonField(&json, "activeModelKey", self.active_key);
        try json.objectField("models");
        try json.beginArray();
        for (self.models.items) |model| try writeModelJson(&json, model);
        try json.endArray();
        try json.endObject();
        try publication.writeAtomic(self.allocator, self.threaded_io.io(), self.index_path, writer.written());
    }

    fn modelJsonAlloc(self: *State, model: Model) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        var json = std.json.Stringify{ .writer = &writer.writer };
        try writeModelJson(&json, model);
        return writer.toOwnedSlice();
    }

    fn loadLocalManifest(self: *State, model_path: []const u8) !Model {
        const directory = std.fs.path.dirname(model_path) orelse return error.InvalidManifest;
        const manifest_path = try std.fs.path.join(self.allocator, &.{ directory, "manifest.json" });
        defer self.allocator.free(manifest_path);
        const bytes = try Dir.cwd().readFileAlloc(self.threaded_io.io(), manifest_path, self.allocator, .limited(max_json_bytes));
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        var model = try self.modelFromJson(parsed.value, false);
        errdefer model.deinit(self.allocator);
        if (!std.mem.eql(u8, model.format, "gguf") or !isLowerHex(model.sha256, 64) or
            model.expected_bytes == 0 or model.expected_bytes > max_artifact_bytes)
            return error.InvalidManifest;
        return model;
    }

    fn validateLocalModel(self: *State, path: []const u8) bool {
        var model = self.loadLocalManifest(path) catch return false;
        defer model.deinit(self.allocator);
        const pin = allowlistedManifest(model) orelse return false;
        const size = fileSize(self.threaded_io.io(), path) catch return false;
        const digest = hashFileHex(self.threaded_io.io(), path) catch return false;
        return size == pin.expected_bytes and std.mem.eql(u8, &digest, pin.sha256);
    }

    fn validateManagedModel(self: *State, expected: Model) bool {
        const directory = std.fs.path.dirname(expected.path) orelse return false;
        const manifest_path = std.fs.path.join(self.allocator, &.{ directory, "manifest.json" }) catch return false;
        defer self.allocator.free(manifest_path);
        const bytes = Dir.cwd().readFileAlloc(self.threaded_io.io(), manifest_path, self.allocator, .limited(max_json_bytes)) catch return false;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return false;
        defer parsed.deinit();
        var manifest = self.modelFromJson(parsed.value, true) catch return false;
        defer manifest.deinit(self.allocator);
        const pin = allowlistedManifest(manifest) orelse return false;
        if (!manifest.managed or !std.mem.eql(u8, manifest.compatibility, "compatible") or
            !sameIdentity(manifest, expected)) return false;
        const size = fileSize(self.threaded_io.io(), expected.path) catch return false;
        const digest = hashFileHex(self.threaded_io.io(), expected.path) catch return false;
        return size == pin.expected_bytes and std.mem.eql(u8, &digest, pin.sha256);
    }

    fn safeManagedDirectory(self: *State, directory_path: []const u8) ![]u8 {
        const root_dir = try Dir.openDirAbsolute(self.threaded_io.io(), self.models_root, .{});
        defer root_dir.close(self.threaded_io.io());
        const target_dir = try Dir.openDirAbsolute(self.threaded_io.io(), directory_path, .{});
        defer target_dir.close(self.threaded_io.io());
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root_length = try root_dir.realPath(self.threaded_io.io(), &root_buffer);
        const target_length = try target_dir.realPath(self.threaded_io.io(), &target_buffer);
        const root = root_buffer[0..root_length];
        const target = target_buffer[0..target_length];
        if (target.len <= root.len or !std.mem.eql(u8, target[0..root.len], root) or target[root.len] != std.fs.path.sep) return error.UnsafeManagedPath;
        return self.allocator.dupe(u8, target);
    }

    fn findPendingResume(self: *State) !?Resume {
        const directory = try Dir.openDirAbsolute(self.threaded_io.io(), self.downloads_root, .{ .iterate = true });
        defer directory.close(self.threaded_io.io());
        var iterator = directory.iterate();
        var inspected: usize = 0;
        while (inspected < 32) : (inspected += 1) {
            const entry = (try iterator.next(self.threaded_io.io())) orelse break;
            if (entry.kind != .directory) continue;
            const operation_root = try std.fs.path.join(self.allocator, &.{ self.downloads_root, entry.name });
            if (self.loadResumeAt(operation_root, null)) |pending_resume| return pending_resume else |_| self.allocator.free(operation_root);
        }
        return null;
    }

    fn loadResumeAt(self: *State, operation_root: []const u8, expected: ?Model) !Resume {
        const resume_path = try std.fs.path.join(self.allocator, &.{ operation_root, "resume.json" });
        defer self.allocator.free(resume_path);
        const partial_path = try std.fs.path.join(self.allocator, &.{ operation_root, "download.partial" });
        defer self.allocator.free(partial_path);
        const bytes = try Dir.cwd().readFileAlloc(self.threaded_io.io(), resume_path, self.allocator, .limited(max_json_bytes));
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidResume,
        };
        const manifest_value = root.get("manifest") orelse return error.InvalidResume;
        var model = try self.modelFromJson(manifest_value, false);
        errdefer model.deinit(self.allocator);
        if (allowlistedManifest(model) == null) return error.UntrustedResume;
        const partial_bytes = fileSize(self.threaded_io.io(), partial_path) catch return error.InvalidResume;
        const stored_partial = jsonUnsigned(root.get("partialBytes")) orelse return error.InvalidResume;
        const url = jsonString(root.get("url")) orelse return error.InvalidResume;
        const revision = jsonString(root.get("revision")) orelse return error.InvalidResume;
        const artifact = jsonString(root.get("artifact")) orelse return error.InvalidResume;
        const sha256 = jsonString(root.get("sha256")) orelse return error.InvalidResume;
        const etag_value = jsonString(root.get("etag")) orelse "";
        const modified_value = jsonString(root.get("lastModified")) orelse "";
        if (etag_value.len == 0 and modified_value.len == 0) return error.InvalidResume;
        if (!std.mem.eql(u8, url, model.download_url) or !std.mem.eql(u8, revision, model.revision) or
            !std.mem.eql(u8, artifact, model.artifact) or !std.mem.eql(u8, sha256, model.sha256) or
            !validDownloadManifest(model) or stored_partial != partial_bytes or partial_bytes == 0 or
            partial_bytes >= model.expected_bytes) return error.InvalidResume;
        if (expected) |wanted| if (!sameIdentity(model, wanted)) return error.InvalidResume;
        return .{
            .model = model,
            .partial_bytes = partial_bytes,
            .etag = try self.allocator.dupe(u8, etag_value),
            .last_modified = try self.allocator.dupe(u8, modified_value),
            .operation_root = try self.allocator.dupe(u8, operation_root),
        };
    }

    fn modelFromJson(self: *State, value: std.json.Value, installed_record: bool) !Model {
        const object = switch (value) {
            .object => |entry| entry,
            else => return error.InvalidManifest,
        };
        const languages_value = object.get("languages") orelse return error.InvalidManifest;
        const language_values = switch (languages_value) {
            .array => |array| array.items,
            else => return error.InvalidManifest,
        };
        if (language_values.len > 128) return error.InvalidManifest;
        var language_slices = try self.allocator.alloc([]const u8, language_values.len);
        defer self.allocator.free(language_slices);
        for (language_values, 0..) |language, index| {
            language_slices[index] = switch (language) {
                .string => |string| string,
                else => return error.InvalidManifest,
            };
        }
        const artifact = jsonString(object.get("artifact")) orelse "model.gguf";
        const name = jsonString(object.get("displayName")) orelse artifact;
        const id = jsonString(object.get("id")) orelse "local/model";
        const repository = jsonString(object.get("repository")) orelse id;
        const expected_bytes = jsonUnsigned(object.get("expectedBytes")) orelse return error.InvalidManifest;
        const engine = jsonString(object.get("engine")) orelse return error.InvalidManifest;
        const family = jsonString(object.get("family")) orelse return error.InvalidManifest;
        const legacy_mode = legacyRecognitionMode(family);
        const legacy_head = if (std.mem.eql(u8, family, "parakeet_tdt")) "tdt" else "runtime_verified";
        const spec = ModelSpec{
            .key = jsonUnsigned(object.get("modelKey")) orelse 0,
            .id = id,
            .name = name,
            .repository = repository,
            .revision = jsonString(object.get("revision")) orelse "",
            .artifact = artifact,
            .sha256 = jsonString(object.get("sha256")) orelse return error.InvalidManifest,
            .expected_bytes = expected_bytes,
            .installed_bytes = jsonUnsigned(object.get("installedBytes")) orelse if (installed_record) expected_bytes else 0,
            .download_url = jsonString(object.get("downloadURL")) orelse jsonString(object.get("downloadUrl")) orelse "",
            .engine = engine,
            .family = family,
            .recognition_mode = jsonString(object.get("recognitionMode")) orelse legacy_mode,
            .head = jsonString(object.get("head")) orelse legacy_head,
            .streaming_profile = jsonString(object.get("streamingProfile")) orelse "none",
            .format = jsonString(object.get("format")) orelse return error.InvalidManifest,
            .parser_admission = jsonString(object.get("parserAdmission")) orelse "none",
            .languages = language_slices,
            .license = jsonString(object.get("license")) orelse return error.InvalidManifest,
            .attribution = jsonString(object.get("attribution")) orelse repository,
            .source = jsonString(object.get("source")) orelse "local",
            .managed = jsonBool(object.get("managed")) orelse false,
            .compatibility = jsonString(object.get("compatibility")) orelse "unknown",
            .verification = jsonString(object.get("verification")) orelse "",
            .path = jsonString(object.get("path")) orelse "",
        };
        if (spec.id.len > 256 or spec.name.len > 256 or spec.repository.len > 256 or spec.artifact.len > 256 or
            spec.license.len > 64 or spec.attribution.len > 256 or spec.path.len > std.fs.max_path_bytes or
            !validCapabilities(spec.recognition_mode, spec.head, spec.streaming_profile) or
            spec.expected_bytes == 0 or spec.expected_bytes > max_artifact_bytes) return error.InvalidManifest;
        return Model.init(self.allocator, spec);
    }
};

fn writeModelJson(json: *std.json.Stringify, model: Model) !void {
    try json.beginObject();
    try jsonField(json, "schemaVersion", 2);
    try jsonField(json, "modelKey", model.key);
    try jsonField(json, "id", model.id);
    try jsonField(json, "displayName", model.name);
    try jsonField(json, "repository", model.repository);
    try jsonField(json, "revision", model.revision);
    try jsonField(json, "artifact", model.artifact);
    try jsonField(json, "sha256", model.sha256);
    try jsonField(json, "expectedBytes", model.expected_bytes);
    try jsonField(json, "installedBytes", model.installed_bytes);
    try jsonField(json, "downloadURL", model.download_url);
    try jsonField(json, "provider", "Hugging Face");
    try jsonField(json, "engine", model.engine);
    try jsonField(json, "family", model.family);
    try jsonField(json, "recognitionMode", model.recognition_mode);
    try jsonField(json, "head", model.head);
    try jsonField(json, "streamingProfile", model.streaming_profile);
    try jsonField(json, "format", model.format);
    try jsonField(json, "parserAdmission", model.parser_admission);
    try json.objectField("languages");
    try json.write(model.languages);
    try jsonField(json, "license", model.license);
    try jsonField(json, "attribution", model.attribution);
    try jsonField(json, "source", model.source);
    try jsonField(json, "managed", model.managed);
    try jsonField(json, "compatibility", model.compatibility);
    if (model.verification.len != 0) try jsonField(json, "verification", model.verification);
    if (model.path.len != 0) try jsonField(json, "path", model.path);
    try json.endObject();
}

fn jsonField(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn stringifyFixed(output: []u8, value: anytype) !usize {
    var writer = std.Io.Writer.fixed(output);
    try std.json.Stringify.value(value, .{}, &writer);
    return writer.end;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return switch (actual) {
        .string => |string| string,
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    return switch (actual) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(float) else null,
        else => null,
    };
}

fn sourceLabel(source: []const u8) []const u8 {
    return if (std.mem.eql(u8, source, "local")) "Local file · reference only" else "Hugging Face · managed by Friday";
}

fn languageSummary(buffer: []u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} languages", .{count}) catch "";
}

fn formatByteCount(buffer: []u8, bytes: u64) []const u8 {
    if (bytes < 1000) return std.fmt.bufPrint(buffer, "{d} bytes", .{bytes}) catch "";
    if (bytes < 1_000_000) return std.fmt.bufPrint(buffer, "{d} KB", .{(bytes + 500) / 1000}) catch "";
    if (bytes < 1_000_000_000) return std.fmt.bufPrint(buffer, "{d} MB", .{(bytes + 500_000) / 1_000_000}) catch "";
    return std.fmt.bufPrint(buffer, "{d} GB", .{(bytes + 500_000_000) / 1_000_000_000}) catch "";
}

fn randomU64(io: Io) u64 {
    var value: u64 = undefined;
    io.random(std.mem.asBytes(&value));
    return value;
}

fn validGgufHeader(io: Io, path: []const u8) bool {
    const file = Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    var header: [24]u8 = undefined;
    const count = file.readPositionalAll(io, &header, 0) catch return false;
    if (count != header.len or !std.mem.eql(u8, header[0..4], "GGUF")) return false;
    const version = std.mem.readInt(u32, header[4..8], .little);
    const tensor_count = std.mem.readInt(u64, header[8..16], .little);
    const metadata_count = std.mem.readInt(u64, header[16..24], .little);
    return (version == 2 or version == 3) and tensor_count > 0 and tensor_count <= 1_000_000 and metadata_count > 0 and metadata_count <= 100_000;
}

fn headerValue(head: []const u8, wanted: []const u8) []const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], wanted)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return "";
}

fn validContentRange(value: []const u8, expected_start: u64, expected_total: u64) bool {
    if (!std.mem.startsWith(u8, value, "bytes ")) return false;
    const slash = std.mem.indexOfScalarPos(u8, value, 6, '/') orelse return false;
    const dash = std.mem.indexOfScalarPos(u8, value, 6, '-') orelse return false;
    if (dash >= slash) return false;
    const start = std.fmt.parseInt(u64, value[6..dash], 10) catch return false;
    const end = std.fmt.parseInt(u64, value[dash + 1 .. slash], 10) catch return false;
    const total = std.fmt.parseInt(u64, value[slash + 1 ..], 10) catch return false;
    return start == expected_start and end >= start and end < total and total == expected_total;
}

fn validatorMatches(previous_etag: []const u8, previous_modified: []const u8, etag: []const u8, modified: []const u8) bool {
    if (previous_etag.len != 0) return etag.len != 0 and std.mem.eql(u8, previous_etag, etag);
    if (previous_modified.len != 0) return modified.len != 0 and std.mem.eql(u8, previous_modified, modified);
    return false;
}

fn hfValidationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.PrivateRepository => "That Hugging Face repository is private.",
        error.GatedRepository => "That Hugging Face repository requires gated access.",
        error.MissingRevision => "Hugging Face did not return an immutable revision.",
        error.NotAsr => "The repository does not advertise speech-recognition metadata.",
        error.MissingLicense => "The repository does not provide bounded license metadata.",
        error.NoGguf => "The repository has no top-level GGUF candidate.",
        error.AmbiguousGguf => "The repository has multiple top-level GGUF artifacts; choose an unambiguous source.",
        error.InvalidLfs => "The GGUF artifact is missing a valid LFS SHA-256 or size.",
        else => "The repository is not a safe download candidate.",
    };
}

fn downloadErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidContentRange, error.ResumeValidatorChanged => "The server returned an invalid resume response.",
        else => "The model download failed.",
    };
}

const ProbeCounter = struct {
    count: usize = 0,
    streaming: bool = false,
    fn probe(context: *anyopaque, path: []const u8, generation: u64) ProbeResult {
        _ = generation;
        const self: *ProbeCounter = @ptrCast(@alignCast(context));
        self.count += 1;
        return .{ .ok = std.mem.endsWith(u8, path, ".gguf"), .streaming = self.streaming };
    }
};

const CompletionCounter = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    count: usize = 0,
    done: bool = false,
    ok: bool = false,
    length: usize = 0,
    bytes: [256]u8 = undefined,
    ticket: Ticket = 0,

    fn admit(context: *anyopaque, ticket: Ticket) void {
        const self: *CompletionCounter = @ptrCast(@alignCast(context));
        self.ticket = ticket;
    }

    fn complete(context: *anyopaque, ok: bool, bytes: []const u8) void {
        const self: *CompletionCounter = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        self.count += 1;
        self.ok = ok;
        self.length = @min(bytes.len, self.bytes.len);
        @memcpy(self.bytes[0..self.length], bytes[0..self.length]);
        self.done = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn wait(self: *CompletionCounter) void {
        self.mutex.lockUncancelable(self.io);
        while (!self.done) self.condition.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
    }
};

const BlockingCompletion = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    entered: bool = false,
    released: bool = false,
    count: usize = 0,

    fn complete(context: *anyopaque, _: bool, _: []const u8) void {
        const self: *BlockingCompletion = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        self.count += 1;
        self.entered = true;
        self.condition.signal(self.io);
        while (!self.released) self.condition.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
    }

    fn waitUntilEntered(self: *BlockingCompletion) void {
        self.mutex.lockUncancelable(self.io);
        while (!self.entered) self.condition.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
    }

    fn release(self: *BlockingCompletion) void {
        self.mutex.lockUncancelable(self.io);
        self.released = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }
};

fn cancellationCycleContracts(repository: *ModelRepository) !bool {
    const io = repository.state.threaded_io.io();
    for (0..32) |index| {
        const request_key: u64 = @intCast(700 + index % 3);
        var blocker = BlockingCompletion{ .io = io };
        _ = try repository.submit(
            .{ .select = .{ .key = 999_999, .request_key = request_key } },
            .{ .context = &blocker, .complete = BlockingCompletion.complete },
        );
        blocker.waitUntilEntered();

        var cancelled_completion = CompletionCounter{ .io = io };
        const cancelled_ticket = try repository.submit(
            .{ .select = .{ .key = 999_999, .request_key = request_key } },
            .{ .context = &cancelled_completion, .admit = CompletionCounter.admit, .complete = CompletionCounter.complete },
        );
        repository.cancel(cancelled_ticket);
        blocker.release();
        cancelled_completion.wait();
        if (blocker.count != 1 or cancelled_completion.ticket != cancelled_ticket or cancelled_completion.count != 1 or
            std.mem.indexOf(u8, cancelled_completion.bytes[0..cancelled_completion.length], "\"code\":\"cancelled\"") == null)
            return false;

        var retry_completion = CompletionCounter{ .io = io };
        const retry_ticket = try repository.submit(
            .{ .select = .{ .key = 999_999, .request_key = request_key } },
            .{ .context = &retry_completion, .admit = CompletionCounter.admit, .complete = CompletionCounter.complete },
        );
        retry_completion.wait();
        if (retry_completion.ticket != retry_ticket or retry_ticket == cancelled_ticket or retry_completion.count != 1 or
            std.mem.indexOf(u8, retry_completion.bytes[0..retry_completion.length], "model_unavailable") == null)
            return false;
    }
    return true;
}

/// Deterministic malformed/fuzz regression corpus. These bytes are exercised
/// only through repository admission; the invariant under test is that none
/// reaches `validGgufHeader` or the external NeMo/GGUF parser.
const malformed_model_corpus = [_]struct { name: []const u8, bytes: []const u8 }{
    .{ .name = "empty", .bytes = "" },
    .{ .name = "magic-only", .bytes = "GGUF" },
    .{ .name = "truncated-valid-looking-header", .bytes = "GGUF\x03\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00" },
    .{ .name = "oversized-counts", .bytes = "GGUF\x03\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" },
    .{ .name = "html-response", .bytes = "<!doctype html><title>not a model</title>" },
};

fn metadataRejected(state: *State, bytes: []const u8) bool {
    var candidate = source_mod.parse(state.allocator, bytes, "fixture/model") catch return true;
    candidate.deinit(state.allocator);
    return false;
}

fn runContractProbes() !struct {
    ok: bool,
    resumeOffset: u64,
    malformedRejectedBeforeParser: bool,
    malformedCorpusCases: usize,
    shaFailed: bool,
    sidecarRequired: bool,
    managedDeleteBounded: bool,
    missingActiveReset: bool,
    finalCollisionCorruptionRejected: bool,
    cleanupTruthful: bool,
    hfCandidateFixture: bool,
    hfCandidateUnverified: bool,
    hfMaliciousCandidateUnverified: bool,
    hfMaliciousPublicationRejected: bool,
    hfMetadataOnly: bool,
    hfDownloadBlockedBeforeParser: bool,
    hfPrivateRejected: bool,
    hfAmbiguousRejected: bool,
    hfNoHashRejected: bool,
    hfIncompatibleRejected: bool,
    hfIdentifierValidation: bool,
    pendingResumeHydrated: bool,
    contentRangeExact: bool,
    resumeIdentityBound: bool,
    completionExactlyOnce: bool,
    serializedMutationOwner: bool,
    cancellationCycles: bool,
} {
    const allocator = std.heap.page_allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const root = try std.fmt.allocPrint(allocator, "/tmp/FridayModelProbe-{x}", .{randomU64(io)});
    defer allocator.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    const data_root = try std.fs.path.join(allocator, &.{ root, "AppData" });
    defer allocator.free(data_root);
    try Dir.cwd().createDirPath(io, data_root);

    const partial = try std.fs.path.join(allocator, &.{ root, "download.partial" });
    defer allocator.free(partial);
    const partial_file = try Dir.createFileAbsolute(io, partial, .{});
    try partial_file.writeStreamingAll(io, &([_]u8{0} ** 4096));
    try partial_file.sync(io);
    partial_file.close(io);
    const resume_offset = try fileSize(io, partial);

    const bad = try std.fs.path.join(allocator, &.{ root, "bad.gguf" });
    defer allocator.free(bad);
    try Dir.cwd().writeFile(io, .{ .sub_path = bad, .data = "NOPE" });
    const bad_digest = try hashFileHex(io, bad);
    const sha_failed = !std.mem.eql(u8, &bad_digest, default_pin.sha256);

    var probe_counter = ProbeCounter{};
    var repository = try ModelRepository.init(allocator, data_root, .{ .context = &probe_counter, .probe = ProbeCounter.probe }, null);
    defer repository.deinit();
    var status_buffer: [16 * 1024]u8 = undefined;
    const initial_status_length = try repository.writeStatus(&status_buffer);
    const missing_active_reset = std.mem.indexOf(u8, status_buffer[0..initial_status_length], "\"activeModelKey\":0") != null;

    const empty_cleanup_length = try repository.removeFailed(&status_buffer);
    const empty_cleanup = std.mem.indexOf(u8, status_buffer[0..empty_cleanup_length], "\"removed\":false") != null;
    const marker = try std.fs.path.join(allocator, &.{ data_root, "ModelDownloads", "partial" });
    defer allocator.free(marker);
    try Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "partial" });
    const removed_cleanup_length = try repository.removeFailed(&status_buffer);
    const removed_cleanup = std.mem.indexOf(u8, status_buffer[0..removed_cleanup_length], "\"removed\":true") != null;

    const content_range_exact = validContentRange("bytes 4096-8191/713975456", 4096, 713_975_456) and
        !validContentRange("bytes 4095-8191/713975456", 4096, 713_975_456) and
        !validContentRange("bytes 4096-8191/713975455", 4096, 713_975_456);
    const resume_identity_bound = validatorMatches("etag-a", "", "etag-a", "") and
        !validatorMatches("etag-a", "", "etag-b", "") and
        validatorMatches("", "date-a", "", "date-a");
    const identifier_validation = safeHuggingFaceIdentifier("community/parakeet-tdt-gguf") and
        !safeHuggingFaceIdentifier("https://example.com/model") and !safeHuggingFaceIdentifier("../escape");

    const sidecar_required = sidecar: {
        var loaded = repository.state.loadLocalManifest(bad) catch break :sidecar true;
        loaded.deinit(allocator);
        break :sidecar false;
    };

    // A forged sidecar can copy every public allowlist field, so the corpus
    // reaches exact-byte verification. Its malformed bytes must still be
    // rejected before either the GGUF reader or NeMo probe is called.
    const corpus_root = try std.fs.path.join(allocator, &.{ root, "MalformedCorpus" });
    defer allocator.free(corpus_root);
    try Dir.cwd().createDirPath(io, corpus_root);
    var forged = try defaultModel(allocator);
    defer forged.deinit(allocator);
    const forged_manifest = try repository.state.modelJsonAlloc(forged);
    defer allocator.free(forged_manifest);
    var corpus_rejected = true;
    for (malformed_model_corpus, 0..) |entry, index| {
        const case_root = try std.fs.path.join(allocator, &.{ corpus_root, entry.name });
        defer allocator.free(case_root);
        try Dir.cwd().createDirPath(io, case_root);
        const corpus_model = try std.fs.path.join(allocator, &.{ case_root, "model.gguf" });
        defer allocator.free(corpus_model);
        try Dir.cwd().writeFile(io, .{ .sub_path = corpus_model, .data = entry.bytes });
        const corpus_manifest = try std.fs.path.join(allocator, &.{ case_root, "manifest.json" });
        defer allocator.free(corpus_manifest);
        try Dir.cwd().writeFile(io, .{ .sub_path = corpus_manifest, .data = forged_manifest });
        var corpus_completion = CompletionCounter{ .io = repository.state.threaded_io.io() };
        const key = 9001 + index;
        _ = try repository.submit(.{ .add_local = .{ .path = corpus_model, .key = key, .request_key = key } }, .{ .context = &corpus_completion, .complete = CompletionCounter.complete });
        corpus_completion.wait();
        corpus_rejected = corpus_rejected and repository.state.findModel(key) == null;
    }
    const malformed_rejected_before_parser = probe_counter.count == 0 and corpus_rejected;

    const outside = try std.fs.path.join(allocator, &.{ root, "Outside" });
    defer allocator.free(outside);
    try Dir.cwd().createDirPath(io, outside);
    const managed_delete_bounded = bounded: {
        const resolved = repository.state.safeManagedDirectory(outside) catch break :bounded true;
        allocator.free(resolved);
        break :bounded false;
    };

    var invalid_managed = try defaultModel(allocator);
    defer invalid_managed.deinit(allocator);
    try Model.replace(allocator, &invalid_managed.path, bad);
    invalid_managed.installed_bytes = invalid_managed.expected_bytes;
    const final_collision_rejected = !repository.state.validateManagedModel(invalid_managed);

    const valid_metadata = "{\"private\":false,\"gated\":false,\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"pipeline_tag\":\"automatic-speech-recognition\",\"tags\":[\"license:apache-2.0\"],\"cardData\":{\"license\":\"apache-2.0\",\"language\":[\"en\"]},\"author\":\"fixture\",\"modelId\":\"fixture/model\",\"siblings\":[{\"rfilename\":\"model.gguf\",\"lfs\":{\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":1048576}}]}";
    var candidate = try source_mod.parse(allocator, valid_metadata, "fixture/model");
    defer candidate.deinit(allocator);
    const hf_candidate_fixture = candidate.expected_bytes == 1_048_576 and std.mem.eql(u8, candidate.artifact, "model.gguf");
    const hf_candidate_unverified = std.mem.eql(u8, candidate.engine, "unverified") and
        std.mem.eql(u8, candidate.family, "unverified") and std.mem.eql(u8, candidate.compatibility, "unverified_candidate");
    const hf_metadata_only = allowlistedArtifactIdentity(candidate) == null and probe_counter.count == 0 and !validInstalledRecord(candidate);
    try repository.state.storeCandidate("fixture/model", candidate);
    var hf_completion = CompletionCounter{ .io = repository.state.threaded_io.io() };
    _ = try repository.submit(.{ .download_resolved_hf = .{ .identifier = "fixture/model", .request_key = 9002 } }, .{ .context = &hf_completion, .complete = CompletionCounter.complete });
    hf_completion.wait();
    const hf_download_blocked_before_parser = probe_counter.count == 0 and repository.state.findModel(candidate.key) == null;

    const malicious_metadata = try std.mem.replaceOwned(u8, allocator, valid_metadata, "model.gguf", "../model.gguf");
    defer allocator.free(malicious_metadata);
    const malicious_rejected = metadataRejected(repository.state, malicious_metadata);
    const private_metadata = try std.mem.replaceOwned(u8, allocator, valid_metadata, "\"private\":false", "\"private\":true");
    defer allocator.free(private_metadata);
    const private_rejected = metadataRejected(repository.state, private_metadata);
    const no_hash_metadata = try std.mem.replaceOwned(u8, allocator, valid_metadata, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "missing");
    defer allocator.free(no_hash_metadata);
    const no_hash_rejected = metadataRejected(repository.state, no_hash_metadata);
    const incompatible_metadata = try std.mem.replaceOwned(u8, allocator, valid_metadata, "automatic-speech-recognition", "text-classification");
    defer allocator.free(incompatible_metadata);
    const incompatible_rejected = metadataRejected(repository.state, incompatible_metadata);
    const ambiguous_metadata = "{\"private\":false,\"gated\":false,\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"pipeline_tag\":\"automatic-speech-recognition\",\"tags\":[\"license:apache-2.0\"],\"cardData\":{\"license\":\"apache-2.0\",\"language\":[\"en\"]},\"siblings\":[{\"rfilename\":\"one.gguf\",\"lfs\":{\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":1048576}},{\"rfilename\":\"two.gguf\",\"lfs\":{\"sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"size\":1048576}}]}";
    const ambiguous_rejected = metadataRejected(repository.state, ambiguous_metadata);

    var pinned = try defaultModel(allocator);
    defer pinned.deinit(allocator);
    const operation_root = try std.fs.path.join(allocator, &.{ data_root, "ModelDownloads", "model-1" });
    defer allocator.free(operation_root);
    try Dir.cwd().createDirPath(io, operation_root);
    const resume_partial = try std.fs.path.join(allocator, &.{ operation_root, "download.partial" });
    defer allocator.free(resume_partial);
    try Dir.cwd().writeFile(io, .{ .sub_path = resume_partial, .data = &([_]u8{0} ** 4096) });
    const resume_path = try std.fs.path.join(allocator, &.{ operation_root, "resume.json" });
    defer allocator.free(resume_path);
    try repository.state.persistResume(resume_path, pinned, 4096, "probe-etag", "");
    var hydrated = try repository.state.loadResumeAt(operation_root, pinned);
    defer hydrated.deinit(allocator);
    const pending_resume_hydrated = hydrated.partial_bytes == 4096 and std.mem.eql(u8, hydrated.etag, "probe-etag");

    var completion_counter = CompletionCounter{ .io = repository.state.threaded_io.io() };
    _ = try repository.submit(.{ .resolve_hf = .{ .identifier = "../escape", .request_key = 991 } }, .{ .context = &completion_counter, .complete = CompletionCounter.complete });
    completion_counter.wait();
    const completion_exactly_once = completion_counter.count == 1;
    const serialized_mutation_owner = repository.state.thread != null and completion_exactly_once;
    const cancellation_cycles = try cancellationCycleContracts(&repository);

    const cleanup_truthful = empty_cleanup and removed_cleanup;
    const probes_ok = resume_offset == 4096 and malformed_rejected_before_parser and sha_failed and sidecar_required and
        managed_delete_bounded and missing_active_reset and final_collision_rejected and cleanup_truthful and
        hf_candidate_fixture and hf_candidate_unverified and malicious_rejected and hf_metadata_only and
        hf_download_blocked_before_parser and private_rejected and ambiguous_rejected and no_hash_rejected and
        incompatible_rejected and identifier_validation and pending_resume_hydrated and content_range_exact and
        resume_identity_bound and completion_exactly_once and serialized_mutation_owner and cancellation_cycles;
    return .{
        .ok = probes_ok,
        .resumeOffset = resume_offset,
        .malformedRejectedBeforeParser = malformed_rejected_before_parser,
        .malformedCorpusCases = malformed_model_corpus.len,
        .shaFailed = sha_failed,
        .sidecarRequired = sidecar_required,
        .managedDeleteBounded = managed_delete_bounded,
        .missingActiveReset = missing_active_reset,
        .finalCollisionCorruptionRejected = final_collision_rejected,
        .cleanupTruthful = cleanup_truthful,
        .hfCandidateFixture = hf_candidate_fixture,
        .hfCandidateUnverified = hf_candidate_unverified,
        .hfMaliciousCandidateUnverified = malicious_rejected,
        .hfMaliciousPublicationRejected = malicious_rejected and !validInstalledRecord(candidate),
        .hfMetadataOnly = hf_metadata_only,
        .hfDownloadBlockedBeforeParser = hf_download_blocked_before_parser,
        .hfPrivateRejected = private_rejected,
        .hfAmbiguousRejected = ambiguous_rejected,
        .hfNoHashRejected = no_hash_rejected,
        .hfIncompatibleRejected = incompatible_rejected,
        .hfIdentifierValidation = identifier_validation,
        .pendingResumeHydrated = pending_resume_hydrated,
        .contentRangeExact = content_range_exact,
        .resumeIdentityBound = resume_identity_bound,
        .completionExactlyOnce = completion_exactly_once,
        .serializedMutationOwner = serialized_mutation_owner,
        .cancellationCycles = cancellation_cycles,
    };
}

test "runtime probe must agree with allowlisted capabilities" {
    const allocator = std.testing.allocator;
    var model = try defaultModel(allocator);
    defer model.deinit(allocator);

    try std.testing.expect(probeMatchesManifest(&model, .{ .ok = true, .streaming = false }));
    try std.testing.expect(!probeMatchesManifest(&model, .{ .ok = true, .streaming = true }));
    try std.testing.expect(!probeMatchesManifest(&model, .{ .ok = false, .streaming = false }));
    try std.testing.expect(allowlistedManifest(model) != null);
}

test "metadata candidates cannot extend the production parser allowlist" {
    const allocator = std.testing.allocator;
    var candidate = try Model.init(allocator, .{
        .key = 99,
        .id = "community/model",
        .name = "Untrusted",
        .repository = "community/model",
        .revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .artifact = "model.gguf",
        .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .expected_bytes = 1_048_576,
        .installed_bytes = 0,
        .download_url = "https://huggingface.co/community/model/resolve/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/model.gguf",
        .engine = "unverified",
        .family = "unverified",
        .recognition_mode = "unverified",
        .head = "runtime_verified",
        .streaming_profile = "none",
        .format = "gguf",
        .parser_admission = "metadata_only",
        .languages = &.{"en"},
        .license = "apache-2.0",
        .attribution = "community",
        .source = "hugging_face",
        .managed = true,
        .compatibility = "unverified_candidate",
        .verification = "",
        .path = "",
    });
    defer candidate.deinit(allocator);

    try std.testing.expect(allowlistedArtifactIdentity(candidate) == null);
    try std.testing.expect(allowlistedManifest(candidate) == null);
    try std.testing.expect(!validDownloadManifest(candidate));
    try std.testing.expect(!validInstalledRecord(candidate));
}

test "malformed model corpus and metadata candidates stop before parser probes" {
    const probes = try runContractProbes();
    try std.testing.expect(probes.ok);
    try std.testing.expectEqual(malformed_model_corpus.len, probes.malformedCorpusCases);
    try std.testing.expect(probes.malformedRejectedBeforeParser);
    try std.testing.expect(probes.hfMetadataOnly);
    try std.testing.expect(probes.hfDownloadBlockedBeforeParser);
}

test "capability vocabulary rejects contradictory manifests" {
    try std.testing.expectEqualStrings("offline", legacyRecognitionMode("parakeet_tdt"));
    try std.testing.expectEqualStrings("offline", legacyRecognitionMode("runtime_verified_asr"));
    try std.testing.expectEqualStrings("unverified", legacyRecognitionMode("unverified"));
    try std.testing.expect(validCapabilities("offline", "tdt", "none"));
    try std.testing.expect(validCapabilities("streaming", "rnnt", "rnnt_low_latency"));
    try std.testing.expect(validCapabilities("streaming", "runtime_verified", "runtime_verified"));
    try std.testing.expect(!validCapabilities("streaming", "tdt", "none"));
    try std.testing.expect(!validCapabilities("offline", "tdt", "runtime_verified"));
    try std.testing.expect(!validCapabilities("claimed", "tdt", "none"));
}

test "model cancellation epochs retire without poisoning retries" {
    var cancelled: CancelledEpochs = .{};
    var next_epoch: u64 = 1;
    for (0..10_000) |_| {
        const cancelled_epoch = next_epoch;
        next_epoch += 1;
        try std.testing.expect(cancelled.insert(cancelled_epoch));
        try std.testing.expect(cancelled.contains(cancelled_epoch));

        cancelled.remove(cancelled_epoch);
        try std.testing.expect(!cancelled.contains(cancelled_epoch));
        try std.testing.expect(!cancelled.contains(next_epoch));
    }

    for (1..129) |value| try std.testing.expect(cancelled.insert(@intCast(value)));
    try std.testing.expect(!cancelled.insert(129));
    for (1..129) |value| cancelled.remove(@intCast(value));
    try std.testing.expect(cancelled.insert(129));
}
