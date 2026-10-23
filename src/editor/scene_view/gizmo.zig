//! The gizmo: handles drawn over the selected entity in the Scene panel, dragged to move, turn or
//! resize it, after ImGuizmo's. It stays the same size on screen however far away the entity is.
//!
//! - Move: an arrow per axis, a square per plane between two axes, and a dot in the middle that
//!   moves it across the screen.
//! - Rotate: a ring per axis (its front half; the back is behind the entity), and an outer ring
//!   that turns it about the view.
//! - Scale: a box-tipped line per axis, and a box in the middle for all three at once.
//! - Universal: the arrows, planes and dot of Move with the rings of Rotate.
//!
//! The axes are the world's, or (Local) the entity's own; Scale always uses its own. Axes point
//! towards the camera, and an axis or plane seen edge-on is hidden. With snapping, moves go in
//! steps of `snap.move_m`, turns of `snap.rotate_deg` and resizes of `snap.scale`. While dragging,
//! the gizmo shows how far: the turned arc and its angle, the path moved and its length, or the
//! factor resized by.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const rotation = @import("rotation.zig");
const rayThrough = @import("picking.zig").rayThrough;
const View = eggy.camera.View;

pub const Tool = enum { move, rotate, scale, universal };
pub const Space = enum { world, local };
pub const Axis = enum(u2) { x, y, z };

pub const Handle = union(enum) {
    /// Move along an axis, or across the plane square at right angles to it.
    arrow: Axis,
    plane: Axis,
    /// Move across the screen.
    screen_move,
    /// Turn about an axis, or about the view.
    ring: Axis,
    screen_ring,
    /// Resize along an axis, or all three at once.
    scale_axis: Axis,
    uniform,
};

/// The steps moves, turns and resizes snap to.
pub const snap = struct {
    pub const move_m: f32 = 0.25;
    pub const rotate_deg: f32 = 15;
    pub const scale: f32 = 0.1;
};

/// How long the axes are on screen, and how near the pointer must be to take a handle, in points.
const length_pt: f32 = 90;
const reach_pt: f32 = 8;
const ring_points = 64;
/// Where a plane's square sits along its two axes, as a share of the axis length.
const plane_near: f32 = 0.2;
const plane_far: f32 = 0.45;
/// How far a ring is from the centre, as a share of the axis length: Universal's go outside the
/// arrows. The view's ring goes a little further out.
const ring_radius: f32 = 1;
const universal_ring_radius: f32 = 1.25;
const screen_ring_scale: f32 = 1.2;
/// Past these, an axis (pointing at the camera) or a plane (edge-on) is hidden.
const axis_limit: f32 = 0.985;
const plane_limit: f32 = 0.2;

const axis_colors = [3][3]f32{ .{ 0.92, 0.27, 0.32 }, .{ 0.47, 0.85, 0.3 }, .{ 0.27, 0.52, 0.96 } };
const highlight = [3]f32{ 1, 0.84, 0.22 };
const neutral = [3]f32{ 0.92, 0.92, 0.92 };

/// Where the gizmo is on screen this frame.
pub const Layout = struct {
    tool: Tool,
    space: Space,
    view: View,
    scene: ui.Rect,
    origin_world: [3]f32,
    origin: ui.Vec2,
    /// Each axis in the world, pointing towards the camera, and whether it is shown.
    axes: [3][3]f32,
    /// Whether each axis was turned round to face the camera.
    flipped: [3]bool,
    axis_shown: [3]bool,
    plane_shown: [3]bool,
    tips: [3]ui.Vec2,
    /// The square for the plane at right angles to each axis.
    planes: [3][4]ui.Vec2,
    rings: [3][ring_points]ui.Vec2,
    /// Whether each ring point is on the front half, facing the camera.
    ring_front: [3][ring_points]bool,
    screen_ring: [ring_points]ui.Vec2,
    /// How long an axis is in the world, for `length_pt` on screen.
    world_length: f32,

    fn hasMove(self: *const Layout) bool {
        return self.tool == .move or self.tool == .universal;
    }

    fn hasRotate(self: *const Layout) bool {
        return self.tool == .rotate or self.tool == .universal;
    }
};

