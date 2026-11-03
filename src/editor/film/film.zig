//! Film: a cutscene of the open scene rendered to a video, from File > Export's Film page. The
//! clip an entity's `Animator` plays is posed (through the animation preview) at each sample
//! time, rendered offscreen through the game's camera at the size and frame rate chosen
//! (`eggy.film`), and written as PNG frames into the project's `zig-out/film/`; when `ffmpeg` is
//! installed they are encoded into an MP4 with the clip's sounds. Rendering goes a frame at a time
//! inside the editor's own frames, so the editor stays responsive and shows the film as it goes.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const animation_dock = @import("../animation_dock/animation_dock.zig");
const png_writer = @import("../assets/png_writer.zig");
const encode = @import("encode.zig");

const key_len = eggy.assets.id.key_len;

pub const sizes = [_][2]u32{ .{ 1280, 720 }, .{ 1920, 1080 }, .{ 2560, 1440 }, .{ 3840, 2160 } };
pub const size_labels = [_][]const u8{ "1280 × 720", "1920 × 1080", "2560 × 1440", "3840 × 2160" };
pub const rates = [_]u32{ 24, 30, 60 };
pub const rate_labels = [_][]const u8{ "24 fps", "30 fps", "60 fps" };
pub const blurs = [_]u32{ 1, 4, 8, 16 };
pub const blur_labels = [_][]const u8{ "Off", "4 samples", "8 samples", "16 samples" };

pub const Format = enum {
    /// Frames encoded with H.264, with the clip's sounds, by `ffmpeg`.
    mp4,
    png_frames,

    pub const labels = [_][]const u8{ "MP4 (H.264) with sound", "PNG frames" };
};

/// What the session works with, borrowed for one call.
pub const Env = struct {
    game: *const HotGame,
    app: *eggy.App,
    assets: *ProjectAssets,
    project_dir: []const u8,
    /// Room for the meshes gathered each frame (the editor's).
    drawables: []eggy.mesh.Drawable,
};

/// A cutscene in the open scene: an entity whose `Animator` names an authored clip.
pub const Source = struct {
    entity: eggy.ecs.EntityId,
    clip: [key_len]u8,
    /// Its entity's name and the clip's file, owned.
    label: []u8,
};

pub const Stage = enum { rendering, encoding, done, failed };

/// How a film is coming along, for the Export window.
pub const Progress = struct {
    stage: Stage,
    label: []const u8,
    frame: u32,
    frames: u32,
    /// What happened, once it is over: where it went, or why it failed.
    message: []const u8,
};

