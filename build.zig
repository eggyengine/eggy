const std = @import("std");

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
    const emsdk = b.option([]const u8, "emsdk", "Path to emsdk for web builds (default: $EMSDK, then ~/emsdk)") orelse
        b.graph.environ_map.get("EMSDK") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse "/", "emsdk" });
    const emscripten_sysroot = b.pathJoin(&.{ emsdk, "upstream/emscripten/cache/sysroot" });
    const emscripten_sysroot_include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ emscripten_sysroot, "include" }) };
    // SDL's build reads Emscripten's sysroot from `--sysroot`.
    if (web and b.sysroot == null) b.sysroot = emscripten_sysroot;

    const host_slang = slangDependency(b, b.graph.host.result.os.tag, b.graph.host.result.cpu.arch) orelse return;
    const host_compiler = host_slang.path(if (b.graph.host.result.os.tag == .windows) "bin/slangc.exe" else "bin/slangc");
    const shader_target, const shader_ext = if (web) .{ "wgsl", "wgsl" } else .{ "spirv", "spv" };
    const viewport_vertex_compile = b.addSystemCommand(&.{host_compiler.getPath(b)});
    viewport_vertex_compile.addFileArg(b.path("src/shaders/viewport3d.slang"));
    viewport_vertex_compile.addArgs(&.{ "-target", shader_target, "-entry", "vertexMain", "-stage", "vertex", "-o" });
    const viewport_vertex_code = viewport_vertex_compile.addOutputFileArg(b.fmt("viewport3d.vert.{s}", .{shader_ext}));
    const viewport_fragment_compile = b.addSystemCommand(&.{host_compiler.getPath(b)});
    viewport_fragment_compile.addFileArg(b.path("src/shaders/viewport3d.slang"));
    viewport_fragment_compile.addArgs(&.{ "-target", shader_target, "-entry", "fragmentMain", "-stage", "fragment", "-o" });
    const viewport_fragment_code = viewport_fragment_compile.addOutputFileArg(b.fmt("viewport3d.frag.{s}", .{shader_ext}));
    const shader_files = b.addWriteFiles();
    _ = shader_files.addCopyFile(viewport_vertex_code, "viewport3d.vert");
    _ = shader_files.addCopyFile(viewport_fragment_code, "viewport3d.frag");
    const shader_module = b.createModule(.{
        .root_source_file = shader_files.add("root.zig",
            \\pub const viewport_vertex = @embedFile("viewport3d.vert");
            \\pub const viewport_fragment = @embedFile("viewport3d.frag");
        ),
        .target = target,
        .optimize = optimize,
    });
    // The in-process Slang compiler is desktop-only; the web build has its shaders baked in.
    const slang_options = b.addOptions();
    if (!web) {
        const target_slang = slangDependency(b, target.result.os.tag, target.result.cpu.arch) orelse return;
        const library_file, const library_name = switch (target.result.os.tag) {
            .linux => .{ "lib/libslang-compiler.so.0.2026.18.2", "libslang-compiler.so" },
            .macos => .{ "lib/libslang-compiler.0.2026.18.2.dylib", "libslang-compiler.dylib" },
            .windows => .{ "bin/slang-compiler.dll", "slang-compiler.dll" },
            else => unreachable,
        };
        const library_path = target_slang.path(library_file);
        slang_options.addOptionPath("library", library_path);
        // Unix loads the library from lib/; Windows keeps DLLs beside the exe.
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(library_path, if (target.result.os.tag == .windows) .bin else .lib, library_name).step);
    }

    const vitellus = b.dependency("vitellus", .{
        .target = target,
        .optimize = optimize,
        .dx12 = true,
        .vk = !web,
        .emsdk = emsdk,
    });
    const emath = b.dependency("eggenvector", .{ .target = target, .optimize = optimize });
    const weeoui = b.dependency("weeoui", .{ .target = target, .optimize = optimize, .sdl3 = !web });
    const nvdialog = b.dependency("nvdialog", .{});
    const fatal_dialog = b.createModule(.{ .root_source_file = b.path("src/fatal_dialog.zig"), .target = target, .optimize = optimize, .link_libc = true });
    if (!web) addNvdialog(b, fatal_dialog, nvdialog, target.result);
    // Same args as Weeoui's lazy sdl3 so both share one SDL build (static by default).
    // On the web Weeoui skips SDL, and SDL needs Emscripten's system headers.
    const sdl3 = if (web)
        b.dependency("sdl3", .{ .target = target, .optimize = optimize, .sdl_system_include_path = emscripten_sysroot_include })
    else
        b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    if (web) sdl3.module("sdl3").addSystemIncludePath(emscripten_sysroot_include);
    const sdl_adapter = b.createModule(.{
        .root_source_file = vitellus.path("src/windowing/sdl3.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdl_adapter.addImport("vitellus", vitellus.module("vitellus"));
    sdl_adapter.addImport("sdl3", sdl3.module("sdl3"));
    const slangc = b.createModule(.{
        .root_source_file = b.path("src/slangc.zig"),
        .target = target,
        .optimize = optimize,
    });
    slangc.addImport("slang_library", slang_options.createModule());

    const engine = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("vitellus", vitellus.module("vitellus"));
    engine.addImport("eggenvector", emath.module("eggenvector"));
    engine.addImport("weeoui", weeoui.module("weeoui"));
    if (!web) engine.addImport("weeoui_sdl3", weeoui.module("weeoui_sdl3"));
    // Weeoui's renderer compiled against Eggy's own Vitellus (its -Dvitellus would fetch a second copy).
    const weeoui_vitellus = b.createModule(.{
        .root_source_file = weeoui.path("src/vitellus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "weeoui", .module = weeoui.module("weeoui") }, .{ .name = "vitellus", .module = vitellus.module("vitellus") } },
    });
    engine.addImport("weeoui_vitellus", weeoui_vitellus);
    engine.addImport("slangc", slangc);
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
    if (web) return addWeb(b, main_module, emsdk, emscripten_sysroot_include, optimize);

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
    const slang_test_module = b.createModule(.{
        .root_source_file = b.path("src/slangc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    slang_test_module.addImport("slang_library", slang_options.createModule());
    const slang_tests = b.addRunArtifact(b.addTest(.{ .root_module = slang_test_module, .use_llvm = true }));
    const test_step = b.step("test", "Run workspace tests");
    test_step.dependOn(&tests.step);
    test_step.dependOn(&slang_tests.step);
    const dialog_tests = b.addRunArtifact(b.addTest(.{ .root_module = fatal_dialog, .use_llvm = true }));
    test_step.dependOn(&dialog_tests.step);
    const viewport_tests_module = b.createModule(.{
        .root_source_file = b.path("src/viewport3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    viewport_tests_module.addImport("vitellus", vitellus.module("vitellus"));
    viewport_tests_module.addImport("weeoui", weeoui.module("weeoui"));
    viewport_tests_module.addImport("sdl3", sdl3.module("sdl3"));
    viewport_tests_module.addImport("ui_shaders", shader_module);
    viewport_tests_module.addImport("weeoui_vitellus", weeoui_vitellus);
    const viewport_tests = b.addRunArtifact(b.addTest(.{ .root_module = viewport_tests_module, .use_llvm = true }));
    test_step.dependOn(&viewport_tests.step);
    b.step("test-viewport", "Run 3D preview tests").dependOn(&viewport_tests.step);
}

/// `zig build -Dtarget=wasm32-emscripten`: Zig builds a static library and emcc links it, SDL
/// and Dawn's WebGPU bindings into zig-out/web/eggy.html. `run` serves it with emrun.
fn addWeb(b: *std.Build, main_module: *std.Build.Module, emsdk: []const u8, sysroot_include: std.Build.LazyPath, optimize: std.builtin.OptimizeMode) void {
    const lib = b.addLibrary(.{ .name = "eggy", .linkage = .static, .root_module = main_module });
    // Zig ships no Emscripten libc headers; C code in every module (FreeType, zlib, stb, ...) needs the sysroot's.
    for (lib.getCompileDependencies(false)) |dep| {
        for (dep.root_module.getGraph().modules) |module| module.addSystemIncludePath(sysroot_include);
    }
    const emscripten = b.pathJoin(&.{ emsdk, "upstream/emscripten" });
    // em++, since Dawn's WebGPU bindings are C++.
    const emcc = b.addSystemCommand(&.{b.pathJoin(&.{ emscripten, "em++" })});
    emcc.setEnvironmentVariable("EM_CONFIG", b.pathJoin(&.{ emsdk, ".emscripten" }));
    // Zig static libraries do not bundle their dependencies, so hand emcc every one (SDL, FreeType, ...).
    for (lib.getCompileDependencies(false)) |dep| {
        if (dep.kind == .lib and dep.linkage == .static) emcc.addArtifactArg(dep);
    }
    emcc.addArgs(&.{
        switch (optimize) {
            .Debug => "-O0",
            .ReleaseSafe, .ReleaseFast => "-O2",
            .ReleaseSmall => "-Oz",
        },
        "--use-port=emdawnwebgpu",
        // Vitellus waits on WebGPU's async adapter, device and fence callbacks.
        "-sASYNCIFY",
        "-sASYNCIFY_STACK_SIZE=65536",
        "-sSTACK_SIZE=1048576",
        "-sALLOW_MEMORY_GROWTH",
        "-o",
    });
    const html = emcc.addOutputFileArg("eggy.html");
    const install = b.addInstallDirectory(.{ .source_dir = html.dirname(), .install_dir = .prefix, .install_subdir = "web" });
    b.getInstallStep().dependOn(&install.step);

    const run = b.addSystemCommand(&.{ b.pathJoin(&.{ emscripten, "emrun" }), b.getInstallPath(.prefix, "web/eggy.html") });
    run.setEnvironmentVariable("EM_CONFIG", b.pathJoin(&.{ emsdk, ".emscripten" }));
    run.step.dependOn(&install.step);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Open the game in a browser").dependOn(&run.step);
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

fn slangDependency(b: *std.Build, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?*std.Build.Dependency {
    const name = switch (os) {
        .linux => switch (arch) {
            .x86_64 => "slang_linux_x86_64",
            .aarch64 => "slang_linux_aarch64",
            else => @panic("Slang has no bundled release for this Linux architecture"),
        },
        .macos => switch (arch) {
            .x86_64 => "slang_macos_x86_64",
            .aarch64 => "slang_macos_aarch64",
            else => @panic("Slang has no bundled release for this macOS architecture"),
        },
        .windows => switch (arch) {
            .x86_64 => "slang_windows_x86_64",
            .aarch64 => "slang_windows_aarch64",
            else => @panic("Slang has no bundled release for this Windows architecture"),
        },
        else => @panic("Slang has no bundled release for this operating system"),
    };
    return b.lazyDependency(name, .{});
}
