//! Animation: the `Animator` component, the `app.animation()` controls, and the step that plays
//! authored clips (`.clip.zon`) on entities' transforms. Imported model clips (bones, blend
//! shapes, baked vertex frames) and the `model:` tracks of authored clips move the model itself,
//! which the renderer deforms (`deformation.zig`) from the same `Animator`.
//!
//! Time is the game's: `step` advances by `Time.delta_s`, which is zero while the game is paused,
//! so playback is deterministic and a paused game holds its pose.
const std = @import("std");
const ecs = @import("clutch");
const assets = @import("eggy_assets");
const api = @import("support.zig");
const refs = @import("refs.zig");
const AssetRef = refs.AssetRef;
const Name = @import("name.zig").Name;
const Transform = @import("transform.zig").Transform;
const Mesh = @import("mesh.zig").Mesh;
const ClipCache = @import("clip_cache.zig").ClipCache;

pub const support: api.Support = .available;

/// What an animated entity plays, as a component. The editor's Inspector shows it and scenes
/// save it; `app.animation()` is the way to drive it from code.
///
/// Two kinds of clip can play together: an authored clip (`clip`, a `.clip.zon` that moves
/// entities and model nodes) and one of the entity's model (`model_clip`, by name: bones, blend
/// shapes or baked frames). `previous_*` is the clip being faded out by `blendTo`.
pub const Animator = struct {
    clip: AssetRef(.animation) = .{},
    /// The name of a clip in the entity's model; empty for none. Names can't contain `:` or `\`.
    model_clip: AssetRef(.any) = .{},
    /// Where the clips are now, in seconds. It keeps counting past the end: a looping clip
    /// wraps, a `once` clip holds its last pose.
    time_s: f32 = 0,
    /// Playback rate: 1 is normal, negative plays backwards, 0 holds.
    speed: f32 = 1,
    playing: bool = true,
    repeat: Repeat = .loop,
    previous_clip: AssetRef(.animation) = .{},
    previous_model_clip: AssetRef(.any) = .{},
    previous_time_s: f32 = 0,
    /// How long the fade from the previous clips lasts, and how far along it is; both zero when
    /// nothing is fading.
    blend_duration_s: f32 = 0,
    blend_elapsed_s: f32 = 0,

    /// How far the fade has got, from 0 (all previous) to 1 (all current); 1 when not fading.
    pub fn blendWeight(self: Animator) f32 {
        if (!(self.blend_duration_s > 0)) return 1;
        return std.math.clamp(self.blend_elapsed_s / self.blend_duration_s, 0, 1);
    }

    /// Whether anything is fading out.
    pub fn isBlending(self: Animator) bool {
        return self.blend_duration_s > 0 and (self.previous_clip.len > 0 or self.previous_model_clip.len > 0);
    }
};

pub const Repeat = enum { once, loop };

/// A clip to play on an entity: an authored clip file, a clip of its model by name, or both.
/// `model` need not be set; when it is, it must be the model the entity draws.
/// The name is borrowed for the duration of the call.
pub const Clip = struct {
    model: AssetRef(.model) = .{},
    name: []const u8 = "",
    asset: AssetRef(.animation) = .{},
};

pub const PlayOptions = struct {
    /// Seconds into the clip to start at.
    start_s: f32 = 0,
    speed: f32 = 1,
    repeat: Repeat = .once,
};

pub const Error = error{ InvalidEntity, NoAnimator, InvalidClip, InvalidTime, InvalidSpeed, ModelMismatch };

