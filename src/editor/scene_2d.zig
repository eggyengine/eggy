//! The 2D Scene panel: the world seen flat from the front (its XY plane, Y up) through an
//! orthographic camera, as a 2D game sees it. Scroll to zoom about the pointer, drag with the
//! right or middle button to pan, click an entity to select it and drag it to move it (snapped to
//! the grid when Snap is on). F frames the selection and Delete deletes it. On a gamepad the left stick pans, the triggers zoom (right in,
//! left out) and holding the left shoulder pans faster. The editor renders the world into the panel (`shot`); the grid and
//! the pointer's place are drawn over it.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const sdl3 = eggy.sdl_adapter.sdl;
const scene_view = @import("scene_view/scene_view.zig");
const page_style = @import("page_style.zig");

/// What the editor renders this frame: the world seen through `view`, into `rect` (logical
/// points of the panel's window), drawn in at `mark` of the page's vertices, under the grid.
pub const Shot = struct {
    rect: ui.Rect,
    view: eggy.camera.View,
    mark: usize,
};

/// The grid's spacings to choose from, in metres: the smallest at least `min_gap_px` apart.
const grid_steps_m = [_]f32{ 0.0625, 0.125, 0.25, 0.5, 1, 2, 5, 10, 25, 50, 100, 250, 500, 1000 };
const min_gap_px = 18;

