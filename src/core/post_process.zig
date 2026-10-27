//! Post-processing settings: tone mapping, bloom and colour grading applied to the rendered scene.
const std = @import("std");
const ecs = @import("clutch");
const camera = @import("camera.zig");
const AssetRef = @import("refs.zig").AssetRef;

/// How many of a project's own passes one image can have.
pub const max_passes = 4;

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

/// A project's post shader (`float4 post(PostInput input)`) run over the scene's HDR light,
/// before bloom and grading, given `values` as `input.values`.
pub const Pass = struct {
    shader: AssetRef(.shader) = .{},
    values: [4]f32 = @splat(0),
};

/// The look of a camera's image. On a `Camera` it replaces the scene's `Environment.post`.
pub const PostProcess = struct {
    /// Marks it in the editor (nf-md-image_filter_hdr).
    pub const icon = "\u{f02f9}";
    pub const category = "Rendering";
    pub const dependencies = .{camera.Camera};
    tone_mapping: ToneMapping = .surface,
    bloom: Bloom = .{},
    /// 1 leaves contrast as it is; more pushes tones apart around middle grey.
    contrast: f32 = 1,
    /// 1 leaves colour as it is; 0 is greyscale.
    saturation: f32 = 1,
    /// How dark the corners get, 0 (none) to 1.
    vignette: f32 = 0,
    /// The project's own passes, in order; those without a shader are skipped.
    passes: [max_passes]Pass = @splat(.{}),

    pub fn validate(self: PostProcess) error{InvalidPostProcess}!void {
        for ([_]f32{ self.bloom.intensity, self.bloom.threshold, self.contrast, self.saturation, self.vignette }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPostProcess;
        if (self.vignette > 1) return error.InvalidPostProcess;
        for (self.passes) |pass| for (pass.values) |value| if (!std.math.isFinite(value)) return error.InvalidPostProcess;
    }

    /// The settings as the renderer's plain data. The passes' shader keys borrow `self`, so
    /// the frame lasts only while it does (in the world: until the world next changes).
    pub fn frame(self: *const PostProcess) Frame {
        var result = Frame{
            .tone_mapping = @backingInt(self.tone_mapping),
            .bloom = .{ self.bloom.intensity, self.bloom.threshold },
            .grade = .{ self.contrast, self.saturation, self.vignette, 0 },
        };
        for (&self.passes, 0..) |*pass, i| {
            result.pass_shaders[i] = &pass.shader.buffer;
            result.pass_shader_lens[i] = pass.shader.len;
            result.pass_values[i] = pass.values;
        }
        return result;
    }
};

/// Plain C data for the renderer, gathered where the game's ECS type numbering lives.
pub const Frame = extern struct {
    tone_mapping: u32 = @backingInt(ToneMapping.surface),
    /// Intensity, threshold.
    bloom: [2]f32 = .{ 0, 1 },
    /// Contrast, saturation, vignette, reserved.
    grade: [4]f32 = .{ 1, 1, 0, 0 },
    /// Each pass's shader key, borrowed from its `PostProcess`; empty for none.
    pass_shaders: [max_passes]?[*]const u8 = @splat(null),
    pass_shader_lens: [max_passes]u32 = @splat(0),
    pass_values: [max_passes][4]f32 = @splat(@splat(0)),

    /// Pass `index`'s shader key, or null when it has none.
    pub fn passShader(self: Frame, index: usize) ?[]const u8 {
        const key = self.pass_shaders[index] orelse return null;
        if (self.pass_shader_lens[index] == 0) return null;
        return key[0..self.pass_shader_lens[index]];
    }

    /// Whether the post pass maps tones, so the mesh shader leaves its own curve out.
    pub fn mapsTones(self: Frame) bool {
        return self.tone_mapping != @backingInt(ToneMapping.surface);
    }
};

/// The active camera's `PostProcess`, else `scene` (the environment's), borrowed from the world.
/// A camera's settings that don't validate are an error rather than silently replaced.
pub fn forActiveCamera(world: *ecs.World, scene: *const PostProcess) error{InvalidPostProcess}!*const PostProcess {
    const entity = (camera.Cameras{ .world = world }).activeEntity() orelse return scene;
    const own = world.get(entity, PostProcess) orelse return scene;
    try own.validate();
    return own;
}

test "a camera's post-processing replaces the environment's" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const scene = PostProcess{ .tone_mapping = .aces };
    try std.testing.expectEqual(ToneMapping.aces, (try forActiveCamera(&world, &scene)).tone_mapping);

    const eye = try world.spawn(.{camera.Camera{}});
    try std.testing.expectEqual(ToneMapping.aces, (try forActiveCamera(&world, &scene)).tone_mapping);
    var own = PostProcess{ .tone_mapping = .agx, .vignette = 0.4 };
    own.passes[1] = .{ .shader = .fromId(42), .values = .{ 0.5, 0, 0, 0 } };
    try world.addComponent(eye, own);
    const chosen = (try forActiveCamera(&world, &scene)).frame();
    try std.testing.expectEqual(@backingInt(ToneMapping.agx), chosen.tone_mapping);
    try std.testing.expectEqual(@as(f32, 0.4), chosen.grade[2]);
    try std.testing.expect(chosen.passShader(0) == null);
    try std.testing.expect(chosen.passShader(1) != null);
    try std.testing.expectEqual(@as(f32, 0.5), chosen.pass_values[1][0]);

    world.get(eye, PostProcess).?.vignette = 2;
    try std.testing.expectError(error.InvalidPostProcess, forActiveCamera(&world, &scene));
}
