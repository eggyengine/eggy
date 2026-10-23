//! The Scene panel: what it is seen from (its own camera, `scene_camera.zig`, or the game's), the
//! toolbar floating over it (`toolbar.zig`), the view's orientation in its corner
//! (`orientation.zig`), clicking an entity to select it (`picking.zig`), and the gizmo that moves,
//! turns and resizes the selected one (`gizmo.zig`), which edits its `Transform` through the
//! game's library. It can look through the game's camera instead (`game_camera.zig`), and while
//! editing, its controls then move that camera; with none to look through it says so. A camera
//! selected shows what it sees in a corner. Lights and cameras are drawn as stand-ins
//! (`stand_ins.zig`). W, E, R and T pick Move, Rotate, Scale and Universal while the pointer is over
//! the panel; Ctrl turns snapping round while dragging.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const sdl3 = eggy.sdl_adapter.sdl;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const gizmo = @import("gizmo.zig");
pub const picking = @import("picking.zig");
const orientation = @import("orientation.zig");
const game_camera = @import("game_camera.zig");
const light_direction = @import("light_direction.zig");
pub const stand_ins = @import("stand_ins.zig");
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
    /// Which way the selected directional or spot light shines.
    light_arrow: ?light_direction.Arrow = null,
    /// The directional lights' badges; borrowed from the `SceneView` until its next `update`.
    suns: []const stand_ins.Sun = &.{},
    pointer: ui.Vec2 = .{ .x = 0, .y = 0 },
    /// The drag's feedback beside the pointer.
    feedback: []const u8 = "",
    /// Whether it looks through the game's camera, and there is none.
    no_camera: bool = false,
    /// Where the selected camera's view is shown, in the panel's points.
    preview: ?ui.Rect = null,
    /// The game owns the panel: no editor controls, just a frame saying it is playing.
    playing: bool = false,

    pub const none: Overlay = .{};
};

/// The Scene panel's floating parts for its node at `scene`: the orientation, the gizmo, then
/// the toolbar; while playing, only the play frame (and the missing-camera notice).
/// Editor-only: `scene` uses UI points; allocates elements and paint state in `b.allocator`
/// for this frame. Attach the returned slice to the dock node and retain its arena through
/// rendering. Builder/allocation errors propagate; this creates UI, not the offscreen scene.
///
/// ```zig
/// // Given a UI builder, current SceneView overlay and Scene rect:
/// const floating = try overlayElements(builder, overlay, scene);
/// ```
pub fn overlayElements(b: L.Builder, overlay: Overlay, scene: ui.Rect) ![]*L.Element {
    var parts: std.ArrayList(*L.Element) = .empty;
    if (overlay.playing) {
        const frame = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 10 }, .{ .custom = .{ .context = undefined, .draw = drawPlayFrame } }, &.{});
        frame.overlay = .{ .point = .init(scene.x, scene.y) };
        frame.accessibility = .{ .role = .ignored };
        try parts.append(b.allocator, frame);
        if (overlay.no_camera) try parts.append(b.allocator, try noCameraNotice(b, scene));
        return parts.items;
    }
    const drawn = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 10 }, orientation.paint(b.allocator, overlay.view, scene, overlay.hot_end), &.{});
    drawn.overlay = .{ .point = .init(scene.x, scene.y) };
    drawn.accessibility.role = .ignored;
    try parts.append(b.allocator, drawn);
    if (overlay.suns.len > 0) {
        const badges = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 10 }, stand_ins.paint(b.allocator, overlay.suns), &.{});
        badges.overlay = .{ .point = .init(scene.x, scene.y) };
        badges.accessibility.role = .ignored;
        try parts.append(b.allocator, badges);
    }
    if (overlay.light_arrow) |arrow| {
        const shine = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 11 }, light_direction.paint(b.allocator, arrow), &.{});
        shine.overlay = .{ .point = .init(scene.x, scene.y) };
        shine.accessibility.role = .ignored;
        try parts.append(b.allocator, shine);
    }
    if (overlay.gizmo) |layout| {
        const handles = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 11 }, gizmo.paint(b.allocator, layout, overlay.hot, overlay.drag, overlay.pointer, overlay.feedback), &.{});
        handles.overlay = .{ .point = .init(scene.x, scene.y) };
        handles.accessibility.role = .ignored;
        try parts.append(b.allocator, handles);
    }
    if (overlay.no_camera) try parts.append(b.allocator, try noCameraNotice(b, scene));
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

/// Nothing to see through: say so, in the middle of the panel at `scene`.
fn noCameraNotice(b: L.Builder, scene: ui.Rect) !*L.Element {
    const notice = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 12, .align_items = .center, .justify = .center }, .{ .surface = .card }, &.{
        try b.node(0, .{ .width = scene.w }, .{ .text = .{ .value = "No camera available", .size = 16, .tone = .muted, .alignment = .center } }, &.{}),
    });
    notice.overlay = .{ .point = .init(scene.x, scene.y) };
    return notice;
}

