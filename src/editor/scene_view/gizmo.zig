//! The gizmo: handles drawn over the selected entity in the Scene panel, dragged to move, turn
//! or resize it. Arrows move it along the world's axes, rings turn it about them, and
//! box-tipped lines (or the box in the middle, for all three at once) resize it. It is the same
//! size on screen however far away the entity is.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

pub const Tool = enum { move, rotate, scale };
pub const Axis = enum(u2) { x, y, z };
pub const Handle = union(enum) { axis: Axis, uniform };

/// How long the axes are on screen, and how near the pointer must be to take a handle, in points.
const length_pt: f32 = 90;
const reach_pt: f32 = 8;
const ring_points = 48;

const axis_colors = [3][3]f32{ .{ 0.92, 0.27, 0.32 }, .{ 0.47, 0.85, 0.3 }, .{ 0.27, 0.52, 0.96 } };
const highlight = [3]f32{ 1, 0.84, 0.22 };

/// Where the gizmo is on screen this frame.
pub const Layout = struct {
    tool: Tool,
    origin: ui.Vec2,
    /// Each axis's tip (move and scale), or its ring (rotate).
    tips: [3]ui.Vec2,
    rings: [3][ring_points]ui.Vec2,
    /// How long an axis is in the world, for `length_pt` on screen.
    world_length: f32,
    /// Whether each axis points towards the camera, which turns a ring's drag the other way.
    towards_camera: [3]bool,
};

/// The gizmo for `tool` at world point `origin`, seen through `view` in `scene` (the Scene
/// panel's rect); null when `origin` is behind the camera.
pub fn layout(tool: Tool, origin: [3]f32, view: eggy.camera.View, scene: ui.Rect) ?Layout {
    const view_projection = view.viewProjection(scene.w / scene.h);
    const centre = toScreen(view_projection, scene, origin) orelse return null;
    const distance = length3(eggy.camera.sub(origin, view.eye));
    const world_length = distance * 2 * @tan(view.fov_deg * std.math.rad_per_deg / 2) * length_pt / @max(1, scene.h);
    var result = Layout{ .tool = tool, .origin = centre, .tips = undefined, .rings = undefined, .world_length = world_length, .towards_camera = undefined };
    for (0..3) |axis| {
        const direction = unit(axis);
        result.tips[axis] = toScreen(view_projection, scene, add(origin, scale(direction, world_length))) orelse centre;
        result.towards_camera[axis] = dot(direction, view.forward) < 0;
        // The ring: a circle about the axis, in the plane of the other two.
        const across = unit((axis + 1) % 3);
        const other = unit((axis + 2) % 3);
        for (&result.rings[axis], 0..) |*point, i| {
            const angle = std.math.tau * @as(f32, @floatFromInt(i)) / ring_points;
            const offset = add(scale(across, @cos(angle) * world_length), scale(other, @sin(angle) * world_length));
            point.* = toScreen(view_projection, scene, add(origin, offset)) orelse centre;
        }
    }
    return result;
}

/// The handle under `pointer`, if any: the nearest within reach.
pub fn hit(gizmo: Layout, pointer: ui.Vec2) ?Handle {
    var best: ?Handle = null;
    var best_distance: f32 = reach_pt;
    if (gizmo.tool == .scale and distanceTo(pointer, gizmo.origin) < reach_pt) return .uniform;
    for (0..3) |axis| {
        const distance = switch (gizmo.tool) {
            .move, .scale => segmentDistance(pointer, gizmo.origin, gizmo.tips[axis]),
            .rotate => ringDistance(pointer, &gizmo.rings[axis]),
        };
        if (distance < best_distance) {
            best_distance = distance;
            best = .{ .axis = @enumFromInt(axis) };
        }
    }
    return best;
}

