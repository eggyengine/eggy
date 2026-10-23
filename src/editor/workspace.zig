//! The editor's windows: the main window's drawn title bar holding the menus (as in Weeoui's
//! gallery) over the workspace's tabs of dockable panels, and one tree per panel or tab popped
//! out into its own OS window. Builds and draws each window's tree, and routes each window's
//! input to the menus, tabs and dock.
const std = @import("std");
const eggy = @import("eggy");
const weeoui_sdl3 = @import("weeoui_sdl3");
const ui = eggy.ui;
const L = ui.Layout;
const widgets = ui.widgets;
const titlebar = ui.titlebar;
const dock = ui.dock;
const help_menu = @import("help_menu.zig");
const menus = @import("menus.zig");
const plugin_bars = @import("plugin_bars.zig");
const panels = @import("panels.zig");
const play_button = @import("play_button.zig");
const pause_button = @import("pause_button.zig");
const simulate_button = @import("simulate_button.zig");
const scene_view = @import("scene_view/scene_view.zig");
const hit_test = eggy.ui_hit_test;
const reload_button = @import("reload_button.zig");
const workspace_tabs = @import("workspace_tabs.zig");
const tab_bar = @import("tab_bar.zig");
const tab_drag = @import("tab_drag.zig");
const no_tabs = @import("no_tabs.zig");
const Panel = panels.Panel;
/// Eggy's version, from its `build.zig.zon`.
const eggy_version = @import("build_options").version;

/// Which OS window a tree, event or panel belongs to: 0 is the main window (and the panels
/// floating inside it), 1 + i is the dock's pop-out window i.
pub const Slot = usize;
pub const main_slot: Slot = 0;
const slot_count = 1 + dock.max_windows;

/// Convert a zero-based dock pop-out index into the editor host's window slot.
/// `index` must be below `ui.dock.max_windows`; main-window slot zero is never returned.
///
/// ```zig
/// const slot = workspace_zig.windowSlot(0);
/// std.debug.assert(slot == 1);
/// ```
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
    /// The Simulate button: start the game, seen through the Scene panel's own camera.
    simulate,
    /// The pause button, while playing: hold the game (true) or let it go on (false).
    pause: bool,
    /// A button floating over the Scene panel.
    scene_button: scene_view.toolbar.Button,
    /// File > New Project.
    new_project,
    /// File > Open Project.
    open_project,
    /// File > Open Project with Developer Eggy (Open Project with Shift held): open a project
    /// linked to the Eggy codebase being developed.
    open_project_linked,
    /// Help > DevTools (F12): open or close the DevTools window.
    toggle_devtools,
    /// Help > About Eggy.
    about,
    /// Edit > Preferences: open the Preferences window.
    preferences,
    /// File > Save (Ctrl+S): save the scene.
    save,
    /// File > Export: open the Export window.
    export_game,
    /// File > Project Settings: open Preferences on its Project section.
    project_settings,
    /// Edit > Plugins: open the Plugins window.
    plugins,
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
    plugin_command: usize,
    /// A plugin's menu row or status bar button.
    plugin_bar: eggy.plugins.EditorBarTarget,
    build_project,
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

/// A warning in the status bar: red text, cut short where it doesn't fit.
const WarningText = struct {
    text: []const u8,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const WarningText = @ptrCast(@alignCast(context));
        try c.textIn(r, self.text, 12, c.theme.destructive, .start);
    }
};

/// How long the Playing light stays on, then off.
const playing_blink_ms = 600;

