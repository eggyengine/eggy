//! What the Assets panel's New menus offer: Eggy's own kinds, then each plugin's file templates.
const std = @import("std");
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

/// Eggy's own: what a game is made of. Plain text files belong in the code editor, not here;
/// plugins add their own kinds with `editor_file_types`.
const builtins = [_]Entry{
    .scene,
    .{ .file = .{
        .key = "eggy/input_map",
        .title = "Input Map",
        .extension = ".inmap.zon",
        .contents = ".{\n    .version = 1,\n    .controls = .{},\n}\n",
    } },
    .folder,
};

/// How many entries are Eggy's own; the plugins' follow, in plugin order.
pub const builtin_count = builtins.len;

/// The plugin that offers `file_type`: its key's part before the first `/`.
pub fn ownerOf(file_type: FileType) []const u8 {
    const key: []const u8 = file_type.key;
    return key[0 .. std.mem.indexOfScalar(u8, key, '/') orelse key.len];
}

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try eggy.input.asset.File.parse(arena.allocator(), try arena.allocator().dupeZ(u8, builtins[1].file.contents));
    const plugins = [_]FileType{.{ .key = "game/material", .title = "Material", .extension = ".material.zon", .contents = ".{}" }};
    try std.testing.expectEqualStrings("Material", at(builtins.len, &plugins).?.label());
    try std.testing.expect(at(count(&plugins), &plugins) == null);
    try std.testing.expectEqualStrings("game", ownerOf(plugins[0]));
}
