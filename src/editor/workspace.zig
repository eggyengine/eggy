//! The editor's windows: the main window's drawn title bar holding the menus (as in Weeoui's
//! gallery) over dockable panels, and one tree per panel popped out into its own OS window.
//! Builds and draws each window's tree, and routes each window's input to the menus and dock.
const std = @import("std");
const eggy = @import("eggy");
const weeoui_sdl3 = @import("weeoui_sdl3");
const ui = eggy.ui;
const L = ui.Layout;
const widgets = ui.widgets;
const titlebar = ui.titlebar;
const dock = ui.dock;
const menus = @import("menus.zig");
const panels = @import("panels.zig");
const Panel = panels.Panel;

/// Which OS window a tree, event or panel belongs to: 0 is the main window (and the panels
/// floating inside it), 1 + i is the dock's pop-out window i.
pub const Slot = usize;
pub const main_slot: Slot = 0;
const slot_count = 1 + dock.max_windows;

pub fn windowSlot(index: usize) Slot {
    return 1 + index;
}

/// What a pointer or key event meant to the workspace.
pub const Outcome = union(enum) {
    /// Not on the workspace's own controls: pass it on to the Inspector's UI.
    ignored,
    handled,
    /// File > Quit.
    quit,
    /// A button on the main window's title bar.
    window: titlebar.Button,
};

/// Title bar ids, kept below `dock.first_id`.
const titlebar_first: u32 = 0x5400_0000;

