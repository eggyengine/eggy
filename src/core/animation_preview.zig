//! The editor's animation preview: pose the scene at a moment of one entity's clips, then put
//! everything back. A clip may move any entity in the scene and set cameras, sprites and UI, so
//! the preview keeps what all of those were. Nothing here plays by itself; the editor owns the
//! clock and asks for a pose, so the preview follows its play, pause and scrub exactly. Sounds
//! and events never fire in a preview.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const refs = @import("refs.zig");
const animation = @import("animation.zig");
const Animator = animation.Animator;
const ClipCache = @import("clip_cache.zig").ClipCache;
const Name = @import("name.zig").Name;
const Transform = @import("transform.zig").Transform;
const Camera = @import("camera.zig").Camera;
const SpriteAnimator = @import("sprite_animator.zig").SpriteAnimator;
const ui_scenes = @import("ui_scenes/ui_scenes.zig");

pub const Error = error{ InvalidEntity, InvalidClip, OutOfMemory };

/// What to show, by asset key (`AssetRef.key()`, empty for none): an authored clip and/or an
/// imported clip of the entity's model, `time_s` seconds in.
pub const Pose = struct {
    clip: []const u8 = "",
    model_clip: []const u8 = "",
    time_s: f32 = 0,
};

/// The scene's state before the preview changed it: the root's `Animator` (if it had one), and
/// every entity's `Transform`, camera field of view, sprite run and UI screen visibility.
pub const Preview = struct {
    gpa: std.mem.Allocator,
    root: ecs.EntityId,
    animator: ?Animator,
    saved: []const Saved,
    /// The UI nodes a pose has set (entity and node name, owned), cleared at `end`.
    ui_nodes: std.ArrayList(UiNode) = .empty,

    const Saved = struct {
        entity: ecs.EntityId,
        transform: ?Transform,
        fov_deg: ?f32,
        first_frame: ?u16,
        screen_visible: ?bool,
        billboard_visible: ?bool,
    };
    const UiNode = struct { entity: ecs.EntityId, name: []const u8 };

    /// Remember the scene so `end` can restore it. Free with `end`.
    /// `error.InvalidEntity` if `root` isn't alive.
    pub fn begin(gpa: std.mem.Allocator, world: *ecs.World, root: ecs.EntityId) Error!Preview {
        if (!world.isAlive(root)) return error.InvalidEntity;
        var saved: std.ArrayList(Saved) = .empty;
        errdefer saved.deinit(gpa);
        for (world.slots.items, 0..) |slot, index| {
            if (!slot.alive) continue;
            const entity = ecs.EntityId{ .id = @intCast(index), .generation = slot.generation };
            if (!world.isAlive(entity)) continue;
            const kept = Saved{
                .entity = entity,
                .transform = if (world.get(entity, Transform)) |found| found.* else null,
                .fov_deg = if (world.get(entity, Camera)) |found| found.fov_deg else null,
                .first_frame = if (world.get(entity, SpriteAnimator)) |found| found.first_frame else null,
                .screen_visible = if (world.get(entity, ui_scenes.UiScreen)) |found| found.visible else null,
                .billboard_visible = if (world.get(entity, ui_scenes.UiBillboard)) |found| found.visible else null,
            };
            if (kept.transform == null and kept.fov_deg == null and kept.first_frame == null and kept.screen_visible == null and kept.billboard_visible == null) continue;
            try saved.append(gpa, kept);
        }
        return .{
            .gpa = gpa,
            .root = root,
            .animator = if (world.get(root, Animator)) |found| found.* else null,
            .saved = try saved.toOwnedSlice(gpa),
        };
    }

    /// Show `pose` on the root: its clips are given a paused `Animator` at that time, and the
    /// authored clip's entity tracks are written into the scene, its UI tracks into `ui` when
    /// given. A clip that isn't in `clips` shows nothing (and is logged by the cache).
    /// `error.InvalidClip` for a key that isn't an asset identity.
    pub fn show(self: *Preview, world: *ecs.World, clips: *ClipCache, ui: ?*ui_scenes.State, pose: Pose) Error!void {
        if (!world.isAlive(self.root)) return error.InvalidEntity;
        const kept = if (world.get(self.root, Animator)) |found| found.takes_over else .nothing;
        const shown = Animator{
            .clip = refs.AssetRef(.animation).parse(pose.clip) catch return error.InvalidClip,
            .model_clip = refs.AssetRef(.animation).parse(pose.model_clip) catch return error.InvalidClip,
            .time_s = pose.time_s,
            .playing = false,
            .repeat = .once,
            .takes_over = kept,
        };
        if (world.get(self.root, Animator)) |found| {
            found.* = shown;
        } else {
            world.addComponent(self.root, shown) catch return error.OutOfMemory;
        }
        world.markChanged(self.root, Animator);
        if (ui != null) try self.noteUiNodes(world, clips, shown);
        animation.applyTracks(world, self.root, shown, clips, .{ .ui = ui });
    }

    /// Put back what `begin` saw (entities since deleted are skipped), drop the UI changes the
    /// poses made from `ui`, and free the preview.
    pub fn end(self: *Preview, world: *ecs.World, ui: ?*ui_scenes.State) void {
        defer self.gpa.free(self.saved);
        defer {
            for (self.ui_nodes.items) |node| {
                if (ui) |state| state.removeOverride(node.entity, node.name);
                self.gpa.free(node.name);
            }
            self.ui_nodes.deinit(self.gpa);
        }
        if (!world.isAlive(self.root)) return;
        for (self.saved) |saved| {
            if (!world.isAlive(saved.entity)) continue;
            if (saved.transform) |before| if (world.get(saved.entity, Transform)) |transform| if (!std.meta.eql(transform.*, before)) {
                transform.* = before;
                world.markChanged(saved.entity, Transform);
            };
            if (saved.fov_deg) |before| if (world.get(saved.entity, Camera)) |found| if (found.fov_deg != before) {
                found.fov_deg = before;
                world.markChanged(saved.entity, Camera);
            };
            if (saved.first_frame) |before| if (world.get(saved.entity, SpriteAnimator)) |found| if (found.first_frame != before) {
                found.first_frame = before;
                world.markChanged(saved.entity, SpriteAnimator);
            };
            if (saved.screen_visible) |before| if (world.get(saved.entity, ui_scenes.UiScreen)) |found| if (found.visible != before) {
                found.visible = before;
                world.markChanged(saved.entity, ui_scenes.UiScreen);
            };
            if (saved.billboard_visible) |before| if (world.get(saved.entity, ui_scenes.UiBillboard)) |found| if (found.visible != before) {
                found.visible = before;
                world.markChanged(saved.entity, ui_scenes.UiBillboard);
            };
        }
        if (self.animator) |before| {
            if (world.get(self.root, Animator)) |found| found.* = before;
            world.markChanged(self.root, Animator);
        } else if (world.get(self.root, Animator) != null) {
            world.removeComponent(self.root, Animator) catch |err| std.log.err("cannot remove the previewed animator: {t}", .{err});
        }
    }

    /// Free the preview without putting anything back, for when the world is already gone.
    pub fn discard(self: *Preview) void {
        for (self.ui_nodes.items) |node| self.gpa.free(node.name);
        self.ui_nodes.deinit(self.gpa);
        self.gpa.free(self.saved);
    }

    /// Remember each UI node the clip's tracks set, so `end` clears it.
    fn noteUiNodes(self: *Preview, world: *ecs.World, clips: *ClipCache, shown: Animator) Error!void {
        if (shown.clip.len == 0) return;
        const clip = clips.authored(shown.clip.key()) orelse return;
        for (clip.tracks) |track| {
            if (track.node.len == 0) continue;
            const target = animation.trackTarget(world, self.root, track) orelse continue;
            const known = for (self.ui_nodes.items) |node| {
                if (node.entity.eql(target) and std.mem.eql(u8, node.name, track.node)) break true;
            } else false;
            if (known) continue;
            const name = try self.gpa.dupe(u8, track.node);
            errdefer self.gpa.free(name);
            try self.ui_nodes.append(self.gpa, .{ .entity = target, .name = name });
        }
    }
};

