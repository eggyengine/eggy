//! Plugin menus and status bar entries as the editor's bars draw them: their element ids, the
//! rows they become, and which entry a pressed id means. Everything is derived from the
//! library's current metadata each frame; no callback or index outlives a hot reload.
const std = @import("std");
const eggy = @import("eggy");
const widgets = eggy.ui.widgets;
const plugins = eggy.plugins;

// Ids, kept below `dock.first_id`, in ranges that leave `menus.zig`'s own alone.
const first_id: u32 = 0x4D02_0000;
/// A plugin menu's trigger on the bar: `menu_trigger_first` + its index in `Bars.menus`.
const menu_trigger_first: u32 = first_id;
/// A menu row: `menu_row_first` + its place among every plugin menu's rows, in order.
const menu_row_first: u32 = first_id + 0x1000;
/// A status item's button: `status_first` + its index in `Bars.status_items`.
const status_first: u32 = first_id + 0x2000;
/// A status item's menu row: `status_row_first` + its place among every status item's rows.
const status_row_first: u32 = first_id + 0x3000;
/// How many of each the ids leave room for.
const room: usize = 0x1000;

/// The library's current plugin menus and status entries, borrowed from `HotGame`.
pub const Bars = struct {
    menus: []const plugins.EditorMenu = &.{},
    status_items: []const plugins.EditorStatusItem = &.{},

    /// Whether the ids have room for everything declared.
    pub fn fits(self: Bars) bool {
        return self.menus.len <= room and self.status_items.len <= room and rowCount(self.menus) <= room and rowCount(self.status_items) <= room;
    }
};

/// How each entry looks this frame, in the same order as `Bars` declares them: every plugin
/// menu's rows one after another, each status item, then every status item's rows.
pub const States = struct {
    menu_rows: []const plugins.EditorBarState = &.{},
    status: []const plugins.EditorBarState = &.{},
    status_rows: []const plugins.EditorBarState = &.{},

    /// Whether these states have exactly one entry for each of `bars`' menus, status items and
    /// rows, so indexing them by `bars` is safe.
    pub fn matches(self: States, bars: Bars) bool {
        return self.menu_rows.len == rowCount(bars.menus) and self.status.len == bars.status_items.len and self.status_rows.len == rowCount(bars.status_items);
    }

    /// The states of `bars` with nothing asked of the plugins: every entry as declared.
    ///
    /// ```zig
    /// const states = try plugin_bars.States.declared(arena, bars);
    /// ```
    pub fn declared(arena: std.mem.Allocator, bars: Bars) !States {
        const menu_rows = try arena.alloc(plugins.EditorBarState, rowCount(bars.menus));
        const status = try arena.alloc(plugins.EditorBarState, bars.status_items.len);
        const status_rows = try arena.alloc(plugins.EditorBarState, rowCount(bars.status_items));
        @memset(menu_rows, .{});
        @memset(status, .{});
        @memset(status_rows, .{});
        return .{ .menu_rows = menu_rows, .status = status, .status_rows = status_rows };
    }
};

/// What a pressed id means.
pub const Press = union(enum) {
    /// Open or close the status item's menu.
    status_menu: usize,
    action: plugins.EditorBarTarget,
};

fn rowCount(owners: anytype) usize {
    var count: usize = 0;
    for (owners) |owner| count += owner.items.len;
    return count;
}

fn rows(arena: std.mem.Allocator, first_row: u32, first_state: usize, items: []const plugins.EditorMenuItem, states: []const plugins.EditorBarState) ![]widgets.MenuItem {
    const result = try arena.alloc(widgets.MenuItem, items.len);
    for (result, items, 0..) |*row, item, i| {
        const state = states[first_state + i];
        row.* = .{
            .id = first_row + @as(u32, @intCast(first_state + i)),
            .label = item.title,
            .shortcut = item.shortcut,
            .kind = if (item.checkable) .checkbox else .item,
            .checked = state.checked,
            .disabled = !state.enabled,
        };
    }
    return result;
}

/// `items`, one of Eggy's menus, with the rows of every plugin menu that extends `menu` added
/// after a separator each. Allocates from `arena`, which must outlive drawing.
///
/// ```zig
/// const view_items = try plugin_bars.extend(arena, built_in, .view, bars, states);
/// ```
pub fn extend(arena: std.mem.Allocator, items: []const widgets.MenuItem, menu: plugins.BuiltinMenu, bars: Bars, states: States) ![]const widgets.MenuItem {
    var all: std.ArrayList(widgets.MenuItem) = .empty;
    try all.appendSlice(arena, items);
    var first_state: usize = 0;
    for (bars.menus) |plugin_menu| {
        defer first_state += plugin_menu.items.len;
        if (plugin_menu.extends != menu or plugin_menu.items.len == 0) continue;
        if (all.items.len > 0) try all.append(arena, .{ .kind = .separator });
        try all.appendSlice(arena, try rows(arena, menu_row_first, first_state, plugin_menu.items, states.menu_rows));
    }
    return all.items;
}

/// The plugin menus that are menus of their own, as bar triggers, in declaration order.
///
/// ```zig
/// const own = try plugin_bars.ownMenus(arena, bars, states);
/// ```
pub fn ownMenus(arena: std.mem.Allocator, bars: Bars, states: States) ![]const widgets.MenubarMenu {
    var all: std.ArrayList(widgets.MenubarMenu) = .empty;
    var first_state: usize = 0;
    for (bars.menus, 0..) |plugin_menu, index| {
        defer first_state += plugin_menu.items.len;
        if (plugin_menu.extends != null) continue;
        try all.append(arena, .{
            .id = menu_trigger_first + @as(u32, @intCast(index)),
            .label = plugin_menu.title,
            .items = try rows(arena, menu_row_first, first_state, plugin_menu.items, states.menu_rows),
        });
    }
    return all.items;
}

