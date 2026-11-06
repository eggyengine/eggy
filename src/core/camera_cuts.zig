//! Camera cuts: a clip's `camera` track picks the camera the view looks through from each of its
//! keys on, cutting there or blending from the shot before (the game's own camera before the
//! first shot and for an empty key), so a cutscene can take the view and hand it back.
const std = @import("std");
const ecs = @import("clutch");
const assets = @import("eggy_assets");
const camera = @import("camera.zig");
const animation = @import("animation.zig");
const ClipCache = @import("clip_cache.zig").ClipCache;
const View = camera.View;

/// The view to draw: through the shot of a cutscene under way (or of the entity the editor
/// previews, `previewed`, at any time), else the game's active camera; null with neither.
/// Hosts call it where they would call `camera.find`.
// ponytail: the first animator with a shot wins when several cutscenes run at once; give
// clips a priority if games overlap them.
///
/// ```zig
/// const view = camera_cuts.find(&app.world, &app.graphics.clips, null) orelse return;
/// ```
pub fn find(world: *ecs.World, clips: *ClipCache, previewed: ?ecs.EntityId) ?View {
    const game = camera.find(world);
    var animators = world.query(.{*const animation.Animator});
    while (animators.next()) |found| {
        const animator = found.get(*const animation.Animator).*;
        if (animator.clip.len == 0) continue;
        const shown = if (previewed) |entity| entity.eql(found.entity) else false;
        if (!shown and !animation.inProgress(animator, clips)) continue;
        const clip = clips.authored(animator.clip.key()) orelse continue;
        const track = clip.find("", .camera, "") orelse continue;
        const time_s = animation.clipTime(animator.time_s, clip.duration_s, animator.repeat);
        if (shotAt(world, found.entity, clip.tracks[track], time_s, game)) |view| return view;
    }
    return game;
}

/// The view `track` (the `camera` track of a clip `root` plays) gives `time_s` into the clip,
/// where `game` is the view the game shows on its own; null before the first key, or when the
/// shot's camera is missing.
pub fn shotAt(world: *ecs.World, root: ecs.EntityId, track: assets.clip.Track, time_s: f32, game: ?View) ?View {
    const index = keyIndexAt(track, time_s) orelse return null;
    const key = track.keys[index];
    const to = through(world, root, key.text, game) orelse return null;
    const blend_s = key.value[0];
    const into_s = time_s - key.time_s;
    if (!(blend_s > 0) or into_s >= blend_s) return to;
    const from = (if (index == 0) game else through(world, root, track.keys[index - 1].text, game)) orelse return to;
    return mix(from, to, key.ease.apply(into_s / blend_s));
}

/// The last key at or before `time_s`.
fn keyIndexAt(track: assets.clip.Track, time_s: f32) ?usize {
    var found: ?usize = null;
    for (track.keys, 0..) |key, index| {
        if (key.time_s > time_s) break;
        found = index;
    }
    return found;
}

/// The view through the camera a key names (as a track target, from `root`), or `game` for "".
fn through(world: *ecs.World, root: ecs.EntityId, target: []const u8, game: ?View) ?View {
    if (target.len == 0) return game;
    const entity = animation.trackTarget(world, root, .{ .target = target, .property = .position, .keys = &.{} }) orelse return null;
    return camera.viewOf(world, entity);
}

/// `t` of the way from `a` to `b`: the eye moves straight, the gaze turns, the lens changes.
pub fn mix(a: View, b: View, t: f32) View {
    const forward = a.forward.lerp(b.forward, t);
    const up = a.up.lerp(b.up, t);
    // Opposite gazes cancel halfway; take the destination's then.
    const turned = forward.lengthSquared() > 1e-6 and up.lengthSquared() > 1e-6;
    const lerp = std.math.lerp;
    return .{
        .eye = a.eye.lerp(b.eye, t),
        .forward = if (turned) forward.normalize() else b.forward,
        .up = if (turned) up.normalize() else b.up,
        .fov_deg = lerp(a.fov_deg, b.fov_deg, t),
        .near = lerp(a.near, b.near, t),
        .far = if (std.math.isInf(a.far) or std.math.isInf(b.far)) b.far else lerp(a.far, b.far, t),
        .projection = if (t < 0.5) a.projection else b.projection,
        .orthographic_height_m = lerp(a.orthographic_height_m, b.orthographic_height_m, t),
    };
}

const Name = @import("name.zig").Name;
const Transform = @import("transform.zig").Transform;
const AssetRef = @import("refs.zig").AssetRef;

test "a cutscene's camera track cuts and blends between shots, and hands the view back" {
    const gpa = std.testing.allocator;
    var clips = ClipCache{ .gpa = gpa };
    defer clips.deinit();
    const key = AssetRef(.animation).fromId(0x31).key();
    try clips.replace(key, .{ .duration_s = 6, .tracks = &.{
        .{ .target = "", .property = .camera, .interpolation = .step, .keys = &.{
            .{ .time_s = 1, .text = "/wide" },
            .{ .time_s = 2, .value = .{ 1, 0, 0 }, .text = "/close" },
            .{ .time_s = 4, .value = .{ 1, 0, 0 }, .text = "" },
        } },
    } });
    var world = ecs.World.init(gpa);
    defer world.deinit();
    _ = try world.spawn(.{ Name.init("game"), Transform{ .position = .init(0, 0, 0) }, camera.Camera{ .priority = 1 } });
    _ = try world.spawn(.{ Name.init("wide"), Transform{ .position = .init(10, 0, 0) }, camera.Camera{ .active = false, .fov_deg = 50 } });
    _ = try world.spawn(.{ Name.init("close"), Transform{ .position = .init(20, 0, 0) }, camera.Camera{ .active = false, .fov_deg = 30 } });
    const scene = try world.spawn(.{ Name.init("intro"), animation.Animator{ .clip = .fromId(0x31), .repeat = .once } });

    const at = struct {
        fn x(w: *ecs.World, c: *ClipCache, animated: ecs.EntityId, time_s: f32) View {
            w.get(animated, animation.Animator).?.time_s = time_s;
            return find(w, c, null).?;
        }
    }.x;
    // Before the first shot the game's camera; then a cut; then a blend halfway; then back.
    try std.testing.expectEqual(@as(f32, 0), at(&world, &clips, scene, 0.5).eye.x);
    try std.testing.expectEqual(@as(f32, 10), at(&world, &clips, scene, 1.5).eye.x);
    try std.testing.expectEqual(@as(f32, 15), at(&world, &clips, scene, 2.5).eye.x);
    try std.testing.expectEqual(@as(f32, 20), at(&world, &clips, scene, 3.5).eye.x);
    const leaving = at(&world, &clips, scene, 4.5);
    try std.testing.expectEqual(@as(f32, 10), leaving.eye.x);
    try std.testing.expectEqual(@as(f32, 45), leaving.fov_deg);
    // Over: the game's own camera.
    try std.testing.expectEqual(@as(f32, 0), at(&world, &clips, scene, 6.5).eye.x);

    // Paused partway (waiting on a choice), it keeps its shot.
    world.get(scene, animation.Animator).?.playing = false;
    try std.testing.expectEqual(@as(f32, 10), at(&world, &clips, scene, 1.5).eye.x);
}
