//! A game's resources as its runtime gets them: every file of `resources/` in `<prefix>/data/`,
//! named after its descriptor's id, never after itself, with `data/manifest.zon` to find each by
//! its path (`addData`; models and textures converted by `models.zig`, everything else copied as
//! it is); and the scene the game starts in (`mainScene`).
const std = @import("std");
const assets_manifest = @import("../core/assets/manifest.zig");
const descriptor = @import("../core/assets/descriptor.zig");
const Kind = @import("../core/assets/kind.zig").Kind;
const Entry = assets_manifest.Entry;

/// The scene the game starts in, relative to the project: `scene` (`-Dscene`), else `eggy.zon`'s
/// `.default_scene`, else (unless `exporting`, which must be told) the scene the editor has open
/// (`.eggy/scene.zon`), else the first scene file in `resources/`; null when there is none.
/// Build-internal; returned text is borrowed from `scene` or allocated in `b`'s arena.
/// An explicit scene is returned unchanged; invalid/missing saved configuration is skipped.
/// This chooses a path, not scene contents, and does not update project settings.
///
/// ```zig
/// const startup = resources.mainScene(b, b.option([]const u8, "scene", "Startup scene"), false);
/// project_options.addOption(?[]const u8, "main_scene", startup);
/// ```
pub fn mainScene(b: *std.Build, scene: ?[]const u8, exporting: bool) ?[]const u8 {
    if (scene) |path| return path;
    const Chosen = struct { default_scene: ?[]const u8 = null, scene: ?[]const u8 = null };
    const sources: []const []const u8 = if (exporting) &.{"eggy.zon"} else &.{ "eggy.zon", ".eggy/scene.zon" };
    for (sources) |file| {
        const source = b.build_root.handle.readFileAllocOptions(b.graph.io, file, b.allocator, .limited(64 * 1024), .of(u8), 0) catch continue;
        const chosen = std.zon.parse.fromSliceAlloc(Chosen, b.allocator, source, null, .{ .ignore_unknown_fields = true }) catch continue;
        const path = chosen.default_scene orelse chosen.scene orelse continue;
        b.build_root.handle.access(b.graph.io, path, .{}) catch continue;
        return path;
    }
    if (exporting) return null;
    for (entries(b)) |entry| if (Kind.of(entry.path) == .scene) return entry.path;
    return null;
}

/// Every file of the project's `resources/` but descriptors, with its descriptor's id (one from
/// its path when it has none yet), sorted by path.
/// The array and paths live in `b`'s arena. Missing/unopenable resource directories produce
/// an empty list; invalid descriptors fall back to path IDs. No descriptors are written.
///
/// ```zig
/// const files = resources.entries(b);
/// if (resources.addData(b, files)) |step| runtime_step.dependOn(step);
/// ```
pub fn entries(b: *std.Build) []const Entry {
    const io = b.graph.io;
    var found: std.ArrayList(Entry) = .empty;
    var dir = b.build_root.handle.openDir(io, "resources", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch null) |item| {
        if (item.kind != .file or descriptor.isDescriptor(item.basename)) continue;
        const relative = std.mem.replaceOwned(u8, b.allocator, item.path, std.fs.path.sep_str, "/") catch @panic("OOM");
        const path = b.fmt("resources/{s}", .{relative});
        const read = descriptor.read(b.allocator, io, b.build_root.handle, path) catch null;
        const id = if (read) |known| known.id else assets_manifest.pathId(path);
        found.append(b.allocator, .{ .path = path, .id = id }) catch @panic("OOM");
    }
    std.mem.sort(Entry, found.items, {}, struct {
        fn before(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.before);
    return found.items;
}

/// Install the manifest and every file packaging copies as it is (all but models and textures)
/// into `<prefix>/data/`, each under its packaged name; null when the project has no resources.
/// Build-internal; returns a graph-owned step to attach to runtime installation. Models/images
/// still appear in the manifest but need `models.addPackaging` for their converted bytes.
///
/// ```zig
/// if (resources.addData(b, resources.entries(b))) |step| {
///     runtime_step.dependOn(step);
/// }
/// ```
pub fn addData(b: *std.Build, files: []const Entry) ?*std.Build.Step {
    if (files.len == 0) return null;
    const step = b.step("eggy-data", "Put the game's resources beside it");
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = dataDirectory(b, files), .install_dir = .prefix, .install_subdir = "data" }).step);
    return step;
}

/// Manifest and unchanged resources in one build-owned directory, also usable as APK assets.
pub fn dataDirectory(b: *std.Build, files: []const Entry) std.Build.LazyPath {
    const output = b.addWriteFiles();
    var text: std.Io.Writer.Allocating = .init(b.allocator);
    assets_manifest.write(&text.writer, .{ .files = files }) catch @panic("OOM");
    _ = output.add(assets_manifest.file_name, text.written());
    for (files) |entry| {
        if (assets_manifest.Packaged.of(entry.path) != .copy) continue;
        var name: [32]u8 = undefined;
        _ = output.addCopyFile(b.path(entry.path), assets_manifest.packagedName(&name, entry));
    }
    return output.getDirectory();
}

/// All runtime resources beneath `data/`, ready for APK assets or an Emscripten preload.
pub fn bundledDirectory(b: *std.Build, engine: *std.Build, optimize: std.builtin.OptimizeMode, files: []const Entry) std.Build.LazyPath {
    const output = b.addWriteFiles();
    _ = output.addCopyDirectory(dataDirectory(b, files), "data", .{});
    if (@import("models.zig").packagedDirectory(b, engine, optimize, files)) |converted|
        _ = output.addCopyDirectory(converted, "data", .{});
    return output.getDirectory();
}