/// A drag of one handle, from where it was taken.
pub const Drag = struct {
    tool: Tool,
    handle: Handle,
    from: ui.Vec2,
    /// The field's value when the drag began: the local position, rotation or scale.
    start: [3]f32,
    gizmo: Layout,
    /// Turns a world-space move into the parent's space (columns; identity at the top level).
    to_local: [4][4]f32,

    /// The field's value with the pointer at `pointer`.
    pub fn valueAt(self: Drag, pointer: ui.Vec2) [3]f32 {
        var value = self.start;
        const moved = sub2(pointer, self.from);
        switch (self.handle) {
            .uniform => {
                // Right and up grow it; left and down shrink it.
                const factor = @max(0.01, 1 + (moved.x - moved.y) / 100);
                for (&value) |*part| part.* *= factor;
            },
            .axis => |which| {
                const axis = @intFromEnum(which);
                switch (self.tool) {
                    .move => {
                        const world = scale(unit(axis), self.alongAxis(axis, moved) * self.gizmo.world_length);
                        value = add(value, eggy.transform.apply(self.to_local, world, 0));
                    },
                    .scale => value[axis] = @max(0.001, value[axis] * (1 + self.alongAxis(axis, moved))),
                    .rotate => {
                        // How far round the centre the pointer went; screen y points down.
                        const before = std.math.atan2(self.from.y - self.gizmo.origin.y, self.from.x - self.gizmo.origin.x);
                        const after = std.math.atan2(pointer.y - self.gizmo.origin.y, pointer.x - self.gizmo.origin.x);
                        const turned = (after - before) * std.math.deg_per_rad;
                        value[axis] = @mod(value[axis] + (if (self.gizmo.towards_camera[axis]) -turned else turned), 360);
                    },
                }
            },
        }
        return value;
    }

    /// How far `moved` goes along `axis` on screen, in axis lengths.
    fn alongAxis(self: Drag, axis: usize, moved: ui.Vec2) f32 {
        const on_screen = sub2(self.gizmo.tips[axis], self.gizmo.origin);
        const squared = on_screen.x * on_screen.x + on_screen.y * on_screen.y;
        if (squared < 1) return 0;
        return (moved.x * on_screen.x + moved.y * on_screen.y) / squared;
    }
};

/// The gizmo as paint for a node covering the Scene panel: `hot` (under the pointer) and
/// `active` (dragged) handles lit. In `arena`.
pub fn paint(arena: std.mem.Allocator, gizmo: Layout, hot: ?Handle, active: ?Handle) ui.Layout.Paint {
    const drawing = arena.create(Drawing) catch return .none;
    drawing.* = .{ .gizmo = gizmo, .hot = hot, .active = active };
    return .{ .custom = .{ .context = drawing, .draw = Drawing.draw } };
}

const Drawing = struct {
    gizmo: Layout,
    hot: ?Handle,
    active: ?Handle,

    fn draw(context: *const anyopaque, c: *ui.Canvas, _: ui.Rect) anyerror!void {
        const self: *const Drawing = @ptrCast(@alignCast(context));
        const gizmo = self.gizmo;
        for (0..3) |axis| {
            const color = self.colorOf(.{ .axis = @enumFromInt(axis) }, axis_colors[axis]);
            switch (gizmo.tool) {
                .move, .scale => {
                    try line(c, gizmo.origin, gizmo.tips[axis], 2.5, color);
                    if (gizmo.tool == .move) try arrowHead(c, gizmo.origin, gizmo.tips[axis], color) else try box(c, gizmo.tips[axis], 5, color);
                },
                .rotate => for (0..ring_points) |i| try line(c, gizmo.rings[axis][i], gizmo.rings[axis][(i + 1) % ring_points], 2.5, color),
            }
        }
        if (gizmo.tool == .scale) try box(c, gizmo.origin, 6, self.colorOf(.uniform, .{ 0.95, 0.95, 0.95 }));
    }

    fn colorOf(self: *const Drawing, handle: Handle, normal: [3]f32) [4]f32 {
        const lit = if (self.active) |active| std.meta.eql(active, handle) else if (self.hot) |hot| std.meta.eql(hot, handle) else false;
        const rgb = if (lit) highlight else normal;
        return .{ rgb[0], rgb[1], rgb[2], 1 };
    }
};

fn line(c: *ui.Canvas, from: ui.Vec2, to: ui.Vec2, width: f32, color: [4]f32) !void {
    const along = sub2(to, from);
    const length = @sqrt(along.x * along.x + along.y * along.y);
    if (length < 0.01) return;
    const nx = -along.y / length * width / 2;
    const ny = along.x / length * width / 2;
    const a = [2]f32{ from.x + nx, from.y + ny };
    const b = [2]f32{ to.x + nx, to.y + ny };
    const d = [2]f32{ to.x - nx, to.y - ny };
    const e = [2]f32{ from.x - nx, from.y - ny };
    try c.triangle(.{ a, b, d }, .{ color, color, color });
    try c.triangle(.{ a, d, e }, .{ color, color, color });
}

fn arrowHead(c: *ui.Canvas, from: ui.Vec2, tip: ui.Vec2, color: [4]f32) !void {
    const along = sub2(tip, from);
    const length = @sqrt(along.x * along.x + along.y * along.y);
    if (length < 1) return;
    const ux = along.x / length;
    const uy = along.y / length;
    const size: f32 = 10;
    const base = [2]f32{ tip.x - ux * size, tip.y - uy * size };
    try c.triangle(.{ .{ tip.x + ux * 2, tip.y + uy * 2 }, .{ base[0] - uy * size / 2, base[1] + ux * size / 2 }, .{ base[0] + uy * size / 2, base[1] - ux * size / 2 } }, .{ color, color, color });
}

