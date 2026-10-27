//! The workspace's tabs: whole dock layouts side by side in the main window, one shown at a
//! time, as an editor's 3D, 2D and UI workspaces are. Each tab is a tree of the one dock's nodes:
//! the tab shown is the dock's main root, the others wait as trees of their own, and a tab
//! popped out is the root of one of the dock's OS windows, so it is a dock inside a window.
//! There may be any number of each kind, pinned ones first, or none, leaving the main window empty.
const std = @import("std");
const eggy = @import("eggy");
const dock = eggy.ui.dock;

/// What a tab is for, which names it and sets what it opens with.
pub const Kind = enum(u8) {
    /// The world in 3D: the Scene panel and what works on it.
    scene_3d,
    /// The world seen flat, for 2D games: the 2D Scene panel and what works on it.
    scene_2d,
    /// The UI Designer's panels.
    ui,
    /// Panels dragged onto the tab bar: named after its first panel.
    panels,
    /// One file in an Asset Preview of its own: named after the file.
    asset,

    /// The name of a tab of this kind (`.panels` tabs are named after a panel instead).
    pub fn title(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .scene_3d => "3D",
            .scene_2d => "2D",
            .ui => "UI",
            .panels => "Panels",
            .asset => "Asset",
        };
    }
};

pub const max_tabs = 8;

/// One tab: the root node of its tree in the dock, what it is for, and whether it is pinned
/// (kept first, and not closed until unpinned).
pub const Tab = struct { root: u8, kind: Kind, pinned: bool = false };

/// The project path an Asset Preview copy shows, kept inline so `Tabs` copies and saves as a
/// value.
pub const PreviewPath = struct {
    pub const max_len = 512;
    /// The path, then a 0 so its name can title a window.
    bytes: [max_len + 1]u8 = undefined,
    len: u16 = 0,

    /// `path` kept, or null when it is longer than `max_len`.
    pub fn of(path: []const u8) ?PreviewPath {
        if (path.len > max_len) return null;
        var kept = PreviewPath{ .len = @intCast(path.len) };
        @memcpy(kept.bytes[0..path.len], path);
        kept.bytes[path.len] = 0;
        return kept;
    }

    pub fn slice(self: *const PreviewPath) []const u8 {
        return self.bytes[0..self.len];
    }

    /// The file's name, for its tab and window.
    pub fn name(self: *const PreviewPath) [:0]const u8 {
        const start = if (std.mem.lastIndexOfScalar(u8, self.slice(), '/')) |slash| slash + 1 else 0;
        return self.bytes[start..self.len :0];
    }
};