/// Borrowed access to this world's animators; obtain it from `app.animation()`.
/// Calls change an entity's `Animator` and take effect when the next `step` and frame run.
pub const Animation = struct {
    world: *ecs.World,

    /// Start `clip` on `entity` now, replacing what was playing and adding an `Animator` if it
    /// has none.
    /// `error.InvalidClip` when the clip names neither a file nor a model clip, or the name
    /// can't be kept (see `Animator.model_clip`); `error.ModelMismatch` when `clip.model` isn't
    /// the model `entity` draws. A model clip that doesn't exist is logged by the renderer and
    /// plays nothing.
    ///
    /// ```zig
    /// try app.animation().play(entity, .{ .name = "walk" }, .{ .repeat = .loop });
    /// ```
    pub fn play(self: Animation, entity: ecs.EntityId, clip: Clip, options: PlayOptions) Error!void {
        const target = try self.prepare(entity, clip, options);
        target.* = .{ .clip = clip.asset, .model_clip = try modelClip(clip), .time_s = options.start_s, .speed = options.speed, .repeat = options.repeat };
        self.world.markChanged(entity, Animator);
    }

    /// Fade from what `entity` plays to `clip` over `duration_s` seconds of game time. An entity
    /// with nothing playing just starts `clip`. Channels only one of the two clips moves ease
    /// from, or to, the pose they had. `error.InvalidTime` unless `duration_s` is positive.
    ///
    /// ```zig
    /// try app.animation().blendTo(entity, .{ .name = "idle" }, 0.2, .{ .repeat = .loop });
    /// ```
    pub fn blendTo(self: Animation, entity: ecs.EntityId, clip: Clip, duration_s: f32, options: PlayOptions) Error!void {
        if (!(duration_s > 0) or !std.math.isFinite(duration_s)) return error.InvalidTime;
        const target = try self.prepare(entity, clip, options);
        const next_model = try modelClip(clip);
        const old = target.*;
        const fading = old.clip.len > 0 or old.model_clip.len > 0;
        target.* = .{
            .clip = clip.asset,
            .model_clip = next_model,
            .time_s = options.start_s,
            .speed = options.speed,
            .repeat = options.repeat,
            .previous_clip = if (fading) old.clip else .{},
            .previous_model_clip = if (fading) old.model_clip else .{},
            .previous_time_s = old.time_s,
            .blend_duration_s = if (fading) duration_s else 0,
        };
        self.world.markChanged(entity, Animator);
    }

    /// Hold `entity`'s pose, without advancing its clips.
    pub fn pause(self: Animation, entity: ecs.EntityId) Error!void {
        (try self.animator(entity)).playing = false;
        self.world.markChanged(entity, Animator);
    }

    /// Carry on from where `pause` or `stop` left it.
    pub fn unpause(self: Animation, entity: ecs.EntityId) Error!void {
        (try self.animator(entity)).playing = true;
        self.world.markChanged(entity, Animator);
    }

    /// Go back to the first pose and hold it, ending any fade.
    pub fn stop(self: Animation, entity: ecs.EntityId) Error!void {
        const found = try self.animator(entity);
        found.* = withoutFade(found.*);
        found.time_s = 0;
        found.playing = false;
        self.world.markChanged(entity, Animator);
    }

    /// Jump to `time_s` seconds into the clips (a fade ends). It plays or stays paused as before.
    /// `error.InvalidTime` for a time that isn't finite.
    pub fn seek(self: Animation, entity: ecs.EntityId, time_s: f32) Error!void {
        if (!std.math.isFinite(time_s)) return error.InvalidTime;
        const found = try self.animator(entity);
        found.* = withoutFade(found.*);
        found.time_s = time_s;
        self.world.markChanged(entity, Animator);
    }

    /// Play faster or slower: 1 is normal, negative backwards. `error.InvalidSpeed` if not finite.
    pub fn setSpeed(self: Animation, entity: ecs.EntityId, speed: f32) Error!void {
        if (!std.math.isFinite(speed)) return error.InvalidSpeed;
        (try self.animator(entity)).speed = speed;
        self.world.markChanged(entity, Animator);
    }

    /// Loop the clips or hold their last pose.
    pub fn setRepeat(self: Animation, entity: ecs.EntityId, repeat: Repeat) Error!void {
        (try self.animator(entity)).repeat = repeat;
        self.world.markChanged(entity, Animator);
    }

    fn animator(self: Animation, entity: ecs.EntityId) Error!*Animator {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        return self.world.get(entity, Animator) orelse error.NoAnimator;
    }

    /// The entity's animator, added when missing, after checking `clip` and `options`.
    fn prepare(self: Animation, entity: ecs.EntityId, clip: Clip, options: PlayOptions) Error!*Animator {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        if (clip.asset.len == 0 and clip.name.len == 0) return error.InvalidClip;
        if (!std.math.isFinite(options.start_s)) return error.InvalidTime;
        if (!std.math.isFinite(options.speed)) return error.InvalidSpeed;
        if (clip.model.len > 0) {
            const mesh = self.world.get(entity, Mesh) orelse return error.ModelMismatch;
            switch (mesh.shape) {
                .model => |drawn| if (!std.mem.eql(u8, drawn.path(), clip.model.path())) return error.ModelMismatch,
                else => return error.ModelMismatch,
            }
        }
        _ = try modelClip(clip);
        if (self.world.get(entity, Animator) == null) self.world.addComponent(entity, Animator{}) catch return error.InvalidEntity;
        return self.world.get(entity, Animator).?;
    }
};

