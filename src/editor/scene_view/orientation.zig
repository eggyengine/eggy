//! The view's orientation, in the Scene panel's top right corner (ImGuizmo's view manipulator):
//! the world's axes as the camera sees them, a bubble at each end, positive ends labelled.
//! Clicking a bubble looks at the scene from that side.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const View = eggy.camera.View;

/// How far the axes reach from the widget's centre, and its bubbles' size, in points.
const reach_pt: f32 = 30;
const bubble_pt: f32 = 8;
/// The widget's centre, in from the panel's top right corner.
const inset_pt: f32 = 46;

const axis_colors = [3][3]f32{ .{ 0.92, 0.27, 0.32 }, .{ 0.47, 0.85, 0.3 }, .{ 0.27, 0.52, 0.96 } };

/// One end of an axis: which axis, which way, where it is on screen, and how near the camera.
pub const End = struct { axis: u2, positive: bool, at: ui.Vec2, nearness: f32 };

/// The six ends as `view` sees them, in the corner of `scene`, furthest first.
/// Editor-only: projects normalized camera axes into UI points, with axis indices 0/1/2 for
/// x/y/z and a signed nearness used for ordering. Returns a value array without allocation.
///
/// ```zig
/// const bubbles = ends(view, scene); // Current camera view and Scene UI rect.
/// ```
pub fn ends(view: View, scene: ui.Rect) [6]End {
    const centre = ui.Vec2{ .x = scene.x + scene.w - inset_pt, .y = scene.y + inset_pt };
    const right = eggy.camera.normalize(eggy.camera.cross(view.forward, view.up));
    var result: [6]End = undefined;
    for (0..6) |i| {
        const axis: u2 = @intCast(i / 2);
        const positive = i % 2 == 0;
        var direction = [3]f32{ 0, 0, 0 };
        direction[axis] = if (positive) 1 else -1;
        result[i] = .{
            .axis = axis,
            .positive = positive,
            .at = .{ .x = centre.x + dot(direction, right) * reach_pt, .y = centre.y - dot(direction, view.up) * reach_pt },
            .nearness = -dot(direction, view.forward),
        };
    }
    std.mem.sort(End, &result, {}, struct {
        fn further(_: void, a: End, b: End) bool {
            return a.nearness < b.nearness;
        }
    }.further);
    return result;
}

/// The end under `pointer`, the nearest the camera first.
/// Editor-only: pointer and scene rect use the same UI points. Tests square bubble bounds;
/// null means none hit. Returns a copied End and does not move the camera.
///
/// ```zig
/// const hovered = hit(view, scene, pointer); // Current view/Scene rect/UI pointer.
/// ```
pub fn hit(view: View, scene: ui.Rect, pointer: ui.Vec2) ?End {
    const all = ends(view, scene);
    var i: usize = all.len;
    while (i > 0) {
        i -= 1;
        const end = all[i];
        if (@abs(pointer.x - end.at.x) <= bubble_pt and @abs(pointer.y - end.at.y) <= bubble_pt) return end;
    }
    return null;
}

/// The camera's turn to look at the scene from `end`'s side: yaw and pitch in degrees, as
/// `SceneCamera` keeps them.
/// Editor-only: use an End from `ends`/`hit` (axis 0..2); pole views use ±89 degrees to avoid
/// a singular up vector. Returns angles only, leaving focus/distance unchanged.
///
/// ```zig
/// // Given an End from hit and an existing SceneCamera:
/// const turn = lookFrom(end);
/// camera.yaw_deg = turn.yaw_deg;
/// camera.pitch_deg = turn.pitch_deg;
/// ```
pub fn lookFrom(end: End) struct { yaw_deg: f32, pitch_deg: f32 } {
    const sign: f32 = if (end.positive) 1 else -1;
    return switch (end.axis) {
        // From +x the camera looks down -x: yaw a quarter turn.
        0 => .{ .yaw_deg = 90 * sign, .pitch_deg = 0 },
        1 => .{ .yaw_deg = 0, .pitch_deg = -89 * sign },
        else => .{ .yaw_deg = if (end.positive) 0 else 180, .pitch_deg = 0 },
    };
}

/// The widget as paint for a node covering the Scene panel, seen through `view`, the end under
/// the pointer (`hot`) lit. In `arena`.
/// Editor-only: copies view-derived drawing state into the frame arena; keep it alive through
/// painting. `hot` should come from this frame's hit test; allocation failure returns `.none`.
///
/// ```zig
/// const widget_paint = paint(arena, view, scene, null); // Frame arena allocator and view/rect.
/// ```
pub fn paint(arena: std.mem.Allocator, view: View, scene: ui.Rect, hot: ?End) ui.Layout.Paint {
    const drawing = arena.create(Drawing) catch return .none;
    drawing.* = .{ .ends = ends(view, scene), .hot = hot, .centre = .{ .x = scene.x + scene.w - inset_pt, .y = scene.y + inset_pt } };
    return .{ .custom = .{ .context = drawing, .draw = Drawing.draw } };
}

const Drawing = struct {
    ends: [6]End,
    hot: ?End,
    centre: ui.Vec2,

    fn draw(context: *const anyopaque, c: *ui.Canvas, _: ui.Rect) anyerror!void {
        const self: *const Drawing = @ptrCast(@alignCast(context));
        const back = reach_pt + bubble_pt + 4;
        try c.roundRectAlpha(.{ .x = self.centre.x - back, .y = self.centre.y - back, .w = back * 2, .h = back * 2 }, .{ 0, 0, 0 }, back, 0.25);
        // Furthest first, so nearer ends cover them.
        for (self.ends) |end| {
            const base = axis_colors[end.axis];
            const lit = if (self.hot) |hot| hot.axis == end.axis and hot.positive == end.positive else false;
            const strength: f32 = if (end.positive) 1 else 0.45;
            const rgb = if (lit) [3]f32{ 1, 0.84, 0.22 } else [3]f32{ base[0] * strength, base[1] * strength, base[2] * strength };
            if (end.positive) try line(c, self.centre, end.at, 2, .{ rgb[0], rgb[1], rgb[2], 1 });
            try c.roundRect(.{ .x = end.at.x - bubble_pt, .y = end.at.y - bubble_pt, .w = bubble_pt * 2, .h = bubble_pt * 2 }, rgb, bubble_pt);
            if (end.positive) try c.textIn(.{ .x = end.at.x - bubble_pt, .y = end.at.y - bubble_pt, .w = bubble_pt * 2, .h = bubble_pt * 2 }, ([_][]const u8{ "X", "Y", "Z" })[end.axis], 10, .{ 0.08, 0.08, 0.08 }, .center);
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

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

test "looking down -z, +x is to the right and +y up, and clicking +x looks from the side" {
    const view = View.lookingAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{});
    const scene = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    var x_end: ?End = null;
    var y_end: ?End = null;
    for (ends(view, scene)) |end| {
        if (end.axis == 0 and end.positive) x_end = end;
        if (end.axis == 1 and end.positive) y_end = end;
    }
    try std.testing.expect(x_end.?.at.x > scene.w - inset_pt);
    try std.testing.expect(y_end.?.at.y < inset_pt);
    const clicked = hit(view, scene, x_end.?.at).?;
    try std.testing.expectEqual(@as(f32, 90), lookFrom(clicked).yaw_deg);
}
