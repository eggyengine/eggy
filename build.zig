const std = @import("std");
const vitellus_build = @import("vitellus");
const Emscripten = vitellus_build.Emscripten;
const models = @import("src/build/models.zig");
const game_export = @import("src/build/export.zig");
const build_runner = @import("src/build/runner.zig");
const game_resources = @import("src/build/resources.zig");
const game_metadata = @import("src/build/metadata.zig");
const sdl_build = @import("src/build/sdl.zig");
const sdk_setup = @import("src/build/sdk_setup.zig");
const android_build = @import("src/build/android.zig");
const web_build = @import("src/build/web.zig");

/// Configure Eggy's own runtime/editor, tests, package resources and API-reference steps.
/// Zig owns `b` and invokes this once per build-graph evaluation; games use `addGame` instead.
/// Dependency fetches can restart configuration, and missing platform SDKs fail explicitly.
///
/// ```sh
/// zig build all
/// zig build test
/// zig build docs --prefix docs/static
/// ```
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
    const emsdk = sdk_setup.prepare(b, target, b.option([]const u8, "emsdk", "Use this installed emsdk instead of automatically setting it up"), b.option([]const u8, "android-sdk", "Use this Android SDK instead of Eggy's cached SDK"));
    const emscripten = Emscripten.init(b, target, emsdk);
    // On a fresh checkout Slang isn't fetched yet: Zig fetches it and runs this build again.
    const engine = addEngine(b, target, optimize, emscripten) orelse return;

    // Eggy's own executables, eggy_runtime and eggy_editor: an empty project, built exactly as
    // `addGame` builds a game.
    const empty_game = b.addWriteFiles().add("game.zig", "pub const Game = struct {};\n");
    const demo = b.option(enum { weeoui, custom }, "api-demo", "Exercise developer APIs with a Weeoui HUD or custom-renderer-only game");
    const game = b.createModule(.{ .root_source_file = if (demo != null) b.path("src/build/api_fixture.zig") else empty_game, .target = target, .optimize = optimize });
    if (demo) |mode| {
        const options = b.addOptions();
        options.addOption(bool, "custom_ui", mode == .custom);
        game.addOptions("api_fixture_options", options);
        game.addAnonymousImport("api_fixture_font", .{ .root_source_file = b.path("resources/fonts/JetBrainsMono-Regular.ttf") });
    }
    const demo_plugins: []const *std.Build.Module = if (demo != null) &.{b.addModule("api_fixture_plugin", .{
        .root_source_file = b.path("resources/template/src/root.zig"),
        .target = target,
        .optimize = optimize,
    })} else &.{};
    _ = addProject(b, b, emscripten, target, optimize, .{
        .name = "eggy",
        .game = game,
        .plugins = demo_plugins,
    }, "eggy_runtime");

    // `zig build docs`: the `eggy` module's API reference, Zig's own docs, into `<prefix>/api`.
    // The docs site publishes it beside the guides.
    const docs_object = b.addObject(.{ .name = "eggy", .root_module = engine.eggy });
    b.step("docs", "Build the eggy module's API reference into api/").dependOn(&b.addInstallDirectory(.{ .source_dir = docs_object.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "api" }).step);

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
        // Importing models through `eggy_assimp`, for real.
        if (editor.import_table.get("eggy_model_import")) |model_import| editor_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = model_import, .use_llvm = true })).step);

        // Hot reload, for real: load the empty game's library, run it, swap it, and unload it.
        const library_options = b.addOptions();
        const fixture = @import("src/build/api_checks.zig").project(b, target, optimize, engine.eggy);
        const fixture_library = addGameLibrary(b, b, target, optimize, fixture, "eggy_api_test");
        library_options.addOptionPath("path", fixture_library.getEmittedBin());
        const hot_reload_tests = &b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor/hot_reload_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "eggy", .module = engine.eggy },
                .{ .name = "test_library", .module = library_options.createModule() },
            },
        }), .use_llvm = true })).step;
        editor_tests.dependOn(hot_reload_tests);
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