fn box(c: *ui.Canvas, centre: ui.Vec2, half: f32, color: [4]f32) !void {
    try c.rect(.{ .x = centre.x - half, .y = centre.y - half, .w = half * 2, .h = half * 2 }, .{ color[0], color[1], color[2] });
}

/// Where world `point` lands in `scene`, in points; null behind the camera.
fn toScreen(view_projection: [4][4]f32, scene: ui.Rect, point: [3]f32) ?ui.Vec2 {
    const projected = eggy.camera.project(view_projection, point);
    if (!projected.in_front) return null;
    return .{ .x = scene.x + (projected.x + 1) / 2 * scene.w, .y = scene.y + (1 - projected.y) / 2 * scene.h };
}

fn segmentDistance(p: ui.Vec2, a: ui.Vec2, b: ui.Vec2) f32 {
    const ab = sub2(b, a);
    const squared = ab.x * ab.x + ab.y * ab.y;
    const t = if (squared < 0.0001) 0 else std.math.clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / squared, 0, 1);
    return distanceTo(p, .{ .x = a.x + ab.x * t, .y = a.y + ab.y * t });
}

fn ringDistance(p: ui.Vec2, ring: *const [ring_points]ui.Vec2) f32 {
    var nearest = std.math.inf(f32);
    for (0..ring_points) |i| nearest = @min(nearest, segmentDistance(p, ring[i], ring[(i + 1) % ring_points]));
    return nearest;
}

fn distanceTo(a: ui.Vec2, b: ui.Vec2) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

fn sub2(a: ui.Vec2, b: ui.Vec2) ui.Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn unit(axis: usize) [3]f32 {
    var direction = [3]f32{ 0, 0, 0 };
    direction[axis] = 1;
    return direction;
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return @as(@Vector(3, f32), a) + @as(@Vector(3, f32), b);
}

fn scale(v: [3]f32, by: f32) [3]f32 {
    return @as(@Vector(3, f32), v) * @as(@Vector(3, f32), @splat(by));
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return @reduce(.Add, @as(@Vector(3, f32), a) * @as(@Vector(3, f32), b));
}

fn length3(v: [3]f32) f32 {
    return @sqrt(dot(v, v));
}

const identity = [4][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
const test_scene = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };

test "dragging the x arrow along its own line moves the entity along x" {
    const gizmo = layout(.move, .{ 0, 1, 0 }, .default, test_scene).?;
    const handle = hit(gizmo, gizmo.tips[0]).?;
    try std.testing.expectEqual(Axis.x, handle.axis);
    const drag = Drag{ .tool = .move, .handle = handle, .from = gizmo.origin, .start = .{ 0, 1, 0 }, .gizmo = gizmo, .to_local = identity };
    const moved = drag.valueAt(gizmo.tips[0]);
    try std.testing.expectApproxEqAbs(gizmo.world_length, moved[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), moved[1], 0.001);
}

test "a move under a parent turned a quarter is made in the parent's space" {
    const gizmo = layout(.move, .{ 0, 1, 0 }, .default, test_scene).?;
    // The parent's inverse: turned back a quarter about y, world x is the parent's z.
    const to_local = [4][4]f32{ .{ 0, 0, 1, 0 }, .{ 0, 1, 0, 0 }, .{ -1, 0, 0, 0 }, .{ 0, 0, 0, 1 } };
    const drag = Drag{ .tool = .move, .handle = .{ .axis = .x }, .from = gizmo.origin, .start = .{ 0, 0, 0 }, .gizmo = gizmo, .to_local = to_local };
    const moved = drag.valueAt(gizmo.tips[0]);
    try std.testing.expectApproxEqAbs(gizmo.world_length, moved[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), moved[0], 0.001);
}

test "the middle box resizes on every axis, and nothing is taken far from the gizmo" {
    const gizmo = layout(.scale, .{ 0, 1, 0 }, .default, test_scene).?;
    try std.testing.expectEqual(Handle.uniform, hit(gizmo, gizmo.origin).?);
    try std.testing.expect(hit(gizmo, .{ .x = 5, .y = 5 }) == null);
    const drag = Drag{ .tool = .scale, .handle = .uniform, .from = gizmo.origin, .start = .{ 1, 2, 1 }, .gizmo = gizmo, .to_local = identity };
    const grown = drag.valueAt(.{ .x = gizmo.origin.x + 100, .y = gizmo.origin.y });
    try std.testing.expectEqualSlices(f32, &.{ 2, 4, 2 }, &grown);
}
