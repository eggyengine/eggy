//! Animation: the `Animator` component, the `app.animation()` controls, and the step that plays
//! authored clips (`.clip.zon`) on entities' transforms, and on what a cutscene drives besides:
//! cameras' fields of view, UI scenes' text and visibility, sprite frames, sounds and named
//! events (`Event`, heard through the `animationEvent` plugin hook). Imported model clips (bones,
//! blend shapes, baked vertex frames) and the `model:` tracks of authored clips move the model
//! itself, which the renderer deforms (`deformation.zig`) from the same `Animator`.
//!
//! Time is the game's: `step` advances by `Time.delta_s`, which is zero while the game is paused,
//! so playback is deterministic and a paused game holds its pose.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const assets = @import("eggy_assets");
const api = @import("support.zig");
const refs = @import("refs.zig");
const AssetRef = refs.AssetRef;
const Name = @import("name.zig").Name;
const Transform = @import("transform.zig").Transform;
const Mesh = @import("mesh.zig").Mesh;
const Camera = @import("camera.zig").Camera;
const SpriteAnimator = @import("sprite_animator.zig").SpriteAnimator;
const ui_scenes = @import("ui_scenes/ui_scenes.zig");
const ClipCache = @import("clip_cache.zig").ClipCache;

pub const support: api.Support = .available;