/// Build a game made with Eggy (a package's `src/main.zig`): its runtime, its editor (desktop
/// only), and the steps `all`, `runtime`, `editor`, `run` (the editor; on the web, the runtime in
/// a browser) and `run-runtime`. The game and each plugin get `@import("eggy")`, this package's
/// eggy even for plugins from other packages, so every part shares one engine. Web builds find
/// installed emsdk through `$EMSDK`, then `~/emsdk`; missing Web/Android SDKs are set up
/// automatically. `export` builds the game to ship (`src/build/export.zig`).
/// Call once from a game's `build`, with a module declaring `pub const Game`; the build
/// graph owns all resulting modules and steps. Options' target/optimization default to
/// the caller's standard build options. See `GameOptions` for plugin ordering.
///
/// ```zig
/// const game = b.createModule(.{
///     .root_source_file = b.path("src/main.zig"),
///     .target = b.standardTargetOptions(.{}),
///     .optimize = b.standardOptimizeOption(.{}),
/// });
/// @import("eggy").addGame(b, .{ .name = "my_game", .game = game });
/// ```
pub fn addGame(b: *std.Build, options: GameOptions) void {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    _ = addProject(b, eggyDependency(b, target, optimize).builder, Emscripten.init(b, target, null), target, optimize, options, options.name);
}

pub const PluginOptions = struct {
    /// The module's name: games use it as `b.dependency(<package>, .{}).module(name)`.
    name: []const u8,
    /// The plugin's root, which declares `pub const Plugin`. By convention `src/root.zig`.
    root_source_file: std.Build.LazyPath,
    /// Default: `-Dtarget`.
    target: ?std.Build.ResolvedTarget = null,
    /// Default: `-Doptimize`.
    optimize: ?std.builtin.OptimizeMode = null,
};

/// Publish a plugin or library (a package's `src/root.zig`) as module `name`, with
/// `@import("eggy")`, so it compiles and tests on its own and other packages can depend on it.
/// A game that lists it gets this package's plugin running on the game's own eggy.
/// The returned module is owned by `b`'s build graph; publishing it does not enable the plugin
/// in a game. Supply it in `GameOptions.plugins` there. Use the same engine dependency
/// arguments for games and plugins, rather than adding divergent Eggy options.
///
/// ```zig
/// const plugin = @import("eggy").addPlugin(b, .{
///     .name = "my_plugin",
///     .root_source_file = b.path("src/root.zig"),
/// });
/// const tests = b.addTest(.{ .root_module = plugin });
/// b.step("test", "Run plugin tests").dependOn(&b.addRunArtifact(tests).step);
/// ```
pub fn addPlugin(b: *std.Build, options: PluginOptions) *std.Build.Module {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    const plugin = b.addModule(options.name, .{ .root_source_file = options.root_source_file, .target = target, .optimize = optimize });
    // Missing until eggy's lazy dependencies are fetched; Zig then runs the build again.
    if (eggyDependency(b, target, optimize).builder.modules.get("eggy")) |eggy| plugin.addImport("eggy", eggy);
    return plugin;
}

/// Eggy as a dependency of `b`. `addGame` and `addPlugin` pass the same arguments, so a package
/// that calls both gets one eggy, and the game's and plugin's `eggy.App` are the same type.
fn eggyDependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Dependency {
    return b.dependencyFromBuildZig(@This(), .{ .target = target, .optimize = optimize });
}

