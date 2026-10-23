//! Project catalog inputs and startup-scene selection for identity-addressed runtime builds.
const std = @import("std");
const zon_file = @import("../core/assets/zon.zig");
const package_root = @import("package_root.zig");
const catalog_zig = @import("../core/assets/catalog.zig");
const asset_id = @import("../core/assets/id.zig");
const Entry = @import("../core/assets/package.zig").Entry;

/// Synchronize the hidden identity database once during build configuration.
/// Preserves migrated sidecar identities/settings; malformed metadata and I/O failures fail
/// the build. Returned source paths live in the build arena, independently of the catalog.
pub fn entries(b: *std.Build) []const Entry {
    var catalog = catalog_zig.Catalog.open(b.allocator, b.graph.io, package_root.open(b)) catch |err|
        std.debug.panic("cannot open .eggy/assets.zon: {t}", .{err});
    defer catalog.deinit();
    _ = catalog.sync(b.graph.io, package_root.open(b)) catch |err|
        std.debug.panic("cannot synchronize the project's asset catalog: {t}", .{err});
    var found: std.ArrayList(Entry) = .empty;
    for (catalog.view().entries) |entry| {
        if (!std.mem.eql(u8, entry.path, "resources") and !std.mem.startsWith(u8, entry.path, "resources/")) continue;
        found.append(b.allocator, .{
            .path = b.dupe(entry.path),
            .id = entry.id,
            .kind = entry.kind,
            .model = entry.model_import,
        }) catch @panic("OOM");
    }
    return found.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// Choose a source scene for authoring/export configuration. Both legacy paths and IDs
/// resolve against this build's catalog; the executable receives only `sceneKey`.
pub fn mainScene(b: *std.Build, files: []const Entry, scene: ?[]const u8, exporting: bool) ?[]const u8 {
    if (scene) |path| return sceneSource(files, path) orelse
        std.debug.panic("startup scene is not a catalogued scene: {s}", .{path});
    const Chosen = struct { default_scene: ?[]const u8 = null, scene: ?[]const u8 = null };
    const sources: []const []const u8 = if (exporting) &.{"eggy.zon"} else &.{ "eggy.zon", ".eggy/scene.zon" };
    for (sources) |file| {
        const source = package_root.open(b).readFileAllocOptions(b.graph.io, file, b.allocator, .limited(64 * 1024), .of(u8), 0) catch continue;
        const chosen = zon_file.parse(Chosen, b.allocator, source, .{ .ignore_unknown_fields = true }) catch continue;
        const path = chosen.default_scene orelse chosen.scene orelse continue;
        if (sceneSource(files, path)) |found| return found;
    }
    if (exporting) return null;
    for (files) |entry| if (entry.kind == .scene) return entry.path;
    return null;
}

/// Resolve the selected source scene to its canonical identity during build configuration.
pub fn sceneKey(b: *std.Build, files: []const Entry, path: []const u8) []const u8 {
    for (files) |entry| {
        if (entry.kind != .scene or !std.mem.eql(u8, entry.path, path)) continue;
        var key: [asset_id.key_len]u8 = undefined;
        return b.dupe(asset_id.key(&key, entry.id));
    }
    std.debug.panic("startup scene disappeared from the asset catalog: {s}", .{path});
}

/// The identity of the catalogued image at `path`, for the runtime to load it packaged; null,
/// with a warning, when `path` isn't one.
pub fn imageKey(b: *std.Build, files: []const Entry, path: []const u8) ?[]const u8 {
    for (files) |entry| {
        if (entry.kind != .image or !std.mem.eql(u8, entry.path, path)) continue;
        var key: [asset_id.key_len]u8 = undefined;
        return b.dupe(asset_id.key(&key, entry.id));
    }
    std.log.warn("the project's icon {s} isn't an image in resources/: the game's window has none", .{path});
    return null;
}

fn sceneSource(files: []const Entry, path: []const u8) ?[]const u8 {
    const identity: ?u64 = asset_id.parse(path) catch null;
    for (files) |entry| {
        if (entry.kind != .scene) continue;
        if (std.mem.eql(u8, entry.path, path) or (identity != null and identity.? == entry.id)) return entry.path;
    }
    return null;
}

/// Put the already prepared payloads under `data/` for Android assets or browser preloading.
pub fn bundledDirectory(b: *std.Build, prepared: std.Build.LazyPath) std.Build.LazyPath {
    const output = b.addWriteFiles();
    _ = output.addCopyDirectory(prepared, "data", .{});
    return output.getDirectory();
}
