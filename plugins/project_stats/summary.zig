//! Everyone's work records added up into the project's: its time, the days it fell on, its
//! streaks, and how often it was saved, played and built.
const std = @import("std");
const record_zig = @import("record.zig");
const Day = record_zig.Day;

pub const Summary = struct {
    worked_ms: u64 = 0,
    sessions: u64 = 0,
    longest_session_ms: u64 = 0,
    saves: u64 = 0,
    plays: u64 = 0,
    builds: u64 = 0,
    /// Every day anyone worked, oldest first, with everyone's time that day.
    days: []const Day = &.{},
    /// Days in a row up to today (or yesterday, before today's work starts), and the most ever.
    streak: u32 = 0,
    best_streak: u32 = 0,
    busiest: ?Day = null,
};

/// Add up `people`'s records as of `today`, allocating the days from `arena`.
pub fn summarize(arena: std.mem.Allocator, people: []const record_zig.Person, today: i32) !Summary {
    var result = Summary{};
    var days: std.ArrayList(Day) = .empty;
    for (people) |person| {
        const record = person.record;
        result.worked_ms += record.worked_ms;
        result.sessions += record.sessions;
        result.longest_session_ms = @max(result.longest_session_ms, record.longest_session_ms);
        result.saves += record.saves;
        result.plays += record.plays;
        result.builds += record.builds;
        try days.appendSlice(arena, record.days);
    }
    std.mem.sort(Day, days.items, {}, struct {
        fn earlier(_: void, a: Day, b: Day) bool {
            return a.day < b.day;
        }
    }.earlier);
    // One entry a day, with everyone's time that day.
    var merged: std.ArrayList(Day) = .empty;
    for (days.items) |day| {
        if (merged.items.len > 0 and merged.items[merged.items.len - 1].day == day.day) {
            merged.items[merged.items.len - 1].worked_ms += day.worked_ms;
        } else try merged.append(arena, day);
    }
    result.days = merged.items;

    var run: u32 = 0;
    for (merged.items, 0..) |day, i| {
        run = if (i > 0 and merged.items[i - 1].day == day.day - 1) run + 1 else 1;
        result.best_streak = @max(result.best_streak, run);
        if (result.busiest == null or day.worked_ms > result.busiest.?.worked_ms) result.busiest = day;
    }
    // The run that ends the list is still going if it reaches today or yesterday.
    if (merged.items.len > 0 and merged.items[merged.items.len - 1].day >= today - 1) result.streak = run;
    return result;
}

test "everyone's days merge, and streaks count days in a row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const people = [_]record_zig.Person{
        .{ .name = "sam", .is_me = true, .record = .{ .worked_ms = 30, .saves = 2, .days = &.{ .{ .day = 10, .worked_ms = 10 }, .{ .day = 11, .worked_ms = 10 }, .{ .day = 12, .worked_ms = 10 } } } },
        .{ .name = "alex", .is_me = false, .record = .{ .worked_ms = 50, .saves = 1, .days = &.{ .{ .day = 12, .worked_ms = 20 }, .{ .day = 19, .worked_ms = 15 }, .{ .day = 20, .worked_ms = 15 } } } },
    };
    const summary = try summarize(arena, &people, 21);
    try std.testing.expectEqual(80, summary.worked_ms);
    try std.testing.expectEqual(3, summary.saves);
    try std.testing.expectEqual(5, summary.days.len);
    try std.testing.expectEqual(Day{ .day = 12, .worked_ms = 30 }, summary.busiest.?);
    try std.testing.expectEqual(3, summary.best_streak);
    // Days 19 and 20 run up to yesterday.
    try std.testing.expectEqual(2, summary.streak);
    try std.testing.expectEqual(0, (try summarize(arena, &people, 23)).streak);
}
