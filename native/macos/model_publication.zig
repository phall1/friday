const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// Publishes repository metadata only after file fsync, atomic rename, and
/// parent-directory fsync. Installer and index code share this durability
/// boundary instead of reproducing an incomplete sequence.
pub fn writeAtomic(allocator: Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, randomU64(io) });
    defer allocator.free(temporary);
    var published = false;
    defer if (!published) Dir.cwd().deleteFile(io, temporary) catch {};
    const file = try Dir.createFileAbsolute(io, temporary, .{ .exclusive = true });
    errdefer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    file.close(io);
    try Dir.renameAbsolute(temporary, path, io);
    published = true;
    try syncDirectory(io, std.fs.path.dirname(path) orelse "/");
}

pub fn fileSize(io: Io, path: []const u8) !u64 {
    const file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    return (try file.stat(io)).size;
}

pub fn directoryExists(io: Io, path: []const u8) bool {
    const directory = Dir.openDirAbsolute(io, path, .{}) catch return false;
    directory.close(io);
    return true;
}

pub fn syncFile(io: Io, path: []const u8) !void {
    const file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.sync(io);
}

pub fn syncDirectory(io: Io, path: []const u8) !void {
    const directory = try Dir.openDirAbsolute(io, path, .{});
    defer directory.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_length = try directory.realPath(io, &buffer);
    const file = try Dir.openFileAbsolute(io, buffer[0..resolved_length], .{});
    defer file.close(io);
    try file.sync(io);
}

pub fn hashFileHex(io: Io, path: []const u8) ![64]u8 {
    const file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    var buffer: [1024 * 1024]u8 = undefined;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var result: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x}", .{digest}) catch unreachable;
    return result;
}

fn randomU64(io: Io) u64 {
    var value: u64 = undefined;
    io.random(std.mem.asBytes(&value));
    return value;
}

pub fn testContracts() !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "/tmp/friday-model-publication-contract";
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    const path = root ++ "/index.json";

    try writeAtomic(std.testing.allocator, io, path, "first");
    try std.testing.expectEqual(@as(u64, 5), try fileSize(io, path));
    try writeAtomic(std.testing.allocator, io, path, "replacement");
    const bytes = try Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("replacement", bytes);
    try std.testing.expectEqualStrings("95713e9cbdd1dfcb2d4080c2537f418d43ca0da25f0d7d6631f4f7c97b89dc47", &(try hashFileHex(io, path)));
}

test "atomic model publication replaces durable bytes" {
    try testContracts();
}