/// The status bar's "Playing": red text after a red dot, lit or not.
const PlayingLight = struct {
    lit: bool,
    label: []const u8,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const PlayingLight = @ptrCast(@alignCast(context));
        const red = c.theme.destructive;
        const dot: f32 = 8;
        if (self.lit) try c.roundRect(.{ .x = r.x, .y = r.y + (r.h - dot) / 2, .w = dot, .h = dot }, red, dot / 2);
        try c.textIn(.{ .x = r.x + 14, .y = r.y, .w = r.w - 14, .h = r.h }, self.label, 12, red, .start);
    }
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
    /// The layouts side by side in the main window, each a tree of `dock`.
    tabs: workspace_tabs.Tabs = .{},
    /// The tab bar's popup open: the "+" menu, or a tab's menu.
    tab_popup: tab_bar.Popup = .none,
    /// A tab pressed on the bar while the pointer is still down, dragged once it moves.
    tab_press: ?tab_drag.TabDrag = null,
    /// The bar's tab something carried rests on, shown after a moment.
    spring: tab_drag.SpringLoad = .{},
    /// Which copy of the Scene, 2D Scene and UI Designer is drawn (one per tab can be open), and
    /// the main window's tree they last followed.
    live: panels.Live = .{},
    followed_root: u8 = 0xFF,
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
    /// Current Stop binding, supplied by the host for the titlebar tooltip.
    stop_tooltip: []const u8 = "Stop (Escape)",
    /// Whether play is paused, which lights the pause button.
    paused: bool = false,
    /// Whether the game runs as Simulate started it, rather than Play.
    simulating: bool = false,
    /// What floats over the Scene panel, set by the editor before each `build`.
    scene_overlay: scene_view.Overlay = .{},
    /// Why Play won't start, shown in the status bar while it won't (borrowed for the frame).
    play_warning: ?[]const u8 = null,
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
    /// `panels.pluginId` of its stable key.
    plugin_panels: []const eggy.plugins.EditorPanel,
    plugin_commands: []const eggy.plugins.EditorCommand = &.{},
    /// The plugins' menus and status bar entries, borrowed from the library like `plugin_panels`
    /// (see `setPluginBars`), and how the editor found them looking, set before each `build`.
    plugin_bars: plugin_bars.Bars = .{},
    bar_states: plugin_bars.States = .{},
    /// The plugin panels (by stable key, owned) this user has had, kept with the layout: only one not
    /// among them docks by itself, so a panel closed stays closed.
    seen_plugin_panels: std.ArrayList([]u8) = .empty,
    /// Where the Scene and pages are, for the editor to draw into.
    placed: panels.Placements = .{},
    arena: std.heap.ArenaAllocator,
    /// The shell's vertices, then the window's finished vertices with the pages spliced in.
    shell: std.ArrayList(ui.Vertex) = .empty,
    vertices: std.ArrayList(ui.Vertex) = .empty,

    /// Create the editor's default dock layout and owned tree/vertex storage.
    /// `buttons` copies desktop titlebar policy; plugin declarations are borrowed until replaced
    /// or deinit. No OS windows are created. Dock capacity/allocation errors propagate,
    /// including `TooManyPluginPanels` for an oversized declaration slice.
    ///
    /// ```zig
    /// var workspace = try Workspace.init(gpa, .default(.linux), &.{});
    /// defer workspace.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, buttons: titlebar.Layout, plugin_panels: []const eggy.plugins.EditorPanel) !Workspace {
        if (plugin_panels.len > panels.max_pages - 1) return error.TooManyPluginPanels;
        var self = Workspace{ .dock = undefined, .buttons = buttons, .plugin_panels = plugin_panels, .arena = .init(gpa) };
        try self.resetLayout();
        return self;
    }

    /// Free remembered panel identities, frame trees, and vertex buffers.
    /// Does not close host-owned OS windows or free borrowed plugin metadata/fonts.
    /// All returned tree/vertex pointers become invalid; do not reuse the workspace.
    ///
    /// ```zig
    /// workspace.deinit(); // Host teardown after closing its pop-out windows.
    /// ```
    pub fn deinit(self: *Workspace) void {
        for (self.seen_plugin_panels.items) |title| self.arena.child_allocator.free(title);
        self.seen_plugin_panels.deinit(self.arena.child_allocator);
        self.shell.deinit(self.arena.child_allocator);
        self.vertices.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    /// Show the game's plugin menus and status entries, after it loaded or was swapped (they
    /// must last until the next call). An open plugin menu closes, as its rows may not exist now.
    /// Editor-host reload hook; keeps no callbacks, only the borrowed declarations.
    ///
    /// ```zig
    /// workspace.setPluginBars(.{ .menus = game.menus, .status_items = game.status_items });
    /// ```
    pub fn setPluginBars(self: *Workspace, bars: plugin_bars.Bars) void {
        self.plugin_bars = if (bars.fits()) bars else blk: {
            std.log.err("plugins declare more menus, status items or rows than the editor's bars hold; none are shown", .{});
            break :blk .{};
        };
        self.bar_states = .{};
        self.menubar.open = 0;
        self.menubar.open_submenu = 0;
    }

    /// Show `plugin_panels`, the game's panels after it loaded or was swapped (they must last
    /// until the next call): panels it no longer has close, and new ones dock as tabs beside the
    /// Inspector, which stays in front.
    /// Editor-host reload hook: borrows the accepted prefix, capped to available page slots.
    /// Migrates old IDs and remembers seen keys; ID collisions disable plugin declarations
    /// and log an error, while allocation/dock failures log without throwing.
    ///
    /// ```zig
    /// workspace.setPluginPanels(game.panels); // Before unloading old borrowed declarations.
    /// ```
    pub fn setPluginPanels(self: *Workspace, plugin_panels: []const eggy.plugins.EditorPanel) void {
        const max_plugin_panels = panels.max_pages - panels.first_plugin_page;
        const shown = plugin_panels[0..@min(plugin_panels.len, max_plugin_panels)];
        for (shown, 0..) |panel, i| for (shown[0..i], 0..) |previous, j| {
            if (panels.pluginId(panel, i) == panels.pluginId(previous, j)) {
                std.log.err("editor panel keys {s} and {s} collide; choose distinct keys", .{ panel.key, previous.key });
                self.plugin_panels = &.{};
                return;
            }
        };
        // Carry the old index-based layout forward once, including closed-panel identities.
        if (self.plugin_panels.len == 0) for (shown, 0..) |panel, i| {
            const old = panels.plugin_first + @as(u32, @intCast(i));
            const new = panels.pluginId(panel, i);
            for (&self.dock.nodes) |*node| {
                if (node.kind != .tabs) continue;
                for (node.panels[0..node.count]) |*id| if (id.* == old) {
                    id.* = new;
                };
            }
            for (&self.dock.homes) |*home| {
                if (home.panel == old) home.panel = new;
                for (home.neighbours[0..home.count]) |*id| if (id.* == old) {
                    id.* = new;
                };
            }
        };
        for (self.dock.nodes) |node| {
            if (node.kind != .tabs) continue;
            for (node.panels[0..node.count]) |id| {
                if (id < panels.plugin_first) continue;
                const present = for (shown, 0..) |panel, index| {
                    if (panels.pluginId(panel, index) == id) break true;
                } else false;
                if (!present) self.dock.remove(id);
            }
        }
        self.plugin_panels = shown;
        // New ones dock beside the Inspector, unless a restored layout already placed them or
        // this user has had them before (and closed them, if they aren't there).
        var added = false;
        for (shown, 0..) |panel, i| {
            const id = panels.pluginId(panel, i);
            const key = if (panel.key.len != 0) panel.key else panel.title;
            const known = self.seenPanel(key) or self.seenPanel(panel.title);
            const gpa = self.arena.child_allocator;
            if (!self.seenPanel(key)) {
                const title = gpa.dupe(u8, key) catch |err| {
                    std.log.err("cannot keep editor panel identity: {t}", .{err});
                    continue;
                };
                self.seen_plugin_panels.append(gpa, title) catch |err| {
                    gpa.free(title);
                    std.log.err("cannot keep editor panel identity: {t}", .{err});
                    continue;
                };
            }
            if (self.dock.nodeOf(id) != null or known) continue;
            const inspector = panels.copyId(.inspector, self.live.inspector);
            self.dock.add(id, if (self.dock.nodeOf(inspector) != null) inspector else null, .center) catch |err| std.log.warn("cannot dock the game's panel {s}: {t}", .{ shown[i].title, err });
            added = true;
        }
        if (added) _ = self.dock.activate(dock.first_id + panels.copyId(.inspector, self.live.inspector));
    }

    fn seenPanel(self: *const Workspace, title: []const u8) bool {
        for (self.seen_plugin_panels.items) |seen| if (std.mem.eql(u8, seen, title)) return true;
        return false;
    }

    /// The default arrangement: hierarchy left, inspector right (the Asset Preview and plugin panels
    /// as tabs beside it),
    /// console, assets and animation below the scene. The UI Designer opens on its own
    /// (`showUiDesigner`).
    fn resetLayout(self: *Workspace) !void {
        self.dock = dock.DockSpace.init();
        self.dock.buttons = self.buttons;
        self.tabs = .init(&self.dock);
        self.live = .{};
        self.followed_root = 0xFF;
        try self.addScenePreset(0);
        try self.dock.add(@intFromEnum(Panel.asset_preview), @intFromEnum(Panel.inspector), .center);
        for (self.plugin_panels, 0..) |panel, i| try self.dock.add(panels.pluginId(panel, i), @intFromEnum(Panel.inspector), .center);
        // The Inspector's tab back in front of those that joined it.
        _ = self.dock.activate(dock.first_id + @intFromEnum(Panel.inspector));
    }

    /// The panels a 3D tab opens with, each its own copy.
    pub const scene_preset = [_]Panel{ .scene, .hierarchy, .inspector, .console, .assets, .animation };

    /// Lay out a 3D tab around copy `copy` of the Scene: the Hierarchy on its left, the Inspector
    /// on its right, and the Console, Assets and Animation below it, all copy `copy`. Lands in
    /// the main window's largest stack, so open and show the tab first.
    fn addScenePreset(self: *Workspace, copy: u8) !void {
        const scene = panels.copyId(.scene, copy);
        const inspector = panels.copyId(.inspector, copy);
        const console = panels.copyId(.console, copy);
        try self.dock.add(scene, null, .center);
        try self.dock.add(panels.copyId(.hierarchy, copy), scene, .left);
        self.splitRatio(panels.copyId(.hierarchy, copy), 0.2);
        try self.dock.add(inspector, scene, .right);
        self.splitRatio(inspector, 0.72);
        try self.dock.add(console, scene, .bottom);
        self.splitRatio(console, 0.7);
        try self.dock.add(panels.copyId(.assets, copy), console, .center);
        try self.dock.add(panels.copyId(.animation, copy), console, .center);
        // The Scene's, the Inspector's and the Console's tabs in front.
        for ([_]u32{ scene, inspector, console }) |id| _ = self.dock.activate(dock.first_id + id);
    }

    /// Size the split that panel `id`'s stack was just added to: `ratio` of it goes to the first side.
    fn splitRatio(self: *Workspace, id: u32, ratio: f32) void {
        const stack = self.dock.nodeOf(id) orelse return;
        const parent = self.dock.nodes[stack].parent;
        if (parent < self.dock.nodes.len) self.dock.nodes[parent].ratio = ratio;
    }

    /// The title for pop-out window `index`: its active panel's.
    /// `index` must be below `dock.max_windows`; absent/empty windows return static "Panel".
    /// The sentinel-terminated title borrows current plugin declarations or static storage.
    ///
    /// ```zig
    /// const title = workspace.windowTitle(popout_index);
    /// try popout.window.window.setTitle(title);
    /// ```
    pub fn windowTitle(self: *const Workspace, index: usize) [:0]const u8 {
        const window = self.dock.windows[index] orelse return "Panel";
        if (self.tabs.ofRoot(window.root)) |tab| return self.tabTitleZ(tab);
        const node = self.dock.nodes[window.root];
        if (node.count == 0) return "Panel";
        return panels.panelTitle(node.panels[node.active], self.plugin_panels);
    }

    /// Build and lay out every window's tree: the main window over `viewport`, and each pop-out
    /// window `i` over `window_viewports[i]` (null until the editor has opened it).
    /// Editor-host frame step: all rectangles are window-local logical points, and `font`
    /// must remain loaded through draw. Set time/style-dependent host fields beforehand.
    /// Invalidates previous trees/placements by resetting the arena; borrowed metadata must
    /// survive drawing. Allocation/layout-building errors propagate; no OS/GPU presentation occurs.
    ///
    /// ```zig
    /// workspace.time_ms = now_ms;
    /// try workspace.build(main_viewport, popout_viewports, context.font);
    /// // Build panel pages using workspace.placed, then call workspace.draw per window.
    /// ```
    pub fn build(self: *Workspace, viewport: ui.Rect, window_viewports: [dock.max_windows]?ui.Rect, font: *const ui.Font) !void {
        // Read the hovered menu item before the trees it's found in go away.
        const hot = if (self.pointer_slot == main_slot) self.controlAt(main_slot, self.pointer.x, self.pointer.y) else 0;
        self.springLoad();
        self.roots = @splat(null);
        self.placed = .{};
        _ = self.arena.reset(.retain_capacity);
        const b = L.Builder{ .allocator = self.arena.allocator() };
        self.followShownTab();

        // The main window: menus on the drawn title bar (untitled; the OS still names the window
        // for the taskbar), or under the system's; panels below.
        // Menus left of the centred play button; those that don't fit fold into "...".
        var menu_room = (viewport.w - play_button.width) / 2 - 16;
        if (self.custom_frame) for (self.buttons.left) |button| {
            // ponytail: estimates the left-hand window buttons' width; measure them if menus overlap on macOS.
            if (button != null) menu_room -= 32;
        };
        const project_state = menus.ProjectState{ .open = self.project != null, .can_upgrade = self.can_upgrade, .can_link = self.can_link, .developer_known = self.developer_known, .shift_held = self.shift_held };
        // How the plugins' entries look, as the editor found them this frame.
        const bar_states = if (self.bar_states.matches(self.plugin_bars)) self.bar_states else try plugin_bars.States.declared(b.allocator, self.plugin_bars);
        self.bar_states = bar_states;
        const menu_list = try self.menubar.list(b.allocator, &self.dock, self.plugin_panels, self.plugin_commands, self.plugin_bars, bar_states, project_state, menus.shownMenus(font, menu_room, self.plugin_bars));
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
        const tabs = try self.tabBar(b, viewport.w, font, hot);
        const top_height = bar_height + tab_bar.height;
        const dock_rect = ui.Rect{ .x = viewport.x, .y = viewport.y + top_height, .w = viewport.w, .h = @max(0, viewport.h - top_height - status_height) };
        const docked = try self.dock.build(b, .main, dock_rect, panels.Provider{ .placements = &self.placed, .slot = main_slot, .plugin_panels = self.plugin_panels, .scene_overlay = &self.scene_overlay, .live = self.live });
        const play = try play_button.element(b, self.playing, viewport.x, viewport.w, bar_height);
        const status = try self.statusBar(b, viewport.w, font);
        var main_children: std.ArrayList(*L.Element) = .empty;
        try main_children.appendSlice(b.allocator, &.{ top_bar, tabs, docked, status, play });
        if (self.tabs.active == null) try main_children.append(b.allocator, try no_tabs.element(b, dock_rect, hot));
        const reload = if (self.project != null) try reload_button.element(b, self.build_state == .ready, viewport.x, viewport.w, bar_height) else null;
        if (reload) |button| try main_children.append(b.allocator, button);
        const pause = if (self.playing) try pause_button.element(b, self.paused, viewport.x, viewport.w, bar_height) else null;
        if (pause) |button| try main_children.append(b.allocator, button);
        const simulate = if (!self.playing) try simulate_button.element(b, viewport.x, viewport.w, bar_height) else null;
        if (simulate) |button| try main_children.append(b.allocator, button);
        // A tooltip for the play or Reload button once the pointer has rested on it a moment.
        if (hot != self.hover_id) {
            self.hover_id = hot;
            self.hover_since_ms = self.time_ms;
        }
        if (self.time_ms -| self.hover_since_ms >= tooltip_delay_ms) if (self.tooltipText(hot)) |text| {
            const button = if (hot == play_button.id) play else if (hot == pause_button.id) pause.? else if (hot == simulate_button.id) simulate.? else if (hot == reload_button.id) reload.? else docked.find(hot) orelse unreachable;
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
            const tree = try self.dock.build(b, .{ .window = @intCast(i) }, area, panels.Provider{ .placements = &self.placed, .slot = slot, .plugin_panels = self.plugin_panels, .scene_overlay = &self.scene_overlay, .live = self.live });
            tree.layout(area, font);
            self.roots[slot] = tree;
        }
    }

    /// Show `message` in the bottom-right corner for a couple of seconds.
    /// Copies at most 96 bytes, replacing any current toast, and expires 2500 ms after
    /// `self.time_ms`; the host must keep that clock current. Does not allocate or retain text.
    ///
    /// ```zig
    /// workspace.time_ms = now_ms;
    /// workspace.toast("Saved");
    /// ```
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

    /// What the button `id` (on the title bar, or the Scene panel's toolbar in the main window)
    /// does, for its tooltip; null for others.
    fn tooltipText(self: *const Workspace, id: u32) ?[]const u8 {
        if (scene_view.toolbar.buttonOf(id)) |button| return scene_view.toolbar.describe(button, self.scene_overlay.tools);
        if (id == play_button.id) return if (self.playing) self.stop_tooltip else "Play";
        if (id == pause_button.id and self.playing) return if (self.paused) "Resume" else "Pause";
        if (id == simulate_button.id and !self.playing) return "Simulate: run the game, seen through the Scene panel's camera";
        if (id == reload_button.id) return if (self.build_state == .ready) "Reload (ready)" else "Reload";
        return null;
    }

    /// The bar along the main window's bottom: which project is open (and where), the rebuild,
    /// whether the game is playing, and Eggy's version.
    fn statusBar(self: *const Workspace, b: L.Builder, width: f32, font: *const ui.Font) !*L.Element {
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
        try self.pluginStatusItems(b, &children, .left);
        try children.append(b.allocator, try b.node(0, .{ .grow = 1 }, .none, &.{}));
        try self.pluginStatusItems(b, &children, .right);
        switch (self.build_state) {
            .idle => {},
            .building => |detail| try children.append(b.allocator, try text(b, try std.fmt.allocPrint(b.allocator, "Building: {s}", .{detail}), .muted)),
            .failed => try children.append(b.allocator, try text(b, "Build failed: see the Console", .foreground)),
            .ready => try children.append(b.allocator, try text(b, "Rebuilt", .foreground)),
        }
        // Why Play won't start, in red, while it won't.
        if (self.play_warning) |warning| {
            const look = try b.allocator.create(WarningText);
            look.* = .{ .text = warning };
            const room = @min(font.measure(warning, 12), width * 0.45);
            const shown = try b.node(0, .{ .width = room, .height = status_height }, .{ .custom = .{ .context = look, .draw = WarningText.draw } }, &.{});
            shown.accessibility = .{ .role = .status, .label = warning };
            try children.append(b.allocator, shown);
        }
        if (self.playing) {
            // Red, with a dot that blinks like a camera's recording light, steady while paused.
            const label = if (self.paused) "Paused" else if (self.simulating) "Simulating" else "Playing";
            const look = try b.allocator.create(PlayingLight);
            look.* = .{ .lit = self.paused or (self.time_ms / playing_blink_ms) % 2 == 0, .label = label };
            const light = try b.node(0, .{ .width = 14 + font.measure(label, 12), .height = status_height }, .{ .custom = .{ .context = look, .draw = PlayingLight.draw } }, &.{});
            light.accessibility = .{ .role = .status, .label = label };
            try children.append(b.allocator, light);
        }
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

    /// Add the plugins' status bar entries on `side`: a button, or one that opens a menu above
    /// it, greyed out while its plugin is off. Their labels are copied for this frame's tree.
    fn pluginStatusItems(self: *const Workspace, b: L.Builder, children: *std.ArrayList(*L.Element), side: eggy.plugins.StatusSide) !void {
        for (self.plugin_bars.status_items, 0..) |item, index| {
            if (item.side != side) continue;
            const state = self.bar_states.status[index];
            const label = try b.allocator.dupe(u8, if (state.text().len > 0) state.text() else item.title);
            if (!state.enabled) {
                try children.append(b.allocator, try b.node(0, .{}, .{ .text = .{ .value = label, .size = 12, .tone = .muted } }, &.{}));
                continue;
            }
            const id = plugin_bars.statusId(index);
            const open = self.menubar.open == id;
            const button = try b.node(id, .{ .height = status_height - 4 }, .{ .button = .{ .label = label, .variant = .ghost, .size = .sm, .hot = open } }, &.{});
            button.accessibility = .{ .role = .button, .label = label, .expanded = if (item.items.len > 0) open else null };
            try children.append(b.allocator, button);
            if (open) {
                const rows = try plugin_bars.statusRows(b.allocator, self.plugin_bars, self.bar_states, index);
                try children.append(b.allocator, widgets.anchorTo(try widgets.sizedMenuItems(b, rows, 0, 0, .sm), button, .bottom, 100));
            }
        }
    }

    /// Where the main window's drawn title bar is, for the OS to move and resize the window by it.
    /// Return a by-value SDL hit-test description from the last build, including popup and
    /// interactive exclusions. Before a tree exists returns an otherwise-empty frame.
    ///
    /// ```zig
    /// try workspace.build(viewport, popout_viewports, context.font);
    /// frame.* = workspace.titlebarFrame(); // Host's stable SDL hit-test Frame allocation.
    /// ```
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
        for (self.plugin_bars.menus, 0..) |menu, index| if (menu.extends == null) if (root.find(plugin_bars.menuTriggerId(index))) |trigger| {
            const r = trigger.bounds;
            controls = if (controls) |so_far| .{ .x = so_far.x, .y = so_far.y, .w = r.x + r.w - so_far.x, .h = so_far.h } else r;
        };
        if (controls) |rect| frame.controls = rect;
        // The play and Reload buttons float on the bar, and take presses too.
        for ([_]u32{ play_button.id, reload_button.id, pause_button.id, simulate_button.id }) |id| if (root.find(id)) |button| {
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
        /// Just after the Asset Preview page's UI, where its model is drawn; null when that
        /// page isn't in this window.
        asset_preview_at: ?usize = null,
        /// Where each page's UI starts in `vertices`; null for pages not in this window.
        page_starts: [panels.max_pages]?usize = @splat(null),
    };

    /// Paint window `slot`'s tree from the last `build`: its background, panels and popups, with
    /// each page's UI (`pages[p]`, empty for pages not in this window) spliced in where that page
    /// was painted. The result stays valid until the next `draw`.
    /// `slot` must be a valid main/pop-out slot. Borrows style/font and page vertices during
    /// this call; pass empty slices for pages in other windows. Returns owned-buffer slices,
    /// never caller-owned memory; no tree yields an empty result. Allocation/paint errors
    /// propagate. Upload/use vertices before drawing another window.
    ///
    /// ```zig
    /// const drawn = try workspace.draw(workspace_zig.main_slot, context, page_vertices);
    /// // Host uploads drawn.vertices and inserts the Scene texture at drawn.scene_at.
    /// _ = drawn;
    /// ```
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
            // Out of vertices is the canvas's flag, not the error: plugin panels draw from the
            // game library, whose error numbers differ from the editor's.
            root.drawWithoutOverlays(&c) catch |err| if (c.out_of_vertices) continue else return err;
            root.drawOverlays(&c) catch |err| if (c.out_of_vertices) continue else return err;
            // DevTools' highlight of the element inspected, over everything. It lets go of the
            // page it was given, so a retry hands it over again.
            if (slot == main_slot) if (self.devtools) |tools| {
                tools.page = root;
                tools.highlight(&c, gpa) catch |err| if (c.out_of_vertices) continue else return err;
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
        var asset_preview_at: ?usize = null;
        var page_starts: [panels.max_pages]?usize = @splat(null);
        var from: usize = 0;
        for (splices[0..count]) |splice| {
            if (self.placed.scene_mark) |mark| if (scene_at == null and mark < splice.at) {
                scene_at = self.vertices.items.len + (mark - from);
            };
            self.vertices.appendSliceAssumeCapacity(shell[from..splice.at]);
            page_starts[splice.page] = self.vertices.items.len;
            self.vertices.appendSliceAssumeCapacity(pages[splice.page]);
            if (splice.page == panels.asset_preview_page) asset_preview_at = self.vertices.items.len;
            from = splice.at;
        }
        if (self.placed.scene_mark) |mark| if (scene_at == null) {
            scene_at = self.vertices.items.len + (mark - from);
        };
        self.vertices.appendSliceAssumeCapacity(shell[from..]);
        return .{ .vertices = self.vertices.items, .scene_at = scene_at orelse self.vertices.items.len, .asset_preview_at = asset_preview_at, .page_starts = page_starts };
    }

    /// Route an input event from window `slot`, in that window's coordinates.
    /// Editor-host only: `slot` must index a valid window and coordinates are logical points
    /// matching the last build. Mutates menus/dock/visual play state and returns the action
    /// the host must carry out; `.ignored` should continue to the appropriate panel.
    /// Does not itself run/stop the game or execute file/build commands.
    ///
    /// ```zig
    /// const outcome = workspace.handle(slot, input);
    /// if (outcome == .ignored) panel_context.handle(input);
    /// // Host dispatches every other Outcome as appropriate.
    /// ```
    pub fn handle(self: *Workspace, slot: Slot, event: ui.input.Event) Outcome {
        switch (event) {
            .pointer_move => |p| {
                self.pointer = p;
                self.pointer_slot = slot;
                if (slot == main_slot and self.menubar.hover(self.controlAt(slot, p.x, p.y))) return .handled;
                if (slot == main_slot) if (self.tab_press) |*pressed| {
                    self.dragTab(pressed, p);
                    return .handled;
                };
                // Tabs only drag within the main window; pop-outs' coordinates are their own.
                if (slot != main_slot or !self.dock.dragging()) return .ignored;
                self.dock.dragTo(p.x, p.y);
                return .handled;
            },
            .pointer_down => |down| {
                self.pointer = down.position;
                self.pointer_slot = slot;
                const id = self.controlAt(slot, down.position.x, down.position.y);
                // A press anywhere closes the tab bar's popup, unless it is on one of its rows.
                const tab_action = if (slot == main_slot) tab_bar.actionOf(id) else null;
                const popup_was = self.tab_popup;
                if (tab_action == null or down.button != .left) self.tab_popup = .none;
                switch (down.button) {
                    .middle => {
                        if (tab_action) |action| if (action == .show) {
                            self.closeTab(action.show);
                            return .handled;
                        };
                        return if (self.dock.closeTab(id)) .handled else .ignored;
                    },
                    .right => {
                        if (tab_action) |action| if (action == .show) {
                            self.tab_popup = .{ .tab = action.show };
                            return .handled;
                        };
                        return .ignored;
                    },
                    .left => {},
                }
                if (tab_action) |action| {
                    self.runTabAction(action, popup_was, down.position);
                    return .handled;
                }
                if (popup_was != .none) return .handled;
                if (slot == main_slot) {
                    if (titlebarButton(id)) |button| return .{ .window = button };
                    if (id == reload_button.id) return .reload;
                    if (id == play_button.id) {
                        self.playing = !self.playing;
                        self.simulating = false;
                        return .{ .play = self.playing };
                    }
                    if (id == simulate_button.id and !self.playing) {
                        self.playing = true;
                        self.simulating = true;
                        return .simulate;
                    }
                    if (id == pause_button.id and self.playing) {
                        self.paused = !self.paused;
                        return .{ .pause = self.paused };
                    }
                    if (self.menubar.press(id, self.plugin_bars)) |action| return self.run(action);
                }
                if (scene_view.toolbar.buttonOf(id)) |button| return .{ .scene_button = button };
                if (no_tabs.kindOf(id)) |kind| {
                    self.openTab(kind);
                    return .handled;
                }
                // A copy of a panel shown elsewhere is shown here instead.
                if (panels.showHereOf(id)) |copy| if (self.live.of(copy.panel)) |live| {
                    live.* = copy.copy;
                    return .handled;
                };
                if (self.dock.press(id, down.position.x, down.position.y)) return .handled;
                return if (self.dock.dismissMenu()) .handled else .ignored;
            },
            .pointer_up => |up| {
                if (slot == main_slot) if (self.tab_press) |pressed| {
                    self.tab_press = null;
                    self.dropTab(pressed, up.position);
                    return .handled;
                };
                if (slot != main_slot or !self.dock.dragging()) return .ignored;
                // A panel let go over the tab bar goes into that tab, or a new one.
                if (self.draggedPanel()) |panel| if (self.roots[main_slot]) |root| if (tab_bar.dropAt(root, self.tabs.count(), up.position.x, up.position.y)) |drop| {
                    self.dock.drag = .none;
                    self.dropPanel(panel, drop);
                    return .handled;
                };
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
                // Ctrl+Tab and Ctrl+Shift+Tab step through the tabs; Ctrl+T offers a new one.
                if (key.key == .tab) {
                    const count = self.tabs.count();
                    if (count == 0) return .handled;
                    const step: usize = if (key.modifiers.shift) count - 1 else 1;
                    self.tabs.show(&self.dock, ((self.tabs.active orelse 0) + step) % count);
                    return .handled;
                }
                if (key.key == .t) {
                    self.tab_popup = if (self.tab_popup == .choose) .none else .choose;
                    return .handled;
                }
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
            .plugin_command => |command| return .{ .plugin_command = command },
            .plugin_bar => |target| return .{ .plugin_bar = target },
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
                .export_game => return .export_game,
                .project_settings => return .project_settings,
                .plugins => return .plugins,
                .undo => return .undo,
                .redo => return .redo,
                .reset_layout => self.resetLayout() catch |err| std.log.warn("cannot reset the layout: {t}", .{err}),
                .new_tab => self.tab_popup = .choose,
                .new_tab_3d => self.openTab(.scene_3d),
                .new_tab_2d => self.openTab(.scene_2d),
                .new_tab_ui => self.openTab(.ui),
                .about => return .about,
                .documentation => help_menu.openUrl(help_menu.documentation_url),
                .report_issue => help_menu.openUrl(help_menu.issues_url),
                .show_logs => if (!help_menu.showLogs(self.arena.allocator())) self.toast("This run has no log file"),
            },
        }
        return .handled;
    }

    /// Open the plugin panel whose key is `<plugin>/<key>` and bring its tab forward, docking it
    /// again if it was closed. Fails with `error.NoSuchPanel` when no plugin declares one.
    pub fn showPluginPanel(self: *Workspace, key: []const u8) !void {
        for (self.plugin_panels, 0..) |panel, i| {
            const slash = std.mem.indexOfScalar(u8, panel.key, '/') orelse continue;
            if (!std.mem.eql(u8, panel.key[slash + 1 ..], key)) continue;
            const id = panels.pluginId(panel, i);
            if (self.dock.nodeOf(id) == null) try self.dock.add(id, null, .center);
            _ = self.dock.activate(ui.dock.first_id + id);
            return;
        }
        return error.NoSuchPanel;
    }

    /// Open built-in `panel` and bring its tab forward, docking it beside the Scene if it was
    /// closed.
    pub fn showPanel(self: *Workspace, panel: Panel) !void {
        const id = if (self.live.of(panel)) |live| panels.copyId(panel, live.*) else @intFromEnum(panel);
        if (self.tabs.ofPanel(&self.dock, id)) |tab| if (self.tabs.windowOf(&self.dock, tab) == null) self.tabs.show(&self.dock, tab);
        const scene = panels.copyId(.scene, self.live.scene);
        if (self.dock.nodeOf(id) == null) try self.dock.add(id, if (self.dock.nodeOf(scene) != null) scene else null, .center);
        _ = self.dock.activate(ui.dock.first_id + id);
    }

    /// Show the Asset Preview in an OS window of its own, popping it out of wherever it is
    /// docked (opening it first if it was closed). Closing the window docks it back home.
    pub fn previewInWindow(self: *Workspace) !void {
        const id = @intFromEnum(Panel.asset_preview);
        if (self.dock.nodeOf(id)) |stack| if (std.meta.activeTag(self.dock.hostOf(stack)) == .window and self.dock.nodes[stack].count == 1) return;
        if (self.dock.nodeOf(id) == null) try self.showPanel(.asset_preview);
        try self.dock.detach(id);
    }

    /// Show the tab holding the live UI Designer, or open a UI tab when it isn't docked in one.
    /// Call `followShownTab` before working with the Designer, so it is that tab's.
    pub fn showUiDesigner(self: *Workspace) !void {
        const designer = panels.copyId(.ui_designer, self.live.ui);
        if (self.tabs.ofPanel(&self.dock, designer)) |tab| return self.tabs.show(&self.dock, tab);
        if (self.dock.nodeOf(designer) != null) return;
        try self.newTab(.ui);
    }

    /// File > New Tab, the tab bar's "+" and Ctrl+T: a new tab of `kind`.
    fn openTab(self: *Workspace, kind: workspace_tabs.Kind) void {
        self.newTab(kind) catch |err| {
            self.toast("Couldn't open the tab: too many tabs or panels");
            std.log.warn("cannot open a {t} tab: {t}", .{ kind, err });
        };
    }

    /// Open a new tab of `kind`, shown, with its own copy of the panels it is for: the 3D preset
    /// (`addScenePreset`), a 2D Scene, or the UI Designer with its tree on the left and
    /// properties on the right.
    fn newTab(self: *Workspace, kind: workspace_tabs.Kind) !void {
        switch (kind) {
            .scene_3d => {
                const copy = try self.freeCopy(&scene_preset);
                _ = try self.tabs.open(&self.dock, .scene_3d);
                try self.addScenePreset(copy);
            },
            .scene_2d => {
                const copy = try self.freeCopy(&.{.scene_2d});
                _ = try self.tabs.open(&self.dock, .scene_2d);
                try self.dock.add(panels.copyId(.scene_2d, copy), null, .center);
            },
            .ui => {
                const copy = try self.freeCopy(&.{ .ui_designer, .ui_tree, .ui_properties });
                _ = try self.tabs.open(&self.dock, .ui);
                const designer = panels.copyId(.ui_designer, copy);
                try self.dock.add(designer, null, .center);
                try self.dock.add(panels.copyId(.ui_tree, copy), designer, .left);
                self.splitRatio(panels.copyId(.ui_tree, copy), 0.2);
                try self.dock.add(panels.copyId(.ui_properties, copy), designer, .right);
                self.splitRatio(panels.copyId(.ui_properties, copy), 0.72);
            },
            .panels => {},
        }
    }

    /// The first copy number none of `group`'s panels have open, for a new tab's.
    fn freeCopy(self: *const Workspace, group: []const Panel) !u8 {
        copies: for (0..panels.max_copies) |copy| {
            for (group) |panel| if (self.dock.nodeOf(panels.copyId(panel, @intCast(copy))) != null) continue :copies;
            return @intCast(copy);
        }
        return error.TooManyCopies;
    }

    /// Close tab `index` and the panels in it, unless it is pinned. Edit > Undo brings it back.
    pub fn closeTab(self: *Workspace, index: usize) void {
        const tab = self.tabs.list[index] orelse return;
        if (tab.pinned) return self.toast("Unpin the tab to close it");
        self.tabs.close(&self.dock, index);
    }

    /// Pop tab `index` out into an OS window, or bring it back when it is out.
    fn popOutTab(self: *Workspace, index: usize) void {
        if (self.tabs.windowOf(&self.dock, index) != null) return self.tabs.show(&self.dock, index);
        const area = self.dock.viewport;
        self.tabs.popOut(&self.dock, index, .{ @max(480, area.w * 0.7), @max(360, area.h * 0.8) }) catch {
            self.toast("Too many windows are open to pop out another");
        };
    }

    /// The OS window `index` was closed: a tab in it goes back to the tab bar, and panels go
    /// back to where they were.
    pub fn closeWindow(self: *Workspace, index: usize) void {
        const window = self.dock.windows[index] orelse return;
        if (self.tabs.ofRoot(window.root) != null) {
            self.dock.windows[index] = null;
            return;
        }
        self.dock.redock(.{ .window = @intCast(index) });
    }

    /// Carry out a press on the tab bar; `popup` is what was open when it came.
    fn runTabAction(self: *Workspace, action: tab_bar.Action, popup: tab_bar.Popup, at: ui.Vec2) void {
        self.tab_popup = .none;
        switch (action) {
            .show => |index| {
                self.tabs.show(&self.dock, index);
                self.tab_press = .{ .root = self.tabs.list[index].?.root, .from = at };
            },
            .close => |index| self.closeTab(index),
            .choose => self.tab_popup = if (popup == .choose) .none else .choose,
            .open => |kind| self.openTab(kind),
            .pin_open_menu => if (popup == .tab) if (self.tabs.list[popup.tab]) |tab| self.tabs.setPinned(popup.tab, !tab.pinned),
            .pop_out => if (popup == .tab) self.popOutTab(popup.tab),
            .close_open_menu => if (popup == .tab) self.closeTab(popup.tab),
        }
    }

    /// The panel carried by a tab drag under way, if any.
    fn draggedPanel(self: *const Workspace) ?u32 {
        return switch (self.dock.drag) {
            .tab => |carried| if (carried.started) carried.panel else null,
            else => null,
        };
    }

    /// Put `panel` into the tab `drop` says, or a new one named after it, and show that tab.
    fn dropPanel(self: *Workspace, panel: u32, drop: tab_bar.Drop) void {
        const index = switch (drop) {
            .tab => |index| index,
            .new => blk: {
                const was = self.tabs.active;
                const made = self.tabs.open(&self.dock, .panels) catch {
                    self.toast("Too many tabs are open for another");
                    return;
                };
                if (was) |shown| self.tabs.show(&self.dock, shown);
                break :blk made;
            },
        };
        const stack = self.tabs.stackOf(&self.dock, index) orelse return;
        self.dock.move(panel, stack, .center) catch |err| return std.log.warn("cannot move panel {d} to tab {d}: {t}", .{ panel, index, err });
        self.tabs.prune(&self.dock);
        if (self.tabs.ofPanel(&self.dock, panel)) |shown| self.tabs.show(&self.dock, shown);
    }

    /// A tab carried from the bar moved to `at`. Over another tab's layout (not its own, and not
    /// when it is pinned, which stays a tab), its first panel is carried as a dock drag, so the
    /// dock shows where its panels would go; anywhere else, nothing is.
    fn dragTab(self: *Workspace, pressed: *tab_drag.TabDrag, at: ui.Vec2) void {
        if (!pressed.moveTo(at)) return;
        const carried = self.tabs.ofRoot(pressed.root) orelse {
            self.tab_press = null;
            self.dock.drag = .none;
            return;
        };
        const on_bar = if (self.roots[main_slot]) |root| tab_bar.dropAt(root, self.tabs.count(), at.x, at.y) != null else false;
        const own_shown = self.tabs.isShown(carried);
        if (on_bar or own_shown or self.tabs.list[carried].?.pinned) {
            self.dock.drag = .none;
            return;
        }
        var buffer: [64 * 16]u32 = undefined;
        const carried_panels = self.tabs.panelsOf(&self.dock, carried, &buffer);
        if (carried_panels.len == 0) return;
        if (std.meta.activeTag(self.dock.drag) != .tab) self.dock.drag = .{ .tab = .{ .panel = carried_panels[0], .x = pressed.from.x, .y = pressed.from.y, .started = true } };
        self.dock.dragTo(at.x, at.y);
    }

    /// Let go of a tab carried from the bar at `at`: into another tab's layout its panels dock
    /// where the dock's targets say, onto the bar it moves to that place, and pulled well below
    /// the bar over its own layout it pops out into a window.
    fn dropTab(self: *Workspace, pressed: tab_drag.TabDrag, at: ui.Vec2) void {
        if (!pressed.started) return;
        const carried = self.tabs.ofRoot(pressed.root) orelse return;
        if (std.meta.activeTag(self.dock.drag) == .tab) {
            var buffer: [64 * 16]u32 = undefined;
            const carried_panels = self.tabs.panelsOf(&self.dock, carried, &buffer);
            self.dock.release(at.x, at.y);
            if (carried_panels.len > 0) tab_drag.follow(&self.dock, carried_panels[0], carried_panels[1..]);
            self.tabs.prune(&self.dock);
            return;
        }
        if (self.roots[main_slot]) |root| if (tab_bar.dropAt(root, self.tabs.count(), at.x, at.y)) |drop| {
            self.tabs.reorder(carried, switch (drop) {
                .tab => |index| index,
                .new => self.tabs.count() - 1,
            });
            return;
        };
        if (at.y - pressed.from.y > 2 * tab_bar.height) self.popOutTab(carried);
    }

    /// Something carried (a tab, or a dock panel) resting on a tab of the bar shows that tab.
    fn springLoad(self: *Workspace) void {
        const root = self.roots[main_slot] orelse return;
        const carrying = (self.tab_press != null and self.tab_press.?.started) or self.draggedPanel() != null;
        const over = if (carrying and self.pointer_slot == main_slot) tab_bar.tabAt(root, self.tabs.count(), self.pointer.x, self.pointer.y) else null;
        if (self.spring.hover(over, self.time_ms)) |index| self.tabs.show(&self.dock, index);
    }

    /// Keep the tabs in step with the dock, make the copies in the tab shown live when the main
    /// window shows another tree, and hand a closed live copy's place to one still open.
    pub fn followShownTab(self: *Workspace) void {
        self.tabs.prune(&self.dock);
        if (self.dock.root != self.followed_root) {
            self.followed_root = self.dock.root;
            var buffer: [64 * 16]u32 = undefined;
            if (self.tabs.active) |active| for (self.tabs.panelsOf(&self.dock, active, &buffer)) |id| {
                const found = panels.copyOf(id) orelse continue;
                if (self.live.of(found.panel)) |live| live.* = found.copy;
            };
        }
        for (panels.live_panels) |panel| {
            const live = self.live.of(panel).?;
            if (self.dock.nodeOf(panels.copyId(panel, live.*)) != null) continue;
            for (0..panels.max_copies) |copy| if (self.dock.nodeOf(panels.copyId(panel, @intCast(copy))) != null) {
                live.* = @intCast(copy);
                break;
            };
        }
    }

    /// Tab `index`'s name: its kind's, or for panels dragged onto the bar, its first panel's.
    fn tabTitleZ(self: *const Workspace, index: usize) [:0]const u8 {
        const tab = self.tabs.list[index] orelse return "Tab";
        if (tab.kind != .panels) return tab.kind.title();
        var at = tab.root;
        while (self.dock.nodes[at].kind == .split) at = self.dock.nodes[at].first;
        const node = self.dock.nodes[at];
        return if (node.count > 0) panels.panelTitle(node.panels[0], self.plugin_panels) else tab.kind.title();
    }

    /// The tab bar as it looks this frame; `hot` is the control under the pointer.
    fn tabBar(self: *const Workspace, b: L.Builder, width: f32, font: *const ui.Font, hot: u32) !*L.Element {
        const count = self.tabs.count();
        const titles = try b.allocator.alloc([]const u8, count);
        const popped = try b.allocator.alloc(bool, count);
        const pinned = try b.allocator.alloc(bool, count);
        for (titles, popped, pinned, 0..) |*title, *out, *pin, i| {
            title.* = self.tabTitleZ(i);
            out.* = self.tabs.windowOf(&self.dock, i) != null;
            pin.* = self.tabs.list[i].?.pinned;
        }
        // A panel carried over the bar lands in a tab or a new one; a tab carried along it, in a place.
        const carried_tab = if (self.tab_press) |pressed| if (pressed.started) self.tabs.ofRoot(pressed.root) else null else null;
        const carried = self.draggedPanel() != null and carried_tab == null;
        const over_bar = (carried or carried_tab != null) and self.pointer_slot == main_slot;
        const drop = if (over_bar) if (self.roots[main_slot]) |root| tab_bar.dropAt(root, count, self.pointer.x, self.pointer.y) else null else null;
        return tab_bar.element(b, width, font, .{
            .titles = titles,
            .active = self.tabs.active,
            .popped = popped,
            .pinned = pinned,
            .popup = self.tab_popup,
            .drop = drop,
            .dragging = carried,
            .carried = if (carried_tab) |index| @intCast(index) else null,
            .hot = hot,
        });
    }

    /// Window > a panel: close it when open; else open it, a Scene, 2D Scene or the UI Designer's
    /// in a new tab of its own.
    fn togglePanel(self: *Workspace, panel: u32) void {
        if (self.dock.nodeOf(panel) != null) return self.dock.remove(panel);
        switch (std.enums.fromInt(Panel, panel) orelse .inspector) {
            .ui_designer, .ui_tree, .ui_properties => return self.openTab(.ui),
            .scene_2d => return self.openTab(.scene_2d),
            .scene => return self.openTab(.scene_3d),
            else => {},
        }
        self.dock.add(panel, null, .center) catch |err| std.log.warn("cannot reopen panel {d}: {t}", .{ panel, err });
    }

    /// Whether one of the workspace's controls (a menu, a tab, the Scene's toolbar) is under (x, y)
    /// in window `slot`, so a press there is the workspace's rather than what lies beneath.
    /// Uses the last built tree in window-local logical points; `slot` must be valid.
    /// Returns false without a tree; performs no state change or allocation.
    ///
    /// ```zig
    /// const over_shell = workspace.hasControlAt(slot, pointer.x, pointer.y);
    /// _ = over_shell; // Host uses this to keep shell presses out of Scene picking.
    /// ```
    pub fn hasControlAt(self: *const Workspace, slot: Slot, x: f32, y: f32) bool {
        return self.controlAt(slot, x, y) != 0;
    }

    /// The topmost interactive element under (x, y) in window `slot`'s last tree, or 0.
    fn controlAt(self: *const Workspace, slot: Slot, x: f32, y: f32) u32 {
        const root = self.roots[slot] orelse return 0;
        return hit_test.controlAt(root, x, y);
    }
};

const test_plugin_panels = [_]eggy.plugins.EditorPanel{.{ .title = "Stats" }};

test "keyed panels retain dock positions through title changes and reordering" {
    const before = [_]eggy.plugins.EditorPanel{
        .{ .key = "game/stats", .title = "Stats" },
        .{ .key = "game/tools", .title = "Tools" },
    };
    var workspace = try Workspace.init(std.testing.allocator, .default(.linux), &.{});
    defer workspace.deinit();
    workspace.setPluginPanels(&before);
    const stats_id = panels.pluginId(before[0], 0);
    const node = workspace.dock.nodeOf(stats_id);
    const after = [_]eggy.plugins.EditorPanel{
        .{ .key = "game/tools", .title = "Tools" },
        .{ .key = "game/stats", .title = "Statistics" },
    };
    workspace.setPluginPanels(&after);
    try std.testing.expectEqual(node, workspace.dock.nodeOf(stats_id));
    try std.testing.expectEqual(@as(?usize, panels.first_plugin_page + 1), panels.pageOf(stats_id, &after));
    workspace.dock.remove(stats_id);
    workspace.setPluginPanels(&after);
    try std.testing.expect(workspace.dock.nodeOf(stats_id) == null);
}

fn testWorkspace() !Workspace {
    return Workspace.init(std.testing.allocator, titlebar.Layout.default(.linux), &test_plugin_panels);
}

test "the default layout docks every panel but the UI Designer's and the 2D Scene" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    for (std.enums.values(Panel)) |panel| {
        const own_tab = panel == .ui_designer or panel == .ui_tree or panel == .ui_properties or panel == .scene_2d;
        try std.testing.expectEqual(!own_tab, workspace.dock.nodeOf(@intFromEnum(panel)) != null);
    }
}