/// What an animated entity plays, as a component. The editor's Inspector shows it and scenes
/// save it; `app.animation()` is the way to drive it from code.
///
/// Two kinds of clip can play together, both `AssetRef(.animation)`: an authored clip (`clip`,
/// a `.clip.zon` that moves entities and model nodes) and an imported one (`model_clip`, made
/// from a model file: bones, blend shapes or baked frames, for that model only). `previous_*`
/// is the clip being faded out by `blendTo`.
pub const Animator = struct {
    /// Marks it in the editor (nf-md-animation_play).
    pub const icon = "\u{f093a}";
    pub const category = "Animation";
    clip: AssetRef(.animation) = .{},
    /// An imported clip of the entity's model; unset for none.
    model_clip: AssetRef(.animation) = .{},
    /// Where the clips are now, in seconds. It keeps counting past the end: a looping clip
    /// wraps, a `once` clip holds its last pose.
    time_s: f32 = 0,
    /// Playback rate: 1 is normal, negative plays backwards, 0 holds.
    speed: f32 = 1,
    playing: bool = true,
    repeat: Repeat = .loop,
    /// What the clip takes from the player while it plays, as a cutscene does: their input
    /// (holding Escape skips to the end), and the HUD (`UiScreen`s the clip doesn't animate are
    /// hidden). See `cutscene.zig`.
    takes_over: Takeover = .nothing,
    /// Black bars over the top and bottom of the view while it plays and takes something over.
    letterbox: bool = false,
    previous_clip: AssetRef(.animation) = .{},
    previous_model_clip: AssetRef(.animation) = .{},
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

pub const Takeover = enum {
    nothing,
    input,
    hud,
    input_and_hud,

    pub fn takesInput(self: Takeover) bool {
        return self == .input or self == .input_and_hud;
    }

    pub fn takesHud(self: Takeover) bool {
        return self == .hud or self == .input_and_hud;
    }
};

/// A named marker an authored clip passed (an `event` track's key), as the `animationEvent`
/// plugin hook hears it. `name` is the clip's: valid during the hook, copy it to keep it.
pub const Event = struct {
    /// The entity whose `Animator` plays the clip.
    animator: ecs.EntityId,
    /// The entity the track acts on (`animator` for a track with an empty target).
    target: ecs.EntityId,
    name: []const u8,
    /// Where in the clip the key is, in seconds.
    time_s: f32,
};

/// Where a clip's cutscene tracks reach beyond the world: the UI scenes whose nodes `text` and
/// `visible` tracks set, and the lists `event` and `sound` keys go to (a sound's `name` is its
/// asset key, which the host starts on the target's `AudioSource`). Each may be null to leave it
/// out: the editor's preview poses UI but fires nothing.
pub const Effects = struct {
    ui: ?*ui_scenes.State = null,
    events: ?*std.ArrayList(Event) = null,
    sounds: ?*std.ArrayList(Event) = null,
    /// Allocates into `events`.
    gpa: ?std.mem.Allocator = null,
};

/// A clip to play on an entity: an authored clip file, an imported clip of its model, or both.
/// `model` need not be set; when it is, it must be the model the entity draws.
pub const Clip = struct {
    model: AssetRef(.model) = .{},
    imported: AssetRef(.animation) = .{},
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
    /// `error.InvalidClip` when `clip` sets neither an authored nor an imported clip;
    /// `error.ModelMismatch` when `clip.model` isn't the model `entity` draws. An imported clip
    /// made for another model is logged by the renderer and plays nothing.
    ///
    /// ```zig
    /// try app.animation().play(entity, .{ .imported = .init("resources/hero.glb/walk") }, .{ .repeat = .loop });
    /// ```
    pub fn play(self: Animation, entity: ecs.EntityId, clip: Clip, options: PlayOptions) Error!void {
        const target = try self.prepare(entity, clip, options);
        target.* = .{ .clip = clip.asset, .model_clip = clip.imported, .time_s = options.start_s, .speed = options.speed, .repeat = options.repeat, .takes_over = target.takes_over, .letterbox = target.letterbox };
        self.world.markChanged(entity, Animator);
    }

    /// Fade from what `entity` plays to `clip` over `duration_s` seconds of game time. An entity
    /// with nothing playing just starts `clip`. Channels only one of the two clips moves ease
    /// from, or to, the pose they had. `error.InvalidTime` unless `duration_s` is positive.
    ///
    /// ```zig
    /// try app.animation().blendTo(entity, .{ .imported = .init("resources/hero.glb/idle") }, 0.2, .{ .repeat = .loop });
    /// ```
    pub fn blendTo(self: Animation, entity: ecs.EntityId, clip: Clip, duration_s: f32, options: PlayOptions) Error!void {
        if (!(duration_s > 0) or !std.math.isFinite(duration_s)) return error.InvalidTime;
        const target = try self.prepare(entity, clip, options);
        const old = target.*;
        const fading = old.clip.len > 0 or old.model_clip.len > 0;
        target.* = .{
            .clip = clip.asset,
            .model_clip = clip.imported,
            .time_s = options.start_s,
            .speed = options.speed,
            .repeat = options.repeat,
            .takes_over = old.takes_over,
            .letterbox = old.letterbox,
            .previous_clip = if (fading) old.clip else .{},
            .previous_model_clip = if (fading) old.model_clip else .{},
            .previous_time_s = old.time_s,
            .blend_duration_s = if (fading) duration_s else 0,
        };
        self.world.markChanged(entity, Animator);
    }

    /// Play the clips `entity`'s `Animator` already names from the start, once: how a game starts
    /// a cutscene set up in a scene.
    ///
    /// ```zig
    /// // In player.zig, when the player talks to the bee:
    /// try app.animation().start(bee_intro);
    /// ```
    pub fn start(self: Animation, entity: ecs.EntityId) Error!void {
        const found = try self.animator(entity);
        if (found.clip.len == 0 and found.model_clip.len == 0) return error.InvalidClip;
        found.* = withoutFade(found.*);
        found.time_s = 0;
        found.speed = 1;
        found.repeat = .once;
        found.playing = true;
        self.world.markChanged(entity, Animator);
    }

    /// Whether `entity`'s authored clip is playing and hasn't reached its end: false for a held
    /// last pose, a paused clip, or no `Animator`.
    pub fn isPlaying(self: Animation, entity: ecs.EntityId, clips: *ClipCache) bool {
        const found = self.animator(entity) catch return false;
        return running(found.*, clips);
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
        if (clip.asset.len == 0 and clip.imported.len == 0) return error.InvalidClip;
        if (!std.math.isFinite(options.start_s)) return error.InvalidTime;
        if (!std.math.isFinite(options.speed)) return error.InvalidSpeed;
        if (clip.model.len > 0) {
            const mesh = self.world.get(entity, Mesh) orelse return error.ModelMismatch;
            switch (mesh.shape) {
                .model => |drawn| if (!std.mem.eql(u8, drawn.key(), clip.model.key())) return error.ModelMismatch,
                else => return error.ModelMismatch,
            }
        }
        if (self.world.get(entity, Animator) == null) self.world.addComponent(entity, Animator{}) catch return error.InvalidEntity;
        return self.world.get(entity, Animator).?;
    }
};

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

/// Advance every `Animator` by `delta_s` (the game's `Time.delta_s`, zero while paused), set
/// what its authored clip animates, and hand `effects` the UI changes and events it passes.
/// Entities a track names that don't exist (or lack what it sets) are skipped. Clips that fail
/// to load are logged once by `clips` and play nothing.
///
/// ```zig
/// animation.step(&app.world, &app.graphics.clips, app.time.delta_s, .{ .ui = &app.ui_scenes });
/// ```
pub fn step(world: *ecs.World, clips: *ClipCache, delta_s: f32, effects: Effects) void {
    var animators = world.query(.{*Animator});
    while (animators.next()) |view| {
        const animator = view.get(*Animator);
        const before_s = animator.time_s;
        advance(animator, delta_s);
        applyTracks(world, view.entity, animator.*, clips, effects);
        firePassed(world, view.entity, animator.*, before_s, clips, effects);
    }
}

/// Whether `animator`'s authored clip is playing forwards short of its end (a looping one never
/// ends).
pub fn running(animator: Animator, clips: *ClipCache) bool {
    if (!animator.playing or animator.clip.len == 0) return false;
    const clip = clips.authored(animator.clip.key()) orelse return false;
    return animator.repeat == .loop or animator.time_s < clip.duration_s;
}

/// Whether `animator`'s authored clip is under way: playing, or paused partway (a cutscene
/// waiting on the player), and short of its end. One set in a scene but not started isn't.
pub fn inProgress(animator: Animator, clips: *ClipCache) bool {
    if (animator.clip.len == 0 or !(animator.playing or animator.time_s > 0)) return false;
    const clip = clips.authored(animator.clip.key()) orelse return false;
    return animator.repeat == .loop or animator.time_s < clip.duration_s;
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

/// Write the entity-targeted tracks of the animator's clips into the world, blended while
/// fading, and UI tracks into `effects.ui`. Keys that fire (`sound`, `event`) are `step`'s.
pub fn applyTracks(world: *ecs.World, entity: ecs.EntityId, animator: Animator, clips: *ClipCache, effects: Effects) void {
    const current: ?*const assets.clip.Clip = if (animator.clip.len > 0) clips.authored(animator.clip.key()) else null;
    const previous: ?*const assets.clip.Clip = if (animator.isBlending() and animator.previous_clip.len > 0) clips.authored(animator.previous_clip.key()) else null;
    const weight: f32 = if (animator.isBlending()) animator.blendWeight() else 1;
    if (current) |clip| for (clip.tracks) |track| {
        if (track.property.fires()) continue;
        const target = entityTarget(world, entity, track) orelse continue;
        const at = clipTime(animator.time_s, clip.duration_s, animator.repeat);
        if (track.property.takesNode() or track.property == .text) {
            if (effects.ui) |ui| setUi(world, ui, target, track, at);
            continue;
        }
        const value = track.valueAt(at) orelse continue;
        const before = read(world, target, track.property) orelse continue;
        const from: [3]f32 = if (previous) |old| blk: {
            if (track.property.discrete()) break :blk before;
            const found = old.find(track.target, track.property, track.node) orelse break :blk before;
            break :blk old.tracks[found].valueAt(clipTime(animator.previous_time_s, old.duration_s, animator.repeat)) orelse before;
        } else before;
        write(world, target, track.property, if (weight < 1 and !track.property.discrete()) lerp(from, value, weight) else value);
    };

    // What only the fading clip moved eases out toward the pose it has now.
    if (previous) |old| for (old.tracks) |track| {
        if (track.property.discrete()) continue;
        if (current) |clip| if (clip.find(track.target, track.property, track.node) != null) continue;
        const target = entityTarget(world, entity, track) orelse continue;
        const from = track.valueAt(clipTime(animator.previous_time_s, old.duration_s, animator.repeat)) orelse continue;
        const now = read(world, target, track.property) orelse continue;
        write(world, target, track.property, lerp(from, now, weight));
    };
}

/// Show what a `text` or `visible` track says at `at` on `target`'s UI scene, through overrides
/// like `app.uiScenes()`'s; a `visible` track without a node shows or hides the whole scene.
fn setUi(world: *ecs.World, ui: *ui_scenes.State, target: ecs.EntityId, track: assets.clip.Track, at: f32) void {
    const key = track.keyAt(at) orelse return;
    const service = ui_scenes.UiScenes{ .state = ui };
    switch (track.property) {
        .text => {
            if (ui.overrideOf(target, track.node)) |known| if (known.text) |shown| if (std.mem.eql(u8, shown, key.text)) return;
            service.setText(target, track.node, key.text) catch |err| std.log.warn("cannot show a clip's text on {s}: {t}", .{ track.node, err });
        },
        .visible => {
            const shown = key.value[0] > 0.5;
            if (track.node.len > 0) {
                service.setVisible(target, track.node, shown) catch |err| std.log.warn("cannot show or hide {s} from a clip: {t}", .{ track.node, err });
            } else if (read(world, target, .visible)) |_| {
                write(world, target, .visible, key.value);
            }
        },
        else => unreachable,
    }
}

/// Fire the `sound` and `event` keys the authored clip passed going from `before_s` to where the
/// animator is now, into `effects.sounds` and `effects.events`. Only forwards; a step longer than a looping clip fires a lap once.
fn firePassed(world: *ecs.World, entity: ecs.EntityId, animator: Animator, before_s: f32, clips: *ClipCache, effects: Effects) void {
    if (!(animator.time_s > before_s) or animator.clip.len == 0) return;
    const clip = clips.authored(animator.clip.key()) orelse return;
    var spans: [2][2]f32 = undefined;
    var span_count: usize = 1;
    if (animator.repeat == .loop and clip.duration_s > 0) {
        const from = @mod(before_s, clip.duration_s);
        const to = from + @min(animator.time_s - before_s, clip.duration_s);
        if (to <= clip.duration_s) {
            spans[0] = .{ from, to };
        } else {
            // Round the end: the rest of this lap (its last key included), then the next's start.
            spans[0] = .{ from, clip.duration_s + assets.clip.same_time_s };
            spans[1] = .{ 0, to - clip.duration_s };
            span_count = 2;
        }
    } else spans[0] = .{ before_s, animator.time_s };

    for (spans[0..span_count]) |span| for (clip.tracks) |track| {
        if (!track.property.fires()) continue;
        const passed = track.passed(span[0], span[1]);
        if (passed.start == passed.end) continue;
        const target = entityTarget(world, entity, track) orelse continue;
        const list = (if (track.property == .sound) effects.sounds else effects.events) orelse continue;
        for (track.keys[passed.start..passed.end]) |key| {
            list.append(effects.gpa.?, .{ .animator = entity, .target = target, .name = key.text, .time_s = key.time_s }) catch |err| std.log.err("cannot pass on the clip's {t} key {s}: {t}", .{ track.property, key.text, err });
        }
    };
}

fn lerp(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (&out, a, b) |*value, from, to| value.* = from + (to - from) * t;
    return out;
}

/// Jump `entity`'s authored clip to its end, showing its last pose and firing the keys it
/// skipped over (a skipped cutscene's events still happen).
pub fn skipToEnd(world: *ecs.World, entity: ecs.EntityId, clips: *ClipCache, effects: Effects) void {
    const animator = world.get(entity, Animator) orelse return;
    const clip = clips.authored(animator.clip.key()) orelse return;
    const before_s = animator.time_s;
    animator.* = withoutFade(animator.*);
    // Just past the end, so a key on the last moment fires too.
    animator.time_s = clip.duration_s + assets.clip.same_time_s;
    animator.repeat = .once;
    world.markChanged(entity, Animator);
    applyTracks(world, entity, animator.*, clips, effects);
    firePassed(world, entity, animator.*, before_s, clips, effects);
}

/// The entity `track` acts on in a clip `root` plays; null for a model target or a path that
/// leads nowhere.
pub fn trackTarget(world: *ecs.World, root: ecs.EntityId, track: assets.clip.Track) ?ecs.EntityId {
    return entityTarget(world, root, track);
}

/// The entity a track names: below `root`, or from the top of the scene; null for a model
/// target or a path that leads nowhere.
fn entityTarget(world: *ecs.World, root: ecs.EntityId, track: assets.clip.Track) ?ecs.EntityId {
    return switch (track.where()) {
        .entity => |path| below(world, root, path),
        .scene => |path| inScene(world, path),
        .model => null,
    };
}

/// The entity `path` (`/`-joined child names) leads to from `root`; `root` itself for "".
pub fn below(world: *ecs.World, root: ecs.EntityId, path: []const u8) ?ecs.EntityId {
    var at = root;
    if (path.len == 0) return at;
    var names = std.mem.splitScalar(u8, path, '/');
    while (names.next()) |name| at = childNamed(world, at, name) orelse return null;
    return at;
}

/// The entity `path` leads to from the top of the scene: its first name is an entity without a
/// parent (the oldest of any that share it), the rest children's names.
pub fn inScene(world: *ecs.World, path: []const u8) ?ecs.EntityId {
    const first_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const first = path[0..first_end];
    var top: ?ecs.EntityId = null;
    var named = world.query(.{*const Name});
    while (named.next()) |view| {
        if (world.getParent(view.entity) != null) continue;
        if (!std.mem.eql(u8, view.get(*const Name).text(), first)) continue;
        if (top == null or view.entity.id < top.?.id) top = view.entity;
    }
    const found = top orelse return null;
    return if (first_end == path.len) found else below(world, found, path[first_end + 1 ..]);
}

/// The target text a track would use for `entity` in a clip played by `root`: a path below it,
/// or from the top of the scene. Null when a name on the way is empty or contains `/`.
pub fn targetFor(world: *ecs.World, root: ecs.EntityId, entity: ecs.EntityId, buffer: []u8) ?[]const u8 {
    // Climb from the entity, collecting names, until `root` (a path below it) or the top.
    var names: [32][]const u8 = undefined;
    var count: usize = 0;
    var at = entity;
    const from_root = while (true) {
        if (at.eql(root)) break true;
        if (count == names.len) return null;
        const name = (world.get(at, Name) orelse return null).text();
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
        names[count] = name;
        count += 1;
        at = world.getParent(at) orelse break false;
    };
    var writer = std.Io.Writer.fixed(buffer);
    if (!from_root) writer.writeAll(assets.clip.scene_prefix) catch return null;
    var index = count;
    while (index > 0) {
        index -= 1;
        writer.writeAll(names[index]) catch return null;
        if (index > 0) writer.writeByte('/') catch return null;
    }
    return writer.buffered();
}

pub fn childNamed(world: *ecs.World, parent: ecs.EntityId, name: []const u8) ?ecs.EntityId {
    var children = world.children(parent);
    while (children.next()) |child| {
        const label = world.get(child, Name) orelse continue;
        if (std.mem.eql(u8, label.text(), name)) return child;
    }
    return null;
}

/// What `property` is now on `entity`, as a key's numbers; null when it lacks the component.
pub fn read(world: *ecs.World, entity: ecs.EntityId, property: assets.clip.Property) ?[3]f32 {
    // Clips keep plain arrays (`eggy_assets` stays free of the engine's math).
    return switch (property) {
        .position => (world.get(entity, Transform) orelse return null).position.toArray(),
        .rotation_deg => (world.get(entity, Transform) orelse return null).rotation_deg.toArray(),
        .scale => (world.get(entity, Transform) orelse return null).scale.toArray(),
        .fov_deg => .{ (world.get(entity, Camera) orelse return null).fov_deg, 0, 0 },
        .sprite_frame => .{ @floatFromInt((world.get(entity, SpriteAnimator) orelse return null).first_frame), 0, 0 },
        .visible => if (world.get(entity, ui_scenes.UiScreen)) |screen|
            .{ @floatFromInt(@intFromBool(screen.visible)), 0, 0 }
        else if (world.get(entity, ui_scenes.UiBillboard)) |billboard|
            .{ @floatFromInt(@intFromBool(billboard.visible)), 0, 0 }
        else
            null,
        .morph_weight, .text, .sound, .event, .camera => null,
    };
}

/// Set `property` on `entity` from a key's numbers, marking the component changed if it did.
pub fn write(world: *ecs.World, entity: ecs.EntityId, property: assets.clip.Property, value: [3]f32) void {
    switch (property) {
        .position, .rotation_deg, .scale => {
            const transform = world.get(entity, Transform) orelse return;
            const field: *math.Vec3 = switch (property) {
                .position => &transform.position,
                .rotation_deg => &transform.rotation_deg,
                else => &transform.scale,
            };
            const next = math.Vec3.fromArray(value);
            if (field.eql(next)) return;
            field.* = next;
            world.markChanged(entity, Transform);
        },
        .fov_deg => {
            const found = world.get(entity, Camera) orelse return;
            // A field of view the camera can't use is left alone.
            if (found.fov_deg == value[0] or !(value[0] > 0 and value[0] < 180)) return;
            found.fov_deg = value[0];
            world.markChanged(entity, Camera);
        },
        .sprite_frame => {
            const found = world.get(entity, SpriteAnimator) orelse return;
            const frame: u16 = @intFromFloat(std.math.clamp(@round(value[0]), 0, std.math.maxInt(u16)));
            if (found.first_frame == frame) return;
            found.first_frame = frame;
            world.markChanged(entity, SpriteAnimator);
        },
        .visible => {
            const shown = value[0] > 0.5;
            if (world.get(entity, ui_scenes.UiScreen)) |screen| if (screen.visible != shown) {
                screen.visible = shown;
                world.markChanged(entity, ui_scenes.UiScreen);
            };
            if (world.get(entity, ui_scenes.UiBillboard)) |billboard| if (billboard.visible != shown) {
                billboard.visible = shown;
                world.markChanged(entity, ui_scenes.UiBillboard);
            };
        },
        .morph_weight, .text, .sound, .event, .camera => {},
    }
}

const walk_id: assets.Id = 0x11;
const still_id: assets.Id = 0x12;
const walk_key = AssetRef(.animation).fromId(walk_id).key();
const still_key = AssetRef(.animation).fromId(still_id).key();

const test_tracks = [_]assets.clip.Track{
    .{ .target = "", .property = .position, .keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 } }, .{ .time_s = 2, .value = .{ 4, 0, 0 } } } },
    .{ .target = "Hand", .property = .rotation_deg, .keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 } }, .{ .time_s = 2, .value = .{ 0, 90, 0 } } } },
};

