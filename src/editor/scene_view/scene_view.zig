//! The Scene panel: what it is seen from (its own camera, `scene_camera.zig`, or the game's), the
//! toolbar floating over it (`toolbar.zig`), the view's orientation in its corner
//! (`orientation.zig`), clicking an entity to select it (`picking.zig`), and the gizmo that moves,
//! turns and resizes the selected one (`gizmo.zig`), which edits its `Transform` through the
//! game's library. It can look through the game's camera instead (`game_camera.zig`), and while
//! editing, its controls then move that camera; with none to look through it says so. A camera
//! selected shows what it sees in a corner. W, E, R and T pick Move, Rotate, Scale and Universal while the pointer is over
//! the panel; Ctrl turns snapping round while dragging.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const sdl3 = eggy.sdl_adapter.sdl;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const gizmo = @import("gizmo.zig");
const picking = @import("picking.zig");
const orientation = @import("orientation.zig");
const game_camera = @import("game_camera.zig");
pub const toolbar = @import("toolbar.zig");
pub const SceneCamera = @import("scene_camera.zig").SceneCamera;

/// What the dock draws over the Scene panel this frame.
pub const Overlay = struct {
    tools: toolbar.State = .{},
    view: eggy.camera.View = .default,
    gizmo: ?gizmo.Layout = null,
    hot: ?gizmo.Handle = null,
    drag: ?gizmo.Drag = null,
    hot_end: ?orientation.End = null,
    pointer: ui.Vec2 = .{ .x = 0, .y = 0 },
    /// The drag's feedback beside the pointer.
    feedback: []const u8 = "",
    /// Whether it looks through the game's camera, and there is none.
    no_camera: bool = false,
    /// Where the selected camera's view is shown, in the panel's points.
    preview: ?ui.Rect = null,

    pub const none: Overlay = .{};
};

/// The Scene panel's floating parts for its node at `scene`: the orientation, the gizmo, then
/// the toolbar.
pub fn overlayElements(b: L.Builder, overlay: Overlay, scene: ui.Rect) ![]*L.Element {
    var parts: std.ArrayList(*L.Element) = .empty;
    const drawn = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 10 }, orientation.paint(b.allocator, overlay.view, scene, overlay.hot_end), &.{});
    drawn.overlay = .{ .point = .init(scene.x, scene.y) };
    drawn.accessibility.role = .ignored;
    try parts.append(b.allocator, drawn);
    if (overlay.gizmo) |layout| {
        const handles = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 11 }, gizmo.paint(b.allocator, layout, overlay.hot, overlay.drag, overlay.pointer, overlay.feedback), &.{});
        handles.overlay = .{ .point = .init(scene.x, scene.y) };
        handles.accessibility.role = .ignored;
        try parts.append(b.allocator, handles);
    }
    // Nothing to see through: say so, in the middle.
    if (overlay.no_camera) {
        const notice = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 12, .align_items = .center, .justify = .center }, .{ .surface = .card }, &.{
            try b.node(0, .{ .width = scene.w }, .{ .text = .{ .value = "No camera available", .size = 16, .tone = .muted, .alignment = .center } }, &.{}),
        });
        notice.overlay = .{ .point = .init(scene.x, scene.y) };
        try parts.append(b.allocator, notice);
    }
    // The selected camera's view, framed and named.
    if (overlay.preview) |inset| {
        const frame = try b.node(0, .{ .width = inset.w, .height = inset.h, .z_index = 12 }, .{ .custom = .{ .context = undefined, .draw = drawPreviewFrame } }, &.{});
        frame.overlay = .{ .point = .init(inset.x, inset.y) };
        frame.accessibility = .{ .role = .ignored };
        try parts.append(b.allocator, frame);
    }
    try parts.append(b.allocator, try toolbar.element(b, overlay.tools, scene));
    return parts.items;
}

/// The border round the selected camera's view, and its name.
fn drawPreviewFrame(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.roundRectStroke(r, c.theme.primary, 2, 2);
}

/// What the Scene panel works on: the game's library, the app whose world it shows, and the
/// entity selected (which clicking the panel changes).
pub const Target = struct {
    game: *const HotGame,
    app: *eggy.App,
    selected: *?eggy.ecs.EntityId,
};

