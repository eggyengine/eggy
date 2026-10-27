//! `app.audio()`: playing sound files on buses, placed in the world in 3D or unplaced.
const std = @import("std");
const AssetRef = @import("../refs.zig").AssetRef;
const Resources = @import("../resources/resources.zig").Resources;
const host_zig = @import("host.zig");
const Host = host_zig.Host;
pub const Voice = host_zig.Voice;

/// Where a voice is mixed. Each bus has its own gain under `master`'s (`setBusGain`), so music
/// and effects can have separate volume sliders.
pub const Bus = enum(u32) { master, music, effects, dialogue, ui };

pub const Repeat = enum { once, loop };

/// How a placed sound fades with distance from the listener: full volume within
/// `min_distance_m`, quieter beyond it (faster for a larger `rolloff`), and no quieter past
/// `max_distance_m`.
pub const Falloff = struct {
    min_distance_m: f32 = 1,
    max_distance_m: f32 = 100,
    rolloff: f32 = 1,
};

pub const PlayOptions = struct {
    /// Linear: 1 as recorded, 0 silent.
    gain: f32 = 1,
    /// Playback rate: 2 is an octave up and twice as fast.
    pitch: f32 = 1,
    repeat: Repeat = .once,
    /// Where it sounds from in the world, in metres; null plays it unplaced (music, UI).
    position_m: ?[3]f32 = null,
    falloff: Falloff = .{},
    bus: Bus = .effects,
    /// How far into the sound it starts, in seconds.
    start_s: f32 = 0,
};

pub const Error = error{ AudioUnavailable, InvalidGain, InvalidPitch, InvalidFalloff, InvalidPosition, TooManyVoices, UnreadableSound };

