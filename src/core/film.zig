//! Film: the scene rendered offscreen at a fixed step and read back as pixels, to make a video of
//! a clip whatever the frame rate the screen manages. Each frame can be several renders across
//! the shutter, averaged, for motion blur. The host poses the world for each sample time
//! (`Settings.sampleTime`), renders it with `Recorder.render`, and after the GPU has run that
//! collects it (`Recorder.collect`); every `motion_blur_samples` renders make a frame.
const std = @import("std");
const vit = @import("vitellus");
const mesh = @import("mesh.zig");
const camera = @import("camera.zig");
const Graphics = @import("graphics.zig").Graphics;
const SceneTexture = @import("scene_texture.zig").SceneTexture;

/// How a film is rendered.
pub const Settings = struct {
    /// Multiples of 64 wide, so rows read back without padding on every backend.
    width_px: u32 = 1920,
    height_px: u32 = 1080,
    frames_per_second: u32 = 60,
    /// Renders averaged into each frame across a half-frame shutter; 1 for none.
    motion_blur_samples: u32 = 1,

    pub const Error = error{InvalidFilmSettings};

    pub fn validate(self: Settings) Error!void {
        if (self.width_px == 0 or self.width_px % 64 != 0 or self.height_px == 0) return error.InvalidFilmSettings;
        if (self.width_px > 8192 or self.height_px > 8192) return error.InvalidFilmSettings;
        if (self.frames_per_second == 0 or self.frames_per_second > 240) return error.InvalidFilmSettings;
        if (self.motion_blur_samples == 0 or self.motion_blur_samples > 64) return error.InvalidFilmSettings;
    }

    /// How many frames a clip `duration_s` long makes, its first and last moments included.
    pub fn frameCount(self: Settings, duration_s: f32) u32 {
        if (!(duration_s > 0)) return 1;
        const frames = @floor(duration_s * @as(f32, @floatFromInt(self.frames_per_second)) + 0.0001);
        return @as(u32, @intFromFloat(@min(frames, 1e7))) + 1;
    }

    /// The clip time of render `sample` of `frame`: the frame's moment, then on through half a
    /// frame for motion blur.
    pub fn sampleTime(self: Settings, frame: u32, sample: u32) f32 {
        const step = 1 / @as(f32, @floatFromInt(self.frames_per_second));
        const shutter = if (self.motion_blur_samples > 1) 0.5 * step * @as(f32, @floatFromInt(sample)) / @as(f32, @floatFromInt(self.motion_blur_samples)) else 0;
        return @as(f32, @floatFromInt(frame)) * step + shutter;
    }
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    settings: Settings,
    scene: SceneTexture,
    readback: vit.Buffer,
    /// Per channel sums of the renders of the frame under way.
    sums: []u32,
    /// The finished frame, RGBA8, rows top to bottom.
    frame: []u8,
    samples: u32 = 0,
    /// A render was recorded and not yet collected.
    pending: bool = false,
    /// The color target's channels come blue first.
    bgra: bool,

    /// Make the offscreen target and readback memory for frames `settings` describes.
    /// Pair with `deinit` once the GPU is done with it.
    pub fn init(gpa: std.mem.Allocator, graphics: *Graphics, settings: Settings) !Recorder {
        try settings.validate();
        const length = @as(usize, settings.width_px) * settings.height_px * 4;
        var scene = try SceneTexture.init(graphics);
        errdefer scene.deinit();
        const readback = try vit.Buffer.init(graphics.device, .{ .label = "film readback", .size = length, .usage = .{ .transfer_dst = true }, .memory = .readback });
        errdefer readback.deinit();
        const sums = try gpa.alloc(u32, length);
        errdefer gpa.free(sums);
        const frame = try gpa.alloc(u8, length);
        @memset(sums, 0);
        return .{
            .gpa = gpa,
            .settings = settings,
            .scene = scene,
            .readback = readback,
            .sums = sums,
            .frame = frame,
            .bgra = graphics.color_format == .bgra8_unorm or graphics.color_format == .bgra8_unorm_srgb,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.gpa.free(self.frame);
        self.gpa.free(self.sums);
        self.readback.deinit();
        self.scene.deinit();
    }

    /// Record a render of `drawables` through `view` into `cmd`, and its copy into readback
    /// memory. Call `collect` once the GPU has run `cmd`, before the next `render`.
    pub fn render(self: *Recorder, graphics: *Graphics, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, view: camera.View) !void {
        std.debug.assert(!self.pending);
        const extent = vit.Extent2D{ .width = self.settings.width_px, .height = self.settings.height_px };
        try self.scene.render(graphics, cmd, extent, drawables, view, &.{}, false);
        const target = self.scene.target.?.texture;
        try cmd.barrier(&.{.{ .texture = .{ .texture = target, .before = .sampled, .after = .copy_source } }});
        try cmd.copyTextureToBuffer(.{ .buffer = self.readback, .bytes_per_row = extent.width * 4, .texture = .{ .texture = target }, .extent = .{ .width = extent.width, .height = extent.height } });
        try cmd.barrier(&.{.{ .texture = .{ .texture = target, .before = .copy_source, .after = .sampled } }});
        self.pending = true;
    }

    /// Wait for the GPU to finish the last `render` and add it to the frame under way. Returns
    /// the finished frame (RGBA8, rows top to bottom, valid until the next call) once it has
    /// all its samples, else null.
    pub fn collect(self: *Recorder, graphics: *Graphics) !?[]const u8 {
        if (!self.pending) return null;
        try graphics.queue.waitIdle();
        self.pending = false;
        const mapped = try self.readback.map(.read, .{ .size = self.sums.len });
        defer self.readback.unmap(null);
        accumulate(self.sums, mapped[0..self.sums.len], self.bgra);
        self.samples += 1;
        if (self.samples < self.settings.motion_blur_samples) return null;
        average(self.frame, self.sums, self.samples);
        @memset(self.sums, 0);
        self.samples = 0;
        return self.frame;
    }
};

/// Add `pixels` (RGBA8, or BGRA8 when `bgra`) into `sums` as RGBA.
fn accumulate(sums: []u32, pixels: []const u8, bgra: bool) void {
    var at: usize = 0;
    while (at + 4 <= pixels.len) : (at += 4) {
        const red = if (bgra) pixels[at + 2] else pixels[at];
        const blue = if (bgra) pixels[at] else pixels[at + 2];
        sums[at] += red;
        sums[at + 1] += pixels[at + 1];
        sums[at + 2] += blue;
        // An opaque film whatever the scene's alpha.
        sums[at + 3] += 255;
    }
}

/// `frame` as `sums` over `count` renders, rounded.
fn average(frame: []u8, sums: []const u32, count: u32) void {
    for (frame, sums) |*out, sum| out.* = @intCast((sum + count / 2) / count);
}

test "a clip's frames cover its first and last moments, and blur samples spread across half a frame" {
    const film = Settings{ .frames_per_second = 10, .motion_blur_samples = 4 };
    try std.testing.expectEqual(@as(u32, 21), film.frameCount(2));
    try std.testing.expectEqual(@as(u32, 1), film.frameCount(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), film.sampleTime(3, 0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3 + 0.0375), film.sampleTime(3, 3), 1e-6);
    try std.testing.expectEqual(@as(f32, 0.5), (Settings{ .frames_per_second = 2 }).sampleTime(1, 0));
    try film.validate();
    try std.testing.expectError(error.InvalidFilmSettings, (Settings{ .width_px = 1000 }).validate());
}

test "renders average into an opaque RGBA frame, blue-first targets swapped" {
    var sums: [4]u32 = @splat(0);
    accumulate(&sums, &.{ 10, 20, 30, 0 }, true);
    accumulate(&sums, &.{ 20, 40, 60, 0 }, true);
    var frame: [4]u8 = undefined;
    average(&frame, &sums, 2);
    try std.testing.expectEqualSlices(u8, &.{ 45, 30, 15, 255 }, &frame);
}
