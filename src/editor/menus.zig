//! The editor's menus (File, Edit, View, Window, Help) and the ones plugins add: their items, and
//! what pressing one does.
//! Menus that don't fit beside the play button fold into a "..." menu, as VS Code's do. Weeoui
//! draws them compact, as a desktop menu bar's are.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const widgets = ui.widgets;
const L = ui.Layout;
const dock = ui.dock;
const panels = @import("panels.zig");
const plugin_bars = @import("plugin_bars.zig");
const Panel = panels.Panel;

// Ids, kept below `dock.first_id`.
const first_id: u32 = 0x4D00_0000;
pub const Menu = enum(u32) {
    file = first_id,
    edit,
    view,
    window,
    help,
    /// The "..." menu holding the menus that don't fit.
    more,

    fn label(menu: Menu) []const u8 {
        return switch (menu) {
            .file => "File",
            .edit => "Edit",
            .view => "View",
            .window => "Window",
            .help => "Help",
            .more => "More",
        };
    }
};
/// The menus in order, all but `more`.
const menu_order = [_]Menu{ .file, .edit, .view, .window, .help };
pub const Command = enum(u32) {
    new_project = first_id + 0x100,
    open_project,
    open_project_linked,
    /// File > Open in > File Manager and > IDE: the project's folder in either.
    open_in_file_manager,
    open_in_ide,
    upgrade_editor,
    link_developer,
    save,
    export_game,
    project_settings,
    quit,
    undo,
    redo,
    preferences,
    reset_layout,
    devtools,
    about,
    plugins,
    documentation,
    report_issue,
    show_logs,
    new_tab,
    new_tab_3d,
    new_tab_2d,
    new_tab_ui,
    oopsies,
};
/// File > Open in: a row whose submenu opens on press or hover, not a command.
const open_in_row: u32 = first_id + 0x1F0;
/// Window menu items: `window_item_first` + panel id.
const window_item_first: u32 = first_id + 0x200;
/// The "..." menu's rows: `overflow_first` + the folded menu's index in `menu_order`.
const overflow_first: u32 = first_id + 0x300;
const plugin_command_first: u32 = first_id + 0x10000;

/// What the File menu can do for the project open in the editor.
pub const ProjectState = struct {
    /// Whether the editor has a project open.
    open: bool = false,
    /// Whether a newer Eggy than the project's is unpacked (File > Upgrade Editor).
    can_upgrade: bool = false,
    /// Whether the project can be linked to the Eggy codebase being developed.
    can_link: bool = false,
    /// Whether an Eggy codebase being developed is known, for Open Project with Developer Eggy.
    developer_known: bool = false,
    /// Whether Shift is held, which turns Open Project into Open Project with Developer Eggy
    /// and Upgrade Editor into Link Developer Eggy.
    shift_held: bool = false,
};

/// What a press on the menu bar asks for.
pub const Action = union(enum) {
    /// The press opened, closed or switched a menu, or closed one by landing elsewhere.
    handled,
    /// Window > (panel): show it if hidden, else hide it.
    toggle_panel: u32,
    command: Command,
    plugin_command: usize,
    /// A plugin's menu row, or its status bar button, was pressed.
    plugin_bar: eggy.plugins.EditorBarTarget,
};

