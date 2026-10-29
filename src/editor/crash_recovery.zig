//! Unsaved scene changes kept aside while the editor runs, so a crash doesn't lose them: a copy
//! of the world in `.eggy/recovery/scene.zon` whenever it differs from the saved scene, which
//! the next editor finds and offers to restore. The scene's own file is never touched.
const std = @import("std");

/// The live copy, relative to the project; its first line names the scene it belongs to.
const live_path = ".eggy/recovery/scene.zon";
const folder = ".eggy/recovery";
const header = "// eggy recovery: ";
/// The least time between copies while the world keeps changing, so dragging doesn't write
/// every few frames.
const min_interval_ms = 2000;

/// The copy this editor keeps up to date for its project.
pub const Recovery = struct {
    /// Hash of the world last copied; null when no copy is kept.
    kept_hash: ?u64 = null,
    kept_at_ms: u64 = 0,

    /// Copy `world_text` (the world as a scene, belonging to `scene_path`, or null when it has
    /// no file yet) unless it is what was copied last, or the last copy is under two seconds
    /// old. Failures are logged: recovery is a safety net, not part of editing.
    pub fn keep(self: *Recovery, io: std.Io, project: std.Io.Dir, world_text: []const u8, scene_path: ?[]const u8, now_ms: u64) void {
        const hash = std.hash.Wyhash.hash(0, world_text);
        if (self.kept_hash == hash) return;
        if (self.kept_hash != null and now_ms -| self.kept_at_ms < min_interval_ms) return;
        self.keepNow(io, project, world_text, scene_path);
        self.kept_at_ms = now_ms;
    }

    /// Copy `world_text` straight away, as `keep` does without waiting: for a fatal error.
    pub fn keepNow(self: *Recovery, io: std.Io, project: std.Io.Dir, world_text: []const u8, scene_path: ?[]const u8) void {
        writeCopy(io, project, world_text, scene_path) catch |err| return std.log.err("cannot keep a recovery copy of the scene: {t}", .{err});
        self.kept_hash = std.hash.Wyhash.hash(0, world_text);
    }

    /// Delete the copy: the scene was saved, or its changes were given up on purpose.
    pub fn forget(self: *Recovery, io: std.Io, project: std.Io.Dir) void {
        if (self.kept_hash == null) return;
        project.deleteFile(io, live_path) catch |err| if (err != error.FileNotFound) std.log.err("cannot remove the recovery copy: {t}", .{err});
        self.kept_hash = null;
    }
};

/// What a previous editor left behind when it closed without saving.
pub const Leftover = struct {
    /// Where the copy now is, relative to the project, out of the way of this editor's own.
    path: []u8,
    /// The scene it belongs to, or null for one never saved.
    scene: ?[]const u8,
    /// The world as a scene.
    text: [:0]u8,

    pub fn deinit(self: *Leftover, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.text);
    }

    /// Delete the copy, once restored or given up on.
    pub fn delete(self: *const Leftover, io: std.Io, project: std.Io.Dir) void {
        project.deleteFile(io, self.path) catch |err| if (err != error.FileNotFound) std.log.err("cannot remove {s}: {t}", .{ self.path, err });
    }
};

/// Take the copy a previous editor left, if any, moving it to `crashed-N.scene.zon` beside it
/// so this editor's own copies don't overwrite it before the person decides. Caller-owned.
pub fn takeLeftover(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir) !?Leftover {
    project.access(io, live_path, .{}) catch return null;
    var n: usize = 1;
    const moved = while (n < 1000) : (n += 1) {
        const name = try std.fmt.allocPrint(gpa, folder ++ "/crashed-{d}.scene.zon", .{n});
        project.access(io, name, .{}) catch break name;
        gpa.free(name);
    } else return error.NoFreeName;
    errdefer gpa.free(moved);
    try project.rename(live_path, project, moved, io);
    const text = try project.readFileAllocOptions(io, moved, gpa, .limited(256 << 20), .of(u8), 0);
    errdefer gpa.free(text);
    return .{ .path = moved, .scene = sceneOf(text), .text = text };
}

/// The scene a copy's first line names; null for none.
fn sceneOf(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, header)) return null;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const named = std.mem.trim(u8, text[header.len..end], " \r");
    return if (named.len == 0) null else named;
}

/// Write the copy whole beside the live one, then put it in its place, so a crash while
/// writing leaves the last copy as it was.
fn writeCopy(io: std.Io, project: std.Io.Dir, world_text: []const u8, scene_path: ?[]const u8) !void {
    try project.createDirPath(io, folder);
    var buffer: [4096]u8 = undefined;
    const temporary = folder ++ "/scene.zon.part";
    var file = try project.createFile(io, temporary, .{});
    defer file.close(io);
    var writer = file.writer(io, &buffer);
    try writer.interface.print("{s}{s}\n", .{ header, scene_path orelse "" });
    try writer.interface.writeAll(world_text);
    try writer.interface.flush();
    try project.rename(temporary, project, live_path, io);
}

test "a copy is kept, found by the next editor with its scene, and forgotten once saved" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const world = ".{ .entities = .{ .{ .name = \"Ship\" } } }";

    // Copied once; the same world again, or another within two seconds, isn't copied again.
    var recovery = Recovery{};
    recovery.keep(io, tmp.dir, world, "resources/scene/level.scene.zon", 10_000);
    const first = recovery.kept_hash.?;
    recovery.keep(io, tmp.dir, ".{}", null, 10_500);
    try std.testing.expectEqual(first, recovery.kept_hash.?);

    // The next editor takes it aside, with the scene it was for, and the world parses as before.
    var leftover = (try takeLeftover(gpa, io, tmp.dir)).?;
    defer leftover.deinit(gpa);
    try std.testing.expectEqualStrings("resources/scene/level.scene.zon", leftover.scene.?);
    try std.testing.expectEqualStrings(".eggy/recovery/crashed-1.scene.zon", leftover.path);
    try std.testing.expect(std.mem.endsWith(u8, leftover.text, world));
    try std.testing.expect(try takeLeftover(gpa, io, tmp.dir) == null);
    leftover.delete(io, tmp.dir);

    // Saving forgets the copy, so nothing is offered next time.
    recovery.keepNow(io, tmp.dir, world, null);
    recovery.forget(io, tmp.dir);
    try std.testing.expect(try takeLeftover(gpa, io, tmp.dir) == null);
}

test "a copy of a scene never saved names none" {
    try std.testing.expect(sceneOf(header ++ "\n.{}") == null);
    try std.testing.expect(sceneOf(".{}") == null);
}