pub const Scene2d = struct {
    /// The world point at the panel's centre, and how many metres its height shows.
    centre: [2]f32 = .{ 0, 0 },
    height_m: f32 = 12,
    grid: bool = true,
    snap: bool = false,
    /// Where the viewport was laid out last frame, the page's vertex count where it was painted,
    /// and whether it was built this frame.
    area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    mark: ?usize = null,
    shown: bool = false,
    pointer: ui.Vec2 = .{ .x = 0, .y = 0 },
    /// Whether the pointer is over the viewport, so a gamepad steers this panel.
    hovered: bool = false,
    /// What was drawn last (for picking); the editor sets it when it renders.
    drawn: []const eggy.mesh.Drawable = &.{},
    /// Where the pointer was last while panning.
    panning: ?ui.Vec2 = null,
    moving: ?Move = null,

    /// An entity being dragged: where it and the pointer started, and how world moves become
    /// moves in its parent's space.
    const Move = struct {
        entity: eggy.ecs.EntityId,
        from_world: [2]f32,
        from_position: [3]f32,
        to_local: [4][4]f32,
    };

    /// The camera the panel sees through: from in front of the XY plane, looking along -Z.
    pub fn view(self: *const Scene2d) eggy.camera.View {
        return .{
            .eye = .{ self.centre[0], self.centre[1], 1000 },
            .forward = .{ 0, 0, -1 },
            .up = .{ 0, 1, 0 },
            .near = 0.1,
            .far = 4000,
            .projection = .orthographic,
            .orthographic_height_m = self.height_m,
        };
    }

    /// What the editor renders this frame; null when the panel isn't shown.
    pub fn shot(self: *const Scene2d) ?Shot {
        if (!self.shown or self.area.w < 1 or self.area.h < 1) return null;
        return .{ .rect = self.area, .view = self.view(), .mark = self.mark orelse return null };
    }

    /// Whether an entity is being dragged, so the scene isn't recorded mid-move.
    pub fn isMoving(self: *const Scene2d) bool {
        return self.moving != null;
    }

    /// Draw the panel: its toolbar, the viewport the world goes into, and the grid over it.
    pub fn build(self: *Scene2d, context: *ui.Context) void {
        self.shown = false;
        // The toolbar: the grid, snapping, and back to the origin.
        context.begin(.row);
        _ = context.toggle("Grid", &self.grid);
        _ = context.toggle("Snap", &self.snap);
        if (context.buttonVariant("Frame origin", .outline)) {
            self.centre = .{ 0, 0 };
            self.height_m = 12;
        }
        const at = self.worldAt(self.pointer);
        context.muted(std.fmt.allocPrint(context.builder().allocator, "x {d:.2}  y {d:.2}   {d:.1} m tall", .{ at[0], at[1], self.height_m }) catch "");
        page_style.smallText(context, 12);
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 12, .align_items = .center });

        // The viewport fills the rest: the world is drawn in where it starts, the grid over it.
        const b = context.builder();
        const height = @max(80, page_style.pageHeight(context) - 44);
        context.element(b.node(0, .{ .width = context.contentWidth(), .height = height }, .{ .custom = .{ .context = self, .draw = drawViewport } }, &.{}) catch return);
        self.shown = true;
    }

    /// Zoom, pan, select and move, for an event the workspace let through. Returns whether the
    /// event was the panel's. A left press selects what is under it (its outermost scene
    /// instance) and starts moving it; the host records the move as one History step once
    /// `isMoving` turns false.
    pub fn handle(self: *Scene2d, event: sdl3.events.Event, target: ?scene_view.Target) bool {
        if (!self.shown) return false;
        switch (event) {
            .mouse_wheel => |wheel| {
                const at = ui.Vec2{ .x = wheel.x, .y = wheel.y };
                if (!self.area.contains(at.x, at.y)) return false;
                self.zoomAbout(at, wheel.scroll_y);
                return true;
            },
            .mouse_button_down => |down| {
                const at = ui.Vec2{ .x = down.x, .y = down.y };
                if (!self.area.contains(at.x, at.y)) return false;
                if (down.button != .left) {
                    self.panning = at;
                    return true;
                }
                const live = target orelse return true;
                const picked = scene_view.picking.pick(self.drawn, &live.app.graphics.models, &live.app.ui_scenes, live.app.resources(), self.view(), self.area, at);
                live.selected.* = scene_view.instanceRoot(live, picked);
                if (live.selected.*) |entity| self.moving = startMove(live, entity, self.worldAt(at));
                return true;
            },
            .mouse_motion => |motion| {
                const at = ui.Vec2{ .x = motion.x, .y = motion.y };
                self.pointer = at;
                self.hovered = self.area.contains(at.x, at.y);
                if (self.panning) |from| {
                    self.panBy(at.x - from.x, at.y - from.y);
                    self.panning = at;
                    return true;
                }
                const move = self.moving orelse return false;
                if (target) |live| self.moveTo(live, move, self.worldAt(at));
                return true;
            },
            .mouse_button_up => {
                const used = self.panning != null or self.moving != null;
                self.panning = null;
                self.moving = null;
                return used;
            },
            else => return false,
        }
    }

    /// Pan and zoom by a gamepad's left stick and triggers, over `seconds`.
    /// Desktop editor only: pass a finite nonnegative frame duration and the pad's raw state.
    /// A full stick crosses the panel's height each second, whatever the zoom; zooming keeps
    /// the panel's centre still. Call once per frame.
    pub fn steer(self: *Scene2d, pad: eggy.input.ControllerState, seconds: f32) void {
        const stick = scene_view.deadZone(pad.left_stick);
        const speed = self.height_m * seconds * (if (pad.buttons.contains(.left_shoulder)) @as(f32, 3) else 1);
        self.centre[0] += stick[0] * speed;
        self.centre[1] -= stick[1] * speed;
        const zoom_in = pad.triggers[1] - pad.triggers[0];
        if (@abs(zoom_in) > 0.15) self.height_m = std.math.clamp(self.height_m * @exp(-zoom_in * 1.5 * seconds), 0.25, 5000);
    }

    /// Centre on `centre`, zoomed to show `radius` around it.
    pub fn frame(self: *Scene2d, centre: [2]f32, radius: f32) void {
        self.centre = centre;
        self.height_m = std.math.clamp(radius * 4, 0.25, 5000);
    }

    /// Zoom in `notches` wheel steps (out when negative), the point under `at` staying there.
    fn zoomAbout(self: *Scene2d, at: ui.Vec2, notches: f32) void {
        const before = self.worldAt(at);
        self.height_m = std.math.clamp(self.height_m * @exp(-notches * 0.12), 0.25, 5000);
        const after = self.worldAt(at);
        self.centre[0] += before[0] - after[0];
        self.centre[1] += before[1] - after[1];
    }

    /// Drag the world `dx`, `dy` points with the pointer.
    fn panBy(self: *Scene2d, dx: f32, dy: f32) void {
        const metres_per_px = self.height_m / @max(1, self.area.h);
        self.centre[0] -= dx * metres_per_px;
        self.centre[1] += dy * metres_per_px;
    }

    /// The world point (on the XY plane) under `at` on the panel.
    fn worldAt(self: *const Scene2d, at: ui.Vec2) [2]f32 {
        if (self.area.h <= 0) return self.centre;
        const metres_per_px = self.height_m / self.area.h;
        return .{
            self.centre[0] + (at.x - (self.area.x + self.area.w / 2)) * metres_per_px,
            self.centre[1] - (at.y - (self.area.y + self.area.h / 2)) * metres_per_px,
        };
    }

    /// The grid's spacing at this zoom, in metres.
    fn gridStep(self: *const Scene2d) f32 {
        const px_per_metre = self.area.h / self.height_m;
        for (grid_steps_m) |step| if (step * px_per_metre >= min_gap_px) return step;
        return grid_steps_m[grid_steps_m.len - 1];
    }

    /// Move the entity `move` holds by how far the pointer went (now at `world`), in its
    /// parent's space, onto the grid when snapping.
    fn moveTo(self: *const Scene2d, target: scene_view.Target, move: Move, world: [2]f32) void {
        const component = target.game.builtinComponent("Transform") orelse return;
        const along = eggy.transform.apply(move.to_local, .{ world[0] - move.from_world[0], world[1] - move.from_world[1], 0 }, 0);
        var position = move.from_position;
        for (&position, along) |*value, delta| value.* += delta;
        if (self.snap) {
            const step = self.gridStep();
            for (position[0..2]) |*value| value.* = @round(value.* / step) * step;
        }
        var text: [160]u8 = undefined;
        const zon = std.fmt.bufPrintSentinel(&text, ".{{ {d}, {d}, {d} }}", .{ position[0], position[1], position[2] }, 0) catch return;
        _ = target.game.writeField(target.app, move.entity, component, 0, zon);
    }
};

