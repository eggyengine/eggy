//! Completing the word at the console's caret: a command, then its words.
const std = @import("std");

/// What a word could be, from where it sits in the line.
pub const Sources = struct {
    /// Every command's name, Eggy's and the game's.
    commands: []const []const u8,
    /// The world's named entities, for `get` and `set`.
    entities: []const []const u8,
    /// Every component field as `Component.field`, for `get` and `set`.
    fields: []const []const u8,
};

/// The word being completed, `line[start..cursor]`, and what it could become, best first.
pub const Completion = struct {
    start: usize,
    candidates: []const []const u8,
};

/// The most candidates offered at once.
const max_candidates = 24;

/// What the word ending at `cursor` in `line` could become, in `arena`. A first word is a
/// command; after `get`/`set` come an entity then a field, after `help` a command. An empty first
/// word has no candidates.
///
/// ```zig
/// const found = try completion.complete(arena, "set Pla", 7, sources); // start 4, "Player"
/// ```
pub fn complete(arena: std.mem.Allocator, line: []const u8, cursor: usize, sources: Sources) !Completion {
    const before = line[0..@min(cursor, line.len)];
    const start = if (std.mem.lastIndexOfAny(u8, before, " \t")) |at| at + 1 else 0;
    const word = before[start..];

    // Which word of the line this is, and the command it starts with.
    const first = line[0 .. std.mem.indexOfAny(u8, line, " \t") orelse line.len];
    const word_index = std.mem.count(u8, std.mem.trim(u8, before[0..start], " \t"), " ") + @intFromBool(start != 0);

    const pool: []const []const u8 = if (start == 0)
        sources.commands
    else if (std.mem.eql(u8, first, "get") or std.mem.eql(u8, first, "set")) switch (word_index) {
        1 => sources.entities,
        2 => sources.fields,
        else => &.{},
    } else if (std.mem.eql(u8, first, "help") and word_index == 1)
        sources.commands
    else
        &.{};
    if (word.len == 0 and start == 0) return .{ .start = start, .candidates = &.{} };

    // Those that start with the word, once each, shortest first, then alphabetically.
    var candidates: std.ArrayList([]const u8) = .empty;
    for (pool) |name| {
        if (name.len <= word.len or !std.mem.startsWith(u8, name, word)) continue;
        for (candidates.items) |kept| {
            if (std.mem.eql(u8, kept, name)) break;
        } else try candidates.append(arena, name);
    }
    std.mem.sort([]const u8, candidates.items, {}, shorterFirst);
    return .{ .start = start, .candidates = candidates.items[0..@min(candidates.items.len, max_candidates)] };
}

fn shorterFirst(_: void, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len < b.len;
    return std.mem.lessThan(u8, a, b);
}

const test_sources = Sources{
    .commands = &.{ "help", "get", "set", "god" },
    .entities = &.{ "Player", "Platform", "Sun" },
    .fields = &.{ "Transform.position", "Transform.scale", "Camera.fov" },
};

test "a first word completes to commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try complete(arena.allocator(), "g", 1, test_sources);
    try std.testing.expectEqual(@as(usize, 0), found.start);
    try std.testing.expectEqual(@as(usize, 2), found.candidates.len);
    try std.testing.expectEqualStrings("get", found.candidates[0]);
    try std.testing.expectEqualStrings("god", found.candidates[1]);
}

test "get and set complete an entity, then a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entity = try complete(arena.allocator(), "set Pl", 6, test_sources);
    try std.testing.expectEqual(@as(usize, 4), entity.start);
    try std.testing.expectEqualStrings("Player", entity.candidates[0]);
    try std.testing.expectEqualStrings("Platform", entity.candidates[1]);
    const field = try complete(arena.allocator(), "get Player Transform.s", 22, test_sources);
    try std.testing.expectEqual(@as(usize, 1), field.candidates.len);
    try std.testing.expectEqualStrings("Transform.scale", field.candidates[0]);
    // A command's next word is offered before anything is typed.
    try std.testing.expectEqual(@as(usize, 3), (try complete(arena.allocator(), "get ", 4, test_sources)).candidates.len);
}

test "help completes a command, and other commands' words complete to nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try complete(arena.allocator(), "help se", 7, test_sources);
    try std.testing.expectEqual(@as(usize, 5), found.start);
    try std.testing.expectEqualStrings("set", found.candidates[0]);
    try std.testing.expectEqual(@as(usize, 0), (try complete(arena.allocator(), "god m", 5, test_sources)).candidates.len);
}