const TestScene = struct { world: ecs.World, root: ecs.EntityId, hand: ecs.EntityId };

fn testScene(gpa: std.mem.Allocator, cache: *ClipCache) !TestScene {
    var world = ecs.World.init(gpa);
    errdefer world.deinit();
    try cache.replace(walk_key, .{ .duration_s = 2, .tracks = &test_tracks });
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
    try animation.play(scene.root, .{ .asset = .fromId(walk_id) }, .{ .repeat = .loop });

    // A half second and then another: a quarter of the way along each time, 1 and 2 metres.
    step(&scene.world, &cache, 0.5, .{});
    try std.testing.expectEqual(@as(f32, 1), scene.world.get(scene.root, Transform).?.position.x);
    try std.testing.expectEqual(@as(f32, 22.5), scene.world.get(scene.hand, Transform).?.rotation_deg.y);
    step(&scene.world, &cache, 0.5, .{});
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position.x);

    // Paused, time (and so the pose) stands still however many frames pass.
    try animation.pause(scene.root);
    for (0..10) |_| step(&scene.world, &cache, 0.5, .{});
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position.x);

    // Seeking while paused shows that moment; unpausing and looping wraps past the end.
    try animation.seek(scene.root, 1.5);
    step(&scene.world, &cache, 0, .{});
    try std.testing.expectEqual(@as(f32, 3), scene.world.get(scene.root, Transform).?.position.x);
    try animation.unpause(scene.root);
    step(&scene.world, &cache, 1, .{});
    try std.testing.expectEqual(@as(f32, 1), scene.world.get(scene.root, Transform).?.position.x);
    try animation.stop(scene.root);
    step(&scene.world, &cache, 1, .{});
    try std.testing.expectEqual(@as(f32, 0), scene.world.get(scene.root, Transform).?.position.x);
}

