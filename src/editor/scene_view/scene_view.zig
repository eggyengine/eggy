//! The Scene panel: what it is seen from (its own camera, `scene_camera.zig`, or the game's), the
//! buttons floating over it (`toolbar.zig`), clicking an entity to select it (`picking.zig`), and
//! the gizmo that moves, turns and resizes the selected one (`gizmo.zig`), which edits its
//! `Transform` through the game's library. W, E and R pick Move, Rotate and Scale while the
//! pointer is over the panel.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const sdl3 = eggy.sdl_adapter.sdl;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const gizmo = @import("gizmo.zig");
const picking = @import("picking.zig");
pub const toolbar = @import("toolbar.zig");
pub const SceneCamera = @import("scene_camera.zig").SceneCamera;

/// What the dock draws over the Scene panel this frame.
pub const Overlay = struct {
    tools: toolbar.State = .{},
    gizmo: ?gizmo.Layout = null,
    hot: ?gizmo.Handle = null,
    active: ?gizmo.Handle = null,

    pub const none: Overlay = .{};
};

/// The Scene panel's floating parts for its node at `scene`: the gizmo, then the buttons.
pub fn overlayElements(b: L.Builder, overlay: Overlay, scene: ui.Rect) ![]*L.Element {
    var parts: std.ArrayList(*L.Element) = .empty;
    if (overlay.gizmo) |layout| {
        const drawn = try b.node(0, .{ .width = scene.w, .height = scene.h, .z_index = 10 }, gizmo.paint(b.allocator, layout, overlay.hot, overlay.active), &.{});
        drawn.overlay = .{ .point = .init(scene.x, scene.y) };
        drawn.accessibility.role = .ignored;
        try parts.append(b.allocator, drawn);
    }
    try parts.append(b.allocator, try toolbar.element(b, overlay.tools, scene));
    return parts.items;
}

/// What the Scene panel works on: the game's library, the app whose world it shows, and the
/// entity selected (which clicking the panel changes).
pub const Target = struct {
    game: *const HotGame,
    app: *eggy.App,
    selected: *?eggy.ecs.EntityId,
};

/// `Transform`'s fields, in order.
const Field = enum(usize) { position, rotation_deg, scale };

