//! The workspace's tabs: whole dock layouts side by side in the main window, one shown at a
//! time, as an editor's 3D, 2D and UI workspaces are. Each tab is a tree of the one dock's nodes:
//! the tab shown is the dock's main root, the others wait as trees of their own, and a tab
//! popped out is the root of one of the dock's OS windows, so it is a dock inside a window.
const std = @import("std");
const eggy = @import("eggy");
const dock = eggy.ui.dock;

/// What a tab is for, which names it and sets what it opens with.
pub const Kind = enum(u8) {
    /// The world in 3D: the Scene panel and what works on it.
    scene_3d,
    /// The world seen flat, for 2D games: the 2D Scene panel.
    scene_2d,
    /// The UI Designer's panels.
    ui,
    /// Panels dragged onto the tab bar: named after its first panel.
    panels,

    /// The name of a tab of this kind (`.panels` tabs are named after a panel instead).
    pub fn title(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .scene_3d => "3D",
            .scene_2d => "2D",
            .ui => "UI",
            .panels => "Panels",
        };
    }
};

pub const max_tabs = 8;

/// One tab: the root node of its tree in the dock, and what it is for.
pub const Tab = struct { root: u8, kind: Kind };

/// The tabs, in order. The first is the 3D one, which can't be closed, and there is always one
/// shown (`active`), whose tree is the dock's main root.
pub const Tabs = struct {
    list: [max_tabs]?Tab = @splat(null),
    active: u8 = 0,

    /// One 3D tab, holding the main root of `layout` as it is.
    pub fn init(layout: *const dock.DockSpace) Tabs {
        var self = Tabs{};
        self.list[0] = .{ .root = layout.root, .kind = .scene_3d };
        return self;
    }

    /// How many tabs there are; they are packed at the front of `list`.
    pub fn count(self: *const Tabs) usize {
        for (self.list, 0..) |tab, i| if (tab == null) return i;
        return max_tabs;
    }

    /// The tab whose tree has root node `root`, if any.
    pub fn ofRoot(self: *const Tabs, root: u8) ?usize {
        for (self.list, 0..) |tab, i| if (tab) |found| if (found.root == root) return i;
        return null;
    }

    /// The first tab of `kind`, if one is open.
    pub fn ofKind(self: *const Tabs, kind: Kind) ?usize {
        for (self.list, 0..) |tab, i| if (tab) |found| if (found.kind == kind) return i;
        return null;
    }

    /// The tab holding `panel`, wherever it is in that tab's tree; null when it floats, is
    /// popped out on its own, or isn't open.
    pub fn ofPanel(self: *const Tabs, layout: *const dock.DockSpace, panel: u32) ?usize {
        const stack = layout.nodeOf(panel) orelse return null;
        return self.ofRoot(topOf(layout, stack));
    }

    /// The OS window tab `index` is popped out into, if it is.
    pub fn windowOf(self: *const Tabs, layout: *const dock.DockSpace, index: usize) ?usize {
        const tab = self.list[index] orelse return null;
        for (layout.windows, 0..) |window, i| if (window) |placed| if (placed.root == tab.root) return i;
        return null;
    }

    /// Show tab `index` in the main window. A tab popped out comes back in first.
    pub fn show(self: *Tabs, layout: *dock.DockSpace, index: usize) void {
        const tab = self.list[index] orelse return;
        if (self.windowOf(layout, index)) |window| layout.windows[window] = null;
        layout.root = tab.root;
        layout.menu = 0xFF;
        self.active = @intCast(index);
    }

    /// Open a new, empty tab of `kind` after the others, shown. Fails when there are already
    /// `max_tabs`, or the dock has no node left for it.
    pub fn open(self: *Tabs, layout: *dock.DockSpace, kind: Kind) !usize {
        // A tab whose tree the dock freed goes first, so its root isn't handed to two tabs.
        self.prune(layout);
        const index = self.count();
        if (index == max_tabs) return error.TooManyTabs;
        const root = for (&layout.nodes, 0..) |*node, i| {
            if (node.kind == .free) {
                node.* = .{ .kind = .tabs };
                break @as(u8, @intCast(i));
            }
        } else return error.TooManyDockNodes;
        self.list[index] = .{ .root = root, .kind = kind };
        self.show(layout, index);
        return index;
    }

    /// A tab stack of tab `index`'s tree to put a panel in: the largest it had when last laid out.
    pub fn stackOf(self: *const Tabs, layout: *const dock.DockSpace, index: usize) ?u8 {
        const tab = self.list[index] orelse return null;
        return largest(layout, tab.root);
    }

    /// Pop tab `index` out into an OS window of its own, `size` big, showing another tab in the
    /// main window. The 3D tab (the first) stays. Fails when the dock has no window left.
    pub fn popOut(self: *Tabs, layout: *dock.DockSpace, index: usize, size: [2]f32) !void {
        if (index == 0 or self.list[index] == null or self.windowOf(layout, index) != null) return;
        const window = for (layout.windows, 0..) |slot, i| {
            if (slot == null) break i;
        } else return error.TooManyWindows;
        if (self.active == index) self.show(layout, self.nearestInMain(layout, index));
        layout.windows[window] = .{ .root = self.list[index].?.root, .size = size };
    }

    /// Close tab `index` (not the first): the panels in `keep` go to the first tab, the rest
    /// close. The tab shown moves to its neighbour when it was this one.
    pub fn close(self: *Tabs, layout: *dock.DockSpace, index: usize, keep: *const fn (panel: u32) bool) void {
        if (index == 0) return;
        const tab = self.list[index] orelse return;
        if (self.active == index) self.show(layout, self.nearestInMain(layout, index));
        // Every panel leaves; the tree's nodes come free as its stacks empty.
        var panels: [64 * 16]u32 = undefined;
        const n = collect(layout, tab.root, &panels, 0);
        const home = self.stackOf(layout, 0);
        for (panels[0..n]) |panel| {
            if (keep(panel)) if (home) |stack| {
                layout.move(panel, stack, .center) catch layout.remove(panel);
                continue;
            };
            layout.remove(panel);
        }
        if (self.windowOf(layout, index)) |window| layout.windows[window] = null;
        if (layout.nodes[tab.root].kind != .free and layout.root != tab.root) layout.nodes[tab.root] = .{};
        self.forget(index);
    }

    /// Drop the tabs whose tree is gone (its last panel left, so the dock freed its root), and
    /// show the first when the one shown went. Call after the dock changes.
    pub fn prune(self: *Tabs, layout: *dock.DockSpace) void {
        var i: usize = self.count();
        while (i > 1) {
            i -= 1;
            const tab = self.list[i].?;
            if (layout.nodes[tab.root].kind == .free or layout.nodes[tab.root].parent != 0xFF) self.forget(i);
        }
        if (self.list[self.active] == null or self.list[self.active].?.root != layout.root) {
            self.active = @intCast(self.ofRoot(layout.root) orelse 0);
            if (self.list[self.active].?.root != layout.root) self.show(layout, self.active);
        }
    }

    /// Take tab `index` out of the list, keeping the rest in order.
    fn forget(self: *Tabs, index: usize) void {
        const n = self.count();
        std.mem.copyForwards(?Tab, self.list[index .. n - 1], self.list[index + 1 .. n]);
        self.list[n - 1] = null;
        if (self.active > index) self.active -= 1;
        if (self.active >= n - 1) self.active = 0;
    }

    /// The tab nearest `index` that is in the main window (not popped out); the first at worst.
    fn nearestInMain(self: *const Tabs, layout: *const dock.DockSpace, index: usize) usize {
        var i = index;
        while (i > 0) {
            i -= 1;
            if (self.windowOf(layout, i) == null) return i;
        }
        return 0;
    }
};

