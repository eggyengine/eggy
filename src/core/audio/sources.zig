//! Sound from scenes: the `AudioSource` component plays a sound at its entity, the
//! `AudioListener` component is where placed sounds are heard, and `step` keeps the mixer's
//! voices and listener in step with them each game frame.
const std = @import("std");
const ecs = @import("clutch");
const AssetRef = @import("../refs.zig").AssetRef;
const transform = @import("../transform.zig");
const math = @import("eggenvector");
const camera = @import("../camera.zig");
const audio = @import("voices.zig");

/// A sound an entity plays: while `playing`, from its place in the world when `spatial` (so it
/// pans and fades as the listener moves), or unplaced. A `.once` sound sets `playing` back to
/// false when it ends; set it true again to replay. Plays only while the game runs (Play).
pub const AudioSource = struct {
    /// Marks it in the editor (nf-md-volume_high).
    pub const icon = "\u{f057e}";
    pub const category = "Audio";
    sound: AssetRef(.audio) = .{},
    playing: bool = true,
    repeat: audio.Repeat = .once,
    /// Linear: 1 as recorded, 0 silent.
    gain: f32 = 1,
    /// Playback rate: 2 is an octave up and twice as fast.
    pitch: f32 = 1,
    bus: audio.Bus = .effects,
    /// Sounds from the entity's place; off for music or UI sounds.
    spatial: bool = true,
    /// Full volume this close, in metres.
    min_distance_m: f32 = 1,
    /// No quieter past this far, in metres.
    max_distance_m: f32 = 100,
    /// How fast it fades beyond `min_distance_m`; 0 doesn't fade.
    rolloff: f32 = 1,
};

/// The ears placed sounds are heard with, at its entity and facing its way (its -z). Without
/// one, the active camera is the listener.
pub const AudioListener = struct {
    /// Marks it in the editor (nf-md-headphones).
    pub const icon = "\u{f02cb}";
    pub const category = "Audio";
};

/// Place the listener, start, update and end `AudioSource`s' voices, and free voices that
/// finished. Runs in `App.updateWorld`, so only while the game does.
pub fn step(world: *ecs.World, sound: audio.Audio) void {
    const host = sound.host orelse return;
    placeListener(world, sound);

    // Each source's voice follows its component.
    var sources = world.query(.{*AudioSource});
    while (sources.next()) |view| {
        const source = view.get(*AudioSource);
        const started = host.started.get(view.entity);
        // Started with another sound or bus, or turned off: end it, and start again if wanted.
        if (started) |old| if (!source.playing or old.sound != source.sound.id() or old.bus != @backingInt(source.bus)) {
            host.remove(old.voice);
            _ = host.started.remove(view.entity);
        };
        if (host.started.get(view.entity)) |old| if (!sound.isPlaying(old.voice)) {
            // It played to its end.
            _ = host.started.remove(view.entity);
            source.playing = false;
            world.markChanged(view.entity, AudioSource);
        };
        if (!source.playing or source.sound.len == 0) continue;

        const position = math.transformPoint4x4(f32, transform.worldMatrix(world, view.entity), .zero);
        if (host.started.get(view.entity)) |playing| {
            update(sound, playing.voice, source.*, position);
            continue;
        }
        start(world, view.entity, sound, source, position);
    }

    // Sources removed, or whose entities were deleted, end.
    var started = host.started.iterator();
    while (started.next()) |entry| {
        if (world.get(entry.key_ptr.*, AudioSource) != null) continue;
        host.remove(entry.value_ptr.voice);
        host.started.removeByPtr(entry.key_ptr);
        started = host.started.iterator();
    }
    host.removeFinished();
}

