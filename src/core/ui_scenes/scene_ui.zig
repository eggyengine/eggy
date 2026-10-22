//! Building one UI scene into a weeoui context: laid out across a viewport, painted by one
//! element, with hit boxes for its buttons (in the game) or for every node (in the UI Designer).
const std = @import("std");
const ecs = @import("clutch");
const ui = @import("weeoui");
const ui_scene = @import("eggy_assets").ui_scene;
const Resources = @import("../resources/resources.zig").Resources;
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const cache = @import("cache.zig");
const state_zig = @import("state.zig");
const State = state_zig.State;

/// How a built scene behaves: in the game, buttons are pressed; in the UI Designer, every node
/// is a box to pick.
pub const Mode = enum { play, design };

/// Where a scene is built, and how.
pub const Placement = struct {
    /// In the context's logical units.
    viewport: ui.Rect,
    /// Viewport units per design pixel.
    scale: f32,
    z_index: i16 = 0,
    mode: Mode = .play,
    /// Off: no hit boxes in `.play`, so presses go through to the game.
    interactive: bool = true,
    /// Cut the painting off outside this rectangle (the context's units).
    clip: ?ui.Rect = null,
};

/// What `build` placed, in the context's frame arena.
pub const Built = struct {
    placed: []const layout.Placed,
    /// Each placed node's hit box id (0 for none).
    ids: []const u32,
};

/// What one built scene paints with, kept in the UI frame's arena until it is rendered.
const Painting = struct {
    frame: paint.Frame,
    sources: state_zig.Sources,
    clip: ?ui.Rect,

    fn draw(context: *const anyopaque, canvas: *ui.Canvas, _: ui.Rect) anyerror!void {
        const self: *const Painting = @ptrCast(@alignCast(context));
        const outer = canvas.clip;
        defer canvas.clip = outer;
        if (self.clip) |clip| canvas.clip = if (outer) |within| within.intersection(clip) else clip;
        var frame = self.frame;
        var sources = self.sources;
        frame.images = sources.imageSource();
        try paint.paint(canvas, frame);
    }
};

/// Lay `scene` out at `placement` and add it to `context`: one element painting it, and a hit
/// box per button (`.play`) or per node (`.design`), named after `entity`. Presses of buttons
/// are recorded in `state` for `entity`. Images load into `images`, which must be for
/// `context`'s font. Allocates in the context's frame arena; the painting borrows `state` and
/// `images` until `context.render`.
pub fn build(context: *ui.Context, state: *State, resources: Resources, images: *cache.Images, scene: *const ui_scene.UiScene, entity: ecs.EntityId, placement: Placement, time_ms: u64) !Built {
    const arena = context.builder().allocator;
    const painting = try arena.create(Painting);
    painting.clip = placement.clip;
    painting.sources = .{ .state = state, .resources = resources, .images = images, .font = context.font, .entity = entity };
    const placed = try layout.place(arena, scene, painting.sources.layoutSources(), placement.viewport, placement.scale);
    const ids = try arena.alloc(u32, placed.len);
    @memset(ids, 0);

    // A hit box per button (or node, when designing), which weeoui hovers and presses.
    for (placed, ids, 0..) |item, *id, index| {
        const pickable = switch (placement.mode) {
            .play => placement.interactive and item.node.widget == .button,
            .design => item.index != null,
        };
        if (!pickable or item.rect.w <= 0 or item.rect.h <= 0) continue;
        const name = try std.fmt.allocPrint(arena, "ui scene {d}:{d} {d}", .{ entity.id, entity.generation, index });
        id.* = context.idFor(name);
        const hit = try context.builder().node(id.*, .{ .width = item.rect.w, .height = item.rect.h, .z_index = placement.z_index }, .none, &.{});
        hit.overlay = .{ .point = .{ .x = item.rect.x, .y = item.rect.y } };
        const button = item.node.widget == .button;
        hit.accessibility = .{ .role = if (button) .button else .group, .label = if (button) item.node.widget.button.label else item.node.name };
        context.element(hit);
        if (placement.mode == .play and context.activated(id.*)) try state.recordClick(entity, item.node.name);
    }

    // The painting under the hit boxes, across the viewport.
    painting.frame = .{ .placed = placed, .scale = placement.scale, .widgets = state.widgets, .time_ms = time_ms, .ids = ids, .pressed = context.active };
    const element = try context.builder().node(0, .{ .width = placement.viewport.w, .height = placement.viewport.h, .z_index = placement.z_index }, .{ .custom = .{ .context = painting, .draw = Painting.draw } }, &.{});
    element.overlay = .{ .point = .{ .x = placement.viewport.x, .y = placement.viewport.y } };
    context.element(element);
    return .{ .placed = placed, .ids = ids };
}

test "a built scene records the press of its button" {
    const gpa = std.testing.allocator;
    var state = State{ .gpa = gpa };
    defer state.deinit();
    var images = cache.Images{ .gpa = gpa };
    defer images.deinit();
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var children = [_]ui_scene.Node{.{ .name = "go", .widget = .{ .button = .{} }, .layout = .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .anchor = .{ .offset = .{ 10, 10 } } } }};
    const scene = ui_scene.UiScene{ .root = .{ .layout = .{ .width = .fill, .height = .fill }, .children = &children } };
    const hud = ecs.EntityId{ .id = 1, .generation = 1 };
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var pressed = false;
    for (0..3) |frame| {
        state.forgetClicks();
        context.newFrame(viewport);
        const built = try build(&context, &state, .{}, &images, &scene, hud, .{ .viewport = viewport, .scale = 1 }, 0);
        try std.testing.expect(built.ids[1] != 0);
        try std.testing.expectEqual(@as(u32, 0), built.ids[0]);
        if (state.clicks.items.len != 0) pressed = true;
        _ = try context.render();
        // Press and release over the button between the first frames.
        if (frame == 0) {
            context.handle(.{ .pointer_move = .init(50, 30) });
            context.handle(.{ .pointer_down = .{ .position = .init(50, 30), .button = .left, .clicks = 1 } });
            context.handle(.{ .pointer_up = .{ .position = .init(50, 30), .button = .left } });
        }
    }
    try std.testing.expect(pressed);
}
