//! Small theme-aware icons for Inspector component headers.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

const Icon = enum { transform, mesh, camera, scene, material, light, plugin };

fn iconFor(name: []const u8, owner: []const u8) Icon {
    if (!std.mem.eql(u8, owner, "eggy")) return .plugin;
    const builtins = .{
        .{ "Transform", Icon.transform },
        .{ "Mesh", Icon.mesh },
        .{ "Camera", Icon.camera },
        .{ "SceneInstance", Icon.scene },
        .{ "Material", Icon.material },
        .{ "SceneLight", Icon.light },
    };
    inline for (builtins) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return .plugin;
}

/// A frame-owned icon; keep the component's text label as its accessible name.
pub fn paint(arena: std.mem.Allocator, component: eggy.components.Info) !ui.Layout.Paint {
    const icon = try arena.create(Icon);
    icon.* = iconFor(component.name, component.owner);
    return .{ .custom = .{ .context = icon, .draw = draw } };
}

fn draw(context: *const anyopaque, canvas: *ui.Canvas, bounds: ui.Rect) anyerror!void {
    const icon: *const Icon = @ptrCast(@alignCast(context));
    const color = canvas.theme.muted_foreground;
    const r = ui.Rect{ .x = bounds.x + (bounds.w - 16) / 2, .y = bounds.y + (bounds.h - 16) / 2, .w = 16, .h = 16 };
    switch (icon.*) {
        .transform => try canvas.icon(r, .command, color),
        .mesh => try canvas.icon(r, .image, color),
        .scene => try canvas.icon(r, .file, color),
        .plugin => try canvas.icon(r, .paperclip, color),
        .camera => {
            try canvas.roundRectStroke(.{ .x = r.x, .y = r.y + 3, .w = 16, .h = 12 }, color, 2, 1.2);
            try canvas.roundRectStroke(.{ .x = r.x + 5, .y = r.y + 6, .w = 6, .h = 6 }, color, 3, 1.2);
            try canvas.rect(.{ .x = r.x + 4, .y = r.y + 1, .w = 6, .h = 2 }, color);
        },
        .material => {
            try canvas.roundRectStroke(r, color, 8, 1.2);
            for ([_][2]f32{ .{ 4, 4 }, .{ 10, 4 }, .{ 4, 10 }, .{ 10, 10 } }) |dot|
                try canvas.roundRect(.{ .x = r.x + dot[0], .y = r.y + dot[1], .w = 2, .h = 2 }, color, 1);
        },
        .light => {
            try canvas.roundRectStroke(.{ .x = r.x + 4, .y = r.y + 4, .w = 8, .h = 8 }, color, 4, 1.2);
            for ([_]f32{ 0, 14 }) |offset| {
                try canvas.rect(.{ .x = r.x + 7, .y = r.y + offset, .w = 2, .h = 2 }, color);
                try canvas.rect(.{ .x = r.x + offset, .y = r.y + 7, .w = 2, .h = 2 }, color);
            }
            for ([_][2]f32{ .{ 1, 1 }, .{ 13, 1 }, .{ 1, 13 }, .{ 13, 13 } }) |ray|
                try canvas.rect(.{ .x = r.x + ray[0], .y = r.y + ray[1], .w = 2, .h = 2 }, color);
        },
    }
}

test "built-in component icons are semantic and plugins always have a fallback" {
    try std.testing.expectEqual(Icon.transform, iconFor("Transform", "eggy"));
    try std.testing.expectEqual(Icon.mesh, iconFor("Mesh", "eggy"));
    try std.testing.expectEqual(Icon.camera, iconFor("Camera", "eggy"));
    try std.testing.expectEqual(Icon.scene, iconFor("SceneInstance", "eggy"));
    try std.testing.expectEqual(Icon.material, iconFor("Material", "eggy"));
    try std.testing.expectEqual(Icon.light, iconFor("SceneLight", "eggy"));
    try std.testing.expectEqual(Icon.plugin, iconFor("Material", "game"));
    try std.testing.expectEqual(Icon.plugin, iconFor("Health", "my_plugin"));
}
