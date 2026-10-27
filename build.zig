const std = @import("std");
const package_root = @import("src/build/package_root.zig");
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
const game_plugins = @import("src/build/game_plugins.zig");
const mingw_fortify = @import("src/build/mingw_fortify.zig");
const builtin_plugins = @import("src/build/builtin_plugins.zig");
const audio_build = @import("src/build/audio.zig");

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
    const emsdk = sdk_setup.prepare(b, target, b.option([]const u8, "emsdk", "Use this installed emsdk instead of automatically setting it up"), b.option([]const u8, "android-sdk", "Use this Android SDK instead of Eggy's cached SDK"));
    const emscripten = Emscripten.init(b, emsdk);
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
    // The plugins inside Eggy, each on its own.
    for (engine.plugins) |plugin| test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = plugin, .use_llvm = true })).step);
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
                .{ .name = "better_dynlib", .module = b.dependency("better_dynlib", .{ .target = target }).module("better_dynlib") },
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
    /// Plugin modules, each declaring `pub const Plugin`. Eggy runs them after the game, in order,
    /// then `dev_plugins`, then those installed from the editor's Plugins window (`eggy.zon`).
    plugins: []const *std.Build.Module = &.{},
    /// Plugins that help make the game, such as editor tools: the editor and `zig build
    /// run-runtime` run them, but `zig build export` leaves them out of the game it ships.
    dev_plugins: []const *std.Build.Module = &.{},
    /// Default: `-Dtarget`.
    target: ?std.Build.ResolvedTarget = null,
    /// Default: `-Doptimize`.
    optimize: ?std.builtin.Optimize = null,
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
    const engine = eggyDependency(b, target, optimize).builder;
    // A copy of `$EMSDK`: plugins' Eggy dependencies re-run SDK setup, which frees the map's old value.
    const emsdk = if (b.graph.environ_map.get("EMSDK")) |path| b.dupe(path) else null;
    _ = addProject(b, engine, Emscripten.init(b, emsdk), target, optimize, options, options.name);
}