/// The root of the tree node `index` is in.
fn topOf(layout: *const dock.DockSpace, index: u8) u8 {
    var at = index;
    while (layout.nodes[at].parent != 0xFF) at = layout.nodes[at].parent;
    return at;
}

/// The tab stack with the largest area under node `index`, as last laid out.
fn largest(layout: *const dock.DockSpace, index: u8) u8 {
    const node = layout.nodes[index];
    if (node.kind != .split) return index;
    const a = largest(layout, node.first);
    const b = largest(layout, node.second);
    const ra = layout.nodes[a].rect;
    const rb = layout.nodes[b].rect;
    return if (rb.w * rb.h > ra.w * ra.h) b else a;
}

/// Every panel under node `index`, appended to `out` from `start`; returns the new length.
fn collect(layout: *const dock.DockSpace, index: u8, out: []u32, start: usize) usize {
    const node = layout.nodes[index];
    return switch (node.kind) {
        .tabs => blk: {
            @memcpy(out[start..][0..node.count], node.panels[0..node.count]);
            break :blk start + node.count;
        },
        .split => collect(layout, node.second, out, collect(layout, node.first, out, start)),
        .free => start,
    };
}

fn keepAll(_: u32) bool {
    return true;
}

test "a new tab is shown, and switching tabs swaps the main window's tree" {
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    var tabs = Tabs.init(&layout);
    const first_root = layout.root;
    const ui_tab = try tabs.open(&layout, .ui);
    try std.testing.expectEqual(@as(usize, 1), ui_tab);
    try std.testing.expect(layout.root != first_root);
    try layout.add(2, null, .center);
    try std.testing.expectEqual(@as(?usize, 1), tabs.ofPanel(&layout, 2));
    tabs.show(&layout, 0);
    try std.testing.expectEqual(first_root, layout.root);
    try std.testing.expectEqual(@as(?usize, 0), tabs.ofPanel(&layout, 1));
}

test "a tab whose last panel leaves is dropped, and closing one sends its panels home" {
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    var tabs = Tabs.init(&layout);
    _ = try tabs.open(&layout, .panels);
    try layout.add(2, null, .center);
    try layout.add(3, 2, .right);
    tabs.show(&layout, 0);
    // Moving both panels back to the first tab empties the second, which goes.
    try layout.move(2, tabs.stackOf(&layout, 0).?, .center);
    try layout.move(3, tabs.stackOf(&layout, 0).?, .center);
    tabs.prune(&layout);
    try std.testing.expectEqual(@as(usize, 1), tabs.count());

    _ = try tabs.open(&layout, .panels);
    try layout.move(3, layout.root, .center);
    tabs.close(&layout, 1, keepAll);
    try std.testing.expectEqual(@as(usize, 1), tabs.count());
    try std.testing.expectEqual(@as(?usize, 0), tabs.ofPanel(&layout, 3));
    try std.testing.expectEqual(@as(u8, 0), tabs.active);
}

test "a popped-out tab is a dock window, and showing it brings it back" {
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    var tabs = Tabs.init(&layout);
    _ = try tabs.open(&layout, .ui);
    try layout.add(2, null, .center);
    try tabs.popOut(&layout, 1, .{ 800, 600 });
    try std.testing.expectEqual(@as(u8, 0), tabs.active);
    const window = tabs.windowOf(&layout, 1).?;
    try std.testing.expect(layout.hostOf(layout.nodeOf(2).?) == .window);
    tabs.show(&layout, 1);
    try std.testing.expect(layout.windows[window] == null);
    try std.testing.expect(layout.hostOf(layout.nodeOf(2).?) == .main);
}