/// `addGame` for any builder: `engine` is Eggy's own builder, which is `b` itself for Eggy's own
/// executables. The runtime executable is `runtime_name`; the editor is `<options.name>_editor`.
/// Returns the editor's game library; null on the web, which has no editor.
fn addProject(b: *std.Build, engine: *std.Build, emscripten: Emscripten, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: GameOptions, runtime_name: []const u8) ?*std.Build.Step.Compile {
    // Missing until Eggy's lazy dependencies are fetched; Zig then runs the build again.
    const eggy = engine.modules.get("eggy") orelse return null;
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
    // Whose preferences each is (`plugins/<key>.zon`): the game's are `game`, a plugin's are its
    // module's name, as its package publishes it with `addPlugin`.
    source.appendSlice(b.allocator, "pub const plugin_keys = [_][:0]const u8{ \"game\"") catch @panic("OOM");
    for (options.plugins, 0..) |plugin, i| source.print(b.allocator, ", \"{f}\"", .{std.zig.fmtString(pluginKey(b, plugin, i))}) catch @panic("OOM");
    source.appendSlice(b.allocator, " };\n") catch @panic("OOM");
    const project = b.createModule(.{ .root_source_file = b.addWriteFiles().add("eggy_project.zig", source.items), .target = target, .optimize = optimize });
    project.addImport("game", options.game);
    for (options.plugins, 0..) |plugin, i| project.addImport(b.fmt("plugin_{d}", .{i}), plugin);

    // The runtime's project module also carries the project's preferences (`.eggy/plugins`),
    // baked in. The editor's game library doesn't, so changing them doesn't rebuild it.
    // It starts in the project's main scene (none for Eggy's own executables, whose resources
    // are the editor's).
    const own = b == engine;
    const scene_option = b.option([]const u8, "scene", "The scene the game starts in (default: eggy.zon's .default_scene); export needs one");
    const main_scene = if (own) null else game_resources.mainScene(b, scene_option, false);
    if (main_scene) |path| source.print(b.allocator, "pub const main_scene: ?[]const u8 = \"{f}\";\n", .{std.zig.fmtString(path)}) catch @panic("OOM");
    // And what its executable says about itself, which it keeps in a section of its own.
    const metadata = if (own) &.{} else game_metadata.read(b);
    if (metadata.len > 0) source.print(b.allocator, "pub const metadata_text = \"{f}\".*;\n", .{std.zig.fmtString(game_metadata.text(b, metadata))}) catch @panic("OOM");
    @import("src/build/render_settings.zig").appendDefaults(b, &source, own);
    const runtime_project = b.createModule(.{ .root_source_file = addPreferenceFiles(b, source.items), .target = target, .optimize = optimize });
    runtime_project.addImport("game", options.game);
    for (options.plugins, 0..) |plugin, i| runtime_project.addImport(b.fmt("plugin_{d}", .{i}), plugin);

    // The runtime, on every platform.
    const runtime_module = b.createModule(.{
        .root_source_file = engine.path("src/runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "eggy", .module = eggy },
            .{ .name = "eggy_runtime", .module = runtime },
            .{ .name = "eggy_project", .module = runtime_project },
            .{ .name = "weeoui_sdl3", .module = eggy.import_table.get("weeoui_sdl3").? },
        },
    });
    const all_step = b.step("all", "Build every executable for this target");
    game_export.addExport(b, engine, target, runtime_name, if (own) null else game_resources.mainScene(b, scene_option, true));
    build_runner.record(b);
    if (target.result.os.tag == .emscripten) {
        const app = web_build.addApp(b, engine, emscripten, runtime_module, runtime_name, if (own) &.{} else game_resources.entries(b));
        b.step("runtime", "Build the game for the browser").dependOn(&app.install.step);
        b.step("run", "Open the game in a browser").dependOn(&app.run.step);
        all_step.dependOn(&app.install.step);
        return null;
    }
    if (target.result.abi.isAndroid()) {
        const android = engine.lazyImport(@This(), "android") orelse return null;
        android_build.addApp(b, engine, android, runtime_module, runtime_name, if (own) &.{} else game_resources.entries(b));
        return null;
    }
    const runtime_app = addDesktopApp(b, target, runtime_module, runtime_name);
    game_metadata.addTo(b, runtime_app.install.artifact, metadata);
    const runtime_step = b.step("runtime", "Build the game");
    runtime_step.dependOn(&runtime_app.install.step);
    const runtime_libraries = installRuntimeLibraries(b, engine);
    runtime_step.dependOn(runtime_libraries);
    all_step.dependOn(runtime_libraries);
    // Its resources: models and textures converted, everything else copied, all into data/.
    const files = if (own) &.{} else game_resources.entries(b);
    for ([_]?*std.Build.Step{ models.addPackaging(b, engine, optimize, files), game_resources.addData(b, files) }) |found| if (found) |packaged| {
        runtime_step.dependOn(packaged);
        runtime_app.run.step.dependOn(packaged);
        b.getInstallStep().dependOn(packaged);
    };
    b.step("run-runtime", "Run the game").dependOn(&runtime_app.run.step);
    all_step.dependOn(&runtime_app.install.step);

    // The editor, desktop only. It loads the game and its plugins from a library of their own,
    // and swaps in a rebuilt one when their code changes, so its project module has the name only.
    const game_library = addGameLibrary(b, engine, target, optimize, project, options.name);
    const library_options = b.addOptions();
    library_options.addOption([]const u8, "file_name", game_library.out_filename);
    const editor_project = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("eggy_editor_project.zig", b.fmt("pub const name = \"{f}\";\npub const game_library = @import(\"game_library\");\n", .{std.zig.fmtString(options.name)})),
        .target = target,
        .optimize = optimize,
    });
    editor_project.addOptions("game_library", library_options);
    const editor_module = b.createModule(.{
        .root_source_file = engine.path("src/editor/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "eggy", .module = eggy },
            .{ .name = "eggy_editor", .module = engine.modules.get("eggy_editor").? },
            .{ .name = "eggy_project", .module = editor_project },
        },
    });
    const editor_app = addDesktopApp(b, target, editor_module, b.fmt("{s}_editor", .{options.name}));
    editor_app.run.setCwd(b.path("."));
    const resources = installEditorResources(b, engine);
    // Beside the editor on every platform, where it looks for it.
    const install_library = b.addInstallArtifact(game_library, .{ .dest_dir = .{ .override = .bin }, .implib_dir = .disabled, .pdb_dir = .disabled });
    const editor_step = b.step("editor", "Build the editor");
    editor_step.dependOn(runtime_libraries);
    editor_step.dependOn(&editor_app.install.step);
    const editor_libraries = installEditorLibraries(b, engine);
    editor_step.dependOn(editor_libraries);
    editor_step.dependOn(&install_library.step);
    editor_step.dependOn(resources);
    editor_app.run.step.dependOn(&install_library.step);
    b.step("run", "Run the editor").dependOn(&editor_app.run.step);
    all_step.dependOn(&editor_app.install.step);
    all_step.dependOn(editor_libraries);
    all_step.dependOn(&install_library.step);
    all_step.dependOn(resources);
    return game_library;
}