/// The menu bar's state: which menu is open.
pub const Menubar = struct {
    plugin_command_count: usize = 0,
    /// How many menus the last `list` made (Eggy's, then the plugins' own), for the "..." rows.
    menu_count: usize = menu_order.len,
    /// Trigger id of the open menu, or of the open status item, or 0.
    open: u32 = 0,
    /// The "..." menu's row whose menu is open beside it, or 0.
    open_submenu: u32 = 0,

    /// The menus as `widgets` draws them: the first `shown` (see `shownMenus`) on the bar and the
    /// rest in the "..." menu. Window lists each panel, the built-in ones then `plugin_panels`,
    /// checked while `layout` shows it. Plugin menus follow Eggy's, and the rows of those that
    /// extend one of Eggy's end it; `states` says how each looks.
    /// Editor-host only: allocate with a frame arena, which owns the returned menus and nested
    /// item slices; labels borrow plugin declarations/static strings through drawing.
    /// Updates command dispatch bounds; errors on allocation or over 65536 plugin commands.
    ///
    /// ```zig
    /// const shown = menus.shownMenus(font, available_points);
    /// const list = try menubar.list(arena, &layout, plugin_panels, plugin_commands, bars, states, project_state, shown);
    /// // Feed list to the frame's titlebarMenubar widget.
    /// _ = list;
    /// ```
    pub fn list(self: *Menubar, gpa: std.mem.Allocator, layout: *const dock.DockSpace, plugin_panels: []const eggy.plugins.EditorPanel, plugin_commands: []const eggy.plugins.EditorCommand, bars: plugin_bars.Bars, states: plugin_bars.States, project: ProjectState, shown: usize) ![]const widgets.MenubarMenu {
        if (!bars.fits()) return error.TooManyPluginMenus;
        if (plugin_commands.len > 65536) return error.TooManyEditorCommands;
        self.plugin_command_count = plugin_commands.len;
        const command_items = try gpa.alloc(widgets.MenuItem, plugin_commands.len);
        for (command_items, plugin_commands, 0..) |*item, command, index| item.* = .{ .id = plugin_command_first + @as(u32, @intCast(index)), .label = command.title };
        const built_in = std.enums.values(Panel);
        const window_items = try gpa.alloc(widgets.MenuItem, built_in.len + plugin_panels.len + 2);
        for (window_items[0 .. built_in.len + plugin_panels.len], 0..) |*item, i| {
            const id: u32 = if (i < built_in.len) @backingInt(built_in[i]) else panels.pluginId(plugin_panels[i - built_in.len], i - built_in.len);
            item.* = .{ .id = window_item_first + id, .label = panels.panelTitle(id, plugin_panels), .kind = .checkbox, .checked = layout.nodeOf(id) != null };
        }
        window_items[window_items.len - 2] = .{ .kind = .separator };
        window_items[window_items.len - 1] = .{ .id = @backingInt(Command.reset_layout), .label = "Reset Layout" };

        const open_in_items = try gpa.dupe(widgets.MenuItem, &.{
            .{ .id = @backingInt(Command.open_in_file_manager), .label = "File Manager", .disabled = !project.open },
            .{ .id = @backingInt(Command.open_in_ide), .label = "IDE", .disabled = !project.open },
        });
        const file_items = try gpa.dupe(widgets.MenuItem, &.{
            .{ .id = @backingInt(Command.new_project), .label = "New Project...", .shortcut = "Ctrl+N" },
            if (project.shift_held)
                .{ .id = @backingInt(Command.open_project_linked), .label = "Open Project with Developer Eggy...", .disabled = !project.developer_known }
            else
                .{ .id = @backingInt(Command.open_project), .label = "Open Project...", .shortcut = "Ctrl+O" },
            .{ .id = open_in_row, .label = "Open in", .kind = .submenu, .items = open_in_items, .disabled = !project.open },
            .{ .id = @backingInt(Command.save), .label = "Save", .shortcut = "Ctrl+S" },
            .{ .kind = .separator },
            .{ .id = @backingInt(Command.new_tab), .label = "New Tab...", .shortcut = "Ctrl+T" },
            .{ .id = @backingInt(Command.new_tab_3d), .label = "New 3D Scene Tab" },
            .{ .id = @backingInt(Command.new_tab_2d), .label = "New 2D Scene Tab" },
            .{ .id = @backingInt(Command.new_tab_ui), .label = "New UI Scene Tab" },
            .{ .kind = .separator },
            .{ .id = @backingInt(Command.export_game), .label = "Export...", .disabled = !project.open },
            .{ .id = @backingInt(Command.project_settings), .label = "Project Settings...", .disabled = !project.open },
            .{ .kind = .separator },
            if (project.shift_held)
                .{ .id = @backingInt(Command.link_developer), .label = "Link Developer Eggy...", .disabled = !project.can_link }
            else
                .{ .id = @backingInt(Command.upgrade_editor), .label = "Upgrade Editor", .disabled = !project.can_upgrade },
            .{ .kind = .separator },
            .{ .id = @backingInt(Command.quit), .label = "Quit", .shortcut = "Ctrl+Q" },
        });

        const edit_items = [_]widgets.MenuItem{
            .{ .id = @backingInt(Command.undo), .label = "Undo", .shortcut = "Ctrl+Z" },
            .{ .id = @backingInt(Command.redo), .label = "Redo", .shortcut = "Ctrl+Shift+Z" },
            .{ .kind = .separator },
            .{ .id = @backingInt(Command.preferences), .label = "Preferences..." },
            .{ .id = @backingInt(Command.plugins), .label = "Plugins...", .disabled = !project.open },
        };
        const help_items = [_]widgets.MenuItem{
            .{ .id = @backingInt(Command.documentation), .label = "Documentation" },
            .{ .id = @backingInt(Command.report_issue), .label = "Report an Issue" },
            .{ .id = @backingInt(Command.show_logs), .label = "Show Log Files" },
            .{ .kind = .separator },
            .{ .id = @backingInt(Command.devtools), .label = "DevTools", .shortcut = "F12" },
            .{ .kind = .separator },
            .{ .id = @backingInt(Command.about), .label = "About Eggy" },
            .{ .id = @backingInt(Command.oopsies), .label = "😛" },
        };
        const own = try plugin_bars.ownMenus(gpa, bars, states);
        const all = try gpa.alloc(widgets.MenubarMenu, menu_order.len + own.len);
        all[0..menu_order.len].* = .{
            .{ .id = @backingInt(Menu.file), .label = Menu.file.label(), .items = try plugin_bars.extend(gpa, file_items, .file, bars, states) },
            .{ .id = @backingInt(Menu.edit), .label = Menu.edit.label(), .items = try plugin_bars.extend(gpa, &edit_items, .edit, bars, states) },
            .{ .id = @backingInt(Menu.view), .label = Menu.view.label(), .items = try plugin_bars.extend(gpa, command_items, .view, bars, states) },
            .{ .id = @backingInt(Menu.window), .label = Menu.window.label(), .items = try plugin_bars.extend(gpa, window_items, .window, bars, states) },
            .{ .id = @backingInt(Menu.help), .label = Menu.help.label(), .items = try plugin_bars.extend(gpa, &help_items, .help, bars, states) },
        };
        @memcpy(all[menu_order.len..], own);
        self.menu_count = all.len;
        if (shown >= all.len) return all;

        // The menus that don't fit, each a submenu of the "..." menu.
        const result = try gpa.alloc(widgets.MenubarMenu, shown + 1);
        @memcpy(result[0..shown], all[0..shown]);
        const folded = try gpa.alloc(widgets.MenuItem, all.len - shown);
        for (folded, all[shown..], shown..) |*row, menu, i| row.* = .{ .id = overflow_first + @as(u32, @intCast(i)), .label = menu.label, .kind = .submenu, .items = menu.items };
        result[shown] = .{ .id = @backingInt(Menu.more), .label = Menu.more.label(), .items = folded };
        return result;
    }

    /// A left press on element `id`: on a trigger, an item, or anywhere while a menu is open
    /// (which closes it). Null when the menu bar has nothing to do with it.
    /// `id` is the hit-tested element ID, not a menu index; returns an action for the host
    /// to execute and mutates open-menu state, but performs no command side effects.
    ///
    /// ```zig
    /// if (menubar.press(hit_id, bars)) |action| switch (action) {
    ///     .command => |command| std.log.info("command: {t}", .{command}),
    ///     else => {},
    /// };
    /// ```
    pub fn press(self: *Menubar, id: u32, bars: plugin_bars.Bars) ?Action {
        const plugin = plugin_bars.pressed(bars, id);
        if (std.enums.fromInt(Menu, id) != null or plugin_bars.isMenuTrigger(bars, id) or (plugin != null and plugin.? == .status_menu)) {
            self.open = if (self.open == id) 0 else id;
            self.open_submenu = 0;
            return .handled;
        }
        // A status bar button needs no open menu; it closes any that is.
        if (plugin) |found| if (found == .action and found.action == .status) {
            self.open = 0;
            self.open_submenu = 0;
            return .{ .plugin_bar = found.action };
        };
        if (self.open == 0) return null;
        // A submenu's row (a folded menu's, in the "..." menu) opens it beside, and the menu stays open.
        if (self.isSubmenuRow(id)) {
            self.open_submenu = id;
            return .handled;
        }
        self.open = 0;
        self.open_submenu = 0;
        if (plugin) |found| return .{ .plugin_bar = found.action };
        if (id >= plugin_command_first and id - plugin_command_first < self.plugin_command_count) return .{ .plugin_command = id - plugin_command_first };
        if (id > window_item_first and id < window_item_first + dock.max_panel) return .{ .toggle_panel = id - window_item_first };
        const command = std.enums.fromInt(Command, id) orelse return .handled;
        return .{ .command = command };
    }

    /// The pointer moved onto element `id`: over a submenu's row (a folded menu's, in the "..."
    /// menu), open it beside. Returns whether that changed anything.
    /// Pass the hit-tested element ID; only an open menu reacts.
    ///
    /// ```zig
    /// _ = menubar.hover(hit_id); // Host pointer-motion route.
    /// ```
    pub fn hover(self: *Menubar, id: u32) bool {
        if (self.open == 0 or !self.isSubmenuRow(id) or self.open_submenu == id) return false;
        self.open_submenu = id;
        return true;
    }

    fn isSubmenuRow(self: *const Menubar, id: u32) bool {
        return id == open_in_row or (id >= overflow_first and id < overflow_first + self.menu_count);
    }
};