pub const SceneView = struct {
    camera: SceneCamera = .{},
    tools: toolbar.State = .{},
    /// The gizmo handle under the pointer, and the one being dragged.
    hot: ?gizmo.Handle = null,
    drag: ?gizmo.Drag = null,
    hot_end: ?orientation.End = null,
    /// The toolbar's drag by its grip: where the pointer and the toolbar were when it began.
    toolbar_drag: ?struct { from: ui.Vec2, offset: ui.Vec2 } = null,
    /// The pointer's last place over the editor's windows.
    pointer: ui.Vec2 = .{ .x = 0, .y = 0 },
    /// This frame's view, the meshes drawn (for picking), the panel's rect, and the gizmo.
    view: eggy.camera.View = .default,
    drawn: []const eggy.mesh.Drawable = &.{},
    scene: ?ui.Rect = null,
    gizmo: ?gizmo.Layout = null,
    feedback_buffer: [32]u8 = undefined,
    /// Whether it looks through the game's camera this frame, and there is none.
    no_camera: bool = false,
    /// Whether it looks through the game's camera this frame (the panel's own, otherwise).
    looking_through_game: bool = false,
    /// The game camera the panel's controls move, while they do, and where they left it.
    steering: ?eggy.ecs.EntityId = null,
    steered_pose: [6]f32 = @splat(0),
    /// The selected camera's view, while one is selected and not looked through.
    preview: ?eggy.camera.View = null,

    /// How the panel looks at the scene: through its own camera (the game camera when the
    /// toolbar says), or through the game's while it plays.
    pub const Look = enum { editing, simulating, playing };

    /// What the dock draws over the panel.
    pub fn overlay(self: *SceneView) Overlay {
        const feedback = if (self.drag) |drag| drag.feedback(self.pointer, self.snapping(), &self.feedback_buffer) else "";
        const inset = if (self.preview != null) if (self.scene) |area| previewRect(area) else null else null;
        return .{ .tools = self.tools, .view = self.view, .gizmo = self.gizmo, .hot = self.hot, .drag = self.drag, .hot_end = self.hot_end, .pointer = self.pointer, .feedback = feedback, .no_camera = self.no_camera, .preview = inset };
    }

    /// Before each frame: what the panel at `scene` is seen from, as `look` says, the selected
    /// camera's view, and where the gizmo goes.
    pub fn update(self: *SceneView, target: ?Target, scene: ?ui.Rect, look: Look) void {
        self.view = self.camera.view();
        self.gizmo = null;
        self.scene = scene;
        self.no_camera = false;
        self.looking_through_game = false;
        self.preview = null;
        const working = target orelse {
            self.steering = null;
            return;
        };
        self.lookThroughGame(working, look);
        if (working.selected.*) |selected| if (self.steering == null or !self.steering.?.eql(selected)) {
            self.preview = game_camera.viewOf(working.game, working.app, selected);
        };
        const area = scene orelse return;
        self.tools.offset = toolbar.keepInside(self.tools, self.tools.offset, area);
        const entity = working.selected.* orelse return;
        const component = transformIndex(working.game) orelse return;
        if (!working.game.hasComponent(working.app, entity, component)) return;
        const placed = working.game.worldMatrix(working.app, entity) orelse return;
        self.gizmo = gizmo.layout(self.tools.tool, self.tools.space, placed, self.view, area);
    }

    /// Look through the game's camera when playing, or when the toolbar says so; while
    /// editing, the panel's controls move it then.
    fn lookThroughGame(self: *SceneView, target: Target, look: Look) void {
        const through_game = look == .playing or self.tools.through_game_camera;
        self.looking_through_game = through_game;
        const found = if (through_game) game_camera.find(target.game, target.app) else null;
        const camera = found orelse {
            self.no_camera = through_game;
            self.steering = null;
            return;
        };
        if (look != .editing) {
            self.steering = null;
            self.view = camera.view;
            return;
        }
        // The panel's camera moved: the game's follows it. Otherwise the panel's camera follows
        // the game's, which the Inspector or the gizmo may have moved.
        const steered = if (self.steering) |entity| entity.eql(camera.entity) and !std.meta.eql(self.steered_pose, self.camera.pose()) else false;
        if (steered) game_camera.steer(target.game, target.app, camera.entity, &self.camera) else self.camera.place(camera.view);
        self.steering = camera.entity;
        self.steered_pose = self.camera.pose();
        self.view = self.camera.view();
        self.view.fov_deg = camera.view.fov_deg;
        self.view.near = camera.view.near;
        self.view.far = camera.view.far;
    }

    /// Whether the panel looks through the game's camera this frame (or would, without one).
    pub fn throughGameCamera(self: *const SceneView) bool {
        return self.looking_through_game;
    }

    /// Whether the panel's controls are moving a camera now, which history waits out.
    pub fn steeringNow(self: *const SceneView) bool {
        return self.drag != null or self.camera.drag != null;
    }

    /// A toolbar button was pressed.
    pub fn press(self: *SceneView, button: toolbar.Button) void {
        switch (button) {
            .grip => self.toolbar_drag = .{ .from = self.pointer, .offset = self.tools.offset },
            .move => self.tools.tool = .move,
            .rotate => self.tools.tool = .rotate,
            .scale => self.tools.tool = .scale,
            .universal => self.tools.tool = .universal,
            .space => self.tools.space = if (self.tools.space == .world) .local else .world,
            .snap => self.tools.snapping = !self.tools.snapping,
            .game_camera => self.tools.through_game_camera = !self.tools.through_game_camera,
            .fold => self.tools.folded = !self.tools.folded,
        }
    }

    /// Before the workspace sees `event`: the camera's drags and wheel over the panel at
    /// `scene`, and W, E, R and T over it. Returns whether it was used.
    pub fn handleFirst(self: *SceneView, event: sdl3.events.Event, scene: ?ui.Rect) bool {
        if (self.camera.handle(event, scene)) return true;
        const key_down = switch (event) {
            .key_down => |key_down| key_down,
            else => return false,
        };
        if (!self.camera.hovered or self.camera.drag != null or key_down.repeat) return false;
        if (key_down.mod.controlDown() or key_down.mod.altDown()) return false;
        const key = key_down.key orelse return false;
        self.tools.tool = switch (key) {
            .w => .move,
            .e => .rotate,
            .r => .scale,
            .t => .universal,
            else => return false,
        };
        return true;
    }

    /// After the workspace let `event` through: a left press on the panel at `scene` takes a
    /// gizmo handle, looks from an orientation bubble's side, or selects what is under it
    /// (nothing: no selection); moves drag the handle or the toolbar. Returns whether it was used.
    pub fn handlePointer(self: *SceneView, event: sdl3.events.Event, scene: ?ui.Rect, target: Target) bool {
        switch (event) {
            .mouse_button_down => |down| {
                if (down.button != .left) return false;
                const area = scene orelse return false;
                const at = ui.Vec2{ .x = down.x, .y = down.y };
                if (!area.contains(at.x, at.y)) return false;
                if (orientation.hit(self.view, area, at)) |end| {
                    const turn = orientation.lookFrom(end);
                    self.camera.yaw_deg = turn.yaw_deg;
                    self.camera.pitch_deg = turn.pitch_deg;
                    return true;
                }
                if (self.gizmo) |layout| if (gizmo.hit(layout, at)) |handle| {
                    self.drag = startDrag(target, layout, handle, at);
                    return true;
                };
                target.selected.* = instanceRoot(target, picking.pick(self.drawn, &target.app.graphics.models, self.view, area, at));
                return true;
            },
            .mouse_motion => |motion| {
                const at = ui.Vec2{ .x = motion.x, .y = motion.y };
                self.pointer = at;
                if (self.toolbar_drag) |moving| {
                    self.tools.offset = .{ .x = moving.offset.x + at.x - moving.from.x, .y = moving.offset.y + at.y - moving.from.y };
                    if (self.scene) |area| self.tools.offset = toolbar.keepInside(self.tools, self.tools.offset, area);
                    return true;
                }
                const drag = self.drag orelse {
                    self.hot = if (self.gizmo) |layout| gizmo.hit(layout, at) else null;
                    self.hot_end = if (scene) |area| orientation.hit(self.view, area, at) else null;
                    return false;
                };
                const entity = target.selected.* orelse return true;
                const component = transformIndex(target.game) orelse return true;
                const change = drag.changeAt(at, self.snapping());
                var text: [160]u8 = undefined;
                const zon = std.fmt.bufPrintZ(&text, ".{{ {d}, {d}, {d} }}", .{ change.value[0], change.value[1], change.value[2] }) catch return true;
                _ = target.game.writeField(target.app, entity, component, @intFromEnum(change.field), zon);
                return true;
            },
            .mouse_button_up => |up| {
                if (up.button != .left or (self.drag == null and self.toolbar_drag == null)) return false;
                self.drag = null;
                self.toolbar_drag = null;
                return true;
            },
            else => return false,
        }
    }

    /// The entity whose mesh is under `at` on the panel at `scene`, as last drawn; null over
    /// nothing.
    pub fn entityAt(self: *const SceneView, models: *const eggy.model_cache.ModelCache, scene: ui.Rect, at: ui.Vec2) ?eggy.ecs.EntityId {
        return picking.pick(self.drawn, models, self.view, scene, at);
    }

    /// Where something let go at `at` on the panel at `scene` goes: on the ground (y = 0) under
    /// the pointer, or a few metres out when the ground there is behind the camera or far off.
    pub fn dropPoint(self: *const SceneView, scene: ui.Rect, at: ui.Vec2) [3]f32 {
        const along = eggy.camera.normalize(picking.rayThrough(self.view, scene, at));
        const eye = self.view.eye;
        const to_ground = if (along[1] < -1e-3) -eye[1] / along[1] else std.math.inf(f32);
        const distance: f32 = if (to_ground > 0 and to_ground < 100) to_ground else 5;
        return .{ eye[0] + along[0] * distance, eye[1] + along[1] * distance, eye[2] + along[2] * distance };
    }

    /// Whether a drag snaps now: the toolbar's setting, turned round while Ctrl is held.
    fn snapping(self: *const SceneView) bool {
        return self.tools.snapping != sdl3.keyboard.getModState().controlDown();
    }
};

