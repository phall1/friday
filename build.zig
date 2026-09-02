const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{
        .name = "friday",
        .manifest = "app.json",
        .ts_runner = "native/friday_main.zig",
        .ts_extension = "native/friday_host.zig",
        .ts_extension_include_paths = &.{"third_party/nemo-speech/include"},
        .macos_minimum_version = .{ .major = 13, .minor = 0, .patch = 0 },
        .macos_cpu_arch = .aarch64,
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
    module.addIncludePath(b.path("third_party/nemo-speech/include"));
    module.addObjectFile(b.path("third_party/nemo-speech/lib/libnemo_speech_asr_c.dylib"));
    module.addRPathSpecial("@executable_path/../Frameworks");
    module.addRPathSpecial("@executable_path/../../../third_party/nemo-speech/lib");
    if (b.sysroot) |sysroot| {
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib/system" });
        module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    }
    module.link_libc = true;
    module.linkSystemLibrary("objc", .{});
    module.linkSystemLibrary("dispatch", .{});
    module.linkFramework("Accelerate", .{});
    module.linkFramework("AppKit", .{});
    module.linkFramework("ApplicationServices", .{});
    module.linkFramework("AudioToolbox", .{});
    module.linkFramework("CoreAudio", .{});
    module.linkFramework("CoreFoundation", .{});
    module.linkFramework("CoreGraphics", .{});
    module.linkFramework("ServiceManagement", .{});
}
