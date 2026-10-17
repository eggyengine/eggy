//! The Scene panel's floating toolbar: icon buttons for the gizmo (Move, Rotate, Scale,
//! Universal), whether it works in the world's axes or the entity's own, snapping, and looking
//! through the game's camera, plus mouse/touchpad navigation. Drag its grip to move it inside
//! the panel; its last button folds it down to the grip.
const std = @import("std");
const ui = @import("eggy").ui;
const L = ui.Layout;
const gizmo = @import("gizmo.zig");
const Navigation = @import("scene_camera.zig").Navigation;

pub const Button = enum(u32) { grip, move, rotate, scale, universal, space, snap, game_camera, touchpad, fold };

/// What the toolbar shows and where.
pub const State = struct {
    tool: gizmo.Tool = .move,
    space: gizmo.Space = .world,
    snapping: bool = false,
    through_game_camera: bool = false,
    navigation: Navigation = .mouse,
    /// Folded down to its grip and the button that unfolds it.
    folded: bool = false,
    /// Where its top left corner is, from the Scene panel's.
    offset: ui.Vec2 = .{ .x = 8, .y = 8 },
};

/// Button `b`'s element id: `first_id` plus the button, below the dock's ids.
const first_id: u32 = 0x5100_0000;
const button_pt: f32 = 26;
const gap_pt: f32 = 2;
const padding_pt: f32 = 3;

/// The button element `id` is, if it is one of these.
pub fn buttonOf(id: u32) ?Button {
    if (id < first_id) return null;
    return std.enums.fromInt(Button, id - first_id);
}

/// What a button does, for its tooltip.
pub fn describe(button: Button, state: State) []const u8 {
    return switch (button) {
        .grip => "Drag to move the toolbar",
        .move => "Move (W)",
        .rotate => "Rotate (E)",
        .scale => "Scale (R)",
        .universal => "Move and rotate (T)",
        .space => if (state.space == .world) "World axes (click for the entity's own)" else "The entity's own axes (click for the world's)",
        .snap => if (state.snapping) "Snapping on (Ctrl turns it off while dragging)" else "Snapping off (Ctrl snaps while dragging)",
        .game_camera => if (state.through_game_camera) "Looking through the game's camera" else "Look through the game's camera",
        .touchpad => if (state.navigation == .touchpad) "Touchpad: scroll orbits, Shift+scroll pans, Ctrl+scroll or pinch zooms (click for mouse)" else "Mouse navigation (click for touchpad gestures)",
        .fold => if (state.folded) "Show the toolbar" else "Hide the toolbar",
    };
}

/// The buttons shown: all of them, or folded, just the grip and the one that unfolds.
fn shown(state: State) []const Button {
    if (state.folded) return &.{ .grip, .fold };
    return std.enums.values(Button);
}

/// The toolbar's size, for keeping it inside the panel.
pub fn size(state: State) ui.Vec2 {
    const count: f32 = @floatFromInt(shown(state).len);
    return .{ .x = count * button_pt + (count - 1) * gap_pt + 2 * padding_pt, .y = button_pt + 2 * padding_pt };
}

/// `offset` moved, if need be, so the toolbar stays inside a panel `scene` big.
pub fn keepInside(state: State, offset: ui.Vec2, scene: ui.Rect) ui.Vec2 {
    const extent = size(state);
    return .{
        .x = std.math.clamp(offset.x, 0, @max(0, scene.w - extent.x)),
        .y = std.math.clamp(offset.y, 0, @max(0, scene.h - extent.y)),
    };
}

/// The toolbar over the Scene panel at `scene`, floating above it.
pub fn element(b: L.Builder, state: State, scene: ui.Rect) !*L.Element {
    var buttons: std.ArrayList(*L.Element) = .empty;
    for (shown(state)) |button| {
        const look = try b.allocator.create(Look);
        look.* = .{ .button = button, .pressed = pressed(button, state), .folded = state.folded, .id = first_id + @intFromEnum(button) };
        const node = try b.node(look.id, .{ .width = button_pt, .height = button_pt }, .{ .custom = .{ .context = look, .draw = Look.draw } }, &.{});
        node.cursor = if (button == .grip) .move else .pointer;
        node.accessibility = .{ .role = .button, .label = describe(button, state) };
        try buttons.append(b.allocator, node);
    }
    const extent = size(state);
    const row = try b.node(0, .{ .width = extent.x, .height = extent.y, .direction = .row, .gap = gap_pt, .padding = .{ .left = padding_pt, .right = padding_pt, .top = padding_pt, .bottom = padding_pt }, .z_index = 20 }, .{ .surface = .popover }, buttons.items);
    const at = keepInside(state, state.offset, scene);
    row.overlay = .{ .point = .init(scene.x + at.x, scene.y + at.y) };
    return row;
}