/// How many menus fit on the bar in `available` points of width at `font`; the rest fold into
/// the "..." menu, which then needs room of its own.
/// Borrows the loaded font; returns a count from zero through five, without allocating.
///
/// ```zig
/// const shown = menus.shownMenus(context.font, 240);
/// // Pass shown to Menubar.list for the same frame.
/// _ = shown;
/// ```
pub fn shownMenus(font: *const ui.Font, available: f32, bars: plugin_bars.Bars) usize {
    const total = menu_order.len + ownMenuCount(bars);
    var used: f32 = 0;
    var fitting: usize = 0;
    for (0..total) |i| {
        used += triggerWidth(font, i, bars);
        if (used > available) break;
        fitting += 1;
    } else return total;
    // Room for the "..." trigger too: drop menus until it fits.
    while (fitting > 0) : (fitting -= 1) {
        var width = widgets.flush_trigger_height;
        for (0..fitting) |i| width += triggerWidth(font, i, bars);
        if (width <= available) break;
    }
    return fitting;
}

fn ownMenuCount(bars: plugin_bars.Bars) usize {
    var count: usize = 0;
    for (bars.menus) |menu| count += @intFromBool(menu.extends == null);
    return count;
}

/// The bar's `index`th trigger: Eggy's menus, then the plugins' own.
fn triggerWidth(font: *const ui.Font, index: usize, bars: plugin_bars.Bars) f32 {
    if (index < menu_order.len) return widgets.flushTriggerWidth(font, menu_order[index].label());
    var own = index - menu_order.len;
    for (bars.menus) |menu| {
        if (menu.extends != null) continue;
        if (own == 0) return widgets.flushTriggerWidth(font, menu.title);
        own -= 1;
    }
    return 0;
}