/// The gizmo for `tool` on the entity placed by `placed` (its world matrix, as columns), seen
/// through `view` in `scene` (the Scene panel's rect); null when it is behind the camera.
/// Editor-only: requires positive scene dimensions and a valid camera/finite world transform.
/// Returns copied geometry in UI points and world metres, hiding edge-on handles; Scale always
/// uses local axes even when `space` is world. Does not allocate or mutate the entity.
///
/// ```zig
/// const handles = layout(.move, .world, world_matrix, view, scene);
/// // Existing column-major entity matrix, camera view and Scene UI rect.
/// ```
pub fn layout(tool: Tool, space: Space, placed: [4][4]f32, view: View, scene: ui.Rect) ?Layout {
    const origin_world = [3]f32{ placed[3][0], placed[3][1], placed[3][2] };
    const view_projection = view.viewProjection(scene.w / scene.h);
    const centre = toScreen(view_projection, scene, origin_world) orelse return null;
    // Orthographic cameras see every point along the same direction, at a size fixed by the view's height.
    const orthographic = view.projection == .orthographic;
    const to_camera = if (orthographic) scale(view.forward, -1) else eggy.camera.normalize(eggy.camera.sub(view.eye, origin_world));
    const distance = length(eggy.camera.sub(origin_world, view.eye));
    const world_length = if (orthographic)
        view.orthographic_height_m * length_pt / @max(1, scene.h)
    else
        distance * 2 * @tan(view.fov_deg * std.math.rad_per_deg / 2) * length_pt / @max(1, scene.h);
    var result = Layout{
        .tool = tool,
        .space = space,
        .view = view,
        .scene = scene,
        .origin_world = origin_world,
        .origin = centre,
        .axes = undefined,
        .flipped = undefined,
        .axis_shown = undefined,
        .plane_shown = undefined,
        .tips = undefined,
        .planes = undefined,
        .rings = undefined,
        .ring_front = undefined,
        .screen_ring = undefined,
        .world_length = world_length,
    };

    // The axes: the world's or the entity's own, each turned to face the camera.
    for (0..3) |axis| {
        const own = space == .local or tool == .scale;
        var direction = if (own) eggy.camera.normalize(.{ placed[axis][0], placed[axis][1], placed[axis][2] }) else unit(axis);
        result.flipped[axis] = dot(direction, to_camera) < 0;
        if (result.flipped[axis]) direction = scale(direction, -1);
        result.axes[axis] = direction;
        result.axis_shown[axis] = @abs(dot(direction, to_camera)) < axis_limit;
        result.plane_shown[axis] = @abs(dot(direction, to_camera)) > plane_limit;
        result.tips[axis] = toScreen(view_projection, scene, add(origin_world, scale(direction, world_length))) orelse centre;
    }
    for (0..3) |axis| {
        const a = result.axes[(axis + 1) % 3];
        const b = result.axes[(axis + 2) % 3];
        for ([4][2]f32{ .{ plane_near, plane_near }, .{ plane_far, plane_near }, .{ plane_far, plane_far }, .{ plane_near, plane_far } }, 0..) |corner, i| {
            const point = add(origin_world, add(scale(a, corner[0] * world_length), scale(b, corner[1] * world_length)));
            result.planes[axis][i] = toScreen(view_projection, scene, point) orelse centre;
        }
    }

    // The rings: a circle about each axis, and one about the view.
    const radius = world_length * (if (tool == .universal) universal_ring_radius else ring_radius);
    const right = eggy.camera.normalize(eggy.camera.cross(view.forward, view.up));
    for (0..ring_points) |i| {
        const angle = std.math.tau * @as(f32, @floatFromInt(i)) / ring_points;
        for (0..3) |axis| {
            const a = result.axes[(axis + 1) % 3];
            const b = result.axes[(axis + 2) % 3];
            const offset = add(scale(a, @cos(angle) * radius), scale(b, @sin(angle) * radius));
            result.rings[axis][i] = toScreen(view_projection, scene, add(origin_world, offset)) orelse centre;
            result.ring_front[axis][i] = dot(offset, to_camera) >= -0.02 * radius;
        }
        const around = add(scale(right, @cos(angle) * radius * screen_ring_scale), scale(view.up, @sin(angle) * radius * screen_ring_scale));
        result.screen_ring[i] = toScreen(view_projection, scene, add(origin_world, around)) orelse centre;
    }
    return result;
}

