//! The editor's menus (File, Edit, View, Window, Help): their items, and what pressing one does.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const widgets = ui.widgets;
const dock = ui.dock;
const panels = @import("panels.zig");
const Panel = panels.Panel;

// Ids, kept below `dock.first_id`.
const first_id: u32 = 0x4D00_0000;
pub const Menu = enum(u32) { file = first_id, edit, view, window, help };
pub const Command = enum(u32) {
    new_project = first_id + 0x100,
    open_project,
    save,
    quit,
    undo,
    redo,
    preferences,
    reset_layout,
    about,
};
/// Window menu items: `window_item_first` + panel id.
const window_item_first: u32 = first_id + 0x200;

/// What a press on the menu bar asks for.
pub const Action = union(enum) {
    /// The press opened, closed or switched a menu, or closed one by landing elsewhere.
    handled,
    /// Window > (panel): show it if hidden, else hide it.
    toggle_panel: u32,
    command: Command,
};

/// The menu bar's state: which menu is open.
pub const Menubar = struct {
    /// Trigger id of the open menu, or 0.
    open: u32 = 0,

    /// The menus as `widgets` draws them. Window lists each panel, the built-in ones then
    /// `plugin_panels`, checked while `layout` shows it.
    pub fn list(_: *const Menubar, gpa: std.mem.Allocator, layout: *const dock.DockSpace, plugin_panels: []const eggy.plugins.EditorPanel) ![]const widgets.MenubarMenu {
        const built_in = std.enums.values(Panel);
        const window_items = try gpa.alloc(widgets.MenuItem, built_in.len + plugin_panels.len + 2);
        for (window_items[0 .. built_in.len + plugin_panels.len], 0..) |*item, i| {
            const id: u32 = if (i < built_in.len) @intFromEnum(built_in[i]) else panels.plugin_first + @as(u32, @intCast(i - built_in.len));
            item.* = .{ .id = window_item_first + id, .label = panels.panelTitle(id, plugin_panels), .kind = .checkbox, .checked = layout.nodeOf(id) != null };
        }
        window_items[window_items.len - 2] = .{ .kind = .separator };
        window_items[window_items.len - 1] = .{ .id = @intFromEnum(Command.reset_layout), .label = "Reset Layout" };

        return gpa.dupe(widgets.MenubarMenu, &.{
            .{ .id = @intFromEnum(Menu.file), .label = "File", .items = &.{
                .{ .id = @intFromEnum(Command.new_project), .label = "New Project...", .shortcut = "Ctrl+N" },
                .{ .id = @intFromEnum(Command.open_project), .label = "Open Project...", .shortcut = "Ctrl+O" },
                .{ .id = @intFromEnum(Command.save), .label = "Save", .shortcut = "Ctrl+S" },
                .{ .kind = .separator },
                .{ .id = @intFromEnum(Command.quit), .label = "Quit", .shortcut = "Ctrl+Q" },
            } },
            .{ .id = @intFromEnum(Menu.edit), .label = "Edit", .items = &.{
                .{ .id = @intFromEnum(Command.undo), .label = "Undo", .shortcut = "Ctrl+Z" },
                .{ .id = @intFromEnum(Command.redo), .label = "Redo", .shortcut = "Ctrl+Shift+Z" },
                .{ .kind = .separator },
                .{ .id = @intFromEnum(Command.preferences), .label = "Preferences..." },
            } },
            .{ .id = @intFromEnum(Menu.view), .label = "View", .items = &.{} },
            .{ .id = @intFromEnum(Menu.window), .label = "Window", .items = window_items },
            .{ .id = @intFromEnum(Menu.help), .label = "Help", .items = &.{
                .{ .id = @intFromEnum(Command.about), .label = "About Eggy" },
            } },
        });
    }

    /// A left press on element `id`: on a trigger, an item, or anywhere while a menu is open
    /// (which closes it). Null when the menu bar has nothing to do with it.
    pub fn press(self: *Menubar, id: u32) ?Action {
        if (std.enums.fromInt(Menu, id) != null) {
            self.open = if (self.open == id) 0 else id;
            return .handled;
        }
        if (self.open == 0) return null;
        self.open = 0;
        if (id > window_item_first and id < window_item_first + dock.max_panel) return .{ .toggle_panel = id - window_item_first };
        const command = std.enums.fromInt(Command, id) orelse return .handled;
        return .{ .command = command };
    }
};

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
