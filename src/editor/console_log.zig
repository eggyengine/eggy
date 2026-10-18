//! The editor's log: every `std.log` message, kept for the Console panel as well as printed.
//! Messages can come from any thread (the project job logs from its own), so the log is guarded
//! by a mutex locked through `std.Options.debug_io`, the process-wide `Io` std's own logging uses.
const std = @import("std");

pub const Entry = struct {
    /// Stable across snapshots, trimming and Clear, so views can hide/select a message.
    id: u64,
    level: std.log.Level,
    /// The formatted line (`level(scope): message`), as a range of `text`.
    start: usize,
    /// End of the first line; everything after it is expandable detail.
    summary_end: usize,
    end: usize,
};

/// A caller-owned snapshot, including message boundaries in its copied text.
pub const Messages = struct {
    text: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    /// Free copied text and entry ranges with the allocator passed to `snapshot`.
    /// Does not affect the shared editor log; the snapshot is invalid afterward.
    ///
    /// ```zig
    /// var messages: Messages = .{};
    /// defer messages.deinit(gpa);
    /// _ = try snapshot(gpa, &messages, .{});
    /// ```
    pub fn deinit(self: *Messages, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

/// What `snapshot` shows.
pub const Filter = struct {
    /// Levels shown, indexed by `std.log.Level`.
    levels: [4]bool = .{ true, true, true, false },
    /// Match the whole message, including collapsed details (case-insensitive).
    query: []const u8 = "",
    hidden: ?*const std.AutoHashMapUnmanaged(u64, void) = null,
};

/// Past this many bytes, the oldest half of the log is dropped.
const max_text = 4 << 20;

var mutex: std.Io.Mutex = .init;
var text: std.ArrayList(u8) = .empty;
var entries: std.ArrayList(Entry) = .empty;
/// Bumped by `clear` and trimming, so views know their old text is gone.
var generation: u64 = 0;
/// Bumped by every change, so the Console filters the log again only when it changed.
var version: u64 = 0;
var next_id: u64 = 0;
const gpa = std.heap.smp_allocator;

/// `std.Options.logFn` for the editor: logs as usual, and keeps the message for the Console.
/// Thread-safe; formatting arguments follow `std.log`. Allocation failures drop the message.
/// Tests suppress stderr forwarding; normal editor execution also uses the default logger.
///
/// ```zig
/// // Test/internal host use; production normally installs this in std_options.logFn.
/// logFn(.info, .projects, "opened {s}", .{"Space"});
/// ```
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    // Tests keep their messages here only: the test runner fails a test that logs a warning.
    if (!@import("builtin").is_test) std.log.defaultLog(level, scope, format, args);
    const prefix = comptime level.asText() ++ (if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ");
    const io = std.Options.debug_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (text.items.len > max_text) trimOldest();
    const start = text.items.len;
    text.print(gpa, prefix ++ format ++ "\n", args) catch return;
    const summary_end = std.mem.indexOfScalarPos(u8, text.items, start, '\n').?;
    entries.append(gpa, .{ .id = next_id, .level = level, .start = start, .summary_end = summary_end, .end = text.items.len }) catch text.shrinkRetainingCapacity(start);
    next_id +%= 1;
    _ = @atomicRmw(u64, &version, .Add, 1, .release);
}

/// A number that changes whenever the log does.
/// Atomically reads a wrapping version, not a message count; compare for inequality.
///
/// ```zig
/// const previous = changes();
/// logFn(.info, .default, "ready", .{});
/// const refresh_needed = changes() != previous;
/// _ = refresh_needed;
/// ```
pub fn changes() u64 {
    return @atomicLoad(u64, &version, .acquire);
}

/// Drop every message.
/// Thread-safe; retains storage, preserves monotonically assigned message identities,
/// and changes the version so Console views refresh. Existing snapshots remain owned copies.
///
/// ```zig
/// clear(); // Editor Console's Clear command.
/// ```
pub fn clear() void {
    const io = std.Options.debug_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    text.clearRetainingCapacity();
    entries.clearRetainingCapacity();
    generation +%= 1;
    _ = @atomicRmw(u64, &version, .Add, 1, .release);
}

pub const Snapshot = struct { shown: usize, total: usize };

/// The messages `filter` shows, joined, into `out` (replacing what it held, allocating with
/// `allocator`); and how many there were in all.
/// Locks the shared log while copying; reuse the same allocator for `out` and its cleanup.
/// `filter` is borrowed during the call. Allocation failures propagate and may leave a
/// partial output; entry offsets refer to `out.text`, not the global log.
///
/// ```zig
/// var messages: Messages = .{};
/// defer messages.deinit(gpa);
/// const counts = try snapshot(gpa, &messages, .{ .query = "error" });
/// std.log.info("{d} of {d}", .{ counts.shown, counts.total });
/// ```
pub fn snapshot(allocator: std.mem.Allocator, out: *Messages, filter: Filter) !Snapshot {
    const io = std.Options.debug_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    out.text.clearRetainingCapacity();
    out.entries.clearRetainingCapacity();
    var shown: usize = 0;
    for (entries.items) |entry| {
        if (!filter.levels[@intFromEnum(entry.level)]) continue;
        if (filter.hidden) |hidden| if (hidden.contains(entry.id)) continue;
        const line = text.items[entry.start..entry.end];
        if (filter.query.len > 0 and std.ascii.indexOfIgnoreCase(line, filter.query) == null) continue;
        const start = out.text.items.len;
        try out.text.appendSlice(allocator, line);
        try out.entries.append(allocator, .{
            .id = entry.id,
            .level = entry.level,
            .start = start,
            .summary_end = start + entry.summary_end - entry.start,
            .end = out.text.items.len,
        });
        shown += 1;
    }
    return .{ .shown = shown, .total = entries.items.len };
}

/// Drop the oldest half of the messages. The mutex must be held.
fn trimOldest() void {
    const keep_from = entries.items[entries.items.len / 2].start;
    const kept = entries.items[entries.items.len / 2 ..];
    std.mem.copyForwards(u8, text.items[0 .. text.items.len - keep_from], text.items[keep_from..]);
    text.shrinkRetainingCapacity(text.items.len - keep_from);
    for (kept) |*entry| {
        entry.start -= keep_from;
        entry.summary_end -= keep_from;
        entry.end -= keep_from;
    }
    std.mem.copyForwards(Entry, entries.items[0..kept.len], kept);
    entries.shrinkRetainingCapacity(kept.len);
    generation +%= 1;
}

test "the log keeps messages and filters them by level and text" {
    defer clear();
    logFn(.info, .projects, "opened {s}", .{"Space Game"});
    logFn(.warn, .default, "slow frame", .{});
    logFn(.debug, .default, "noise", .{});
    var out: Messages = .{};
    defer out.deinit(std.testing.allocator);
    const all = try snapshot(std.testing.allocator, &out, .{});
    try std.testing.expectEqual(@as(usize, 3), all.total);
    try std.testing.expectEqualStrings("info(projects): opened Space Game\nwarning: slow frame\n", out.text.items);
    _ = try snapshot(std.testing.allocator, &out, .{ .levels = .{ false, true, false, false } });
    try std.testing.expectEqualStrings("warning: slow frame\n", out.text.items);
    const searched = try snapshot(std.testing.allocator, &out, .{ .query = "SPACE" });
    try std.testing.expectEqual(@as(usize, 1), searched.shown);
    // Each message changes the log.
    const before = changes();
    logFn(.info, .default, "one more", .{});
    try std.testing.expect(changes() != before);
}

test "multiline diagnostics filter and hide as one error, even with info hidden" {
    defer clear();
    logFn(.err, .zig_build, "src/main.zig:12:5: error: wrong argument\n    broken();\n    ~~~~~~^~\nreferenced by:\n    game: src/root.zig:8:2", .{});
    logFn(.info, .default, "another message", .{});
    var out: Messages = .{};
    defer out.deinit(std.testing.allocator);
    const filtered = try snapshot(std.testing.allocator, &out, .{ .levels = .{ true, false, false, false }, .query = "REFERENCED" });
    try std.testing.expectEqual(@as(usize, 1), filtered.shown);
    try std.testing.expectEqual(@as(usize, 2), filtered.total);
    const entry = out.entries.items[0];
    try std.testing.expectEqualStrings("error(zig_build): src/main.zig:12:5: error: wrong argument", out.text.items[entry.start..entry.summary_end]);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items[entry.summary_end..entry.end], "broken();") != null);

    var hidden: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer hidden.deinit(std.testing.allocator);
    try hidden.put(std.testing.allocator, entry.id, {});
    const hiding = try snapshot(std.testing.allocator, &out, .{ .hidden = &hidden });
    try std.testing.expectEqual(@as(usize, 1), hiding.shown);
    try std.testing.expectEqualStrings("info: another message\n", out.text.items);
    hidden.clearRetainingCapacity();
    const restored = try snapshot(std.testing.allocator, &out, .{});
    try std.testing.expectEqual(@as(usize, 2), restored.shown);
    try std.testing.expectEqual(entry.id, out.entries.items[0].id);

    clear();
    logFn(.err, .default, "new message after Clear", .{});
    _ = try snapshot(std.testing.allocator, &out, .{});
    try std.testing.expect(out.entries.items[0].id != entry.id);
}

test "trimming keeps message identities and summary boundaries" {
    defer clear();
    logFn(.info, .default, "old", .{});
    logFn(.err, .zig_build, "kept\n    detail", .{});
    var out: Messages = .{};
    defer out.deinit(std.testing.allocator);
    _ = try snapshot(std.testing.allocator, &out, .{});
    const kept_id = out.entries.items[1].id;
    mutex.lockUncancelable(std.Options.debug_io);
    trimOldest();
    mutex.unlock(std.Options.debug_io);
    _ = try snapshot(std.testing.allocator, &out, .{});
    try std.testing.expectEqual(@as(usize, 1), out.entries.items.len);
    const entry = out.entries.items[0];
    try std.testing.expectEqual(kept_id, entry.id);
    try std.testing.expectEqualStrings("error(zig_build): kept", out.text.items[entry.start..entry.summary_end]);
}
