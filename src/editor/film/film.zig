//! Film: cutscenes of the open scene rendered to videos, from File > Export's Film page, as a
//! queue filmed one after another, each with its own size, rate, blur and format. The clip an
//! entity's `Animator` plays is posed (through the animation preview) at each sample time,
//! rendered offscreen through its camera cuts (or the game's camera) at the size and frame rate
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
const sdl3 = eggy.sdl_adapter.sdl;

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

/// How a film is rendered and saved.
pub const Look = struct {
    size: usize = 1,
    rate: usize = 2,
    blur: usize = 0,
    format: Format = .mp4,

    pub fn settings(self: Look) eggy.film.Settings {
        return .{ .width_px = sizes[self.size][0], .height_px = sizes[self.size][1], .frames_per_second = rates[self.rate], .motion_blur_samples = blurs[self.blur] };
    }

    /// In a few words, for the queue: `MP4, 1920 × 1080, 60 fps`.
    pub fn summary(self: Look, buffer: []u8) []const u8 {
        const format = if (self.format == .mp4) "MP4" else "PNG frames";
        return std.fmt.bufPrint(buffer, "{s}, {s}, {s}", .{ format, size_labels[self.size], rate_labels[self.rate] }) catch format;
    }
};

/// A cutscene waiting in the queue, being filmed, or filmed.
pub const Queued = struct {
    source: Source,
    look: Look,
    state: enum { waiting, filming, done, failed } = .waiting,
    /// Where it went or why it failed, once over; owned.
    message: []u8 = &.{},
};

/// How a queued film is coming along, for the Export window.
pub const Progress = struct {
    stage: Stage,
    frame: u32,
    frames: u32,
    /// About how long the rest takes, from how long the frames so far took; null early on.
    left_s: ?u32,
};

