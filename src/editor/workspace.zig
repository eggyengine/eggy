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
const play_button = @import("play_button.zig");
const hit_test = @import("hit_test.zig");
const reload_button = @import("reload_button.zig");
const Panel = panels.Panel;
/// Eggy's version, from its `build.zig.zon`.
const eggy_version = @import("build_options").version;

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
    /// The play button: start the game (true) or stop it (false).
    play: bool,
    /// File > New Project.
    new_project,
    /// File > Open Project.
    open_project,
    /// File > Open Project with Developer Eggy (Open Project with Shift held): open a project
    /// linked to the Eggy codebase being developed.
    open_project_linked,
    /// Help > DevTools (F12): open or close the DevTools window.
    toggle_devtools,
    /// Edit > Preferences: open the Preferences window.
    preferences,
    /// File > Save (Ctrl+S): save the scene.
    save,
    /// Edit > Undo (Ctrl+Z) and Redo (Ctrl+Shift+Z, Ctrl+Y).
    undo,
    redo,
    /// File > Open Project Folder: show the project in the system's file manager.
    open_project_folder,
    /// File > Upgrade Editor: move the project to the newest Eggy.
    upgrade_editor,
    /// File > Link Developer Eggy (Upgrade Editor with Shift held): link the project to the
    /// Eggy codebase being developed.
    link_developer,
    /// The title bar's Reload: open the rebuilt editor, rebuilding it first if need be.
    reload,
};

/// The project the editor has open, for the status bar.
pub const Project = struct { name: []const u8, title: []const u8, dir: []const u8 };

/// How the build after refocusing went, for the status bar.
pub const BuildState = union(enum) {
    idle,
    /// Under way; what it is doing.
    building: []const u8,
    failed,
    /// Done, and the editor changed: Reload opens the new one.
    ready,
};

/// How long a toast stays.
const toast_ms = 2500;

/// How long the pointer rests on a title bar button before its tooltip shows.
const tooltip_delay_ms = 500;

