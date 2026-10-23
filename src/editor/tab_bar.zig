//! The bar of workspace tabs under the main window's title bar (`workspace_tabs.zig`): a tab
//! per layout, the "+" that opens a new 3D, 2D or UI one, a tab's own menu (pin, pop out, close),
//! and where a panel or tab dragged onto the bar would land.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const widgets = ui.widgets;
const workspace_tabs = @import("workspace_tabs.zig");
const Kind = workspace_tabs.Kind;

pub const height: f32 = 30;

// Ids, kept below `dock.first_id`: tab i, its close button, "+", the kinds "+" offers, a tab's
// menu rows, and the drop zone that makes a new tab.
const first_id: u32 = 0x5500_0000;
const tab_first = first_id;
const close_first = first_id + 0x10;
const new_id = first_id + 0x20;
const kind_first = first_id + 0x30;
const pop_out_id = first_id + 0x40;
const close_row_id = first_id + 0x41;
const pin_row_id = first_id + 0x42;
const drop_new_id = first_id + 0x50;

/// What a press on the bar (or one of its popups) asks for.
pub const Action = union(enum) {
    show: u8,
    close: u8,
    /// "+": open the menu of kinds of tab.
    choose,
    open: Kind,
    /// The tab whose menu is open: pin or unpin it, pop it out, or close it.
    pin_open_menu,
    pop_out,
    close_open_menu,
};

/// The bar's popup open, if any: the "+" menu, or tab `i`'s menu.
pub const Popup = union(enum) { none, choose, tab: u8 };

/// Where a panel let go over the bar goes: into tab `i`, or a new tab.
pub const Drop = union(enum) { tab: u8, new };

/// What the bar shows this frame.
pub const Look = struct {
    titles: []const []const u8,
    /// The tab shown in the main window, if one is.
    active: ?u8,
    /// Which tabs are popped out into windows of their own, and which are pinned.
    popped: []const bool,
    pinned: []const bool,
    popup: Popup = .none,
    /// While a panel is dragged: where it would land.
    drop: ?Drop = null,
    /// Whether a panel is being dragged, which shows the new-tab drop zone.
    dragging: bool = false,
    /// The tab being dragged along the bar, if one is.
    carried: ?u8 = null,
    hot: u32 = 0,
};

/// What a press on element `id` asks for, if it is the bar's.
pub fn actionOf(id: u32) ?Action {
    if (id >= tab_first and id < tab_first + workspace_tabs.max_tabs) return .{ .show = @intCast(id - tab_first) };
    if (id >= close_first and id < close_first + workspace_tabs.max_tabs) return .{ .close = @intCast(id - close_first) };
    if (id == new_id) return .choose;
    if (id >= kind_first and id < kind_first + 3) return .{ .open = @enumFromInt(id - kind_first) };
    if (id == pin_row_id) return .pin_open_menu;
    if (id == pop_out_id) return .pop_out;
    if (id == close_row_id) return .close_open_menu;
    return null;
}

/// Where tab `index` was laid out in the last tree `root`, if it was.
pub fn tabBounds(root: *const L.Element, index: u8) ?ui.Rect {
    return (root.find(tab_first + @as(u32, index)) orelse return null).bounds;
}

/// The tab under (x, y) in the last tree `root`, if any.
pub fn tabAt(root: *const L.Element, count: usize, x: f32, y: f32) ?u8 {
    for (0..count) |i| if (root.find(tab_first + @as(u32, @intCast(i)))) |tab| {
        if (tab.bounds.contains(x, y)) return @intCast(i);
    };
    return null;
}

/// Where a panel let go at (x, y) would go, given the last tree `root`: onto a tab, or anywhere
/// else on the bar for a new tab. Null off the bar.
pub fn dropAt(root: *const L.Element, count: usize, x: f32, y: f32) ?Drop {
    const bar = root.find(first_id + 0xFF) orelse return null;
    if (!bar.bounds.contains(x, y)) return null;
    if (tabAt(root, count, x, y)) |tab| return .{ .tab = tab };
    return .new;
}

/// The bar, `width` wide, with its popups anchored to it.
pub fn element(b: L.Builder, width: f32, font: *const ui.Font, look: Look) !*L.Element {
    var children: std.ArrayList(*L.Element) = .empty;
    var popups: std.ArrayList(*L.Element) = .empty;
    for (look.titles, 0..) |title, i| {
        const index: u8 = @intCast(i);
        const tab = try tabElement(b, index, title, font.measure(title, 13), look);
        try children.append(b.allocator, tab);
        if (look.popup == .tab and look.popup.tab == index) {
            const rows = [_]widgets.MenuItem{
                .{ .id = pin_row_id, .label = if (look.pinned[i]) "Unpin tab" else "Pin tab" },
                .{ .id = pop_out_id, .label = if (look.popped[i]) "Bring back into the window" else "Pop out into window" },
                .{ .id = close_row_id, .label = "Close tab", .disabled = look.pinned[i] },
            };
            try popups.append(b.allocator, widgets.anchorTo(try widgets.sizedMenuItems(b, &rows, look.hot, 0, .sm), tab, .bottom, 300));
        }
    }

    // "+", then while a panel is carried, a zone that makes a new tab of it.
    const plus = try b.node(new_id, .{ .width = 26, .height = 24 }, .{ .button = .{ .label = "+", .variant = .ghost, .size = .sm, .hot = look.hot == new_id or look.popup == .choose } }, &.{});
    plus.accessibility = .{ .role = .button, .label = "New tab", .expanded = look.popup == .choose };
    try children.append(b.allocator, plus);
    if (look.popup == .choose) {
        const rows = [_]widgets.MenuItem{
            .{ .id = kind_first + @intFromEnum(Kind.scene_3d), .label = "3D Scene" },
            .{ .id = kind_first + @intFromEnum(Kind.scene_2d), .label = "2D Scene" },
            .{ .id = kind_first + @intFromEnum(Kind.ui), .label = "UI Scene" },
        };
        try popups.append(b.allocator, widgets.anchorTo(try widgets.sizedMenuItems(b, &rows, look.hot, 0, .sm), plus, .bottom, 300));
    }
    if (look.dragging) {
        const zone_look = try b.allocator.create(DropZone);
        zone_look.* = .{ .lit = look.drop != null and look.drop.? == .new };
        try children.append(b.allocator, try b.node(drop_new_id, .{ .width = 150, .height = 24 }, .{ .custom = .{ .context = zone_look, .draw = DropZone.draw } }, &.{}));
    }
    try children.appendSlice(b.allocator, popups.items);

    const bar = try b.node(first_id + 0xFF, .{ .width = width, .height = height, .direction = .row, .align_items = .center, .gap = 2, .padding = .{ .left = 6, .right = 6 } }, .{ .surface = .sidebar }, children.items);
    bar.accessibility = .{ .role = .tab_list, .label = "Workspace tabs" };
    return bar;
}