/// The name `plugin`'s package published it under (`addPlugin`). A plugin in the project's own
/// source (a module made with `createModule`) is named after its file (`src/stats.zig`: `stats`),
/// unless that is just `root` or `main`; failing all that, `plugin_<index>`.
fn pluginKey(b: *std.Build, plugin: *std.Build.Module, index: usize) []const u8 {
    var it = plugin.owner.modules.iterator();
    while (it.next()) |entry| if (entry.value_ptr.* == plugin) return entry.key_ptr.*;
    if (plugin.root_source_file) |root| if (root == .src_path) {
        const stem = std.fs.path.stem(root.src_path.sub_path);
        if (!std.mem.eql(u8, stem, "root") and !std.mem.eql(u8, stem, "main")) return stem;
    };
    return b.fmt("plugin_{d}", .{index});
}

/// `project_source` (the project module's) with `preference_files` added: each of the project's
/// `.eggy/plugins/<key>.zon`, embedded, for the runtime to read at start; and, when it has one,
/// `plugin_registry`: its `.eggy/plugins.zon`, which says which plugins are on (see
/// `eggy.plugins.registry_file`). Project-root `controls.zon` supplies input-map overrides.
fn addPreferenceFiles(b: *std.Build, project_source: []const u8) std.Build.LazyPath {
    const io = b.graph.io;
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    source.appendSlice(b.allocator, project_source) catch @panic("OOM");
    source.appendSlice(b.allocator, "pub const preference_files = [_]struct { key: []const u8, zon: [:0]const u8 }{\n") catch @panic("OOM");
    if (b.build_root.handle.openDir(io, ".eggy/plugins", .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
            const key = entry.name[0 .. entry.name.len - ".zon".len];
            _ = files.addCopyFile(b.path(b.pathJoin(&.{ ".eggy", "plugins", entry.name })), b.pathJoin(&.{ "preferences", entry.name }));
            source.print(b.allocator, "    .{{ .key = \"{f}\", .zon = @embedFile(\"preferences/{f}\") }},\n", .{ std.zig.fmtString(key), std.zig.fmtString(entry.name) }) catch @panic("OOM");
        }
    } else |_| {}
    source.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    if (b.build_root.handle.access(io, @import("src/core/project.zig").controls_file, .{})) {
        _ = files.addCopyFile(b.path(@import("src/core/project.zig").controls_file), "controls.zon");
        source.appendSlice(b.allocator, "pub const input_bindings = @embedFile(\"controls.zon\");\n") catch @panic("OOM");
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot read controls.zon: {t}", .{err}),
    }
    if (b.build_root.handle.access(io, ".eggy/plugins.zon", .{})) {
        _ = files.addCopyFile(b.path(".eggy/plugins.zon"), "plugins.zon");
        source.appendSlice(b.allocator, "pub const plugin_registry = @embedFile(\"plugins.zon\");\n") catch @panic("OOM");
    } else |_| {}
    return files.add("eggy_project.zig", source.items);
}