/// The accent border round the panel while the game plays, so play is never mistaken for editing.
fn drawPlayFrame(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.roundRectStroke(r, c.theme.accent, 0, 2);
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
    selection_hidden: bool = false,
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
    light_arrow: ?light_direction.Arrow = null,
    /// The directional lights' badges this frame, seen through the panel's own camera.
    suns: [eggy.lighting.max_lights]stand_ins.Sun = undefined,
    sun_count: usize = 0,
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
    /// Whether the game owns the panel this frame (`Look.playing`), hiding the editor's controls.
    playing: bool = false,

    /// How the panel looks at the scene: through its own camera (the game camera when the
    /// toolbar says), or through the game's while it plays.
    pub const Look = enum { editing, simulating, playing };

    /// What the dock draws over the panel.
    /// Editor-only: call after `update`; returned geometry is copied, but feedback borrows
    /// this SceneView's buffer until the next `overlay` call/mutation. Build paint before reuse.
    ///
    /// ```zig
    /// const drawn_overlay = scene_view.overlay(); // Existing updated SceneView.
    /// ```
    pub fn overlay(self: *SceneView) Overlay {
        const feedback = if (self.drag) |drag| drag.feedback(self.pointer, self.snapping(), &self.feedback_buffer) else "";
        const inset = if (self.preview != null) if (self.scene) |area| previewRect(area) else null else null;
        return .{ .tools = self.tools, .view = self.view, .gizmo = self.gizmo, .hot = self.hot, .drag = self.drag, .hot_end = self.hot_end, .light_arrow = self.light_arrow, .suns = self.suns[0..self.sun_count], .pointer = self.pointer, .feedback = feedback, .no_camera = self.no_camera, .preview = inset, .playing = self.playing };
    }

    /// Before each frame: what the panel at `scene` is seen from, as `look` says, the selected
    /// camera's view, and where the gizmo goes.
    /// Editor-only: `target` borrows the current App/library/selection and `scene` is its
    /// window's UI rect (null when hidden). May write the game camera Transform while editing
    /// through it; playing hides editing controls. Recompute before rendering/overlay hit tests;
    /// missing target/components/camera degrade to absent controls rather than errors.
    ///
    /// ```zig
    /// // Given SceneView, current host target and optional Scene UI rect:
    /// scene_view.update(target, scene_rect, .editing);
    /// ```
    pub fn update(self: *SceneView, target: ?Target, scene: ?ui.Rect, look: Look) void {
        // The panel's own camera is perspective; only a game camera's lens (below) changes that.
        self.camera.projection = .perspective;
        self.view = self.camera.view();
        self.gizmo = null;
        self.light_arrow = null;
        self.sun_count = 0;
        self.scene = scene;
        self.no_camera = false;
        self.looking_through_game = false;
        self.preview = null;
        self.playing = look == .playing;
        const working = target orelse {
            self.steering = null;
            return;
        };
        self.lookThroughGame(working, look);
        if (self.playing) return;
        // Directional lights' badges, from the lights the panel last drew; the game's camera sees only the game.
        if (scene) |area| if (!self.looking_through_game) {
            self.sun_count = stand_ins.suns(&working.app.graphics.lights, self.view, area, &self.suns);
        };
        if (working.selection_hidden) {
            self.drag = null;
            self.hot = null;
            return;
        }
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
        if (self.gizmo) |handles| if (shinesAlong(working, entity)) {
            self.light_arrow = light_direction.arrow(handles, placed);
        };
    }

    /// Whether `entity` is a directional or spot light, which shine along their local -Z.
    fn shinesAlong(target: Target, entity: eggy.ecs.EntityId) bool {
        const component = target.game.builtinComponent("SceneLight") orelse return false;
        if (!target.game.hasComponent(target.app, entity, component)) return false;
        var buffer: [64]u8 = undefined;
        // `kind` is the light's first field.
        const kind = target.game.readField(target.app, entity, component, 0, &buffer) orelse return false;
        return light_direction.shinesAlongDirection(kind);
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
        self.view.projection = camera.view.projection;
        self.view.orthographic_height_m = camera.view.orthographic_height_m;
        // Panning keeps the focus under the pointer, whichever lens it is.
        self.camera.fov_deg = camera.view.fov_deg;
        self.camera.projection = camera.view.projection;
        self.camera.orthographic_height_m = camera.view.orthographic_height_m;
    }

    /// Whether the panel looks through the game's camera this frame (or would, without one).
    /// Editor-only: reports the last `update`, not simply the toolbar toggle; playing also
    /// selects the game's camera. Owns no camera reference.
    ///
    /// ```zig
    /// const through_game = scene_view.throughGameCamera(); // Updated SceneView.
    /// ```
    pub fn throughGameCamera(self: *const SceneView) bool {
        return self.looking_through_game;
    }

    /// Whether the panel's controls are moving a camera now, which history waits out.
    /// Editor-only: true for gizmo dragging or camera drag/pinch, not toolbar dragging.
    /// Use it to defer/coalesce history snapshots, not as a Play-mode indicator.
    ///
    /// ```zig
    /// const hold_history_snapshot = scene_view.steeringNow(); // Existing SceneView.
    /// ```
    pub fn steeringNow(self: *const SceneView) bool {
        return self.drag != null or self.camera.drag != null or self.camera.pinch != null;
    }

    /// A toolbar button was pressed.
    /// Editor-only: changes tool/space/snap/camera/fold state or starts moving the toolbar
    /// from the last pointer position. Does not immediately change the world or rebuild UI.
    ///
    /// ```zig
    /// scene_view.press(.rotate); // Existing SceneView after toolbar activation.
    /// ```
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

    /// Before the workspace sees `event`: the camera's drags, scroll and pinch over the panel at
    /// `scene`, and W, E, R and T over it. Returns whether it was used.
    /// Desktop editor only: raw SDL event positions and the optional Scene rect use the event
    /// window's points. Route only in an editor-navigation context, before ordinary workspace
    /// handling; active camera navigation takes precedence over tool shortcut keys.
    ///
    /// ```zig
    /// const used = scene_view.handleFirst(event, scene_rect); // Raw SDL event and optional rect.
    /// ```
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
    /// Desktop editor only: call for editing input not consumed by workspace, with current
    /// `update` geometry and borrowed drawables valid for picking. May change selection or
    /// write Transform fields through `target.game`; outer scene instances are selected instead
    /// of their generated children. Host owns undo snapshots; rejected field writes are ignored.
    ///
    /// ```zig
    /// const used = scene_view.handlePointer(event, scene_rect, target);
    /// // Unconsumed raw SDL event, optional UI rect and live host Target.
    /// ```
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
                if (stand_ins.sunAt(self.suns[0..self.sun_count], at)) |light| {
                    target.selected.* = instanceRoot(target, light);
                    return true;
                }
                target.selected.* = instanceRoot(target, picking.pick(self.drawn, &target.app.graphics.models, &target.app.ui_scenes, target.app.resources(), self.view, area, at));
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
                const zon = std.fmt.bufPrintSentinel(&text, ".{{ {d}, {d}, {d} }}", .{ change.value[0], change.value[1], change.value[2] }, 0) catch return true;
                _ = target.game.writeField(target.app, entity, component, @backingInt(change.field), zon);
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

    /// The entity whose mesh or billboard is under `at` on the panel at `scene`, as last drawn; null over
    /// nothing.
    /// Editor-only: positive scene dimensions and matching UI coordinates are required;
    /// `drawn` must still refer to valid current-frame drawables. Returns the mesh id directly,
    /// without remapping instance roots or mutating selection; cache bounds are borrowed.
    ///
    /// ```zig
    /// const entity = scene_view.entityAt(app, scene, pointer);
    /// // Updated SceneView and live App.
    /// ```
    pub fn entityAt(self: *const SceneView, app: *eggy.App, scene: ui.Rect, at: ui.Vec2) ?eggy.ecs.EntityId {
        return picking.pick(self.drawn, &app.graphics.models, &app.ui_scenes, app.resources(), self.view, scene, at);
    }

    /// Where something let go at `at` on the panel at `scene` goes: on the ground (y = 0) under
    /// the pointer, or a few metres out when the ground there is behind the camera or far off.
    /// Editor-only: requires a positive-sized Scene rect and UI-space drop point.
    /// Returns world metres: ground intersection only when forward and within 100 m, otherwise
    /// a point 5 m along the normalized ray. Does not create or parent an entity.
    ///
    /// ```zig
    /// const world_position = scene_view.dropPoint(scene, pointer); // Updated view and UI rect/point.
    /// ```
    pub fn dropPoint(self: *const SceneView, scene: ui.Rect, at: ui.Vec2) [3]f32 {
        const ray = picking.rayThrough(self.view, scene, at);
        const along = ray.direction;
        const eye = ray.origin;
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
/// Editor-only: input/output use UI points; width has a 120-point minimum and a 12-point
/// margin, so a very small panel can place the preview outside its bounds. Pure calculation.
///
/// ```zig
/// const inset = previewRect(.{ .x = 0, .y = 0, .w = 800, .h = 600 });
/// ```
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
pub fn parseVector(text: []const u8) ?[3]f32 {
    var source: [160]u8 = undefined;
    const terminated = std.fmt.bufPrintSentinel(&source, "{s}", .{text}, 0) catch return null;
    // ZON's parser needs room for its syntax tree, as the Inspector's does.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    return zon_file.parse([3]f32, fba.allocator(), terminated, .{}) catch null;
}

/// Eggy's `Transform` among the game's component types.
fn transformIndex(game: *const HotGame) ?usize {
    return game.builtinComponent("Transform");
}

/// What a click on `entity` selects: the outermost scene instance it was made under, as its
/// entities come from the instance's file and edits to them aren't kept; else itself.
pub fn instanceRoot(target: Target, entity: ?eggy.ecs.EntityId) ?eggy.ecs.EntityId {
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
    _ = light_direction;
    _ = stand_ins;
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