pub const Film = struct {
    gpa: std.mem.Allocator,
    size: usize = 1,
    rate: usize = 2,
    blur: usize = 0,
    format: Format = .mp4,
    sources: std.ArrayList(Source) = .empty,
    chosen: usize = 0,
    job: ?*Job = null,

    pub fn deinit(self: *Film, env: ?Env) void {
        if (self.job) |job| self.endJob(job, env);
        self.clearSources();
        self.sources.deinit(self.gpa);
    }

    /// Find the cutscenes the open scene has, keeping the one chosen where it can.
    pub fn findSources(self: *Film, env: Env) void {
        const before: ?eggy.ecs.EntityId = if (self.chosen < self.sources.items.len) self.sources.items[self.chosen].entity else null;
        self.clearSources();
        self.chosen = 0;
        for (env.app.world.slots.items, 0..) |slot, index| {
            if (!slot.alive) continue;
            const entity = eggy.ecs.EntityId{ .id = @intCast(index), .generation = slot.generation };
            const keys = animation_dock.clipKeysOf(env.game, env.app, entity);
            if (keys.authored_len == 0) continue;
            var name_buffer: [eggy.Name.max_len]u8 = undefined;
            const name = env.game.readName(env.app, entity, &name_buffer) orelse "Unnamed";
            var path_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer path_arena.deinit();
            const path = env.assets.label(path_arena.allocator(), &keys.authored);
            const label = std.fmt.allocPrint(self.gpa, "{s} · {s}", .{ name, std.fs.path.basename(path) }) catch continue;
            self.sources.append(self.gpa, .{ .entity = entity, .clip = keys.authored, .label = label }) catch {
                self.gpa.free(label);
                continue;
            };
            if (before) |kept| if (kept.eql(entity)) {
                self.chosen = self.sources.items.len - 1;
            };
        }
    }

    /// The cutscenes as the Export window lists them.
    pub fn sourceLabels(self: *const Film, arena: std.mem.Allocator) []const []const u8 {
        const labels = arena.alloc([]const u8, self.sources.items.len) catch return &.{};
        for (labels, self.sources.items) |*label, source| label.* = source.label;
        return labels;
    }

    pub fn settings(self: *const Film) eggy.film.Settings {
        return .{ .width_px = sizes[self.size][0], .height_px = sizes[self.size][1], .frames_per_second = rates[self.rate], .motion_blur_samples = blurs[self.blur] };
    }

    /// Start rendering the chosen cutscene. Errors: no cutscene, a clip that doesn't load, or
    /// the film's memory or folder can't be made.
    pub fn start(self: *Film, env: Env) !void {
        if (self.job != null) return error.FilmUnderWay;
        if (self.chosen >= self.sources.items.len) return error.NoCutscene;
        const source = self.sources.items[self.chosen];
        const clip = env.app.graphics.clips.authored(&source.clip) orelse return error.ClipNotLoaded;
        const job = try self.gpa.create(Job);
        errdefer self.gpa.destroy(job);
        job.* = try Job.init(self.gpa, env, source, clip.*, self.settings(), self.format);
        self.job = job;
    }

    /// Whether a film is being rendered, which the scene's pose belongs to while it is.
    pub fn busy(self: *const Film) bool {
        const job = self.job orelse return false;
        return job.stage == .rendering;
    }

    /// Once an editor frame, while rendering: collect the last render, write a finished frame,
    /// and pose and render the next sample into `cmd`. When the last frame is written, the pose
    /// is put back and encoding starts.
    pub fn step(self: *Film, env: Env, cmd: eggy.vit.CommandBuffer) void {
        const job = self.job orelse return;
        switch (job.stage) {
            .rendering => job.render(env, cmd) catch |err| job.fail(env, "Rendering stopped", err),
            .encoding => job.pollEncoder(),
            .done, .failed => {},
        }
    }

    pub fn progress(self: *const Film) ?Progress {
        const job = self.job orelse return null;
        return .{ .stage = job.stage, .label = job.label, .frame = job.frame, .frames = job.frames, .message = job.message.items };
    }

    /// Stop the film under way, keeping the frames written, or forget one that is over.
    pub fn close(self: *Film, env: ?Env) void {
        const job = self.job orelse return;
        self.endJob(job, env);
    }

    fn endJob(self: *Film, job: *Job, env: ?Env) void {
        job.deinit(env);
        self.gpa.destroy(job);
        self.job = null;
    }

    fn clearSources(self: *Film) void {
        for (self.sources.items) |source| self.gpa.free(source.label);
        self.sources.clearRetainingCapacity();
    }
};