/// Where the selected camera's view goes in the panel at `scene`: its bottom right corner, a
/// quarter of its width, as wide for its height as the panel.
pub fn previewRect(scene: ui.Rect) ui.Rect {
    const margin: f32 = 12;
    const w = @max(120, scene.w * 0.25);
    const h = w * scene.h / @max(1, scene.w);
    return .{ .x = scene.x + scene.w - w - margin, .y = scene.y + scene.h - h - margin, .w = w, .h = h };
}

/// A drag of `handle`, from the selected entity's `Transform` as it is now.
fn startDrag(target: Target, layout: gizmo.Layout, handle: gizmo.Handle, at: ui.Vec2) ?gizmo.Drag {
    const entity = target.selected.* orelse return null;
    const component = transformIndex(target.game) orelse return null;
    var fields: [3][3]f32 = undefined;
    for (&fields, 0..) |*field, index| {
        var buffer: [160]u8 = undefined;
        const text = target.game.readField(target.app, entity, component, index, &buffer) orelse return null;
        field.* = parseVector(text) orelse {
            std.log.err("the gizmo can't read the Transform's field {d}: {s}", .{ index, text });
            return null;
        };
    }
    // Moves and turns about world axes are made in the parent's space: the world's at the top.
    var to_local = [4][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    if (target.app.world.getParent(entity)) |parent| if (target.game.worldMatrix(target.app, parent)) |placed| {
        to_local = eggy.transform.invert(placed) orelse return null;
    };
    return gizmo.Drag.init(handle, at, layout, .{ .position = fields[0], .rotation_deg = fields[1], .scale = fields[2] }, to_local);
}

/// Three numbers, `.{ x, y, z }` in ZON; null when `text` isn't that.
fn parseVector(text: []const u8) ?[3]f32 {
    var source: [160]u8 = undefined;
    const terminated = std.fmt.bufPrintZ(&source, "{s}", .{text}) catch return null;
    // ZON's parser needs room for its syntax tree, as the Inspector's does.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    return std.zon.parse.fromSlice([3]f32, fba.allocator(), terminated, null, .{}) catch null;
}

/// Eggy's `Transform` among the game's component types.
fn transformIndex(game: *const HotGame) ?usize {
    return game.builtinComponent("Transform");
}

/// What a click on `entity` selects: the outermost scene instance it was made under, as its
/// entities come from the instance's file and edits to them aren't kept; else itself.
fn instanceRoot(target: Target, entity: ?eggy.ecs.EntityId) ?eggy.ecs.EntityId {
    var picked = entity orelse return null;
    const component = target.game.builtinComponent("SceneInstance") orelse return picked;
    var above = target.app.world.getParent(picked);
    while (above) |up| : (above = target.app.world.getParent(up)) {
        if (target.game.hasComponent(target.app, up, component)) picked = up;
    }
    return picked;
}

test {
    _ = game_camera;
    _ = gizmo;
    _ = picking;
    _ = toolbar;
    _ = orientation;
    _ = @import("rotation.zig");
    _ = @import("scene_camera.zig");
}

test "the toolbar picks the gizmo and its axes, and folds away" {
    var view = SceneView{};
    view.press(.rotate);
    try std.testing.expectEqual(gizmo.Tool.rotate, view.tools.tool);
    view.press(.space);
    try std.testing.expectEqual(gizmo.Space.local, view.tools.space);
    view.press(.game_camera);
    view.press(.game_camera);
    try std.testing.expect(!view.tools.through_game_camera);
    view.press(.fold);
    try std.testing.expect(view.tools.folded);
}

test "a Transform field's ZON, as the game's library writes it, reads back for a drag" {
    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try std.zon.stringify.serialize([3]f32{ 0, 0.75, -2 }, .{ .whitespace = false }, &written.writer);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.75, -2 }, &parseVector(written.written()).?);
    try std.testing.expect(parseVector("sideways") == null);
}
