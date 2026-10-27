//! The C mixer (`mixer.c`, miniaudio): its handles and functions, as Zig sees them.

/// miniaudio's engine with its buses; made by `create`, freed by `destroy` once its voices are.
pub const Mixer = opaque {
    pub const create = eggy_mixer_create;
    pub const destroy = eggy_mixer_destroy;
    /// Mix `frame_count` interleaved frames into `out` (`frame_count` times the channel count).
    /// Safe on the audio thread while the main thread changes voices.
    pub const read = eggy_mixer_read;
    pub const setBusGain = eggy_mixer_set_bus_gain;
    pub const setListener = eggy_mixer_set_listener;
};

/// One playing sound: a decoder over borrowed encoded bytes, feeding a bus. Stopped when made.
pub const Voice = opaque {
    /// A voice into `bus` over `bytes`, which must outlive it; `UnreadableSound` when miniaudio
    /// can't decode them (or is out of memory).
    pub fn create(mixer: *Mixer, bytes: []const u8, bus: u32) error{UnreadableSound}!*Voice {
        var voice: *Voice = undefined;
        if (eggy_voice_create(mixer, bytes.ptr, bytes.len, bus, &voice) != 0) return error.UnreadableSound;
        return voice;
    }
    pub const destroy = eggy_voice_destroy;
    pub const start = eggy_voice_start;
    pub const pause = eggy_voice_pause;
    pub const setGain = eggy_voice_set_gain;
    pub const setPitch = eggy_voice_set_pitch;
    pub fn setLooping(voice: *Voice, looping: bool) void {
        eggy_voice_set_looping(voice, @intFromBool(looping));
    }
    pub fn setSpatial(voice: *Voice, spatial: bool, min_distance_m: f32, max_distance_m: f32, rolloff: f32) void {
        eggy_voice_set_spatial(voice, @intFromBool(spatial), min_distance_m, max_distance_m, rolloff);
    }
    pub fn setSpatialEnabled(voice: *Voice, spatial: bool) void {
        eggy_voice_set_spatialized(voice, @intFromBool(spatial));
    }
    pub fn setPosition(voice: *Voice, position_m: [3]f32) void {
        eggy_voice_set_position(voice, &position_m);
    }
    /// Where it is in its sound, in seconds.
    pub const cursorSeconds = eggy_voice_cursor_seconds;
    pub const seekSeconds = eggy_voice_seek_seconds;
    pub fn atEnd(voice: *const Voice) bool {
        return eggy_voice_at_end(voice) != 0;
    }
};

/// What a sound file holds, as `analyse` finds by decoding it whole.
pub const SoundInfo = extern struct {
    frames: u64,
    channels: u32,
    sample_rate: u32,
};

/// Decode `bytes` whole: their length, channels and rate, and in `peaks` the loudest sample
/// (0 to 1) of each equal stretch of the sound. `UnreadableSound` when miniaudio can't decode them.
pub fn analyse(bytes: []const u8, peaks: []f32) error{UnreadableSound}!SoundInfo {
    var info: SoundInfo = undefined;
    if (eggy_sound_analyse(bytes.ptr, bytes.len, peaks.ptr, @intCast(peaks.len), &info) != 0) return error.UnreadableSound;
    return info;
}

/// Buses past master that the mixer makes (`EGGY_BUSES`).
pub const bus_count = 4;

extern fn eggy_mixer_create(channels: u32, sample_rate: u32) ?*Mixer;
extern fn eggy_mixer_destroy(mixer: *Mixer) void;
extern fn eggy_mixer_read(mixer: *Mixer, out: [*]f32, frame_count: u32) void;
extern fn eggy_mixer_set_bus_gain(mixer: *Mixer, bus: u32, gain: f32) void;
extern fn eggy_mixer_set_listener(mixer: *Mixer, position: *const [3]f32, forward: *const [3]f32, up: *const [3]f32) void;
extern fn eggy_voice_create(mixer: *Mixer, bytes: [*]const u8, len: usize, bus: u32, out: **Voice) c_int;
extern fn eggy_voice_destroy(voice: *Voice) void;
extern fn eggy_voice_start(voice: *Voice) void;
extern fn eggy_voice_pause(voice: *Voice) void;
extern fn eggy_voice_set_gain(voice: *Voice, gain: f32) void;
extern fn eggy_voice_set_pitch(voice: *Voice, pitch: f32) void;
extern fn eggy_voice_set_looping(voice: *Voice, looping: c_int) void;
extern fn eggy_voice_set_spatial(voice: *Voice, spatial: c_int, min_distance: f32, max_distance: f32, rolloff: f32) void;
extern fn eggy_voice_set_spatialized(voice: *Voice, spatial: c_int) void;
extern fn eggy_voice_set_position(voice: *Voice, position: *const [3]f32) void;
extern fn eggy_voice_cursor_seconds(voice: *Voice) f32;
extern fn eggy_voice_seek_seconds(voice: *Voice, seconds: f32) void;
extern fn eggy_sound_analyse(bytes: [*]const u8, len: usize, peaks: [*]f32, peak_count: u32, info: *SoundInfo) c_int;
extern fn eggy_voice_at_end(voice: *const Voice) c_int;
