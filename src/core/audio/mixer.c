/* The mixer: miniaudio's engine (decoding, mixing, 3D placement) behind a small C interface
 * of opaque handles, so Zig never translates miniaudio.h. The engine opens no device of its
 * own: `eggy_mixer_read` hands the mix to whoever plays it (SDL, in `host.zig`). */
#define MA_NO_DEVICE_IO
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_ENCODING
#ifdef __EMSCRIPTEN__
/* The web build has no threads; without a device of its own miniaudio needs none. */
#define MA_NO_THREADING
#endif

/* Ogg Vorbis through stb_vorbis: its declarations before miniaudio, its code after. */
#define STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#undef STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"

/* Buses past master (music, effects, voice, ui), each a group feeding the engine's output. */
#define EGGY_BUSES 4

typedef struct eggy_mixer {
    ma_engine engine;
    ma_sound_group buses[EGGY_BUSES];
} eggy_mixer;

typedef struct eggy_voice {
    ma_decoder decoder;
    ma_sound sound;
} eggy_voice;

eggy_mixer *eggy_mixer_create(ma_uint32 channels, ma_uint32 sample_rate) {
    eggy_mixer *mixer = ma_malloc(sizeof *mixer, NULL);
    if (mixer == NULL) return NULL;
    ma_engine_config config = ma_engine_config_init();
    config.noDevice = MA_TRUE;
    config.channels = channels;
    config.sampleRate = sample_rate;
    config.listenerCount = 1;
    if (ma_engine_init(&config, &mixer->engine) != MA_SUCCESS) {
        ma_free(mixer, NULL);
        return NULL;
    }
    for (int bus = 0; bus < EGGY_BUSES; bus += 1) {
        if (ma_sound_group_init(&mixer->engine, 0, NULL, &mixer->buses[bus]) == MA_SUCCESS) continue;
        while (bus > 0) ma_sound_group_uninit(&mixer->buses[--bus]);
        ma_engine_uninit(&mixer->engine);
        ma_free(mixer, NULL);
        return NULL;
    }
    return mixer;
}

/* Every voice must be destroyed first. */
void eggy_mixer_destroy(eggy_mixer *mixer) {
    for (int bus = 0; bus < EGGY_BUSES; bus += 1) ma_sound_group_uninit(&mixer->buses[bus]);
    ma_engine_uninit(&mixer->engine);
    ma_free(mixer, NULL);
}

/* Mix `frame_count` interleaved float frames into `out`; silence where nothing plays. */
void eggy_mixer_read(eggy_mixer *mixer, float *out, ma_uint32 frame_count) {
    ma_uint64 read = 0;
    if (ma_engine_read_pcm_frames(&mixer->engine, out, frame_count, &read) != MA_SUCCESS) read = 0;
    ma_uint32 channels = ma_engine_get_channels(&mixer->engine);
    for (ma_uint64 at = read * channels; at < (ma_uint64)frame_count * channels; at += 1) out[at] = 0;
}

/* Bus 0 is master, the engine's output; 1 to EGGY_BUSES are the groups. */
static ma_sound_group *bus_group(eggy_mixer *mixer, ma_uint32 bus) {
    return bus == 0 ? NULL : &mixer->buses[bus - 1];
}

void eggy_mixer_set_bus_gain(eggy_mixer *mixer, ma_uint32 bus, float gain) {
    if (bus == 0) ma_engine_set_volume(&mixer->engine, gain);
    else ma_sound_group_set_volume(bus_group(mixer, bus), gain);
}

void eggy_mixer_set_listener(eggy_mixer *mixer, const float position[3], const float forward[3], const float up[3]) {
    ma_engine_listener_set_position(&mixer->engine, 0, position[0], position[1], position[2]);
    ma_engine_listener_set_direction(&mixer->engine, 0, forward[0], forward[1], forward[2]);
    ma_engine_listener_set_world_up(&mixer->engine, 0, up[0], up[1], up[2]);
}

/* A stopped voice decoding `bytes` (WAV, FLAC, MP3 or Ogg Vorbis) into `bus`. The bytes are
 * borrowed, and must outlive the voice. Returns a miniaudio result; MA_SUCCESS sets `out`. */
int eggy_voice_create(eggy_mixer *mixer, const void *bytes, size_t len, ma_uint32 bus, eggy_voice **out) {
    eggy_voice *voice = ma_malloc(sizeof *voice, NULL);
    if (voice == NULL) return MA_OUT_OF_MEMORY;
    ma_decoder_config decoding = ma_decoder_config_init(ma_format_f32, 0, 0);
    ma_result result = ma_decoder_init_memory(bytes, len, &decoding, &voice->decoder);
    if (result != MA_SUCCESS) {
        ma_free(voice, NULL);
        return result;
    }
    result = ma_sound_init_from_data_source(&mixer->engine, &voice->decoder, 0, bus_group(mixer, bus), &voice->sound);
    if (result != MA_SUCCESS) {
        ma_decoder_uninit(&voice->decoder);
        ma_free(voice, NULL);
        return result;
    }
    /* Positions are set every frame, not followed for speed: no Doppler shift. */
    ma_sound_set_doppler_factor(&voice->sound, 0);
    *out = voice;
    return MA_SUCCESS;
}