/// Draw the "..." trigger in `tree` (from `widgets.titlebarMenubar`) as three dots, as the font
/// has no ellipsis glyph.
/// Mutates the frame tree in place and allocates replacement children from `b`; allocation
/// failures propagate. Both builder storage and tree must live through layout/draw.
///
/// ```zig
/// // Host: tree was created by widgets.titlebarMenubar in builder b.
/// try menus.drawMoreAsDots(b, tree);
/// ```
pub fn drawMoreAsDots(b: L.Builder, tree: *L.Element) !void {
    for (tree.children) |child| try drawMoreAsDots(b, child);
    if (tree.id != @backingInt(Menu.more)) return;
    // The trigger spans the bar; its look is its one child, a button.
    if (tree.children.len != 1 or tree.children[0].paint_kind != .button) return;
    const look = tree.children[0];
    look.paint_kind.button.label = "";
    look.style.width = widgets.flush_trigger_height;
    look.style.direction = .row;
    look.style.align_items = .center;
    look.style.justify = .center;
    const dots = try b.node(0, .{ .width = 14, .height = 4 }, .{ .custom = .{ .context = tree, .draw = drawDots } }, &.{});
    dots.accessibility.role = .ignored;
    look.children = try b.allocator.dupe(*L.Element, &.{dots});
    tree.accessibility.label = "More menus";
}

