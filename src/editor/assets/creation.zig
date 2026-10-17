//! File types offered by the Assets panel's shared New menu.
const eggy = @import("eggy");
const FileType = eggy.plugins.EditorFileType;

pub const Entry = union(enum) {
    scene,
    folder,
    file: FileType,

    pub fn label(self: Entry) []const u8 {
        return switch (self) {
            .scene => "Scene",
            .folder => "Folder",
            .file => |file_type| file_type.title,
        };
    }
};

const builtins = [_]Entry{
    .scene,
    .{ .file = .{
        .key = "eggy/input_map",
        .title = "Input Map",
        .extension = ".inmap.zon",
        .contents = ".{\n    .version = 1,\n    .controls = .{},\n}\n",
    } },
    .folder,
    .{ .file = .{ .key = "eggy/text", .title = "Text File", .extension = ".txt" } },
    .{ .file = .{ .key = "eggy/zig", .title = "Zig File", .extension = ".zig", .contents = "//! A project module.\n" } },
    .{ .file = .{ .key = "eggy/zon", .title = "ZON File", .extension = ".zon", .contents = ".{}\n" } },
    .{ .file = .{ .key = "eggy/json", .title = "JSON File", .extension = ".json", .contents = "{}\n" } },
    .{ .file = .{ .key = "eggy/markdown", .title = "Markdown File", .extension = ".md", .contents = "# New document\n" } },
    .{ .file = .{ .key = "eggy/toml", .title = "TOML File", .extension = ".toml" } },
};

pub fn count(plugins: []const FileType) usize {
    return builtins.len + plugins.len;
}

/// The same catalog serves both the toolbar dropdown and the right-click submenu.
pub fn at(index: usize, plugins: []const FileType) ?Entry {
    if (index < builtins.len) return builtins[index];
    if (index - builtins.len < plugins.len) return .{ .file = plugins[index - builtins.len] };
    return null;
}

test "built-in input maps are valid ZON and plugin templates extend the same catalog" {
    const std = @import("std");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try eggy.input.asset.File.parse(arena.allocator(), try arena.allocator().dupeZ(u8, builtins[1].file.contents));
    const plugins = [_]FileType{.{ .key = "game/material", .title = "Material", .extension = ".material.zon", .contents = ".{}" }};
    try std.testing.expectEqualStrings("Material", at(builtins.len, &plugins).?.label());
    try std.testing.expect(at(count(&plugins), &plugins) == null);
}