pub const PluginOptions = struct {
    /// The module's name: games use it as `b.dependency(<package>, .{}).module(name)`.
    name: []const u8,
    /// The plugin's root, which declares `pub const Plugin`. By convention `src/root.zig`.
    root_source_file: std.Build.LazyPath,
    /// Default: `-Dtarget`.
    target: ?std.Build.ResolvedTarget = null,
    /// Default: `-Doptimize`.
    optimize: ?std.builtin.Optimize = null,
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
fn eggyDependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Dependency {
    // The macOS SDK to cross-compile with, kept where Eggy's SDL and the export's inner build
    // find it (see `sdl.zig`), before Eggy is configured. An option is declared once a build.
    const declared = struct {
        var macos_sdk = false;
    };
    if (!declared.macos_sdk) {
        declared.macos_sdk = true;
        if (b.option([]const u8, "macos-sdk", "The macOS SDK folder, to build for macOS from another system")) |sdk|
            b.graph.environ_map.put(sdl_build.macos_sdk_variable, sdk) catch @panic("OOM");
    }
    return b.dependencyFromBuildZig(@This(), .{ .target = target, .optimize = optimize });
}

/// `addGame` for any builder: `engine` is Eggy's own builder, which is `b` itself for Eggy's own
/// executables. The runtime executable is `runtime_name`; the editor is `<options.name>_editor`.
/// Returns the editor's game library; null on the web, which has no editor.
fn addProject(b: *std.Build, engine: *std.Build, emscripten: Emscripten, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, options: GameOptions, runtime_name: []const u8) ?*std.Build.Step.Compile {
    // Missing until Eggy's lazy dependencies are fetched; Zig then runs the build again.
    const eggy = engine.modules.get("eggy") orelse return null;
    const runtime = engine.modules.get("eggy_runtime").?;
    const own = b == engine;
    const files = if (own) &.{} else game_resources.entries(b);
    const prepared = models.prepare(b, engine, target, optimize, files) orelse return null;

    // The project module: the game's name and its plugin types, the game first. The editor's
    // game library has every plugin; the runtime leaves dev plugins out when exporting.
    options.game.addImport("eggy", eggy);
    const dev_plugins = b.option(bool, "dev-plugins", "Build the runtime with dev plugins (default: true; export leaves them out)") orelse true;
    const plugins = game_plugins.collect(b, engine, target, optimize, options.plugins, options.dev_plugins, dev_plugins) orelse return null;
    var all_modules: std.ArrayList(*std.Build.Module) = .empty;
    var all_keys: std.ArrayList([]const u8) = .empty;
    var runtime_modules: std.ArrayList(*std.Build.Module) = .empty;
    var runtime_keys: std.ArrayList([]const u8) = .empty;
    for (plugins, 0..) |plugin, i| {
        plugin.module.addImport("eggy", eggy);
        const key = pluginKey(b, plugin.module, i);
        all_modules.append(b.allocator, plugin.module) catch @panic("OOM");
        all_keys.append(b.allocator, key) catch @panic("OOM");
        if (!dev_plugins and plugin.dev) continue;
        runtime_modules.append(b.allocator, plugin.module) catch @panic("OOM");
        runtime_keys.append(b.allocator, key) catch @panic("OOM");
    }
    const project = b.createModule(.{ .root_source_file = b.addWriteFiles().add("eggy_project.zig", projectSource(b, options.name, all_modules.items.len, all_keys.items).items), .target = target, .optimize = optimize });
    project.addImport("game", options.game);
    project.addImport("eggy_asset_ids", prepared.ids);
    for (all_modules.items, 0..) |plugin, i| project.addImport(b.fmt("plugin_{d}", .{i}), plugin);

    // The runtime's project module also carries the project's preferences (`.eggy/plugins`),
    // baked in. The editor's game library doesn't, so changing them doesn't rebuild it.
    // It starts in the project's main scene (none for Eggy's own executables, whose resources
    // are the editor's).
    var source = projectSource(b, options.name, runtime_modules.items.len, runtime_keys.items);
    const scene_option = b.option([]const u8, "scene", "The scene the game starts in (default: eggy.zon's .default_scene); export needs one");
    const main_scene = if (own) null else game_resources.mainScene(b, files, scene_option, false);
    if (main_scene) |path| source.print(b.allocator, "pub const main_scene: ?[]const u8 = \"{s}\";\n", .{game_resources.sceneKey(b, files, path)}) catch @panic("OOM");
    // And what its executable says about itself, which it keeps in a section of its own.
    const metadata = if (own) &.{} else game_metadata.read(b);
    if (metadata.len > 0) source.print(b.allocator, "pub const metadata_text = \"{f}\".*;\n", .{std.zig.fmtString(game_metadata.text(b, metadata))}) catch @panic("OOM");
    // And its icon, which the desktop runtime puts on its window from the packaged image.
    const icon_path = if (own) null else game_metadata.iconPath(b);
    const icon_key = if (icon_path) |path| game_resources.imageKey(b, files, path) else null;
    if (icon_key) |key| if (target.result.os.tag != .emscripten and !target.result.abi.isAndroid()) {
        source.print(b.allocator, "pub const icon: []const u8 = \"{s}\";\n", .{key}) catch @panic("OOM");
    };
    @import("src/build/render_settings.zig").appendDefaults(b, &source, own);
    const runtime_project = b.createModule(.{ .root_source_file = addPreferenceFiles(b, source.items), .target = target, .optimize = optimize });
    runtime_project.addImport("game", options.game);
    runtime_project.addImport("eggy_asset_ids", prepared.ids);
    for (runtime_modules.items, 0..) |plugin, i| runtime_project.addImport(b.fmt("plugin_{d}", .{i}), plugin);

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
    // Building for macOS elsewhere: the SDK's frameworks and libraries, which the runtime links.
    if (target.result.os.tag == .macos and !target.query.isNativeOs()) if (b.graph.environ_map.get(sdl_build.macos_sdk_variable)) |sdk| {
        runtime_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        runtime_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    };
    const all_step = b.step("all", "Build every executable for this target");
    game_export.addExport(b, engine, target, runtime_name, if (own) null else game_resources.mainScene(b, files, scene_option, true));
    build_runner.record(b);
    if (target.result.os.tag == .emscripten) {
        const data: ?std.Build.LazyPath = for (files) |file| {
            if (file.kind != .folder) break prepared.directory;
        } else null;
        const app = web_build.addApp(b, engine, emscripten, runtime_module, runtime_name, data);
        b.step("runtime", "Build the game for the browser").dependOn(&app.install.step);
        b.step("run", "Open the game in a browser").dependOn(&app.run.step);
        all_step.dependOn(&app.install.step);
        return null;
    }
    if (target.result.abi.isAndroid()) {
        const android = engine.lazyImport(@This(), "android") orelse return null;
        android_build.addApp(b, engine, android, runtime_module, runtime_name, prepared.directory, icon_path);
        return null;
    }
    // A released game ships without Windows debug symbols beside it.
    const runtime_app = addDesktopApp(b, target, runtime_module, runtime_name, optimize == .debug);
    // The executable's own icon, which Windows shows for it, from the same packaged image.
    const icon_ico = if (icon_key != null and target.result.os.tag == .windows) game_metadata.icoFrom(b, engine, prepared.directory.path(b, icon_key.?)) else null;
    game_metadata.addTo(b, runtime_app.install.artifact, metadata, icon_ico);
    const runtime_step = b.step("runtime", "Build the game");
    runtime_step.dependOn(&runtime_app.install.step);
    const runtime_libraries = installRuntimeLibraries(b, engine);
    runtime_step.dependOn(runtime_libraries);
    all_step.dependOn(runtime_libraries);
    // The same prepared payloads back native installation and mobile/browser bundling.
    const packaged = &b.addInstallDirectory(.{ .source_dir = prepared.directory, .install_dir = .prefix, .install_subdir = "data" }).step;
    runtime_step.dependOn(packaged);
    runtime_app.run.step.dependOn(packaged);
    b.getInstallStep().dependOn(packaged);
    all_step.dependOn(packaged);
    b.step("run-runtime", "Run the game").dependOn(&runtime_app.run.step);
    all_step.dependOn(&runtime_app.install.step);

    // The editor, desktop only. It loads the game and its plugins from a library of their own,
    // and swaps in a rebuilt one when their code changes, so its project module has the name only.
    const game_library = addGameLibrary(b, engine, target, optimize, project, options.name);
    const library_options = b.addOptions();
    library_options.addOption([]const u8, "file_name", game_library.out_filename);
    const editor_project = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("eggy_editor_project.zig", b.fmt("pub const name = \"{f}\";\npub const asset_ids = @import(\"eggy_asset_ids\");\npub const game_library = @import(\"game_library\");\n", .{std.zig.fmtString(options.name)})),
        .target = target,
        .optimize = optimize,
    });
    editor_project.addOptions("game_library", library_options);
    editor_project.addImport("eggy_asset_ids", prepared.ids);
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
    const editor_app = addDesktopApp(b, target, editor_module, b.fmt("{s}_editor", .{options.name}), true);
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

