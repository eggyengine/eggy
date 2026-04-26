const std = @import("std");
const math = @import("math.zig");

/// A 3D camera that uses matrices.
///
/// Right-handed, Vulkan-convention (Y-down, depth 0..1).
pub const Camera3D = struct {
    eye: math.Vec3 = math.Vec3.init(0, 0, 1),
    target: math.Vec3 = math.Vec3.splat(0),
    up: math.Vec3 = math.Vec3.init(0, 1, 0),
    fov_y: f32 = std.math.degreesToRadians(60.0),
    aspect: f32 = 16.0 / 9.0,
    near: f32 = 0.1,
    far: f32 = 100.0,
    
    view: math.Mat4 = math.identity(f32, 4),
    proj: math.Mat4 = math.identity(f32, 4),

    /// Create a perspective camera from a look-at view and projection parameters.
    pub fn perspective(
        eye: math.Vec3,
        target: math.Vec3,
        up: math.Vec3,
        fov_y: f32,
        aspect: f32,
        near: f32,
        far: f32,
    ) Camera3D {
        return .{
            .view = math.lookAt4x4(f32, eye, target, up),
            .proj = math.perspective4x4(f32, fov_y, aspect, near, far),
        };
    }

    /// Create an orthographic camera from a look-at view and ortho bounds.
    pub fn orthographic(
        eye: math.Vec3,
        target: math.Vec3,
        up: math.Vec3,
        left: f32,
        right: f32,
        bottom: f32,
        top: f32,
        near: f32,
        far: f32,
    ) Camera3D {
        return .{
            .view = math.lookAt4x4(f32, eye, target, up),
            .proj = math.orthographic4x4(f32, left, right, bottom, top, near, far),
        };
    }

    /// Recompute the view matrix from eye, target, and up.
    pub fn lookAt(self: *Camera3D, eye: math.Vec3, target: math.Vec3, up: math.Vec3) void {
        self.view = math.lookAt4x4(f32, eye, target, up);
    }

    /// Recompute the perspective projection.
    pub fn setPerspective(self: *Camera3D, fov_y: f32, aspect: f32, near: f32, far: f32) void {
        self.proj = math.perspective4x4(f32, fov_y, aspect, near, far);
    }

    /// Recompute the orthographic projection.
    pub fn setOrthographic(self: *Camera3D, left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) void {
        self.proj = math.orthographic4x4(f32, left, right, bottom, top, near, far);
    }

    /// Combined view-projection matrix (proj * view).
    pub fn viewProjection(self: Camera3D) math.Mat4 {
        return math.multiply4x4(f32, self.proj, self.view);
    }
};

/// A 2D camera using an orthographic projection.
///
/// Suitable for UI, tilemaps, and 2D scenes. Wraps a simple
/// position + zoom into the same view/proj pair the shader expects.
pub const Camera2D = struct {
    position: math.Vec2 = math.Vec2.splat(0),
    zoom: f32 = 1.0,
    rotation: f32 = 0.0,
    viewport_width: f32 = 1,
    viewport_height: f32 = 1,

    pub fn viewMatrix(self: Camera2D) math.Mat4 {
        const cos_r = @cos(-self.rotation);
        const sin_r = @sin(-self.rotation);

        const tx = -self.position.x;
        const ty = -self.position.y;

        return math.Mat4{
            .data = .{
                .{ cos_r, -sin_r, 0, 0 },
                .{ sin_r, cos_r, 0, 0 },
                .{ 0, 0, 1, 0 },
                .{ cos_r * tx + sin_r * ty, -sin_r * tx + cos_r * ty, 0, 1 },
            },
        };
    }

    /// Build the orthographic projection (zoom-aware, Vulkan Y-down).
    pub fn projMatrix(self: Camera2D) math.Mat4 {
        const hw = self.viewport_width / (2.0 * self.zoom);
        const hh = self.viewport_height / (2.0 * self.zoom);
        return math.orthographic4x4(f32, -hw, hw, -hh, hh, -1.0, 1.0);
    }

    /// Combined view-projection matrix.
    pub fn viewProjection(self: Camera2D) math.Mat4 {
        return math.multiply4x4(f32, self.projMatrix(), self.viewMatrix());
    }

    /// Update viewport dimensions (e.g. on window resize).
    pub fn setViewport(self: *Camera2D, width: f32, height: f32) void {
        self.viewport_width = width;
        self.viewport_height = height;
    }

    /// Convert a screen-space point to world-space.
    pub fn screenToWorld(self: Camera2D, screen_pos: math.Vec2) math.Vec2 {
        const hw = self.viewport_width / (2.0 * self.zoom);
        const hh = self.viewport_height / (2.0 * self.zoom);

        const ndc_x = (screen_pos.x / self.viewport_width) * 2.0 - 1.0;
        const ndc_y = (screen_pos.y / self.viewport_height) * 2.0 - 1.0;

        const local_x = ndc_x * hw;
        const local_y = ndc_y * hh;

        const cos_r = @cos(self.rotation);
        const sin_r = @sin(self.rotation);

        return .{
            .x = cos_r * local_x + sin_r * local_y + self.position.x,
            .y = -sin_r * local_x + cos_r * local_y + self.position.y,
        };
    }

    /// Convert a world-space point to screen-space.
    pub fn worldToScreen(self: Camera2D, world_pos: math.Vec2) math.Vec2 {
        const hw = self.viewport_width / (2.0 * self.zoom);
        const hh = self.viewport_height / (2.0 * self.zoom);

        const dx = world_pos.x - self.position.x;
        const dy = world_pos.y - self.position.y;

        const cos_r = @cos(-self.rotation);
        const sin_r = @sin(-self.rotation);
        const local_x = cos_r * dx + sin_r * dy;
        const local_y = -sin_r * dx + cos_r * dy;

        return .{
            .x = (local_x / hw + 1.0) * 0.5 * self.viewport_width,
            .y = (local_y / hh + 1.0) * 0.5 * self.viewport_height,
        };
    }
};