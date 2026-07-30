const std = @import("std");
const emath = @import("eggenvector");

pub const CameraMovement = enum { forward, backward, left, right, up, down };

pub const Camera = struct {
    position: emath.Vec3 = .zero,
    front: emath.Vec3 = .forward,
    up: emath.Vec3 = .up,
    right: emath.Vec3 = .right,
    world_up: emath.Vec3 = .up,

    yaw: emath.Angle = .fromDegrees(-90.0),
    pitch: emath.Angle = .fromDegrees(0.0),

    movement_speed: f32 = 2.5,
    mouse_sensitivity: f32 = 0.1,
    /// Vertical field of view in degrees.
    zoom: f32 = 45.0,

    pub fn init(position: emath.Vec3) Camera {
        var camera: Camera = .{ .position = position };
        camera.updateCameraVectors();
        return camera;
    }

    pub fn updateCameraVectors(self: *Camera) void {
        const yaw = self.yaw.toRadians();
        const pitch = self.pitch.toRadians();

        const front = emath.Vec3{
            .x = @cos(yaw) * @cos(pitch),
            .y = @sin(pitch),
            .z = @sin(yaw) * @cos(pitch),
        };
        self.front = front.normalize();
        self.right = self.front.cross(self.world_up).normalize();
        self.up = self.right.cross(self.front).normalize();
    }

    pub fn getViewMatrix(self: Camera) emath.Mat4 {
        return emath.lookAt(self.position, self.position.add(self.front), self.up);
    }

    pub fn getProjectionMatrix(self: Camera, aspect_ratio: f32, near_plane: f32, far_plane: f32) emath.Mat4 {
        const fov_y = emath.Angle.fromDegrees(self.zoom).toRadians();
        var projection = emath.perspective(fov_y, aspect_ratio, near_plane, far_plane);
        projection.data[1][1] = -projection.data[1][1];
        return projection;
    }

    pub fn processKeyboard(self: *Camera, direction: CameraMovement, delta_time: f32) void {
        const velocity = self.movement_speed * delta_time;
        self.position = switch (direction) {
            .forward => self.position.add(self.front.scale(velocity)),
            .backward => self.position.sub(self.front.scale(velocity)),
            .left => self.position.sub(self.right.scale(velocity)),
            .right => self.position.add(self.right.scale(velocity)),
            .up => self.position.add(self.world_up.scale(velocity)),
            .down => self.position.sub(self.world_up.scale(velocity)),
        };
    }

    pub fn processMouseMovement(self: *Camera, x_offset: f32, y_offset: f32, constrain_pitch: bool) void {
        self.yaw = self.yaw.add(.fromDegrees(x_offset * self.mouse_sensitivity));
        self.pitch = self.pitch.add(.fromDegrees(y_offset * self.mouse_sensitivity));

        if (constrain_pitch) {
            const max_pitch = emath.Angle.fromDegrees(89.0);
            const min_pitch = emath.Angle.fromDegrees(-89.0);
            if (self.pitch.toDegrees() > max_pitch.toDegrees()) self.pitch = max_pitch;
            if (self.pitch.toDegrees() < min_pitch.toDegrees()) self.pitch = min_pitch;
        }

        self.updateCameraVectors();
    }

    pub fn processMouseScroll(self: *Camera, y_offset: f32) void {
        self.zoom -= y_offset;
        self.zoom = std.math.clamp(self.zoom, 1.0, 45.0);
    }
};

test "projection uses Vitellus clip-space Y convention" {
    const projection = Camera.init(.{ .x = 0, .y = 0, .z = 3 })
        .getProjectionMatrix(16.0 / 9.0, 0.1, 100.0);
    try std.testing.expect(projection.data[1][1] > 0);
}
