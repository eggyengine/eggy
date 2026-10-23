//! The editor's dock panels and what each shows. Scene marks where the editor draws the scene
//! texture, with its gizmo and buttons floating over it; the "pages" (Inspector, Console, Hierarchy, Assets, Animation, the UI Designer's three, the Asset Preview, the 2D Scene and each plugin's `editor_panels`) mark
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
    /// The world seen flat, through an orthographic camera, for 2D games.
    scene_2d,

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
            .scene_2d => "2D Scene",
        };
    }
};

/// How many of a panel there can be: one per workspace tab (`workspace_tabs.max_tabs`).
pub const max_copies = 8;

/// The panels each workspace tab can have its own of: every 3D tab its Scene and the panels
/// around it, every 2D tab its 2D Scene, every UI tab the UI Designer's three. Copy 0 is the
/// panel's own id; copy n takes an id from the gap between the built-in panels and `plugin_first`.
const copyable = [_]Panel{ .scene, .scene_2d, .ui_designer, .ui_tree, .ui_properties, .hierarchy, .inspector, .console, .assets, .animation };

/// One panel for each live copy `Live` keeps (the UI Designer's three go live together).
pub const live_panels = [_]Panel{ .scene, .scene_2d, .ui_designer, .hierarchy, .inspector, .console, .assets, .animation };
const copy_first: u32 = 20;

/// The dock id of `panel`'s copy `copy` (below `max_copies`); copy 0 is `panel`'s own id.
pub fn copyId(panel: Panel, copy: u8) u32 {
    if (copy == 0) return @backingInt(panel);
    const slot = std.mem.indexOfScalar(Panel, &copyable, panel).?;
    return copy_first + (copy - 1) * @as(u32, copyable.len) + @as(u32, @intCast(slot));
}

/// A built-in panel's id read back: which panel, and which copy of it (0 for every panel's own id).
pub const Copy = struct { panel: Panel, copy: u8 };

/// Which built-in panel, and which copy of it, `id` is; null for plugin panels and unknown ids.
pub fn copyOf(id: u32) ?Copy {
    if (std.enums.fromInt(Panel, id)) |panel| return .{ .panel = panel, .copy = 0 };
    if (id < copy_first or id >= copy_first + (max_copies - 1) * copyable.len) return null;
    const n = id - copy_first;
    return .{ .panel = copyable[n % copyable.len], .copy = @intCast(n / copyable.len + 1) };
}

/// Which copy of each copyable panel is live: drawn, and worked with. The editor has one of
/// each panel's page or view, so another copy in sight shows a placeholder offering to show it
/// there instead. The UI Designer's three panels go live together.
pub const Live = struct {
    scene: u8 = 0,
    scene_2d: u8 = 0,
    ui: u8 = 0,
    hierarchy: u8 = 0,
    inspector: u8 = 0,
    console: u8 = 0,
    assets: u8 = 0,
    animation: u8 = 0,

    /// Where `panel`'s live copy is kept, or null for a panel there is only one of.
    pub fn of(self: *Live, panel: Panel) ?*u8 {
        return switch (panel) {
            .scene => &self.scene,
            .scene_2d => &self.scene_2d,
            .ui_designer, .ui_tree, .ui_properties => &self.ui,
            .hierarchy => &self.hierarchy,
            .inspector => &self.inspector,
            .console => &self.console,
            .assets => &self.assets,
            .animation => &self.animation,
            .asset_preview => null,
        };
    }

    /// Whether panel id `id` is drawn: a panel there is one of, or the live copy.
    pub fn shows(self: Live, id: u32) bool {
        var live = self;
        const found = copyOf(id) orelse return true;
        const copy = live.of(found.panel) orelse return true;
        return copy.* == found.copy;
    }
};

/// Ids of the "Show here" buttons on copies that aren't live: `show_here_first` + the copy's id.
/// Kept below `dock.first_id`.
const show_here_first: u32 = 0x5600_0000;

/// The copy whose "Show here" button is `id`, if it is one.
pub fn showHereOf(id: u32) ?Copy {
    if (id < show_here_first or id >= show_here_first + plugin_first) return null;
    return copyOf(id - show_here_first);
}

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
/// Preview (`asset_preview_page`), the 2D Scene (`scene_2d_page`), then the plugin panels
/// (`first_plugin_page + i`).
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
pub const scene_2d_page = 9;
pub const first_plugin_page = 10;