/// The first `AudioListener`'s place, else the active camera's; left as it is with neither.
fn placeListener(world: *ecs.World, sound: audio.Audio) void {
    var listeners = world.query(.{*const AudioListener});
    const ears: camera.View = if (listeners.next()) |view| blk: {
        const placed = transform.worldMatrix(world, view.entity);
        break :blk .{
            .eye = math.transformPoint4x4(f32, placed, .zero),
            .forward = math.transformDirection4x4(f32, placed, .forward).normalize(),
            .up = math.transformDirection4x4(f32, placed, .up).normalize(),
        };
    } else camera.find(world) orelse return;
    sound.setListener(ears.eye, ears.forward, ears.up) catch |err| std.log.warn("cannot place the audio listener: {t}", .{err});
}

fn start(world: *ecs.World, entity: ecs.EntityId, sound: audio.Audio, source: *AudioSource, position_m: math.Vec3) void {
    const voice = sound.play(source.sound, .{
        .gain = source.gain,
        .pitch = source.pitch,
        .repeat = source.repeat,
        .position_m = if (source.spatial) position_m else null,
        .falloff = .{ .min_distance_m = source.min_distance_m, .max_distance_m = source.max_distance_m, .rolloff = source.rolloff },
        .bus = source.bus,
    }) catch |err| {
        // Reported once: it stays off until something turns it on again.
        std.log.err("entity {d}'s AudioSource cannot play: {t}", .{ entity.id, err });
        source.playing = false;
        world.markChanged(entity, AudioSource);
        return;
    };
    sound.host.?.started.put(sound.host.?.gpa, entity, .{ .voice = voice, .sound = source.sound.id(), .bus = @backingInt(source.bus) }) catch {
        sound.stop(voice) catch {};
    };
}

/// Carry the component's gain, pitch, repeat and place over to its voice.
fn update(sound: audio.Audio, handle: audio.Voice, source: AudioSource, position_m: math.Vec3) void {
    const voice = sound.host.?.get(handle) orelse return;
    if (source.gain >= 0 and std.math.isFinite(source.gain)) voice.setGain(source.gain);
    if (source.pitch > 0 and std.math.isFinite(source.pitch)) voice.setPitch(source.pitch);
    voice.setLooping(source.repeat == .loop);
    if (source.min_distance_m > 0 and source.max_distance_m >= source.min_distance_m and source.rolloff >= 0)
        voice.setSpatial(source.spatial, source.min_distance_m, source.max_distance_m, source.rolloff)
    else
        voice.setSpatialEnabled(source.spatial);
    if (source.spatial) voice.setPosition(position_m.toArray());
}

test "a once source plays at its entity, then turns itself off when it ends" {
    const gpa = std.testing.allocator;
    const Source = struct {
        fn read(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![:0]u8 {
            const wav: *const [44 + 960 * 2]u8 = @ptrCast(context);
            return allocator.dupeSentinel(u8, wav, 0);
        }
        fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !@import("eggy_assets").Model {
            return error.Unsupported;
        }
        fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !@import("eggy_assets").Texture {
            return error.Unsupported;
        }
    };
    // Two hundredths of a second, so one read plays it out.
    var wav = @import("host.zig").testSquareWave(960);
    const host = try @import("host.zig").Host.create(gpa, false);
    defer host.destroy();
    const sound = audio.Audio{ .host = host, .resources = .from(&wav, Source.read, Source.model, Source.image) };
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const entity = try world.spawn(.{ transform.Transform{ .position = .init(3, 0, 0) }, AudioSource{ .sound = .init("beep.wav") } });

    // The first step starts it.
    step(&world, sound);
    try std.testing.expect(host.started.contains(entity));
    try std.testing.expect(world.get(entity, AudioSource).?.playing);

    // Once mixed past its end, the next step ends it and turns the source off.
    var mix: [2048 * @import("host.zig").channels]f32 = undefined;
    host.mixer.read(&mix, 2048);
    step(&world, sound);
    try std.testing.expect(!host.started.contains(entity));
    try std.testing.expect(!world.get(entity, AudioSource).?.playing);
}
