const std = @import("std");
const policy = @import("model_policy.zig");
const Allocator = std.mem.Allocator;
const Model = policy.Model;
const ModelSpec = policy.ModelSpec;
const max_artifact_bytes = policy.max_artifact_bytes;
const isLowerHex = policy.isLowerHex;
const topLevelArtifact = policy.topLevelArtifact;
const hasExtension = policy.hasExtension;
const modelKeyForIdentifier = policy.modelKeyForIdentifier;

pub fn parse(allocator: Allocator, bytes: []const u8, identifier: []const u8) !Model {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |entry| entry,
        else => return error.InvalidMetadata,
    };
    if (jsonBool(object.get("private")) orelse false) return error.PrivateRepository;
    if (isGated(object.get("gated"))) return error.GatedRepository;
    const revision = jsonString(object.get("sha")) orelse return error.MissingRevision;
    if (!isLowerHex(revision, 40)) return error.MissingRevision;

    var asr = if (jsonString(object.get("pipeline_tag"))) |tag| std.mem.eql(u8, tag, "automatic-speech-recognition") else false;
    var license: []const u8 = "";
    if (object.get("tags")) |tags_value| switch (tags_value) {
        .array => |tags| for (tags.items[0..@min(tags.items.len, 256)]) |tag_value| switch (tag_value) {
            .string => |tag| {
                if (std.ascii.eqlIgnoreCase(tag, "automatic-speech-recognition")) asr = true;
                if (std.mem.startsWith(u8, tag, "license:")) license = tag[8..];
            },
            else => {},
        },
        else => {},
    };
    var language_values: []const std.json.Value = &.{};
    if (object.get("cardData")) |card_value| switch (card_value) {
        .object => |card| {
            if (jsonString(card.get("license"))) |card_license| license = card_license;
            if (card.get("language")) |languages| switch (languages) {
                .array => |array| language_values = array.items,
                else => {},
            };
        },
        else => {},
    };
    if (!asr) return error.NotAsr;
    if (license.len == 0 or license.len > 64) return error.MissingLicense;

    const siblings_value = object.get("siblings") orelse return error.NoGguf;
    const siblings = switch (siblings_value) {
        .array => |array| array.items,
        else => return error.NoGguf,
    };
    var candidate: ?std.json.ObjectMap = null;
    var candidate_count: usize = 0;
    for (siblings[0..@min(siblings.len, 4096)]) |sibling_value| {
        const sibling = switch (sibling_value) {
            .object => |entry| entry,
            else => continue,
        };
        const filename = jsonString(sibling.get("rfilename")) orelse continue;
        if (filename.len <= 256 and topLevelArtifact(filename) and hasExtension(filename, ".gguf")) {
            candidate_count += 1;
            candidate = sibling;
        }
    }
    if (candidate_count == 0) return error.NoGguf;
    if (candidate_count != 1) return error.AmbiguousGguf;
    const sibling = candidate.?;
    const artifact = jsonString(sibling.get("rfilename")).?;
    const lfs_value = sibling.get("lfs") orelse return error.InvalidLfs;
    const lfs = switch (lfs_value) {
        .object => |entry| entry,
        else => return error.InvalidLfs,
    };
    var sha256 = jsonString(lfs.get("sha256")) orelse "";
    if (sha256.len == 0) {
        const oid = jsonString(lfs.get("oid")) orelse "";
        sha256 = if (std.mem.startsWith(u8, oid, "sha256:")) oid[7..] else oid;
    }
    const expected_bytes = jsonUnsigned(lfs.get("size")) orelse return error.InvalidLfs;
    if (!isLowerHex(sha256, 64) or expected_bytes < 1024 * 1024 or expected_bytes > max_artifact_bytes) return error.InvalidLfs;

    var language_slices = std.ArrayList([]const u8).empty;
    defer language_slices.deinit(allocator);
    for (language_values[0..@min(language_values.len, 128)]) |language_value| switch (language_value) {
        .string => |language| if (language.len <= 32) language_slices.append(allocator, language) catch return error.OutOfMemory,
        else => {},
    };
    const author = jsonString(object.get("author")) orelse identifier[0..std.mem.indexOfScalar(u8, identifier, '/').?];
    const display_name = jsonString(object.get("modelId")) orelse identifier[std.mem.indexOfScalar(u8, identifier, '/').? + 1 ..];
    const encoded_artifact = try percentEncodeArtifact(allocator, artifact);
    defer allocator.free(encoded_artifact);
    const download_url = try std.fmt.allocPrint(allocator, "https://huggingface.co/{s}/resolve/{s}/{s}", .{ identifier, revision, encoded_artifact });
    defer allocator.free(download_url);
    return Model.init(allocator, .{
        .key = modelKeyForIdentifier(identifier),
        .id = identifier,
        .name = display_name,
        .repository = identifier,
        .revision = revision,
        .artifact = artifact,
        .sha256 = sha256,
        .expected_bytes = expected_bytes,
        .installed_bytes = 0,
        .download_url = download_url,
        .engine = "unverified",
        .family = "unverified",
        .recognition_mode = "unverified",
        .head = "runtime_verified",
        .streaming_profile = "none",
        .format = "gguf",
        .parser_admission = "metadata_only",
        .languages = language_slices.items,
        .license = license,
        .attribution = author,
        .source = "hugging_face",
        .managed = true,
        .compatibility = "unverified_candidate",
        .verification = "",
        .path = "",
    });
}

fn percentEncodeArtifact(allocator: Allocator, artifact: []const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    for (artifact) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writer.writeByte(byte);
        } else {
            try writer.writer.print("%{X:0>2}", .{byte});
        }
    }
    return writer.toOwnedSlice();
}

fn isGated(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return switch (actual) {
        .bool => |boolean| boolean,
        .string => |string| string.len != 0 and !std.mem.eql(u8, string, "false"),
        else => false,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return if (actual == .string) actual.string else null;
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    return if (actual == .bool) actual.bool else null;
}

fn jsonUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(float) else null,
        else => null,
    };
}

pub fn testContracts() !void {
    const metadata = "{\"private\":false,\"gated\":false,\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"pipeline_tag\":\"automatic-speech-recognition\",\"tags\":[\"license:apache-2.0\"],\"siblings\":[{\"rfilename\":\"model.gguf\",\"lfs\":{\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":1048576}}]}";
    var model = try parse(std.testing.allocator, metadata, "fixture/model");
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("metadata_only", model.parser_admission);
    try std.testing.expect(policy.allowlistedArtifactIdentity(model) == null);
    try std.testing.expectError(error.PrivateRepository, parse(std.testing.allocator, "{\"private\":true}", "fixture/model"));
}

test "Hugging Face source remains metadata only" {
    try testContracts();
}
