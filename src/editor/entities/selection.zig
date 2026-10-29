//! The entities selected together: the primary one, which the Inspector and the gizmo show, and
//! the others Ctrl-clicks and Shift-clicks in the Hierarchy and Scene add beside it.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;
const sdl3 = eggy.sdl_adapter.sdl;

/// What a click does to the selection.
pub const How = enum {
    /// Select just this (a plain click).
    only,
    /// Add it, or take it out if it was in (Ctrl).
    toggle,
    /// Select every row from the primary to it (Shift, in the Hierarchy).
    range,
};

/// What a click does with the modifier keys held now.
pub fn howNow() How {
    const held = sdl3.keyboard.getModState();
    if (held.controlDown() or held.guiDown()) return .toggle;
    if (held.shiftDown()) return .range;
    return .only;
}

pub const Selection = struct {
    /// Every entity selected, the primary included; empty with none.
    all: std.ArrayList(ecs.EntityId) = .empty,

    pub fn deinit(self: *Selection, gpa: std.mem.Allocator) void {
        self.all.deinit(gpa);
    }

    pub fn contains(self: *const Selection, entity: ecs.EntityId) bool {
        for (self.all.items) |selected| if (selected.eql(entity)) return true;
        return false;
    }

    /// Catch up with `primary` after something set it on its own: the others stay while it is
    /// one of them, and otherwise it is selected alone. Entities no longer in `world` drop out.
    pub fn follow(self: *Selection, gpa: std.mem.Allocator, primary: ?ecs.EntityId, world: *ecs.World) void {
        var kept: usize = 0;
        for (self.all.items) |entity| if (world.isAlive(entity)) {
            self.all.items[kept] = entity;
            kept += 1;
        };
        self.all.shrinkRetainingCapacity(kept);
        const chosen = primary orelse return self.all.clearRetainingCapacity();
        if (self.contains(chosen)) return;
        self.all.clearRetainingCapacity();
        self.all.append(gpa, chosen) catch {};
    }

    /// Click `entity` (null: empty space) as `how` says, with the rows in `order` for a range,
    /// setting `primary` to what the Inspector should show.
    pub fn choose(self: *Selection, gpa: std.mem.Allocator, primary: *?ecs.EntityId, entity: ?ecs.EntityId, how: How, order: []const ecs.EntityId) void {
        const clicked = entity orelse {
            // Empty space clears a plain click's selection; a modified click there keeps it.
            if (how == .only) {
                primary.* = null;
                self.all.clearRetainingCapacity();
            }
            return;
        };
        switch (how) {
            .only => {},
            .toggle => {
                if (self.indexOf(clicked)) |at| {
                    _ = self.all.orderedRemove(at);
                    if (primary.*) |was| if (was.eql(clicked)) {
                        primary.* = if (self.all.items.len > 0) self.all.items[self.all.items.len - 1] else null;
                    };
                    return;
                }
                self.all.append(gpa, clicked) catch return;
                primary.* = clicked;
                return;
            },
            .range => if (primary.*) |anchor| if (indexIn(order, anchor)) |from| if (indexIn(order, clicked)) |to| {
                self.all.clearRetainingCapacity();
                for (order[@min(from, to) .. @max(from, to) + 1]) |row| self.all.append(gpa, row) catch return;
                primary.* = clicked;
                return;
            },
        }
        primary.* = clicked;
        self.all.clearRetainingCapacity();
        self.all.append(gpa, clicked) catch {};
    }

    fn indexOf(self: *const Selection, entity: ecs.EntityId) ?usize {
        return indexIn(self.all.items, entity);
    }
};

fn indexIn(list: []const ecs.EntityId, entity: ecs.EntityId) ?usize {
    for (list, 0..) |item, at| if (item.eql(entity)) return at;
    return null;
}

test "Ctrl adds and takes out, Shift selects the rows between, and a plain click starts again" {
    const gpa = std.testing.allocator;
    var selection = Selection{};
    defer selection.deinit(gpa);
    const rows = [_]ecs.EntityId{ .init(0, 0), .init(1, 0), .init(2, 0), .init(3, 0) };
    var primary: ?ecs.EntityId = null;

    selection.choose(gpa, &primary, rows[1], .only, &rows);
    selection.choose(gpa, &primary, rows[3], .toggle, &rows);
    try std.testing.expectEqual(@as(usize, 2), selection.all.items.len);
    try std.testing.expect(primary.?.eql(rows[3]));
    // Taking the primary out hands it to the one left.
    selection.choose(gpa, &primary, rows[3], .toggle, &rows);
    try std.testing.expect(primary.?.eql(rows[1]));

    selection.choose(gpa, &primary, rows[3], .range, &rows);
    try std.testing.expectEqual(@as(usize, 3), selection.all.items.len);
    try std.testing.expect(selection.contains(rows[2]) and !selection.contains(rows[0]));

    selection.choose(gpa, &primary, rows[0], .only, &rows);
    try std.testing.expectEqual(@as(usize, 1), selection.all.items.len);
}

test "the selection follows a primary set elsewhere, and drops what died" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const a = try world.spawn(.{});
    const b = try world.spawn(.{});
    const c = try world.spawn(.{});
    var selection = Selection{};
    defer selection.deinit(gpa);
    var primary: ?ecs.EntityId = a;
    selection.choose(gpa, &primary, a, .only, &.{});
    selection.choose(gpa, &primary, b, .toggle, &.{});

    // Still one of them: both stay.
    selection.follow(gpa, a, &world);
    try std.testing.expectEqual(@as(usize, 2), selection.all.items.len);
    // Another: it alone.
    selection.follow(gpa, c, &world);
    try std.testing.expectEqual(@as(usize, 1), selection.all.items.len);
    world.despawn(c);
    selection.follow(gpa, null, &world);
    try std.testing.expectEqual(@as(usize, 0), selection.all.items.len);
}