fn pressed(button: Button, state: State) bool {
    return switch (button) {
        .move => state.tool == .move,
        .rotate => state.tool == .rotate,
        .scale => state.tool == .scale,
        .universal => state.tool == .universal,
        .space => state.space == .local,
        .snap => state.snapping,
        .game_camera => state.through_game_camera,
        .touchpad => state.navigation == .touchpad,
        .grip, .fold => false,
    };
}

/// A button: its box, lit when pressed or under the pointer, and its icon.
const Look = struct {
    button: Button,
    pressed: bool,
    folded: bool,
    id: u32,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Look = @ptrCast(@alignCast(context));
        const t = c.theme;
        if (self.pressed) {
            try c.roundRect(r, t.accent, t.radiusSm());
        } else if (c.hot_id == self.id and self.button != .grip) try c.roundRectAlpha(r, t.accent, t.radiusSm(), 0.5);
        const ink = (if (self.pressed) t.accent_foreground else t.foreground) ++ [_]f32{1};
        const m = r.center();
        switch (self.button) {
            .grip => for (0..3) |row| for (0..2) |col| {
                try dotAt(c, .{ .x = m.x - 2.5 + 5 * @as(f32, @floatFromInt(col)), .y = m.y - 5 + 5 * @as(f32, @floatFromInt(row)) }, 1.3, t.muted_foreground);
            },
            .move => {
                // Four arrows out from the middle.
                try line(c, .{ .x = m.x - 7, .y = m.y }, .{ .x = m.x + 7, .y = m.y }, 1.5, ink);
                try line(c, .{ .x = m.x, .y = m.y - 7 }, .{ .x = m.x, .y = m.y + 7 }, 1.5, ink);
                for ([_][2]f32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| try head(c, m, d, 8, ink);
            },
            .rotate => try arc(c, m, 6.5, -2.4, 2.0, ink, true),
            .scale => {
                try outlineRect(c, .{ .x = m.x - 7, .y = m.y - 1, .w = 8, .h = 8 }, 1.3, ink);
                try line(c, .{ .x = m.x - 1, .y = m.y + 1 }, .{ .x = m.x + 6, .y = m.y - 6 }, 1.5, ink);
                try head(c, m, .{ 0.707, -0.707 }, 8, ink);
            },
            .universal => {
                try arc(c, m, 7, 0, std.math.tau, ink, false);
                try line(c, .{ .x = m.x - 4, .y = m.y }, .{ .x = m.x + 4, .y = m.y }, 1.5, ink);
                try line(c, .{ .x = m.x, .y = m.y - 4 }, .{ .x = m.x, .y = m.y + 4 }, 1.5, ink);
            },
            .space => if (self.pressed) {
                // The entity's own axes: a cube.
                try outlineRect(c, .{ .x = m.x - 6, .y = m.y - 3, .w = 9, .h = 9 }, 1.3, ink);
                try outlineRect(c, .{ .x = m.x - 3, .y = m.y - 6, .w = 9, .h = 9 }, 1.3, ink);
            } else {
                // The world's: a globe.
                try arc(c, m, 7, 0, std.math.tau, ink, false);
                try line(c, .{ .x = m.x - 7, .y = m.y }, .{ .x = m.x + 7, .y = m.y }, 1.2, ink);
                try outlineEllipse(c, m, 3, 7, ink);
            },
            .snap => {
                // A magnet: a U with its tips.
                try arc(c, .{ .x = m.x, .y = m.y + 1 }, 5.5, 0, std.math.pi, ink, false);
                try line(c, .{ .x = m.x - 5.5, .y = m.y + 1 }, .{ .x = m.x - 5.5, .y = m.y - 6 }, 2.5, ink);
                try line(c, .{ .x = m.x + 5.5, .y = m.y + 1 }, .{ .x = m.x + 5.5, .y = m.y - 6 }, 2.5, ink);
            },
            .game_camera => {
                // A film camera: a body and a lens.
                try outlineRect(c, .{ .x = m.x - 8, .y = m.y - 4, .w = 11, .h = 9 }, 1.3, ink);
                try c.triangle(.{ .{ m.x + 3, m.y }, .{ m.x + 8, m.y - 4 }, .{ m.x + 8, m.y + 4 } }, .{ ink, ink, ink });
            },
            .touchpad => {
                try outlineRect(c, .{ .x = m.x - 8, .y = m.y - 6, .w = 16, .h = 12 }, 1.3, ink);
                try line(c, .{ .x = m.x - 3, .y = m.y - 3 }, .{ .x = m.x - 3, .y = m.y + 3 }, 1.8, ink);
                try line(c, .{ .x = m.x + 3, .y = m.y - 3 }, .{ .x = m.x + 3, .y = m.y + 3 }, 1.8, ink);
            },
            .fold => try chevron(c, m, if (self.folded) 1 else -1, ink),
        }
    }
};