/// The handle under `pointer`, if any: the middle first, then planes, then the nearest line or
/// ring within reach.
/// Editor-only: pointer must use the Layout's UI coordinates. Returns a handle value only;
/// the caller starts a Drag and owns any scene/undo changes.
///
/// ```zig
/// const handle = hit(layout_value, pointer); // Current gizmo Layout and UI-space pointer.
/// ```
pub fn hit(gizmo: Layout, pointer: ui.Vec2) ?Handle {
    if (distanceTo(pointer, gizmo.origin) < reach_pt) return switch (gizmo.tool) {
        .scale => .uniform,
        .move, .universal => .screen_move,
        .rotate => null,
    };
    if (gizmo.hasMove()) for (0..3) |axis| {
        if (gizmo.plane_shown[axis] and insideQuad(pointer, gizmo.planes[axis])) return .{ .plane = @fromBackingInt(@intCast(axis)) };
    };
    var best: ?Handle = null;
    var best_distance: f32 = reach_pt;
    for (0..3) |axis| {
        const which: Axis = @fromBackingInt(@intCast(axis));
        if (gizmo.axis_shown[axis] and gizmo.tool != .rotate) {
            const distance = segmentDistance(pointer, gizmo.origin, gizmo.tips[axis]);
            if (distance < best_distance) {
                best_distance = distance;
                best = if (gizmo.tool == .scale) .{ .scale_axis = which } else .{ .arrow = which };
            }
        }
        if (gizmo.hasRotate()) {
            const distance = ringDistance(pointer, &gizmo.rings[axis], &gizmo.ring_front[axis]);
            if (distance < best_distance) {
                best_distance = distance;
                best = .{ .ring = which };
            }
        }
    }
    if (best == null and gizmo.tool == .rotate and ringDistance(pointer, &gizmo.screen_ring, null) < reach_pt) return .screen_ring;
    return best;
}

/// Which `Transform` field a drag changes, and to what.
pub const Change = struct {
    field: enum { position, rotation_deg, scale },
    value: [3]f32,
};

/// The entity's local `Transform` fields when a drag began.
pub const Start = struct { position: [3]f32, rotation_deg: [3]f32, scale: [3]f32 };

