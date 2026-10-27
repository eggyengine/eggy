//! The sound the host owns: the mixer, the SDL stream that plays it, and the voices in it.
//!
//! The executable makes it with `App`, so the stream's callback is the host's code. In the
//! editor, voices are made by the game library's code too (miniaudio keeps pointers into it), so
//! `clear` must run before that library unloads, as `App.resetWorld` does.
const std = @import("std");
const sdl = @import("vitellus_sdl3").sdl;
const mixer_zig = @import("mixer.zig");
const Mixer = mixer_zig.Mixer;
const Resources = @import("../resources/resources.zig").Resources;
const AssetRef = @import("../refs.zig").AssetRef;
const EntityId = @import("clutch").EntityId;

pub const sample_rate_hz = 48000;
pub const channels = 2;
/// ponytail: a fixed voice count; raise it if busy scenes run out.
pub const max_voices = 64;

/// A playing sound, as `play` returns it: a slot and its generation, so a handle to a sound
/// that ended never reaches the one playing in its slot now.
pub const Voice = enum(u32) {
    _,

    fn of(index: usize, generation_count: u16) Voice {
        return @fromBackingInt(@as(u32, generation_count) << 16 | @as(u32, @intCast(index)));
    }
    fn slot(self: Voice) usize {
        return @backingInt(self) & 0xffff;
    }
    fn generation(self: Voice) u16 {
        return @intCast(@backingInt(self) >> 16);
    }
};

