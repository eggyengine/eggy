//! A model's skeleton in the Scene panel, for posing it: every node of the selected entity's
//! model placed as the scene shows it (its clips at the Animation panel's time, through
//! `eggy.deformation.posed`), drawn as bones from each node to its parent with a dot at every
//! joint, and the joint under the pointer found.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const math = eggy.math;
const Vec3 = math.Vec3;
const gizmo = @import("gizmo.zig");
const rotation = @import("rotation.zig");

/// How near the pointer must be to a joint's dot to pick it, in points.
const pick_radius: f32 = 9;
const joint_radius: f32 = 3.5;
const bone_color = [4]f32{ 0.85, 0.85, 0.9, 0.85 };
const picked_color = [4]f32{ 0.25, 0.65, 1, 1 };
const hot_color = [4]f32{ 1, 0.84, 0.22, 1 };

/// A node as posed: its name, parent, place in the world and on screen, and its own
/// translation, rotation and scale (what its tracks key).
pub const Joint = struct {
    name: []const u8,
    parent: ?u32,
    world: math.Mat4,
    screen: ?ui.Vec2,
    local: [3]Vec3,
};

pub const Skeleton = struct {
    arena: std.heap.ArenaAllocator,
    /// The entity whose model it is, while one is posed.
    entity: ?eggy.ecs.EntityId = null,
    /// The entity's world matrix.
    placed: math.Mat4 = math.identity(f32, 4),
    joints: []Joint = &.{},

    pub fn init(gpa: std.mem.Allocator) Skeleton {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Skeleton) void {
        self.arena.deinit();
    }

    /// Pose the skeleton of what `drawn` drew for `entity`, seen through `view` in `scene`;
    /// none when it isn't a model with nodes and an `Animator`.
    pub fn update(self: *Skeleton, app: *eggy.App, drawn: []const eggy.mesh.Drawable, entity: ?eggy.ecs.EntityId, view: eggy.camera.View, scene: ui.Rect) void {
        _ = self.arena.reset(.retain_capacity);
        self.entity = null;
        self.joints = &.{};
        const chosen = entity orelse return;
        const drawable = for (drawn) |found| {
            if (found.entity_id == chosen.id and found.entity_generation == chosen.generation) break found;
        } else return;
        if (drawable.animator == null) return;
        if (self.show(app, drawable, view, scene)) self.entity = chosen;
    }

    /// Pose the skeleton of `drawable`'s model as it is drawn (its `Animator`'s clips, else at
    /// rest), seen through `view` in `scene`. False, with no joints, when its model has no nodes.
    pub fn show(self: *Skeleton, app: *eggy.App, drawable: eggy.mesh.Drawable, view: eggy.camera.View, scene: ui.Rect) bool {
        _ = self.arena.reset(.retain_capacity);
        self.joints = &.{};
        const path = drawable.modelFile() orelse return false;
        const gpu = app.graphics.models.get(path, &app.graphics.textures) orelse return false;
        const model = gpu.rig orelse return false;
        if (model.rig.nodes.len == 0) return false;
        const animator: eggy.animation.Animator = if (drawable.animator) |found| found.* else .{};
        self.pose(app, model, path, animator, math.fromArray(f32, 4, 4, drawable.model), view, scene) catch return false;
        return true;
    }

    /// Record a line for each bone, from its joint to its parent's, in `debug`.
    pub fn lines(self: *const Skeleton, debug: *eggy.debug_draw.DebugDraw) !void {
        for (self.joints) |joint| {
            const parent = joint.parent orelse continue;
            try debug.line(origin(self.joints[parent].world), origin(joint.world), bone_color);
        }
    }

    fn pose(self: *Skeleton, app: *eggy.App, model: *const eggy.assets.Model, path: []const u8, animator: eggy.animation.Animator, placed: math.Mat4, view: eggy.camera.View, scene: ui.Rect) !void {
        const arena = self.arena.allocator();
        const posed = try eggy.deformation.posed(arena, model, path, animator, &app.graphics.clips, null);
        var deformer = try eggy.assets.rig.Deformer.init(arena, model.*);
        deformer.place(model.*, posed);
        const view_projection = view.viewProjection(scene.w / scene.h);
        const joints = try arena.alloc(Joint, model.rig.nodes.len);
        for (joints, model.rig.nodes, 0..) |*joint, node, index| {
            const world = math.multiply4x4(f32, placed, math.fromArray(f32, 4, 4, deformer.world[index]));
            const turned = rotation.toEuler(quaternionRows(posed.rotation[index]));
            joint.* = .{
                .name = node.name,
                .parent = node.parent,
                .world = world,
                .screen = gizmo.toScreen(view_projection, scene, origin(world)),
                .local = .{ .fromArray(posed.translation[index]), turned, .fromArray(posed.scale[index]) },
            };
        }
        self.placed = placed;
        self.joints = joints;
    }

    /// The joint whose dot is under `at`, nearest first; null over none.
    pub fn jointAt(self: *const Skeleton, at: ui.Vec2) ?u32 {
        var best: ?u32 = null;
        var best_distance = pick_radius;
        for (self.joints, 0..) |joint, index| {
            const screen = joint.screen orelse continue;
            const distance = @sqrt((screen.x - at.x) * (screen.x - at.x) + (screen.y - at.y) * (screen.y - at.y));
            if (distance <= best_distance) {
                best = @intCast(index);
                best_distance = distance;
            }
        }
        return best;
    }

    /// The space joint `index` moves in: its parent's, or the entity's for a root.
    pub fn parentSpace(self: *const Skeleton, index: u32) math.Mat4 {
        const parent = self.joints[index].parent orelse return self.placed;
        return self.joints[parent].world;
    }

    /// The bones and joints as layout paint, `picked` and `hot` lit. Allocates in `arena`.
    pub fn paint(self: *const Skeleton, arena: std.mem.Allocator, picked: ?u32, hot: ?u32) ui.Layout.Paint {
        const drawing = arena.create(Drawing) catch return .none;
        drawing.* = .{ .joints = arena.dupe(Joint, self.joints) catch return .none, .picked = picked, .hot = hot };
        return .{ .custom = .{ .context = drawing, .draw = Drawing.draw } };
    }
};

