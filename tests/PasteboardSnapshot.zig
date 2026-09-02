const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("CoreFoundation/CFArray.h");
    @cInclude("CoreFoundation/CFData.h");
    @cInclude("CoreFoundation/CFString.h");
    @cDefine("__COREFOUNDATION__", "1");
    @cDefine("CFURLRef", "void *");
    @cInclude("HIServices/Pasteboard.h");
});

comptime {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos)
        @compileError("PasteboardSnapshot must target arm64 macOS");
}

const magic = "FRIDAYPB\x01";
const max_snapshot_bytes = 1024 * 1024 * 1024;

fn release(value: anytype) void {
    c.CFRelease(@ptrCast(value));
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(2);
}

fn check(status: c.OSStatus) !void {
    if (status != 0) return error.PasteboardOperationFailed;
}

fn generalPasteboard() !c.PasteboardRef {
    const name = c.CFStringCreateWithCString(null, "com.apple.pasteboard.clipboard", c.kCFStringEncodingUTF8) orelse
        return error.CouldNotCreatePasteboardName;
    defer release(name);

    var pasteboard: c.PasteboardRef = undefined;
    try check(c.PasteboardCreate(name, &pasteboard));
    return pasteboard;
}

const Utf8String = struct {
    allocation: []u8,
    bytes: []const u8,
};

fn utf8String(allocator: std.mem.Allocator, value: c.CFStringRef) !Utf8String {
    const length = c.CFStringGetLength(value);
    const capacity = c.CFStringGetMaximumSizeForEncoding(length, c.kCFStringEncodingUTF8) + 1;
    if (capacity <= 0) return error.InvalidPasteboardType;
    const buffer = try allocator.alloc(u8, @intCast(capacity));
    errdefer allocator.free(buffer);
    if (c.CFStringGetCString(value, buffer.ptr, capacity, c.kCFStringEncodingUTF8) == 0)
        return error.InvalidPasteboardType;
    return .{
        .allocation = buffer,
        .bytes = buffer[0..std.mem.indexOfScalar(u8, buffer, 0).?],
    };
}

fn copyFlavorData(pasteboard: c.PasteboardRef, item: c.PasteboardItemID, flavor: c.CFStringRef) ?c.CFDataRef {
    var data: c.CFDataRef = undefined;
    if (c.PasteboardCopyItemFlavorData(pasteboard, item, flavor, &data) != 0) return null;
    return data;
}

fn save(init: std.process.Init, pasteboard: c.PasteboardRef, path: []const u8) !void {
    _ = c.PasteboardSynchronize(pasteboard);

    var item_count: c.ItemCount = 0;
    try check(c.PasteboardGetItemCount(pasteboard, &item_count));

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(init.io, path, .{ .replace = true });
    defer atomic_file.deinit(init.io);
    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = atomic_file.file.writer(init.io, &buffer);
    const writer = &file_writer.interface;

    try writer.writeAll(magic);
    try writer.writeInt(u32, @intCast(item_count), .little);

    var item_index: c.ItemCount = 1;
    while (item_index <= item_count) : (item_index += 1) {
        var item: c.PasteboardItemID = undefined;
        try check(c.PasteboardGetItemIdentifier(pasteboard, @intCast(item_index), &item));

        var flavors: c.CFArrayRef = undefined;
        try check(c.PasteboardCopyItemFlavors(pasteboard, item, &flavors));
        defer release(flavors);

        const flavor_count = c.CFArrayGetCount(flavors);
        if (flavor_count < 0) return error.InvalidPasteboardData;
        const saved_data = try init.gpa.alloc(?c.CFDataRef, @intCast(flavor_count));
        @memset(saved_data, null);
        defer {
            for (saved_data) |data| {
                if (data) |value| release(value);
            }
            init.gpa.free(saved_data);
        }

        var saved_flavor_count: u32 = 0;
        var flavor_index: c.CFIndex = 0;
        while (flavor_index < flavor_count) : (flavor_index += 1) {
            const flavor: c.CFStringRef = @ptrCast(c.CFArrayGetValueAtIndex(flavors, flavor_index).?);
            if (copyFlavorData(pasteboard, item, flavor)) |data| {
                saved_data[@intCast(flavor_index)] = data;
                saved_flavor_count += 1;
            }
        }
        try writer.writeInt(u32, saved_flavor_count, .little);

        flavor_index = 0;
        while (flavor_index < flavor_count) : (flavor_index += 1) {
            const flavor: c.CFStringRef = @ptrCast(c.CFArrayGetValueAtIndex(flavors, flavor_index).?);
            const data = saved_data[@intCast(flavor_index)] orelse continue;
            const flavor_name = try utf8String(init.gpa, flavor);
            defer init.gpa.free(flavor_name.allocation);
            try writer.writeInt(u32, @intCast(flavor_name.bytes.len), .little);
            try writer.writeAll(flavor_name.bytes);
            const data_length = c.CFDataGetLength(data);
            if (data_length < 0) return error.InvalidPasteboardData;
            try writer.writeInt(u64, @intCast(data_length), .little);
            if (data_length != 0) {
                const bytes = c.CFDataGetBytePtr(data) orelse return error.InvalidPasteboardData;
                try writer.writeAll(bytes[0..@intCast(data_length)]);
            }
        }
    }

    try writer.flush();
    try atomic_file.replace(init.io);
}