/// Page index of dock panel `id`, if it is a page.
/// Borrows the current plugin declarations; Scene and unknown IDs return null.
///
/// ```zig
/// const page = panels.pageOf(@intFromEnum(Panel.inspector), &.{}).?;
/// std.debug.assert(page == panels.inspector_page);
/// ```
pub fn pageOf(id: u32, plugin_panels: []const EditorPanel) ?usize {
    if (id == @backingInt(Panel.inspector)) return inspector_page;
    if (id == @backingInt(Panel.console)) return console_page;
    if (id == @backingInt(Panel.hierarchy)) return hierarchy_page;
    if (id == @backingInt(Panel.assets)) return assets_page;
    if (id == @backingInt(Panel.animation)) return animation_page;
    if (id == @backingInt(Panel.ui_designer)) return ui_designer_page;
    if (id == @backingInt(Panel.ui_tree)) return ui_tree_page;
    if (id == @backingInt(Panel.ui_properties)) return ui_properties_page;
    if (id == @backingInt(Panel.asset_preview)) return asset_preview_page;
    if (id == @backingInt(Panel.scene_2d)) return scene_2d_page;
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
    return (copyOf(id) orelse return "Panel").panel.title();
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
    /// Which copies of the Scene, 2D Scene and UI Designer are drawn; the others offer "Show here".
    live: Live = .{},

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
    pub fn content(self: Provider, b: L.Builder, id: u32, rect: ui.Rect) !*L.Element {
        const placed = self.placements;
        if (!self.live.shows(id)) return showHere(b, id);
        // A live copy draws as the panel itself.
        const panel = if (copyOf(id)) |found| @backingInt(found.panel) else id;
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
            .inspector, .console, .hierarchy, .assets, .animation, .ui_designer, .ui_tree, .ui_properties, .asset_preview, .scene_2d => unreachable, // pages
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

/// A copy that isn't live: where the panel is shown instead, and a button to show it here.
fn showHere(b: L.Builder, id: u32) !*L.Element {
    const button = try b.node(show_here_first + id, .{ .height = 28 }, .{ .button = .{ .label = "Show here", .variant = .outline, .size = .sm } }, &.{});
    button.cursor = .pointer;
    return b.node(0, .{ .direction = .column, .gap = 10, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 } }, .none, &.{
        try b.node(0, .{}, .{ .text = .{ .value = "Shown in another tab, or another window.", .size = 13, .tone = .muted } }, &.{}),
        button,
    });
}

fn placeholder(b: L.Builder, message: []const u8) !*L.Element {
    return b.node(0, .{ .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 } }, .none, &.{
        try b.node(0, .{}, .{ .text = .{ .value = message, .size = 13, .tone = .muted } }, &.{}),
    });
}

test "pages are the Inspector, the Console, the Hierarchy, Assets, Animation, the UI Designer's three, the Asset Preview, the 2D Scene and the plugin panels, in that order" {
    const plugin_panels = [_]EditorPanel{ .{ .title = "Stats" }, .{ .title = "Level" } };
    try std.testing.expectEqual(@as(?usize, 0), pageOf(@backingInt(Panel.inspector), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 1), pageOf(@backingInt(Panel.console), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 2), pageOf(@backingInt(Panel.hierarchy), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 3), pageOf(@backingInt(Panel.assets), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 4), pageOf(@backingInt(Panel.animation), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 5), pageOf(@backingInt(Panel.ui_designer), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 7), pageOf(@backingInt(Panel.ui_properties), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 8), pageOf(@backingInt(Panel.asset_preview), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 9), pageOf(@backingInt(Panel.scene_2d), &plugin_panels));
    try std.testing.expectEqual(@as(?usize, 11), pageOf(plugin_first + 1, &plugin_panels));
    try std.testing.expectEqual(@as(?usize, null), pageOf(@backingInt(Panel.scene), &plugin_panels));
    try std.testing.expectEqualStrings("Level", panelTitle(plugin_first + 1, &plugin_panels));
    try std.testing.expectEqualStrings("Console", panelTitle(@backingInt(Panel.console), &plugin_panels));
}

test "a copy's id reads back as its panel and copy, clear of the built-in and plugin ids" {
    try std.testing.expectEqual(@as(u32, @backingInt(Panel.scene)), copyId(.scene, 0));
    for (copyable) |panel| for (1..max_copies) |copy| {
        const id = copyId(panel, @intCast(copy));
        try std.testing.expect(id > @backingInt(Panel.scene_2d) and id < plugin_first);
        try std.testing.expectEqual(Copy{ .panel = panel, .copy = @intCast(copy) }, copyOf(id).?);
        try std.testing.expectEqualStrings(panel.title(), panelTitle(id, &.{}));
    };
    try std.testing.expect(copyOf(plugin_first) == null);
}

test "only the live copy is drawn, and the UI Designer's three go live together" {
    const live = Live{ .scene = 2, .ui = 1 };
    try std.testing.expect(live.shows(copyId(.scene, 2)));
    try std.testing.expect(!live.shows(copyId(.scene, 0)));
    try std.testing.expect(live.shows(copyId(.ui_tree, 1)) and live.shows(copyId(.ui_properties, 1)));
    try std.testing.expect(live.shows(@backingInt(Panel.inspector)));
    try std.testing.expectEqual(Copy{ .panel = .scene, .copy = 2 }, showHereOf(show_here_first + copyId(.scene, 2)).?);
}