fn line(c: *ui.Canvas, from: ui.Vec2, to: ui.Vec2, width: f32, color: [4]f32) !void {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const span = @sqrt(dx * dx + dy * dy);
    if (span < 0.01) return;
    const nx = -dy / span * width / 2;
    const ny = dx / span * width / 2;
    try c.triangle(.{ .{ from.x + nx, from.y + ny }, .{ to.x + nx, to.y + ny }, .{ to.x - nx, to.y - ny } }, .{ color, color, color });
    try c.triangle(.{ .{ from.x + nx, from.y + ny }, .{ to.x - nx, to.y - ny }, .{ from.x - nx, from.y - ny } }, .{ color, color, color });
}

/// An arrowhead at `reach` from `m` along `d`, pointing out.
fn head(c: *ui.Canvas, m: ui.Vec2, d: [2]f32, reach: f32, color: [4]f32) !void {
    const tip = [2]f32{ m.x + d[0] * reach, m.y + d[1] * reach };
    const base = [2]f32{ tip[0] - d[0] * 3.5, tip[1] - d[1] * 3.5 };
    try c.triangle(.{ tip, .{ base[0] - d[1] * 3, base[1] + d[0] * 3 }, .{ base[0] + d[1] * 3, base[1] - d[0] * 3 } }, .{ color, color, color });
}

/// An arc round `m` from angle `from` to `to` (radians, y down), with an arrowhead at its end.
fn arc(c: *ui.Canvas, m: ui.Vec2, radius: f32, from: f32, to: f32, color: [4]f32, arrow: bool) !void {
    const steps = 20;
    var last = ui.Vec2{ .x = m.x + @cos(from) * radius, .y = m.y + @sin(from) * radius };
    for (1..steps + 1) |i| {
        const angle = from + (to - from) * @as(f32, @floatFromInt(i)) / steps;
        const next = ui.Vec2{ .x = m.x + @cos(angle) * radius, .y = m.y + @sin(angle) * radius };
        try line(c, last, next, 1.5, color);
        last = next;
    }
    if (arrow) try head(c, .{ .x = last.x, .y = last.y }, .{ -@sin(to), @cos(to) }, 0.5, color);
}

fn outlineRect(c: *ui.Canvas, r: ui.Rect, width: f32, color: [4]f32) !void {
    const corners = [4]ui.Vec2{ .{ .x = r.x, .y = r.y }, .{ .x = r.x + r.w, .y = r.y }, .{ .x = r.x + r.w, .y = r.y + r.h }, .{ .x = r.x, .y = r.y + r.h } };
    for (0..4) |i| try line(c, corners[i], corners[(i + 1) % 4], width, color);
}

fn outlineEllipse(c: *ui.Canvas, m: ui.Vec2, rx: f32, ry: f32, color: [4]f32) !void {
    const steps = 20;
    for (0..steps) |i| {
        const a0 = std.math.tau * @as(f32, @floatFromInt(i)) / steps;
        const a1 = std.math.tau * @as(f32, @floatFromInt(i + 1)) / steps;
        try line(c, .{ .x = m.x + @cos(a0) * rx, .y = m.y + @sin(a0) * ry }, .{ .x = m.x + @cos(a1) * rx, .y = m.y + @sin(a1) * ry }, 1.2, color);
    }
}

fn dotAt(c: *ui.Canvas, m: ui.Vec2, radius: f32, color: [3]f32) !void {
    try c.roundRect(.{ .x = m.x - radius, .y = m.y - radius, .w = radius * 2, .h = radius * 2 }, color, radius);
}

/// A chevron pointing right (`way` 1) or left (-1).
fn chevron(c: *ui.Canvas, m: ui.Vec2, way: f32, color: [4]f32) !void {
    try line(c, .{ .x = m.x - 2 * way, .y = m.y - 5 }, .{ .x = m.x + 3 * way, .y = m.y }, 1.6, color);
    try line(c, .{ .x = m.x + 3 * way, .y = m.y }, .{ .x = m.x - 2 * way, .y = m.y + 5 }, 1.6, color);
}

test "every button is told apart by its id, and other ids are none of them" {
    try std.testing.expectEqual(Button.scale, buttonOf(first_id + 3).?);
    try std.testing.expect(buttonOf(first_id + 40) == null);
    try std.testing.expect(buttonOf(12) == null);
}

test "the toolbar stays inside the panel, folded or not" {
    const scene = ui.Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const open = State{};
    const kept = keepInside(open, .{ .x = 390, .y = -20 }, scene);
    try std.testing.expectEqual(scene.w - size(open).x, kept.x);
    try std.testing.expectEqual(@as(f32, 0), kept.y);
    try std.testing.expect(size(.{ .folded = true }).x < size(open).x);
}
