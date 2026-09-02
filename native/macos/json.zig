const std = @import("std");

pub fn field(payload: []const u8, name: []const u8) []const u8 {
    var parts = std.mem.splitScalar(u8, payload, ';');
    while (parts.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..split], name)) return part[split + 1 ..];
    }
    return "";
}

pub fn unsignedField(payload: []const u8, name: []const u8) u64 {
    return std.fmt.parseUnsigned(u64, field(payload, name), 10) catch 0;
}

pub fn boolField(payload: []const u8, name: []const u8) bool {
    const value = field(payload, name);
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
}

pub fn decodeBase64Alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const length = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, length);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

pub fn writeBase64(writer: *std.Io.Writer, bytes: []const u8) !void {
    const encoded_length = std.base64.standard.Encoder.calcSize(bytes.len);
    if (encoded_length <= 4096) {
        var buffer: [4096]u8 = undefined;
        try writer.writeAll(std.base64.standard.Encoder.encode(buffer[0..encoded_length], bytes));
        return;
    }
    const allocator = std.heap.page_allocator;
    const encoded = try allocator.alloc(u8, encoded_length);
    defer allocator.free(encoded);
    try writer.writeAll(std.base64.standard.Encoder.encode(encoded, bytes));
}

pub fn writeString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try std.json.Stringify.value(bytes, .{}, writer);
}

pub fn objectOk(bytes: []const u8) bool {
    return boolValue(bytes, "ok") orelse false;
}

pub fn boolValue(bytes: []const u8, name: []const u8) ?bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(name) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        .integer => |integer| integer != 0,
        else => null,
    };
}

pub fn unsignedValue(bytes: []const u8, name: []const u8) ?u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(float) else null,
        .number_string => |number| std.fmt.parseUnsigned(u64, number, 10) catch null,
        else => null,
    };
}

pub fn stringAlloc(allocator: std.mem.Allocator, bytes: []const u8, name: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(name) orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}

pub fn writeError(output: []u8, code: []const u8, message: []const u8) usize {
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("{\"ok\":false,\"code\":") catch return 0;
    writeString(&writer, code) catch return 0;
    writer.writeAll(",\"message\":") catch return 0;
    writeString(&writer, message) catch return 0;
    writer.writeByte('}') catch return 0;
    return writer.buffered().len;
}

pub fn addFields(output: []u8, object: []const u8, fields: []const u8) !usize {
    if (object.len < 2 or object[0] != '{' or object[object.len - 1] != '}') return error.InvalidJsonObject;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(object[0 .. object.len - 1]);
    if (object.len > 2 and fields.len > 0) try writer.writeByte(',');
    try writer.writeAll(fields);
    try writer.writeByte('}');
    return writer.buffered().len;
}

pub fn addGeneration(output: []u8, object: []const u8, generation: u64) !usize {
    var fields_buffer: [64]u8 = undefined;
    const fields = try std.fmt.bufPrint(&fields_buffer, "\"generation\":{d}", .{generation});
    return addFields(output, object, fields);
}

pub fn mergeNamed(output: []u8, object: []const u8, name: []const u8, nested: []const u8) !usize {
    var fields_buffer: [128]u8 = undefined;
    var fields_writer = std.Io.Writer.fixed(&fields_buffer);
    try writeString(&fields_writer, name);
    try fields_writer.writeByte(':');
    const prefix = fields_writer.buffered().len;
    if (prefix + nested.len > output.len) return error.WriteFailed;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(object[0 .. object.len - 1]);
    if (object.len > 2) try writer.writeByte(',');
    try writer.writeAll(fields_writer.buffered());
    try writer.writeAll(nested);
    try writer.writeByte('}');
    return writer.buffered().len;
}
