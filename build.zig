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
    const emscripten = Emscripten.init(b, target, b.option([]const u8, "emsdk", "Path to emsdk for web builds (default: $EMSDK, then ~/emsdk)"));
    // On a fresh checkout Slang isn't fetched yet: Zig fetches it and runs this build again.
    const engine = addEngine(b, target, optimize, emscripten) orelse return;

    // The sandbox: what `zig build run` opens here, built exactly as `addGame` builds a game.
    addProject(b, b, emscripten, target, optimize, .{
        .name = "sandbox",
        .game = b.createModule(.{ .root_source_file = b.path("examples/sandbox/game.zig"), .target = target, .optimize = optimize }),
        .plugins = &.{b.createModule(.{ .root_source_file = b.path("examples/sandbox/window_info.zig"), .target = target, .optimize = optimize })},
    });

    // Tests. The runtime's and editor's mostly check that they compile: running them needs a GPU.
    const test_step = b.step("test", "Run every test");
    const core_tests = addCoreTests(b, engine);
    test_step.dependOn(core_tests);
    const runtime_tests = &b.addRunArtifact(b.addTest(.{ .root_module = b.modules.get("eggy_runtime").?, .use_llvm = true })).step;
    b.step("test-runtime", "Run eggy_runtime's tests").dependOn(runtime_tests);
    test_step.dependOn(runtime_tests);
    if (b.modules.get("eggy_editor")) |editor| {
        const editor_tests = &b.addRunArtifact(b.addTest(.{ .root_module = editor, .use_llvm = true })).step;
        b.step("test-editor", "Run eggy_editor's tests").dependOn(editor_tests);
        test_step.dependOn(editor_tests);
    }
}

pub const GameOptions = struct {
    /// The runtime executable's and window's name; the editor is `<name>_editor`.
    name: []const u8,
    /// The game's root module. It declares `pub const Game`, Eggy's first plugin (see `eggy.plugins`).
    game: *std.Build.Module,
    /// Plugin modules, each declaring `pub const Plugin`. Eggy runs them after the game, in order.
    plugins: []const *std.Build.Module = &.{},
    /// Default: `-Dtarget`.
    target: ?std.Build.ResolvedTarget = null,
    /// Default: `-Doptimize`.
    optimize: ?std.builtin.OptimizeMode = null,
};

/// Build a game made with Eggy: its runtime, its editor (desktop only), and the steps `all`,
/// `runtime`, `editor`, `run` (the editor; on the web, the runtime in a browser) and `run-runtime`.
/// The game and each plugin get `@import("eggy")`. Call this from the game's `build.zig`.
pub fn addGame(b: *std.Build, options: GameOptions) void {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    const emsdk = b.option([]const u8, "emsdk", "Path to emsdk for web builds (default: $EMSDK, then ~/emsdk)");
    const eggy = b.dependencyFromBuildZig(@This(), .{ .target = target, .optimize = optimize, .emsdk = emsdk });
    addProject(b, eggy.builder, Emscripten.init(b, target, emsdk), target, optimize, options);
}