/// The tabs, in order, pinned ones first.
pub const Tabs = struct {
    list: [max_tabs]?Tab = @splat(null),
    /// The tab shown in the main window, whose tree is the dock's main root; null when none is,
    /// and the main window is an empty stack no tab owns.
    active: ?u8 = null,
    /// The file each Asset Preview copy shows, by copy (`panels.max_copies` of them, as many as
    /// tabs); copy 0, and a copy with none, shows the Assets selection.
    previews: [max_tabs]?PreviewPath = @splat(null),

    /// One 3D tab, holding the main root of `layout` as it is.
    pub fn init(layout: *const dock.DockSpace) Tabs {
        var self = Tabs{ .active = 0 };
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

    /// Whether tab `index` is the one shown in the main window.
    pub fn isShown(self: *const Tabs, index: usize) bool {
        return self.active != null and self.active.? == index;
    }

    /// The OS window tab `index` is popped out into, if it is.
    pub fn windowOf(self: *const Tabs, layout: *const dock.DockSpace, index: usize) ?usize {
        const tab = self.list[index] orelse return null;
        for (layout.windows, 0..) |window, i| if (window) |placed| if (placed.root == tab.root) return i;
        return null;
    }

    /// Every panel in tab `index`'s tree, in `out`.
    pub fn panelsOf(self: *const Tabs, layout: *const dock.DockSpace, index: usize, out: []u32) []u32 {
        const tab = self.list[index] orelse return out[0..0];
        return out[0..collect(layout, tab.root, out, 0)];
    }

    /// Show tab `index` in the main window. A tab popped out comes back in first.
    pub fn show(self: *Tabs, layout: *dock.DockSpace, index: usize) void {
        const tab = self.list[index] orelse return;
        if (self.windowOf(layout, index)) |window| layout.windows[window] = null;
        self.leaveMain(layout);
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
        // An empty main window's stack becomes the tab's; otherwise it takes a free node.
        const root = if (self.active == null and self.ofRoot(layout.root) == null and isEmptyStack(layout, layout.root))
            layout.root
        else
            try newStack(layout);
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
    /// main window, or none. Fails when the dock has no window, or no node, left.
    pub fn popOut(self: *Tabs, layout: *dock.DockSpace, index: usize, size: [2]f32) !void {
        if (self.list[index] == null or self.windowOf(layout, index) != null) return;
        const window = for (layout.windows, 0..) |slot, i| {
            if (slot == null) break i;
        } else return error.TooManyWindows;
        if (self.isShown(index)) {
            if (self.nearestInMain(layout, index)) |next| self.show(layout, next) else try self.showNothing(layout);
        }
        layout.windows[window] = .{ .root = self.list[index].?.root, .size = size };
    }

    /// Close tab `index` and every panel in it, unless it is pinned. Another tab takes the main
    /// window when it was shown there, or none is left shown.
    pub fn close(self: *Tabs, layout: *dock.DockSpace, index: usize) void {
        const tab = self.list[index] orelse return;
        if (tab.pinned) return;
        // A neighbour takes the main window first, so the tree closes out of sight.
        if (self.isShown(index)) if (self.nearestInMain(layout, index)) |next| self.show(layout, next);
        // Every panel leaves; the tree's nodes come free as its stacks empty.
        var panels: [64 * 16]u32 = undefined;
        for (self.panelsOf(layout, index, &panels)) |panel| layout.remove(panel);
        if (self.windowOf(layout, index)) |window| layout.windows[window] = null;
        // Still the main window's, its root stays as an empty stack no tab owns.
        if (layout.root == tab.root) self.active = null else if (layout.nodes[tab.root].kind != .free) layout.nodes[tab.root] = .{};
        self.forget(index);
    }

    /// Move tab `from` to place `to` in the list, kept among its own: pinned tabs come first.
    pub fn reorder(self: *Tabs, from: usize, to: usize) void {
        const n = self.count();
        if (from >= n) return;
        const tab = self.list[from].?;
        const shown = if (self.active) |active| self.list[active].?.root else null;
        // Take it out, then put it back where asked, within its group.
        std.mem.copyForwards(?Tab, self.list[from .. n - 1], self.list[from + 1 .. n]);
        const pinned = self.pinnedCount(n - 1);
        const at = if (tab.pinned) @min(to, pinned) else std.math.clamp(to, pinned, n - 1);
        std.mem.copyBackwards(?Tab, self.list[at + 1 .. n], self.list[at .. n - 1]);
        self.list[at] = tab;
        if (shown) |root| self.active = @intCast(self.ofRoot(root).?);
    }

    /// Pin or unpin tab `index`: either way it moves to where the pinned tabs end.
    pub fn setPinned(self: *Tabs, index: usize, pinned: bool) void {
        const tab = &(self.list[index] orelse return);
        tab.pinned = pinned;
        self.reorder(index, if (pinned) max_tabs else 0);
    }

    /// Drop the tabs whose tree is gone or emptied, give a tab to panels in a main window no tab
    /// owns, and keep `active` on the tab shown. Call after the dock changes.
    pub fn prune(self: *Tabs, layout: *dock.DockSpace) void {
        // The dock frees a tree's root when its last panel leaves, but keeps the main window's
        // as an empty stack.
        var i: usize = self.count();
        while (i > 0) {
            i -= 1;
            const root = layout.nodes[self.list[i].?.root];
            if (root.kind == .free or root.parent != 0xFF or (root.kind == .tabs and root.count == 0)) self.forget(i);
        }
        if (self.ofRoot(layout.root)) |owner| {
            self.active = @intCast(owner);
            return;
        }
        // Panels docked into an empty main window (from the Window menu) make a tab of their own.
        self.active = null;
        if (!isEmptyStack(layout, layout.root)) {
            const index = self.count();
            if (index == max_tabs) return; // ponytail: an eight-tab limit leaves them tabless, raise max_tabs if it bites
            self.list[index] = .{ .root = layout.root, .kind = .panels };
            self.active = @intCast(index);
            return;
        }
        // An empty main window shows the first tab that isn't out in a window, if there is one.
        for (0..self.count()) |index| if (self.windowOf(layout, index) == null) return self.show(layout, index);
    }

    /// Take tab `index` out of the list, keeping the rest in order.
    fn forget(self: *Tabs, index: usize) void {
        const n = self.count();
        std.mem.copyForwards(?Tab, self.list[index .. n - 1], self.list[index + 1 .. n]);
        self.list[n - 1] = null;
        if (self.active) |active| {
            if (active == index) self.active = null else if (active > index) self.active = active - 1;
        }
    }

    /// How many of the first `n` tabs are pinned.
    fn pinnedCount(self: *const Tabs, n: usize) usize {
        var pinned: usize = 0;
        for (self.list[0..n]) |tab| {
            if (tab.?.pinned) pinned += 1;
        }
        return pinned;
    }

    /// The tab nearest `index` (not itself) that is in the main window rather than popped out.
    fn nearestInMain(self: *const Tabs, layout: *const dock.DockSpace, index: usize) ?usize {
        var before = index;
        while (before > 0) {
            before -= 1;
            if (self.windowOf(layout, before) == null) return before;
        }
        for (index + 1..self.count()) |after| if (self.windowOf(layout, after) == null) return after;
        return null;
    }

    /// Leave the main window empty: an empty stack no tab owns, with no tab shown.
    fn showNothing(self: *Tabs, layout: *dock.DockSpace) !void {
        layout.root = try newStack(layout);
        layout.menu = 0xFF;
        self.active = null;
    }

    /// Before another tree takes the main window, an empty stack no tab owns goes free.
    fn leaveMain(self: *const Tabs, layout: *dock.DockSpace) void {
        if (self.ofRoot(layout.root) == null and isEmptyStack(layout, layout.root)) layout.nodes[layout.root] = .{};
    }
};

/// A free node of `layout` made an empty tab stack, for a tree's root.
fn newStack(layout: *dock.DockSpace) !u8 {
    for (&layout.nodes, 0..) |*node, i| if (node.kind == .free) {
        node.* = .{ .kind = .tabs };
        return @intCast(i);
    };
    return error.TooManyDockNodes;
}

fn isEmptyStack(layout: *const dock.DockSpace, index: u8) bool {
    return layout.nodes[index].kind == .tabs and layout.nodes[index].count == 0;
}

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

test "a tab whose last panel leaves is dropped, and closing one closes its panels" {
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
    tabs.close(&layout, 1);
    try std.testing.expectEqual(@as(usize, 1), tabs.count());
    try std.testing.expect(layout.nodeOf(3) == null);
    try std.testing.expectEqual(@as(?u8, 0), tabs.active);
}

test "closing every tab leaves the main window empty, and a new tab takes it" {
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    var tabs = Tabs.init(&layout);
    tabs.close(&layout, 0);
    tabs.prune(&layout);
    try std.testing.expectEqual(@as(usize, 0), tabs.count());
    try std.testing.expectEqual(@as(?u8, null), tabs.active);
    try std.testing.expect(layout.nodeOf(1) == null);

    const empty_root = layout.root;
    _ = try tabs.open(&layout, .scene_3d);
    try std.testing.expectEqual(empty_root, layout.root);
    try layout.add(2, null, .center);
    _ = try tabs.open(&layout, .scene_3d);
    try layout.add(3, null, .center);
    try std.testing.expectEqual(@as(usize, 2), tabs.count());
}

test "a panel docked into an empty main window makes a tab of its own" {
    var layout = dock.DockSpace.init();
    var tabs = Tabs.init(&layout);
    tabs.prune(&layout);
    try std.testing.expectEqual(@as(usize, 0), tabs.count());
    try layout.add(4, null, .center);
    tabs.prune(&layout);
    try std.testing.expectEqual(@as(usize, 1), tabs.count());
    try std.testing.expectEqual(Kind.panels, tabs.list[0].?.kind);
    try std.testing.expectEqual(@as(?u8, 0), tabs.active);
}

test "pinned tabs come first, aren't closed, and reordering keeps them first" {
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    var tabs = Tabs.init(&layout);
    for (2..5) |panel| {
        _ = try tabs.open(&layout, .panels);
        try layout.add(@intCast(panel), null, .center);
    }
    // Pinning the last moves it to the front; the tab shown stays shown.
    const shown = tabs.list[tabs.active.?].?.root;
    tabs.setPinned(3, true);
    try std.testing.expectEqual(@as(?usize, 0), tabs.ofPanel(&layout, 4));
    try std.testing.expectEqual(shown, tabs.list[tabs.active.?].?.root);
    // An unpinned tab can't go before it, and closing it does nothing.
    tabs.reorder(3, 0);
    try std.testing.expectEqual(@as(?usize, 1), tabs.ofPanel(&layout, 3));
    tabs.close(&layout, 0);
    try std.testing.expectEqual(@as(usize, 4), tabs.count());
    tabs.reorder(1, 3);
    try std.testing.expectEqual(@as(?usize, 3), tabs.ofPanel(&layout, 3));
}

test "a popped-out tab is a dock window, and showing it brings it back" {
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    var tabs = Tabs.init(&layout);
    _ = try tabs.open(&layout, .ui);
    try layout.add(2, null, .center);
    try tabs.popOut(&layout, 1, .{ 800, 600 });
    try std.testing.expectEqual(@as(?u8, 0), tabs.active);
    const window = tabs.windowOf(&layout, 1).?;
    try std.testing.expect(layout.hostOf(layout.nodeOf(2).?) == .window);
    tabs.show(&layout, 1);
    try std.testing.expect(layout.windows[window] == null);
    try std.testing.expect(layout.hostOf(layout.nodeOf(2).?) == .main);

    // The only tab popped out leaves the main window empty.
    tabs.close(&layout, 0);
    try tabs.popOut(&layout, 0, .{ 800, 600 });
    try std.testing.expectEqual(@as(?u8, null), tabs.active);
    try std.testing.expect(layout.root != tabs.list[0].?.root);
}
