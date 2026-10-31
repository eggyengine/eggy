//! The editor's animation preview: pose one entity (and its children) at a time in a clip, then
//! put everything back. Nothing here plays by itself; the editor owns the clock and asks for a
//! pose, so the preview follows its play, pause and scrub exactly.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const refs = @import("refs.zig");
const animation = @import("animation.zig");
const Animator = animation.Animator;
const ClipCache = @import("clip_cache.zig").ClipCache;
const Name = @import("name.zig").Name;
const Transform = @import("transform.zig").Transform;

pub const Error = error{ InvalidEntity, InvalidClip, OutOfMemory };

/// What to show, by asset key (`AssetRef.key()`, empty for none): an authored clip and/or an
/// imported clip of the entity's model, `time_s` seconds in.
pub const Pose = struct {
    clip: []const u8 = "",
    model_clip: []const u8 = "",
    time_s: f32 = 0,
};

/// The entity's own state before the preview moved it: its `Animator` (if it had one) and the
/// `Transform` of it and every descendant.
pub const Preview = struct {
    gpa: std.mem.Allocator,
    root: ecs.EntityId,
    animator: ?Animator,
    saved: []const Saved,

    const Saved = struct { entity: ecs.EntityId, transform: Transform };

    /// Remember `root` and its subtree so `end` can restore them. Free with `end`.
    /// `error.InvalidEntity` if `root` isn't alive.
    pub fn begin(gpa: std.mem.Allocator, world: *ecs.World, root: ecs.EntityId) Error!Preview {
        if (!world.isAlive(root)) return error.InvalidEntity;
        var saved: std.ArrayList(Saved) = .empty;
        errdefer saved.deinit(gpa);
        var pending: std.ArrayList(ecs.EntityId) = .empty;
        defer pending.deinit(gpa);
        try pending.append(gpa, root);
        while (pending.pop()) |entity| {
            if (world.get(entity, Transform)) |transform| try saved.append(gpa, .{ .entity = entity, .transform = transform.* });
            var children = world.children(entity);
            while (children.next()) |child| try pending.append(gpa, child);
        }
        return .{
            .gpa = gpa,
            .root = root,
            .animator = if (world.get(root, Animator)) |found| found.* else null,
            .saved = try saved.toOwnedSlice(gpa),
        };
    }

    /// Show `pose` on the root: its clips are given a paused `Animator` at that time, and the
    /// authored clip's entity tracks are written into the transforms. A clip that isn't in
    /// `clips` shows nothing (and is logged by the cache).
    /// `error.InvalidClip` for a key that isn't an asset identity.
    pub fn show(self: Preview, world: *ecs.World, clips: *ClipCache, pose: Pose) Error!void {
        if (!world.isAlive(self.root)) return error.InvalidEntity;
        const shown = Animator{
            .clip = refs.AssetRef(.animation).parse(pose.clip) catch return error.InvalidClip,
            .model_clip = refs.AssetRef(.animation).parse(pose.model_clip) catch return error.InvalidClip,
            .time_s = pose.time_s,
            .playing = false,
            .repeat = .once,
        };
        if (world.get(self.root, Animator)) |found| {
            found.* = shown;
        } else {
            world.addComponent(self.root, shown) catch return error.OutOfMemory;
        }
        world.markChanged(self.root, Animator);
        animation.applyTracks(world, self.root, shown, clips);
    }

    /// Put back the animator and transforms `begin` saw (those of entities since deleted are
    /// skipped), and free the preview.
    pub fn end(self: *Preview, world: *ecs.World) void {
        defer self.gpa.free(self.saved);
        if (!world.isAlive(self.root)) return;
        for (self.saved) |saved| {
            const transform = world.get(saved.entity, Transform) orelse continue;
            if (std.meta.eql(transform.*, saved.transform)) continue;
            transform.* = saved.transform;
            world.markChanged(saved.entity, Transform);
        }
        if (self.animator) |before| {
            if (world.get(self.root, Animator)) |found| found.* = before;
            world.markChanged(self.root, Animator);
        } else if (world.get(self.root, Animator) != null) {
            world.removeComponent(self.root, Animator) catch |err| std.log.err("cannot remove the previewed animator: {t}", .{err});
        }
    }
};

/// The child paths below `root` that a clip track can name (`Arm`, `Arm/Hand`), one per line.
/// A child with the same name as an earlier sibling is skipped: a path can't reach it.
pub fn writeTargets(world: *ecs.World, root: ecs.EntityId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var path: [refs.max_path_len]u8 = undefined;
    try writeChildren(world, root, &path, 0, writer);
}

