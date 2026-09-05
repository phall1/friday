const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_artifact_bytes: u64 = 8 * 1024 * 1024 * 1024;

const default_languages = [_][]const u8{
    "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
    "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
};

/// Production parser admission is a compiled allowlist, not a claim made by a
/// downloaded or user-provided manifest. Each entry mirrors one reviewed file
/// in resources/models. Extending this array and the packaged manifest is an
/// explicit code-review event; repository metadata alone can never extend it.
pub const TrustedManifestPin = struct {
    key: u64 = 1,
    id: []const u8 = "nvidia/parakeet-tdt-0.6b-v3",
    name: []const u8 = "Parakeet TDT 0.6B v3",
    repository: []const u8 = "nvidia/parakeet-tdt-0.6b-v3",
    revision: []const u8 = "541d1f99c6b0c3cd0b11a95167540bb8edefd82b",
    artifact: []const u8 = "parakeet-tdt-0.6b-v3.q8_0.gguf",
    sha256: []const u8 = "e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e",
    expected_bytes: u64 = 713_975_456,
    url: []const u8 = "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/parakeet-tdt-0.6b-v3.q8_0.gguf",
    engine: []const u8 = "nemo_speech_cpp",
    family: []const u8 = "parakeet_tdt",
    recognition_mode: []const u8 = "offline",
    head: []const u8 = "tdt",
    streaming_profile: []const u8 = "none",
    format: []const u8 = "gguf",
    parser_admission: []const u8 = "friday_production_allowlist_v1",
    languages: []const []const u8 = &default_languages,
    license: []const u8 = "CC-BY-4.0",
    attribution: []const u8 = "NVIDIA Parakeet TDT 0.6B v3",
};
pub const trusted_manifest_pins = [_]TrustedManifestPin{.{}};
pub const default_pin = trusted_manifest_pins[0];

pub const ModelSpec = struct {
    key: u64,
    id: []const u8,
    name: []const u8,
    repository: []const u8,
    revision: []const u8,
    artifact: []const u8,
    sha256: []const u8,
    expected_bytes: u64,
    installed_bytes: u64,
    download_url: []const u8,
    engine: []const u8,
    family: []const u8,
    recognition_mode: []const u8,
    head: []const u8,
    streaming_profile: []const u8,
    format: []const u8,
    parser_admission: []const u8,
    languages: []const []const u8,
    license: []const u8,
    attribution: []const u8,
    source: []const u8,
    managed: bool,
    compatibility: []const u8,
    verification: []const u8,
    path: []const u8,
};