/// One tab: its title, then a close button, or a pin mark when it is pinned.
fn tabElement(b: L.Builder, index: u8, title: []const u8, title_width: f32, look: Look) !*L.Element {
    const tab_look = try b.allocator.create(TabLook);
    const dropping = look.drop != null and look.drop.? == .tab and look.drop.?.tab == index;
    const carried = look.carried != null and look.carried.? == index;
    tab_look.* = .{ .title = title, .active = look.active != null and look.active.? == index, .hot = look.hot == tab_first + index or dropping, .popped = look.popped[index], .pinned = look.pinned[index], .carried = carried };
    var kids: std.ArrayList(*L.Element) = .empty;
    if (!look.pinned[index]) {
        const close = try b.node(close_first + index, .{ .width = 16, .height = 16 }, .{ .icon = .x }, &.{});
        close.accessibility = .{ .role = .button, .label = "Close tab" };
        try kids.append(b.allocator, close);
    }
    const tab = try b.node(tab_first + index, .{ .height = 24, .direction = .row, .align_items = .center, .padding = .{ .left = 12 + title_width + 8, .right = if (look.pinned[index]) 22 else 6 } }, .{ .custom = .{ .context = tab_look, .draw = TabLook.draw } }, kids.items);
    tab.accessibility = .{ .role = .tab, .label = title, .expanded = look.active != null and look.active.? == index, .description = if (look.pinned[index]) "Pinned" else null };
    tab.cursor = .pointer;
    return tab;
}

const TabLook = struct {
    title: []const u8,
    active: bool,
    hot: bool,
    popped: bool,
    pinned: bool,
    /// Being dragged: drawn faint, as the bar does a dragged dock tab.
    carried: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const TabLook = @ptrCast(@alignCast(context));
        if (self.active) try c.roundRect(r, c.theme.background, 6) else if (self.hot) try c.roundRectAlpha(r, c.theme.muted, 6, 0.8);
        if (self.carried) try c.roundRectStroke(r, c.theme.primary, 6, 1);
        const tone = if (self.active) c.theme.foreground else c.theme.muted_foreground;
        try c.textIn(.{ .x = r.x + 12, .y = r.y, .w = r.w - 12, .h = r.h }, self.title, 13, tone, .start);
        // A pinned tab shows a pushpin where the close button would be: a round head on a stem.
        if (self.pinned) {
            const x = r.x + r.w - 14;
            const y = r.y + r.h / 2;
            try c.roundRect(.{ .x = x - 3, .y = y - 6, .w = 6, .h = 6 }, tone, 3);
            try c.rect(.{ .x = x - 4, .y = y - 1, .w = 8, .h = 1.5 }, tone);
            try c.rect(.{ .x = x - 0.5, .y = y, .w = 1, .h = 5 }, tone);
        }
        // The shown tab is marked along its foot; a popped-out one along its top.
        if (self.active) try c.rect(.{ .x = r.x + 8, .y = r.y + r.h - 2, .w = r.w - 16, .h = 2 }, c.theme.primary);
        if (self.popped) try c.rect(.{ .x = r.x + 8, .y = r.y, .w = r.w - 16, .h = 1 }, c.theme.muted_foreground);
    }
};

const DropZone = struct {
    lit: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const DropZone = @ptrCast(@alignCast(context));
        if (self.lit) try c.roundRectAlpha(r, c.theme.primary, 6, 0.25);
        try c.roundRectStroke(r, if (self.lit) c.theme.primary else c.theme.border, 6, 1);
        try c.textIn(r, "Drop here for a new tab", 12, c.theme.muted_foreground, .center);
    }
};

test "the bar's ids say what a press asks for" {
    try std.testing.expectEqual(Action{ .show = 2 }, actionOf(tab_first + 2).?);
    try std.testing.expectEqual(Action{ .close = 1 }, actionOf(close_first + 1).?);
    try std.testing.expectEqual(Action{ .open = .ui }, actionOf(kind_first + @intFromEnum(Kind.ui)).?);
    try std.testing.expectEqual(Action.choose, actionOf(new_id).?);
    try std.testing.expectEqual(Action.pin_open_menu, actionOf(pin_row_id).?);
    try std.testing.expect(actionOf(first_id + 0x99) == null);
}
