//! A project's `eggy.zon`: its settings for Eggy, in the project's root beside `build.zig.zon`.
//! The editor reads it when it opens the project.
const std = @import("std");

pub const file_name = "eggy.zon";

pub const Config = struct {
    /// The package name, as `build.zig`'s `addGame` uses it: the project's executables are
    /// `<name>` and `<name>_editor`.
    name: []const u8,
    /// The project's name as people see it (window titles, the editor); any text.
    title: []const u8,
    version: []const u8 = "0.0.1",
};

/// `source` (an `eggy.zon`) parsed. Strings live in `arena`.
pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) !Config {
    return std.zon.parse.fromSliceAlloc(Config, arena, source, null, .{});
}

/// The `eggy.zon` in `dir`, parsed into `arena`.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Config {
    const source = try dir.readFileAllocOptions(io, file_name, arena, .limited(1 << 20), .of(u8), 0);
    return parse(arena, source);
}

test "eggy.zon gives the project's title and version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parse(arena.allocator(),
        \\.{ .name = "space_game", .title = "Space Game", .version = "1.2.0" }
    );
    try std.testing.expectEqualStrings("space_game", config.name);
    try std.testing.expectEqualStrings("Space Game", config.title);
    try std.testing.expectEqualStrings("1.2.0", config.version);
    try std.testing.expectError(error.ParseZon, parse(arena.allocator(), ".{ .title = \"No name\" }"));
}