pub const Model = struct {
    key: u64,
    id: []u8,
    name: []u8,
    repository: []u8,
    revision: []u8,
    artifact: []u8,
    sha256: []u8,
    expected_bytes: u64,
    installed_bytes: u64,
    download_url: []u8,
    engine: []u8,
    family: []u8,
    recognition_mode: []u8,
    head: []u8,
    streaming_profile: []u8,
    format: []u8,
    parser_admission: []u8,
    languages: [][]u8,
    license: []u8,
    attribution: []u8,
    source: []u8,
    managed: bool,
    compatibility: []u8,
    verification: []u8,
    path: []u8,

    pub fn init(allocator: Allocator, spec: ModelSpec) !Model {
        const id = try allocator.dupe(u8, spec.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const repository = try allocator.dupe(u8, spec.repository);
        errdefer allocator.free(repository);
        const revision = try allocator.dupe(u8, spec.revision);
        errdefer allocator.free(revision);
        const artifact = try allocator.dupe(u8, spec.artifact);
        errdefer allocator.free(artifact);
        const sha256 = try allocator.dupe(u8, spec.sha256);
        errdefer allocator.free(sha256);
        const download_url = try allocator.dupe(u8, spec.download_url);
        errdefer allocator.free(download_url);
        const engine = try allocator.dupe(u8, spec.engine);
        errdefer allocator.free(engine);
        const family = try allocator.dupe(u8, spec.family);
        errdefer allocator.free(family);
        const recognition_mode = try allocator.dupe(u8, spec.recognition_mode);
        errdefer allocator.free(recognition_mode);
        const head = try allocator.dupe(u8, spec.head);
        errdefer allocator.free(head);
        const streaming_profile = try allocator.dupe(u8, spec.streaming_profile);
        errdefer allocator.free(streaming_profile);
        const format = try allocator.dupe(u8, spec.format);
        errdefer allocator.free(format);
        const parser_admission = try allocator.dupe(u8, spec.parser_admission);
        errdefer allocator.free(parser_admission);
        const license = try allocator.dupe(u8, spec.license);
        errdefer allocator.free(license);
        const attribution = try allocator.dupe(u8, spec.attribution);
        errdefer allocator.free(attribution);
        const source = try allocator.dupe(u8, spec.source);
        errdefer allocator.free(source);
        const compatibility = try allocator.dupe(u8, spec.compatibility);
        errdefer allocator.free(compatibility);
        const verification = try allocator.dupe(u8, spec.verification);
        errdefer allocator.free(verification);
        const path = try allocator.dupe(u8, spec.path);
        errdefer allocator.free(path);

        const languages = try allocator.alloc([]u8, spec.languages.len);
        errdefer allocator.free(languages);
        var language_count: usize = 0;
        errdefer for (languages[0..language_count]) |language| allocator.free(language);
        for (spec.languages, 0..) |language, index| {
            if (language.len > 32) return error.InvalidManifest;
            languages[index] = try allocator.dupe(u8, language);
            language_count += 1;
        }

        return .{
            .key = spec.key,
            .id = id,
            .name = name,
            .repository = repository,
            .revision = revision,
            .artifact = artifact,
            .sha256 = sha256,
            .expected_bytes = spec.expected_bytes,
            .installed_bytes = spec.installed_bytes,
            .download_url = download_url,
            .engine = engine,
            .family = family,
            .recognition_mode = recognition_mode,
            .head = head,
            .streaming_profile = streaming_profile,
            .format = format,
            .parser_admission = parser_admission,
            .languages = languages,
            .license = license,
            .attribution = attribution,
            .source = source,
            .managed = spec.managed,
            .compatibility = compatibility,
            .verification = verification,
            .path = path,
        };
    }

    pub fn clone(self: Model, allocator: Allocator) !Model {
        return init(allocator, self.toSpec());
    }

    pub fn toSpec(self: Model) ModelSpec {
        return .{
            .key = self.key,
            .id = self.id,
            .name = self.name,
            .repository = self.repository,
            .revision = self.revision,
            .artifact = self.artifact,
            .sha256 = self.sha256,
            .expected_bytes = self.expected_bytes,
            .installed_bytes = self.installed_bytes,
            .download_url = self.download_url,
            .engine = self.engine,
            .family = self.family,
            .recognition_mode = self.recognition_mode,
            .head = self.head,
            .streaming_profile = self.streaming_profile,
            .format = self.format,
            .parser_admission = self.parser_admission,
            .languages = self.languages,
            .license = self.license,
            .attribution = self.attribution,
            .source = self.source,
            .managed = self.managed,
            .compatibility = self.compatibility,
            .verification = self.verification,
            .path = self.path,
        };
    }

    pub fn deinit(self: *Model, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.repository);
        allocator.free(self.revision);
        allocator.free(self.artifact);
        allocator.free(self.sha256);
        allocator.free(self.download_url);
        allocator.free(self.engine);
        allocator.free(self.family);
        allocator.free(self.recognition_mode);
        allocator.free(self.head);
        allocator.free(self.streaming_profile);
        allocator.free(self.format);
        allocator.free(self.parser_admission);
        for (self.languages) |language| allocator.free(language);
        allocator.free(self.languages);
        allocator.free(self.license);
        allocator.free(self.attribution);
        allocator.free(self.source);
        allocator.free(self.compatibility);
        allocator.free(self.verification);
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn replace(allocator: Allocator, destination: *[]u8, value: []const u8) !void {
        const copy = try allocator.dupe(u8, value);
        allocator.free(destination.*);
        destination.* = copy;
    }
};

pub fn defaultModel(allocator: Allocator) !Model {
    return trustedModel(allocator, default_pin, true, "hugging_face", default_pin.key);
}

pub fn trustedModel(allocator: Allocator, pin: TrustedManifestPin, managed: bool, source: []const u8, key: u64) !Model {
    return Model.init(allocator, .{
        .key = key,
        .id = pin.id,
        .name = pin.name,
        .repository = pin.repository,
        .revision = pin.revision,
        .artifact = pin.artifact,
        .sha256 = pin.sha256,
        .expected_bytes = pin.expected_bytes,
        .installed_bytes = 0,
        .download_url = pin.url,
        .engine = pin.engine,
        .family = pin.family,
        .recognition_mode = pin.recognition_mode,
        .head = pin.head,
        .streaming_profile = pin.streaming_profile,
        .format = pin.format,
        .parser_admission = pin.parser_admission,
        .languages = pin.languages,
        .license = pin.license,
        .attribution = pin.attribution,
        .source = source,
        .managed = managed,
        .compatibility = "compatible",
        .verification = "",
        .path = "",
    });
}

pub fn isLowerHex(value: []const u8, expected_length: usize) bool {
    if (value.len != expected_length) return false;
    for (value) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

pub fn hasExtension(path: []const u8, extension: []const u8) bool {
    if (path.len < extension.len) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - extension.len ..], extension);
}

