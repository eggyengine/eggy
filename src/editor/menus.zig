//! The editor's menus (File, Edit, View, Window, Help): their items, and what pressing one does.
//! Menus that don't fit beside the play button fold into a "..." menu, as VS Code's do. Weeoui
//! draws them compact, as a desktop menu bar's are.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const widgets = ui.widgets;
const L = ui.Layout;
const dock = ui.dock;
const panels = @import("panels.zig");
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
    open_project_folder,
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
};
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
};

/// The menu bar's state: which menu is open.
pub const Menubar = struct {
    plugin_command_count: usize = 0,
    /// Trigger id of the open menu, or 0.
    open: u32 = 0,
    /// The "..." menu's row whose menu is open beside it, or 0.
    open_submenu: u32 = 0,

    /// The menus as `widgets` draws them: the first `shown` (see `shownMenus`) on the bar and the
    /// rest in the "..." menu. Window lists each panel, the built-in ones then `plugin_panels`,
    /// checked while `layout` shows it.
    pub fn list(self: *Menubar, gpa: std.mem.Allocator, layout: *const dock.DockSpace, plugin_panels: []const eggy.plugins.EditorPanel, plugin_commands: []const eggy.plugins.EditorCommand, project: ProjectState, shown: usize) ![]const widgets.MenubarMenu {
        if (plugin_commands.len > 65536) return error.TooManyEditorCommands;
        self.plugin_command_count = plugin_commands.len;
        const command_items = try gpa.alloc(widgets.MenuItem, plugin_commands.len);
        for (command_items, plugin_commands, 0..) |*item, command, index| item.* = .{ .id = plugin_command_first + @as(u32, @intCast(index)), .label = command.title };
        const built_in = std.enums.values(Panel);
        const window_items = try gpa.alloc(widgets.MenuItem, built_in.len + plugin_panels.len + 2);
        for (window_items[0 .. built_in.len + plugin_panels.len], 0..) |*item, i| {
            const id: u32 = if (i < built_in.len) @intFromEnum(built_in[i]) else panels.pluginId(plugin_panels[i - built_in.len], i - built_in.len);
            item.* = .{ .id = window_item_first + id, .label = panels.panelTitle(id, plugin_panels), .kind = .checkbox, .checked = layout.nodeOf(id) != null };
        }
        window_items[window_items.len - 2] = .{ .kind = .separator };
        window_items[window_items.len - 1] = .{ .id = @intFromEnum(Command.reset_layout), .label = "Reset Layout" };

        const file_items = try gpa.dupe(widgets.MenuItem, &.{
            .{ .id = @intFromEnum(Command.new_project), .label = "New Project...", .shortcut = "Ctrl+N" },
            if (project.shift_held)
                .{ .id = @intFromEnum(Command.open_project_linked), .label = "Open Project with Developer Eggy...", .disabled = !project.developer_known }
            else
                .{ .id = @intFromEnum(Command.open_project), .label = "Open Project...", .shortcut = "Ctrl+O" },
            .{ .id = @intFromEnum(Command.open_project_folder), .label = "Open Project Folder", .disabled = !project.open },
            .{ .id = @intFromEnum(Command.save), .label = "Save", .shortcut = "Ctrl+S" },
            .{ .id = @intFromEnum(Command.export_game), .label = "Export...", .disabled = !project.open },
            .{ .id = @intFromEnum(Command.project_settings), .label = "Project Settings...", .disabled = !project.open },
            .{ .kind = .separator },
            if (project.shift_held)
                .{ .id = @intFromEnum(Command.link_developer), .label = "Link Developer Eggy...", .disabled = !project.can_link }
            else
                .{ .id = @intFromEnum(Command.upgrade_editor), .label = "Upgrade Editor", .disabled = !project.can_upgrade },
            .{ .kind = .separator },
            .{ .id = @intFromEnum(Command.quit), .label = "Quit", .shortcut = "Ctrl+Q" },
        });

        const all = [menu_order.len]widgets.MenubarMenu{
            .{ .id = @intFromEnum(Menu.file), .label = Menu.file.label(), .items = file_items },
            .{ .id = @intFromEnum(Menu.edit), .label = Menu.edit.label(), .items = &.{
                .{ .id = @intFromEnum(Command.undo), .label = "Undo", .shortcut = "Ctrl+Z" },
                .{ .id = @intFromEnum(Command.redo), .label = "Redo", .shortcut = "Ctrl+Shift+Z" },
                .{ .kind = .separator },
                .{ .id = @intFromEnum(Command.preferences), .label = "Preferences..." },
            } },
            .{ .id = @intFromEnum(Menu.view), .label = Menu.view.label(), .items = command_items },
            .{ .id = @intFromEnum(Menu.window), .label = Menu.window.label(), .items = window_items },
            .{ .id = @intFromEnum(Menu.help), .label = Menu.help.label(), .items = &.{
                .{ .id = @intFromEnum(Command.devtools), .label = "DevTools", .shortcut = "F12" },
                .{ .kind = .separator },
                .{ .id = @intFromEnum(Command.about), .label = "About Eggy" },
            } },
        };
        if (shown >= all.len) return gpa.dupe(widgets.MenubarMenu, &all);

        // The menus that don't fit, each a submenu of the "..." menu.
        const result = try gpa.alloc(widgets.MenubarMenu, shown + 1);
        @memcpy(result[0..shown], all[0..shown]);
        const folded = try gpa.alloc(widgets.MenuItem, all.len - shown);
        for (folded, all[shown..], shown..) |*row, menu, i| row.* = .{ .id = overflow_first + @as(u32, @intCast(i)), .label = menu.label, .kind = .submenu, .items = menu.items };
        result[shown] = .{ .id = @intFromEnum(Menu.more), .label = Menu.more.label(), .items = folded };
        return result;
    }

    /// A left press on element `id`: on a trigger, an item, or anywhere while a menu is open
    /// (which closes it). Null when the menu bar has nothing to do with it.
    pub fn press(self: *Menubar, id: u32) ?Action {
        if (std.enums.fromInt(Menu, id) != null) {
            self.open = if (self.open == id) 0 else id;
            self.open_submenu = 0;
            return .handled;
        }
        if (self.open == 0) return null;
        // A folded menu's row opens it beside the "..." menu, which stays open.
        if (isOverflowRow(id)) {
            self.open_submenu = id;
            return .handled;
        }
        self.open = 0;
        self.open_submenu = 0;
        if (id >= plugin_command_first and id - plugin_command_first < self.plugin_command_count) return .{ .plugin_command = id - plugin_command_first };
        if (id > window_item_first and id < window_item_first + dock.max_panel) return .{ .toggle_panel = id - window_item_first };
        const command = std.enums.fromInt(Command, id) orelse return .handled;
        return .{ .command = command };
    }

    /// The pointer moved onto element `id`: over a folded menu's row, open that menu beside it.
    /// Returns whether that changed anything.
    pub fn hover(self: *Menubar, id: u32) bool {
        if (self.open != @intFromEnum(Menu.more) or !isOverflowRow(id) or self.open_submenu == id) return false;
        self.open_submenu = id;
        return true;
    }

    fn isOverflowRow(id: u32) bool {
        return id >= overflow_first and id < overflow_first + menu_order.len;
    }
};

