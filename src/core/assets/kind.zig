//! What kind of file each of a project's files is, by its name.
const std = @import("std");

/// What kind of file something is, by its name; `any` accepts every file.
pub const Kind = enum(u8) {
    any,
    scene,
    image,
    audio,
    text,
    code,
    /// A 3D model.
    model,
    /// A folder: its descriptor says so. `of` never gives it, since a name doesn't tell.
    folder,
    /// A complete input-map resource.
    input_map,
    /// A reusable surface material.
    material,

    /// The kind of the file at `path`; `any` for a kind Eggy doesn't know.
    /// Does not inspect the filesystem or infer folders. Ordinary extensions ignore case;
    /// the compound `.scene.zon` and `.inmap.zon` suffixes are case-sensitive.
    ///
    /// ```zig
    /// const kind = Kind.of("resources/ship.GLB"); // .model
    /// ```
    pub fn of(path: []const u8) Kind {
        if (std.mem.endsWith(u8, path, ".scene.zon")) return .scene;
        if (std.mem.endsWith(u8, path, ".inmap.zon")) return .input_map;
        if (std.mem.endsWith(u8, path, ".material.zon")) return .material;
        const extension = std.fs.path.extension(path);
        const kinds = [_]struct { []const []const u8, Kind }{
            .{ &.{".zig"}, .code },
            .{ &.{ ".zon", ".md", ".txt", ".json", ".toml" }, .text },
            .{ &.{ ".png", ".jpg", ".jpeg", ".gif", ".svg", ".bmp", ".webp" }, .image },
            .{ &.{ ".wav", ".ogg", ".mp3", ".flac" }, .audio },
            .{ &.{ ".glb", ".gltf", ".obj", ".fbx", ".dae", ".3ds", ".ply", ".stl" }, .model },
        };
        for (kinds) |entry| for (entry[0]) |known| {
            if (std.ascii.eqlIgnoreCase(extension, known)) return entry[1];
        };
        return .any;
    }

    /// Whether the file at `path` is an image a mesh can be painted with: one stb_image decodes
    /// (not an SVG or WebP).
    /// Checks the extension without decoding or opening the file.
    ///
    /// ```zig
    /// const decodable = Kind.isTexture("resources/wood.png");
    /// ```
    pub fn isTexture(path: []const u8) bool {
        const extension = std.fs.path.extension(path);
        for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp" }) |known| {
            if (std.ascii.eqlIgnoreCase(extension, known)) return true;
        }
        return false;
    }

    /// Whether a field of this kind takes the file at `path`.
    /// `.any` accepts every name; other kinds compare against `of`, not file contents.
    ///
    /// ```zig
    /// const accepted = Kind.audio.takes("resources/bell.ogg");
    /// ```
    pub fn takes(self: Kind, path: []const u8) bool {
        return self == .any or Kind.of(path) == self;
    }
};

test "a file's kind comes from its name" {
    try std.testing.expect(Kind.audio.takes("sounds/boom.ogg"));
    try std.testing.expect(!Kind.audio.takes("art/ship.png"));
    try std.testing.expectEqual(Kind.scene, Kind.of("levels/one.scene.zon"));
    try std.testing.expectEqual(Kind.model, Kind.of("ships/Fighter.GLB"));
    try std.testing.expectEqual(Kind.input_map, Kind.of("input/player.inmap.zon"));
    try std.testing.expectEqual(Kind.material, Kind.of("art/metal.material.zon"));
    try std.testing.expect(Kind.isTexture("art/Wood.PNG"));
    try std.testing.expect(!Kind.isTexture("art/logo.svg"));
}
