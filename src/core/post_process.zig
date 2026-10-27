//! Post-processing settings: tone mapping, bloom and colour grading applied to the rendered scene.
const std = @import("std");
const ecs = @import("clutch");
const camera = @import("camera.zig");

/// How the scene's light is fitted into what a display shows.
pub const ToneMapping = enum(u32) {
    /// Lit surfaces fit themselves (an ACES curve in the mesh shader); unlit ones and the rest
    /// pass through. Eggy's look before post-processing.
    surface,
    /// The ACES filmic curve over the whole image.
    aces,
    /// AgX: softer highlights that keep their hue as they brighten.
    agx,
    /// Reinhard: each channel divided by one more than itself.
    reinhard,
    /// Clip at white.
    none,
};

/// Light above `threshold` spread into a glow, added back at `intensity` (0 is off).
pub const Bloom = struct {
    intensity: f32 = 0,
    /// The brightness, in linear scene light, a pixel needs before it glows.
    threshold: f32 = 1,
};

/// The look of a camera's image. On a `Camera` it replaces the scene's `Environment.post`.
pub const PostProcess = struct {
    /// Marks it in the editor (nf-md-image_filter_hdr).
    pub const icon = "\u{f02f9}";
    pub const dependencies = .{camera.Camera};
    tone_mapping: ToneMapping = .surface,
    bloom: Bloom = .{},
    /// 1 leaves contrast as it is; more pushes tones apart around middle grey.
    contrast: f32 = 1,
    /// 1 leaves colour as it is; 0 is greyscale.
    saturation: f32 = 1,
    /// How dark the corners get, 0 (none) to 1.
    vignette: f32 = 0,

    pub fn validate(self: PostProcess) error{InvalidPostProcess}!void {
        for ([_]f32{ self.bloom.intensity, self.bloom.threshold, self.contrast, self.saturation, self.vignette }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPostProcess;
        if (self.vignette > 1) return error.InvalidPostProcess;
    }

    /// The settings as the renderer's plain data.
    pub fn frame(self: PostProcess) Frame {
        return .{
            .tone_mapping = @backingInt(self.tone_mapping),
            .bloom = .{ self.bloom.intensity, self.bloom.threshold },
            .grade = .{ self.contrast, self.saturation, self.vignette, 0 },
        };
    }
};

/// Plain C data for the renderer, gathered where the game's ECS type numbering lives.
pub const Frame = extern struct {
    tone_mapping: u32 = @backingInt(ToneMapping.surface),
    /// Intensity, threshold.
    bloom: [2]f32 = .{ 0, 1 },
    /// Contrast, saturation, vignette, reserved.
    grade: [4]f32 = .{ 1, 1, 0, 0 },

    /// Whether the post pass maps tones, so the mesh shader leaves its own curve out.
    pub fn mapsTones(self: Frame) bool {
        return self.tone_mapping != @backingInt(ToneMapping.surface);
    }
};

/// The active camera's `PostProcess`, else `scene` (the environment's). A camera's settings
/// that don't validate are an error rather than silently replaced.
pub fn forActiveCamera(world: *ecs.World, scene: PostProcess) error{InvalidPostProcess}!PostProcess {
    const entity = (camera.Cameras{ .world = world }).activeEntity() orelse return scene;
    const own = world.get(entity, PostProcess) orelse return scene;
    try own.validate();
    return own.*;
}

test "a camera's post-processing replaces the environment's" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const scene = PostProcess{ .tone_mapping = .aces };
    try std.testing.expectEqual(ToneMapping.aces, (try forActiveCamera(&world, scene)).tone_mapping);

    const eye = try world.spawn(.{camera.Camera{}});
    try std.testing.expectEqual(ToneMapping.aces, (try forActiveCamera(&world, scene)).tone_mapping);
    try world.addComponent(eye, PostProcess{ .tone_mapping = .agx, .vignette = 0.4 });
    const chosen = try forActiveCamera(&world, scene);
    try std.testing.expectEqual(ToneMapping.agx, chosen.tone_mapping);
    try std.testing.expectEqual(@as(f32, 0.4), chosen.frame().grade[2]);

    world.get(eye, PostProcess).?.vignette = 2;
    try std.testing.expectError(error.InvalidPostProcess, forActiveCamera(&world, scene));
}
