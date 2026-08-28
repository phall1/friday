const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{
        .name = "friday",
        .manifest = "app.json",
        .ts_runner = "native/friday_main.zig",
        .ts_extension = "native/friday_host.zig",
        .macos_minimum_version = .{ .major = 14, .minor = 0, .patch = 0 },
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
        "-fno-sanitize=builtin",
        "-ObjC++",
        "-std=c++20",
        "-stdlib=libc++",
        "-mmacosx-version-min=14.0",
        "-isysroot",
        sysroot,
        b.fmt("-isystem{s}/usr/include", .{sysroot}),
    } else &.{
        "-fobjc-arc",
        "-fno-sanitize=builtin",
        "-ObjC++",
        "-std=c++20",
        "-stdlib=libc++",
        "-mmacosx-version-min=14.0",
    };
    module.addCSourceFile(.{
        .file = b.path("native/macos/FridayHost.mm"),
        .flags = flags,
    });
    module.link_libcpp = true;
    module.linkFramework("Accelerate", .{});
    module.linkFramework("AVFoundation", .{});
    module.linkFramework("AppKit", .{});
    module.linkFramework("ApplicationServices", .{});
    module.linkFramework("Carbon", .{});
    module.linkFramework("CoreAudio", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("Metal", .{});
    module.linkFramework("MetalKit", .{});
    module.linkFramework("ServiceManagement", .{});
}
