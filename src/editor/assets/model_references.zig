//! The files a glTF model refers to beside itself (its textures and buffers), which importing it
//! brings along so it keeps its look.
const std = @import("std");

/// Whether `path` names a glTF model (`.gltf`, or binary `.glb`), whose references are files.
pub fn isGltf(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".gltf") or std.ascii.eqlIgnoreCase(extension, ".glb");
}

/// The files `model` (a `.gltf`'s text or a `.glb`'s bytes) refers to, relative to its folder and
/// `/` separated, in `arena`. Embedded data, absolute paths and paths leaving its folder are left
/// out. Fails with `error.InvalidModel` when it isn't glTF.
///
/// ```zig
/// for (try referencedFiles(arena, bytes)) |relative| std.debug.print("{s}\n", .{relative});
/// ```
pub fn referencedFiles(arena: std.mem.Allocator, model: []const u8) ![]const []const u8 {
    const Reference = struct { uri: ?[]const u8 = null };
    const Gltf = struct { images: []const Reference = &.{}, buffers: []const Reference = &.{} };
    const parsed = std.json.parseFromSliceLeaky(Gltf, arena, try jsonOf(model), .{ .ignore_unknown_fields = true }) catch return error.InvalidModel;

    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const Reference{ parsed.images, parsed.buffers }) |references| for (references) |reference| {
        const uri = reference.uri orelse continue;
        if (std.mem.startsWith(u8, uri, "data:")) continue;
        const relative = std.Uri.percentDecodeInPlace(try arena.dupe(u8, uri));
        std.mem.replaceScalar(u8, relative, '\\', '/');
        if (!staysInFolder(relative)) continue;
        for (files.items) |listed| {
            if (std.mem.eql(u8, listed, relative)) break;
        } else try files.append(arena, relative);
    };
    return files.items;
}

/// A `.glb`'s JSON chunk, or a `.gltf`'s whole text.
fn jsonOf(model: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, model, "glTF")) return model;
    if (model.len < 20) return error.InvalidModel;
    const length = std.mem.readInt(u32, model[12..16], .little);
    if (!std.mem.eql(u8, model[16..20], "JSON") or model.len - 20 < length) return error.InvalidModel;
    return model[20..][0..length];
}

/// Whether `relative` is a plain path inside the model's folder: not absolute, no scheme, no `..`.
fn staysInFolder(relative: []const u8) bool {
    if (relative.len == 0 or relative[0] == '/' or std.mem.indexOfScalar(u8, relative, ':') != null) return false;
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}
