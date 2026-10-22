//! Models and images in the build: `eggy_assimp`, the shared library the editor imports model
//! files and decodes images with, plus identity-addressed payloads and the compiled asset lookup.
const std = @import("std");
const assimp = @import("assimp.zig");
const mingw_fortify = @import("mingw_fortify.zig");
const package = @import("../core/assets/package.zig");
const registry = @import("../core/assets/registry.zig");
const asset_id = @import("../core/assets/id.zig");

/// `eggy_assimp` and the `eggy_model_import` module, which links it.
pub const Importer = struct {
    library: *std.Build.Step.Compile,
    module: *std.Build.Module,
};

/// The `eggy_assets` module for `target`, made with `eggy`, Eggy's own builder.
/// Build-internal; returns a graph-owned module independent of the engine/GPU, with the
/// matching s2s serialization dependency. Reuse this module within the compilation.
///
/// ```zig
/// const assets = models.assetsModule(engine_builder, target, optimize);
/// tool_module.addImport("eggy_assets", assets);
/// ```
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
/// Build-internal; the build graph owns both results. Link/import the returned module and
/// separately install its shared library using `installedPath` for deployed editors.
///
/// ```zig
/// const importer = models.addImporter(engine_builder, target, optimize, assets) orelse return;
/// editor_module.addImport("eggy_model_import", importer.module);
/// ```
pub fn addImporter(eggy: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, assets: *std.Build.Module) ?Importer {
    const source = eggy.lazyDependency("assimp", .{}) orelse return null;
    const built = assimp.build(eggy, source, target, optimize);

    // assimp's C API, for the library's Zig.
    const translated = eggy.addTranslateC(.{ .root_source_file = eggy.path("src/model_import/assimp.h"), .target = target, .optimize = optimize });
    translated.addIncludePath(built.include);
    translated.addIncludePath(source.path("contrib"));
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
    // stb_image, from assimp's copy, for images.
    library.root_module.addIncludePath(source.path("contrib"));
    library.root_module.addCSourceFile(.{ .file = eggy.path("src/model_import/stb_image.c"), .flags = &.{"-fno-sanitize=undefined"} });
    mingw_fortify.disable(library.root_module, target, optimize);

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
/// Returns a library-owner-build-allocated relative path: `bin/` on Windows, `lib/` elsewhere.
/// Does not create an install step or change the library's loader search path.
///
/// ```zig
/// const path = models.installedPath(target.result, importer.library);
/// b.getInstallStep().dependOn(&b.addInstallFile(importer.library.getEmittedBin(), path).step);
/// ```
pub fn installedPath(target: std.Target, library: *std.Build.Step.Compile) []const u8 {
    const owner = library.step.owner;
    return if (target.os.tag == .windows) owner.fmt("bin/{s}", .{library.out_filename}) else owner.fmt("lib/{s}", .{library.out_filename});
}

pub const Prepared = struct {
    directory: std.Build.LazyPath,
    ids: *std.Build.Module,
};

/// Produce payloads and their compile-time authoring aliases once for every target.
/// Imported clips require host conversion before game/library compilation, not a runtime index.
/// Null means a lazy importer dependency was requested and Zig will reevaluate the build.
pub fn prepare(b: *std.Build, eggy: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, files: []const package.Entry) ?Prepared {
    const converted = for (files) |entry| {
        if (entry.kind != .folder and package.Conversion.of(entry.path) != .copy) break true;
    } else false;
    if (!converted) {
        const output = b.addWriteFiles();
        var aliases = registry.Builder{ .gpa = b.allocator };
        defer aliases.deinit();
        for (files) |entry| aliases.claim(entry.id) catch |err| std.debug.panic("invalid asset catalog identity for {s}: {t}", .{ entry.path, err });
        for (files) |entry| {
            aliases.add(.{ .path = entry.path, .id = entry.id, .kind = entry.kind, .converted = false }) catch |err| std.debug.panic("invalid asset alias {s}: {t}", .{ entry.path, err });
            if (entry.kind == .folder) continue;
            var name: [asset_id.key_len]u8 = undefined;
            _ = output.addCopyFile(b.path(entry.path), asset_id.key(&name, entry.id));
        }
        return .{ .directory = output.getDirectory(), .ids = registryModule(b, target, optimize, &aliases) };
    }
    const host = eggy.graph.host;
    const assets = assetsModule(eggy, host, optimize);
    const importer = addImporter(eggy, host, optimize, assets) orelse return null;
    const tool = eggy.addExecutable(.{
        .name = "eggy_package_assets",
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

    // Every source and import setting participates in the same conversion/lookup cache key.
    const run = b.addRunArtifact(tool);
    run.addArg(b.build_root.handle.realPathFileAlloc(b.graph.io, ".", b.allocator) catch |err| std.debug.panic("cannot resolve the project's directory: {t}", .{err}));
    const output = run.addOutputDirectoryArg("assets");
    const ids = run.addOutputFileArg("asset_ids.zig");
    for (files) |entry| {
        var key: [asset_id.key_len]u8 = undefined;
        run.addArgs(&.{ entry.path, b.dupe(asset_id.key(&key, entry.id)), @tagName(entry.kind), b.fmt("{d}", .{entry.model.scale}) });
        if (entry.kind != .folder) run.addFileInput(b.path(entry.path));
    }
    return .{ .directory = output, .ids = b.createModule(.{ .root_source_file = ids, .target = target, .optimize = optimize }) };
}

fn registryModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, aliases: *const registry.Builder) *std.Build.Module {
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    aliases.write(&source.writer) catch @panic("OOM");
    return b.createModule(.{ .root_source_file = b.addWriteFiles().add("asset_ids.zig", source.written()), .target = target, .optimize = optimize });
}
