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
    pub fn play(_: Audio, sound: AssetRef(.audio), options: PlayOptions) api.Error!Voice {
        return api.notImplemented(.{ sound, options });
    }
    pub fn pause(_: Audio, voice: Voice) api.Error!void {
        return api.notImplemented(voice);
    }
    pub fn unpause(_: Audio, voice: Voice) api.Error!void {
        return api.notImplemented(voice);
    }
    pub fn stop(_: Audio, voice: Voice) api.Error!void {
        return api.notImplemented(voice);
    }
    pub fn setGain(_: Audio, voice: Voice, gain: f32) api.Error!void {
        return api.notImplemented(.{ voice, gain });
    }
    pub fn setBusGain(_: Audio, bus: Bus, gain: f32) api.Error!void {
        return api.notImplemented(.{ bus, gain });
    }
    pub fn setListener(_: Audio, position_m: [3]f32, forward: [3]f32, up: [3]f32) api.Error!void {
        return api.notImplemented(.{ position_m, forward, up });
    }
};