fn writeChildren(world: *ecs.World, parent: ecs.EntityId, path: *[refs.max_path_len]u8, used: usize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var children = world.children(parent);
    while (children.next()) |child| {
        const label = (world.get(child, Name) orelse continue).text();
        if (label.len == 0 or std.mem.indexOfScalar(u8, label, '/') != null) continue;
        if (animation.childNamed(world, parent, label).?.id != child.id) continue;
        const start = if (used == 0) 0 else used + 1;
        if (start + label.len > path.len) continue;
        if (used > 0) path[used] = '/';
        @memcpy(path[start..][0..label.len], label);
        const total = start + label.len;
        try writer.print("{s}\n", .{path[0..total]});
        try writeChildren(world, child, path, total, writer);
    }
}

/// The position, rotation (degrees) and scale of the entity `path` names below `root`, as nine
/// numbers; null when there is no such entity or it has no `Transform`.
pub fn transformAt(world: *ecs.World, root: ecs.EntityId, path: []const u8) ?[9]f32 {
    var at = root;
    if (path.len > 0) {
        var names = std.mem.splitScalar(u8, path, '/');
        while (names.next()) |name| at = animation.childNamed(world, at, name) orelse return null;
    }
    const transform = world.get(at, Transform) orelse return null;
    return transform.position.toArray() ++ transform.rotation_deg.toArray() ++ transform.scale.toArray();
}

const walk_key = refs.AssetRef(.animation).fromId(0x31).key();
const run_key = refs.AssetRef(.animation).fromId(0x32).key();

test "a preview poses an entity and its child by a clip, then restores both and the animator" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    try cache.replace(walk_key, .{ .duration_s = 2, .tracks = &.{
        .{ .target = "", .property = .position, .keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 } }, .{ .time_s = 2, .value = .{ 4, 0, 0 } } } },
        .{ .target = "Hand", .property = .rotation_deg, .keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 } }, .{ .time_s = 2, .value = .{ 0, 90, 0 } } } },
    } });
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const root = try world.spawn(.{ Name.init("Root"), Transform{ .position = .init(9, 9, 9) } });
    const hand = try world.spawn(.{ Name.init("Hand"), Transform{} });
    try world.setParent(hand, root);

    var preview = try Preview.begin(gpa, &world, root);
    try preview.show(&world, &cache, .{ .clip = walk_key, .time_s = 1 });
    try std.testing.expectEqual(@as(f32, 2), world.get(root, Transform).?.position.x);
    try std.testing.expectEqual(@as(f32, 45), world.get(hand, Transform).?.rotation_deg.y);
    try std.testing.expect(world.get(root, Animator) != null);

    // Scrubbing back shows the earlier pose; ending restores the untouched scene.
    try preview.show(&world, &cache, .{ .clip = walk_key, .time_s = 0 });
    try std.testing.expectEqual(@as(f32, 0), world.get(root, Transform).?.position.x);
    preview.end(&world);
    try std.testing.expectEqual(math.Vec3.splat(9), world.get(root, Transform).?.position);
    try std.testing.expectEqual(math.Vec3.zero, world.get(hand, Transform).?.rotation_deg);
    try std.testing.expect(world.get(root, Animator) == null);
}

test "ending a preview puts back the animator the entity had" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const root = try world.spawn(.{ Name.init("Root"), Transform{}, Animator{ .speed = 3, .playing = true } });

    var preview = try Preview.begin(gpa, &world, root);
    try preview.show(&world, &cache, .{ .model_clip = run_key, .time_s = 0.5 });
    try std.testing.expect(!world.get(root, Animator).?.playing);
    try std.testing.expectEqualStrings(run_key, world.get(root, Animator).?.model_clip.key());
    preview.end(&world);
    try std.testing.expectEqual(@as(f32, 3), world.get(root, Animator).?.speed);
    try std.testing.expect(world.get(root, Animator).?.playing);
    try std.testing.expectEqual(@as(usize, 0), world.get(root, Animator).?.model_clip.len);
}

test "targets list reachable child paths and a transform reads by path" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const root = try world.spawn(.{ Name.init("Root"), Transform{} });
    const arm = try world.spawn(.{ Name.init("Arm"), Transform{ .position = .init(1, 2, 3) } });
    const hand = try world.spawn(.{ Name.init("Hand"), Transform{ .scale = .init(2, 2, 2) } });
    const twin = try world.spawn(.{ Name.init("Arm"), Transform{} });
    try world.setParent(arm, root);
    try world.setParent(twin, root);
    try world.setParent(hand, arm);

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeTargets(&world, root, &writer);
    try std.testing.expectEqualStrings("Arm\nArm/Hand\n", writer.buffered());

    const numbers = transformAt(&world, root, "Arm/Hand").?;
    try std.testing.expectEqual(@as(f32, 2), numbers[6]);
    try std.testing.expectEqual(@as(f32, 2), transformAt(&world, root, "Arm").?[1]);
    try std.testing.expect(transformAt(&world, root, "Leg") == null);
}
