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

    /// The kind of the file at `path`; `any` for a kind Eggy doesn't know.
    pub fn of(path: []const u8) Kind {
        if (std.mem.endsWith(u8, path, ".scene.zon")) return .scene;
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

    /// Whether a field of this kind takes the file at `path`.
    pub fn takes(self: Kind, path: []const u8) bool {
        return self == .any or Kind.of(path) == self;
    }
};

test "a file's kind comes from its name" {
    try std.testing.expect(Kind.audio.takes("sounds/boom.ogg"));
    try std.testing.expect(!Kind.audio.takes("art/ship.png"));
    try std.testing.expectEqual(Kind.scene, Kind.of("levels/one.scene.zon"));
    try std.testing.expectEqual(Kind.model, Kind.of("ships/Fighter.GLB"));
}
