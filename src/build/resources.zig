//! A game's resources as its runtime gets them, beside what `models.zig` converts: the scene it
//! starts in (`mainScene`), and every other file of `resources/` (scenes, sounds, text...)
//! copied as it is into `<prefix>/data/` (`addCopies`), where the runtime reads them.
const std = @import("std");
const Kind = @import("../core/assets/kind.zig").Kind;
const descriptor = @import("../core/assets/descriptor.zig");

/// The scene the game starts in, relative to the project: `eggy.zon`'s `.main_scene`, else the
/// scene the editor has open (`.eggy/scene.zon`), else the first scene file in `resources/`;
/// null when the project has none.
pub fn mainScene(b: *std.Build) ?[]const u8 {
    const Chosen = struct { main_scene: ?[]const u8 = null, scene: ?[]const u8 = null };
    for ([_][]const u8{ "eggy.zon", ".eggy/scene.zon" }) |file| {
        const source = b.build_root.handle.readFileAllocOptions(b.graph.io, file, b.allocator, .limited(64 * 1024), .of(u8), 0) catch continue;
        const chosen = std.zon.parse.fromSliceAlloc(Chosen, b.allocator, source, null, .{ .ignore_unknown_fields = true }) catch continue;
        const path = chosen.main_scene orelse chosen.scene orelse continue;
        b.build_root.handle.access(b.graph.io, path, .{}) catch continue;
        return path;
    }
    for (files(b)) |path| if (Kind.of(path) == .scene) return path;
    return null;
}

/// Install every file of the project's `resources/` that packaging doesn't convert (models and
/// textures) into `<prefix>/data/`, as it is; null when there are none.
pub fn addCopies(b: *std.Build) ?*std.Build.Step {
    const step = b.step("eggy-resources", "Copy the game's resources beside it");
    var any = false;
    for (files(b)) |path| {
        if (Kind.of(path) == .model or Kind.isTexture(path)) continue;
        step.dependOn(&b.addInstallFileWithDir(b.path(path), .prefix, b.fmt("data/{s}", .{path})).step);
        any = true;
    }
    return if (any) step else null;
}

/// Every file in the project's `resources/` but descriptors, relative to the project with `/`
/// between parts, sorted.
fn files(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    var found: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, "resources", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file or descriptor.isDescriptor(entry.basename)) continue;
        const path = std.mem.replaceOwned(u8, b.allocator, entry.path, std.fs.path.sep_str, "/") catch @panic("OOM");
        found.append(b.allocator, b.fmt("resources/{s}", .{path})) catch @panic("OOM");
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    return found.items;
}
