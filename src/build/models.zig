//! Models in the build: `eggy_assimp`, the shared library the editor imports model files with,
//! and packaging, which converts a game's model files to `.eggmodel` for its runtime (installed
//! into `<prefix>/data/`, where the runtime looks).
const std = @import("std");
const assimp = @import("assimp.zig");
const Kind = @import("../core/assets/kind.zig").Kind;

/// `eggy_assimp` and the `eggy_model_import` module, which links it.
pub const Importer = struct {
    library: *std.Build.Step.Compile,
    module: *std.Build.Module,
};

/// The `eggy_assets` module for `target`, made with `eggy`, Eggy's own builder.
pub fn assetsModule(eggy: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const s2s = eggy.dependency("s2s", .{ .target = target, .optimize = optimize });
    return eggy.createModule(.{
        .root_source_file = eggy.path("src/core/assets/assets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "s2s", .module = s2s.module("s2s") }},
    });
}

/// The importer for `target`, built with `eggy` (Eggy's builder), using `assets` (an
/// `assetsModule`, the one everything else in the compilation imports). Null until assimp has
/// been fetched; Zig then runs the build again.
pub fn addImporter(eggy: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, assets: *std.Build.Module) ?Importer {
    const source = eggy.lazyDependency("assimp", .{}) orelse return null;
    const built = assimp.build(eggy, source, target, optimize);

    // assimp's C API, for the library's Zig.
    const translated = eggy.addTranslateC(.{ .root_source_file = eggy.path("src/model_import/assimp.h"), .target = target, .optimize = optimize });
    translated.addIncludePath(built.include);
    translated.addConfigHeader(built.config);

    const library = eggy.addLibrary(.{
        .name = "eggy_assimp",
        .linkage = .dynamic,
        .root_module = eggy.createModule(.{
            .root_source_file = eggy.path("src/model_import/library.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            .imports = &.{
                .{ .name = "assimp", .module = translated.createModule() },
                .{ .name = "eggy_assets", .module = assets },
            },
        }),
        .use_llvm = true,
    });
    library.root_module.linkLibrary(built.library);

    const module = eggy.createModule(.{
        .root_source_file = eggy.path("src/model_import/model_import.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "eggy_assets", .module = assets }},
    });
    module.linkLibrary(library);
    return .{ .library = library, .module = module };
}

/// Where a game installs `library` (a shared library) beside its executables, which find it there.
pub fn installedPath(target: std.Target, library: *std.Build.Step.Compile) []const u8 {
    const owner = library.step.owner;
    return if (target.os.tag == .windows) owner.fmt("bin/{s}", .{library.out_filename}) else owner.fmt("lib/{s}", .{library.out_filename});
}

/// Packaging for the game `b` builds: each model file in its `resources/` converted to
/// `<prefix>/data/<path>.eggmodel`, by a tool built with `eggy` for the machine building. Null
/// when the game has no models (so assimp isn't built for it), or until assimp is fetched.
pub fn addPackaging(b: *std.Build, eggy: *std.Build, optimize: std.builtin.OptimizeMode) ?*std.Build.Step {
    const models = findModels(b);
    if (models.len == 0) return null;
    const host = eggy.graph.host;
    const assets = assetsModule(eggy, host, optimize);
    const importer = addImporter(eggy, host, optimize, assets) orelse return null;
    const tool = eggy.addExecutable(.{
        .name = "eggy_package_models",
        .root_module = eggy.createModule(.{
            .root_source_file = eggy.path("src/model_import/package.zig"),
            .target = host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "eggy_assets", .module = assets },
                .{ .name = "eggy_model_import", .module = importer.module },
            },
        }),
        .use_llvm = true,
    });

    // Each model and its descriptor is an input, so changing either packages again.
    const package = b.addRunArtifact(tool);
    package.addArg(b.build_root.handle.realPathFileAlloc(b.graph.io, ".", b.allocator) catch |err| std.debug.panic("cannot resolve the project's directory: {t}", .{err}));
    const output = package.addOutputDirectoryArg("models");
    for (models) |path| {
        package.addArg(path);
        package.addFileInput(b.path(path));
        if (b.build_root.handle.access(b.graph.io, b.fmt("{s}.eggy", .{path}), .{})) {
            package.addFileInput(b.path(b.fmt("{s}.eggy", .{path})));
        } else |_| {}
    }
    return &b.addInstallDirectory(.{ .source_dir = output, .install_dir = .prefix, .install_subdir = "data" }).step;
}

/// The model files in `b`'s project's `resources/`, relative to the project with `/` between
/// parts, sorted so the same files always package the same way.
fn findModels(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    var models: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, "resources", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file or Kind.of(entry.basename) != .model) continue;
        const path = std.mem.replaceOwned(u8, b.allocator, entry.path, std.fs.path.sep_str, "/") catch @panic("OOM");
        models.append(b.allocator, b.fmt("resources/{s}", .{path})) catch @panic("OOM");
    }
    std.mem.sort([]const u8, models.items, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    return models.items;
}