test "every new tab is a tab of its own, and the copy of its panel in the tab shown goes live" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    // The UI Designer's three open together in a UI tab, shown.
    _ = workspace.run(.{ .toggle_panel = @intFromEnum(Panel.ui_properties) });
    const ui_tab = workspace.tabs.ofKind(.ui).?;
    try std.testing.expect(workspace.tabs.isShown(ui_tab));
    for ([_]Panel{ .ui_designer, .ui_tree, .ui_properties }) |panel| {
        try std.testing.expectEqual(@as(?usize, ui_tab), workspace.tabs.ofPanel(&workspace.dock, @intFromEnum(panel)));
    }
    // Another UI tab, two 2D tabs and another 3D tab each have their own copy.
    _ = workspace.run(.{ .command = .new_tab_ui });
    workspace.followShownTab();
    try std.testing.expect(workspace.tabs.isShown(workspace.tabs.ofPanel(&workspace.dock, panels.copyId(.ui_tree, 1)).?));
    _ = workspace.run(.{ .command = .new_tab_2d });
    _ = workspace.run(.{ .command = .new_tab_2d });
    workspace.followShownTab();
    try std.testing.expect(workspace.tabs.isShown(workspace.tabs.ofPanel(&workspace.dock, panels.copyId(.scene_2d, 1)).?));
    _ = workspace.run(.{ .command = .new_tab_3d });
    try std.testing.expectEqual(@as(usize, 6), workspace.tabs.count());
    workspace.followShownTab();
    try std.testing.expectEqual(@as(u8, 1), workspace.live.scene);
    try std.testing.expectEqual(@as(u8, 1), workspace.live.scene_2d);
    // The new 3D tab has the 3D preset of its own: the Hierarchy left of its Scene, the Inspector
    // right, and the Console, Assets and Animation below; those copies are the live ones.
    const three_d = workspace.tabs.active.?;
    for (Workspace.scene_preset) |panel| try std.testing.expectEqual(@as(?usize, three_d), workspace.tabs.ofPanel(&workspace.dock, panels.copyId(panel, 1)));
    try std.testing.expectEqual(workspace.dock.nodeOf(panels.copyId(.console, 1)).?, workspace.dock.nodeOf(panels.copyId(.assets, 1)).?);
    try std.testing.expectEqual(@as(u8, 1), workspace.live.inspector);
    try std.testing.expectEqual(@as(u8, 1), workspace.live.ui);
    // Back on the first tab, its Scene is the live one again.
    workspace.tabs.show(&workspace.dock, 0);
    workspace.followShownTab();
    try std.testing.expectEqual(@as(u8, 0), workspace.live.scene);
}

