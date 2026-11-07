//! Which scene each 3D tab shows, by its Scene copy (`panels.Live.scene`): the editor has one
//! world, so the live copy's scene is the open one, and the others are kept as the world was when
//! their tab was left (unsaved edits and all) until it is shown again. A tab with no scene of its
//! own shows an empty world, never another tab's. Which file each tab shows
//! is kept in the project's `.eggy/scene_tabs.zon`, so the tabs show them again when it reopens.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const panels = @import("panels.zig");
const scene_file = @import("scene_file.zig");
const log = std.log.scoped(.tabs);

/// Where in the project the tabs' scenes are kept.
const tabs_path = ".eggy" ++ std.fs.path.sep_str ++ "scene_tabs.zon";

/// The file's shape: the copy whose scene is the open one, and each copy's scene file.
const Saved = struct {
    applied: u8 = 0,
    files: [panels.max_copies]?[]const u8 = @splat(null),
};

/// A scene put aside: the world's text as its tab left it, the hash it was saved with, and
/// whether that text has changes the file doesn't.
pub const Kept = struct {
    /// Its file; empty for a world never saved.
    path: []u8,
    text: []u8,
    saved_hash: ?u64,
    unsaved: bool,

    pub fn deinit(self: Kept, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.text);
    }
};

/// What a 3D tab shows when it is shown: its scene's file, the world it left, or, for a tab with
/// none of its own, an empty world.
pub const Waiting = union(enum) {
    file: []u8,
    kept: Kept,
    empty,

    pub fn deinit(self: Waiting, gpa: std.mem.Allocator) void {
        switch (self) {
            .file => |path| gpa.free(path),
            .kept => |kept| kept.deinit(gpa),
            .empty => {},
        }
    }
};