/// Borrowed sound controls; obtain them from `app.audio()` and don't keep them past the frame.
/// A voice that ended (played out, stopped, or reset with the world on Play, Stop and reload)
/// is gone: calls on it do nothing and `isPlaying` says false.
pub const Audio = struct {
    /// Null where the host made no mixer (tests), and every call fails `AudioUnavailable`.
    host: ?*Host,
    resources: Resources,

    /// Start `sound` and return its voice. The file is read the first time it plays, then kept
    /// until the world resets. `.once` voices end by themselves when they finish.
    /// Fails on an unset or unreadable sound, invalid options, or every voice in use.
    ///
    /// ```zig
    /// _ = try app.audio().play(.init("resources/sounds/jump.ogg"), .{ .gain = 0.5 });
    /// // Placed in the world, so it pans and fades with the listener:
    /// _ = try app.audio().play(.init("resources/sounds/boom.wav"), .{ .position_m = .{ 4, 0, -2 } });
    /// ```
    pub fn play(self: Audio, sound: AssetRef(.audio), options: PlayOptions) !Voice {
        const host = self.host orelse return error.AudioUnavailable;
        try checkGain(options.gain);
        try checkPitch(options.pitch);
        if (options.position_m) |place| try checkPosition(place);
        if (!(options.start_s >= 0) or !std.math.isFinite(options.start_s)) return error.InvalidPosition;
        const falloff = options.falloff;
        if (!(falloff.min_distance_m > 0) or !(falloff.max_distance_m >= falloff.min_distance_m) or !std.math.isFinite(falloff.max_distance_m) or !(falloff.rolloff >= 0) or !std.math.isFinite(falloff.rolloff)) return error.InvalidFalloff;

        const bytes = try host.sound(self.resources, sound);
        const handle = try host.add(bytes, @backingInt(options.bus));
        const voice = host.get(handle).?;
        voice.setGain(options.gain);
        voice.setPitch(options.pitch);
        voice.setLooping(options.repeat == .loop);
        voice.setSpatial(options.position_m != null, falloff.min_distance_m, falloff.max_distance_m, falloff.rolloff);
        if (options.position_m) |place| voice.setPosition(place);
        if (options.start_s > 0) voice.seekSeconds(options.start_s);
        voice.start();
        return handle;
    }

    /// Whether `voice` is still going (paused counts; ended does not).
    pub fn isPlaying(self: Audio, voice: Voice) bool {
        const host = self.host orelse return false;
        const playing = host.get(voice) orelse return false;
        return !playing.atEnd();
    }

    /// Where `voice` is in its sound, in seconds; null once it has ended.
    ///
    /// ```zig
    /// const at_s = app.audio().position(music) orelse 0;
    /// ```
    pub fn position(self: Audio, voice: Voice) ?f32 {
        const host = self.host orelse return null;
        const playing = host.get(voice) orelse return null;
        return playing.cursorSeconds();
    }

    /// Move `voice` to `seconds` into its sound (clamped to it).
    ///
    /// ```zig
    /// try app.audio().seek(music, 30);
    /// ```
    pub fn seek(self: Audio, voice: Voice, seconds: f32) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        if (!(seconds >= 0) or !std.math.isFinite(seconds)) return error.InvalidPosition;
        if (host.get(voice)) |playing| playing.seekSeconds(seconds);
    }

    /// Hold `voice` where it is, until `unpause`.
    ///
    /// ```zig
    /// try app.audio().pause(music);
    /// ```
    pub fn pause(self: Audio, voice: Voice) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        host.setPaused(voice, true);
    }

    /// Let a paused `voice` go on from where it was held.
    pub fn unpause(self: Audio, voice: Voice) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        host.setPaused(voice, false);
    }

    /// End `voice` now; its handle names nothing afterwards.
    ///
    /// ```zig
    /// try app.audio().stop(engine_hum);
    /// ```
    pub fn stop(self: Audio, voice: Voice) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        host.remove(voice);
    }

    /// Make `voice` loop, or end when it next reaches its end.
    pub fn setRepeat(self: Audio, voice: Voice, repeat: Repeat) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        if (host.get(voice)) |playing| playing.setLooping(repeat == .loop);
    }

    /// Change `voice`'s linear gain (1 as recorded, 0 silent).
    pub fn setGain(self: Audio, voice: Voice, gain: f32) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        try checkGain(gain);
        if (host.get(voice)) |playing| playing.setGain(gain);
    }

    /// Change `voice`'s playback rate (1 as recorded).
    pub fn setPitch(self: Audio, voice: Voice, pitch: f32) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        try checkPitch(pitch);
        if (host.get(voice)) |playing| playing.setPitch(pitch);
    }

    /// Move `voice` to `position_m` in the world, placing it there if it played unplaced.
    ///
    /// ```zig
    /// try app.audio().setPosition(siren, car_position);
    /// ```
    pub fn setPosition(self: Audio, voice: Voice, position_m: [3]f32) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        try checkPosition(position_m);
        const playing = host.get(voice) orelse return;
        playing.setSpatialEnabled(true);
        playing.setPosition(position_m);
    }

    /// Set the linear gain of a whole bus, `.master` for everything.
    ///
    /// ```zig
    /// try app.audio().setBusGain(.music, 0.4);
    /// ```
    pub fn setBusGain(self: Audio, bus: Bus, gain: f32) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        try checkGain(gain);
        host.mixer.setBusGain(@backingInt(bus), gain);
    }

    /// Place the ears placed sounds are heard with: at `position_m`, facing `forward`, with `up`
    /// overhead. The `AudioListener` entity (else the active camera) sets this every game frame,
    /// so call it yourself only in scenes with neither.
    ///
    /// ```zig
    /// try app.audio().setListener(.{ 0, 1.7, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 });
    /// ```
    pub fn setListener(self: Audio, position_m: [3]f32, forward: [3]f32, up: [3]f32) Error!void {
        const host = self.host orelse return error.AudioUnavailable;
        inline for (.{ position_m, forward, up }) |vector| try checkPosition(vector);
        host.mixer.setListener(&position_m, &forward, &up);
    }

    /// Hold every sound where it is (true), as a pause menu or the editor's pause does, or let
    /// them all go on.
    pub fn hold(self: Audio, held: bool) void {
        const host = self.host orelse return;
        host.held.store(held, .release);
    }
};

fn checkGain(gain: f32) error{InvalidGain}!void {
    if (!(gain >= 0) or !std.math.isFinite(gain)) return error.InvalidGain;
}

fn checkPitch(pitch: f32) error{InvalidPitch}!void {
    if (!(pitch > 0) or !std.math.isFinite(pitch)) return error.InvalidPitch;
}

fn checkPosition(position: [3]f32) error{InvalidPosition}!void {
    for (position) |value| if (!std.math.isFinite(value)) return error.InvalidPosition;
}

test "sound controls fail plainly without a mixer, and reject bad values first" {
    const audio = Audio{ .host = null, .resources = .{} };
    try std.testing.expectError(error.AudioUnavailable, audio.play(.init("jump.ogg"), .{}));
    try std.testing.expectError(error.AudioUnavailable, audio.setBusGain(.music, 0.5));
    try std.testing.expect(!audio.isPlaying(@fromBackingInt(1 << 16)));
    try std.testing.expectError(error.InvalidGain, checkGain(-1));
    try std.testing.expectError(error.InvalidPitch, checkPitch(0));
    try std.testing.expectError(error.InvalidPosition, checkPosition(.{ 0, std.math.nan(f32), 0 }));
}
