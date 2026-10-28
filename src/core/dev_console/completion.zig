//! Completing the word at the console's caret: commands, then their words, or Buzz's names.
const std = @import("std");

/// What a word could be, from where it sits in the line.
pub const Sources = struct {
    /// Every command's name, Eggy's and the game's.
    commands: []const []const u8,
    /// Buzz's keywords and the names the session has declared.
    buzz: []const []const u8,
    /// The world's named entities, for `get` and `set`.
    entities: []const []const u8,
    /// Every component field as `Component.field`, for `get` and `set`.
    fields: []const []const u8,
    /// The `.buzz` files `run` could run.
    scripts: []const []const u8 = &.{},
};

/// The word being completed, `line[start..cursor]`, and what it could become, best first.
pub const Completion = struct {
    start: usize,
    candidates: []const []const u8,
};

/// The most candidates offered at once.
const max_candidates = 24;

/// What the word ending at `cursor` in `line` could become, in `arena`. A first word is a command
/// or Buzz; after `get`/`set` come an entity then a field, after `help` a command, after `run` a
/// script's path (one word, slashes and all); anything else is Buzz. An empty word has no candidates, except as a command's word.
///
/// ```zig
/// const found = try completion.complete(arena, "set Pla", 7, sources); // start 4, "Player"
/// ```
pub fn complete(arena: std.mem.Allocator, line: []const u8, cursor: usize, sources: Sources) !Completion {
    const before = line[0..@min(cursor, line.len)];
    var start = if (std.mem.lastIndexOfAny(u8, before, word_breaks)) |at| at + 1 else 0;

    // Which word of a command line this is, when the line starts with a command.
    const first_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const first = line[0..first_end];
    const word_index = std.mem.count(u8, std.mem.trim(u8, before[0..start], " \t"), " ") + @intFromBool(start != 0);
    const is_command = for (sources.commands) |name| {
        if (std.mem.eql(u8, name, first)) break true;
    } else false;

    // A script's path is the whole word after `run`, though `/` and `-` break other words.
    const path_start = std.mem.indexOfNonePos(u8, line, first_end, " \t") orelse line.len;
    const naming_script = is_command and std.mem.eql(u8, first, "run") and start != 0 and before.len >= path_start;
    if (naming_script) start = path_start;
    const word = before[start..];

    const pool: []const []const []const u8 = if (start == 0)
        &.{ sources.commands, sources.buzz }
    else if (is_command and (std.mem.eql(u8, first, "get") or std.mem.eql(u8, first, "set"))) switch (word_index) {
        1 => &.{sources.entities},
        2 => &.{sources.fields},
        else => &.{},
    } else if (naming_script)
        &.{sources.scripts}
    else if (is_command and std.mem.eql(u8, first, "help") and word_index == 1)
        &.{sources.commands}
    else if (is_command)
        &.{}
    else
        &.{sources.buzz};
    if (word.len == 0 and (start == 0 or !is_command)) return .{ .start = start, .candidates = &.{} };

    // Those that start with the word, once each, shortest first, then alphabetically.
    var candidates: std.ArrayList([]const u8) = .empty;
    for (pool) |group| for (group) |name| {
        if (name.len <= word.len or !std.mem.startsWith(u8, name, word)) continue;
        for (candidates.items) |kept| {
            if (std.mem.eql(u8, kept, name)) break;
        } else try candidates.append(arena, name);
    };
    std.mem.sort([]const u8, candidates.items, {}, shorterFirst);
    return .{ .start = start, .candidates = candidates.items[0..@min(candidates.items.len, max_candidates)] };
}

/// What ends a word: spaces, and the punctuation Buzz puts between names.
const word_breaks = " \t()[]{},;+-*/%=<>!&|^~\"'?:\\";

fn shorterFirst(_: void, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len < b.len;
    return std.mem.lessThan(u8, a, b);
}

const test_sources = Sources{
    .commands = &.{ "help", "get", "set", "run", "god" },
    .buzz = &.{ "print", "run", "fun", "final", "speed" },
    .entities = &.{ "Player", "Platform", "Sun" },
    .fields = &.{ "Transform.position", "Transform.scale", "Camera.fov" },
    .scripts = &.{ "mods/fly.buzz", "mods/fly-fast.buzz", "setup.buzz" },
};

test "a first word completes to commands and Buzz names" {
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

test "words inside Buzz code complete to Buzz names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try complete(arena.allocator(), "var x = sp", 10, test_sources);
    try std.testing.expectEqual(@as(usize, 8), found.start);
    try std.testing.expectEqualStrings("speed", found.candidates[0]);
    try std.testing.expectEqual(@as(usize, 0), (try complete(arena.allocator(), "print(", 6, test_sources)).candidates.len);
}

test "run completes a script's whole path, slashes and dashes included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try complete(arena.allocator(), "run mods/fl", 11, test_sources);
    try std.testing.expectEqual(@as(usize, 4), found.start);
    try std.testing.expectEqual(@as(usize, 2), found.candidates.len);
    try std.testing.expectEqualStrings("mods/fly.buzz", found.candidates[0]);
    try std.testing.expectEqualStrings("mods/fly-fast.buzz", found.candidates[1]);
    try std.testing.expectEqual(@as(usize, 3), (try complete(arena.allocator(), "run ", 4, test_sources)).candidates.len);
}