const Drawing = struct {
    joints: []const Joint,
    picked: ?u32,
    hot: ?u32,

    fn draw(context: *const anyopaque, c: *ui.Canvas, _: ui.Rect) anyerror!void {
        const self: *const Drawing = @ptrCast(@alignCast(context));
        for (self.joints) |joint| {
            const parent = joint.parent orelse continue;
            const from = self.joints[parent].screen orelse continue;
            const to = joint.screen orelse continue;
            try gizmo.line(c, from, to, 1.5, bone_color);
        }
        for (self.joints, 0..) |joint, at_index| {
            const index: u32 = @intCast(at_index);
            const at = joint.screen orelse continue;
            const color = if (self.picked == index) picked_color else if (self.hot == index) hot_color else bone_color;
            const radius = if (self.picked == index) joint_radius + 1.5 else joint_radius;
            try c.roundRect(.{ .x = at.x - radius, .y = at.y - radius, .w = radius * 2, .h = radius * 2 }, .{ color[0], color[1], color[2] }, radius);
        }
    }
};

/// Where `matrix` puts its origin.
fn origin(matrix: math.Mat4) Vec3 {
    return math.transformPoint4x4(f32, matrix, .zero);
}

/// The rotation of unit quaternion `q` (x, y, z, w) as a 3×3 matrix of rows, as `rotation.zig`
/// takes them.
fn quaternionRows(q: [4]f32) rotation.Matrix {
    const x, const y, const z, const w = q;
    return .{
        .{ 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w) },
        .{ 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w) },
        .{ 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) },
    };
}

test "a node's quaternion turns back into the degrees a bone track keys" {
    const degrees = Vec3.init(20, -35, 70);
    const back = rotation.toEuler(quaternionRows(eggy.deformation.eulerQuaternion(degrees.toArray())));
    try std.testing.expectApproxEqAbs(degrees.x, back.x, 0.01);
    try std.testing.expectApproxEqAbs(degrees.y, back.y, 0.01);
    try std.testing.expectApproxEqAbs(degrees.z, back.z, 0.01);
}

test "the joint nearest the pointer is picked, within reach" {
    var joints = [_]Joint{
        .{ .name = "hips", .parent = null, .world = math.identity(f32, 4), .screen = .{ .x = 100, .y = 100 }, .local = .{ .zero, .zero, .one } },
        .{ .name = "spine", .parent = 0, .world = math.identity(f32, 4), .screen = .{ .x = 104, .y = 100 }, .local = .{ .zero, .zero, .one } },
    };
    var skeleton = Skeleton.init(std.testing.allocator);
    defer skeleton.deinit();
    skeleton.joints = &joints;
    try std.testing.expectEqual(@as(?u32, 1), skeleton.jointAt(.{ .x = 105, .y = 101 }));
    try std.testing.expectEqual(@as(?u32, null), skeleton.jointAt(.{ .x = 130, .y = 100 }));
}

test "each bone becomes one line from its parent's joint to its own" {
    const hips = math.translation4x4(f32, 0, 1, 0);
    var joints = [_]Joint{
        .{ .name = "root", .parent = null, .world = math.identity(f32, 4), .screen = null, .local = .{ .zero, .zero, .one } },
        .{ .name = "hips", .parent = 0, .world = hips, .screen = null, .local = .{ .zero, .zero, .one } },
    };
    var skeleton = Skeleton.init(std.testing.allocator);
    defer skeleton.deinit();
    skeleton.joints = &joints;
    var debug = eggy.debug_draw.DebugDraw{};
    try skeleton.lines(&debug);
    try std.testing.expectEqual(@as(usize, 1), debug.line_count);
    try std.testing.expectEqual(@as(f32, 0), debug.lines[0].from_m.y);
    try std.testing.expectEqual(@as(f32, 1), debug.lines[0].to_m.y);
}