/// The game and its plugins (`project`) as a shared library for the editor, which loads it and
/// swaps in a rebuilt one while it runs (see `src/editor/hot_reload`).
fn addGameLibrary(b: *std.Build, engine: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, project: *std.Build.Module, name: []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = engine.path("src/editor/hot_reload/library.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .imports = &.{
            .{ .name = "eggy", .module = engine.modules.get("eggy").? },
            .{ .name = "eggy_project", .module = project },
        },
    });
    return b.addLibrary(.{ .linkage = .dynamic, .name = b.fmt("{s}_game", .{name}), .root_module = module, .use_llvm = true });
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
    assets: *std.Build.Module,
};

/// Publish Eggy's modules (`eggy`, `eggy_runtime`, and `eggy_editor` on desktop) and the runtime
/// libraries games install beside their executables. Null until Slang has been fetched.
fn addEngine(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emscripten: Emscripten) ?Engine {
    // The web build renders with WebGPU, takes WGSL, and is linked by emcc instead of Zig.
    const web = target.result.os.tag == .emscripten;
    // On Windows DirectX 12 comes first, running the SPIR-V shaders through SPIRV-Cross and DXC.
    const windows = target.result.os.tag == .windows;
    const android = target.result.abi.isAndroid();
    const vitellus = b.dependency("vitellus", .{
        .target = target,
        .optimize = optimize,
        .dx12 = true,
        .enable_dxc = windows,
        .enable_spirv_cross = windows,
        .vk = !web,
        .emsdk = emscripten.emsdk,
        .enable_slang = !android,
    });

    // Built-in shaders: WGSL on the web, SPIR-V elsewhere.
    const viewport_shader = b.path("src/core/shaders/viewport3d.slang");
    const viewport_vertex = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "vertexMain", .vertex) orelse return null;
    const viewport_fragment = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "fragmentMain", .fragment) orelse return null;
    const mesh_shader = b.path("src/core/shaders/mesh.slang");
    const mesh_vertex = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "vertexMain", .vertex) orelse return null;
    const mesh_fragment = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "fragmentMain", .fragment) orelse return null;
    const outline_vertex = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "vertexOutline", .vertex) orelse return null;
    const outline_fragment = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "fragmentOutline", .fragment) orelse return null;
    const mask_vertex = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "vertexMask", .vertex) orelse return null;
    const blit_shader = b.path("src/core/shaders/scene_blit.slang");
    const blit_vertex = vitellus_build.compileSlang(b, vitellus, target, blit_shader, "vertexMain", .vertex) orelse return null;
    const blit_fragment = vitellus_build.compileSlang(b, vitellus, target, blit_shader, "fragmentMain", .fragment) orelse return null;
    const grid_shader = b.path("src/core/shaders/grid.slang");
    const grid_vertex = vitellus_build.compileSlang(b, vitellus, target, grid_shader, "vertexMain", .vertex) orelse return null;
    const grid_fragment = vitellus_build.compileSlang(b, vitellus, target, grid_shader, "fragmentMain", .fragment) orelse return null;
    const resolve_shader = b.path("src/core/shaders/scene_resolve.slang");
    const resolve_vertex = vitellus_build.compileSlang(b, vitellus, target, resolve_shader, "vertexMain", .vertex) orelse return null;
    const resolve_fragment = vitellus_build.compileSlang(b, vitellus, target, resolve_shader, "fragmentMain", .fragment) orelse return null;
    const shader_files = b.addWriteFiles();
    _ = shader_files.addCopyFile(viewport_vertex, "viewport3d.vert");
    _ = shader_files.addCopyFile(viewport_fragment, "viewport3d.frag");
    _ = shader_files.addCopyFile(mesh_vertex, "mesh.vert");
    _ = shader_files.addCopyFile(mesh_fragment, "mesh.frag");
    _ = shader_files.addCopyFile(outline_vertex, "outline.vert");
    _ = shader_files.addCopyFile(outline_fragment, "outline.frag");
    _ = shader_files.addCopyFile(mask_vertex, "mask.vert");
    _ = shader_files.addCopyFile(blit_vertex, "scene_blit.vert");
    _ = shader_files.addCopyFile(blit_fragment, "scene_blit.frag");
    _ = shader_files.addCopyFile(grid_vertex, "grid.vert");
    _ = shader_files.addCopyFile(grid_fragment, "grid.frag");
    _ = shader_files.addCopyFile(resolve_vertex, "scene_resolve.vert");
    _ = shader_files.addCopyFile(resolve_fragment, "scene_resolve.frag");
    const shader_module = b.createModule(.{
        .root_source_file = shader_files.add("root.zig",
            \\pub const viewport_vertex = @embedFile("viewport3d.vert");
            \\pub const viewport_fragment = @embedFile("viewport3d.frag");
            \\pub const mesh_vertex = @embedFile("mesh.vert");
            \\pub const mesh_fragment = @embedFile("mesh.frag");
            \\pub const outline_vertex = @embedFile("outline.vert");
            \\pub const outline_fragment = @embedFile("outline.frag");
            \\pub const mask_vertex = @embedFile("mask.vert");
            \\pub const blit_vertex = @embedFile("scene_blit.vert");
            \\pub const blit_fragment = @embedFile("scene_blit.frag");
            \\pub const grid_vertex = @embedFile("grid.vert");
            \\pub const grid_fragment = @embedFile("grid.frag");
            \\pub const resolve_vertex = @embedFile("scene_resolve.vert");
            \\pub const resolve_fragment = @embedFile("scene_resolve.frag");
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    const emath = b.dependency("eggenvector", .{ .target = target, .optimize = optimize });
    // Eggy wires Weeoui's SDL adapter below, against the same SDL as the game.
    const weeoui = b.dependency("weeoui", .{ .target = target, .optimize = optimize, .sdl3 = false });
    if (android) b.addNamedLazyPath("android_java", weeoui.path("examples/android/java"));
    const nvdialog = b.dependency("nvdialog", .{});
    const fatal_dialog = b.createModule(.{ .root_source_file = b.path("src/core/fatal_dialog.zig"), .target = target, .optimize = optimize, .link_libc = true });
    if (!web and !android) addNvdialog(b, fatal_dialog, nvdialog, target.result);
    const sdl3 = sdl_build.dependency(b, target, optimize, if (web) emscripten.include else null) orelse return null;
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
    engine.addImport("clutch", b.dependency("clutch", .{ .target = target, .optimize = optimize }).module("clutch"));
    engine.addImport("weeoui", weeoui.module("weeoui"));
    engine.addImport("fatal_dialog", fatal_dialog);
    const assets = models.assetsModule(b, target, optimize);
    // Tools can import the formats without linking App, SDL, the renderer, or editor code.
    b.modules.put(b.allocator, "eggy_assets", assets) catch @panic("OOM");
    engine.addImport("eggy_assets", assets);
    // Weeoui's renderer compiled against Eggy's own Vitellus (its -Dvitellus would fetch a second copy).
    const weeoui_vitellus = b.createModule(.{
        .root_source_file = weeoui.path("src/vitellus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "weeoui", .module = weeoui.module("weeoui") }, .{ .name = "vitellus", .module = vitellus.module("vitellus") }, .{ .name = "vitellus_spirv", .module = vitellus.module("vitellus_spirv") } },
    });
    engine.addImport("weeoui_vitellus", weeoui_vitellus);
    const slangc = if (!android) vitellus.module("vitellus_slangc") else blk: {
        const disabled = b.addOptions();
        disabled.addOption(bool, "available", false);
        const module = b.createModule(.{
            .root_source_file = vitellus.path("src/slangc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "vitellus", .module = vitellus.module("vitellus") }},
        });
        module.addOptions("slang_options", disabled);
        break :blk module;
    };
    engine.addImport("vitellus_slangc", slangc);
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
            if (!android) engine.linkSystemLibrary("unwind", .{});
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

    // One SDL adapter for game UI and editor tools, sharing Eggy's existing SDL and device.
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
    engine.addImport("weeoui_sdl3", weeoui_sdl3);

    // eggy_runtime: runs a game and its plugins, for every platform.
    _ = b.addModule("eggy_runtime", .{
        .root_source_file = b.path("src/runtime/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "eggy", .module = engine }},
    });

    // eggy_editor: a game with Weeoui tooling over it, desktop only.
    if (!web and !android) {
        const cli = b.lazyDependency("cli", .{ .target = target, .optimize = optimize }) orelse return null;
        const editor = b.addModule("eggy_editor", .{
            .root_source_file = b.path("src/editor/editor.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "eggy", .module = engine },
                .{ .name = "weeoui_sdl3", .module = weeoui_sdl3 },
                .{ .name = "weeoui_vitellus", .module = weeoui_vitellus },
                .{ .name = "cli", .module = cli.module("cli") },
            },
        });
        // The window icon: the original 256x256 pixel art (resources/icon.svg is the same egg as vector).
        editor.addAnonymousImport("editor_icon", .{ .root_source_file = b.path("resources/icon.png") });
        // The editor's monospace face, for terminal output (OFL; see resources/fonts/OFL.txt).
        // Eggy's version, for the editor's status bar, and where this Eggy is, so an editor built
        // from a checkout can offer it to projects (File > Link Developer Eggy).
        const build_options = b.addOptions();
        build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
        build_options.addOption([]const u8, "zig_version", @import("build.zig.zon").minimum_zig_version);
        const source_dir = b.build_root.handle.realPathFileAlloc(b.graph.io, ".", b.allocator) catch |err| std.debug.panic("cannot resolve Eggy's directory: {t}", .{err});
        build_options.addOption([]const u8, "source_dir", source_dir);
        editor.addOptions("build_options", build_options);
        editor.addAnonymousImport("mono_font", .{ .root_source_file = b.path("resources/fonts/JetBrainsMono-Regular.ttf") });
        // Model files, imported through assimp in a library of its own, installed beside the editor.
        const importer = models.addImporter(b, target, optimize, assets) orelse return null;
        editor.addImport("eggy_model_import", importer.module);
        b.addNamedLazyPath(b.fmt(editor_library_prefix ++ "{s}", .{models.installedPath(target.result, importer.library)}), importer.library.getEmittedBin());
    }

    return .{
        .eggy = engine,
        .fatal_dialog = fatal_dialog,
        .vitellus = vitellus,
        .weeoui = weeoui,
        .sdl3 = sdl3,
        .shader_module = shader_module,
        .weeoui_vitellus = weeoui_vitellus,
        .assets = assets,
    };
}

/// What the editor ships in `<prefix>/resources/`, as tarballs it unpacks when it creates a
/// project: `template.tar`, the new-project template (`resources/template/`), and `eggy.tar`,
/// Eggy's own package, which new projects build against. Returns the step that installs both.
fn installEditorResources(b: *std.Build, engine: *std.Build) *std.Build.Step {
    const tool = engine.addExecutable(.{
        .name = "tar",
        .root_module = engine.createModule(.{ .root_source_file = engine.path("src/build/tar.zig"), .target = engine.graph.host }),
    });
    const step = b.step("editor-resources", "Pack the editor's resources");
    step.dependOn(packTarball(b, engine, tool, "resources/template", &.{}, "template.tar"));
    // The package as `zig fetch` would see it (build.zig.zon's `.paths`), less the submodules,
    // which are dependencies fetched by URL.
    step.dependOn(packTarball(b, engine, tool, ".", &.{ "build.zig", "build.zig.zon", "resources", "src" }, "eggy.tar"));
    b.getInstallStep().dependOn(step);
    return step;
}

/// Pack `engine`'s directory `root` into `<prefix>/resources/<name>`, keeping only the top-level
/// entries in `only` when it is not empty. Build output and Git submodules are left out.
fn packTarball(b: *std.Build, engine: *std.Build, tool: *std.Build.Step.Compile, root: []const u8, only: []const []const u8, name: []const u8) *std.Build.Step {
    const io = b.graph.io;
    const pack = b.addRunArtifact(tool);
    const tarball = pack.addOutputFileArg(name);

    // List the files now, each as a file argument, so editing one repacks the tarball. They go in
    // sorted, so the same files always make the same tarball, whatever order the disk lists them.
    const File = struct { archive_path: []const u8, path: []const u8 };
    var files: std.ArrayList(File) = .empty;
    var dir = engine.build_root.handle.openDir(io, root, .{ .iterate = true }) catch |err| std.debug.panic("cannot open {s}: {t}", .{ root, err });
    defer dir.close(io);
    var walker = dir.walkSelectively(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("cannot list {s}: {t}", .{ root, err })) |entry| {
        const archive_path = std.mem.replaceOwned(u8, b.allocator, entry.path, std.fs.path.sep_str, "/") catch @panic("OOM");
        const top_level = std.mem.indexOfScalar(u8, archive_path, '/') == null;
        if (top_level and only.len > 0) {
            for (only) |kept| {
                if (std.mem.eql(u8, archive_path, kept)) break;
            } else continue;
        }
        switch (entry.kind) {
            .directory => {
                for ([_][]const u8{ ".zig-cache", "zig-out", "zig-pkg", "node_modules", ".git" }) |ignored| {
                    if (std.mem.eql(u8, entry.basename, ignored)) break;
                } else if (!isSubmodule(entry.dir, io, entry.basename)) {
                    walker.enter(io, entry) catch |err| std.debug.panic("cannot open {s}/{s}: {t}", .{ root, archive_path, err });
                }
            },
            .file => files.append(b.allocator, .{ .archive_path = archive_path, .path = b.pathJoin(&.{ root, entry.path }) }) catch @panic("OOM"),
            else => {},
        }
    }
    std.mem.sort(File, files.items, {}, struct {
        fn before(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.archive_path, y.archive_path);
        }
    }.before);
    for (files.items) |file| {
        pack.addArg(file.archive_path);
        pack.addFileArg(engine.path(file.path));
    }

    const install = &b.addInstallFileWithDir(tarball, .{ .custom = "resources" }, name).step;
    return install;
}

/// Whether directory `name` in `parent` is a Git submodule's checkout (it holds a `.git` file).
fn isSubmodule(parent: std.Io.Dir, io: std.Io, name: []const u8) bool {
    var dir = parent.openDir(io, name, .{}) catch return false;
    defer dir.close(io);
    const stat = dir.statFile(io, ".git", .{}) catch return false;
    return stat.kind == .file;
}

const runtime_library_prefix = "runtime:";
/// Like `runtime_library_prefix`, for libraries only the editor loads (`eggy_assimp`).
const editor_library_prefix = "editor:";

/// Install the libraries only the editor loads (published by `addEngine`) into `b`'s prefix.
/// Returns the step that does.
fn installEditorLibraries(b: *std.Build, engine: *std.Build) *std.Build.Step {
    const step = b.step("editor-libraries", "Install the libraries the editor loads");
    var it = engine.named_lazy_paths.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, editor_library_prefix)) continue;
        step.dependOn(&b.addInstallFile(entry.value_ptr.*, entry.key_ptr.*[editor_library_prefix.len..]).step);
    }
    b.getInstallStep().dependOn(step);
    return step;
}

/// Install the shared runtime libraries for either executable and exported games.
fn installRuntimeLibraries(b: *std.Build, engine: *std.Build) *std.Build.Step {
    const step = b.step("runtime-libraries", "Install the shared runtime libraries");
    var it = engine.named_lazy_paths.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, runtime_library_prefix)) continue;
        const install = &b.addInstallFile(entry.value_ptr.*, entry.key_ptr.*[runtime_library_prefix.len..]).step;
        step.dependOn(install);
    }
    b.getInstallStep().dependOn(step);
    return step;
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
            .{ .name = "eggenvector", .module = engine.eggy.import_table.get("eggenvector").? },
            .{ .name = "clutch", .module = engine.eggy.import_table.get("clutch").? },
            .{ .name = "eggy_assets", .module = engine.assets },
        },
    });
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = viewport, .use_llvm = true })).step);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = engine.assets, .use_llvm = true })).step);
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
    if (mod.resolved_target.?.result.os.tag != .macos) return;
    const sysroot = b.sysroot orelse return;
    mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
}
