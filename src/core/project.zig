//! A project as Eggy sees it: its `eggy.zon` (its settings for Eggy, in the project's root beside
//! `build.zig.zon`), which the editor reads when it opens the project and File > Project Settings
//! writes, and the folders every project has, which the editor makes if they are missing.
const std = @import("std");

pub const file_name = "eggy.zon";

/// Where a project keeps the files its game uses, relative to the project.
pub const resources_dir = "resources";
/// Where new scenes go, inside `resources_dir`.
pub const scenes_dir = resources_dir ++ "/scene";

/// Make the folders every project has (`resources_dir`, `scenes_dir`) in `dir`, if missing.
pub fn makeFolders(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, scenes_dir);
}

pub const Config = struct {
    /// The package name, as `build.zig`'s `addGame` uses it: the project's executables are
    /// `<name>` and `<name>_editor`.
    name: []const u8,
    /// The project's name as people see it (window titles, the editor); any text.
    title: []const u8,
    version: []const u8 = "0.0.1",
    /// The scene the game starts in, relative to the project: what exports start in unless
    /// told otherwise, and `zig build runtime` too (which, without it, takes the scene the
    /// editor has open, else the first in `resources_dir`: see `src/build/resources.zig`).
    default_scene: ?[]const u8 = null,
    /// What the built game says about itself, in its executable.
    metadata: Metadata = .{},
};

/// What a game's executable says about itself: on Windows, its version information (in the
/// file's Properties), with the title as its product name and the version as its version;
/// elsewhere, a section of its own (see `src/build/metadata.zig`). Empty ones are left out.
pub const Metadata = struct {
    company: []const u8 = "",
    description: []const u8 = "",
    copyright: []const u8 = "",
    /// Any more of your own, by name.
    extra: []const Entry = &.{},

    pub const Entry = struct { name: []const u8, value: []const u8 };
};

/// `config` as an `eggy.zon`, with its comments.
pub fn write(writer: *std.Io.Writer, config: Config) std.Io.Writer.Error!void {
    try writer.writeAll(".{\n    // The package name, as build.zig's addGame uses it: the editor opens `<name>_editor`.\n");
    try writer.print("    .name = \"{f}\",\n    .title = \"{f}\",\n    .version = \"{f}\",\n", .{ std.zig.fmtString(config.name), std.zig.fmtString(config.title), std.zig.fmtString(config.version) });
    if (config.default_scene) |scene| try writer.print("    // The scene the built game starts in.\n    .default_scene = \"{f}\",\n", .{std.zig.fmtString(scene)});
    const metadata = config.metadata;
    if (metadata.company.len + metadata.description.len + metadata.copyright.len + metadata.extra.len > 0) {
        try writer.writeAll("    // What the built game's executable says about itself.\n    .metadata = .{\n");
        inline for (.{ "company", "description", "copyright" }) |field| {
            const value = @field(metadata, field);
            if (value.len > 0) try writer.print("        ." ++ field ++ " = \"{f}\",\n", .{std.zig.fmtString(value)});
        }
        if (metadata.extra.len > 0) {
            try writer.writeAll("        .extra = .{\n");
            for (metadata.extra) |entry| try writer.print("            .{{ .name = \"{f}\", .value = \"{f}\" }},\n", .{ std.zig.fmtString(entry.name), std.zig.fmtString(entry.value) });
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
    }
    try writer.writeAll("}\n");
}

/// `source` (an `eggy.zon`) parsed. Strings live in `arena`.
pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) !Config {
    return std.zon.parse.fromSliceAlloc(Config, arena, source, null, .{});
}

/// The `eggy.zon` in `dir`, parsed into `arena`.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Config {
    const source = try dir.readFileAllocOptions(io, file_name, arena, .limited(1 << 20), .of(u8), 0);
    return parse(arena, source);
}

test "a project gets its resources and scene folders" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFolders(std.testing.io, tmp.dir);
    try makeFolders(std.testing.io, tmp.dir); // already there: fine
    try tmp.dir.access(std.testing.io, scenes_dir, .{});
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

test "eggy.zon written reads back the same, its metadata included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = Config{
        .name = "space_game",
        .title = "Space \"Game\"",
        .default_scene = "resources/scene/start.scene.zon",
        .metadata = .{ .company = "Rat Co", .extra = &.{.{ .name = "Website", .value = "rats.example" }} },
    };
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    try write(&text.writer, config);
    const read = try parse(arena.allocator(), try arena.allocator().dupeZ(u8, text.written()));
    try std.testing.expectEqualStrings(config.title, read.title);
    try std.testing.expectEqualStrings(config.default_scene.?, read.default_scene.?);
    try std.testing.expectEqualStrings("Rat Co", read.metadata.company);
    try std.testing.expectEqualStrings("rats.example", read.metadata.extra[0].value);
    try std.testing.expectEqual(@as(usize, 0), read.metadata.copyright.len);
}