/// Three dots across `r`.
fn drawDots(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const side: f32 = 3;
    const y = r.center().y - side / 2;
    for (0..3) |i| {
        const x = r.x + (r.w - side) * @as(f32, @floatFromInt(i)) / 2;
        try c.roundRect(.{ .x = x, .y = y, .w = side, .h = side }, c.theme.foreground, side / 2);
    }
}

test "plugin View commands dispatch their current index without storing callbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var layout = dock.DockSpace.init();
    var menubar = Menubar{};
    const commands = [_]eggy.plugins.EditorCommand{.{ .key = "game/raise", .title = "Raise" }};
    const list = try menubar.list(arena.allocator(), &layout, &.{}, &commands, .{}, .{}, .{}, menu_order.len);
    try std.testing.expectEqualStrings("Raise", list[2].items[0].label);
    _ = menubar.press(@backingInt(Menu.view), .{});
    try std.testing.expectEqual(Action{ .plugin_command = 0 }, menubar.press(list[2].items[0].id, .{}).?);
}

test "pressing a trigger opens its menu, and an item runs and closes it" {
    var menubar = Menubar{};
    try std.testing.expectEqual(Action.handled, menubar.press(@backingInt(Menu.file), .{}).?);
    try std.testing.expectEqual(@backingInt(Menu.file), menubar.open);
    try std.testing.expectEqual(Action{ .command = .quit }, menubar.press(@backingInt(Command.quit), .{}).?);
    try std.testing.expectEqual(@as(u32, 0), menubar.open);
    try std.testing.expect(menubar.press(@backingInt(Command.quit), .{}) == null); // closed: not ours
}

test "the Window menu's items toggle their panel" {
    var menubar = Menubar{ .open = @backingInt(Menu.window) };
    const console = @backingInt(Panel.console);
    try std.testing.expectEqual(Action{ .toggle_panel = console }, menubar.press(window_item_first + console, .{}).?);
}

test "menus that don't fit fold into the \"...\" menu, and its rows open them beside it" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    try std.testing.expectEqual(menu_order.len, shownMenus(&font, 1000, .{}));
    const shown = shownMenus(&font, triggerWidth(&font, 0, .{}) + triggerWidth(&font, 1, .{}) + widgets.flush_trigger_height, .{});
    try std.testing.expectEqual(@as(usize, 2), shown);
    try std.testing.expectEqual(@as(usize, 0), shownMenus(&font, 1, .{}));

    var menubar = Menubar{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var layout = dock.DockSpace.init();
    const list = try menubar.list(arena.allocator(), &layout, &.{}, &.{}, .{}, .{}, .{}, shown);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@backingInt(Menu.more), list[2].id);
    try std.testing.expectEqualStrings("View", list[2].items[0].label);

    _ = menubar.press(@backingInt(Menu.more), .{});
    try std.testing.expect(menubar.hover(overflow_first + 3));
    try std.testing.expectEqual(Action.handled, menubar.press(overflow_first + 4, .{}).?);
    try std.testing.expectEqual(@backingInt(Menu.more), menubar.open); // still open, on Help now
    try std.testing.expectEqual(Action{ .command = .about }, menubar.press(@backingInt(Command.about), .{}).?);
    try std.testing.expectEqual(@as(u32, 0), menubar.open_submenu);
}

