//! The 2D Scene panel: the world seen flat from the front (its XY plane, Y up) through an
//! orthographic camera, as a 2D game sees it. Scroll to zoom about the pointer, drag with the
//! right or middle button to pan, click an entity to select it and drag it to move it (snapped to
//! the grid when snapping). The tool picked on the floating toolbar (the Scene's, `toolbar.zig`;
//! W, E, R and T) sets the selection's handles: its corners scale it (Shift: evenly) and the knob
//! above it turns it (in 15 degree steps when snapping); Ctrl turns snapping round while
//! dragging. The arrow keys nudge it a grid step. F frames the selection and Delete deletes it. A
//! selected `Tilemap` is painted with `tile_brush.zig`. On a gamepad the left stick pans, the
//! triggers zoom (right in, left out) and holding the left shoulder pans faster. The editor
//! renders the world into the panel (`shot`); the grid, the handles, the toolbar and the
//! pointer's place are drawn over it.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const sdl3 = eggy.sdl_adapter.sdl;
const scene_view = @import("../scene_view/scene_view.zig");
const page_style = @import("../page_style.zig");
const handles = @import("handles.zig");
const toolbar = scene_view.toolbar;
pub const tile_brush = @import("tile_brush.zig");

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
    /// The floating toolbar: the tool, snapping and the grid. Scaling and turning both show at first.
    tools: toolbar.State = .{ .panel = .scene_2d, .tool = .universal },
    /// The toolbar's drag by its grip: where the pointer and the toolbar were when it began.
    toolbar_drag: ?struct { from: ui.Vec2, offset: ui.Vec2 } = null,
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
    /// What the editor has selected, for its handles; it sets this each frame.
    selected: ?eggy.ecs.EntityId = null,
    /// A corner or the knob being dragged.
    reshaping: ?Reshape = null,
    /// Painting the selection's tilemap.
    brush: tile_brush.Brush = .{},

    const Reshape = struct { entity: eggy.ecs.EntityId, drag: handles.Drag };

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

    /// The toolbar button `button` was pressed: pick a tool, switch snapping or the grid, go back
    /// to the origin, fold, or start dragging the toolbar by its grip.
    pub fn press(self: *Scene2d, button: toolbar.Button) void {
        switch (button) {
            .grip => self.toolbar_drag = .{ .from = self.pointer, .offset = self.tools.offset },
            .move => self.tools.tool = .move,
            .rotate => self.tools.tool = .rotate,
            .scale => self.tools.tool = .scale,
            .universal => self.tools.tool = .universal,
            .snap => self.tools.snapping = !self.tools.snapping,
            .grid => self.tools.grid = !self.tools.grid,
            .frame_origin => {
                self.centre = .{ 0, 0 };
                self.height_m = 12;
            },
            .fold => self.tools.folded = !self.tools.folded,
            // The Scene's own; this toolbar doesn't show them.
            .space, .game_camera => {},
        }
    }

    /// W, E, R or T (without Ctrl or Alt) picks the tool, as over the Scene. Returns whether it did.
    pub fn shortcut(self: *Scene2d, key: sdl3.keycode.Keycode, mod: sdl3.keycode.KeyModifier) bool {
        if (mod.controlDown() or mod.altDown()) return false;
        self.tools.tool = switch (key) {
            .w => .move,
            .e => .rotate,
            .r => .scale,
            .t => .universal,
            else => return false,
        };
        return true;
    }

    /// Whether a drag snaps now: the toolbar's setting, turned round while Ctrl is held.
    fn snapping(self: *const Scene2d) bool {
        return self.tools.snapping != sdl3.keyboard.getModState().controlDown();
    }

    /// Where the toolbar's top left corner is on the panel.
    fn toolbarCorner(self: *const Scene2d) ui.Vec2 {
        const at = toolbar.keepInside(self.tools, self.tools.offset, self.area);
        return .{ .x = self.area.x + at.x, .y = self.area.y + at.y };
    }

    /// Whether an entity is being moved, scaled or turned, so the scene isn't recorded mid-drag.
    pub fn isMoving(self: *const Scene2d) bool {
        return self.moving != null or self.reshaping != null;
    }

    /// Move the selection `steps` grid steps along x and y (onto the grid when snapping).
    /// Returns whether there was a selection with a Transform to move.
    pub fn nudge(self: *const Scene2d, target: scene_view.Target, steps: [2]f32) bool {
        const entity = self.selected orelse return false;
        const move = startMove(target, entity, .{ 0, 0 }) orelse return false;
        const step = self.gridStep();
        self.moveTo(target, move, .{ steps[0] * step, steps[1] * step });
        return true;
    }

    /// Draw the panel: the viewport the world goes into, with the grid, the toolbar and the
    /// pointer's place floating over it. With `app`, the tile brush's toggle and palette show
    /// above it for a tilemap.
    pub fn build(self: *Scene2d, context: *ui.Context, app: ?*eggy.App, gpa: std.mem.Allocator) void {
        self.shown = false;
        if (app) |live| self.brush.build(context, live, gpa);
        const brush_px: f32 = if (self.brush.target == null or app == null) 0 else if (self.brush.painting) 44 + tile_brush.palette_height_px else 40;

        // The viewport fills the rest: the world is drawn in where it starts, the grid over it,
        // and the toolbar and the pointer's place float over that (where it was laid out last).
        const b = context.builder();
        const height = @max(80, page_style.pageHeight(context) - brush_px);
        const floating = self.overlay(b) catch return;
        context.element(b.node(0, .{ .width = context.contentWidth(), .height = height }, .{ .custom = .{ .context = self, .draw = drawViewport } }, floating) catch return);
        self.shown = true;
    }

    /// The toolbar, its tooltip, and the pointer's place in the bottom left corner.
    fn overlay(self: *const Scene2d, b: ui.Layout.Builder) ![]const *ui.Layout.Element {
        var parts: std.ArrayList(*ui.Layout.Element) = .empty;
        try parts.append(b.allocator, try toolbar.element(b, self.tools, self.area));
        const corner = self.toolbarCorner();
        if (self.toolbar_drag == null and self.hovered) if (toolbar.buttonAt(self.tools, corner, self.pointer)) |button| {
            const tip = try ui.widgets.tooltip(b, toolbar.describe(button, self.tools));
            tip.style.z_index = 30;
            tip.overlay = .{ .point = .init(corner.x, corner.y + toolbar.size(self.tools).y + 4) };
            try parts.append(b.allocator, tip);
        };
        const at = self.worldAt(self.pointer);
        const place = try std.fmt.allocPrint(b.allocator, "x {d:.2}   y {d:.2}   {d:.1} m tall", .{ at[0], at[1], self.height_m });
        const label = try b.node(0, .{ .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 }, .z_index = 20 }, .{ .surface = .popover }, &.{
            try b.node(0, .{}, .{ .text = .{ .value = place, .size = 12, .tone = .muted } }, &.{}),
        });
        label.overlay = .{ .point = .init(self.area.x + 8, self.area.y + @max(0, self.area.h - 30)) };
        try parts.append(b.allocator, label);
        return parts.items;
    }

    /// Zoom, pan, select and move, for an event the workspace let through. Returns whether the
    /// event was the panel's. A left press selects what is under it (its outermost scene
    /// instance) and starts moving it; the host records the move as one History step once
    /// `isMoving` turns false.
    pub fn handle(self: *Scene2d, event: sdl3.events.Event, target: ?scene_view.Target, brush_env: ?tile_brush.Env) bool {
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
                // The toolbar floats over everything else.
                if (toolbar.buttonAt(self.tools, self.toolbarCorner(), at)) |button| {
                    self.pointer = at;
                    self.press(button);
                    return true;
                }
                const live = target orelse return true;
                // Painting tiles takes the press while the brush is on and over its map.
                if (brush_env) |env| if (self.mapPoint(self.worldAt(at))) |local| {
                    const keys = sdl3.keyboard.getModState();
                    if (self.brush.press(env, local, keys.shiftDown(), keys.altDown())) return true;
                };
                // The selection's corners and knob come before what is under them.
                if (self.selectedBox()) |box| if (box.handleAt(self.worldAt(at), self.metresPerPx(), self.handlesShown())) |taken| {
                    self.reshaping = startReshape(live, self.selected.?, taken, box, self.worldAt(at));
                    return true;
                };
                const picked = scene_view.picking.pick(self.drawn, &live.app.graphics.models, &live.app.ui_scenes, live.app.resources(), self.view(), self.area, at);
                live.selected.* = scene_view.instanceRoot(live, picked);
                if (live.selected.*) |entity| self.moving = startMove(live, entity, self.worldAt(at));
                return true;
            },
            .mouse_motion => |motion| {
                const at = ui.Vec2{ .x = motion.x, .y = motion.y };
                self.pointer = at;
                self.hovered = self.area.contains(at.x, at.y);
                if (self.toolbar_drag) |moving| {
                    self.tools.offset = toolbar.keepInside(self.tools, .{ .x = moving.offset.x + at.x - moving.from.x, .y = moving.offset.y + at.y - moving.from.y }, self.area);
                    return true;
                }
                if (self.panning) |from| {
                    self.panBy(at.x - from.x, at.y - from.y);
                    self.panning = at;
                    return true;
                }
                if (self.reshaping) |reshape| {
                    if (target) |live| reshapeTo(live, reshape, self.worldAt(at), sdl3.keyboard.getModState().shiftDown(), self.snapping());
                    return true;
                }
                if (self.brush.stroking()) {
                    if (brush_env) |env| if (self.mapPoint(self.worldAt(at))) |local| self.brush.paint(env, local, sdl3.keyboard.getModState().shiftDown());
                    return true;
                }
                const move = self.moving orelse return false;
                if (target) |live| self.moveTo(live, move, self.worldAt(at));
                return true;
            },
            .mouse_button_up => {
                if (brush_env) |env| if (self.brush.release(env)) return true;
                const used = self.panning != null or self.moving != null or self.reshaping != null or self.toolbar_drag != null;
                self.toolbar_drag = null;
                self.panning = null;
                self.moving = null;
                self.reshaping = null;
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

    fn metresPerPx(self: *const Scene2d) f32 {
        return self.height_m / @max(1, self.area.h);
    }

    /// Where on the panel the world point `world` (on the XY plane) is.
    fn screenAt(self: *const Scene2d, world: [2]f32) ui.Vec2 {
        const px_per_metre = 1 / self.metresPerPx();
        return .{
            .x = self.area.x + self.area.w / 2 + (world[0] - self.centre[0]) * px_per_metre,
            .y = self.area.y + self.area.h / 2 - (world[1] - self.centre[1]) * px_per_metre,
        };
    }

    /// The world point `world` in the brush's tilemap's own space (tiles, y up from its top
    /// edge); null without a tilemap drawn here.
    fn mapPoint(self: *const Scene2d, world: [2]f32) ?[2]f32 {
        const entity = (self.brush.target orelse return null).entity;
        for (self.drawn) |drawable| {
            if (drawable.entity_id != entity.id or drawable.entity_generation != entity.generation) continue;
            const to_local = eggy.transform.invert(drawable.model) orelse return null;
            const local = eggy.transform.apply(to_local, .{ world[0], world[1], drawable.model[3][2] }, 1);
            return .{ local[0], local[1] };
        }
        return null;
    }

    /// The handles the tool picked shows: Move none, Rotate the knob, Scale the corners, and
    /// Universal both.
    fn handlesShown(self: *const Scene2d) handles.Shown {
        return switch (self.tools.tool) {
            .move => .{ .corners = false, .knob = false },
            .rotate => .{ .corners = false, .knob = true },
            .scale => .{ .corners = true, .knob = false },
            .universal => .{ .corners = true, .knob = true },
        };
    }

    /// The selection's box, from what was drawn last; null when it isn't drawn here.
    fn selectedBox(self: *const Scene2d) ?handles.Box {
        const entity = self.selected orelse return null;
        for (self.drawn) |drawable| {
            if (drawable.entity_id == entity.id and drawable.entity_generation == entity.generation) return .of(drawable.model);
        }
        return null;
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
        if (self.snapping()) {
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

/// Take `handle` of `entity`'s `box` with the pointer at `world`: read its rotation and scale.
/// Null when it has no Transform.
fn startReshape(target: scene_view.Target, entity: eggy.ecs.EntityId, handle: handles.Handle, box: handles.Box, world: [2]f32) ?Scene2d.Reshape {
    const component = target.game.builtinComponent("Transform") orelse return null;
    var buffer: [160]u8 = undefined;
    const rotation_deg = scene_view.parseVector(target.game.readField(target.app, entity, component, 1, &buffer) orelse return null) orelse return null;
    const scale = scene_view.parseVector(target.game.readField(target.app, entity, component, 2, &buffer) orelse return null) orelse return null;
    return .{ .entity = entity, .drag = .{ .handle = handle, .box = box, .from = world, .rotation_deg = rotation_deg, .scale = scale } };
}

/// Write what dragging `reshape`'s handle to `world` makes of its entity's rotation or scale.
fn reshapeTo(target: scene_view.Target, reshape: Scene2d.Reshape, world: [2]f32, uniform: bool, snap: bool) void {
    const component = target.game.builtinComponent("Transform") orelse return;
    const field: usize, const value = switch (reshape.drag.apply(world, uniform, snap)) {
        .rotation_deg => |v| .{ 1, v },
        .scale => |v| .{ 2, v },
    };
    var text: [160]u8 = undefined;
    const zon = std.fmt.bufPrintSentinel(&text, ".{{ {d}, {d}, {d} }}", .{ value[0], value[1], value[2] }, 0) catch return;
    _ = target.game.writeField(target.app, reshape.entity, component, field, zon);
}

/// The selection's box, and the handles its tool shows: a square on each corner, the knob on
/// its stalk.
fn drawHandles(self: *const Scene2d, c: *ui.Canvas) !void {
    const box = self.selectedBox() orelse return;
    const accent = c.theme.primary;
    const shown = self.handlesShown();
    var corners: [4]ui.Vec2 = undefined;
    for (&corners, box.corners()) |*at, world| at.* = self.screenAt(world);
    for (corners, 0..) |from, i| try line(c, from, corners[(i + 1) % 4], 1.5, accent);
    if (shown.knob) {
        const top = self.screenAt(.{ (box.corners()[2][0] + box.corners()[3][0]) / 2, (box.corners()[2][1] + box.corners()[3][1]) / 2 });
        const knob = self.screenAt(box.knob(self.metresPerPx()));
        try line(c, top, knob, 1.5, accent);
        try c.roundRect(.{ .x = knob.x - 6, .y = knob.y - 6, .w = 12, .h = 12 }, accent, 6);
    }
    if (shown.corners) for (corners) |at| {
        try c.rect(.{ .x = at.x - 5, .y = at.y - 5, .w = 10, .h = 10 }, c.theme.background);
        try c.roundRectStroke(.{ .x = at.x - 5, .y = at.y - 5, .w = 10, .h = 10 }, accent, 0, 1.5);
    };
}

/// A straight line `width` points wide from `from` to `to`.
fn line(c: *ui.Canvas, from: ui.Vec2, to: ui.Vec2, width: f32, color: [3]f32) !void {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 0.001) return;
    const nx = -dy / length * width / 2;
    const ny = dx / length * width / 2;
    const colour = [4]f32{ color[0], color[1], color[2], 1 };
    const a = [2]f32{ from.x + nx, from.y + ny };
    const b = [2]f32{ to.x + nx, to.y + ny };
    const d = [2]f32{ to.x - nx, to.y - ny };
    const e = [2]f32{ from.x - nx, from.y - ny };
    try c.triangle(.{ a, b, d }, @splat(colour));
    try c.triangle(.{ a, d, e }, @splat(colour));
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
    if (self.tools.grid) {
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
    try drawHandles(self, c);
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