test "a once clip holds its last pose, and speed scales the clock" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    var scene = try testScene(gpa, &cache);
    defer scene.world.deinit();
    const animation = Animation{ .world = &scene.world };
    try animation.play(scene.root, .{ .asset = .fromId(walk_id) }, .{ .speed = 2 });
    step(&scene.world, &cache, 0.5, .{});
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position.x);
    step(&scene.world, &cache, 5, .{});
    try std.testing.expectEqual(@as(f32, 4), scene.world.get(scene.root, Transform).?.position.x);
}

test "blending fades from the previous clip, then ends the fade" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    var scene = try testScene(gpa, &cache);
    defer scene.world.deinit();
    const still = [_]assets.clip.Track{.{ .target = "", .property = .position, .keys = &.{.{ .time_s = 0, .value = .{ 10, 0, 0 } }} }};
    try cache.replace(still_key, .{ .duration_s = 1, .tracks = &still });
    const animation = Animation{ .world = &scene.world };
    try animation.play(scene.root, .{ .asset = .fromId(walk_id) }, .{});
    step(&scene.world, &cache, 1, .{});
    try std.testing.expectEqual(@as(f32, 2), scene.world.get(scene.root, Transform).?.position.x);

    // Halfway through a one second fade: walk is at 1.5 s (3 m), still is at 10 m, so 6.5 m.
    try animation.blendTo(scene.root, .{ .asset = .fromId(still_id) }, 1, .{});
    step(&scene.world, &cache, 0.5, .{});
    try std.testing.expectEqual(@as(f32, 6.5), scene.world.get(scene.root, Transform).?.position.x);
    step(&scene.world, &cache, 0.5, .{});
    try std.testing.expect(!scene.world.get(scene.root, Animator).?.isBlending());
    try std.testing.expectEqual(@as(f32, 10), scene.world.get(scene.root, Transform).?.position.x);
}

