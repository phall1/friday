const std = @import("std");
const c = @import("audio_ffi.zig").api;

pub const sample_rate: u64 = 16_000;
pub const warning_frames: u64 = sample_rate * 585;
pub const maximum_frames: u64 = sample_rate * 600;
pub const maximum_storage_bytes: u64 = maximum_frames * @sizeOf(f32);
const path_capacity = 4096;

/// Owns the canonical 16 kHz mono Float32 file and its retry lifetime. Paths
/// are borrowed only for immediate recognizer submission; deletion policy
/// never leaves this module.
pub const Store = struct {
    allocator: std.mem.Allocator,
    audio_dir: [:0]u8,
    fd: c_int = -1,
    current_path: [path_capacity]u8 = @splat(0),
    current_path_len: usize = 0,
    retry_path: ?[:0]u8 = null,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !Store {
        const joined = try std.fs.path.join(allocator, &.{ data_dir, "Audio" });
        defer allocator.free(joined);
        if (joined.len + 1 > path_capacity) return error.NameTooLong;
        const directory = try allocator.dupeZ(u8, joined);
        errdefer allocator.free(directory);
        try ensureDirectory(data_dir);
        try ensureDirectory(directory);
        sweep(directory);
        return .{ .allocator = allocator, .audio_dir = directory };
    }

    pub fn deinit(self: *Store) void {
        self.failCurrent();
        self.discardRetry();
        self.allocator.free(self.audio_dir);
        self.* = undefined;
    }

    pub fn begin(self: *Store, session_id: u64) !void {
        self.failCurrent();
        self.discardRetry();
        const path = try std.fmt.bufPrint(self.current_path[0 .. self.current_path.len - 1], "{s}/session-{d}.f32", .{ self.audio_dir, session_id });
        self.current_path_len = path.len;
        self.current_path[path.len] = 0;
        self.fd = c.open(@ptrCast(&self.current_path), c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
        if (self.fd < 0) {
            self.removeCurrent();
            return error.TemporaryStorageUnavailable;
        }
    }

    pub fn write(self: *Store, samples: []const f32) !void {
        if (self.fd < 0) return error.TemporaryStorageUnavailable;
        try writeAll(self.fd, std.mem.sliceAsBytes(samples));
    }

    /// Flushes and closes the authoritative capture, retaining it as the sole
    /// retry artifact. The returned path is borrowed until begin/discard/deinit.
    pub fn sealRetry(self: *Store) ![]const u8 {
        if (self.fd < 0 or self.current_path_len == 0) return error.TemporaryStorageUnavailable;
        if (c.fsync(self.fd) != 0) return error.TemporaryStorageUnavailable;
        self.closeFile();
        self.retry_path = try self.allocator.dupeZ(u8, self.currentPath());
        return self.retry_path.?[0..self.retry_path.?.len];
    }

    pub fn failCurrent(self: *Store) void {
        self.closeFile();
        self.removeCurrent();
    }

    pub fn discardRetry(self: *Store) void {
        if (self.retry_path) |path| {
            _ = c.unlink(path.ptr);
            self.allocator.free(path);
            self.retry_path = null;
        }
    }

    pub fn retryPath(self: *const Store) ?[]const u8 {
        return if (self.retry_path) |path| path[0..path.len] else null;
    }

    pub fn retryAvailable(self: *const Store) bool {
        return self.retry_path != null;
    }

    pub fn probeMaximumStorage(self: *Store) !i64 {
        var path: [path_capacity]u8 = @splat(0);
        const visible = try std.fmt.bufPrint(path[0 .. path.len - 1], "{s}/friday-10-minute-probe.f32", .{self.audio_dir});
        path[visible.len] = 0;
        const fd = c.open(@ptrCast(&path), c.O_CREAT | c.O_TRUNC | c.O_RDWR | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
        if (fd < 0) return error.TemporaryStorageUnavailable;
        defer {
            _ = c.close(fd);
            _ = c.unlink(@ptrCast(&path));
        }
        const expected: c.off_t = @intCast(maximum_storage_bytes);
        if (c.ftruncate(fd, expected) != 0) return error.TemporaryStorageUnavailable;
        var stat = std.mem.zeroes(c.struct_stat);
        if (c.fstat(fd, &stat) != 0) return error.TemporaryStorageUnavailable;
        return @intCast(stat.st_size);
    }

    pub fn cleanupProbe(self: *Store, name: []const u8) !bool {
        var path: [path_capacity]u8 = @splat(0);
        const visible = try std.fmt.bufPrint(path[0 .. path.len - 1], "{s}/{s}", .{ self.audio_dir, name });
        path[visible.len] = 0;
        const fd = c.open(@ptrCast(&path), c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | noFollow(), @as(c_uint, 0o600));
        if (fd < 0) return error.TemporaryStorageUnavailable;
        _ = c.close(fd);
        _ = c.unlink(@ptrCast(&path));
        return c.access(@ptrCast(&path), c.F_OK) != 0;
    }

    fn closeFile(self: *Store) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    fn removeCurrent(self: *Store) void {
        if (self.current_path_len != 0) {
            _ = c.unlink(@ptrCast(&self.current_path));
            self.current_path_len = 0;
            self.current_path[0] = 0;
        }
    }

    fn currentPath(self: *const Store) []const u8 {
        return self.current_path[0..self.current_path_len];
    }
};

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const wrote = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (wrote < 0 and c.__error().* == c.EINTR) continue;
        if (wrote <= 0) return error.WriteFailed;
        offset += @intCast(wrote);
    }
}

fn ensureDirectory(path: []const u8) !void {
    var buffer: [path_capacity]u8 = @splat(0);
    if (path.len + 1 > buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    if (c.mkdir(@ptrCast(&buffer), @as(c_uint, 0o700)) != 0 and c.__error().* != c.EEXIST) return error.DirectoryUnavailable;
}

fn sweep(directory: [:0]const u8) void {
    const dir = c.opendir(directory.ptr) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (!std.mem.startsWith(u8, name, "session-") or !std.mem.endsWith(u8, name, ".f32")) continue;
        var path: [path_capacity]u8 = @splat(0);
        const visible = std.fmt.bufPrint(path[0 .. path.len - 1], "{s}/{s}", .{ directory, name }) catch continue;
        path[visible.len] = 0;
        _ = c.unlink(@ptrCast(&path));
    }
}

fn noFollow() c_int {
    return if (@hasDecl(c, "O_NOFOLLOW")) c.O_NOFOLLOW else 0;
}

pub fn testContracts() !void {
    const root: [:0]const u8 = "/tmp/friday-canonical-store-contract";
    _ = c.mkdir(root.ptr, @as(c_uint, 0o700));
    defer {
        _ = c.rmdir("/tmp/friday-canonical-store-contract/Audio");
        _ = c.rmdir(root.ptr);
    }
    var store = try Store.init(std.testing.allocator, root);
    defer store.deinit();

    try store.begin(1);
    try store.write(&.{ 0.25, -0.25, 0.5 });
    const retry = try store.sealRetry();
    try std.testing.expect(retry.len > 0);
    try std.testing.expect(store.retryAvailable());
    try store.begin(2);
    try std.testing.expect(!store.retryAvailable());
    store.failCurrent();
    try std.testing.expect(try store.cleanupProbe("failure.f32"));
}

test "canonical store owns retry and failure cleanup" {
    try testContracts();
}