pub const SceneTabs = struct {
    /// The Scene copy whose scene is open now.
    applied: u8 = 0,
    /// Whether `applied` is known; until then the first copy followed takes the open scene.
    settled: bool = false,
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

    /// The live copy is `live` now: when it is another than the one applied, put the open world
    /// aside for its copy as `leaving` (owned; null for an empty one) and return what `live`
    /// shows instead, the caller's to free: its own scene, or `.empty`. Null when `live` is
    /// already applied, freeing `leaving`.
    pub fn follow(self: *SceneTabs, gpa: std.mem.Allocator, live: u8, leaving: ?Kept) ?Waiting {
        if (!self.settled) {
            self.settled = true;
            self.applied = live;
        }
        if (live == self.applied) {
            if (leaving) |kept| kept.deinit(gpa);
            return null;
        }
        const next = self.waiting[live] orelse .empty;
        self.waiting[live] = null;
        if (self.waiting[self.applied]) |old| old.deinit(gpa);
        self.waiting[self.applied] = if (leaving) |kept| .{ .kept = kept } else null;
        self.applied = live;
        return next;
    }

    /// Write which scene file each copy shows to `project`'s `.eggy/scene_tabs.zon`: the applied
    /// copy's is `open_path` (null: none open), the others' what waits for them. A kept world's
    /// unsaved changes aren't written, only its file. Errors are the file's.
    pub fn save(self: *const SceneTabs, gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, open_path: ?[]const u8) !void {
        var saved = Saved{ .applied = self.applied };
        for (&saved.files, self.waiting) |*file, entry| if (entry) |found| {
            file.* = switch (found) {
                .file => |path| path,
                .kept => |kept| if (kept.path.len == 0) null else kept.path,
                .empty => null,
            };
        };
        saved.files[self.applied] = open_path;

        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.writeAll("// The scene each 3D tab shows, opened again when the editor opens.\n");
        try std.zon.stringify.serialize(saved, .{}, &text.writer);
        try project.createDirPath(io, ".eggy");
        try project.writeFile(io, .{ .sub_path = tabs_path, .data = text.written() });
    }

    /// Read what `save` kept in `project`: the copy saved as applied is applied again (the editor
    /// reopens its scene itself), and every other copy's file waits for its tab. Call before the
    /// first `follow`. Without a readable file, the first copy `follow` sees takes the scene the
    /// editor reopens; an unreadable file is logged, and files that are gone or outside the
    /// project are left out.
    pub fn load(self: *SceneTabs, gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir) void {
        const source = project.readFileAllocOptions(io, tabs_path, gpa, .limited(64 * 1024), .of(u8), 0) catch return;
        defer gpa.free(source);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const saved = zon_file.parse(Saved, arena.allocator(), source, .{ .ignore_unknown_fields = true }) catch |err| return log.warn("cannot read the tabs' scenes: {t}", .{err});
        if (saved.applied >= panels.max_copies) return;
        self.deinit(gpa);
        self.applied = saved.applied;
        self.settled = true;
        for (saved.files, 0..) |file, copy| {
            const path = file orelse continue;
            if (copy == saved.applied or !scene_file.isProjectPath(path)) continue;
            project.access(io, path, .{}) catch continue;
            self.assign(gpa, @intCast(copy), path) catch return;
        }
    }

    /// Whether `live` is another copy than the applied one, so the open world must be put aside.
    pub fn changing(self: *const SceneTabs, live: u8) bool {
        return self.settled and live != self.applied;
    }

    /// The Scene copies among `closing` whose unsaved changes closing them throws away: a kept
    /// world's, and the open world's (`open_unsaved`) when its copy closes and another copy,
    /// `live_after`, is shown next. The editor asks before those go.
    pub fn lostByClosing(self: *const SceneTabs, closing: [panels.max_copies]bool, live_after: ?u8, open_unsaved: bool) [panels.max_copies]bool {
        var lost: [panels.max_copies]bool = @splat(false);
        for (closing, self.waiting, &lost) |goes, entry, *gone| {
            if (goes) if (entry) |found| if (found == .kept) {
                gone.* = found.kept.unsaved;
            };
        }
        // Whatever the next copy shows, its own scene or an empty world, replaces the open one.
        const replaced = if (live_after) |next| next != self.applied else false;
        if (closing[self.applied] and open_unsaved and replaced) lost[self.applied] = true;
        return lost;
    }

    /// Forget the scenes of copies `open` says are closed, as their tabs are. The editor has
    /// asked about any unsaved ones first (`lostByClosing`).
    pub fn forgetClosed(self: *SceneTabs, gpa: std.mem.Allocator, open: [panels.max_copies]bool) void {
        for (&self.waiting, open) |*entry, still| if (!still) if (entry.*) |found| {
            found.deinit(gpa);
            entry.* = null;
        };
    }
};

test "a tab's scene waits for it to be shown, and the scene it replaces waits on the tab left" {
    const gpa = std.testing.allocator;
    var tabs = SceneTabs{ .settled = true };
    defer tabs.deinit(gpa);
    try tabs.assign(gpa, 1, "resources/scene/garden.scene.zon");
    try std.testing.expect(tabs.changing(1));

    // Showing tab 1 opens the garden, keeping what tab 0 had open.
    const leaving = Kept{ .path = try gpa.dupe(u8, "resources/scene/main.scene.zon"), .text = try gpa.dupe(u8, ".{}"), .saved_hash = 7, .unsaved = false };
    const shown = tabs.follow(gpa, 1, leaving).?;
    defer shown.deinit(gpa);
    try std.testing.expectEqualStrings("resources/scene/garden.scene.zon", shown.file);
    try std.testing.expectEqual(@as(u8, 1), tabs.applied);

    // Going back brings tab 0's world back as it was.
    const back = tabs.follow(gpa, 0, null).?;
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("resources/scene/main.scene.zon", back.kept.path);
    try std.testing.expectEqual(@as(?u64, 7), back.kept.saved_hash);

    // A copy with nothing of its own shows an empty world, not tab 0's scene, which waits.
    try std.testing.expect(tabs.changing(2));
    const leaving_again = Kept{ .path = try gpa.dupe(u8, "resources/scene/main.scene.zon"), .text = try gpa.dupe(u8, ".{}"), .saved_hash = 7, .unsaved = false };
    try std.testing.expect(tabs.follow(gpa, 2, leaving_again).? == .empty);
    try std.testing.expectEqual(@as(u8, 2), tabs.applied);
    try std.testing.expectEqualStrings("resources/scene/main.scene.zon", tabs.waiting[0].?.kept.path);
}