/// The rows of status item `index`'s menu, empty for a plain button.
///
/// ```zig
/// const rows = try plugin_bars.statusRows(arena, bars, states, 0);
/// ```
pub fn statusRows(arena: std.mem.Allocator, bars: Bars, states: States, index: usize) ![]const widgets.MenuItem {
    var first_state: usize = 0;
    for (bars.status_items[0..index]) |item| first_state += item.items.len;
    return rows(arena, status_row_first, first_state, bars.status_items[index].items, states.status_rows);
}

/// The id of status item `index`'s button.
pub fn statusId(index: usize) u32 {
    return status_first + @as(u32, @intCast(index));
}

/// The id of plugin menu `index`'s trigger.
pub fn menuTriggerId(index: usize) u32 {
    return menu_trigger_first + @as(u32, @intCast(index));
}

/// Whether `id` is a plugin menu's trigger on the bar.
pub fn isMenuTrigger(bars: Bars, id: u32) bool {
    return id >= menu_trigger_first and id - menu_trigger_first < bars.menus.len and bars.menus[id - menu_trigger_first].extends == null;
}

/// What pressing `id` means, or null when it isn't a plugin entry. Rows past the metadata, from
/// a library since swapped, are not entries.
///
/// ```zig
/// if (plugin_bars.pressed(bars, id)) |press| switch (press) { ... }
/// ```
pub fn pressed(bars: Bars, id: u32) ?Press {
    if (id >= menu_row_first and id < menu_row_first + room) {
        var left = id - menu_row_first;
        for (bars.menus, 0..) |menu, index| {
            if (left < menu.items.len) return .{ .action = .{ .menu_item = .{ .menu = index, .item = left } } };
            left -= @intCast(menu.items.len);
        }
        return null;
    }
    if (id >= status_row_first and id < status_row_first + room) {
        var left = id - status_row_first;
        for (bars.status_items, 0..) |status, index| {
            if (left < status.items.len) return .{ .action = .{ .status_item = .{ .status = index, .item = left } } };
            left -= @intCast(status.items.len);
        }
        return null;
    }
    if (id >= status_first and id - status_first < bars.status_items.len) {
        const index = id - status_first;
        if (bars.status_items[index].items.len > 0) return .{ .status_menu = index };
        return .{ .action = .{ .status = index } };
    }
    return null;
}

const test_menus = [_]plugins.EditorMenu{
    .{ .key = "a/tools", .title = "Tools", .items = &.{ .{ .key = "a/tools/one", .title = "One" }, .{ .key = "a/tools/two", .title = "Two", .checkable = true } } },
    .{ .key = "b/more", .title = "More", .extends = .view, .items = &.{.{ .key = "b/more/grid", .title = "Grid" }} },
};
const test_status = [_]plugins.EditorStatusItem{
    .{ .key = "a/fps", .title = "FPS" },
    .{ .key = "a/mode", .title = "Mode", .items = &.{ .{ .key = "a/mode/x", .title = "X" }, .{ .key = "a/mode/y", .title = "Y" } } },
};

test "plugin menus become bar triggers or rows of Eggy's menus" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bars = Bars{ .menus = &test_menus, .status_items = &test_status };
    var states = try States.declared(arena, bars);
    const menu_rows = try arena.dupe(plugins.EditorBarState, states.menu_rows);
    menu_rows[1] = .{ .checked = true, .enabled = false };
    states.menu_rows = menu_rows;

    const own = try ownMenus(arena, bars, states);
    try std.testing.expectEqual(@as(usize, 1), own.len);
    try std.testing.expectEqualStrings("Tools", own[0].label);
    try std.testing.expect(own[0].items[1].checked and own[0].items[1].disabled);

    const view = try extend(arena, &.{.{ .id = 1, .label = "Panels" }}, .view, bars, states);
    try std.testing.expectEqual(@as(usize, 3), view.len);
    try std.testing.expectEqualStrings("Grid", view[2].label);
    // Menus nothing extends keep their rows as they were.
    try std.testing.expectEqual(@as(usize, 1), (try extend(arena, &.{.{ .id = 1, .label = "Panels" }}, .edit, bars, states)).len);
}

test "a pressed id names the entry by its place, and ids past the metadata name nothing" {
    const bars = Bars{ .menus = &test_menus, .status_items = &test_status };
    try std.testing.expect(isMenuTrigger(bars, menuTriggerId(0)));
    // The View extension has no trigger of its own.
    try std.testing.expect(!isMenuTrigger(bars, menuTriggerId(1)));

    // Row 2 is the extending menu's first and only row.
    const grid = pressed(bars, menu_row_first + 2).?;
    try std.testing.expectEqual(@as(usize, 1), grid.action.menu_item.menu);
    try std.testing.expectEqual(@as(usize, 0), grid.action.menu_item.item);
    try std.testing.expect(pressed(bars, menu_row_first + 3) == null);

    try std.testing.expectEqual(@as(usize, 0), pressed(bars, statusId(0)).?.action.status);
    try std.testing.expectEqual(@as(usize, 1), pressed(bars, statusId(1)).?.status_menu);
    const y = pressed(bars, status_row_first + 1).?;
    try std.testing.expectEqual(@as(usize, 1), y.action.status_item.item);
    try std.testing.expect(pressed(bars, status_row_first + 2) == null);
    try std.testing.expect(pressed(bars, statusId(2)) == null);

    // Once the library is swapped for one with fewer entries, old ids go nowhere.
    try std.testing.expect(pressed(.{}, menu_row_first) == null);
    try std.testing.expect(pressed(.{}, statusId(0)) == null);
}
