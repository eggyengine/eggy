//! Dragging a workspace tab from the tab bar: along the bar it moves to where it is let go,
//! resting on another tab shows that tab, let go over another tab's layout its panels dock
//! there (the dock's own targets say where), and pulled down over its own layout it pops out.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const dock = ui.dock;
const log = std.log.scoped(.tabs);

/// How long something carried rests on another tab before that tab is shown.
pub const spring_ms = 450;

/// How far the pointer moves from the press before a press on a tab becomes a drag.
const drag_after_px = 6;

/// A tab on the bar the pointer rests on while carrying a tab or a panel, to show it after
/// `spring_ms`, as a file manager opens a folder something is held over.
pub const SpringLoad = struct {
    tab: ?u8 = null,
    since_ms: u64 = 0,

    /// The pointer is over tab `over` (null: no tab) at `now_ms`. Returns the tab to show, once,
    /// when it has rested there `spring_ms`.
    pub fn hover(self: *SpringLoad, over: ?u8, now_ms: u64) ?u8 {
        if (over != self.tab) {
            self.* = .{ .tab = over, .since_ms = now_ms };
            return null;
        }
        const tab = over orelse return null;
        if (now_ms -| self.since_ms < spring_ms) return null;
        self.since_ms = std.math.maxInt(u64);
        return tab;
    }
};

/// A tab pressed on the bar while the pointer is still down.
pub const TabDrag = struct {
    /// The carried tab's root node: unlike its place in the list, it holds while other tabs close.
    root: u8,
    /// Where the press was, in the main window.
    from: ui.Vec2,
    /// Whether the pointer has moved far enough to make the press a drag.
    started: bool = false,

    /// The pointer moved to `at`. Returns whether the press is a drag by now.
    pub fn moveTo(self: *TabDrag, at: ui.Vec2) bool {
        if (!self.started and std.math.hypot(at.x - self.from.x, at.y - self.from.y) >= drag_after_px) self.started = true;
        return self.started;
    }
};

/// After the dock let go of a carried tab's first panel `first`, its other panels `rest` join it
/// in the stack it landed in, wherever that is. A stack already full leaves them where they were.
pub fn follow(layout: *dock.DockSpace, first: u32, rest: []const u32) void {
    for (rest) |panel| {
        const stack = layout.nodeOf(first) orelse return;
        layout.move(panel, stack, .center) catch |err| log.warn("cannot move panel {d} with its tab: {t}", .{ panel, err });
    }
}