fn modelClip(clip: Clip) Error!AssetRef(.any) {
    return AssetRef(.any).parse(clip.name) catch error.InvalidClip;
}

fn withoutFade(animator: Animator) Animator {
    var result = animator;
    result.previous_clip = .{};
    result.previous_model_clip = .{};
    result.previous_time_s = 0;
    result.blend_duration_s = 0;
    result.blend_elapsed_s = 0;
    return result;
}

/// Where a clip of `duration_s` is at the animator's `time_s`: wrapped when looping, held at the
/// ends otherwise.
pub fn clipTime(time_s: f32, duration_s: f32, repeat: Repeat) f32 {
    return assets.rig.wrapTime(time_s, duration_s, repeat == .loop);
}

/// Advance every `Animator` by `delta_s` (the game's `Time.delta_s`, zero while paused) and set
/// the transforms its authored clip animates. Entities a track names that don't exist (or have no
/// `Transform`) are skipped. Clips that fail to load are logged once by `clips` and play nothing.
///
/// ```zig
/// animation.step(&app.world, &app.graphics.clips, app.time.delta_s);
/// ```
pub fn step(world: *ecs.World, clips: *ClipCache, delta_s: f32) void {
    var animators = world.query(.{*Animator});
    while (animators.next()) |view| {
        const animator = view.get(*Animator);
        advance(animator, delta_s);
        applyTracks(world, view.entity, animator.*, clips);
    }
}

/// Move the clock of `animator` along, and finish a fade that has run its course.
fn advance(animator: *Animator, delta_s: f32) void {
    if (!animator.playing or !std.math.isFinite(delta_s)) return;
    const moved = delta_s * animator.speed;
    animator.time_s += moved;
    if (!animator.isBlending()) return;
    animator.previous_time_s += moved;
    animator.blend_elapsed_s += delta_s;
    if (animator.blend_elapsed_s >= animator.blend_duration_s) animator.* = withoutFade(animator.*);
}

/// Write the entity-targeted tracks of the animator's clips into transforms, blended while fading.
fn applyTracks(world: *ecs.World, entity: ecs.EntityId, animator: Animator, clips: *ClipCache) void {
    const current: ?*const assets.clip.Clip = if (animator.clip.len > 0) clips.get(animator.clip.path()) else null;
    const previous: ?*const assets.clip.Clip = if (animator.isBlending() and animator.previous_clip.len > 0) clips.get(animator.previous_clip.path()) else null;
    const weight: f32 = if (animator.isBlending()) animator.blendWeight() else 1;
    if (current) |clip| for (clip.tracks) |track| {
        const target = entityTarget(world, entity, track) orelse continue;
        const value = track.valueAt(clipTime(animator.time_s, clip.duration_s, animator.repeat)) orelse continue;
        const before = read(world, target, track.property) orelse continue;
        const from: [3]f32 = if (previous) |old| blk: {
            const at = old.find(track.target, track.property) orelse break :blk before;
            break :blk old.tracks[at].valueAt(clipTime(animator.previous_time_s, old.duration_s, animator.repeat)) orelse before;
        } else before;
        write(world, target, track.property, if (weight < 1) lerp(from, value, weight) else value);
    };

    // What only the fading clip moved eases out toward the pose it has now.
    if (previous) |old| for (old.tracks) |track| {
        if (current) |clip| if (clip.find(track.target, track.property) != null) continue;
        const target = entityTarget(world, entity, track) orelse continue;
        const from = track.valueAt(clipTime(animator.previous_time_s, old.duration_s, animator.repeat)) orelse continue;
        const now = read(world, target, track.property) orelse continue;
        write(world, target, track.property, lerp(from, now, weight));
    };
}