test "controls refuse what they can't do and change nothing" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const animation = Animation{ .world = &world };
    const entity = try world.spawn(.{Transform{}});
    try std.testing.expectError(error.NoAnimator, animation.pause(entity));
    try std.testing.expectError(error.InvalidClip, animation.play(entity, .{}, .{}));
    const run: Clip = .{ .imported = .fromId(0x21) };
    try std.testing.expectError(error.InvalidSpeed, animation.play(entity, run, .{ .speed = std.math.inf(f32) }));
    var other = run;
    other.model = .fromId(0x22);
    try std.testing.expectError(error.ModelMismatch, animation.play(entity, other, .{}));
    try std.testing.expect(world.get(entity, Animator) == null);
    try animation.play(entity, run, .{ .start_s = 0.25 });
    try std.testing.expectError(error.InvalidTime, animation.blendTo(entity, .{ .imported = .fromId(0x23) }, 0, .{}));
    try std.testing.expectError(error.InvalidTime, animation.seek(entity, std.math.nan(f32)));
    try std.testing.expectEqual(@as(u64, 0x21), world.get(entity, Animator).?.model_clip.id());
    try std.testing.expectEqual(@as(f32, 0.25), world.get(entity, Animator).?.time_s);
}

test "a cutscene clip moves entities across the scene, sets a camera, UI text and fires its events once" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    const intro_key = AssetRef(.animation).fromId(0x13).key();
    try cache.replace(intro_key, .{ .duration_s = 4, .tracks = &.{
        .{ .target = "/bee", .property = .position, .keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 } }, .{ .time_s = 2, .value = .{ 2, 0, 0 } } } },
        .{ .target = "/camera", .property = .fov_deg, .keys = &.{ .{ .time_s = 0, .value = .{ 60, 0, 0 } }, .{ .time_s = 2, .value = .{ 40, 0, 0 } } } },
        .{ .target = "/dialogue", .property = .text, .node = "line", .interpolation = .step, .keys = &.{.{ .time_s = 1, .text = "Bzz!" }} },
        .{ .target = "", .property = .event, .interpolation = .step, .keys = &.{.{ .time_s = 1.5, .text = "wait_for_choice" }} },
    } });
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var ui = ui_scenes.State{ .gpa = gpa };
    defer ui.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);
    const effects = Effects{ .ui = &ui, .events = &events, .gpa = gpa };

    const bee = try world.spawn(.{ Name.init("bee"), Transform{} });
    const camera = try world.spawn(.{ Name.init("camera"), Transform{}, Camera{} });
    const dialogue = try world.spawn(.{ Name.init("dialogue"), ui_scenes.UiScreen{} });
    const intro = try world.spawn(.{ Name.init("bee intro"), Animator{ .clip = .fromId(0x13), .playing = false, .takes_over = .input_and_hud } });
    const animation = Animation{ .world = &world };
    try animation.start(intro);
    try std.testing.expectEqual(Takeover.input_and_hud, world.get(intro, Animator).?.takes_over);

    // A second in: the bee is halfway, the camera narrowing, the line shown, no event yet.
    step(&world, &cache, 1, effects);
    try std.testing.expectEqual(@as(f32, 1), world.get(bee, Transform).?.position.x);
    try std.testing.expectEqual(@as(f32, 50), world.get(camera, Camera).?.fov_deg);
    try std.testing.expectEqualStrings("Bzz!", ui.overrideOf(dialogue, "line").?.text.?);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    // Passing 1.5 s fires the event, once, from the cutscene's own entity.
    step(&world, &cache, 1, effects);
    step(&world, &cache, 1, effects);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("wait_for_choice", events.items[0].name);
    try std.testing.expect(events.items[0].target.eql(intro));
    try std.testing.expect(animation.isPlaying(intro, &cache));
    step(&world, &cache, 2, effects);
    try std.testing.expect(!animation.isPlaying(intro, &cache));
}

test "a track's target text reaches an entity below the animator or from the top of the scene" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const intro = try world.spawn(.{Name.init("intro")});
    const prop = try world.spawn(.{Name.init("prop")});
    try world.setParent(prop, intro);
    const garden = try world.spawn(.{Name.init("garden")});
    const gate = try world.spawn(.{Name.init("gate")});
    try world.setParent(gate, garden);

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("prop", targetFor(&world, intro, prop, &buffer).?);
    try std.testing.expectEqualStrings("/garden/gate", targetFor(&world, intro, gate, &buffer).?);
    try std.testing.expectEqualStrings("", targetFor(&world, intro, intro, &buffer).?);
    try std.testing.expect(inScene(&world, "garden/gate").?.eql(gate));
    try std.testing.expect(inScene(&world, "gate") == null);
    try std.testing.expect(below(&world, intro, "prop").?.eql(prop));
}
