//! The editor's dock panels and what each shows. Scene marks where the editor draws the scene
//! texture, with its gizmo and buttons floating over it; the "pages" (Inspector, Console, Hierarchy, Assets, Animation, the UI Designer's three, the Asset Preview and each plugin's `editor_panels`) mark
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
    animation,
    /// The UI Designer: its preview, its node tree and the selected node's properties.
    ui_designer,
    ui_tree,
    ui_properties,
    /// The file selected in Assets, shown as itself.
    asset_preview,

    /// Return a static, sentinel-terminated display title for a built-in editor panel.
    ///
    /// ```zig
    /// const title = Panel.scene.title();
    /// std.debug.assert(std.mem.eql(u8, title, "Scene"));
    /// ```
    pub fn title(panel: Panel) [:0]const u8 {
        return switch (panel) {
            .scene => "Scene",
            .hierarchy => "Hierarchy",
            .inspector => "Inspector",
            .assets => "Assets",
            .console => "Console",
            .animation => "Animation",
            .ui_designer => "UI Designer",
            .ui_tree => "UI Tree",
            .ui_properties => "UI Properties",
            .asset_preview => "Asset Preview",
        };
    }
};

/// Beginning of the plugin panel ID range. Keyed panels keep their ID across reorder/reload.
pub const plugin_first: u32 = 100;
/// Derive an internal dock ID from a panel's stable key; unkeyed panels use their zero-based
/// declaration index. The host checks hash collisions; this does not guarantee uniqueness.
/// Borrowed panel metadata is not retained; unkeyed indices must fit the dock's panel range.
///
/// ```zig
/// const panel = EditorPanel{ .title = "Stats" };
/// const id = panels.pluginId(panel, 0);
/// std.debug.assert(id == panels.plugin_first);
/// ```
pub fn pluginId(panel: EditorPanel, index: usize) u32 {
    if (panel.key.len == 0) return plugin_first + @as(u32, @intCast(index));
    return 128 + @as(u32, @intCast(std.hash.Wyhash.hash(0, panel.key) % (ui.dock.max_panel - 128)));
}
/// Pages: the Inspector (`inspector_page`), the Console (`console_page`), the Hierarchy
/// (`hierarchy_page`), Assets (`assets_page`), Animation (`animation_page`), the UI Designer
/// (`ui_designer_page`), its tree (`ui_tree_page`) and properties (`ui_properties_page`), the Asset
/// Preview (`asset_preview_page`), then the plugin panels (`first_plugin_page + i`).
pub const max_pages = 32;
pub const inspector_page = 0;
pub const console_page = 1;
pub const hierarchy_page = 2;
pub const assets_page = 3;
pub const animation_page = 4;
pub const ui_designer_page = 5;
pub const ui_tree_page = 6;
pub const ui_properties_page = 7;
pub const asset_preview_page = 8;
pub const first_plugin_page = 9;

/// Page index of dock panel `id`, if it is a page.
/// Borrows the current plugin declarations; Scene and unknown IDs return null.
///
/// ```zig
/// const page = panels.pageOf(@intFromEnum(Panel.inspector), &.{}).?;
/// std.debug.assert(page == panels.inspector_page);
/// ```
pub fn pageOf(id: u32, plugin_panels: []const EditorPanel) ?usize {
    if (id == @intFromEnum(Panel.inspector)) return inspector_page;
    if (id == @intFromEnum(Panel.console)) return console_page;
    if (id == @intFromEnum(Panel.hierarchy)) return hierarchy_page;
    if (id == @intFromEnum(Panel.assets)) return assets_page;
    if (id == @intFromEnum(Panel.animation)) return animation_page;
    if (id == @intFromEnum(Panel.ui_designer)) return ui_designer_page;
    if (id == @intFromEnum(Panel.ui_tree)) return ui_tree_page;
    if (id == @intFromEnum(Panel.ui_properties)) return ui_properties_page;
    if (id == @intFromEnum(Panel.asset_preview)) return asset_preview_page;
    for (plugin_panels, 0..) |panel, index| if (pluginId(panel, index) == id) return first_plugin_page + index;
    return null;
}

/// Title of dock panel `id`, built in or from `plugin_panels`.
/// Returns static built-in/fallback text or a borrowed plugin title; keep plugin metadata alive.
///
/// ```zig
/// const title = panels.panelTitle(@intFromEnum(Panel.console), &.{});
/// std.debug.assert(std.mem.eql(u8, title, "Console"));
/// ```
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

    /// Dock-provider callback for the title of `panel`; canonical behavior is `panelTitle`.
    /// Returned text borrows plugin metadata or static storage, never the builder arena.
    ///
    /// ```zig
    /// // Host has a Provider for this window:
    /// const label = provider.title(@intFromEnum(Panel.scene));
    /// _ = label;
    /// ```
    pub fn title(self: Provider, panel: u32) []const u8 {
        return panelTitle(panel, self.plugin_panels);
    }

    /// Build the internal dock placeholder/Scene overlay in `rect` (window logical points),
    /// recording page placement and a draw-order marker for the host's later render splice.
    /// The returned element belongs to `b`'s frame arena; placements must outlive its draw.
    /// Plugin pages must fit `max_pages`; allocation/overlay-building errors propagate.
    ///
    /// ```zig
    /// // Host's active layout builder and per-window Provider:
    /// const scene = try provider.content(b, @intFromEnum(Panel.scene), content_rect);
    /// context.element(scene);
    /// ```
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
            .inspector, .console, .hierarchy, .assets, .animation, .ui_designer, .ui_tree, .ui_properties, .asset_preview => unreachable, // pages
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

test "pages are the Inspector, the Console, the Hierarchy, Assets, Animation, the UI Designer's three, the Asset Preview and the plugin panels, in that order" {
    const plugin_panels = [_]EditorPanel{ .{ .title = "Stats" }, .{ .title = "Level" } };
    try std.testing.expectEqual(@as(?usize, 0), pageOf(@intFromEnum(Panel.inspector), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 1), pageOf(@intFromEnum(Panel.console), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 2), pageOf(@intFromEnum(Panel.hierarchy), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 3), pageOf(@intFromEnum(Panel.assets), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 4), pageOf(@intFromEnum(Panel.animation), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 5), pageOf(@intFromEnum(Panel.ui_designer), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 7), pageOf(@intFromEnum(Panel.ui_properties), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 8), pageOf(@intFromEnum(Panel.asset_preview), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 10), pageOf(plugin_first + 1, &plugin_panels));
    try std.testing.expectEqual(@as(?usize, null), pageOf(@intFromEnum(Panel.scene), &plugin_panels));
    try std.testing.expectEqualStrings("Level", panelTitle(plugin_first + 1, &plugin_panels));
    try std.testing.expectEqualStrings("Console", panelTitle(@intFromEnum(Panel.console), &plugin_panels));
}