test "closing loses a kept world's changes, and the open one's when another tab is shown" {
    const gpa = std.testing.allocator;
    var tabs = SceneTabs{ .settled = true };
    defer tabs.deinit(gpa);
    // Copy 1 waits with unsaved changes, copy 2 with a saved world, copy 3 for its file.
    tabs.waiting[1] = .{ .kept = .{ .path = try gpa.dupe(u8, "a.scene.zon"), .text = try gpa.dupe(u8, ".{}"), .saved_hash = 1, .unsaved = true } };
    tabs.waiting[2] = .{ .kept = .{ .path = try gpa.dupe(u8, "b.scene.zon"), .text = try gpa.dupe(u8, ".{}"), .saved_hash = 2, .unsaved = false } };
    try tabs.assign(gpa, 3, "c.scene.zon");
    const only = struct {
        fn of(copies: []const u8) [panels.max_copies]bool {
            var set: [panels.max_copies]bool = @splat(false);
            for (copies) |copy| set[copy] = true;
            return set;
        }
    }.of;

    try std.testing.expectEqual(only(&.{1}), tabs.lostByClosing(only(&.{ 1, 2 }), 0, true));
    // The open world (copy 0) is lost when copy 3's scene opens in its place...
    try std.testing.expectEqual(only(&.{0}), tabs.lostByClosing(only(&.{0}), 3, true));
    // ...or an empty world does, but not when no tab is left, or nothing changed.
    try std.testing.expectEqual(only(&.{0}), tabs.lostByClosing(only(&.{0}), 4, true));
    try std.testing.expectEqual(only(&.{}), tabs.lostByClosing(only(&.{0}), null, true));
    try std.testing.expectEqual(only(&.{}), tabs.lostByClosing(only(&.{0}), 3, false));
}

test "each tab's scene file comes back for its own tab, the open one's left to the editor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "resources/scene");
    for ([_][]const u8{ "resources/scene/garden.scene.zon", "resources/scene/basic.scene.zon" }) |path| try tmp.dir.writeFile(io, .{ .sub_path = path, .data = ".{}" });

    var before = SceneTabs{};
    defer before.deinit(gpa);
    try before.assign(gpa, 0, "resources/scene/garden.scene.zon");
    try before.assign(gpa, 3, "resources/scene/gone.scene.zon");
    before.applied = 2;
    try before.save(gpa, io, tmp.dir, "resources/scene/basic.scene.zon");

    var after = SceneTabs{};
    defer after.deinit(gpa);
    after.load(gpa, io, tmp.dir);
    try std.testing.expectEqual(@as(u8, 2), after.applied);
    try std.testing.expectEqualStrings("resources/scene/garden.scene.zon", after.waiting[0].?.file);
    try std.testing.expect(after.waiting[2] == null);
    try std.testing.expect(after.waiting[3] == null);
}

test "without saved tabs, the first tab shown keeps the scene the editor reopened" {
    const gpa = std.testing.allocator;
    var tabs = SceneTabs{};
    defer tabs.deinit(gpa);
    try std.testing.expect(!tabs.changing(2));
    try std.testing.expect(tabs.follow(gpa, 2, null) == null);
    try std.testing.expectEqual(@as(u8, 2), tabs.applied);
    try std.testing.expect(tabs.changing(0));
}
