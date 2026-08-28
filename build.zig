const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{
        .name = "friday",
        .manifest = "app.json",
        .ts_runner = "native/friday_main.zig",
        .ts_extension = "native/friday_host.zig",
        .macos_minimum_version = .{ .major = 13, .minor = 0, .patch = 0 },
    });
    addFridayHost(b, artifacts.exe.root_module);
    addFridayHost(b, artifacts.tests.root_module);
    installNemoRuntime(b, artifacts);
}

fn installNemoRuntime(b: *std.Build, artifacts: native_sdk.AppArtifacts) void {
    const libraries = [_][]const u8{
        "libnemo_speech_asr_c.1.dylib",
        "libnemo_speech_asr.dylib",
        "libggml.0.dylib",
        "libggml-base.0.dylib",
        "libggml-blas.0.dylib",
        "libggml-cpu.0.dylib",
        "libggml-metal.0.dylib",
    };
    for (libraries) |library| {
        const install = b.addInstallFileWithDir(
            b.path(b.fmt("third_party/nemo-speech/lib/{s}", .{library})),
            .prefix,
            b.fmt("Frameworks/{s}", .{library}),
        );
        b.getInstallStep().dependOn(&install.step);
        artifacts.run.step.dependOn(&install.step);
    }
}

fn addFridayHost(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("native/include"));
    module.addIncludePath(b.path("third_party/nemo-speech/include"));
    module.addObjectFile(b.path("third_party/nemo-speech/lib/libnemo_speech_asr_c.dylib"));
    module.addRPathSpecial("@executable_path/../Frameworks");
    module.addRPathSpecial("@executable_path/../../../third_party/nemo-speech/lib");
    const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{
        "-fobjc-arc",
        "-fblocks",
        "-fno-sanitize=builtin",
        "-Wno-deprecated-declarations",
        "-Wno-availability",
        "-Wno-unknown-attributes",
        "-Wno-deprecated-enum-enum-conversion",
        "-Wno-unguarded-availability-new",
        "-ObjC++",
        "-std=c++17",
        "-stdlib=libc++",
        "-mmacosx-version-min=13.0",
        "-isysroot",
        sysroot,
        b.fmt("-isystem{s}/usr/include", .{sysroot}),
    } else &.{
        "-fobjc-arc",
        "-fblocks",
        "-fno-sanitize=builtin",
        "-Wno-deprecated-declarations",
        "-ObjC++",
        "-std=c++17",
        "-stdlib=libc++",
        "-mmacosx-version-min=13.0",
        "-Wno-availability",
        "-Wno-unknown-attributes",
        "-Wno-deprecated-enum-enum-conversion",
        "-Wno-unguarded-availability-new",
    };
    const sources = [_][]const u8{
        "native/macos/FridayHost.mm",
        "native/macos/GlobalInputMonitor.mm",
        "native/macos/TextDelivery.mm",
        "native/macos/OverlayWindow.mm",
        "native/macos/AudioSession.mm",
        "native/macos/NemoRecognizer.mm",
        "native/macos/ModelRepository.mm",
    };
    for (sources) |source| module.addCSourceFile(.{ .file = b.path(source), .flags = flags });
    if (b.sysroot) |sysroot| module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    module.link_libcpp = true;
    module.linkFramework("Accelerate", .{});
    module.linkFramework("AVFoundation", .{});
    module.linkFramework("AVFAudio", .{});
    module.linkFramework("AppKit", .{});
    module.linkFramework("ApplicationServices", .{});
    module.linkFramework("Carbon", .{});
    module.linkFramework("CoreAudio", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("Metal", .{});
    module.linkFramework("MetalKit", .{});
    module.linkFramework("ServiceManagement", .{});
}