pub const Film = struct {
    gpa: std.mem.Allocator,
    /// What the next cutscene added is filmed with.
    next: Look = .{},
    sources: std.ArrayList(Source) = .empty,
    chosen: usize = 0,
    queue: std.ArrayList(Queued) = .empty,
    /// The queued film whose settings the page edits; null for `next`.
    picked: ?usize = null,
    /// Filming the queue (or showing how it went) since `filmAll`, until `close`.
    active: bool = false,
    /// The queued film being made, and its job.
    running: ?usize = null,
    job: ?*Job = null,

    pub fn deinit(self: *Film, env: ?Env) void {
        if (self.job) |job| self.endJob(job, env);
        self.clearSources();
        self.sources.deinit(self.gpa);
        for (self.queue.items) |queued| self.freeQueued(queued);
        self.queue.deinit(self.gpa);
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

    /// The settings the page shows: the picked queued film's, or the next one's.
    pub fn editing(self: *Film) *Look {
        if (self.picked) |index| if (index < self.queue.items.len and self.queue.items[index].state == .waiting) return &self.queue.items[index].look;
        return &self.next;
    }

    /// Queue the chosen cutscene with the next film's settings, and pick it.
    /// Errors: no cutscene, or out of memory.
    pub fn add(self: *Film) !void {
        if (self.chosen >= self.sources.items.len) return error.NoCutscene;
        const source = self.sources.items[self.chosen];
        const label = try self.gpa.dupe(u8, source.label);
        errdefer self.gpa.free(label);
        try self.queue.append(self.gpa, .{ .source = .{ .entity = source.entity, .clip = source.clip, .label = label }, .look = self.next });
        self.picked = self.queue.items.len - 1;
    }

    /// Take queued film `index` out, unless it is being filmed.
    pub fn remove(self: *Film, index: usize) void {
        if (index >= self.queue.items.len or self.running == index) return;
        self.freeQueued(self.queue.orderedRemove(index));
        if (self.running) |running| if (running > index) {
            self.running = running - 1;
        };
        self.picked = null;
    }

    /// Film every waiting cutscene in turn; with none queued, the chosen one. Errors: nothing
    /// to film, or the first film can't start.
    pub fn filmAll(self: *Film, env: Env) !void {
        if (self.job != null) return error.FilmUnderWay;
        if (self.queue.items.len == 0) try self.add();
        for (self.queue.items) |*queued| if (queued.state != .waiting) {
            self.gpa.free(queued.message);
            queued.message = &.{};
            queued.state = .waiting;
        };
        self.active = true;
        self.startNext(env);
    }

    /// Whether a film is being rendered, which the scene's pose belongs to while it is.
    pub fn busy(self: *const Film) bool {
        const job = self.job orelse return false;
        return job.stage == .rendering;
    }

    /// Once an editor frame, while filming: collect the last render, write a finished frame,
    /// and pose and render the next sample into `cmd`. When a film is over the next starts.
    pub fn step(self: *Film, env: Env, cmd: eggy.vit.CommandBuffer) void {
        const job = self.job orelse return;
        switch (job.stage) {
            .rendering => job.render(env, cmd) catch |err| job.fail(env, "Rendering stopped", err),
            .encoding => job.pollEncoder(),
            .done, .failed => {
                self.settle(job, env);
                self.startNext(env);
            },
        }
    }

    /// How queued film `index` is coming along, while it is filmed.
    pub fn progress(self: *const Film, index: usize) ?Progress {
        if (self.running != index) return null;
        const job = self.job orelse return null;
        const elapsed_ms = sdl3.timer.getMillisecondsSinceInit() -| job.started_ms;
        const left: ?u32 = if (job.frame >= 4 and job.stage == .rendering) @intCast(elapsed_ms * (job.frames - job.frame) / job.frame / 1000) else null;
        return .{ .stage = job.stage, .frame = job.frame, .frames = job.frames, .left_s = left };
    }

    /// Whether every queued film is over.
    pub fn finished(self: *const Film) bool {
        return self.job == null;
    }

    /// Stop filming, keeping the frames written; the rest of the queue waits. Leaves the
    /// progress view.
    pub fn close(self: *Film, env: ?Env) void {
        if (self.job) |job| {
            if (self.running) |index| self.queue.items[index].state = .waiting;
            self.endJob(job, env);
        }
        self.running = null;
        self.active = false;
    }

    /// Start the first waiting film; one that can't start fails and the next is tried.
    fn startNext(self: *Film, env: Env) void {
        for (self.queue.items, 0..) |*queued, index| {
            if (queued.state != .waiting) continue;
            const clip = env.app.graphics.clips.authored(&queued.source.clip) orelse {
                self.failQueued(queued, "Its clip can't be read: see the Console.");
                continue;
            };
            const job = self.gpa.create(Job) catch return self.failQueued(queued, "Out of memory.");
            job.* = Job.init(self.gpa, env, queued.source, clip.*, queued.look.settings(), queued.look.format) catch |err| {
                self.gpa.destroy(job);
                std.log.err("cannot start the film of {s}: {t}", .{ queued.source.label, err });
                self.failQueued(queued, "It couldn't start: see the Console.");
                continue;
            };
            queued.state = .filming;
            self.running = index;
            self.job = job;
            return;
        }
        self.running = null;
    }

    /// Record how the job of the running film ended, and drop the job.
    fn settle(self: *Film, job: *Job, env: Env) void {
        if (self.running) |index| {
            const queued = &self.queue.items[index];
            queued.state = if (job.stage == .done) .done else .failed;
            self.gpa.free(queued.message);
            queued.message = self.gpa.dupe(u8, job.message.items) catch &.{};
        }
        self.endJob(job, env);
        self.running = null;
    }

    fn failQueued(self: *Film, queued: *Queued, why: []const u8) void {
        queued.state = .failed;
        self.gpa.free(queued.message);
        queued.message = self.gpa.dupe(u8, why) catch &.{};
    }

    fn endJob(self: *Film, job: *Job, env: ?Env) void {
        job.deinit(env);
        self.gpa.destroy(job);
        self.job = null;
    }

    fn freeQueued(self: *Film, queued: Queued) void {
        self.gpa.free(queued.source.label);
        self.gpa.free(queued.message);
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
    /// When rendering began, to say how long the rest takes.
    started_ms: u64,

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
            .started_ms = sdl3.timer.getMillisecondsSinceInit(),
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

test "queued films keep their own settings, and the page edits the picked one" {
    var film = Film{ .gpa = std.testing.allocator };
    defer film.deinit(null);
    const label = try std.testing.allocator.dupe(u8, "bee · intro.clip.zon");
    try film.sources.append(std.testing.allocator, .{ .entity = .{ .id = 3, .generation = 0 }, .clip = @splat('a'), .label = label });

    try film.add();
    film.editing().format = .png_frames;
    film.picked = null;
    film.editing().size = 3;
    try film.add();
    try std.testing.expectEqual(Format.png_frames, film.queue.items[0].look.format);
    try std.testing.expectEqual(@as(usize, 1), film.queue.items[0].look.size);
    try std.testing.expectEqual(@as(usize, 3), film.queue.items[1].look.size);
    try std.testing.expectEqual(@as(?usize, 1), film.picked);

    film.remove(0);
    try std.testing.expectEqual(@as(usize, 1), film.queue.items.len);
    try std.testing.expectEqual(@as(usize, 3), film.queue.items[0].look.size);
    try std.testing.expectEqual(@as(?usize, null), film.picked);
}

test {
    _ = encode;
}