/// A drag of one handle, from where it was taken.
pub const Drag = struct {
    handle: Handle,
    from: ui.Vec2,
    gizmo: Layout,
    start: Start,
    /// Turns world-space moves and axes into the parent's space (columns; identity at the top
    /// level).
    to_local: [4][4]f32,
    /// Where the pointer's ray met the dragged plane when the drag began (plane and screen moves).
    plane_from: ?[3]f32 = null,

    /// Snapshot an editor drag from a hit handle, UI-space press and matching gizmo Layout.
    /// `start` contains the entity's local position/metres, Euler degrees and scale; `to_local`
    /// is its parent's inverse world matrix in columns (identity for roots). Returns owned
    /// value state; an unresolvable drag-plane intersection later keeps the starting position.
    ///
    /// ```zig
    /// // Given a hit handle, UI pointer, Layout, local Start and inverse parent matrix:
    /// const drag = Drag.init(handle, pointer, layout_value, start, inverse_parent);
    /// ```
    pub fn init(handle: Handle, from: ui.Vec2, gizmo: Layout, start: Start, to_local: [4][4]f32) Drag {
        var drag = Drag{ .handle = handle, .from = from, .gizmo = gizmo, .start = start, .to_local = to_local };
        if (drag.planeNormal()) |normal| drag.plane_from = drag.onPlane(normal, from);
        return drag;
    }

    /// The field's value with the pointer at `pointer`, snapped when `snapping`.
    /// Editor-only: uses the original drag snapshot, not accumulated frame deltas; returns
    /// an absolute local Transform field (position metres, rotation degrees or scale factor).
    /// Snap steps come from `snap`; axis scale has a positive minimum. Does not write the world.
    ///
    /// ```zig
    /// const change = drag.changeAt(pointer, true); // Existing Drag and current UI pointer.
    /// // Apply change.value to the Transform field named by change.field through the game ABI.
    /// ```
    pub fn changeAt(self: Drag, pointer: ui.Vec2, snapping: bool) Change {
        const moved = sub2(pointer, self.from);
        switch (self.handle) {
            .arrow => |which| {
                const axis = @backingInt(which);
                var metres = self.alongAxis(axis, moved) * self.gizmo.world_length;
                if (snapping) metres = snapTo(metres, snap.move_m);
                return self.moveBy(scale(self.gizmo.axes[axis], metres));
            },
            .plane, .screen_move => {
                const normal = self.planeNormal().?;
                const before = self.plane_from orelse return .{ .field = .position, .value = self.start.position };
                const now = self.onPlane(normal, pointer) orelse return .{ .field = .position, .value = self.start.position };
                var shift = eggy.camera.sub(now, before);
                if (snapping) for (&shift) |*part| {
                    part.* = snapTo(part.*, snap.move_m);
                };
                return self.moveBy(shift);
            },
            .ring, .screen_ring => {
                var degrees = self.turnedDegrees(pointer);
                if (snapping) degrees = snapTo(degrees, snap.rotate_deg);
                return .{ .field = .rotation_deg, .value = self.turnBy(degrees) };
            },
            .scale_axis => |which| {
                const axis = @backingInt(which);
                var value = self.start.scale;
                value[axis] = @max(0.001, value[axis] * (1 + self.alongAxis(axis, moved)));
                if (snapping) value[axis] = @max(snap.scale, snapTo(value[axis], snap.scale));
                return .{ .field = .scale, .value = value };
            },
            .uniform => {
                // Right and up grow it; left and down shrink it.
                var factor = @max(0.01, 1 + (moved.x - moved.y) / 100);
                if (snapping) factor = @max(snap.scale, snapTo(factor, snap.scale));
                var value = self.start.scale;
                for (&value) |*part| part.* *= factor;
                return .{ .field = .scale, .value = value };
            },
        }
    }

    /// What the drag shows beside the pointer: the angle, distance or factor so far. In `buffer`.
    /// Editor-only: matches `changeAt` snapping; movement distance uses the local position delta
    /// (labelled metres), rotation degrees and scale a dimensionless ratio. Returns borrowed
    /// buffer text or static empty text when formatting does not fit.
    ///
    /// ```zig
    /// var buffer: [64]u8 = undefined;
    /// const label = drag.feedback(pointer, false, &buffer); // Existing Drag/UI pointer.
    /// ```
    pub fn feedback(self: Drag, pointer: ui.Vec2, snapping: bool, buffer: []u8) []const u8 {
        const change = self.changeAt(pointer, snapping);
        return switch (self.handle) {
            .ring, .screen_ring => blk: {
                var degrees = self.turnedDegrees(pointer);
                if (snapping) degrees = snapTo(degrees, snap.rotate_deg);
                break :blk std.fmt.bufPrint(buffer, "{d:.1}°", .{degrees}) catch "";
            },
            .arrow, .plane, .screen_move => std.fmt.bufPrint(buffer, "{d:.2} m", .{length(eggy.camera.sub(change.value, self.start.position))}) catch "",
            .scale_axis => |which| std.fmt.bufPrint(buffer, "×{d:.2}", .{change.value[@backingInt(which)] / @max(0.0001, self.start.scale[@backingInt(which)])}) catch "",
            .uniform => std.fmt.bufPrint(buffer, "×{d:.2}", .{change.value[0] / @max(0.0001, self.start.scale[0])}) catch "",
        };
    }

    /// The position after a move of `world` (a world-space offset), in the parent's space.
    fn moveBy(self: Drag, world: [3]f32) Change {
        return .{ .field = .position, .value = add(self.start.position, eggy.transform.apply(self.to_local, world, 0)) };
    }

    /// The Euler angles after a turn of `degrees` about the dragged ring's axis.
    fn turnBy(self: Drag, degrees: f32) [3]f32 {
        const start = rotation.fromEuler(self.start.rotation_deg);
        const turned = switch (self.handle) {
            // About one of the entity's own axes: turned within its own space.
            .ring => |which| if (self.gizmo.space == .local)
                rotation.mul(start, rotation.aboutAxis(unit(@backingInt(which)), degrees))
            else
                rotation.mul(rotation.aboutAxis(self.parentAxis(unit(@backingInt(which))), degrees), start),
            .screen_ring => rotation.mul(rotation.aboutAxis(self.parentAxis(scale(self.gizmo.view.forward, -1)), degrees), start),
            else => start,
        };
        return rotation.toEuler(turned);
    }

    /// A world direction in the parent's space, unit length.
    fn parentAxis(self: Drag, world: [3]f32) [3]f32 {
        return eggy.camera.normalize(eggy.transform.apply(self.to_local, world, 0));
    }

    /// How far round the centre the pointer went, in degrees, counter-clockwise looking down the
    /// dragged ring's axis.
    fn turnedDegrees(self: Drag, pointer: ui.Vec2) f32 {
        const origin = self.gizmo.origin;
        const before = std.math.atan2(self.from.y - origin.y, self.from.x - origin.x);
        const after = std.math.atan2(pointer.y - origin.y, pointer.x - origin.x);
        var turned = (after - before) * std.math.deg_per_rad;
        if (turned > 180) turned -= 360;
        if (turned < -180) turned += 360;
        // Screen y points down, so a turn that looks counter-clockwise has a falling angle; an
        // axis pointing away from the camera is seen from behind.
        const towards_camera = switch (self.handle) {
            .ring => |which| !self.gizmo.flipped[@backingInt(which)],
            else => true,
        };
        return if (towards_camera) -turned else turned;
    }

    /// How far `moved` goes along `axis` on screen, in axis lengths.
    fn alongAxis(self: Drag, axis: usize, moved: ui.Vec2) f32 {
        const on_screen = sub2(self.gizmo.tips[axis], self.gizmo.origin);
        const squared = on_screen.x * on_screen.x + on_screen.y * on_screen.y;
        if (squared < 1) return 0;
        return (moved.x * on_screen.x + moved.y * on_screen.y) / squared;
    }

    /// The normal of the plane a plane or screen move slides on.
    fn planeNormal(self: Drag) ?[3]f32 {
        return switch (self.handle) {
            .plane => |which| self.gizmo.axes[@backingInt(which)],
            .screen_move => self.gizmo.view.forward,
            else => null,
        };
    }

    /// Where the pointer's ray at `pointer` meets the plane through the entity with `normal`.
    fn onPlane(self: Drag, normal: [3]f32, pointer: ui.Vec2) ?[3]f32 {
        const ray = rayThrough(self.gizmo.view, self.gizmo.scene, pointer);
        const facing = dot(ray.direction, normal);
        if (@abs(facing) < 1e-5) return null;
        const t = dot(eggy.camera.sub(self.gizmo.origin_world, ray.origin), normal) / facing;
        if (t <= 0) return null;
        return add(ray.origin, scale(ray.direction, t));
    }
};