const Slot = struct {
    voice: ?*mixer_zig.Voice = null,
    /// Starts at 1, so no handle is ever 0.
    generation: u16 = 1,
    /// Paused by the game (not held with the whole mix).
    paused: bool = false,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    mixer: *Mixer,
    /// Plays the mix; null when no audio device opened, and voices play to no one.
    stream: ?*sdl.c.SDL_AudioStream,
    /// Whether the whole mix is held where it is: the device is fed silence meanwhile.
    held: std.atomic.Value(bool) = .init(false),
    slots: [max_voices]Slot = @splat(.{}),
    /// Each sound's encoded file, by asset id, read once and decoded by every voice playing it.
    sounds: std.AutoHashMapUnmanaged(u64, [:0]u8) = .empty,
    /// The voices entities' `AudioSource`s started (see `sources.zig`).
    started: std.AutoHashMapUnmanaged(EntityId, Started) = .empty,

    /// A voice an `AudioSource` started, and what it was started with, so a change restarts it.
    pub const Started = struct { voice: Voice, sound: u64, bus: u32 };

    /// Make the mixer and open the default playback device. SDL's audio subsystem must be up
    /// for the device; without one (or if it fails to open) voices still play, silently.
    /// Free with `destroy`.
    pub fn create(gpa: std.mem.Allocator, audio_subsystem: bool) !*Host {
        const mixer = Mixer.create(channels, sample_rate_hz) orelse return error.AudioMixerFailed;
        errdefer mixer.destroy();
        const self = try gpa.create(Host);
        self.* = .{ .gpa = gpa, .mixer = mixer, .stream = null };

        // SDL asks for more of the mix from its own thread; `feed` mixes it.
        if (audio_subsystem) {
            const spec = sdl.c.SDL_AudioSpec{ .format = sdl.c.SDL_AUDIO_F32, .channels = channels, .freq = sample_rate_hz };
            self.stream = sdl.c.SDL_OpenAudioDeviceStream(sdl.c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, feed, self);
            if (self.stream) |stream| {
                if (!sdl.c.SDL_ResumeAudioStreamDevice(stream)) std.log.warn("cannot start the audio device: {s}", .{sdl.c.SDL_GetError()});
            } else std.log.warn("no audio device, so sounds play silently: {s}", .{sdl.c.SDL_GetError()});
        }
        return self;
    }

    /// Close the device, then free every voice, sound and the mixer.
    pub fn destroy(self: *Host) void {
        if (self.stream) |stream| sdl.c.SDL_DestroyAudioStream(stream);
        self.clear();
        self.sounds.deinit(self.gpa);
        self.started.deinit(self.gpa);
        self.mixer.destroy();
        self.gpa.destroy(self);
    }

    /// End every voice, forget every sound read (files may have changed) and let the mix go on.
    /// Old handles stay invalid.
    pub fn clear(self: *Host) void {
        for (&self.slots) |*slot| self.end(slot);
        var sounds = self.sounds.valueIterator();
        while (sounds.next()) |bytes| self.gpa.free(bytes.*);
        self.sounds.clearRetainingCapacity();
        self.started.clearRetainingCapacity();
        self.held.store(false, .release);
    }

    /// The encoded bytes of `file`, read through `resources` the first time it plays.
    pub fn sound(self: *Host, resources: Resources, file: AssetRef(.audio)) ![]const u8 {
        const entry = try self.sounds.getOrPut(self.gpa, file.id());
        if (!entry.found_existing) entry.value_ptr.* = resources.read(self.gpa, file) catch |err| {
            self.sounds.removeByPtr(entry.key_ptr);
            return err;
        };
        return entry.value_ptr.*;
    }

    /// A new, stopped voice decoding `bytes` (which must stay in `sounds`) into `bus`.
    pub fn add(self: *Host, bytes: []const u8, bus: u32) !Voice {
        const index = for (self.slots, 0..) |slot, i| {
            if (slot.voice == null) break i;
        } else return error.TooManyVoices;
        self.slots[index].voice = try mixer_zig.Voice.create(self.mixer, bytes, bus);
        self.slots[index].paused = false;
        return .of(index, self.slots[index].generation);
    }

    /// The voice `handle` names, or null once it has ended.
    pub fn get(self: *Host, handle: Voice) ?*mixer_zig.Voice {
        const slot = self.slotOf(handle) orelse return null;
        return slot.voice;
    }

    /// Hold `handle` where it is (true) or let it go on; nothing once it has ended.
    pub fn setPaused(self: *Host, handle: Voice, paused: bool) void {
        const slot = self.slotOf(handle) orelse return;
        const voice = slot.voice orelse return;
        slot.paused = paused;
        if (paused) voice.pause() else voice.start();
    }

    /// End `handle`'s voice, freeing its slot; nothing once it has ended.
    pub fn remove(self: *Host, handle: Voice) void {
        if (self.slotOf(handle)) |slot| self.end(slot);
    }

    /// End the voices that played to their end, so their slots take new ones.
    pub fn removeFinished(self: *Host) void {
        for (&self.slots) |*slot| {
            const voice = slot.voice orelse continue;
            if (voice.atEnd()) self.end(slot);
        }
    }

    fn slotOf(self: *Host, handle: Voice) ?*Slot {
        if (handle.slot() >= max_voices) return null;
        const slot = &self.slots[handle.slot()];
        return if (slot.generation == handle.generation() and slot.voice != null) slot else null;
    }

    fn end(_: *Host, slot: *Slot) void {
        const voice = slot.voice orelse return;
        voice.destroy();
        slot.* = .{ .generation = slot.generation +% 1 };
        if (slot.generation == 0) slot.generation = 1;
    }
};

/// SDL's audio thread asking for `additional_bytes` more of the mix.
fn feed(userdata: ?*anyopaque, stream: ?*sdl.c.SDL_AudioStream, additional_bytes: c_int, _: c_int) callconv(.c) void {
    const self: *Host = @ptrCast(@alignCast(userdata));
    const frame_bytes = channels * @sizeOf(f32);
    var frames_left = std.math.divCeil(usize, @intCast(@max(additional_bytes, 0)), frame_bytes) catch unreachable;
    var buffer: [512 * channels]f32 = undefined;
    while (frames_left > 0) {
        const frames: usize = @min(frames_left, buffer.len / channels);
        const mix = buffer[0 .. frames * channels];
        if (self.held.load(.acquire)) @memset(mix, 0) else self.mixer.read(mix.ptr, @intCast(frames));
        if (!sdl.c.SDL_PutAudioStreamData(stream, mix.ptr, @intCast(mix.len * @sizeOf(f32)))) return;
        frames_left -= frames;
    }
}

