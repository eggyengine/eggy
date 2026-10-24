//! Which scene each 3D tab shows, by its Scene copy (`panels.Live.scene`): the editor has one
//! world, so the live copy's scene is the open one, and the others are kept as the world was when
//! their tab was left (unsaved edits and all) until it is shown again.
const std = @import("std");
const panels = @import("panels.zig");

/// A scene put aside: the world's text as its tab left it, and the hash it was saved with.
pub const Kept = struct {
    path: []u8,
    text: []u8,
    saved_hash: ?u64,

    pub fn deinit(self: Kept, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.text);
    }
};

/// What a 3D tab shows when it is shown: its scene's file, or the world it left.
pub const Waiting = union(enum) {
    file: []u8,
    kept: Kept,

    pub fn deinit(self: Waiting, gpa: std.mem.Allocator) void {
        switch (self) {
            .file => |path| gpa.free(path),
            .kept => |kept| kept.deinit(gpa),
        }
    }
};

pub const SceneTabs = struct {
    /// The Scene copy whose scene is open now.
    applied: u8 = 0,
    /// Each other copy's scene, waiting for its tab to be shown.
    waiting: [panels.max_copies]?Waiting = @splat(null),

    pub fn deinit(self: *SceneTabs, gpa: std.mem.Allocator) void {
        for (self.waiting) |entry| if (entry) |found| found.deinit(gpa);
        self.* = .{};
    }

    /// Give Scene copy `copy` (a new tab's) the scene file at `path` to open when it is shown.
    pub fn assign(self: *SceneTabs, gpa: std.mem.Allocator, copy: u8, path: []const u8) !void {
        const owned = try gpa.dupe(u8, path);
        if (self.waiting[copy]) |old| old.deinit(gpa);
        self.waiting[copy] = .{ .file = owned };
    }

    /// The live copy is `live` now: when it is another than the one applied and has a scene of
    /// its own waiting, put the open one aside as `leaving` (owned, or null with none open) and
    /// return what to show instead, the caller's to free. Null leaves the open scene to the new
    /// copy too, and frees `leaving`.
    pub fn follow(self: *SceneTabs, gpa: std.mem.Allocator, live: u8, leaving: ?Kept) ?Waiting {
        if (live == self.applied) {
            if (leaving) |kept| kept.deinit(gpa);
            return null;
        }
        const next = self.waiting[live] orelse {
            if (leaving) |kept| kept.deinit(gpa);
            self.applied = live;
            return null;
        };
        self.waiting[live] = null;
        if (self.waiting[self.applied]) |old| old.deinit(gpa);
        self.waiting[self.applied] = if (leaving) |kept| .{ .kept = kept } else null;
        self.applied = live;
        return next;
    }

    /// Whether a scene is waiting on copy `copy`'s tab, so the open one must be put aside.
    pub fn changing(self: *const SceneTabs, live: u8) bool {
        return live != self.applied and self.waiting[live] != null;
    }

    /// Forget the scenes of copies `open` says are closed, as their tabs are.
    // ponytail: a closed tab's unsaved world is dropped without asking; ask with the save prompt if that loses work.
    pub fn forgetClosed(self: *SceneTabs, gpa: std.mem.Allocator, open: [panels.max_copies]bool) void {
        for (&self.waiting, open) |*entry, still| if (!still) if (entry.*) |found| {
            found.deinit(gpa);
            entry.* = null;
        };
    }
};

test "a tab's scene waits for it to be shown, and the scene it replaces waits on the tab left" {
    const gpa = std.testing.allocator;
    var tabs = SceneTabs{};
    defer tabs.deinit(gpa);
    try tabs.assign(gpa, 1, "resources/scene/garden.scene.zon");
    try std.testing.expect(tabs.changing(1));

    // Showing tab 1 opens the garden, keeping what tab 0 had open.
    const leaving = Kept{ .path = try gpa.dupe(u8, "resources/scene/main.scene.zon"), .text = try gpa.dupe(u8, ".{}"), .saved_hash = 7 };
    const shown = tabs.follow(gpa, 1, leaving).?;
    defer shown.deinit(gpa);
    try std.testing.expectEqualStrings("resources/scene/garden.scene.zon", shown.file);
    try std.testing.expectEqual(@as(u8, 1), tabs.applied);

    // Going back brings tab 0's world back as it was.
    const back = tabs.follow(gpa, 0, null).?;
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("resources/scene/main.scene.zon", back.kept.path);
    try std.testing.expectEqual(@as(?u64, 7), back.kept.saved_hash);

    // A copy with nothing waiting shares the open scene.
    try std.testing.expect(!tabs.changing(2));
    try std.testing.expect(tabs.follow(gpa, 2, null) == null);
    try std.testing.expectEqual(@as(u8, 2), tabs.applied);
}