/// The gizmo as paint for a node covering the Scene panel: `hot` (under the pointer) and the
/// dragged handle lit, with `drag`'s feedback (`text`, at `pointer`). In `arena`.
/// Editor-only: copies geometry/interaction state and feedback text into the frame arena,
/// which must survive rendering. Pointer uses the Layout's UI coordinates. Allocation failure
/// yields `.none` or omits feedback text; no entity state changes.
///
/// ```zig
/// const handle_paint = paint(arena, layout_value, hot_handle, drag, pointer, feedback_text);
/// // Frame arena allocator and current Scene gizmo/interaction values.
/// ```
pub fn paint(arena: std.mem.Allocator, gizmo: Layout, hot: ?Handle, drag: ?Drag, pointer: ui.Vec2, text: []const u8) ui.Layout.Paint {
    const drawing = arena.create(Drawing) catch return .none;
    drawing.* = .{ .gizmo = gizmo, .hot = hot, .drag = drag, .pointer = pointer, .text = arena.dupe(u8, text) catch "" };
    return .{ .custom = .{ .context = drawing, .draw = Drawing.draw } };
}

const Drawing = struct {
    gizmo: Layout,
    hot: ?Handle,
    drag: ?Drag,
    pointer: ui.Vec2,
    text: []const u8,

    fn draw(context: *const anyopaque, c: *ui.Canvas, _: ui.Rect) anyerror!void {
        const self: *const Drawing = @ptrCast(@alignCast(context));
        const gizmo = &self.gizmo;
        try self.drawFeedback(c);

        // The view's ring, then each axis's ring (front half), planes, lines and their tips.
        if (gizmo.tool == .rotate) try polyline(c, &gizmo.screen_ring, null, 2, self.colorOf(.screen_ring, neutral));
        if (gizmo.hasRotate()) for (0..3) |axis| {
            try polyline(c, &gizmo.rings[axis], &gizmo.ring_front[axis], 2.5, self.colorOf(.{ .ring = @fromBackingInt(@intCast(axis)) }, axis_colors[axis]));
        };
        if (gizmo.hasMove()) for (0..3) |axis| if (gizmo.plane_shown[axis]) {
            const color = self.colorOf(.{ .plane = @fromBackingInt(@intCast(axis)) }, axis_colors[axis]);
            const quad = gizmo.planes[axis];
            const fill = [4]f32{ color[0], color[1], color[2], 0.35 };
            try c.triangle(.{ pair(quad[0]), pair(quad[1]), pair(quad[2]) }, .{ fill, fill, fill });
            try c.triangle(.{ pair(quad[0]), pair(quad[2]), pair(quad[3]) }, .{ fill, fill, fill });
            for (0..4) |i| try line(c, quad[i], quad[(i + 1) % 4], 1.2, color);
        };
        if (gizmo.tool != .rotate) for (0..3) |axis| if (gizmo.axis_shown[axis]) {
            const handle: Handle = if (gizmo.tool == .scale) .{ .scale_axis = @fromBackingInt(@intCast(axis)) } else .{ .arrow = @fromBackingInt(@intCast(axis)) };
            const color = self.colorOf(handle, axis_colors[axis]);
            try line(c, gizmo.origin, gizmo.tips[axis], 2.5, color);
            if (gizmo.tool == .scale) try box(c, gizmo.tips[axis], 5, color) else try arrowHead(c, gizmo.origin, gizmo.tips[axis], color);
        };
        switch (gizmo.tool) {
            .scale => try box(c, gizmo.origin, 6, self.colorOf(.uniform, neutral)),
            .move, .universal => try dot2(c, gizmo.origin, 6, self.colorOf(.screen_move, neutral)),
            .rotate => {},
        }
    }

    /// While dragging: the arc turned or the path moved, and the amount beside the pointer.
    fn drawFeedback(self: *const Drawing, c: *ui.Canvas) !void {
        const drag = self.drag orelse return;
        const start = drag.gizmo.origin;
        switch (drag.handle) {
            .ring, .screen_ring => {
                const radius = distanceTo(drag.from, start);
                const before = std.math.atan2(drag.from.y - start.y, drag.from.x - start.x);
                const after = std.math.atan2(self.pointer.y - start.y, self.pointer.x - start.x);
                var sweep = after - before;
                if (sweep > std.math.pi) sweep -= std.math.tau;
                if (sweep < -std.math.pi) sweep += std.math.tau;
                const fill = [4]f32{ highlight[0], highlight[1], highlight[2], 0.3 };
                const steps = 32;
                for (0..steps) |i| {
                    const a0 = before + sweep * @as(f32, @floatFromInt(i)) / steps;
                    const a1 = before + sweep * @as(f32, @floatFromInt(i + 1)) / steps;
                    try c.triangle(.{ pair(start), .{ start.x + @cos(a0) * radius, start.y + @sin(a0) * radius }, .{ start.x + @cos(a1) * radius, start.y + @sin(a1) * radius } }, .{ fill, fill, fill });
                }
            },
            .arrow, .plane, .screen_move => try line(c, start, self.gizmo.origin, 1.5, .{ highlight[0], highlight[1], highlight[2], 0.8 }),
            else => {},
        }
        if (self.text.len > 0) {
            const size: f32 = 12;
            const width = c.font.measure(self.text, size) + 10;
            const at = ui.Vec2{ .x = self.pointer.x + 16, .y = self.pointer.y + 16 };
            try c.roundRectAlpha(.{ .x = at.x, .y = at.y, .w = width, .h = 20 }, .{ 0, 0, 0 }, 4, 0.7);
            try c.textIn(.{ .x = at.x + 5, .y = at.y, .w = width - 10, .h = 20 }, self.text, size, neutral, .start);
        }
    }

    fn colorOf(self: *const Drawing, handle: Handle, normal: [3]f32) [4]f32 {
        const lit = if (self.drag) |drag| std.meta.eql(drag.handle, handle) else if (self.hot) |hot| std.meta.eql(hot, handle) else false;
        const rgb = if (lit) highlight else normal;
        return .{ rgb[0], rgb[1], rgb[2], 1 };
    }
};