/// For tests: `samples` of a loud 16-bit mono square wave at the mix's rate, as a WAV file.
pub fn testSquareWave(comptime samples: usize) [44 + samples * 2]u8 {
    var wav: [44 + samples * 2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav);
    writer.writeAll("RIFF") catch unreachable;
    writer.writeInt(u32, wav.len - 8, .little) catch unreachable;
    writer.writeAll("WAVEfmt ") catch unreachable;
    inline for (.{ @as(u32, 16), @as(u16, 1), @as(u16, 1), @as(u32, sample_rate_hz), @as(u32, sample_rate_hz * 2), @as(u16, 2), @as(u16, 16) }) |field| writer.writeInt(@TypeOf(field), field, .little) catch unreachable;
    writer.writeAll("data") catch unreachable;
    writer.writeInt(u32, samples * 2, .little) catch unreachable;
    for (0..samples) |i| writer.writeInt(i16, if (i / 24 % 2 == 0) 20000 else -20000, .little) catch unreachable;
    return wav;
}

test "a voice mixes its sound until it is removed" {
    const wav = testSquareWave(4800);
    const host = try Host.create(std.testing.allocator, false);
    defer host.destroy();
    const handle = try host.add(&wav, 0);
    host.get(handle).?.setSpatial(false, 1, 100, 1);
    host.get(handle).?.start();
    var mix: [256 * channels]f32 = undefined;
    host.mixer.read(&mix, 256);
    var loudest: f32 = 0;
    for (mix) |sample| loudest = @max(loudest, @abs(sample));
    try std.testing.expect(loudest > 0.1);

    // Removed, it is silent and its handle names nothing.
    host.remove(handle);
    try std.testing.expectEqual(null, host.get(handle));
    host.mixer.read(&mix, 256);
    for (mix) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
}

test "a voice handle stops naming its slot once the voice ends" {
    const first = Voice.of(3, 1);
    const reused = Voice.of(3, 2);
    try std.testing.expectEqual(@as(usize, 3), reused.slot());
    try std.testing.expect(first != reused);
    try std.testing.expect(@backingInt(first) != 0);
}

test "a placed voice to the listener's right is louder on the right" {
    const wav = testSquareWave(4800);
    const host = try Host.create(std.testing.allocator, false);
    defer host.destroy();
    host.mixer.setListener(&.{ 0, 0, 0 }, &.{ 0, 0, -1 }, &.{ 0, 1, 0 });
    const handle = try host.add(&wav, 0);
    const voice = host.get(handle).?;
    voice.setSpatial(true, 1, 100, 1);
    voice.setPosition(.{ 5, 0, 0 });
    voice.start();

    var mix: [1024 * channels]f32 = undefined;
    host.mixer.read(&mix, 1024);
    var left: f32 = 0;
    var right: f32 = 0;
    for (0..1024) |frame| {
        left += @abs(mix[frame * channels]);
        right += @abs(mix[frame * channels + 1]);
    }
    try std.testing.expect(right > left * 2);
}

test "analysing a sound finds its length and where it is loud, and a voice seeks into it" {
    // A tenth of a second of square wave, then as long again of silence.
    var wav = testSquareWave(9600);
    for (wav[44 + 4800 * 2 ..]) |*byte| byte.* = 0;
    var peaks: [4]f32 = undefined;
    const info = try mixer_zig.analyse(&wav, &peaks);
    try std.testing.expectEqual(@as(u64, 9600), info.frames);
    try std.testing.expectEqual(@as(u32, 1), info.channels);
    try std.testing.expectEqual(@as(u32, sample_rate_hz), info.sample_rate);
    try std.testing.expect(peaks[0] > 0.5 and peaks[1] > 0.5);
    try std.testing.expect(peaks[2] < 0.01 and peaks[3] < 0.01);
    try std.testing.expectError(error.UnreadableSound, mixer_zig.analyse("not a sound", &peaks));

    const host = try Host.create(std.testing.allocator, false);
    defer host.destroy();
    const voice = host.get(try host.add(&wav, 0)).?;
    voice.seekSeconds(0.15);
    voice.start();
    var mix: [64 * channels]f32 = undefined;
    host.mixer.read(&mix, 64);
    // Past the seek by what was mixed, and what the decoder read ahead (up to 1024 frames).
    try std.testing.expect(voice.cursorSeconds() >= 0.15 and voice.cursorSeconds() < 0.15 + 1088.0 / @as(f32, sample_rate_hz));
    for (mix) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
}