fn lerp(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (&out, a, b) |*value, from, to| value.* = from + (to - from) * t;
    return out;
}

/// The entity a track's path names below `root`, if the track is for an entity.
fn entityTarget(world: *ecs.World, root: ecs.EntityId, track: assets.clip.Track) ?ecs.EntityId {
    const path = switch (track.where()) {
        .entity => |path| path,
        .model => return null,
    };
    var at = root;
    if (path.len == 0) return at;
    var names = std.mem.splitScalar(u8, path, '/');
    while (names.next()) |name| at = childNamed(world, at, name) orelse return null;
    return at;
}

fn childNamed(world: *ecs.World, parent: ecs.EntityId, name: []const u8) ?ecs.EntityId {
    var children = world.children(parent);
    while (children.next()) |child| {
        const label = world.get(child, Name) orelse continue;
        if (std.mem.eql(u8, label.text(), name)) return child;
    }
    return null;
}

fn read(world: *ecs.World, entity: ecs.EntityId, property: assets.clip.Property) ?[3]f32 {
    const transform = world.get(entity, Transform) orelse return null;
    return switch (property) {
        .position => transform.position,
        .rotation_deg => transform.rotation_deg,
        .scale => transform.scale,
        .morph_weight => null,
    };
}

fn write(world: *ecs.World, entity: ecs.EntityId, property: assets.clip.Property, value: [3]f32) void {
    const transform = world.get(entity, Transform) orelse return;
    const field: *[3]f32 = switch (property) {
        .position => &transform.position,
        .rotation_deg => &transform.rotation_deg,
        .scale => &transform.scale,
        .morph_weight => return,
    };
    if (std.mem.eql(f32, field, &value)) return;
    field.* = value;
    world.markChanged(entity, Transform);
}

const test_tracks = [_]assets.clip.Track{
    .{ .target = "", .property = .position, .keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 } }, .{ .time_s = 2, .value = .{ 4, 0, 0 } } } },
    .{ .target = "Hand", .property = .rotation_deg, .keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 } }, .{ .time_s = 2, .value = .{ 0, 90, 0 } } } },
};

const TestScene = struct { world: ecs.World, root: ecs.EntityId, hand: ecs.EntityId };

fn testScene(gpa: std.mem.Allocator, cache: *ClipCache) !TestScene {
    var world = ecs.World.init(gpa);
    errdefer world.deinit();
    try cache.replace("walk.clip.zon", .{ .duration_s = 2, .tracks = &test_tracks });
    const root = try world.spawn(.{ Name.init("Root"), Transform{} });
    const hand = try world.spawn(.{ Name.init("Hand"), Transform{} });
    try world.setParent(hand, root);
    return .{ .world = world, .root = root, .hand = hand };
}

