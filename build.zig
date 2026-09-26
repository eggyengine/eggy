const std = @import("std");
const android = @import("android");

pub fn build(b: *std.Build) void {
    const update_submodules = b.addSystemCommand(&.{ "git", "submodule", "update", "--init", "--remote", "--recursive" });
    b.step("update-submodules", "Update submodules to their latest remote commits").dependOn(&update_submodules.step);

    const root_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const android_targets = android.resolveTargets(b, .{
        .default_target = root_target,
        .all_targets = b.option(bool, "android", "Build for all Android targets") orelse false,
        .api_level = .android15,
    });

    var root_target_single = [_]std.Build.ResolvedTarget{root_target};
    const targets: []std.Build.ResolvedTarget = if (android_targets.len == 0)
        root_target_single[0..]
    else
        android_targets;

    const android_apk: ?*android.Apk = blk: {
        if (android_targets.len == 0) break :blk null;

        const android_sdk = android.Sdk.create(b, .{});
        const apk = android_sdk.createApk(.{
            .name = "eggy",
            .api_level = .android15,
            .build_tools_version = "36.0.0",
            .ndk_version = "30.0.15729638",
        });
        apk.setKeyStore(android_sdk.createKeyStore(.example));
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));
        apk.addJavaSourceFiles(.{
            .root = b.path("android/java"),
            .files = &.{
                "com/eggyengine/eggy/EggyActivity.java",
                "org/libsdl/app/SDL.java",
                "org/libsdl/app/SDLActivity.java",
                "org/libsdl/app/SDLAudioManager.java",
                "org/libsdl/app/SDLControllerManager.java",
                "org/libsdl/app/SDLDummyEdit.java",
                "org/libsdl/app/SDLInputConnection.java",
                "org/libsdl/app/SDLSurface.java",
                "org/libsdl/app/HIDDevice.java",
                "org/libsdl/app/HIDDeviceManager.java",
                "org/libsdl/app/HIDDeviceUSB.java",
                "org/libsdl/app/HIDDeviceBLESteamController.java",
            },
        });
        break :blk apk;
    };

    for (targets) |target| {
        const android_target = target.result.abi.isAndroid();
        const library_optimize: std.builtin.OptimizeMode = if (android_target and optimize == .Debug)
            .ReleaseSafe
        else
            optimize;

        const vitellus = b.dependency("vitellus", .{
            .target = target,
            .optimize = library_optimize,
            .dx12 = !android_target,
            .vk = true,
        });
        const emath = b.dependency("eggenvector", .{
            .target = target,
            .optimize = library_optimize,
        });
        const sdl_linkage: std.builtin.LinkMode = if (android_target) .dynamic else .static;
        const sdl3 = b.dependency("sdl3", .{
            .target = target,
            .optimize = library_optimize,
            .c_sdl_preferred_linkage = sdl_linkage,
        });
        const sdl_adapter = b.createModule(.{
            .root_source_file = vitellus.path("src/windowing/sdl3.zig"),
            .target = target,
            .optimize = library_optimize,
        });
        sdl_adapter.addImport("vitellus", vitellus.module("vitellus"));
        sdl_adapter.addImport("sdl3", sdl3.module("sdl3"));

        const engine = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = library_optimize,
        });
        engine.addImport("vitellus", vitellus.module("vitellus"));
        engine.addImport("eggenvector", emath.module("eggenvector"));
        engine.addImport("sdl3", sdl3.module("sdl3"));
        engine.addImport("vitellus_sdl3", sdl_adapter);

        const root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = library_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "eggy", .module = engine }},
        });

        if (android_target) {
            const apk = android_apk orelse @panic("Android APK should be initialized");
            const lib = b.addLibrary(.{
                .name = "main",
                .linkage = .dynamic,
                .root_module = root_module,
                .use_llvm = true,
            });
            apk.addArtifact(lib);
        } else {
            const exe = b.addExecutable(.{
                .name = "eggy",
                .root_module = root_module,
                .use_llvm = true,
            });
            b.installArtifact(exe);

            if (targets.len == 1) {
                const run = b.addRunArtifact(exe);
                if (b.args) |args| run.addArgs(args);
                b.step("run", "Run the engine").dependOn(&run.step);
            }

            const tests = b.addRunArtifact(b.addTest(.{
                .root_module = engine,
                .use_llvm = true,
            }));
            b.step("test", "Run workspace tests").dependOn(&tests.step);
        }
    }

    if (android_apk) |apk| {
        const installed_apk = apk.addInstallApk();
        b.getInstallStep().dependOn(&installed_apk.step);

        const run_step = b.step("run", "Install and run on an Android device");
        const adb_install = apk.sdk.addAdbInstall(installed_apk.source);
        const adb_start = apk.sdk.addAdbStart("com.eggyengine.eggy/com.eggyengine.eggy.EggyActivity");
        adb_start.step.dependOn(&adb_install.step);
        run_step.dependOn(&adb_start.step);
    }
}