void eggy_voice_destroy(eggy_voice *voice) {
    ma_sound_uninit(&voice->sound);
    ma_decoder_uninit(&voice->decoder);
    ma_free(voice, NULL);
}

void eggy_voice_start(eggy_voice *voice) { ma_sound_start(&voice->sound); }
void eggy_voice_pause(eggy_voice *voice) { ma_sound_stop(&voice->sound); }
void eggy_voice_set_gain(eggy_voice *voice, float gain) { ma_sound_set_volume(&voice->sound, gain); }
void eggy_voice_set_pitch(eggy_voice *voice, float pitch) { ma_sound_set_pitch(&voice->sound, pitch); }
void eggy_voice_set_looping(eggy_voice *voice, int looping) { ma_sound_set_looping(&voice->sound, looping ? MA_TRUE : MA_FALSE); }

/* Place the voice in the world (`spatial`), fading with distance between `min_distance` and
 * `max_distance` metres, or play it as is, unplaced. */
void eggy_voice_set_spatial(eggy_voice *voice, int spatial, float min_distance, float max_distance, float rolloff) {
    ma_sound_set_spatialization_enabled(&voice->sound, spatial ? MA_TRUE : MA_FALSE);
    ma_sound_set_attenuation_model(&voice->sound, ma_attenuation_model_inverse);
    ma_sound_set_min_distance(&voice->sound, min_distance);
    ma_sound_set_max_distance(&voice->sound, max_distance);
    ma_sound_set_rolloff(&voice->sound, rolloff);
}

void eggy_voice_set_spatialized(eggy_voice *voice, int spatial) {
    ma_sound_set_spatialization_enabled(&voice->sound, spatial ? MA_TRUE : MA_FALSE);
}

void eggy_voice_set_position(eggy_voice *voice, const float position[3]) {
    ma_sound_set_position(&voice->sound, position[0], position[1], position[2]);
}

/* Where a voice is in its sound, in seconds. */
float eggy_voice_cursor_seconds(eggy_voice *voice) {
    float cursor = 0;
    if (ma_sound_get_cursor_in_seconds(&voice->sound, &cursor) != MA_SUCCESS) return 0;
    return cursor;
}

void eggy_voice_seek_seconds(eggy_voice *voice, float seconds) { ma_sound_seek_to_second(&voice->sound, seconds); }

/* What `eggy_sound_analyse` finds: the sound's length in frames, and its channels and rate. */
typedef struct eggy_sound_info {
    ma_uint64 frames;
    ma_uint32 channels;
    ma_uint32 sample_rate;
} eggy_sound_info;

/* Decode `bytes` whole, filling `info` and `peaks` with the loudest sample (0 to 1) of each of
 * `peak_count` equal stretches of it. Decoders can't all tell their length up front (Vorbis
 * can't), so it keeps the peak of every block it reads, then folds those into `peaks`.
 * Returns a miniaudio result. */
int eggy_sound_analyse(const void *bytes, size_t len, float *peaks, ma_uint32 peak_count, eggy_sound_info *info) {
    ma_decoder decoder;
    ma_decoder_config decoding = ma_decoder_config_init(ma_format_f32, 0, 0);
    ma_result result = ma_decoder_init_memory(bytes, len, &decoding, &decoder);
    if (result != MA_SUCCESS) return result;
    ma_uint32 channels = decoder.outputChannels;
    info->channels = channels;
    info->sample_rate = decoder.outputSampleRate;
    info->frames = 0;

    // The peak of each block of frames, in a list that grows as the sound decodes.
    float frames[4096];
    ma_uint64 block = sizeof frames / sizeof *frames / channels;
    float *blocks = NULL;
    size_t block_count = 0, block_capacity = 0;
    for (;;) {
        ma_uint64 read = 0;
        result = ma_decoder_read_pcm_frames(&decoder, frames, block, &read);
        if (read == 0) break;
        float loudest = 0;
        for (ma_uint64 at = 0; at < read * channels; at += 1) {
            float level = frames[at] < 0 ? -frames[at] : frames[at];
            if (level > loudest) loudest = level;
        }
        if (block_count == block_capacity) {
            size_t capacity = block_capacity == 0 ? 1024 : block_capacity * 2;
            float *grown = ma_realloc(blocks, capacity * sizeof *blocks, NULL);
            if (grown == NULL) {
                result = MA_OUT_OF_MEMORY;
                break;
            }
            blocks = grown;
            block_capacity = capacity;
        }
        blocks[block_count++] = loudest;
        info->frames += read;
        if (result != MA_SUCCESS) break;
    }
    if (result == MA_AT_END) result = MA_SUCCESS;

    // Fold the blocks into the stretches asked for.
    for (ma_uint32 peak = 0; peak < peak_count; peak += 1) peaks[peak] = 0;
    for (size_t at = 0; at < block_count && peak_count > 0; at += 1) {
        ma_uint32 peak = (ma_uint32)(at * peak_count / block_count);
        if (blocks[at] > peaks[peak]) peaks[peak] = blocks[at] > 1 ? 1 : blocks[at];
    }
    ma_free(blocks, NULL);
    ma_decoder_uninit(&decoder);
    return result;
}

/* Whether a voice played to its end (never, while looping). */
int eggy_voice_at_end(const eggy_voice *voice) { return ma_sound_at_end(&voice->sound) ? 1 : 0; }