fn pair(v: ui.Vec2) [2]f32 {
    return .{ v.x, v.y };
}

fn line(c: *ui.Canvas, from: ui.Vec2, to: ui.Vec2, width: f32, color: [4]f32) !void {
    const along = sub2(to, from);
    const span = @sqrt(along.x * along.x + along.y * along.y);
    if (span < 0.01) return;
    const nx = -along.y / span * width / 2;
    const ny = along.x / span * width / 2;
    const a = [2]f32{ from.x + nx, from.y + ny };
    const b = [2]f32{ to.x + nx, to.y + ny };
    const d = [2]f32{ to.x - nx, to.y - ny };
    const e = [2]f32{ from.x - nx, from.y - ny };
    try c.triangle(.{ a, b, d }, .{ color, color, color });
    try c.triangle(.{ a, d, e }, .{ color, color, color });
}

/// A closed line through `points`, leaving out the segments between hidden points.
fn polyline(c: *ui.Canvas, points: []const ui.Vec2, shown: ?[]const bool, width: f32, color: [4]f32) !void {
    for (0..points.len) |i| {
        const next = (i + 1) % points.len;
        if (shown) |visible| if (!visible[i] or !visible[next]) continue;
        try line(c, points[i], points[next], width, color);
    }
}

fn arrowHead(c: *ui.Canvas, from: ui.Vec2, tip: ui.Vec2, color: [4]f32) !void {
    const along = sub2(tip, from);
    const span = @sqrt(along.x * along.x + along.y * along.y);
    if (span < 1) return;
    const ux = along.x / span;
    const uy = along.y / span;
    const size: f32 = 10;
    const base = [2]f32{ tip.x - ux * size, tip.y - uy * size };
    try c.triangle(.{ .{ tip.x + ux * 2, tip.y + uy * 2 }, .{ base[0] - uy * size / 2, base[1] + ux * size / 2 }, .{ base[0] + uy * size / 2, base[1] - ux * size / 2 } }, .{ color, color, color });
}