/// How many menus fit on the bar in `available` points of width at `font`; the rest fold into
/// the "..." menu, which then needs room of its own.
pub fn shownMenus(font: *const ui.Font, available: f32) usize {
    var used: f32 = 0;
    var fitting: usize = 0;
    for (menu_order) |menu| {
        used += triggerWidth(font, menu);
        if (used > available) break;
        fitting += 1;
    } else return menu_order.len;
    // Room for the "..." trigger too: drop menus until it fits.
    while (fitting > 0) : (fitting -= 1) {
        var width = triggerWidth(font, .more);
        for (menu_order[0..fitting]) |menu| width += triggerWidth(font, menu);
        if (width <= available) break;
    }
    return fitting;
}

fn triggerWidth(font: *const ui.Font, menu: Menu) f32 {
    if (menu == .more) return widgets.flush_trigger_height;
    return widgets.flushTriggerWidth(font, menu.label());
}

/// Draw the "..." trigger in `tree` (from `widgets.titlebarMenubar`) as three dots, as the font
/// has no ellipsis glyph.
pub fn drawMoreAsDots(b: L.Builder, tree: *L.Element) !void {
    for (tree.children) |child| try drawMoreAsDots(b, child);
    if (tree.id != @intFromEnum(Menu.more)) return;
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
    const list = try menubar.list(arena.allocator(), &layout, &.{}, &commands, .{}, menu_order.len);
    try std.testing.expectEqualStrings("Raise", list[2].items[0].label);
    _ = menubar.press(@intFromEnum(Menu.view));
    try std.testing.expectEqual(Action{ .plugin_command = 0 }, menubar.press(list[2].items[0].id).?);
}

test "pressing a trigger opens its menu, and an item runs and closes it" {
    var menubar = Menubar{};
    try std.testing.expectEqual(Action.handled, menubar.press(@intFromEnum(Menu.file)).?);
    try std.testing.expectEqual(@intFromEnum(Menu.file), menubar.open);
    try std.testing.expectEqual(Action{ .command = .quit }, menubar.press(@intFromEnum(Command.quit)).?);
    try std.testing.expectEqual(@as(u32, 0), menubar.open);
    try std.testing.expect(menubar.press(@intFromEnum(Command.quit)) == null); // closed: not ours
}

test "the Window menu's items toggle their panel" {
    var menubar = Menubar{ .open = @intFromEnum(Menu.window) };
    const console = @intFromEnum(Panel.console);
    try std.testing.expectEqual(Action{ .toggle_panel = console }, menubar.press(window_item_first + console).?);
}

test "menus that don't fit fold into the \"...\" menu, and its rows open them beside it" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    try std.testing.expectEqual(menu_order.len, shownMenus(&font, 1000));
    const shown = shownMenus(&font, triggerWidth(&font, .file) + triggerWidth(&font, .edit) + triggerWidth(&font, .more));
    try std.testing.expectEqual(@as(usize, 2), shown);
    try std.testing.expectEqual(@as(usize, 0), shownMenus(&font, 1));

    var menubar = Menubar{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var layout = dock.DockSpace.init();
    const list = try menubar.list(arena.allocator(), &layout, &.{}, &.{}, .{}, shown);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@intFromEnum(Menu.more), list[2].id);
    try std.testing.expectEqualStrings("View", list[2].items[0].label);

    _ = menubar.press(@intFromEnum(Menu.more));
    try std.testing.expect(menubar.hover(overflow_first + 3));
    try std.testing.expectEqual(Action.handled, menubar.press(overflow_first + 4).?);
    try std.testing.expectEqual(@intFromEnum(Menu.more), menubar.open); // still open, on Help now
    try std.testing.expectEqual(Action{ .command = .about }, menubar.press(@intFromEnum(Command.about)).?);
    try std.testing.expectEqual(@as(u32, 0), menubar.open_submenu);
}