/// `addGame` for any builder: `engine` is Eggy's own builder, which is `b` itself for the sandbox.
fn addProject(b: *std.Build, engine: *std.Build, emscripten: Emscripten, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: GameOptions) void {
    // Missing until Eggy's lazy dependencies are fetched; Zig then runs the build again.
    const eggy = engine.modules.get("eggy") orelse return;
    const runtime = engine.modules.get("eggy_runtime").?;

    // The project module: the game's name and its plugin types, the game first.
    options.game.addImport("eggy", eggy);
    var source: std.ArrayList(u8) = .empty;
    source.print(b.allocator, "pub const name = \"{f}\";\npub const plugins = .{{ @import(\"game\").Game", .{std.zig.fmtString(options.name)}) catch @panic("OOM");
    for (options.plugins, 0..) |plugin, i| {
        plugin.addImport("eggy", eggy);
        source.print(b.allocator, ", @import(\"plugin_{d}\").Plugin", .{i}) catch @panic("OOM");
    }
    source.appendSlice(b.allocator, " };\n") catch @panic("OOM");
    const project = b.createModule(.{ .root_source_file = b.addWriteFiles().add("eggy_project.zig", source.items), .target = target, .optimize = optimize });
    project.addImport("game", options.game);
    for (options.plugins, 0..) |plugin, i| project.addImport(b.fmt("plugin_{d}", .{i}), plugin);

    // The runtime, on every platform.
    const runtime_module = b.createModule(.{
        .root_source_file = engine.path("src/runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "eggy", .module = eggy },
            .{ .name = "eggy_runtime", .module = runtime },
            .{ .name = "eggy_project", .module = project },
        },
    });
    const all_step = b.step("all", "Build every executable for this target");
    if (target.result.os.tag == .emscripten) {
        const app = emscripten.addApp(b, .{ .name = options.name, .root_module = runtime_module });
        b.step("runtime", "Build the game for the browser").dependOn(&app.install.step);
        b.step("run", "Open the game in a browser").dependOn(&app.run.step);
        all_step.dependOn(&app.install.step);
        return;
    }
    installRuntimeLibraries(b, engine);
    const runtime_app = addDesktopApp(b, target, runtime_module, options.name);
    b.step("runtime", "Build the game").dependOn(&runtime_app.install.step);
    b.step("run-runtime", "Run the game").dependOn(&runtime_app.run.step);
    all_step.dependOn(&runtime_app.install.step);

    // The editor, desktop only.
    const editor_module = b.createModule(.{
        .root_source_file = engine.path("src/editor/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "eggy", .module = eggy },
            .{ .name = "eggy_editor", .module = engine.modules.get("eggy_editor").? },
            .{ .name = "eggy_project", .module = project },
        },
    });
    const editor_app = addDesktopApp(b, target, editor_module, b.fmt("{s}_editor", .{options.name}));
    b.step("editor", "Build the editor").dependOn(&editor_app.install.step);
    b.step("run", "Run the editor").dependOn(&editor_app.run.step);
    all_step.dependOn(&editor_app.install.step);
}

/// The modules and dependencies Eggy's own tests need.
const Engine = struct {
    eggy: *std.Build.Module,
    fatal_dialog: *std.Build.Module,
    vitellus: *std.Build.Dependency,
    weeoui: *std.Build.Dependency,
    sdl3: *std.Build.Dependency,
    shader_module: *std.Build.Module,
    weeoui_vitellus: *std.Build.Module,
};

/// Publish Eggy's modules (`eggy`, `eggy_runtime`, and `eggy_editor` on desktop) and the runtime
/// libraries games install beside their executables. Null until Slang has been fetched.
fn addEngine(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emscripten: Emscripten) ?Engine {
    // The web build renders with WebGPU, takes WGSL, and is linked by emcc instead of Zig.
    const web = target.result.os.tag == .emscripten;
    const vitellus = b.dependency("vitellus", .{
        .target = target,
        .optimize = optimize,
        .dx12 = true,
        .vk = !web,
        .emsdk = emscripten.emsdk,
        .enable_slang = true,
    });

    // Built-in shaders: WGSL on the web, SPIR-V elsewhere.
    const viewport_shader = b.path("src/core/shaders/viewport3d.slang");
    const viewport_vertex = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "vertexMain", .vertex) orelse return null;
    const viewport_fragment = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "fragmentMain", .fragment) orelse return null;
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
    const fatal_dialog = b.createModule(.{ .root_source_file = b.path("src/core/fatal_dialog.zig"), .target = target, .optimize = optimize, .link_libc = true });
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

    // eggy: the engine games and plugins import, for every platform.
    const engine = b.addModule("eggy", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("vitellus", vitellus.module("vitellus"));
    engine.addImport("vitellus_spirv", vitellus.module("vitellus_spirv"));
    engine.addImport("eggenvector", emath.module("eggenvector"));
    engine.addImport("weeoui", weeoui.module("weeoui"));
    engine.addImport("fatal_dialog", fatal_dialog);
    // Weeoui's renderer compiled against Eggy's own Vitellus (its -Dvitellus would fetch a second copy).
    const weeoui_vitellus = b.createModule(.{
        .root_source_file = weeoui.path("src/vitellus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "weeoui", .module = weeoui.module("weeoui") }, .{ .name = "vitellus", .module = vitellus.module("vitellus") }, .{ .name = "vitellus_spirv", .module = vitellus.module("vitellus_spirv") } },
    });
    engine.addImport("weeoui_vitellus", weeoui_vitellus);
    engine.addImport("vitellus_slangc", vitellus.module("vitellus_slangc"));
    engine.addImport("scene_shaders", shader_module);
    engine.addImport("sdl3", sdl3.module("sdl3"));
    engine.addImport("vitellus_sdl3", sdl_adapter);
    engine.link_libc = true;
    // Libraries loaded at runtime, for `installRuntimeLibraries`: Vitellus's (DXC, Slang), and on
    // Windows AccessKit's DLL, which Weeoui links.
    var vitellus_libraries = vitellus.builder.named_lazy_paths.iterator();
    while (vitellus_libraries.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, runtime_library_prefix)) b.addNamedLazyPath(entry.key_ptr.*, entry.value_ptr.*);
    }
    if (target.result.os.tag == .windows) b.addNamedLazyPath(runtime_library_prefix ++ "bin/accesskit.dll", weeoui.namedLazyPath("accesskit_dll"));
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
    addMacSdk(b, engine);

    // eggy_runtime: runs a game and its plugins, for every platform.
    _ = b.addModule("eggy_runtime", .{
        .root_source_file = b.path("src/runtime/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "eggy", .module = engine }},
    });

    // eggy_editor: a game with Weeoui tooling over it, desktop only.
    if (!web) {
        // Weeoui's SDL adapter compiled against Eggy's SDL and Vitellus, so neither is built twice.
        const weeoui_sdl3 = b.createModule(.{
            .root_source_file = weeoui.path("src/sdl3.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weeoui", .module = weeoui.module("weeoui") },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "vitellus", .module = vitellus.module("vitellus") },
                .{ .name = "vitellus_sdl3", .module = sdl_adapter },
                .{ .name = "weeoui_vitellus", .module = weeoui_vitellus },
            },
        });
        _ = b.addModule("eggy_editor", .{
            .root_source_file = b.path("src/editor/editor.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "eggy", .module = engine },
                .{ .name = "weeoui_sdl3", .module = weeoui_sdl3 },
                .{ .name = "weeoui_vitellus", .module = weeoui_vitellus },
            },
        });
    }

    return .{
        .eggy = engine,
        .fatal_dialog = fatal_dialog,
        .vitellus = vitellus,
        .weeoui = weeoui,
        .sdl3 = sdl3,
        .shader_module = shader_module,
        .weeoui_vitellus = weeoui_vitellus,
    };
}