/// Begin dragging `entity`, the pointer at `world`: read where it is, and how world moves map
/// into its parent's space. Null when it has no Transform to move.
fn startMove(target: scene_view.Target, entity: eggy.ecs.EntityId, world: [2]f32) ?Scene2d.Move {
    const component = target.game.builtinComponent("Transform") orelse return null;
    var buffer: [160]u8 = undefined;
    const text = target.game.readField(target.app, entity, component, 0, &buffer) orelse return null;
    const position = scene_view.parseVector(text) orelse return null;
    var to_local = [4][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    if (target.app.world.getParent(entity)) |parent| if (target.game.worldMatrix(target.app, parent)) |placed| {
        to_local = eggy.transform.invert(placed) orelse return null;
    };
    return .{ .entity = entity, .from_world = world, .from_position = position, .to_local = to_local };
}

// Keep where the viewport was laid out and where in the page's drawing the world goes in, then
// draw the grid over it: lines every step, the axes through the origin in their colours.
fn drawViewport(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const self: *Scene2d = @ptrCast(@alignCast(@constCast(context)));
    self.area = r;
    self.mark = c.len;
    const outer = c.clip;
    defer c.clip = outer;
    c.clip = if (outer) |within| within.intersection(r) else r;
    if (self.grid) {
        const step = self.gridStep();
        const px_per_metre = r.h / self.height_m;
        const left = self.centre[0] - r.w / 2 / px_per_metre;
        const top = self.centre[1] + r.h / 2 / px_per_metre;
        var x = @ceil(left / step) * step;
        while ((x - left) * px_per_metre <= r.w) : (x += step) {
            const at = r.x + (x - left) * px_per_metre;
            try c.rectAlpha(.{ .x = at, .y = r.y, .w = 1, .h = r.h }, c.theme.foreground, if (@abs(x) < step / 2) 0 else 0.08);
        }
        var y = @floor(top / step) * step;
        while ((top - y) * px_per_metre <= r.h) : (y -= step) {
            const at = r.y + (top - y) * px_per_metre;
            try c.rectAlpha(.{ .x = r.x, .y = at, .w = r.w, .h = 1 }, c.theme.foreground, if (@abs(y) < step / 2) 0 else 0.08);
        }
        // The axes: X red along y = 0, Y green along x = 0.
        const origin_x = r.x + (0 - left) * px_per_metre;
        const origin_y = r.y + top * px_per_metre;
        if (origin_y >= r.y and origin_y <= r.y + r.h) try c.rectAlpha(.{ .x = r.x, .y = origin_y - 0.5, .w = r.w, .h = 1.5 }, .{ 0.86, 0.3, 0.3 }, 0.8);
        if (origin_x >= r.x and origin_x <= r.x + r.w) try c.rectAlpha(.{ .x = origin_x - 0.5, .y = r.y, .w = 1.5, .h = r.h }, .{ 0.4, 0.78, 0.35 }, 0.8);
    }
    try c.roundRectStroke(r, c.theme.border, 0, 1);
}

test "zooming keeps the point under the pointer still" {
    var view = Scene2d{ .area = .{ .x = 0, .y = 0, .w = 400, .h = 200 }, .shown = true };
    const pointer = ui.Vec2{ .x = 300, .y = 50 };
    const before = view.worldAt(pointer);
    view.zoomAbout(pointer, 2);
    try std.testing.expect(view.height_m < 12);
    const after = view.worldAt(pointer);
    try std.testing.expectApproxEqAbs(before[0], after[0], 1e-4);
    try std.testing.expectApproxEqAbs(before[1], after[1], 1e-4);
}

test "panning drags the world with the pointer, and the grid thins out when zoomed out" {
    var view = Scene2d{ .area = .{ .x = 0, .y = 0, .w = 400, .h = 200 }, .shown = true };
    // 12 m over 200 px: 100 px right is 6 m, the world moving right under the pointer.
    view.panBy(100, 0);
    try std.testing.expectApproxEqAbs(@as(f32, -6), view.centre[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), view.worldAt(.{ .x = 300, .y = 100 })[0], 1e-4);
    const near_step = view.gridStep();
    view.height_m = 400;
    try std.testing.expect(view.gridStep() > near_step);
}

test "a gamepad's left stick pans a panel height a second, and the right trigger zooms in" {
    var view = Scene2d{};
    view.steer(.{ .left_stick = .{ 1, 0 } }, 0.5);
    view.steer(.{ .left_stick = .{ 0, -1 } }, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 6), view.centre[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 6), view.centre[1], 1e-4);
    view.steer(.{ .triggers = .{ 0, 1 } }, 1);
    try std.testing.expect(view.height_m < 12);
    const height = view.height_m;
    view.steer(.{ .left_stick = .{ 0.1, 0 }, .triggers = .{ 0.1, 0 } }, 1);
    try std.testing.expectEqual(height, view.height_m);
}