/// Height of the status bar along the main window's bottom.
const status_height: f32 = 24;

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
    /// Whether the game is playing, which turns the play button into a stop button.
    playing: bool = false,
    /// The project open in this editor, shown in the status bar; its text belongs to the editor.
    project: ?Project = null,
    /// Help > DevTools' tools while open, for their highlight over the main window.
    devtools: ?*ui.devtools.Devtools = null,
    /// The rebuild's state, shown in the status bar; its text must last until `draw`.
    build_state: BuildState = .idle,
    /// Which Eggy this editor was built with, for the status bar: a packaged engine's short
    /// version or the codebase it is linked to. Its text belongs to the editor.
    engine_label: ?[]const u8 = null,
    /// The open scene's file name, for the status bar; null with none open. Its text belongs to
    /// the editor.
    scene_name: ?[]const u8 = null,
    /// Whether the world has changes the open scene doesn't: the status bar marks it with `*`.
    scene_unsaved: bool = false,
    /// A short note in the window's bottom-right corner (say, "Saved"), until `toast_until_ms`.
    toast_buffer: [96]u8 = undefined,
    toast_len: usize = 0,
    toast_until_ms: u64 = 0,
    /// Whether a newer engine than the project's is unpacked, for File > Upgrade Editor.
    can_upgrade: bool = false,
    /// Whether the project can be linked to the Eggy codebase being developed.
    can_link: bool = false,
    /// Whether an Eggy codebase being developed is known, for Open Project with Developer Eggy.
    developer_known: bool = false,
    /// Whether Shift is held, which turns Open Project and Upgrade Editor into their
    /// developer-Eggy versions.
    shift_held: bool = false,
    pointer: ui.Vec2 = .{ .x = -1, .y = -1 },
    pointer_slot: Slot = main_slot,
    /// Milliseconds since the editor started, set before each `build`, for tooltips' delay.
    time_ms: u64 = 0,
    /// The main window's control under the pointer, and since when, for tooltips.
    hover_id: u32 = 0,
    hover_since_ms: u64 = 0,
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

    /// Show `plugin_panels`, the game's panels after it loaded or was swapped (they must last
    /// until the next call): panels it no longer has close, and new ones dock as tabs beside the
    /// Inspector, which stays in front.
    pub fn setPluginPanels(self: *Workspace, plugin_panels: []const eggy.plugins.EditorPanel) void {
        const max_plugin_panels = panels.max_pages - panels.first_plugin_page;
        const shown = plugin_panels[0..@min(plugin_panels.len, max_plugin_panels)];
        const old_len = self.plugin_panels.len;
        // Panels it no longer has go, wherever they are (a restored layout may hold any).
        for (shown.len..max_plugin_panels) |i| self.dock.remove(panels.plugin_first + @as(u32, @intCast(i)));
        self.plugin_panels = shown;
        // New ones dock beside the Inspector, unless a restored layout already placed them.
        var added = false;
        if (shown.len > old_len) for (old_len..shown.len) |i| {
            const id = panels.plugin_first + @as(u32, @intCast(i));
            if (self.dock.nodeOf(id) != null) continue;
            self.dock.add(id, @intFromEnum(Panel.inspector), .center) catch |err| std.log.warn("cannot dock the game's panel {s}: {t}", .{ shown[i].title, err });
            added = true;
        };
        if (added) _ = self.dock.activate(dock.first_id + @intFromEnum(Panel.inspector));
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
        // The Inspector's and the Console's tabs in front.
        _ = self.dock.activate(dock.first_id + @intFromEnum(Panel.inspector));
        _ = self.dock.activate(dock.first_id + @intFromEnum(Panel.console));
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
        const hot = if (self.pointer_slot == main_slot) self.controlAt(main_slot, self.pointer.x, self.pointer.y) else 0;
        self.roots = @splat(null);
        self.placed = .{};
        _ = self.arena.reset(.retain_capacity);
        const b = L.Builder{ .allocator = self.arena.allocator() };

        // The main window: menus on the drawn title bar (untitled; the OS still names the window
        // for the taskbar), or under the system's; panels below.
        // Menus left of the centred play button; those that don't fit fold into "...".
        var menu_room = (viewport.w - play_button.width) / 2 - 16;
        if (self.custom_frame) for (self.buttons.left) |button| {
            // ponytail: estimates the left-hand window buttons' width; measure them if menus overlap on macOS.
            if (button != null) menu_room -= 32;
        };
        const project_state = menus.ProjectState{ .open = self.project != null, .can_upgrade = self.can_upgrade, .can_link = self.can_link, .developer_known = self.developer_known, .shift_held = self.shift_held };
        const menu_list = try self.menubar.list(b.allocator, &self.dock, self.plugin_panels, project_state, menus.shownMenus(font, menu_room));
        const menubar = if (self.custom_frame)
            try widgets.titlebarMenubar(b, menu_list, self.menubar.open, hot, self.menubar.open_submenu)
        else
            try widgets.windowMenubar(b, menu_list, self.menubar.open, hot, self.menubar.open_submenu);
        try menus.drawMoreAsDots(b, menubar);
        const top_bar = if (self.custom_frame)
            try titlebar.barWithMenus(b, titlebar_first, 0, "", self.buttons, self.window_state, menubar)
        else blk: {
            menubar.style.width = viewport.w;
            break :blk menubar;
        };
        const bar_height = if (self.custom_frame) titlebar.height else widgets.window_menubar_height;
        const dock_rect = ui.Rect{ .x = viewport.x, .y = viewport.y + bar_height, .w = viewport.w, .h = @max(0, viewport.h - bar_height - status_height) };
        const docked = try self.dock.build(b, .main, dock_rect, panels.Provider{ .placements = &self.placed, .slot = main_slot, .plugin_panels = self.plugin_panels });
        const play = try play_button.element(b, self.playing, viewport.x, viewport.w, bar_height);
        const status = try self.statusBar(b, viewport.w);
        var main_children: std.ArrayList(*L.Element) = .empty;
        try main_children.appendSlice(b.allocator, &.{ top_bar, docked, status, play });
        const reload = if (self.project != null) try reload_button.element(b, self.build_state == .ready, viewport.x, viewport.w, bar_height) else null;
        if (reload) |button| try main_children.append(b.allocator, button);
        // A tooltip for the play or Reload button once the pointer has rested on it a moment.
        if (hot != self.hover_id) {
            self.hover_id = hot;
            self.hover_since_ms = self.time_ms;
        }
        if (self.time_ms -| self.hover_since_ms >= tooltip_delay_ms) if (self.tooltipText(hot)) |text| {
            const button = if (hot == play_button.id) play else reload orelse unreachable;
            // Sized to its text: an overlay in this column would otherwise stretch across it.
            const tooltip = try widgets.tooltipAt(b, button, text);
            tooltip.style.width = font.measure(text, 13) + 20;
            try main_children.append(b.allocator, tooltip);
        };
        if (self.time_ms < self.toast_until_ms) try main_children.append(b.allocator, try self.toastElement(b, viewport, font));
        const main = try b.node(0, .{ .width = viewport.w, .height = viewport.h, .direction = .column }, .none, main_children.items);
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

    /// Show `message` in the bottom-right corner for a couple of seconds.
    pub fn toast(self: *Workspace, message: []const u8) void {
        self.toast_len = @min(message.len, self.toast_buffer.len);
        @memcpy(self.toast_buffer[0..self.toast_len], message[0..self.toast_len]);
        self.toast_until_ms = self.time_ms + toast_ms;
    }

    /// The toast: a small note floating just above the status bar, at the right.
    fn toastElement(self: *const Workspace, b: L.Builder, viewport: ui.Rect, font: *const ui.Font) !*L.Element {
        const message = self.toast_buffer[0..self.toast_len];
        const width = font.measure(message, 12) + 24;
        const note = try b.node(0, .{ .width = width, .height = 28, .padding = .{ .left = 12, .right = 12 }, .align_items = .center, .direction = .row, .z_index = 260 }, .{ .surface = .tooltip }, &.{
            try b.node(0, .{}, .{ .text = .{ .value = message, .size = 12 } }, &.{}),
        });
        note.overlay = .{ .point = .init(viewport.x + viewport.w - width - 12, viewport.y + viewport.h - status_height - 28 - 10) };
        note.accessibility = .{ .role = .status, .label = message };
        return note;
    }

    /// What the title bar button `id` (play or Reload) does, for its tooltip; null for others.
    fn tooltipText(self: *const Workspace, id: u32) ?[]const u8 {
        if (id == play_button.id) return if (self.playing) "Stop" else "Play";
        if (id == reload_button.id) return if (self.build_state == .ready) "Reload (ready)" else "Reload";
        return null;
    }

    /// The bar along the main window's bottom: which project is open (and where), the rebuild,
    /// whether the game is playing, and Eggy's version.
    fn statusBar(self: *const Workspace, b: L.Builder, width: f32) !*L.Element {
        var children: std.ArrayList(*L.Element) = .empty;
        const text = struct {
            fn make(builder: L.Builder, value: []const u8, tone: @FieldType(L.Text, "tone")) !*L.Element {
                return builder.node(0, .{}, .{ .text = .{ .value = value, .size = 12, .tone = tone } }, &.{});
            }
        }.make;
        if (self.project) |project| {
            try children.append(b.allocator, try text(b, project.title, .foreground));
            const scene_label = if (self.scene_name) |name|
                try std.fmt.allocPrint(b.allocator, "{s}{s}", .{ name, if (self.scene_unsaved) "*" else "" })
            else if (self.scene_unsaved) "Unsaved scene*" else "No scene open: open one in Assets";
            try children.append(b.allocator, try text(b, scene_label, if (self.scene_name != null or self.scene_unsaved) .foreground else .muted));
            try children.append(b.allocator, try text(b, project.dir, .muted));
        } else try children.append(b.allocator, try text(b, "No project open: File > New Project or Open Project", .muted));
        try children.append(b.allocator, try b.node(0, .{ .grow = 1 }, .none, &.{}));
        switch (self.build_state) {
            .idle => {},
            .building => |detail| try children.append(b.allocator, try text(b, try std.fmt.allocPrint(b.allocator, "Building: {s}", .{detail}), .muted)),
            .failed => try children.append(b.allocator, try text(b, "Build failed: see the Console", .foreground)),
            .ready => try children.append(b.allocator, try text(b, "Rebuilt", .foreground)),
        }
        if (self.playing) try children.append(b.allocator, try text(b, "Playing", .foreground));
        const version = if (self.engine_label) |label|
            try std.fmt.allocPrint(b.allocator, "Eggy {s} ({s})", .{ eggy_version, label })
        else
            "Eggy " ++ eggy_version;
        try children.append(b.allocator, try text(b, version, .muted));
        if (self.can_upgrade) try children.append(b.allocator, try text(b, "Upgrade available: File > Upgrade Editor", .foreground));
        const bar = try b.node(0, .{ .width = width, .height = status_height, .direction = .row, .align_items = .center, .gap = 10, .padding = .{ .left = 10, .right = 10 } }, .{ .surface = .sidebar }, children.items);
        bar.accessibility = .{ .role = .group, .label = "Status" };
        return bar;
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
        var controls: ?ui.Rect = null;
        for (std.enums.values(menus.Menu)) |menu| if (root.find(@intFromEnum(menu))) |trigger| {
            const r = trigger.bounds;
            controls = if (controls) |so_far| .{ .x = so_far.x, .y = so_far.y, .w = r.x + r.w - so_far.x, .h = so_far.h } else r;
        };
        if (controls) |rect| frame.controls = rect;
        // The play and Reload buttons float on the bar, and take presses too.
        for ([_]u32{ play_button.id, reload_button.id }) |id| if (root.find(id)) |button| {
            frame.extra_controls[frame.extra_count] = button.bounds;
            frame.extra_count += 1;
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
            // DevTools' highlight of the element inspected, over everything. It lets go of the
            // page it was given, so a retry hands it over again.
            if (slot == main_slot) if (self.devtools) |tools| {
                tools.page = root;
                tools.highlight(&c, gpa) catch |err| switch (err) {
                    error.OutOfVertices => continue,
                    else => return err,
                };
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
                if (slot == main_slot and self.menubar.hover(self.controlAt(slot, p.x, p.y))) return .handled;
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
                    if (id == reload_button.id) return .reload;
                    if (id == play_button.id) {
                        self.playing = !self.playing;
                        return .{ .play = self.playing };
                    }
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
            .key_down => |key| {
                if (key.key == .escape) {
                    if (self.menubar.open != 0) {
                        self.menubar.open = 0;
                        return .handled;
                    }
                    if (self.dock.dismissMenu()) return .handled;
                }
                // The menus' shortcuts.
                if (key.key == .f12 and !key.repeat) return .toggle_devtools;
                if (key.repeat or !(key.modifiers.control or key.modifiers.super)) return .ignored;
                const command: menus.Command = switch (key.key) {
                    .n => .new_project,
                    .o => .open_project,
                    .s => .save,
                    .q => .quit,
                    .z => if (key.modifiers.shift) .redo else .undo,
                    .y => .redo,
                    else => return .ignored,
                };
                return self.run(.{ .command = command });
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
                .new_project => return .new_project,
                .open_project => return .open_project,
                .open_project_linked => return .open_project_linked,
                .open_project_folder => return .open_project_folder,
                .upgrade_editor => return .upgrade_editor,
                .link_developer => return .link_developer,
                .devtools => return .toggle_devtools,
                .preferences => return .preferences,
                .save => return .save,
                .undo => return .undo,
                .redo => return .redo,
                .reset_layout => self.resetLayout() catch |err| std.log.warn("cannot reset the layout: {t}", .{err}),
                // ponytail: a stub until there is an About window.
                .about => std.log.info("about: not implemented yet", .{}),
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
        return hit_test.controlAt(root, x, y);
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

test "the play button turns into a stop button and back" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try workspace.build(viewport, @splat(null), &font);
    const play = workspace.roots[main_slot].?.find(play_button.id).?;
    try std.testing.expectApproxEqAbs(viewport.w / 2, play.bounds.x + play.bounds.w / 2, 0.5);
    try std.testing.expect(workspace.titlebarFrame().extra_count == 1);
    const press = ui.input.Event{ .pointer_down = .{ .position = play.bounds.center(), .button = .left, .clicks = 1 } };
    try std.testing.expectEqual(Outcome{ .play = true }, workspace.handle(main_slot, press));
    try std.testing.expectEqual(Outcome{ .play = false }, workspace.handle(main_slot, press));
}

test "the menus' shortcuts run their commands" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    const press = struct {
        fn key(k: ui.input.Key, shift: bool) ui.input.Event {
            return .{ .key_down = .{ .key = k, .modifiers = .{ .control = true, .shift = shift }, .repeat = false } };
        }
    }.key;
    try std.testing.expectEqual(Outcome.quit, workspace.handle(main_slot, press(.q, false)));
    try std.testing.expectEqual(Outcome.new_project, workspace.handle(main_slot, press(.n, false)));
    try std.testing.expectEqual(Outcome.open_project, workspace.handle(main_slot, press(.o, false)));
    try std.testing.expectEqual(Outcome.redo, workspace.handle(main_slot, press(.z, true)));
    try std.testing.expectEqual(Outcome.undo, workspace.handle(main_slot, press(.z, false)));
    try std.testing.expectEqual(Outcome.ignored, workspace.handle(main_slot, press(.c, false)));
}

test "every menu trigger and row is hit where it is drawn" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 800 };
    for (std.enums.values(menus.Menu)) |menu| {
        if (menu == .more) continue;
        workspace.menubar.open = @intFromEnum(menu);
        try workspace.build(viewport, @splat(null), &font);
        const root = workspace.roots[main_slot].?;
        const trigger = root.find(@intFromEnum(menu)).?;
        try std.testing.expectEqual(@intFromEnum(menu), workspace.controlAt(main_slot, trigger.bounds.center().x, trigger.bounds.center().y));
        // Pressable across the bar's height, not just over its label.
        try std.testing.expectEqual(@intFromEnum(menu), workspace.controlAt(main_slot, trigger.bounds.center().x, 2));
        if (menu != .view) try std.testing.expect(try expectRowsHit(&workspace, root) > 0);
    }
}

/// Check that each menu row under `element` is hit at its centre; returns how many there were.
fn expectRowsHit(workspace: *const Workspace, element: *const L.Element) !usize {
    var rows: usize = 0;
    for (element.children) |child| rows += try expectRowsHit(workspace, child);
    if (element.paint_kind != .menu_item or element.id == 0) return rows;
    const at = element.bounds.center();
    try std.testing.expectEqual(element.id, workspace.controlAt(main_slot, at.x, at.y));
    return rows + 1;
}

test "the game's panels follow it across swaps, and the Inspector stays in front" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    const inspector = @intFromEnum(Panel.inspector);
    const two = [_]eggy.plugins.EditorPanel{ .{ .title = "Stats" }, .{ .title = "Level" } };
    workspace.setPluginPanels(&two);
    try std.testing.expect(workspace.dock.nodeOf(panels.plugin_first + 1) != null);
    try std.testing.expect(workspace.dock.isVisible(inspector));
    workspace.setPluginPanels(&.{});
    try std.testing.expect(workspace.dock.nodeOf(panels.plugin_first) == null);
    try std.testing.expect(workspace.dock.nodeOf(panels.plugin_first + 1) == null);
}