test "a tab carried onto another, rested there and let go on its tabs docks between them" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 800 };
    const inspector = @intFromEnum(Panel.inspector);
    const console = @intFromEnum(Panel.console);
    // The Inspector in a tab of its own, shown.
    workspace.dropPanel(inspector, .new);
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expectEqual(@as(?usize, 1), workspace.tabs.ofPanel(&workspace.dock, inspector));
    try std.testing.expect(workspace.tabs.isShown(1));

    // Carry its tab onto the 3D tab and rest there until the 3D tab shows.
    const root = workspace.roots[main_slot].?;
    const carried = tab_bar.tabBounds(root, 1).?.center();
    const three_d = tab_bar.tabBounds(root, 0).?.center();
    _ = workspace.handle(main_slot, .{ .pointer_down = .{ .position = carried, .button = .left, .clicks = 1 } });
    _ = workspace.handle(main_slot, .{ .pointer_move = three_d });
    try workspace.build(viewport, @splat(null), &font);
    workspace.time_ms += tab_drag.spring_ms;
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expect(workspace.tabs.isShown(0));

    // Let go on the Console's tabs, just past the Console's own: before Assets. The dock notes
    // where its tabs are as it paints them, which a test doesn't.
    const stack = &workspace.dock.nodes[workspace.dock.nodeOf(console).?];
    try std.testing.expectEqual(@as(u32, @intFromEnum(Panel.assets)), stack.panels[1]);
    for (stack.panels[0..stack.count], 0..) |panel, i| {
        const tab = workspace.roots[main_slot].?.find(ui.dock.first_id + panel).?.bounds;
        stack.tab_spans[i] = .{ tab.x, tab.x + tab.w };
    }
    const drop = ui.Vec2{ .x = stack.tab_spans[0][1] - 2, .y = stack.rect.y + 6 };
    _ = workspace.handle(main_slot, .{ .pointer_move = drop });
    _ = workspace.handle(main_slot, .{ .pointer_up = .{ .position = drop, .button = .left } });
    const joined = workspace.dock.nodes[workspace.dock.nodeOf(inspector).?];
    try std.testing.expectEqual(workspace.dock.nodeOf(console).?, workspace.dock.nodeOf(inspector).?);
    try std.testing.expectEqual(inspector, joined.panels[1]);
    // The emptied tab goes.
    workspace.followShownTab();
    try std.testing.expectEqual(@as(usize, 1), workspace.tabs.count());
}

