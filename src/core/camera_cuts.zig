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
