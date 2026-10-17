//! The editor's dock panels and what each shows. Scene marks where the editor draws the scene
//! texture, with its gizmo and buttons floating over it; the "pages" (Inspector, Console, Hierarchy, Assets and each plugin's `editor_panels`) mark
//! where it draws a `ui.Context` of their own.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const EditorPanel = eggy.plugins.EditorPanel;
const scene_view = @import("scene_view/scene_view.zig");

/// The built-in panels' dock ids (nonzero, below `dock.max_panel`).
pub const Panel = enum(u32) {
    scene = 1,
    hierarchy,
    inspector,
    assets,
    console,

    pub fn title(panel: Panel) [:0]const u8 {
        return switch (panel) {
            .scene => "Scene",
            .hierarchy => "Hierarchy",
            .inspector => "Inspector",
            .assets => "Assets",
            .console => "Console",
        };
    }
};

/// Beginning of the plugin panel ID range. Keyed panels keep their ID across reorder/reload.
pub const plugin_first: u32 = 100;
pub fn pluginId(panel: EditorPanel, index: usize) u32 {
    if (panel.key.len == 0) return plugin_first + @as(u32, @intCast(index));
    return 128 + @as(u32, @intCast(std.hash.Wyhash.hash(0, panel.key) % (ui.dock.max_panel - 128)));
}
/// Pages: the Inspector (`inspector_page`), the Console (`console_page`), the Hierarchy
/// (`hierarchy_page`), Assets (`assets_page`), then the plugin panels (`first_plugin_page + i`).
pub const max_pages = 32;
pub const inspector_page = 0;
pub const console_page = 1;
pub const hierarchy_page = 2;
pub const assets_page = 3;
pub const first_plugin_page = 4;

/// Page index of dock panel `id`, if it is a page.
pub fn pageOf(id: u32, plugin_panels: []const EditorPanel) ?usize {
    if (id == @intFromEnum(Panel.inspector)) return inspector_page;
    if (id == @intFromEnum(Panel.console)) return console_page;
    if (id == @intFromEnum(Panel.hierarchy)) return hierarchy_page;
    if (id == @intFromEnum(Panel.assets)) return assets_page;
    for (plugin_panels, 0..) |panel, index| if (pluginId(panel, index) == id) return first_plugin_page + index;
    return null;
}

/// Title of dock panel `id`, built in or from `plugin_panels`.
pub fn panelTitle(id: u32, plugin_panels: []const EditorPanel) [:0]const u8 {
    if (id >= plugin_first) {
        for (plugin_panels, 0..) |panel, index| if (pluginId(panel, index) == id) return panel.title;
        return "Panel";
    }
    return (std.enums.fromInt(Panel, id) orelse return "Panel").title();
}

/// Where a panel's content was laid out: in which window (see `workspace.Slot`), and where.
pub const Placement = struct { slot: usize, rect: ui.Rect };

/// Where the Scene and pages landed in the last build, and where in their window's draw order
/// (its vertex count when drawing reached them), which is where the editor draws into them.
pub const Placements = struct {
    scene: ?Placement = null,
    scene_mark: ?usize = null,
    pages: [max_pages]?Placement = @splat(null),
    page_marks: [max_pages]?usize = @splat(null),
};

/// The dock's provider for window `slot`: panel titles and contents.
pub const Provider = struct {
    placements: *Placements,
    slot: usize,
    plugin_panels: []const EditorPanel,
    /// What floats over the Scene panel.
    scene_overlay: *const scene_view.Overlay = &scene_view.Overlay.none,

    pub fn title(self: Provider, panel: u32) []const u8 {
        return panelTitle(panel, self.plugin_panels);
    }

    pub fn content(self: Provider, b: L.Builder, panel: u32, rect: ui.Rect) !*L.Element {
        const placed = self.placements;
        if (pageOf(panel, self.plugin_panels)) |page| {
            placed.pages[page] = .{ .slot = self.slot, .rect = rect };
            return b.node(0, .{ .width = rect.w, .height = rect.h }, marker(&placed.page_marks[page]), &.{});
        }
        return switch (std.enums.fromInt(Panel, panel) orelse return placeholder(b, "")) {
            .scene => blk: {
                placed.scene = .{ .slot = self.slot, .rect = rect };
                // The scene texture goes in at the mark; the gizmo and buttons float over it.
                const floating = try scene_view.overlayElements(b, self.scene_overlay.*, rect);
                const scene = try b.node(0, .{ .width = rect.w, .height = rect.h }, marker(&placed.scene_mark), floating);
                scene.accessibility = .{ .role = .image, .label = "Scene view" };
                break :blk scene;
            },
            .inspector, .console, .hierarchy, .assets => unreachable, // pages
        };
    }
};

/// Paint that draws nothing but stores the canvas's vertex count in `mark` when reached.
fn marker(mark: *?usize) L.Paint {
    return .{ .custom = .{ .context = mark, .draw = recordMark } };
}

fn recordMark(context: *const anyopaque, c: *ui.Canvas, _: ui.Rect) anyerror!void {
    const mark: *?usize = @ptrCast(@alignCast(@constCast(context)));
    mark.* = c.len;
}

fn placeholder(b: L.Builder, message: []const u8) !*L.Element {
    return b.node(0, .{ .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 } }, .none, &.{
        try b.node(0, .{}, .{ .text = .{ .value = message, .size = 13, .tone = .muted } }, &.{}),
    });
}

test "pages are the Inspector, the Console, the Hierarchy, Assets and the plugin panels, in that order" {
    const plugin_panels = [_]EditorPanel{ .{ .title = "Stats" }, .{ .title = "Level" } };
    try std.testing.expectEqual(@as(?usize, 0), pageOf(@intFromEnum(Panel.inspector), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 1), pageOf(@intFromEnum(Panel.console), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 2), pageOf(@intFromEnum(Panel.hierarchy), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 3), pageOf(@intFromEnum(Panel.assets), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 5), pageOf(plugin_first + 1, &plugin_panels));
    try std.testing.expectEqual(@as(?usize, null), pageOf(@intFromEnum(Panel.scene), &plugin_panels));
    try std.testing.expectEqualStrings("Level", panelTitle(plugin_first + 1, &plugin_panels));
    try std.testing.expectEqualStrings("Console", panelTitle(@intFromEnum(Panel.console), &plugin_panels));
}