test "closing every tab leaves the main window empty, and a new tab fills it" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 800 };
    workspace.closeTab(0);
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabs.count());
    try std.testing.expect(workspace.dock.nodeOf(@intFromEnum(Panel.scene)) == null);
    // It says how to open one.
    const hasText = struct {
        fn f(element: *const L.Element, value: []const u8) bool {
            if (element.paint_kind == .text and std.mem.eql(u8, element.paint_kind.text.value, value)) return true;
            for (element.children) |child| if (f(child, value)) return true;
            return false;
        }
    }.f;
    try std.testing.expect(hasText(workspace.roots[main_slot].?, "Open a tab"));

    // Its 3D Scene row opens a 3D tab.
    const row = workspace.roots[main_slot].?.find(0x5700_0000 + @as(u32, @intFromEnum(workspace_tabs.Kind.scene_3d))).?;
    try std.testing.expectEqual(Outcome.handled, workspace.handle(main_slot, .{ .pointer_down = .{ .position = row.bounds.center(), .button = .left, .clicks = 1 } }));
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expectEqual(@as(usize, 1), workspace.tabs.count());
    try std.testing.expect(workspace.placed.scene != null);
}

test "a pinned tab can't be closed until it is unpinned" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    workspace.tabs.setPinned(0, true);
    workspace.closeTab(0);
    try std.testing.expectEqual(@as(usize, 1), workspace.tabs.count());
    workspace.tabs.setPinned(0, false);
    workspace.closeTab(0);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabs.count());
}