const Job = struct {
    gpa: std.mem.Allocator,
    recorder: eggy.film.Recorder,
    entity: eggy.ecs.EntityId,
    clip_key: [key_len]u8,
    format: Format,
    duration_s: f32,
    frame: u32 = 0,
    frames: u32,
    stage: Stage = .rendering,
    posed: bool = false,
    label: []u8,
    /// Where the film goes (absolute), and its frames.
    out_dir: []u8,
    frames_dir: []u8,
    /// The `ffmpeg` command, made when rendering ends.
    encoder: ?*encode.Encoder = null,
    sounds: []encode.Sound,
    message: std.ArrayList(u8) = .empty,

    fn init(gpa: std.mem.Allocator, env: Env, source: Source, clip: eggy.assets.clip.Clip, settings: eggy.film.Settings, format: Format) !Job {
        var recorder = try eggy.film.Recorder.init(gpa, &env.app.graphics, settings);
        errdefer recorder.deinit();
        const label = try gpa.dupe(u8, source.label);
        errdefer gpa.free(label);

        // `zig-out/film/<clip>-<n>/`, the first number free, so films never overwrite.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const clip_name = encode.fileStem(std.fs.path.basename(env.assets.label(arena, &source.clip)));
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const out_dir = try freeFolder(gpa, io, env.project_dir, clip_name);
        errdefer gpa.free(out_dir);
        const frames_dir = try std.fs.path.join(gpa, &.{ out_dir, "frames" });
        errdefer gpa.free(frames_dir);
        try std.Io.Dir.cwd().createDirPath(io, frames_dir);

        // The sounds the clip starts, from the files their keys name, for the encoder to mix in.
        const sounds = try encode.soundsOf(gpa, clip, env.project_dir, env.assets);
        return .{
            .gpa = gpa,
            .recorder = recorder,
            .entity = source.entity,
            .clip_key = source.clip,
            .format = format,
            .duration_s = clip.duration_s,
            .frames = settings.frameCount(clip.duration_s),
            .label = label,
            .out_dir = out_dir,
            .frames_dir = frames_dir,
            .sounds = sounds,
        };
    }

    fn deinit(self: *Job, env: ?Env) void {
        if (self.posed) if (env) |found| found.game.endAnimationPreview(found.app);
        if (self.encoder) |encoder| encoder.destroy();
        encode.freeSounds(self.gpa, self.sounds);
        self.message.deinit(self.gpa);
        self.gpa.free(self.frames_dir);
        self.gpa.free(self.out_dir);
        self.gpa.free(self.label);
        self.recorder.deinit();
    }

    fn render(self: *Job, env: Env, cmd: eggy.vit.CommandBuffer) !void {
        // The render recorded last frame has run by now: add it, and write the frame it finished.
        if (try self.recorder.collect(&env.app.graphics)) |pixels| {
            try self.writeFrame(pixels);
            self.frame += 1;
        }
        if (self.frame >= self.frames) return self.finishRendering(env);

        // Pose the next sample and render it through the game's camera.
        if (!self.posed) {
            if (!env.game.beginAnimationPreview(env.app, self.entity)) return error.CannotPose;
            self.posed = true;
        }
        const time = self.recorder.settings.sampleTime(self.frame, self.recorder.samples);
        if (!env.game.showAnimationPreview(env.app, &self.clip_key, "", time)) return error.CannotPose;
        const view = env.game.findCamera(env.app) orelse return error.NoCamera;
        const drawn = env.game.gatherMeshes(env.app, env.drawables);
        try self.recorder.render(&env.app.graphics, cmd, drawn, view);
    }

    fn writeFrame(self: *Job, pixels: []const u8) !void {
        var png: std.Io.Writer.Allocating = .init(self.gpa);
        defer png.deinit();
        try png_writer.write(self.gpa, &png.writer, self.recorder.settings.width_px, self.recorder.settings.height_px, pixels);
        var name: [32]u8 = undefined;
        const file = try std.fmt.bufPrint(&name, encode.frame_pattern_format, .{self.frame});
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.frames_dir, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = file, .data = png.written() });
    }

    fn finishRendering(self: *Job, env: Env) void {
        env.game.endAnimationPreview(env.app);
        self.posed = false;
        if (self.format == .png_frames) return self.finish(.done, "The frames are in {s}", .{self.frames_dir});
        self.encoder = encode.Encoder.start(self.gpa, .{
            .frames_dir = self.frames_dir,
            .out_dir = self.out_dir,
            .frames_per_second = self.recorder.settings.frames_per_second,
            .duration_s = self.duration_s,
            .sounds = self.sounds,
        }) catch |err| return self.finish(.failed, "Couldn't start ffmpeg ({t}). The frames are in {s}", .{ err, self.frames_dir });
        self.stage = .encoding;
    }

    fn pollEncoder(self: *Job) void {
        const encoder = self.encoder orelse return;
        switch (encoder.result()) {
            .running => {},
            .done => self.finish(.done, "Saved {s}{c}film.mp4", .{ self.out_dir, std.fs.path.sep }),
            .not_installed => self.finish(.done, "ffmpeg isn't installed, so the film is left as PNG frames in {s}", .{self.frames_dir}),
            .failed => self.finish(.failed, "ffmpeg couldn't encode the film; the frames are in {s}", .{self.frames_dir}),
        }
    }

    fn fail(self: *Job, env: Env, what: []const u8, err: anyerror) void {
        if (self.posed) env.game.endAnimationPreview(env.app);
        self.posed = false;
        const why = switch (err) {
            error.NoCamera => "the scene has no active camera to film through",
            error.CannotPose => "the cutscene couldn't be posed; see the Console",
            else => @errorName(err),
        };
        self.finish(.failed, "{s}: {s}.", .{ what, why });
    }

    fn finish(self: *Job, stage: Stage, comptime format: []const u8, args: anytype) void {
        self.stage = stage;
        self.message.clearRetainingCapacity();
        self.message.print(self.gpa, format, args) catch {};
    }
};

/// `<project>/zig-out/film/<name>-<n>`, the first `n` from 1 not taken, owned by `gpa`.
fn freeFolder(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8, name: []const u8) ![]u8 {
    var number: u32 = 1;
    while (number < 10_000) : (number += 1) {
        var buffer: [16]u8 = undefined;
        const leaf = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ name, try std.fmt.bufPrint(&buffer, "{d}", .{number}) });
        defer gpa.free(leaf);
        const path = try std.fs.path.join(gpa, &.{ project_dir, "zig-out", "film", leaf });
        std.Io.Dir.cwd().access(io, path, .{}) catch return path;
        gpa.free(path);
    }
    return error.PathAlreadyExists;
}

test "a film's folder takes the first free number" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const first = try freeFolder(gpa, std.testing.io, root, "bee_intro");
    defer gpa.free(first);
    try std.testing.expect(std.mem.endsWith(u8, first, "bee_intro-1"));
    try std.Io.Dir.cwd().createDirPath(std.testing.io, first);
    const second = try freeFolder(gpa, std.testing.io, root, "bee_intro");
    defer gpa.free(second);
    try std.testing.expect(std.mem.endsWith(u8, second, "bee_intro-2"));
}

test {
    _ = encode;
}