/// The targets a clip played by `root` can name, one per line: the child paths below it (`Arm`,
/// `Arm/Hand`), then every other named entity from the top of the scene (`/bee`, `/garden/gate`).
/// A child with the same name as an earlier sibling is skipped: a path can't reach it.
pub fn writeTargets(world: *ecs.World, root: ecs.EntityId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var path: [refs.max_path_len]u8 = undefined;
    try writeChildren(world, root, &path, 0, writer);
    var named = world.query(.{*const Name});
    while (named.next()) |view| {
        if (view.entity.eql(root) or world.getParent(view.entity) != null) continue;
        const label = view.get(*const Name).text();
        if (label.len == 0 or label.len + 1 > path.len or std.mem.indexOfScalar(u8, label, '/') != null) continue;
        if (!animation.inScene(world, label).?.eql(view.entity)) continue;
        path[0] = '/';
        @memcpy(path[1..][0..label.len], label);
        try writer.print("{s}\n", .{path[0 .. label.len + 1]});
        try writeChildren(world, view.entity, &path, label.len + 1, writer);
    }
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

/// The position, rotation (degrees) and scale of the entity a clip played by `root` names with
/// `target` (below it, or `/` from the top of the scene), as nine numbers; null when there is no
/// such entity or it has no `Transform`.
pub fn transformAt(world: *ecs.World, root: ecs.EntityId, target: []const u8) ?[9]f32 {
    const at = entityAt(world, root, target) orelse return null;
    const transform = world.get(at, Transform) orelse return null;
    return transform.position.toArray() ++ transform.rotation_deg.toArray() ++ transform.scale.toArray();
}

/// The entity a clip played by `root` names with `target`: below it, or `/` from the top.
pub fn entityAt(world: *ecs.World, root: ecs.EntityId, target: []const u8) ?ecs.EntityId {
    return animation.trackTarget(world, root, .{ .target = target, .property = .position, .keys = &.{} });
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
    try preview.show(&world, &cache, null, .{ .clip = walk_key, .time_s = 1 });
    try std.testing.expectEqual(@as(f32, 2), world.get(root, Transform).?.position.x);
    try std.testing.expectEqual(@as(f32, 45), world.get(hand, Transform).?.rotation_deg.y);
    try std.testing.expect(world.get(root, Animator) != null);

    // Scrubbing back shows the earlier pose; ending restores the untouched scene.
    try preview.show(&world, &cache, null, .{ .clip = walk_key, .time_s = 0 });
    try std.testing.expectEqual(@as(f32, 0), world.get(root, Transform).?.position.x);
    preview.end(&world, null);
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
    try preview.show(&world, &cache, null, .{ .model_clip = run_key, .time_s = 0.5 });
    try std.testing.expect(!world.get(root, Animator).?.playing);
    try std.testing.expectEqualStrings(run_key, world.get(root, Animator).?.model_clip.key());
    preview.end(&world, null);
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
    const prop = try world.spawn(.{ Name.init("prop"), Transform{ .position = .init(7, 0, 0) } });
    writer = std.Io.Writer.fixed(&buffer);
    try writeTargets(&world, root, &writer);
    try std.testing.expectEqualStrings("Arm\nArm/Hand\n/prop\n", writer.buffered());
    try std.testing.expectEqual(@as(f32, 7), transformAt(&world, root, "/prop").?[0]);
    _ = prop;

    const numbers = transformAt(&world, root, "Arm/Hand").?;
    try std.testing.expectEqual(@as(f32, 2), numbers[6]);
    try std.testing.expectEqual(@as(f32, 2), transformAt(&world, root, "Arm").?[1]);
    try std.testing.expect(transformAt(&world, root, "Leg") == null);
}