test "previewing an asset pops the Asset Preview out into a window, once" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    workspace.dock.os_windows = true;
    const id = @intFromEnum(Panel.asset_preview);
    try workspace.previewInWindow();
    const host = workspace.dock.hostOf(workspace.dock.nodeOf(id).?);
    try std.testing.expect(std.meta.activeTag(host) == .window);
    try workspace.previewInWindow();
    try std.testing.expect(std.meta.eql(host, workspace.dock.hostOf(workspace.dock.nodeOf(id).?)));
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
    // Play and Simulate take presses on the bar.
    try std.testing.expect(workspace.titlebarFrame().extra_count == 2);
    const press = ui.input.Event{ .pointer_down = .{ .position = play.bounds.center(), .button = .left, .clicks = 1 } };
    try std.testing.expectEqual(Outcome{ .play = true }, workspace.handle(main_slot, press));
    try std.testing.expectEqual(Outcome{ .play = false }, workspace.handle(main_slot, press));
}

test "Simulate runs the game, and play's stop button ends it" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try workspace.build(viewport, @splat(null), &font);
    const simulate = workspace.roots[main_slot].?.find(simulate_button.id).?;
    try std.testing.expectEqual(Outcome.simulate, workspace.handle(main_slot, .{ .pointer_down = .{ .position = simulate.bounds.center(), .button = .left, .clicks = 1 } }));
    try std.testing.expect(workspace.playing and workspace.simulating);

    // While it runs, Simulate gives way to the pause button.
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expect(workspace.roots[main_slot].?.find(simulate_button.id) == null);
    const play = workspace.roots[main_slot].?.find(play_button.id).?;
    try std.testing.expectEqual(Outcome{ .play = false }, workspace.handle(main_slot, .{ .pointer_down = .{ .position = play.bounds.center(), .button = .left, .clicks = 1 } }));
    try std.testing.expect(!workspace.simulating);
}

