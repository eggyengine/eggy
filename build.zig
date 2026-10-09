const std = @import("std");
const vitellus_build = @import("vitellus");
const Emscripten = vitellus_build.Emscripten;

pub fn build(b: *std.Build) void {
    const update_submodules = b.addSystemCommand(&.{ "git", "submodule", "update", "--init", "--remote", "--recursive" });
    b.step("update-submodules", "Update submodules to their latest remote commits").dependOn(&update_submodules.step);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const macos_sdk = b.option([]const u8, "macos-sdk", "MacOSX.sdk path (default: $HOME/SDKs or --sysroot)");
    if (target.result.os.tag == .macos and b.sysroot == null) {
        b.sysroot = macos_sdk orelse defaultMacSdk(b) orelse {
            std.log.err("macOS builds need --sysroot or -Dmacos-sdk pointing at a MacOSX.sdk", .{});
            std.process.exit(1);
        };
    }
    // The web build renders with WebGPU, takes WGSL, and is linked by emcc instead of Zig.
    const web = target.result.os.tag == .emscripten;
    const emscripten = Emscripten.init(b, target, b.option([]const u8, "emsdk", "Path to emsdk for web builds (default: $EMSDK, then ~/emsdk)"));

    const vitellus = b.dependency("vitellus", .{
        .target = target,
        .optimize = optimize,
        .dx12 = true,
        .vk = !web,
        .emsdk = emscripten.emsdk,
        .enable_slang = true,
    });
    vitellus_build.installLibraries(b, vitellus);

    // Built-in shaders: WGSL on the web, SPIR-V elsewhere.
    const viewport_shader = b.path("src/shaders/viewport3d.slang");
    const viewport_vertex = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "vertexMain", .vertex) orelse return;
    const viewport_fragment = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "fragmentMain", .fragment) orelse return;
    const shader_files = b.addWriteFiles();
    _ = shader_files.addCopyFile(viewport_vertex, "viewport3d.vert");
    _ = shader_files.addCopyFile(viewport_fragment, "viewport3d.frag");
    const shader_module = b.createModule(.{
        .root_source_file = shader_files.add("root.zig",
            \\pub const viewport_vertex = @embedFile("viewport3d.vert");
            \\pub const viewport_fragment = @embedFile("viewport3d.frag");
        ),
        .target = target,
        .optimize = optimize,
    });
    const emath = b.dependency("eggenvector", .{ .target = target, .optimize = optimize });
    const weeoui = b.dependency("weeoui", .{ .target = target, .optimize = optimize, .sdl3 = !web });
    const nvdialog = b.dependency("nvdialog", .{});
    const fatal_dialog = b.createModule(.{ .root_source_file = b.path("src/fatal_dialog.zig"), .target = target, .optimize = optimize, .link_libc = true });
    if (!web) addNvdialog(b, fatal_dialog, nvdialog, target.result);
    // Same args as Weeoui's lazy sdl3 so both share one SDL build (static by default).
    // On the web Weeoui skips SDL, and SDL needs Emscripten's system headers.
    const sdl3 = if (web)
        b.dependency("sdl3", .{ .target = target, .optimize = optimize, .sdl_system_include_path = emscripten.include })
    else
        b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    const sdl_adapter = b.createModule(.{
        .root_source_file = vitellus.path("src/windowing/sdl3.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdl_adapter.addImport("vitellus", vitellus.module("vitellus"));
    sdl_adapter.addImport("sdl3", sdl3.module("sdl3"));

    const engine = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("vitellus", vitellus.module("vitellus"));
    engine.addImport("vitellus_spirv", vitellus.module("vitellus_spirv"));
    engine.addImport("eggenvector", emath.module("eggenvector"));
    engine.addImport("weeoui", weeoui.module("weeoui"));
    if (!web) engine.addImport("weeoui_sdl3", weeoui.module("weeoui_sdl3"));
    // Weeoui's renderer compiled against Eggy's own Vitellus (its -Dvitellus would fetch a second copy).
    const weeoui_vitellus = b.createModule(.{
        .root_source_file = weeoui.path("src/vitellus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "weeoui", .module = weeoui.module("weeoui") }, .{ .name = "vitellus", .module = vitellus.module("vitellus") }, .{ .name = "vitellus_spirv", .module = vitellus.module("vitellus_spirv") } },
    });
    engine.addImport("weeoui_vitellus", weeoui_vitellus);
    engine.addImport("vitellus_slangc", vitellus.module("vitellus_slangc"));
    engine.addImport("ui_shaders", shader_module);
    engine.addImport("sdl3", sdl3.module("sdl3"));
    engine.addImport("vitellus_sdl3", sdl_adapter);
    engine.link_libc = true;
    // AccessKit comes linked into Weeoui; on Windows its DLL must sit next to the exe.
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&b.addInstallFileWithDir(weeoui.namedLazyPath("accesskit_dll"), .bin, "accesskit.dll").step);
    switch (target.result.os.tag) {
        .linux => {
            engine.linkSystemLibrary("m", .{});
            engine.linkSystemLibrary("unwind", .{});
        },
        .windows => {},
        .macos => {
            inline for (.{ "AppKit", "Foundation", "CoreFoundation" }) |framework| engine.linkFramework(framework, .{});
            engine.linkSystemLibrary("objc", .{});
            engine.linkSystemLibrary("c++", .{});
        },
        .emscripten => {},
        else => unreachable,
    }
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "eggy", .module = engine }, .{ .name = "fatal_dialog", .module = fatal_dialog } },
    });
    if (web) {
        const app = emscripten.addApp(b, .{ .name = "eggy", .root_module = main_module });
        b.step("run", "Open the game in a browser").dependOn(&app.run.step);
        return;
    }

    const exe = b.addExecutable(.{
        .name = "eggy",
        .root_module = main_module,
        .use_llvm = true,
    });
    addMacSdk(b, exe.root_module);
    addMacSdk(b, engine);
    b.installArtifact(exe);

    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, if (target.result.os.tag == .windows) "eggy.exe" else "eggy")});
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the game").dependOn(&run.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = engine, .use_llvm = true }));
    const test_step = b.step("test", "Run workspace tests");
    test_step.dependOn(&tests.step);
    const dialog_tests = b.addRunArtifact(b.addTest(.{ .root_module = fatal_dialog, .use_llvm = true }));
    test_step.dependOn(&dialog_tests.step);
    const viewport_tests_module = b.createModule(.{
        .root_source_file = b.path("src/viewport3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    viewport_tests_module.addImport("vitellus", vitellus.module("vitellus"));
    viewport_tests_module.addImport("vitellus_spirv", vitellus.module("vitellus_spirv"));
    viewport_tests_module.addImport("weeoui", weeoui.module("weeoui"));
    viewport_tests_module.addImport("sdl3", sdl3.module("sdl3"));
    viewport_tests_module.addImport("ui_shaders", shader_module);
    viewport_tests_module.addImport("weeoui_vitellus", weeoui_vitellus);
    const viewport_tests = b.addRunArtifact(b.addTest(.{ .root_module = viewport_tests_module, .use_llvm = true }));
    test_step.dependOn(&viewport_tests.step);
    b.step("test-viewport", "Run 3D preview tests").dependOn(&viewport_tests.step);
}

/// The native fatal-error dialog; the web build reports to the browser console instead.
fn addNvdialog(b: *std.Build, fatal_dialog: *std.Build.Module, nvdialog: *std.Build.Dependency, target: std.Target) void {
    fatal_dialog.addIncludePath(nvdialog.path("include"));
    fatal_dialog.addIncludePath(nvdialog.path("src"));
    fatal_dialog.addIncludePath(nvdialog.path("src/impl"));
    fatal_dialog.addIncludePath(nvdialog.path("vendor"));
    fatal_dialog.addCSourceFiles(.{
        .root = nvdialog.path("."),
        .files = &.{
            "src/nvdialog_error.c",
            "src/nvdialog_image.c",
            "src/nvdialog_util.c",
            "src/nvdialog_capab.c",
            "src/nvdialog_version.c",
            "src/nvdialog_init.c",
            "src/nvdialog_string.c",
            "src/nvdialog_main.c",
        },
        .flags = if (target.os.tag == .macos)
            &.{ "-std=c11", "-DNVDIALOG_MAXBUF=4096", "-DNVD_STATIC_LINKAGE", "-DNVD_USE_COCOA=1" }
        else
            &.{ "-std=c11", "-DNVDIALOG_MAXBUF=4096", "-DNVD_STATIC_LINKAGE" },
    });
    switch (target.os.tag) {
        .linux => {
            fatal_dialog.addCSourceFiles(.{
                .root = nvdialog.path("."),
                .files = &.{
                    "src/backend/gtk/nvdialog_about_dialog.c",
                    "src/backend/gtk/nvdialog_file_dialog.c",
                    "src/backend/gtk/nvdialog_dialog_box.c",
                    "src/backend/gtk/nvdialog_question_dialog.c",
                    "src/backend/gtk/nvdialog_notification.c",
                    "src/backend/gtk/nvdialog_input_dialog.c",
                },
                .flags = &.{ "-std=c11", "-DNVDIALOG_MAXBUF=4096", "-DNVD_STATIC_LINKAGE" },
            });
            fatal_dialog.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
            fatal_dialog.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .force });
        },
        .macos => {
            fatal_dialog.addCSourceFiles(.{
                .root = nvdialog.path("."),
                .files = &.{
                    "src/backend/cocoa/nvdialog_dialog_box.m",
                    "src/backend/cocoa/nvdialog_file_dialog.m",
                    "src/backend/cocoa/nvdialog_input_box.m",
                    "src/backend/cocoa/nvdialog_question_dialog.m",
                    "src/backend/cocoa/nvdialog_notification.m",
                    "src/backend/cocoa/nvdialog_about_dialog.m",
                    "src/backend/cocoa/nvdialog_cocoa_init.m",
                },
                .flags = &.{ "-DNVD_USE_COCOA=1", "-fno-objc-arc", "-DNVDIALOG_MAXBUF=4096", "-DNVD_STATIC_LINKAGE" },
            });
            addMacSdk(b, fatal_dialog);
            inline for (.{ "AppKit", "Cocoa", "Foundation", "UserNotifications" }) |framework| fatal_dialog.linkFramework(framework, .{});
        },
        .windows => {
            fatal_dialog.addCSourceFiles(.{
                .root = nvdialog.path("."),
                .files = &.{
                    "src/backend/win32/nvdialog_about_dialog.c",
                    "src/backend/win32/nvdialog_dialog_box.c",
                    "src/backend/win32/nvdialog_question_dialog.c",
                    "src/backend/win32/nvdialog_file_dialog.c",
                    "src/backend/win32/nvdialog_notification.c",
                    "src/backend/win32/nvdialog_input_box.c",
                },
                .flags = &.{ "-std=c11", "-DNVDIALOG_MAXBUF=4096", "-DNVD_STATIC_LINKAGE" },
            });
            inline for (.{ "comdlg32", "shell32", "user32", "gdi32", "ole32" }) |lib| fatal_dialog.linkSystemLibrary(lib, .{});
        },
        else => @panic("nvdialog is supported only on desktop Linux, macOS, and Windows"),
    }
}

fn defaultMacSdk(b: *std.Build) ?[]const u8 {
    const home = b.graph.environ_map.get("HOME") orelse return null;
    return b.pathJoin(&.{ home, "SDKs" });
}

fn addMacSdk(b: *std.Build, mod: *std.Build.Module) void {
    const sysroot = b.sysroot orelse return;
    mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
}
