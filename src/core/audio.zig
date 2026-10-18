//! Audio playback contracts; no audio device or decoder is opened.
const api = @import("support.zig");
const AssetRef = @import("refs.zig").AssetRef;
pub const support: api.Support = .not_implemented;
pub const Voice = enum(u32) { _ };
pub const Bus = enum(u32) { master, _ };
pub const PlayOptions = struct {
    gain: f32 = 1,
    repeat: enum { once, loop } = .once,
    position_m: ?[3]f32 = null,
    bus: Bus = .master,
};

/// Stateless until a playback backend is implemented. Every effectful operation fails.
// ponytail: audio has no playback backend, add one before reporting available.
pub const Audio = struct {
    /// Start a sound; never fabricates a voice when playback is unsupported.
    /// `options` describes gain, repetition, optional world position in metres and output bus.
    /// Currently returns `NotImplemented`, without loading `sound` or allocating a handle.
    ///
    /// ```zig
    /// // Request syntax; propagates NotImplemented until an audio backend exists.
    /// const voice = try app.audio.play(.init("resources/sounds/jump.ogg"), .{ .gain = 0.5 });
    /// ```
    pub fn play(_: Audio, sound: AssetRef(.audio), options: PlayOptions) api.Error!Voice {
        return api.notImplemented(.{ sound, options });
    }
    /// Request that an existing `voice` stop advancing without discarding its playback position.
    /// Currently returns `NotImplemented`; no playback state changes.
    ///
    /// ```zig
    /// try app.audio.pause(voice); // Existing backend-issued voice; currently NotImplemented.
    /// ```
    pub fn pause(_: Audio, voice: Voice) api.Error!void {
        return api.notImplemented(voice);
    }
    /// Request resumption of a paused backend-issued voice. Currently returns `NotImplemented`.
    ///
    /// ```zig
    /// try app.audio.unpause(voice); // Request only: playback is not implemented yet.
    /// ```
    pub fn unpause(_: Audio, voice: Voice) api.Error!void {
        return api.notImplemented(voice);
    }
    /// Request the end of a backend-issued voice. Currently returns `NotImplemented`;
    /// callers must not treat a failed request as successful resource release.
    ///
    /// ```zig
    /// try app.audio.stop(voice); // Propagates NotImplemented rather than faking a stop.
    /// ```
    pub fn stop(_: Audio, voice: Voice) api.Error!void {
        return api.notImplemented(voice);
    }
    /// Request a linear amplitude multiplier for `voice` (1 is unchanged, 0 is silent).
    /// Currently returns `NotImplemented` without validating the value or changing a voice.
    ///
    /// ```zig
    /// try app.audio.setGain(voice, 0.25); // Currently NotImplemented.
    /// ```
    pub fn setGain(_: Audio, voice: Voice, gain: f32) api.Error!void {
        return api.notImplemented(.{ voice, gain });
    }
    /// Request a linear gain for an output bus, such as `.master`.
    /// Currently returns `NotImplemented`; no mixer is created and values are not validated.
    ///
    /// ```zig
    /// try app.audio.setBusGain(.master, 0.8); // Currently NotImplemented.
    /// ```
    pub fn setBusGain(_: Audio, bus: Bus, gain: f32) api.Error!void {
        return api.notImplemented(.{ bus, gain });
    }
    /// Request listener position in world metres and orientation direction vectors.
    /// Currently returns `NotImplemented`; no spatialization or vector validation occurs.
    ///
    /// ```zig
    /// try app.audio.setListener(.{ 0, 1.7, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 });
    /// // The request currently returns NotImplemented.
    /// ```
    pub fn setListener(_: Audio, position_m: [3]f32, forward: [3]f32, up: [3]f32) api.Error!void {
        return api.notImplemented(.{ position_m, forward, up });
    }
};