test "while playing, a pause button left of play holds the game and lets it go" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expect(workspace.roots[main_slot].?.find(pause_button.id) == null);

    workspace.playing = true;
    try workspace.build(viewport, @splat(null), &font);
    const pause = workspace.roots[main_slot].?.find(pause_button.id).?;
    const play = workspace.roots[main_slot].?.find(play_button.id).?;
    try std.testing.expect(pause.bounds.x + pause.bounds.w <= play.bounds.x);
    const press = ui.input.Event{ .pointer_down = .{ .position = pause.bounds.center(), .button = .left, .clicks = 1 } };
    try std.testing.expectEqual(Outcome{ .pause = true }, workspace.handle(main_slot, press));
    try std.testing.expectEqual(Outcome{ .pause = false }, workspace.handle(main_slot, press));
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

test "the Scene's panel menu, dropped over the Scene, takes presses there" {
    var workspace = try testWorkspace();
    defer workspace.deinit();
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 800 };
    try workspace.build(viewport, @splat(null), &font);

    // Open the Scene stack's menu with its burger, at the right of the Scene's tab bar.
    const scene = workspace.placed.scene.?.rect;
    const burger = workspace.controlAt(main_slot, scene.x + scene.w - 12, scene.y - 12);
    try std.testing.expectEqual(Outcome.handled, workspace.handle(main_slot, .{ .pointer_down = .{ .position = .{ .x = scene.x + scene.w - 12, .y = scene.y - 12 }, .button = .left, .clicks = 1 } }));
    try std.testing.expect(burger != 0);
    try workspace.build(viewport, @splat(null), &font);

    // Its Pop out row lies over the Scene, and is the workspace's to press.
    const findRow = struct {
        fn f(element: *const L.Element, label: []const u8) ?*const L.Element {
            if (element.paint_kind == .menu_item and std.mem.eql(u8, element.paint_kind.menu_item.label, label)) return element;
            for (element.children) |child| if (f(child, label)) |found| return found;
            return null;
        }
    }.f;
    const row = findRow(workspace.roots[main_slot].?, "Pop out into window").?;
    const at = ui.Vec2{ .x = @max(row.bounds.x, scene.x) + 4, .y = row.bounds.center().y };
    try std.testing.expect(scene.contains(at.x, at.y));
    try std.testing.expect(workspace.hasControlAt(main_slot, at.x, at.y));
    _ = workspace.handle(main_slot, .{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    try std.testing.expect(workspace.dock.windows[0] != null);

    // The Scene itself is not a control: the scene camera and the game take presses there.
    try workspace.build(viewport, @splat(null), &font);
    try std.testing.expect(!workspace.hasControlAt(main_slot, viewport.w / 2, viewport.h / 2));
}

test "a plugin panel closed stays closed across swaps and restarts" {
    var workspace = try Workspace.init(std.testing.allocator, titlebar.Layout.default(.linux), &.{});
    defer workspace.deinit();
    const stats = panels.plugin_first;
    workspace.setPluginPanels(&test_plugin_panels);
    try std.testing.expect(workspace.dock.nodeOf(stats) != null);
    workspace.dock.remove(stats); // closed
    // The game swapped (its panels gone, then back), as on a rebuild or the next start.
    workspace.setPluginPanels(&.{});
    workspace.setPluginPanels(&test_plugin_panels);
    try std.testing.expect(workspace.dock.nodeOf(stats) == null);
    // Window > Stats still brings it back.
    _ = workspace.run(.{ .toggle_panel = stats });
    try std.testing.expect(workspace.dock.nodeOf(stats) != null);
}