/// The project module's start: the game's `name`, its asset ids, and the plugin types (the game
/// first, then `plugin_count` plugins, imported as `plugin_<index>`) with their `keys`.
fn projectSource(b: *std.Build, name: []const u8, plugin_count: usize, keys: []const []const u8) std.ArrayList(u8) {
    var source: std.ArrayList(u8) = .empty;
    source.print(b.allocator, "pub const name = \"{f}\";\npub const asset_ids = @import(\"eggy_asset_ids\");\npub const plugins = .{{ @import(\"game\").Game", .{std.zig.fmtString(name)}) catch @panic("OOM");
    for (0..plugin_count) |i| source.print(b.allocator, ", @import(\"plugin_{d}\").Plugin", .{i}) catch @panic("OOM");
    source.appendSlice(b.allocator, " };\n") catch @panic("OOM");
    // Whose preferences each is (`plugins/<key>.zon`): the game's are `game`, a plugin's are its
    // module's name, as its package publishes it with `addPlugin`.
    source.appendSlice(b.allocator, "pub const plugin_keys = [_][:0]const u8{ \"game\"") catch @panic("OOM");
    for (keys) |key| source.print(b.allocator, ", \"{f}\"", .{std.zig.fmtString(key)}) catch @panic("OOM");
    source.appendSlice(b.allocator, " };\n") catch @panic("OOM");
    return source;
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
    if (package_root.open(b).openDir(io, ".eggy/plugins", .{ .iterate = true })) |opened| {
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
    if (package_root.open(b).access(io, @import("src/core/project.zig").controls_file, .{})) {
        _ = files.addCopyFile(b.path(@import("src/core/project.zig").controls_file), "controls.zon");
        source.appendSlice(b.allocator, "pub const input_bindings = @embedFile(\"controls.zon\");\n") catch @panic("OOM");
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot read controls.zon: {t}", .{err}),
    }
    if (package_root.open(b).access(io, ".eggy/plugins.zon", .{})) {
        _ = files.addCopyFile(b.path(".eggy/plugins.zon"), "plugins.zon");
        source.appendSlice(b.allocator, "pub const plugin_registry = @embedFile(\"plugins.zon\");\n") catch @panic("OOM");
    } else |_| {}
    return files.add("eggy_project.zig", source.items);
}

/// The game and its plugins (`project`) as a shared library for the editor, which loads it and
/// swaps in a rebuilt one while it runs (see `src/editor/hot_reload`).
fn addGameLibrary(b: *std.Build, engine: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, project: *std.Build.Module, name: []const u8) *std.Build.Step.Compile {
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
    vitellus: *std.Build.Dependency,
    weeoui: *std.Build.Dependency,
    sdl3: *std.Build.Dependency,
    shader_module: *std.Build.Module,
    weeoui_vitellus: *std.Build.Module,
    assets: *std.Build.Module,
    plugins: []const *std.Build.Module,
};

/// Publish Eggy's modules (`eggy`, `eggy_runtime`, and `eggy_editor` on desktop) and the runtime
/// libraries games install beside their executables. Null until Slang has been fetched.
fn addEngine(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, emscripten: Emscripten) ?Engine {
    // The web build renders with WebGPU, takes WGSL, and is linked by emcc instead of Zig.
    const web = target.result.os.tag == .emscripten;
    // On Windows DirectX 12 comes first, running the SPIR-V shaders through SPIRV-Cross and DXC.
    const windows = target.result.os.tag == .windows;
    const android = target.result.abi.isAndroid();
    // Slang's prebuilt library, which compiles shaders at run time, is glibc-only on Linux.
    const slang = !android and (target.result.os.tag != .linux or target.result.abi.isGnu());
    const vitellus = b.dependency("vitellus", .{
        .target = target,
        .optimize = optimize,
        .dx12 = true,
        .enable_dxc = windows,
        .enable_spirv_cross = windows,
        .vk = !web,
        .emsdk = emscripten.emsdk,
        .enable_slang = slang,
    });

    // Built-in shaders: WGSL on the web, SPIR-V elsewhere.
    const viewport_shader = b.path("src/core/shaders/viewport3d.slang");
    const viewport_vertex = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "vertexMain", .vertex) orelse return null;
    const viewport_fragment = vitellus_build.compileSlang(b, vitellus, target, viewport_shader, "fragmentMain", .fragment) orelse return null;
    const mesh_shader = b.path("src/core/shaders/mesh.slang");
    const mesh_vertex = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "vertexMain", .vertex) orelse return null;
    const mesh_fragment = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "fragmentMain", .fragment) orelse return null;
    const mesh_shadow_fragment = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "fragmentShadow", .fragment) orelse return null;
    const outline_vertex = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "vertexOutline", .vertex) orelse return null;
    const outline_fragment = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "fragmentOutline", .fragment) orelse return null;
    const mask_vertex = vitellus_build.compileSlang(b, vitellus, target, mesh_shader, "vertexMask", .vertex) orelse return null;
    const blit_shader = b.path("src/core/shaders/scene_blit.slang");
    const blit_vertex = vitellus_build.compileSlang(b, vitellus, target, blit_shader, "vertexMain", .vertex) orelse return null;
    const blit_fragment = vitellus_build.compileSlang(b, vitellus, target, blit_shader, "fragmentMain", .fragment) orelse return null;
    const grid_shader = b.path("src/core/shaders/grid.slang");
    const grid_vertex = vitellus_build.compileSlang(b, vitellus, target, grid_shader, "vertexMain", .vertex) orelse return null;
    const grid_fragment = vitellus_build.compileSlang(b, vitellus, target, grid_shader, "fragmentMain", .fragment) orelse return null;
    const world_shader = b.path("src/core/shaders/world_draw.slang");
    const world_vertex = vitellus_build.compileSlang(b, vitellus, target, world_shader, "vertexMain", .vertex) orelse return null;
    const world_fragment = vitellus_build.compileSlang(b, vitellus, target, world_shader, "fragmentMain", .fragment) orelse return null;
    const resolve_shader = b.path("src/core/shaders/scene_resolve.slang");
    const resolve_vertex = vitellus_build.compileSlang(b, vitellus, target, resolve_shader, "vertexMain", .vertex) orelse return null;
    const resolve_fragment = vitellus_build.compileSlang(b, vitellus, target, resolve_shader, "fragmentMain", .fragment) orelse return null;
    const shader_files = b.addWriteFiles();
    _ = shader_files.addCopyFile(viewport_vertex, "viewport3d.vert");
    _ = shader_files.addCopyFile(viewport_fragment, "viewport3d.frag");
    _ = shader_files.addCopyFile(mesh_vertex, "mesh.vert");
    _ = shader_files.addCopyFile(mesh_fragment, "mesh.frag");
    _ = shader_files.addCopyFile(mesh_shadow_fragment, "mesh_shadow.frag");
    _ = shader_files.addCopyFile(outline_vertex, "outline.vert");
    _ = shader_files.addCopyFile(outline_fragment, "outline.frag");
    _ = shader_files.addCopyFile(mask_vertex, "mask.vert");
    _ = shader_files.addCopyFile(blit_vertex, "scene_blit.vert");
    _ = shader_files.addCopyFile(blit_fragment, "scene_blit.frag");
    _ = shader_files.addCopyFile(grid_vertex, "grid.vert");
    _ = shader_files.addCopyFile(grid_fragment, "grid.frag");
    _ = shader_files.addCopyFile(world_vertex, "world.vert");
    _ = shader_files.addCopyFile(world_fragment, "world.frag");
    _ = shader_files.addCopyFile(resolve_vertex, "scene_resolve.vert");
    _ = shader_files.addCopyFile(resolve_fragment, "scene_resolve.frag");
    const shader_module = b.createModule(.{
        .root_source_file = shader_files.add("root.zig",
            \\pub const viewport_vertex = @embedFile("viewport3d.vert");
            \\pub const viewport_fragment = @embedFile("viewport3d.frag");
            \\pub const mesh_vertex = @embedFile("mesh.vert");
            \\pub const mesh_fragment = @embedFile("mesh.frag");
            \\pub const mesh_shadow_fragment = @embedFile("mesh_shadow.frag");
            \\pub const outline_vertex = @embedFile("outline.vert");
            \\pub const outline_fragment = @embedFile("outline.frag");
            \\pub const mask_vertex = @embedFile("mask.vert");
            \\pub const blit_vertex = @embedFile("scene_blit.vert");
            \\pub const blit_fragment = @embedFile("scene_blit.frag");
            \\pub const grid_vertex = @embedFile("grid.vert");
            \\pub const grid_fragment = @embedFile("grid.frag");
            \\pub const world_vertex = @embedFile("world.vert");
            \\pub const world_fragment = @embedFile("world.frag");
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
    // SDL's Java activity from the release zig-sdl3 builds natively, so their JNI signatures agree.
    if (android) b.addNamedLazyPath("android_java", (b.lazyDependency("sdl_android_java", .{}) orelse return null).path("android-project/app/src/main/java"));
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
    const slangc = if (slang) vitellus.module("vitellus_slangc") else blk: {
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
    // Sound: miniaudio decodes, mixes and places voices in 3D; SDL plays the mix.
    engine.linkLibrary(audio_build.addMixer(b, target, optimize, if (web) emscripten.include else null));
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
    mingw_fortify.disable(engine, target, optimize);

    // eggy_runtime: runs a game and its plugins, for every platform.
    _ = b.addModule("eggy_runtime", .{
        .root_source_file = b.path("src/runtime/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "eggy", .module = engine }},
    });
    // The plugins inside Eggy (`plugins/`), which projects install from the editor.
    const plugins = builtin_plugins.publish(b, target, optimize, engine);

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
                // std.DynLib has no Windows support; the editor loads the game library through this.
                .{ .name = "better_dynlib", .module = b.dependency("better_dynlib", .{ .target = target }).module("better_dynlib") },
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
        // Eggy's fingerprint, which the plugins inside it name (see `plugin_manifest`).
        build_options.addOption(u64, "fingerprint", @import("build.zig.zon").fingerprint);
        const source_dir = package_root.absolute(b);
        build_options.addOption([]const u8, "source_dir", source_dir);
        editor.addOptions("build_options", build_options);
        editor.addAnonymousImport("mono_font", .{ .root_source_file = b.path("resources/fonts/JetBrainsMono-Regular.ttf") });
        // Icons for private-use characters (Nerd Font glyphs) the UI and monospace faces lack
        // (MIT; see resources/fonts/SymbolsNerdFont-LICENSE.txt).
        editor.addAnonymousImport("symbols_font", .{ .root_source_file = b.path("resources/fonts/SymbolsNerdFontMono-Regular.ttf") });
        // The plugins inside Eggy, as its Plugins window lists them.
        editor.addImport("eggy_builtin_plugins", builtin_plugins.embedded(b));
        // Model files, imported through assimp in a library of its own, installed beside the editor.
        const importer = models.addImporter(b, target, optimize, assets) orelse return null;
        editor.addImport("eggy_model_import", importer.module);
        b.addNamedLazyPath(b.fmt(editor_library_prefix ++ "{s}", .{models.installedPath(target.result, importer.library)}), importer.library.getEmittedBin());
    }

    return .{
        .eggy = engine,
        .vitellus = vitellus,
        .weeoui = weeoui,
        .sdl3 = sdl3,
        .shader_module = shader_module,
        .weeoui_vitellus = weeoui_vitellus,
        .assets = assets,
        .plugins = plugins,
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
    step.dependOn(packTarball(b, engine, tool, ".", &.{ "build.zig", "build.zig.zon", "plugins", "resources", "src" }, "eggy.tar"));
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
    var dir = package_root.open(engine).openDir(io, root, .{ .iterate = true }) catch |err| std.debug.panic("cannot open {s}: {t}", .{ root, err });
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

/// Executable `name` from `root_module`: installed with `zig build` (with its `.pdb` on Windows
/// when `with_pdb`), and runnable on its own.
fn addDesktopApp(b: *std.Build, target: std.Build.ResolvedTarget, root_module: *std.Build.Module, name: []const u8, with_pdb: bool) DesktopApp {
    const exe = b.addExecutable(.{ .name = name, .root_module = root_module, .use_llvm = true });
    const install = b.addInstallArtifact(exe, .{ .pdb_dir = if (with_pdb) .default else .disabled });
    b.getInstallStep().dependOn(&install.step);

    // Run the installed copy, so libraries installed beside it (DXC, Slang, AccessKit) are found.
    const file_name = if (target.result.os.tag == .windows) b.fmt("{s}.exe", .{name}) else name;
    const run = b.addRunFile(b.graph.path(.install_bin, file_name));
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    return .{ .install = install, .run = run };
}

/// `zig build test-core`: the engine's tests, the 3D scene's, and the icon tool's.
fn addCoreTests(b: *std.Build, engine: Engine) *std.Build.Step {
    const step = b.step("test-core", "Run eggy's core tests");
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = engine.eggy, .use_llvm = true })).step);
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
    // The build tool that makes a Windows game's executable icon.
    const ico = b.createModule(.{ .root_source_file = b.path("src/build/ico.zig"), .target = engine.eggy.resolved_target, .optimize = engine.eggy.optimize, .imports = &.{.{ .name = "eggy_assets", .module = engine.assets }} });
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ico, .use_llvm = true })).step);
    return step;
}