fn box(c: *ui.Canvas, centre: ui.Vec2, half: f32, color: [4]f32) !void {
    try c.rect(.{ .x = centre.x - half, .y = centre.y - half, .w = half * 2, .h = half * 2 }, .{ color[0], color[1], color[2] });
}

fn dot2(c: *ui.Canvas, centre: ui.Vec2, radius: f32, color: [4]f32) !void {
    try c.roundRect(.{ .x = centre.x - radius, .y = centre.y - radius, .w = radius * 2, .h = radius * 2 }, .{ color[0], color[1], color[2] }, radius);
}

/// Where world `point` lands in `scene`, in points; null behind the camera.
fn toScreen(view_projection: [4][4]f32, scene: ui.Rect, world: [3]f32) ?ui.Vec2 {
    const projected = eggy.camera.project(view_projection, world);
    if (!projected.in_front) return null;
    return .{ .x = scene.x + (projected.x + 1) / 2 * scene.w, .y = scene.y + (1 - projected.y) / 2 * scene.h };
}

fn snapTo(value: f32, step: f32) f32 {
    return @round(value / step) * step;
}

fn insideQuad(p: ui.Vec2, quad: [4]ui.Vec2) bool {
    // Inside when on the same side of every edge.
    var sign: f32 = 0;
    for (0..4) |i| {
        const a = quad[i];
        const b = quad[(i + 1) % 4];
        const side = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
        if (side == 0) continue;
        if (sign == 0) sign = side else if ((side > 0) != (sign > 0)) return false;
    }
    return sign != 0;
}

fn segmentDistance(p: ui.Vec2, a: ui.Vec2, b: ui.Vec2) f32 {
    const ab = sub2(b, a);
    const squared = ab.x * ab.x + ab.y * ab.y;
    const t = if (squared < 0.0001) 0 else std.math.clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / squared, 0, 1);
    return distanceTo(p, .{ .x = a.x + ab.x * t, .y = a.y + ab.y * t });
}

