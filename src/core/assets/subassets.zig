//! Stable identities and unambiguous virtual paths for a model's geometry and animation clips.
const std = @import("std");
const identity = @import("id.zig");
const Kind = @import("kind.zig").Kind;
const model = @import("model.zig");

pub const Child = struct {
    id: identity.Id,
    kind: Kind,
    path: []const u8,
    /// Null for the geometry/skeleton child.
    clip_index: ?usize = null,
};

/// Allocate the model child followed by every imported clip in source order.
/// IDs use raw names and duplicate ordinals; virtual labels are sanitized and disambiguated.
/// Returned paths and the array are owned together; release them with `free`.
pub fn list(gpa: std.mem.Allocator, source_id: identity.Id, model_path: []const u8, clips: []const model.Clip) ![]Child {
    if (source_id == 0) return error.InvalidAssetId;
    const children = try gpa.alloc(Child, clips.len + 1);
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
        .path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ model_path, if (clips.len == 0) "Static" else "Skeleton" }),
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
        var suffix: usize = @as(usize, occurrence) + 1;
        if (std.mem.eql(u8, name, "Skeleton") or std.mem.eql(u8, name, "Static")) suffix = @max(suffix, 2);
        while (true) : (suffix += 1) {
            const path = if (suffix == 1)
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ model_path, name })
            else
                try std.fmt.allocPrint(gpa, "{s}/{s} ({d})", .{ model_path, name, suffix });
            const taken = for (children[0..made]) |child| {
                if (std.mem.eql(u8, child.path, path)) break true;
            } else false;
            if (taken) {
                gpa.free(path);
                continue;
            }
            children[made] = .{ .id = id, .kind = .animation, .path = path, .clip_index = index };
            made += 1;
            break;
        }
    }
    return children;
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
                .{ .name = "Skeleton", .duration_s = 0, .tracks = &.{} },
                .{ .name = "a/b", .duration_s = 0, .tracks = &.{} },
                .{ .name = "a_b", .duration_s = 0, .tracks = &.{} },
                .{ .name = "", .duration_s = 0, .tracks = &.{} },
            };
            const children = try list(gpa, 42, "resources/rat.glb", &clips);
            defer free(gpa, children);
            try std.testing.expectEqualStrings("resources/rat.glb/Skeleton", children[0].path);
            try std.testing.expectEqualStrings("resources/rat.glb/walk (2)", children[2].path);
            try std.testing.expectEqualStrings("resources/rat.glb/Skeleton (2)", children[3].path);
            try std.testing.expectEqualStrings("resources/rat.glb/a_b", children[4].path);
            try std.testing.expectEqualStrings("resources/rat.glb/a_b (2)", children[5].path);
            try std.testing.expectEqualStrings("resources/rat.glb/Animation", children[6].path);
            try std.testing.expectEqual(identity.animation(42, "walk", 1), children[2].id);
            const static = try list(gpa, 42, "resources/renamed.glb", &.{});
            defer free(gpa, static);
            try std.testing.expectEqual(children[0].id, static[0].id);
            try std.testing.expectEqualStrings("resources/renamed.glb/Static", static[0].path);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
