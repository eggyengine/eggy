//! The editor's log: every `std.log` message, kept for the Console panel as well as printed.
//! Messages can come from any thread (the project job logs from its own), so the log is guarded
//! by a mutex locked through `std.Options.debug_io`, the process-wide `Io` std's own logging uses.
const std = @import("std");

pub const Entry = struct {
    level: std.log.Level,
    /// The formatted line (`level(scope): message`), as a range of `text`.
    start: usize,
    end: usize,
};

/// What `snapshot` shows.
pub const Filter = struct {
    /// Levels shown, indexed by `std.log.Level`.
    levels: [4]bool = .{ true, true, true, false },
    /// Only lines containing this (case-insensitive); empty shows every line.
    query: []const u8 = "",
};

/// Past this many bytes, the oldest half of the log is dropped.
const max_text = 4 << 20;

var mutex: std.Io.Mutex = .init;
var text: std.ArrayList(u8) = .empty;
var entries: std.ArrayList(Entry) = .empty;
/// Bumped by `clear` and trimming, so views know their old text is gone.
var generation: u64 = 0;
const gpa = std.heap.smp_allocator;

/// `std.Options.logFn` for the editor: logs as usual, and keeps the message for the Console.
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
    entries.append(gpa, .{ .level = level, .start = start, .end = text.items.len }) catch text.shrinkRetainingCapacity(start);
}

/// Drop every message.
pub fn clear() void {
    const io = std.Options.debug_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    text.clearRetainingCapacity();
    entries.clearRetainingCapacity();
    generation +%= 1;
}

/// The messages `filter` shows, joined, copied into `arena`; and how many there were in all.
pub fn snapshot(arena: std.mem.Allocator, filter: Filter) !struct { text: []const u8, shown: usize, total: usize } {
    const io = std.Options.debug_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var out: std.ArrayList(u8) = .empty;
    var shown: usize = 0;
    for (entries.items) |entry| {
        if (!filter.levels[@intFromEnum(entry.level)]) continue;
        const line = text.items[entry.start..entry.end];
        if (filter.query.len > 0 and std.ascii.indexOfIgnoreCase(line, filter.query) == null) continue;
        try out.appendSlice(arena, line);
        shown += 1;
    }
    return .{ .text = out.items, .shown = shown, .total = entries.items.len };
}

/// Drop the oldest half of the messages. The mutex must be held.
fn trimOldest() void {
    const keep_from = entries.items[entries.items.len / 2].start;
    const kept = entries.items[entries.items.len / 2 ..];
    std.mem.copyForwards(u8, text.items[0 .. text.items.len - keep_from], text.items[keep_from..]);
    text.shrinkRetainingCapacity(text.items.len - keep_from);
    for (kept) |*entry| {
        entry.start -= keep_from;
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all = try snapshot(arena.allocator(), .{});
    try std.testing.expectEqual(@as(usize, 3), all.total);
    try std.testing.expectEqualStrings("info(projects): opened Space Game\nwarning: slow frame\n", all.text);
    const warnings = try snapshot(arena.allocator(), .{ .levels = .{ false, true, false, false } });
    try std.testing.expectEqualStrings("warning: slow frame\n", warnings.text);
    const searched = try snapshot(arena.allocator(), .{ .query = "SPACE" });
    try std.testing.expectEqual(@as(usize, 1), searched.shown);
}
