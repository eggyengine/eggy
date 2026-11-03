//! Encoding a film's frames: the `ffmpeg` command that turns the PNG frames into an H.264 MP4,
//! with each sound the clip starts mixed in at its key's time, run on a thread of its own so
//! the editor keeps going. Without `ffmpeg` installed the frames stay as they are.
const std = @import("std");
const eggy = @import("eggy");
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;

/// Frame file names as written (`std.fmt`) and as `ffmpeg` reads them.
pub const frame_pattern_format = "frame_{d:0>5}.png";
const frame_pattern_ffmpeg = "frame_%05d.png";

/// A sound the clip starts: its file (absolute) and when, from the start.
pub const Sound = struct { path: []u8, delay_ms: u32 };

/// What to encode.
pub const Inputs = struct {
    frames_dir: []const u8,
    out_dir: []const u8,
    frames_per_second: u32,
    duration_s: f32,
    sounds: []const Sound,
};

/// The name of a clip file without its extensions (`bee_intro` for `bee_intro.clip.zon`).
pub fn fileStem(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

/// Every key of the clip's `sound` tracks, as files in the project, owned by `gpa` (free with
/// `freeSounds`). Keys whose sound isn't in the project are left out.
pub fn soundsOf(gpa: std.mem.Allocator, clip: eggy.assets.clip.Clip, project_dir: []const u8, assets: *ProjectAssets) ![]Sound {
    var sounds: std.ArrayList(Sound) = .empty;
    errdefer {
        for (sounds.items) |sound| gpa.free(sound.path);
        sounds.deinit(gpa);
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    for (clip.tracks) |track| {
        if (track.property != .sound) continue;
        for (track.keys) |key| {
            const relative = assets.label(arena_state.allocator(), key.text);
            if (std.mem.eql(u8, relative, key.text)) continue;
            const path = try std.fs.path.join(gpa, &.{ project_dir, relative });
            errdefer gpa.free(path);
            try sounds.append(gpa, .{ .path = path, .delay_ms = @intFromFloat(@max(0, key.time_s) * 1000) });
        }
    }
    return sounds.toOwnedSlice(gpa);
}

pub fn freeSounds(gpa: std.mem.Allocator, sounds: []Sound) void {
    for (sounds) |sound| gpa.free(sound.path);
    gpa.free(sounds);
}

/// The `ffmpeg` command for `inputs`, in `arena`: the frames at their rate, each sound delayed
/// to its key and all mixed at full volume, cut to the clip's length.
pub fn arguments(arena: std.mem.Allocator, inputs: Inputs) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "ffmpeg", "-y", "-loglevel", "error", "-framerate" });
    try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{inputs.frames_per_second}));
    try argv.appendSlice(arena, &.{ "-i", try std.fs.path.join(arena, &.{ inputs.frames_dir, frame_pattern_ffmpeg }) });
    for (inputs.sounds) |sound| try argv.appendSlice(arena, &.{ "-i", sound.path });
    if (inputs.sounds.len > 0) {
        var graph: std.ArrayList(u8) = .empty;
        for (inputs.sounds, 1..) |sound, index| try graph.print(arena, "[{d}:a]adelay={d}:all=1[a{d}];", .{ index, sound.delay_ms, index });
        for (1..inputs.sounds.len + 1) |index| try graph.print(arena, "[a{d}]", .{index});
        try graph.print(arena, "amix=inputs={d}:normalize=0[aout]", .{inputs.sounds.len});
        try argv.appendSlice(arena, &.{ "-filter_complex", graph.items, "-map", "0:v", "-map", "[aout]", "-c:a", "aac", "-b:a", "192k" });
    }
    try argv.appendSlice(arena, &.{ "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-t" });
    const length_s = inputs.duration_s + 1 / @as(f32, @floatFromInt(inputs.frames_per_second));
    try argv.append(arena, try std.fmt.allocPrint(arena, "{d:.3}", .{length_s}));
    try argv.append(arena, try std.fs.path.join(arena, &.{ inputs.out_dir, "film.mp4" }));
    return argv.items;
}

pub const Result = enum(u8) { running, done, not_installed, failed };

/// `ffmpeg` running on a thread of its own.
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    thread: std.Thread,
    state: std.atomic.Value(u8) = .init(@backingInt(Result.running)),

    /// Start encoding `inputs` (copied). Thread and allocation errors propagate; `ffmpeg`'s own
    /// show in `result`.
    pub fn start(gpa: std.mem.Allocator, inputs: Inputs) !*Encoder {
        const self = try gpa.create(Encoder);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .arena = .init(gpa), .argv = &.{}, .thread = undefined };
        errdefer self.arena.deinit();
        self.argv = try arguments(self.arena.allocator(), inputs);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn result(self: *const Encoder) Result {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }

    /// Wait for `ffmpeg` to end, and free the encoder.
    pub fn destroy(self: *Encoder) void {
        self.thread.join();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    fn run(self: *Encoder) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const outcome: Result = blk: {
            var child = std.process.spawn(io, .{ .argv = self.argv, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit }) catch |err| {
                if (err == error.FileNotFound) break :blk .not_installed;
                std.log.err("cannot start ffmpeg: {t}", .{err});
                break :blk .failed;
            };
            const term = child.wait(io) catch |err| {
                std.log.err("ffmpeg didn't finish: {t}", .{err});
                break :blk .failed;
            };
            break :blk switch (term) {
                .exited => |code| if (code == 0) .done else .failed,
                else => .failed,
            };
        };
        self.state.store(@backingInt(outcome), .release);
    }
};

test "a clip's file name loses its extensions" {
    try std.testing.expectEqualStrings("bee_intro", fileStem("bee_intro.clip.zon"));
    try std.testing.expectEqualStrings("walk", fileStem("walk"));
}

test "the command mixes each sound in at its key, and cuts to the clip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buzz = "/p/resources/buzz.wav".*;
    var jingle = "/p/resources/jingle.mp3".*;
    const argv = try arguments(arena.allocator(), .{
        .frames_dir = "/p/zig-out/film/bee_intro-1/frames",
        .out_dir = "/p/zig-out/film/bee_intro-1",
        .frames_per_second = 60,
        .duration_s = 12,
        .sounds = &.{ .{ .path = &buzz, .delay_ms = 0 }, .{ .path = &jingle, .delay_ms = 9200 } },
    });
    const joined = try std.mem.join(arena.allocator(), " ", argv);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-framerate 60 -i /p/zig-out/film/bee_intro-1/frames/frame_%05d.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "[1:a]adelay=0:all=1[a1];[2:a]adelay=9200:all=1[a2];[a1][a2]amix=inputs=2:normalize=0[aout]") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-t 12.017 /p/zig-out/film/bee_intro-1/film.mp4") != null);

    var name: [32]u8 = undefined;
    try std.testing.expectEqualStrings("frame_00042.png", try std.fmt.bufPrint(&name, frame_pattern_format, .{42}));
}
