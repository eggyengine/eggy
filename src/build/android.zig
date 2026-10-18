//! Package an Eggy runtime as an installable, test-signed Android APK.
const std = @import("std");
const resources = @import("resources.zig");
const manifest = @import("../core/assets/manifest.zig");

/// Build `libmain.so`, SDL's Android backend and Java activity, with packaged game assets.
/// Requires the SDK environment prepared by sdk_setup; never builds the desktop editor.
pub fn addApp(b: *std.Build, engine: *std.Build, comptime android: type, root: *std.Build.Module, name: []const u8, files: []const manifest.Entry) void {
    const target = root.resolved_target.?;
    root.linkSystemLibrary("log", .{});
    const sdk = android.Sdk.create(b, .{});
    const app = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = root, .use_llvm = true });
    const apk = sdk.createApk(.{
        .name = b.fmt("{s}-android-test", .{name}),
        .api_level = .android15,
        .build_tools_version = "36.0.0",
        .ndk_version = "27.1.12297006",
    });
    apk.setKeyStore(sdk.createKeyStore(.example));
    const package = packageName(b, name);
    apk.setAndroidManifest(b.addWriteFiles().add("AndroidManifest.xml", b.fmt(android_manifest, .{ package, name })));
    const sdl = prepareSdl(b, engine, root);
    const installed_sdl = b.addInstallFileWithDir(sdl.library, .{ .custom = "android" }, "libSDL3.so");
    app.step.dependOn(&installed_sdl.step);
    apk.addJavaSourceFiles(.{ .root = engine.named_lazy_paths.get("android_java").?, .files = &.{
        "org/libsdl/app/SDL.java",                  "org/libsdl/app/SDLActivity.java",                 "org/libsdl/app/SDLAudioManager.java",
        "org/libsdl/app/SDLControllerManager.java", "org/libsdl/app/SDLDummyEdit.java",                "org/libsdl/app/SDLInputConnection.java",
        "org/libsdl/app/SDLSurface.java",           "org/libsdl/app/HIDDevice.java",                   "org/libsdl/app/HIDDeviceManager.java",
        "org/libsdl/app/HIDDeviceUSB.java",         "org/libsdl/app/HIDDeviceBLESteamController.java",
    } });
    apk.addLibraryFile(switch (target.result.cpu.arch) {
        .aarch64 => .arm64_v8a,
        .x86_64 => .x86_64,
        else => @panic("Android APK exports support aarch64 and x86_64"),
    }, .{ .cwd_relative = b.getInstallPath(.{ .custom = "android" }, "libSDL3.so") });
    apk.addAssetDirectory(resources.bundledDirectory(b, engine, root.optimize orelse .Debug, files));
    apk.addArtifact(app);
    const install = apk.addInstallApk();
    if (sdl.run) |run| run.addFileArg(app.libc_file.?);
    makePic(app);
    b.step("runtime", "Build an installable Android test APK").dependOn(&install.step);
    b.top_level_steps.get("all").?.step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
}

fn prepareSdl(b: *std.Build, engine: *std.Build, root: *std.Build.Module) struct { library: std.Build.LazyPath, run: ?*std.Build.Step.Run } {
    // Eggy's dependency build defines its own runtime first; games share that patched SDL.
    if (engine.named_lazy_paths.get("android_sdl")) |library| return .{ .library = library, .run = null };
    const target = root.resolved_target.?;
    // SDLActivity and the native backend must come from the same pinned SDL source.
    const sdl = engine.modules.get("eggy").?.import_table.get("sdl3").?;
    const objects = sdl.link_objects.items;
    const index = for (objects, 0..) |object, i| {
        if (object == .other_step and std.mem.eql(u8, object.other_step.name, "SDL3")) break i;
    } else @panic("SDL3 library not found");
    const desktop = objects[index].other_step;
    const source = desktop.step.owner.build_root.path orelse ".";
    // The patched SDL build omits installed SDL_main.h; callbacks translate its source header.
    sdl.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ source, "include" }) });
    const vitellus = engine.dependency("vitellus", .{
        .target = target,
        .optimize = root.optimize orelse .Debug,
        .dx12 = true,
        .enable_dxc = false,
        .enable_spirv_cross = false,
        .vk = true,
        .emsdk = engine.graph.environ_map.get("EMSDK") orelse b.pathJoin(&.{ engine.graph.environ_map.get("HOME") orelse "/", "emsdk" }),
        .enable_slang = false,
    });
    const build_sdl = b.addSystemCommand(&.{ "python3", engine.path("src/build/android_sdl.py").getPath(b), source });
    const out = build_sdl.addOutputDirectoryArg("sdl");
    build_sdl.addFileArg(vitellus.path("patches/sdl-android.patch"));
    build_sdl.addArgs(&.{ b.graph.zig_exe, target.query.zigTriple(b.allocator) catch @panic("OOM"), @tagName(root.optimize orelse .Debug) });
    build_sdl.setName("build SDL3 for Android");
    const library = out.path(b, "lib/libSDL3.so");
    objects[index] = .{ .static_path = library };
    for (sdl.include_dirs.items, 0..) |dir, i| {
        if (dir == .other_step and dir.other_step == desktop) {
            _ = sdl.include_dirs.orderedRemove(i);
            break;
        }
    }
    engine.addNamedLazyPath("android_sdl", library);
    return .{ .library = library, .run = build_sdl };
}

fn makePic(app: *std.Build.Step.Compile) void {
    for (app.getCompileDependencies(false)) |dep| for (dep.root_module.getGraph().modules) |module| {
        module.pic = true;
        module.addCMacro("_Nonnull", "");
        module.addCMacro("_Nullable", "");
    };
}

fn packageName(b: *std.Build, name: []const u8) []const u8 {
    const part = b.allocator.dupe(u8, name) catch @panic("OOM");
    for (part) |*char| if (!std.ascii.isAlphanumeric(char.*)) {
        char.* = '_';
    };
    return b.fmt("com.eggyengine.game_{s}", .{part});
}

const android_manifest =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{s}" android:versionCode="1" android:versionName="0.1.0">
    \\  <uses-sdk android:minSdkVersion="35" android:targetSdkVersion="35" />
    \\  <uses-feature android:name="android.hardware.vulkan.version" android:version="0x00403000" android:required="true" />
    \\  <application android:label="{s}" android:theme="@android:style/Theme.NoTitleBar.Fullscreen" android:hardwareAccelerated="true" android:extractNativeLibs="true">
    \\    <activity android:name="org.libsdl.app.SDLActivity" android:exported="true" android:configChanges="layoutDirection|locale|orientation|uiMode|screenLayout|screenSize|smallestScreenSize|keyboard|keyboardHidden|navigation">
    \\      <intent-filter><action android:name="android.intent.action.MAIN" /><category android:name="android.intent.category.LAUNCHER" /></intent-filter>
    \\    </activity>
    \\  </application>
    \\</manifest>
;
