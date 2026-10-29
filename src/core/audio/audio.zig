//! Sound: `app.audio()` plays sound files (WAV, FLAC, MP3, Ogg Vorbis) on buses, placed in the
//! world in 3D or unplaced, and the `AudioSource` and `AudioListener` components do the same from
//! scenes. miniaudio decodes, mixes and spatializes (`mixer.c`); SDL plays the mix (`host.zig`).
const voices = @import("voices.zig");
const sources = @import("sources.zig");

pub const support: @import("../support.zig").Support = .available;
pub const Audio = voices.Audio;
pub const Voice = voices.Voice;
pub const Bus = voices.Bus;
pub const Repeat = voices.Repeat;
pub const Falloff = voices.Falloff;
pub const PlayOptions = voices.PlayOptions;
pub const Error = voices.Error;
pub const Host = @import("host.zig").Host;
/// What a sound file holds (length, channels, rate) and its loudness over time, for tools.
pub const SoundInfo = @import("mixer.zig").SoundInfo;
pub const analyse = @import("mixer.zig").analyse;
pub const max_voices = @import("host.zig").max_voices;
pub const AudioSource = sources.AudioSource;
pub const AudioListener = sources.AudioListener;
pub const step = sources.step;

test {
    _ = voices;
    _ = sources;
    _ = @import("host.zig");
}