test "the play button's tooltip shows once the pointer rests on it" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try workspace.build(viewport, @splat(null), &font);
    workspace.pointer = workspace.roots[main_slot].?.find(play_button.id).?.bounds.center();

    const tooltipShown = struct {
        fn f(element: *const L.Element) bool {
            if (element.paint_kind == .surface and element.paint_kind.surface == .tooltip) return true;
            for (element.children) |child| if (f(child)) return true;
            return false;
        }
    }.f;
    workspace.time_ms = 1000;
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expect(!tooltipShown(workspace.roots[main_slot].?));
    workspace.time_ms = 1000 + tooltip_delay_ms;
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expect(tooltipShown(workspace.roots[main_slot].?));
}

test "the save toast shows for a while, inside the window" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 640, .h = 480 };
    workspace.time_ms = 1000;
    workspace.toast("Saved main.scene.zon");
    try workspace.build(viewport, @splat(null), &font);
    const root = workspace.roots[main_slot].?;
    const note = root.children[root.children.len - 1];
    try std.testing.expectEqual(ui.Layout.Paint{ .surface = .tooltip }, note.paint_kind);
    try std.testing.expect(note.bounds.x + note.bounds.w <= viewport.w);
    workspace.time_ms = 1000 + toast_ms;
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expect(workspace.roots[main_slot].?.children[workspace.roots[main_slot].?.children.len - 1].paint_kind != .surface);
}