pub const Workspace = struct {
    dock: dock.DockSpace,
    menubar: menus.Menubar = .{},
    /// The desktop's title bar button order and style, for the main title bar and floating panels.
    buttons: titlebar.Layout,
    /// Whether the main window draws its own title bar (the menus share its row); else the
    /// menus get a row of their own under the system's.
    custom_frame: bool = true,
    /// The main window's title bar state, for its buttons' look.
    window_state: titlebar.State = .{},
    pointer: ui.Vec2 = .{ .x = -1, .y = -1 },
    pointer_slot: Slot = main_slot,
    /// Each window's tree from the last `build`; lives in `arena` until the next one.
    roots: [slot_count]?*L.Element = @splat(null),
    /// The panels plugins add (`eggy.plugins.Set.editor_panels`); panel i has dock id
    /// `panels.plugin_first + i`.
    plugin_panels: []const eggy.plugins.EditorPanel,
    /// Where the Scene and pages are, for the editor to draw into.
    placed: panels.Placements = .{},
    arena: std.heap.ArenaAllocator,
    /// The shell's vertices, then the window's finished vertices with the pages spliced in.
    shell: std.ArrayList(ui.Vertex) = .empty,
    vertices: std.ArrayList(ui.Vertex) = .empty,

    pub fn init(gpa: std.mem.Allocator, buttons: titlebar.Layout, plugin_panels: []const eggy.plugins.EditorPanel) !Workspace {
        if (plugin_panels.len > panels.max_pages - 1) return error.TooManyPluginPanels;
        var self = Workspace{ .dock = undefined, .buttons = buttons, .plugin_panels = plugin_panels, .arena = .init(gpa) };
        try self.resetLayout();
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        self.shell.deinit(self.arena.child_allocator);
        self.vertices.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    /// The default arrangement: hierarchy left, inspector right (plugin panels as tabs beside it),
    /// console and assets below the scene.
    fn resetLayout(self: *Workspace) !void {
        self.dock = dock.DockSpace.init();
        self.dock.buttons = self.buttons;
        try self.dock.add(@intFromEnum(Panel.scene), null, .center);
        try self.dock.add(@intFromEnum(Panel.hierarchy), @intFromEnum(Panel.scene), .left);
        self.splitRatio(.hierarchy, 0.2);
        try self.dock.add(@intFromEnum(Panel.inspector), @intFromEnum(Panel.scene), .right);
        self.splitRatio(.inspector, 0.72);
        try self.dock.add(@intFromEnum(Panel.console), @intFromEnum(Panel.scene), .bottom);
        self.splitRatio(.console, 0.7);
        try self.dock.add(@intFromEnum(Panel.assets), @intFromEnum(Panel.console), .center);
        for (0..self.plugin_panels.len) |i| try self.dock.add(panels.plugin_first + @as(u32, @intCast(i)), @intFromEnum(Panel.inspector), .center);
        _ = self.dock.activate(dock.first_id + @intFromEnum(Panel.inspector)); // the Inspector's tab stays in front
    }

    /// Size the split that `panel`'s stack was just added to: `ratio` of it goes to the first side.
    fn splitRatio(self: *Workspace, panel: Panel, ratio: f32) void {
        const stack = self.dock.nodeOf(@intFromEnum(panel)) orelse return;
        const parent = self.dock.nodes[stack].parent;
        if (parent < self.dock.nodes.len) self.dock.nodes[parent].ratio = ratio;
    }

    /// The title for pop-out window `index`: its active panel's.
    pub fn windowTitle(self: *const Workspace, index: usize) [:0]const u8 {
        const window = self.dock.windows[index] orelse return "Panel";
        const node = self.dock.nodes[window.root];
        if (node.count == 0) return "Panel";
        return panels.panelTitle(node.panels[node.active], self.plugin_panels);
    }

    /// Build and lay out every window's tree: the main window over `viewport`, and each pop-out
    /// window `i` over `window_viewports[i]` (null until the editor has opened it).
    pub fn build(self: *Workspace, viewport: ui.Rect, window_viewports: [dock.max_windows]?ui.Rect, font: *const ui.Font) !void {
        // Read the hovered menu item before the trees it's found in go away.
        const hot = self.controlAt(main_slot, self.pointer.x, self.pointer.y);
        self.roots = @splat(null);
        self.placed = .{};
        _ = self.arena.reset(.retain_capacity);
        const b = L.Builder{ .allocator = self.arena.allocator() };

        // The main window: menus on the drawn title bar (untitled; the OS still names the window
        // for the taskbar), or under the system's; panels below.
        const menu_list = try self.menubar.list(b.allocator, &self.dock, self.plugin_panels);
        const top_bar = if (self.custom_frame)
            try titlebar.barWithMenus(b, titlebar_first, 0, "", self.buttons, self.window_state, try widgets.titlebarMenubar(b, menu_list, self.menubar.open, hot, 0))
        else blk: {
            const bar = try widgets.windowMenubar(b, menu_list, self.menubar.open, hot, 0);
            bar.style.width = viewport.w;
            break :blk bar;
        };
        const bar_height = if (self.custom_frame) titlebar.height else widgets.window_menubar_height;
        const dock_rect = ui.Rect{ .x = viewport.x, .y = viewport.y + bar_height, .w = viewport.w, .h = @max(0, viewport.h - bar_height) };
        const docked = try self.dock.build(b, .main, dock_rect, panels.Provider{ .placements = &self.placed, .slot = main_slot, .plugin_panels = self.plugin_panels });
        const main = try b.node(0, .{ .width = viewport.w, .height = viewport.h, .direction = .column }, .none, &.{ top_bar, docked });
        main.layout(viewport, font);
        self.roots[main_slot] = main;

        // Each pop-out window: its panels fill it, under the system's title bar.
        for (window_viewports, 0..) |window_viewport, i| {
            const area = window_viewport orelse continue;
            if (self.dock.windows[i] == null) continue;
            const slot = windowSlot(i);
            const tree = try self.dock.build(b, .{ .window = @intCast(i) }, area, panels.Provider{ .placements = &self.placed, .slot = slot, .plugin_panels = self.plugin_panels });
            tree.layout(area, font);
            self.roots[slot] = tree;
        }
    }

    /// Where the main window's drawn title bar is, for the OS to move and resize the window by it.
    pub fn titlebarFrame(self: *const Workspace) weeoui_sdl3.Frame {
        var frame = weeoui_sdl3.Frame{ .popup_open = self.menubar.open != 0 };
        const root = self.roots[main_slot] orelse return frame;
        frame.bar = (root.find(titlebar.id(titlebar_first, 0, .bar)) orelse return frame).bounds;
        inline for (.{ .close, .minimize, .maximize }) |part| if (root.find(titlebar.id(titlebar_first, 0, part))) |button| {
            frame.buttons[frame.button_count] = button.bounds;
            frame.button_count += 1;
        };
        // The menus sharing the bar take presses instead of dragging the window.
        if (root.find(@intFromEnum(menus.Menu.file))) |first| if (root.find(@intFromEnum(menus.Menu.help))) |last| {
            frame.controls = .{ .x = first.bounds.x, .y = first.bounds.y, .w = last.bounds.x + last.bounds.w - first.bounds.x, .h = first.bounds.h };
        };
        return frame;
    }

    pub const Drawn = struct {
        vertices: []const ui.Vertex,
        /// Draw `vertices[0..scene_at]`, then the scene texture into the Scene panel, then the
        /// rest, so whatever covers the Scene panel (menus, floating panels) stays on top.
        scene_at: usize,
    };

    /// Paint window `slot`'s tree from the last `build`: its background, panels and popups, with
    /// each page's UI (`pages[p]`, empty for pages not in this window) spliced in where that page
    /// was painted. The result stays valid until the next `draw`.
    pub fn draw(self: *Workspace, slot: Slot, style: *const ui.Context, pages: []const []const ui.Vertex) !Drawn {
        const root = self.roots[slot] orelse return .{ .vertices = &.{}, .scene_at = 0 };
        const gpa = self.arena.child_allocator;

        // The window's background, the docked panels, then the popups in their layer order.
        if (self.shell.capacity == 0) try self.shell.ensureTotalCapacity(gpa, 4096);
        const shell = while (true) : (try self.shell.ensureTotalCapacity(gpa, self.shell.capacity * 2)) {
            const buffer = self.shell.allocatedSlice();
            self.placed.scene_mark = null;
            self.placed.page_marks = @splat(null);
            var c = ui.Canvas.init(buffer, style.font);
            c.theme = style.theme;
            c.pixel_scale = style.pixel_scale;
            c.srgb_target = style.srgb_target;
            c.hot_id = if (slot == self.pointer_slot) self.controlAt(slot, self.pointer.x, self.pointer.y) else 0;
            c.rect(root.bounds, c.theme.background) catch continue;
            root.drawWithoutOverlays(&c) catch |err| switch (err) {
                error.OutOfVertices => continue,
                else => return err,
            };
            root.drawOverlays(&c) catch |err| switch (err) {
                error.OutOfVertices => continue,
                else => return err,
            };
            break buffer[0..c.len];
        };

        // Splice each page's UI in at its panel, after whatever was painted beneath it, and note
        // where the scene's mark ends up.
        const Splice = struct { at: usize, page: usize };
        var splices: [panels.max_pages]Splice = undefined;
        var count: usize = 0;
        var total = shell.len;
        for (self.placed.page_marks, 0..) |mark, page| if (mark) |at| if (page < pages.len) {
            splices[count] = .{ .at = at, .page = page };
            count += 1;
            total += pages[page].len;
        };
        std.mem.sort(Splice, splices[0..count], {}, struct {
            fn before(_: void, a: Splice, b: Splice) bool {
                return a.at < b.at;
            }
        }.before);
        self.vertices.clearRetainingCapacity();
        try self.vertices.ensureTotalCapacity(gpa, total);
        var scene_at: ?usize = null;
        var from: usize = 0;
        for (splices[0..count]) |splice| {
            if (self.placed.scene_mark) |mark| if (scene_at == null and mark < splice.at) {
                scene_at = self.vertices.items.len + (mark - from);
            };
            self.vertices.appendSliceAssumeCapacity(shell[from..splice.at]);
            self.vertices.appendSliceAssumeCapacity(pages[splice.page]);
            from = splice.at;
        }
        if (self.placed.scene_mark) |mark| if (scene_at == null) {
            scene_at = self.vertices.items.len + (mark - from);
        };
        self.vertices.appendSliceAssumeCapacity(shell[from..]);
        return .{ .vertices = self.vertices.items, .scene_at = scene_at orelse self.vertices.items.len };
    }

    /// Route an input event from window `slot`, in that window's coordinates.
    pub fn handle(self: *Workspace, slot: Slot, event: ui.input.Event) Outcome {
        switch (event) {
            .pointer_move => |p| {
                self.pointer = p;
                self.pointer_slot = slot;
                // Tabs only drag within the main window; pop-outs' coordinates are their own.
                if (slot != main_slot or !self.dock.dragging()) return .ignored;
                self.dock.dragTo(p.x, p.y);
                return .handled;
            },
            .pointer_down => |down| {
                self.pointer = down.position;
                self.pointer_slot = slot;
                const id = self.controlAt(slot, down.position.x, down.position.y);
                switch (down.button) {
                    .middle => return if (self.dock.closeTab(id)) .handled else .ignored,
                    .right => return .ignored,
                    .left => {},
                }
                if (slot == main_slot) {
                    if (titlebarButton(id)) |button| return .{ .window = button };
                    if (self.menubar.press(id)) |action| return self.run(action);
                }
                if (self.dock.press(id, down.position.x, down.position.y)) return .handled;
                return if (self.dock.dismissMenu()) .handled else .ignored;
            },
            .pointer_up => |up| {
                if (slot != main_slot or !self.dock.dragging()) return .ignored;
                self.dock.release(up.position.x, up.position.y);
                return .handled;
            },
            .key_down => |key| if (key.key == .escape) {
                if (self.menubar.open != 0) {
                    self.menubar.open = 0;
                    return .handled;
                }
                if (self.dock.dismissMenu()) return .handled;
            },
            else => {},
        }
        return .ignored;
    }

    fn titlebarButton(id: u32) ?titlebar.Button {
        inline for (.{ .close, .minimize, .maximize }) |part| {
            if (id == titlebar.id(titlebar_first, 0, part)) return @field(titlebar.Button, @tagName(part));
        }
        return null;
    }

    /// Carry out what a menu press asked for.
    fn run(self: *Workspace, action: menus.Action) Outcome {
        switch (action) {
            .handled => {},
            .toggle_panel => |panel| self.togglePanel(panel),
            .command => |command| switch (command) {
                .quit => return .quit,
                .reset_layout => self.resetLayout() catch |err| std.log.warn("cannot reset the layout: {t}", .{err}),
                // ponytail: stubs until the editor has projects, undo history and settings.
                else => std.log.info("{t}: not implemented yet", .{command}),
            },
        }
        return .handled;
    }

    fn togglePanel(self: *Workspace, panel: u32) void {
        if (self.dock.nodeOf(panel) != null) return self.dock.remove(panel);
        self.dock.add(panel, null, .center) catch |err| std.log.warn("cannot reopen panel {d}: {t}", .{ panel, err });
    }

    /// The topmost interactive element under (x, y) in window `slot`'s last tree, or 0.
    fn controlAt(self: *const Workspace, slot: Slot, x: f32, y: f32) u32 {
        const root = self.roots[slot] orelse return 0;
        var best = Hit{};
        best.visit(root, 0, x, y);
        return best.id;
    }
};

/// Hit testing as Weeoui's `Context` does it: the highest overlay layer wins, then the smallest box.
const Hit = struct {
    id: u32 = 0,
    z: i16 = std.math.minInt(i16),
    area: f32 = std.math.inf(f32),

    fn visit(self: *Hit, element: *const L.Element, layer: i16, x: f32, y: f32) void {
        const z = if (element.overlay != null) element.style.z_index else layer;
        const rect = element.bounds.intersection(element.clip);
        if (element.id != 0 and rect.contains(x, y) and (z > self.z or (z == self.z and rect.w * rect.h < self.area))) {
            self.* = .{ .id = element.id, .z = z, .area = rect.w * rect.h };
        }
        for (element.children) |child| self.visit(child, z, x, y);
    }
};

const test_plugin_panels = [_]eggy.plugins.EditorPanel{.{ .title = "Stats" }};

fn testWorkspace() !Workspace {
    return Workspace.init(std.testing.allocator, titlebar.Layout.default(.linux), &test_plugin_panels);
}

test "the default layout docks every panel" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    for (std.enums.values(Panel)) |panel| try std.testing.expect(workspace.dock.nodeOf(@intFromEnum(panel)) != null);
}