fn ringDistance(p: ui.Vec2, ring: []const ui.Vec2, shown: ?[]const bool) f32 {
    var nearest = std.math.inf(f32);
    for (0..ring.len) |i| {
        const next = (i + 1) % ring.len;
        if (shown) |visible| if (!visible[i] or !visible[next]) continue;
        nearest = @min(nearest, segmentDistance(p, ring[i], ring[next]));
    }
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

fn length(v: [3]f32) f32 {
    return @sqrt(dot(v, v));
}

const identity = [4][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
const test_scene = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
const at_origin = [4][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 1, 0, 1 } };
const still = Start{ .position = .{ 0, 1, 0 }, .rotation_deg = .{ 0, 0, 0 }, .scale = .{ 1, 1, 1 } };

test "dragging the x arrow along its own line moves the entity along x, in snapped steps too" {
    const gizmo = layout(.move, .world, at_origin, .default, test_scene).?;
    const handle = hit(gizmo, gizmo.tips[0]).?;
    try std.testing.expectEqual(Axis.x, handle.arrow);
    const drag = Drag.init(handle, gizmo.origin, gizmo, still, identity);
    const moved = drag.changeAt(gizmo.tips[0], false);
    try std.testing.expectApproxEqAbs(gizmo.world_length, @abs(moved.value[0]), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), moved.value[1], 0.001);
    const snapped = drag.changeAt(gizmo.tips[0], true);
    try std.testing.expectApproxEqAbs(@as(f32, 0), @mod(snapped.value[0], snap.move_m), 0.001);
}

test "a move under a parent turned a quarter is made in the parent's space" {
    const gizmo = layout(.move, .world, at_origin, .default, test_scene).?;
    // The parent's inverse: turned back a quarter about y, world x is the parent's z.
    const to_local = [4][4]f32{ .{ 0, 0, 1, 0 }, .{ 0, 1, 0, 0 }, .{ -1, 0, 0, 0 }, .{ 0, 0, 0, 1 } };
    const drag = Drag.init(.{ .arrow = .x }, gizmo.origin, gizmo, .{ .position = .{ 0, 0, 0 }, .rotation_deg = .{ 0, 0, 0 }, .scale = .{ 1, 1, 1 } }, to_local);
    const moved = drag.changeAt(gizmo.tips[0], false);
    try std.testing.expectApproxEqAbs(gizmo.world_length, @abs(moved.value[2]), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), moved.value[0], 0.001);
}

test "a plane move follows the pointer across the plane, keeping to it" {
    const gizmo = layout(.move, .world, at_origin, .default, test_scene).?;
    // The floor's plane (at right angles to y), taken in the middle of its square.
    const quad = gizmo.planes[1];
    const middle = ui.Vec2{ .x = (quad[0].x + quad[2].x) / 2, .y = (quad[0].y + quad[2].y) / 2 };
    try std.testing.expectEqual(Axis.y, hit(gizmo, middle).?.plane);
    const drag = Drag.init(.{ .plane = .y }, middle, gizmo, still, identity);
    const moved = drag.changeAt(.{ .x = middle.x + 40, .y = middle.y + 20 }, false);
    try std.testing.expectApproxEqAbs(@as(f32, 1), moved.value[1], 0.001);
    try std.testing.expect(moved.value[0] > 0 and moved.value[2] > 0);
}

test "the middle box resizes on every axis, and nothing is taken far from the gizmo" {
    const gizmo = layout(.scale, .world, at_origin, .default, test_scene).?;
    try std.testing.expectEqual(Handle.uniform, hit(gizmo, gizmo.origin).?);
    try std.testing.expect(hit(gizmo, .{ .x = 5, .y = 5 }) == null);
    const drag = Drag.init(.uniform, gizmo.origin, gizmo, .{ .position = .{ 0, 1, 0 }, .rotation_deg = .{ 0, 0, 0 }, .scale = .{ 1, 2, 1 } }, identity);
    const grown = drag.changeAt(.{ .x = gizmo.origin.x + 100, .y = gizmo.origin.y }, false);
    try std.testing.expectEqualSlices(f32, &.{ 2, 4, 2 }, &grown.value);
}

test "turning the y ring a snapped step turns about y only" {
    const gizmo = layout(.rotate, .world, at_origin, .default, test_scene).?;
    const ring = gizmo.rings[1];
    // A front point of the ring, then a little further round it.
    var front: usize = 0;
    while (!gizmo.ring_front[1][front]) front += 1;
    const drag = Drag.init(.{ .ring = .y }, ring[front], gizmo, still, identity);
    const turned = drag.changeAt(ring[(front + 6) % ring_points], true);
    try std.testing.expectEqual(@TypeOf(turned.field).rotation_deg, turned.field);
    try std.testing.expectApproxEqAbs(@as(f32, 0), turned.value[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), turned.value[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), @mod(turned.value[1] + 360, snap.rotate_deg), 0.01);
    try std.testing.expect(turned.value[1] != 0);
}