const test_menus = [_]eggy.plugins.EditorMenu{
    .{ .key = "tools/tools", .title = "Tools", .items = &.{ .{ .key = "tools/tools/bake", .title = "Bake" }, .{ .key = "tools/tools/clean", .title = "Clean" } } },
    .{ .key = "tools/view", .title = "Grid", .extends = .view, .items = &.{.{ .key = "tools/view/snap", .title = "Snap" }} },
};
const test_status = [_]eggy.plugins.EditorStatusItem{
    .{ .key = "tools/fps", .title = "FPS" },
    .{ .key = "tools/mode", .title = "Mode", .items = &.{.{ .key = "tools/mode/fast", .title = "Fast" }} },
};

test "plugin menus join the bar and Eggy's menus, and their rows run by place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var layout = dock.DockSpace.init();
    var menubar = Menubar{};
    const bars = plugin_bars.Bars{ .menus = &test_menus, .status_items = &test_status };
    const states = try plugin_bars.States.declared(arena.allocator(), bars);
    const list = try menubar.list(arena.allocator(), &layout, &.{}, &.{}, bars, states, .{}, menu_order.len + 1);

    // Eggy's five, then the one menu that stands alone.
    try std.testing.expectEqual(@as(usize, 6), list.len);
    try std.testing.expectEqualStrings("Tools", list[5].label);
    // The extension's row ends View.
    try std.testing.expectEqualStrings("Snap", list[2].items[list[2].items.len - 1].label);

    try std.testing.expectEqual(Action.handled, menubar.press(list[5].id, bars).?);
    const press = menubar.press(list[5].items[1].id, bars).?;
    try std.testing.expectEqual(@as(usize, 0), press.plugin_bar.menu_item.menu);
    try std.testing.expectEqual(@as(usize, 1), press.plugin_bar.menu_item.item);
    try std.testing.expectEqual(@as(u32, 0), menubar.open);

    // The extension is pressed from its own place in View.
    _ = menubar.press(@backingInt(Menu.view), bars);
    const snap = menubar.press(list[2].items[list[2].items.len - 1].id, bars).?;
    try std.testing.expectEqual(@as(usize, 1), snap.plugin_bar.menu_item.menu);
}

test "a status button acts at once and a status menu opens and closes" {
    var menubar = Menubar{ .open = @backingInt(Menu.file) };
    const bars = plugin_bars.Bars{ .menus = &test_menus, .status_items = &test_status };
    const button = menubar.press(plugin_bars.statusId(0), bars).?;
    try std.testing.expectEqual(@as(usize, 0), button.plugin_bar.status);
    try std.testing.expectEqual(@as(u32, 0), menubar.open); // a menu that was open closes

    try std.testing.expectEqual(Action.handled, menubar.press(plugin_bars.statusId(1), bars).?);
    try std.testing.expectEqual(plugin_bars.statusId(1), menubar.open);
    try std.testing.expectEqual(Action.handled, menubar.press(plugin_bars.statusId(1), bars).?);
    try std.testing.expectEqual(@as(u32, 0), menubar.open);

    // Its row runs and closes it.
    _ = menubar.press(plugin_bars.statusId(1), bars);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const states = try plugin_bars.States.declared(arena.allocator(), bars);
    const rows = try plugin_bars.statusRows(arena.allocator(), bars, states, 1);
    const row = menubar.press(rows[0].id, bars).?;
    try std.testing.expectEqual(@as(usize, 1), row.plugin_bar.status_item.status);
    try std.testing.expectEqual(@as(u32, 0), menubar.open);
}

test "plugin menus count toward what fits on the bar" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    const bars = plugin_bars.Bars{ .menus = &test_menus };
    try std.testing.expectEqual(menu_order.len + 1, shownMenus(&font, 1000, bars));
    // Room for Eggy's five but not the plugin's menu: it folds away, and so does the one before it.
    var room: f32 = widgets.flush_trigger_height;
    for (0..menu_order.len) |i| room += triggerWidth(&font, i, bars);
    try std.testing.expect(shownMenus(&font, room, bars) < menu_order.len + 1);
}