test "the Window menu closes and reopens a panel" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    const console = @intFromEnum(Panel.console);
    _ = workspace.run(.{ .toggle_panel = console });
    try std.testing.expect(workspace.dock.nodeOf(console) == null);
    _ = workspace.run(.{ .toggle_panel = console });
    try std.testing.expect(workspace.dock.nodeOf(console) != null);
}

test "File > Quit asks the editor to quit" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    try std.testing.expectEqual(Outcome.quit, workspace.run(.{ .command = .quit }));
}

test "a popped-out panel's window is titled after it" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    try workspace.dock.detach(@intFromEnum(Panel.console));
    const index = for (workspace.dock.windows, 0..) |window, i| {
        if (window != null) break i;
    } else return error.NoWindow;
    try std.testing.expectEqualStrings("Console", workspace.windowTitle(index));
}

test "plugin panels dock as tabs beside the Inspector, which stays in front" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    const inspector = @intFromEnum(Panel.inspector);
    try std.testing.expectEqual(workspace.dock.nodeOf(inspector), workspace.dock.nodeOf(panels.plugin_first));
    try std.testing.expect(workspace.dock.isVisible(inspector));
    try workspace.dock.detach(panels.plugin_first);
    try std.testing.expectEqualStrings("Stats", workspace.windowTitle(0));
}