pub const SceneView = struct {
    camera: SceneCamera = .{},
    tools: toolbar.State = .{},
    /// The gizmo handle under the pointer, and the one being dragged.
    hot: ?gizmo.Handle = null,
    drag: ?gizmo.Drag = null,
    /// This frame's view, the meshes drawn (for picking), and the gizmo.
    view: eggy.camera.View = .default,
    drawn: []const eggy.mesh.Drawable = &.{},
    gizmo: ?gizmo.Layout = null,

    /// What the dock draws over the panel.
    pub fn overlay(self: *const SceneView) Overlay {
        return .{ .tools = self.tools, .gizmo = self.gizmo, .hot = self.hot, .active = if (self.drag) |drag| drag.handle else null };
    }

    /// Before each frame: what the panel at `scene` is seen from, and where the gizmo goes.
    pub fn update(self: *SceneView, target: ?Target, scene: ?ui.Rect) void {
        self.view = self.camera.view();
        self.gizmo = null;
        const working = target orelse return;
        if (self.tools.through_game_camera) if (working.game.findCamera(working.app)) |view| {
            self.view = view;
        };
        const area = scene orelse return;
        const entity = working.selected.* orelse return;
        const component = transformIndex(working.game) orelse return;
        if (!working.game.hasComponent(working.app, entity, component)) return;
        const placed = working.game.worldMatrix(working.app, entity) orelse return;
        self.gizmo = gizmo.layout(self.tools.tool, .{ placed[3][0], placed[3][1], placed[3][2] }, self.view, area);
    }

    /// A button over the panel was pressed.
    pub fn press(self: *SceneView, button: toolbar.Button) void {
        switch (button) {
            .move => self.tools.tool = .move,
            .rotate => self.tools.tool = .rotate,
            .scale => self.tools.tool = .scale,
            .game_camera => self.tools.through_game_camera = !self.tools.through_game_camera,
        }
    }

    /// Before the workspace sees `event`: the camera's drags and wheel over the panel at
    /// `scene`, and W, E and R over it. Returns whether it was used.
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
            else => return false,
        };
        return true;
    }

    /// After the workspace let `event` through: a left press on the panel at `scene` takes a
    /// gizmo handle or selects what is under it (nothing: no selection); moves drag the handle.
    /// Returns whether it was used.
    pub fn handlePointer(self: *SceneView, event: sdl3.events.Event, scene: ?ui.Rect, target: Target) bool {
        switch (event) {
            .mouse_button_down => |down| {
                if (down.button != .left) return false;
                const area = scene orelse return false;
                const at = ui.Vec2{ .x = down.x, .y = down.y };
                if (!area.contains(at.x, at.y)) return false;
                if (self.gizmo) |layout| if (gizmo.hit(layout, at)) |handle| {
                    self.drag = self.startDrag(target, layout, handle, at);
                    return true;
                };
                target.selected.* = picking.pick(self.drawn, self.view, area, at);
                return true;
            },
            .mouse_motion => |motion| {
                const at = ui.Vec2{ .x = motion.x, .y = motion.y };
                const drag = self.drag orelse {
                    self.hot = if (self.gizmo) |layout| gizmo.hit(layout, at) else null;
                    return false;
                };
                const entity = target.selected.* orelse return true;
                const component = transformIndex(target.game) orelse return true;
                const value = drag.valueAt(at);
                var text: [160]u8 = undefined;
                const zon = std.fmt.bufPrintZ(&text, ".{{ {d}, {d}, {d} }}", .{ value[0], value[1], value[2] }) catch return true;
                _ = target.game.writeField(target.app, entity, component, @intFromEnum(fieldFor(drag.tool)), zon);
                return true;
            },
            .mouse_button_up => |up| {
                if (up.button != .left or self.drag == null) return false;
                self.drag = null;
                return true;
            },
            else => return false,
        }
    }

    /// A drag of `handle`, from the selected entity's field as it is now.
    fn startDrag(self: *const SceneView, target: Target, layout: gizmo.Layout, handle: gizmo.Handle, at: ui.Vec2) ?gizmo.Drag {
        const entity = target.selected.* orelse return null;
        const component = transformIndex(target.game) orelse return null;
        const tool = self.tools.tool;
        var buffer: [160]u8 = undefined;
        const text = target.game.readField(target.app, entity, component, @intFromEnum(fieldFor(tool)), &buffer) orelse return null;
        const start = parseVector(text) orelse {
            std.log.err("the gizmo can't read the Transform's {t}: {s}", .{ fieldFor(tool), text });
            return null;
        };
        // A move is made in the parent's space: the world's at the top level.
        var to_local = [4][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
        if (target.app.world.getParent(entity)) |parent| if (target.game.worldMatrix(target.app, parent)) |placed| {
            to_local = eggy.transform.invert(placed) orelse return null;
        };
        return .{ .tool = tool, .handle = handle, .from = at, .start = start, .gizmo = layout, .to_local = to_local };
    }
};

/// Three numbers, `.{ x, y, z }` in ZON; null when `text` isn't that.
fn parseVector(text: []const u8) ?[3]f32 {
    var source: [160]u8 = undefined;
    const terminated = std.fmt.bufPrintZ(&source, "{s}", .{text}) catch return null;
    // ZON's parser needs room for its syntax tree, as the Inspector's does.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    return std.zon.parse.fromSlice([3]f32, fba.allocator(), terminated, null, .{}) catch null;
}

fn fieldFor(tool: gizmo.Tool) Field {
    return switch (tool) {
        .move => .position,
        .rotate => .rotation_deg,
        .scale => .scale,
    };
}

/// Eggy's `Transform` among the game's component types.
fn transformIndex(game: *const HotGame) ?usize {
    for (game.component_types, 0..) |info, index| {
        if (std.mem.eql(u8, info.name, "Transform") and std.mem.eql(u8, info.owner, "eggy")) return index;
    }
    return null;
}

test {
    _ = gizmo;
    _ = picking;
    _ = toolbar;
    _ = @import("scene_camera.zig");
}

test "the buttons pick the gizmo, and the game camera button turns it on and off" {
    var view = SceneView{};
    view.press(.rotate);
    try std.testing.expectEqual(gizmo.Tool.rotate, view.tools.tool);
    view.press(.game_camera);
    view.press(.game_camera);
    try std.testing.expect(!view.tools.through_game_camera);
}

test "a Transform field's ZON, as the game's library writes it, reads back for a drag" {
    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try std.zon.stringify.serialize([3]f32{ 0, 0.75, -2 }, .{ .whitespace = false }, &written.writer);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.75, -2 }, &parseVector(written.written()).?);
    try std.testing.expect(parseVector("sideways") == null);
}