test "a clip moves the entity and a named child by the game's time, and holds while paused" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    var scene = try testScene(gpa, &cache);
    defer scene.world.deinit();
    const animation = Animation{ .world = &scene.world };
    try animation.play(scene.root, .{ .asset = .init("walk.clip.zon") }, .{ .repeat = .loop });

    // A half second and then another: a quarter of the way along each time, 1 and 2 metres.
    step(&scene.world, &cache, 0.5);
    try std.testing.expectEqual(@as(f32, 1), scene.world.get(scene.root, Transform).?.position[0]);
    try std.testing.expectEqual(@as(f32, 22.5), scene.world.get(scene.hand, Transform).?.rotation_deg[1]);
    step(&scene.world, &cache, 0.5);
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position[0]);

    // Paused, time (and so the pose) stands still however many frames pass.
    try animation.pause(scene.root);
    for (0..10) |_| step(&scene.world, &cache, 0.5);
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position[0]);

    // Seeking while paused shows that moment; unpausing and looping wraps past the end.
    try animation.seek(scene.root, 1.5);
    step(&scene.world, &cache, 0);
    try std.testing.expectEqual(@as(f32, 3), scene.world.get(scene.root, Transform).?.position[0]);
    try animation.unpause(scene.root);
    step(&scene.world, &cache, 1);
    try std.testing.expectEqual(@as(f32, 1), scene.world.get(scene.root, Transform).?.position[0]);
    try animation.stop(scene.root);
    step(&scene.world, &cache, 1);
    try std.testing.expectEqual(@as(f32, 0), scene.world.get(scene.root, Transform).?.position[0]);
}

test "a once clip holds its last pose, and speed scales the clock" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    var scene = try testScene(gpa, &cache);
    defer scene.world.deinit();
    const animation = Animation{ .world = &scene.world };
    try animation.play(scene.root, .{ .asset = .init("walk.clip.zon") }, .{ .speed = 2 });
    step(&scene.world, &cache, 0.5);
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position[0]);
    step(&scene.world, &cache, 5);
    try std.testing.expectEqual(@as(f32, 4), scene.world.get(scene.root, Transform).?.position[0]);
}

test "blending fades from the previous clip, then ends the fade" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    var scene = try testScene(gpa, &cache);
    defer scene.world.deinit();
    const still = [_]assets.clip.Track{.{ .target = "", .property = .position, .keys = &.{.{ .time_s = 0, .value = .{ 10, 0, 0 } }} }};
    try cache.replace("still.clip.zon", .{ .duration_s = 1, .tracks = &still });
    const animation = Animation{ .world = &scene.world };
    try animation.play(scene.root, .{ .asset = .init("walk.clip.zon") }, .{});
    step(&scene.world, &cache, 1);
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position[0]);

    // Halfway through a one second fade: walk is at 1.5 s (3 m), still is at 10 m, so 6.5 m.
    try animation.blendTo(scene.root, .{ .asset = .init("still.clip.zon") }, 1, .{});
    step(&scene.world, &cache, 0.5);
    try std.testing.expectEqual(@as(f32, 6.5), scene.world.get(scene.root, Transform).?.position[0]);
    step(&scene.world, &cache, 0.5);
    try std.testing.expect(!scene.world.get(scene.root, Animator).?.isBlending());
    try std.testing.expectEqual(@as(f32, 10), scene.world.get(scene.root, Transform).?.position[0]);
}

test "controls refuse what they can't do and change nothing" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const animation = Animation{ .world = &world };
    const entity = try world.spawn(.{Transform{}});
    try std.testing.expectError(error.NoAnimator, animation.pause(entity));
    try std.testing.expectError(error.InvalidClip, animation.play(entity, .{}, .{}));
    try std.testing.expectError(error.InvalidClip, animation.play(entity, .{ .name = "a:b" }, .{}));
    try std.testing.expectError(error.InvalidSpeed, animation.play(entity, .{ .name = "run" }, .{ .speed = std.math.inf(f32) }));
    try std.testing.expectError(error.ModelMismatch, animation.play(entity, .{ .model = .init("rat.glb"), .name = "run" }, .{}));
    try std.testing.expect(world.get(entity, Animator) == null);
    try animation.play(entity, .{ .name = "run" }, .{ .start_s = 0.25 });
    try std.testing.expectError(error.InvalidTime, animation.blendTo(entity, .{ .name = "idle" }, 0, .{}));
    try std.testing.expectError(error.InvalidTime, animation.seek(entity, std.math.nan(f32)));
    try std.testing.expectEqualStrings("run", world.get(entity, Animator).?.model_clip.path());
    try std.testing.expectEqual(@as(f32, 0.25), world.get(entity, Animator).?.time_s);
}