pub fn topLevelArtifact(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfAny(u8, name, "/\\") == null and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

pub fn safeHuggingFaceIdentifier(identifier: []const u8) bool {
    if (identifier.len < 3 or identifier.len > 128) return false;
    var parts = std.mem.splitScalar(u8, identifier, '/');
    const owner = parts.next() orelse return false;
    const repository = parts.next() orelse return false;
    if (parts.next() != null or !safeIdentifierPart(owner) or !safeIdentifierPart(repository)) return false;
    return true;
}

pub fn safeIdentifierPart(part: []const u8) bool {
    if (part.len == 0 or part.len > 64 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-')) return false;
    return true;
}

pub fn modelKeyForIdentifier(identifier: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identifier, &digest, .{});
    const prefix = std.mem.readInt(u32, digest[0..4], .little);
    return 1000 + (@as(u64, prefix) % 1_000_000_000);
}

pub fn sameIdentity(left: Model, right: Model) bool {
    return left.key == right.key and left.expected_bytes == right.expected_bytes and
        std.mem.eql(u8, left.id, right.id) and std.mem.eql(u8, left.repository, right.repository) and
        std.mem.eql(u8, left.revision, right.revision) and std.mem.eql(u8, left.artifact, right.artifact) and
        std.mem.eql(u8, left.sha256, right.sha256);
}

pub fn sameLanguages(actual: []const []u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

/// Identity-only matching is used for untrusted network metadata. It may
/// establish that a candidate names already-reviewed bytes, but it does not
/// trust any capability or family claim supplied by that repository.
pub fn allowlistedArtifactIdentity(model: Model) ?TrustedManifestPin {
    for (trusted_manifest_pins) |pin| {
        if (model.expected_bytes == pin.expected_bytes and
            std.mem.eql(u8, model.id, pin.id) and std.mem.eql(u8, model.repository, pin.repository) and
            std.mem.eql(u8, model.revision, pin.revision) and std.mem.eql(u8, model.artifact, pin.artifact) and
            std.mem.eql(u8, model.sha256, pin.sha256)) return pin;
    }
    return null;
}

/// Full manifest matching protects parser admission for local sidecars,
/// persisted indexes, managed manifests, downloads, and resumes. All model
/// capabilities come from the compiled Friday allowlist.
pub fn allowlistedManifest(model: Model) ?TrustedManifestPin {
    const pin = allowlistedArtifactIdentity(model) orelse return null;
    if (!std.mem.eql(u8, model.name, pin.name) or !std.mem.eql(u8, model.download_url, pin.url) or
        !std.mem.eql(u8, model.engine, pin.engine) or !std.mem.eql(u8, model.family, pin.family) or
        !std.mem.eql(u8, model.recognition_mode, pin.recognition_mode) or !std.mem.eql(u8, model.head, pin.head) or
        !std.mem.eql(u8, model.streaming_profile, pin.streaming_profile) or !std.mem.eql(u8, model.format, pin.format) or
        !std.mem.eql(u8, model.parser_admission, pin.parser_admission) or
        !sameLanguages(model.languages, pin.languages) or !std.mem.eql(u8, model.license, pin.license) or
        !std.mem.eql(u8, model.attribution, pin.attribution)) return null;
    return pin;
}

pub fn validInstalledRecord(model: Model) bool {
    return model.key != 0 and model.path.len != 0 and model.installed_bytes == model.expected_bytes and
        std.mem.eql(u8, model.compatibility, "compatible") and allowlistedManifest(model) != null;
}

pub fn legacyRecognitionMode(family: []const u8) []const u8 {
    return if (std.mem.eql(u8, family, "parakeet_tdt") or std.mem.eql(u8, family, "runtime_verified_asr"))
        "offline"
    else
        "unverified";
}

pub fn validCapabilities(recognition_mode: []const u8, head: []const u8, streaming_profile: []const u8) bool {
    const mode_valid = std.mem.eql(u8, recognition_mode, "offline") or
        std.mem.eql(u8, recognition_mode, "streaming") or
        std.mem.eql(u8, recognition_mode, "unverified");
    const head_valid = std.mem.eql(u8, head, "tdt") or std.mem.eql(u8, head, "rnnt") or
        std.mem.eql(u8, head, "ctc") or std.mem.eql(u8, head, "runtime_verified");
    const profile_valid = std.mem.eql(u8, streaming_profile, "none") or
        std.mem.eql(u8, streaming_profile, "rnnt_low_latency") or
        std.mem.eql(u8, streaming_profile, "ctc_buffered") or
        std.mem.eql(u8, streaming_profile, "runtime_verified");
    if (!mode_valid or !head_valid or !profile_valid) return false;
    if (std.mem.eql(u8, recognition_mode, "streaming")) return !std.mem.eql(u8, streaming_profile, "none");
    return std.mem.eql(u8, streaming_profile, "none");
}

pub fn probeMatchesManifest(model: *const Model, probe: anytype) bool {
    return probe.ok and probe.streaming == std.mem.eql(u8, model.recognition_mode, "streaming");
}

pub fn validDownloadManifest(model: Model) bool {
    return model.managed and model.key != 0 and model.expected_bytes > 0 and model.expected_bytes <= max_artifact_bytes and
        isLowerHex(model.revision, 40) and isLowerHex(model.sha256, 64) and topLevelArtifact(model.artifact) and
        std.mem.startsWith(u8, model.download_url, "https://huggingface.co/") and
        std.mem.eql(u8, model.compatibility, "compatible") and allowlistedManifest(model) != null;
}

pub fn testContracts() !void {
    var model = try defaultModel(std.testing.allocator);
    defer model.deinit(std.testing.allocator);
    try std.testing.expect(allowlistedManifest(model) != null);
    try std.testing.expect(validDownloadManifest(model));
    try std.testing.expect(safeHuggingFaceIdentifier("org/model"));
    try std.testing.expect(!safeHuggingFaceIdentifier("../model"));
    try Model.replace(std.testing.allocator, &model.sha256, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expect(allowlistedManifest(model) == null);
}

test "compiled model policy fails closed" {
    try testContracts();
}
