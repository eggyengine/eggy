//! Stable identities and unambiguous virtual paths for a model's geometry, animation clips and
//! material textures.
const std = @import("std");
const identity = @import("id.zig");
const Kind = @import("kind.zig").Kind;
const model = @import("model.zig");

pub const Child = struct {
    id: identity.Id,
    kind: Kind,
    path: []const u8,
    /// Which of the model's clips this is; null for the others.
    clip_index: ?usize = null,
    /// Which of the model's textures this is (an `.image`); null for the others.
    texture_index: ?usize = null,
};

/// Allocate the model child, then every imported clip in source order, then one image per
/// texture the model's materials use (`texture_count` of them, named "Material 1" and on).
/// The model child is "Static", or "Skeletal" when the model has clips.
/// IDs use raw names and duplicate ordinals; virtual labels are sanitized and disambiguated.
/// Returned paths and the array are owned together; release them with `free`.
pub fn list(gpa: std.mem.Allocator, source_id: identity.Id, model_path: []const u8, clips: []const model.Clip, texture_count: usize) ![]Child {
    if (source_id == 0) return error.InvalidAssetId;
    const children = try gpa.alloc(Child, 1 + clips.len + texture_count);
    var made: usize = 0;
    errdefer {
        for (children[0..made]) |child| gpa.free(child.path);
        gpa.free(children);
    }
    const geometry = identity.model(source_id);
    if (geometry == source_id) return error.AssetIdCollision;
    children[0] = .{
        .id = geometry,
        .kind = .model,
        .path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ model_path, if (clips.len == 0) "Static" else "Skeletal" }),
    };
    made = 1;
    for (clips, 0..) |clip, index| {
        var occurrence: u32 = 0;
        for (clips[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, clip.name)) occurrence += 1;
        }
        const id = identity.animation(source_id, clip.name, occurrence);
        if (id == source_id) return error.AssetIdCollision;
        for (children[0..made]) |child| if (child.id == id) return error.AssetIdCollision;
        const raw = if (clip.name.len == 0 or std.mem.eql(u8, clip.name, ".") or std.mem.eql(u8, clip.name, "..")) "Animation" else clip.name;
        const name = try gpa.dupe(u8, raw);
        defer gpa.free(name);
        for (name) |*byte| if (std.mem.indexOfScalar(u8, "/\\:\x00", byte.*) != null) {
            byte.* = '_';
        };
        const first_suffix = @as(usize, occurrence) + 1;
        const reserved = std.mem.eql(u8, name, "Skeletal") or std.mem.eql(u8, name, "Static");
        children[made] = .{ .id = id, .kind = .animation, .path = try uniquePath(gpa, children[0..made], model_path, name, if (reserved) @max(first_suffix, 2) else first_suffix), .clip_index = index };
        made += 1;
    }
    for (0..texture_count) |index| {
        const id = identity.texture(source_id, @intCast(index));
        if (id == source_id) return error.AssetIdCollision;
        for (children[0..made]) |child| if (child.id == id) return error.AssetIdCollision;
        var name: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&name, "Material {d}", .{index + 1}) catch unreachable;
        children[made] = .{ .id = id, .kind = .image, .path = try uniquePath(gpa, children[0..made], model_path, label, 1), .texture_index = index };
        made += 1;
    }
    return children;
}

/// `model_path/name`, or with " (n)" from `suffix` on when 1 is taken or `suffix` is above 1, so
/// no child in `taken` has the same path.
fn uniquePath(gpa: std.mem.Allocator, taken: []const Child, model_path: []const u8, name: []const u8, first_suffix: usize) ![]u8 {
    var suffix = first_suffix;
    while (true) : (suffix += 1) {
        const path = if (suffix == 1)
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ model_path, name })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s} ({d})", .{ model_path, name, suffix });
        const clash = for (taken) |child| {
            if (std.mem.eql(u8, child.path, path)) break true;
        } else false;
        if (!clash) return path;
        gpa.free(path);
    }
}

/// Release one `list` result, including every owned virtual path.
pub fn free(gpa: std.mem.Allocator, children: []const Child) void {
    for (children) |child| gpa.free(child.path);
    gpa.free(children);
}

test "model children preserve clip identities while disambiguating virtual names" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const clips = [_]model.Clip{
                .{ .name = "walk", .duration_s = 0, .tracks = &.{} },
                .{ .name = "walk", .duration_s = 0, .tracks = &.{} },
                .{ .name = "Skeletal", .duration_s = 0, .tracks = &.{} },
                .{ .name = "a/b", .duration_s = 0, .tracks = &.{} },
                .{ .name = "a_b", .duration_s = 0, .tracks = &.{} },
                .{ .name = "", .duration_s = 0, .tracks = &.{} },
            };
            const children = try list(gpa, 42, "resources/rat.glb", &clips, 2);
            defer free(gpa, children);
            try std.testing.expectEqualStrings("resources/rat.glb/Skeletal", children[0].path);
            try std.testing.expectEqualStrings("resources/rat.glb/walk (2)", children[2].path);
            try std.testing.expectEqualStrings("resources/rat.glb/Skeletal (2)", children[3].path);
            try std.testing.expectEqualStrings("resources/rat.glb/a_b", children[4].path);
            try std.testing.expectEqualStrings("resources/rat.glb/a_b (2)", children[5].path);
            try std.testing.expectEqualStrings("resources/rat.glb/Animation", children[6].path);
            try std.testing.expectEqual(identity.animation(42, "walk", 1), children[2].id);
            try std.testing.expectEqualStrings("resources/rat.glb/Material 2", children[8].path);
            try std.testing.expectEqual(@as(?usize, 1), children[8].texture_index);
            try std.testing.expectEqual(identity.texture(42, 1), children[8].id);
            const static = try list(gpa, 42, "resources/renamed.glb", &.{}, 0);
            defer free(gpa, static);
            try std.testing.expectEqual(children[0].id, static[0].id);
            try std.testing.expectEqualStrings("resources/renamed.glb/Static", static[0].path);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