test "a click picks the entity under the pointer through the flat view" {
    var view = Scene2d{ .area = .{ .x = 0, .y = 0, .w = 400, .h = 200 }, .shown = true };
    view.panBy(-100, 0);
    // Panned to x = 6 m; at 12 m over 200 px, 50 px right of the middle is 3 m further, on the cube.
    const cube = eggy.mesh.Drawable{ .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 9, 0, 0, 1 } }, .color = .{ 1, 1, 1, 1 }, .shape = .cube, .entity_id = 4, .entity_generation = 0 };
    var models = eggy.model_cache.ModelCache.init(std.testing.allocator, undefined);
    var ui_scenes = eggy.ui_scenes.State{ .gpa = std.testing.allocator };
    const over = view.worldAt(.{ .x = 250, .y = 100 });
    try std.testing.expectApproxEqAbs(@as(f32, 9), over[0], 1e-4);
    try std.testing.expectEqual(@as(u32, 4), scene_view.picking.pick(&.{cube}, &models, &ui_scenes, .{}, view.view(), view.area, .{ .x = 250, .y = 100 }).?.id);
    try std.testing.expect(scene_view.picking.pick(&.{cube}, &models, &ui_scenes, .{}, view.view(), view.area, .{ .x = 100, .y = 100 }) == null);
}
