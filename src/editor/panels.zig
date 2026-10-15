//! The editor's dock panels and what each shows. Scene marks where the editor draws the scene
//! texture; the "pages" (Inspector, Console, Hierarchy and each plugin's `editor_panels`) mark
//! where it draws a `ui.Context` of their own. Assets is a stub for now.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const EditorPanel = eggy.plugins.EditorPanel;

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

/// Plugin panel i (of `Set.editor_panels`) has dock id `plugin_first + i`.
pub const plugin_first: u32 = 100;
/// Pages: the Inspector (`inspector_page`), the Console (`console_page`), the Hierarchy
/// (`hierarchy_page`), then the plugin panels (`first_plugin_page + i`).
pub const max_pages = 32;
pub const inspector_page = 0;
pub const console_page = 1;
pub const hierarchy_page = 2;
pub const first_plugin_page = 3;

/// Page index of dock panel `id`, if it is a page.
pub fn pageOf(id: u32) ?usize {
    if (id == @intFromEnum(Panel.inspector)) return inspector_page;
    if (id == @intFromEnum(Panel.console)) return console_page;
    if (id == @intFromEnum(Panel.hierarchy)) return hierarchy_page;
    if (id >= plugin_first and id < plugin_first + max_pages - first_plugin_page) return first_plugin_page + (id - plugin_first);
    return null;
}

/// Title of dock panel `id`, built in or from `plugin_panels`.
pub fn panelTitle(id: u32, plugin_panels: []const EditorPanel) [:0]const u8 {
    if (id >= plugin_first) return if (id - plugin_first < plugin_panels.len) plugin_panels[id - plugin_first].title else "Panel";
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

    pub fn title(self: Provider, panel: u32) []const u8 {
        return panelTitle(panel, self.plugin_panels);
    }

    pub fn content(self: Provider, b: L.Builder, panel: u32, rect: ui.Rect) !*L.Element {
        const placed = self.placements;
        if (pageOf(panel)) |page| {
            placed.pages[page] = .{ .slot = self.slot, .rect = rect };
            return b.node(0, .{ .width = rect.w, .height = rect.h }, marker(&placed.page_marks[page]), &.{});
        }
        return switch (std.enums.fromInt(Panel, panel) orelse return placeholder(b, "")) {
            .scene => blk: {
                placed.scene = .{ .slot = self.slot, .rect = rect };
                const scene = try b.node(0, .{ .width = rect.w, .height = rect.h }, marker(&placed.scene_mark), &.{});
                scene.accessibility = .{ .role = .image, .label = "Scene view" };
                break :blk scene;
            },
            .assets => placeholder(b, "No assets yet."),
            .inspector, .console, .hierarchy => unreachable, // pages
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

test "pages are the Inspector, the Console, the Hierarchy and the plugin panels, in that order" {
    try std.testing.expectEqual(@as(?usize, 0), pageOf(@intFromEnum(Panel.inspector)));
    try std.testing.expectEqual(@as(?usize, 1), pageOf(@intFromEnum(Panel.console)));
    try std.testing.expectEqual(@as(?usize, 2), pageOf(@intFromEnum(Panel.hierarchy)));
    try std.testing.expectEqual(@as(?usize, 4), pageOf(plugin_first + 1));
    try std.testing.expectEqual(@as(?usize, null), pageOf(@intFromEnum(Panel.scene)));
    const plugin_panels = [_]EditorPanel{ .{ .title = "Stats" }, .{ .title = "Level" } };
    try std.testing.expectEqualStrings("Level", panelTitle(plugin_first + 1, &plugin_panels));
    try std.testing.expectEqualStrings("Console", panelTitle(@intFromEnum(Panel.console), &plugin_panels));
}