const Parser = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Parser, length: usize) ![]const u8 {
        const end = std.math.add(usize, self.offset, length) catch return error.InvalidSnapshot;
        if (end > self.bytes.len) return error.InvalidSnapshot;
        defer self.offset = end;
        return self.bytes[self.offset..end];
    }

    fn integer(self: *Parser, comptime T: type) !T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, @ptrCast(bytes.ptr), .little);
    }
};

fn validateSnapshot(bytes: []const u8) !u32 {
    var parser = Parser{ .bytes = bytes };
    if (!std.mem.eql(u8, try parser.take(magic.len), magic)) return error.InvalidSnapshot;
    const item_count = try parser.integer(u32);

    var item_index: u32 = 0;
    while (item_index < item_count) : (item_index += 1) {
        const flavor_count = try parser.integer(u32);
        var flavor_index: u32 = 0;
        while (flavor_index < flavor_count) : (flavor_index += 1) {
            const name_length = try parser.integer(u32);
            if (!std.unicode.utf8ValidateSlice(try parser.take(name_length))) return error.InvalidSnapshot;
            const data_length = try parser.integer(u64);
            _ = try parser.take(std.math.cast(usize, data_length) orelse return error.InvalidSnapshot);
        }
    }
    if (parser.offset != bytes.len) return error.InvalidSnapshot;
    return item_count;
}

fn restore(init: std.process.Init, pasteboard: c.PasteboardRef, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_snapshot_bytes));
    defer init.gpa.free(bytes);

    const item_count = try validateSnapshot(bytes);
    var parser = Parser{ .bytes = bytes, .offset = magic.len + @sizeOf(u32) };

    try check(c.PasteboardClear(pasteboard));
    var item_index: u32 = 0;
    while (item_index < item_count) : (item_index += 1) {
        const flavor_count = try parser.integer(u32);
        var flavor_index: u32 = 0;
        while (flavor_index < flavor_count) : (flavor_index += 1) {
            const name_length = try parser.integer(u32);
            const name_bytes = try parser.take(name_length);
            const data_length = try parser.integer(u64);
            const data_bytes = try parser.take(std.math.cast(usize, data_length) orelse return error.InvalidSnapshot);

            const flavor = c.CFStringCreateWithBytes(null, name_bytes.ptr, @intCast(name_bytes.len), c.kCFStringEncodingUTF8, 0) orelse
                return error.InvalidSnapshot;
            defer release(flavor);
            const data = c.CFDataCreate(null, data_bytes.ptr, @intCast(data_bytes.len)) orelse
                return error.InvalidSnapshot;
            defer release(data);

            const item: c.PasteboardItemID = @ptrFromInt(@as(usize, item_index) + 1);
            try check(c.PasteboardPutItemFlavor(pasteboard, item, flavor, data, 0));
        }
    }
    std.debug.assert(parser.offset == bytes.len);
}

fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    const pasteboard = try generalPasteboard();
    defer release(pasteboard);

    if (std.mem.eql(u8, args[1], "save")) {
        try save(init, pasteboard, args[2]);
    } else if (std.mem.eql(u8, args[1], "restore")) {
        try restore(init, pasteboard, args[2]);
    } else {
        return error.InvalidMode;
    }
}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        fail("could not read arguments", .{});
    if (args.len != 3)
        fail("usage: PasteboardSnapshot.zig <save|restore> <snapshot-path>", .{});
    run(init, args) catch |err| {
        const action = if (std.mem.eql(u8, args[1], "save")) "save" else if (std.mem.eql(u8, args[1], "restore")) "restore" else
            fail("mode must be save or restore", .{});
        fail("could not {s} pasteboard: {s}", .{ action, @errorName(err) });
    };
}
