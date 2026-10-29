//! Eggy's loading screen: while a scene streams in with `loading_screen` set, it covers the game
//! with the scene's name, a bar of how far it has come, and what is being loaded now.
const std = @import("std");
const ui = @import("weeoui");
const Loading = @import("stream.zig").Loading;

/// Under the dev console, over the game's own UI.
const z_index = 300;
const bar_width: f32 = 360;
const bar_height: f32 = 6;

/// Cover the game with the loading screen while `loading` asks for it; nothing otherwise. Its
/// clicks don't reach the game under it. Host-only: call where the game UI is built, after the
/// game's own.
///
/// ```zig
/// eggy.scenes.loading_screen.draw(app.scenes().loading(), &layer.context);
/// ```
pub fn draw(loading: ?Loading, context: *ui.Context) void {
    const shown = loading orelse return;
    if (!shown.loading_screen) return;
    const viewport = context.viewport;
    const arena = context.builder().allocator;
    const paint = arena.create(Screen) catch return;
    paint.* = .{
        .title = std.fmt.allocPrint(arena, "Loading {s}", .{sceneName(shown.scene)}) catch return,
        .detail = detailText(arena, shown) catch return,
        .fraction = shown.fraction(),
    };
    const screen = context.builder().node(context.idFor("##loading screen"), .{ .width = viewport.w, .height = viewport.h, .z_index = z_index }, .{ .custom = .{ .context = paint, .draw = Screen.draw } }, &.{}) catch return;
    screen.overlay = .{ .point = .init(viewport.x, viewport.y) };
    screen.accessibility = .{ .role = .progress, .label = paint.title, .numeric_value = paint.fraction };
    context.element(screen);
}

/// Whether `loading` shows the screen, so a host knows to build its UI layer this frame.
pub fn shows(loading: ?Loading) bool {
    const shown = loading orelse return false;
    return shown.loading_screen;
}

/// The scene's file name without its folders and `.scene.zon`.
fn sceneName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".scene.zon")) base[0 .. base.len - ".scene.zon".len] else base;
}

/// What is being loaded now, and how many of the scene's models and images are done.
fn detailText(arena: std.mem.Allocator, loading: Loading) ![]const u8 {
    return switch (loading.stage) {
        .reading => try std.fmt.allocPrint(arena, "Reading {s}", .{loading.item}),
        .models_and_images => try std.fmt.allocPrint(arena, "{s} ({d} of {d})", .{ loading.item, loading.done + 1, loading.total }),
        .placing => "Placing entities",
    };
}

const Screen = struct {
    title: []const u8,
    detail: []const u8,
    fraction: f32,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Screen = @ptrCast(@alignCast(context));
        try c.rect(r, c.theme.background);
        const width = @min(bar_width, r.w - 32);
        const left = r.x + (r.w - width) / 2;
        const middle = r.y + r.h / 2;
        try c.textIn(.{ .x = left, .y = middle - 44, .w = width, .h = 28 }, self.title, 18, c.theme.foreground, .center);
        try c.roundRect(.{ .x = left, .y = middle - bar_height / 2, .w = width, .h = bar_height }, c.theme.muted, bar_height / 2);
        try c.roundRect(.{ .x = left, .y = middle - bar_height / 2, .w = width * std.math.clamp(self.fraction, 0, 1), .h = bar_height }, c.theme.primary, bar_height / 2);
        try c.textIn(.{ .x = left, .y = middle + 12, .w = width, .h = 20 }, self.detail, 12, c.theme.muted_foreground, .center);
    }
};

test "the screen names the scene and says what is loading, out of how many" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("level", sceneName("resources/scene/level.scene.zon"));
    const loading = Loading{ .scene = "resources/scene/level.scene.zon", .stage = .models_and_images, .done = 2, .total = 5, .item = "resources/ship.glb", .loading_screen = true };
    try std.testing.expectEqualStrings("resources/ship.glb (3 of 5)", try detailText(arena.allocator(), loading));
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), loading.fraction(), 0.001);
    try std.testing.expect(!shows(null));
}