const runtime_library_prefix = "runtime:";

/// Install the libraries Eggy's executables load at runtime (published by `addEngine`) into `b`'s prefix.
fn installRuntimeLibraries(b: *std.Build, engine: *std.Build) void {
    var it = engine.named_lazy_paths.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, runtime_library_prefix)) continue;
        b.getInstallStep().dependOn(&b.addInstallFile(entry.value_ptr.*, entry.key_ptr.*[runtime_library_prefix.len..]).step);
    }
}

const DesktopApp = struct { install: *std.Build.Step.InstallArtifact, run: *std.Build.Step.Run };

/// Executable `name` from `root_module`: installed with `zig build`, and runnable on its own.
fn addDesktopApp(b: *std.Build, target: std.Build.ResolvedTarget, root_module: *std.Build.Module, name: []const u8) DesktopApp {
    const exe = b.addExecutable(.{ .name = name, .root_module = root_module, .use_llvm = true });
    addMacSdk(b, exe.root_module);
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // Run the installed copy, so libraries installed beside it (DXC, Slang, AccessKit) are found.
    const file_name = if (target.result.os.tag == .windows) b.fmt("{s}.exe", .{name}) else name;
    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, file_name)});
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    return .{ .install = install, .run = run };
}

/// `zig build test-core`: the engine's tests, the fatal dialog's, and the 3D scene's.
fn addCoreTests(b: *std.Build, engine: Engine) *std.Build.Step {
    const step = b.step("test-core", "Run eggy's core tests");
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = engine.eggy, .use_llvm = true })).step);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = engine.fatal_dialog, .use_llvm = true })).step);
    const viewport = b.createModule(.{
        .root_source_file = b.path("src/core/viewport3d.zig"),
        .target = engine.eggy.resolved_target,
        .optimize = engine.eggy.optimize,
        .imports = &.{
            .{ .name = "vitellus", .module = engine.vitellus.module("vitellus") },
            .{ .name = "vitellus_spirv", .module = engine.vitellus.module("vitellus_spirv") },
            .{ .name = "weeoui", .module = engine.weeoui.module("weeoui") },
            .{ .name = "sdl3", .module = engine.sdl3.module("sdl3") },
            .{ .name = "scene_shaders", .module = engine.shader_module },
            .{ .name = "weeoui_vitellus", .module = engine.weeoui_vitellus },
        },
    });
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = viewport, .use_llvm = true })).step);
    return step;
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
