//! Reading, writing and serializing an authored `.clip.zon` in the project, as text, so the
//! Animation panel can keep the exact text before and after an edit for undo.
const std = @import("std");
const eggy = @import("eggy");
const Clip = eggy.assets.clip.Clip;

/// `clip` as `.clip.zon` text, owned by `gpa`.
pub fn serialize(gpa: std.mem.Allocator, clip: Clip) std.mem.Allocator.Error![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    clip.write(&text.writer) catch return error.OutOfMemory;
    return text.toOwnedSlice();
}

/// The text of the project file `path` (project-relative), owned by `gpa`.
pub fn read(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8) ![]u8 {
    return project.readFileAlloc(io, path, gpa, .limited(1024 * 1024));
}

/// Replace the project file `path` with `text`.
pub fn write(io: std.Io, project: std.Io.Dir, path: []const u8, text: []const u8) !void {
    try project.writeFile(io, .{ .sub_path = path, .data = text });
}

/// Whether the asset at `path` is an authored clip file (an imported clip lives in a model).
pub fn isAuthored(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".clip.zon");
}

test "a clip's text is written, read back and parsed again" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var clip = try (Clip{ .duration_s = 2, .tracks = &.{} }).withTrack(gpa, "Arm", .position);
    defer clip.deinit(gpa);

    const text = try serialize(gpa, clip);
    defer gpa.free(text);
    try write(std.testing.io, tmp.dir, "walk.clip.zon", text);
    const back = try read(gpa, std.testing.io, tmp.dir, "walk.clip.zon");
    defer gpa.free(back);
    try std.testing.expectEqualStrings(text, back);

    const source = try gpa.dupeZ(u8, back);
    defer gpa.free(source);
    const parsed = try eggy.assets.clip.parse(gpa, source);
    defer parsed.deinit(gpa);
    try std.testing.expectEqualStrings("Arm", parsed.tracks[0].target);
}

test "only .clip.zon files are authored clips" {
    try std.testing.expect(isAuthored("resources/walk.clip.zon"));
    try std.testing.expect(!isAuthored("resources/rig.gltf/Walk"));
}
