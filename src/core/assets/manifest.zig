//! The manifest of a packaged game's resources, `data/manifest.zon`: each file of the project's
//! `resources/` by its path, with the id its descriptor gave it. Packaging names what it puts in
//! `data/` after that id (`packagedName`), never after the file, so the runtime finds a file
//! through the manifest.
//!
//!     .{ .files = .{
//!         .{ .path = "resources/assets/rat.glb", .id = 8410273145522034177 },
//!     } }
const std = @import("std");
const Kind = @import("kind.zig").Kind;

/// The manifest's name in `data/`.
pub const file_name = "manifest.zon";

pub const Entry = struct {
    /// Relative to the project, with `/` between parts.
    path: []const u8,
    /// Its descriptor's id.
    id: u64,
};

pub const Manifest = struct {
    files: []const Entry = &.{},

    /// The entry for `path`, if packaged.
    pub fn find(self: Manifest, path: []const u8) ?Entry {
        for (self.files) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
        return null;
    }
};

/// What packaging makes of the file at `path`.
pub const Packaged = enum {
    /// Imported into an `.eggmodel`.
    model,
    /// Decoded into an `.eggtexture`.
    texture,
    /// Copied as it is.
    copy,

    pub fn of(path: []const u8) Packaged {
        if (Kind.of(path) == .model) return .model;
        if (Kind.isTexture(path)) return .texture;
        return .copy;
    }

    /// What its name in `data/` ends in.
    pub fn extension(self: Packaged) []const u8 {
        return switch (self) {
            .model => ".eggmodel",
            .texture => ".eggtexture",
            .copy => "",
        };
    }
};

/// The name in `data/` of what packaging made of `entry`, in `buffer`: its id in hexadecimal,
/// then what it was made into (`000000000000002a.eggmodel` for a model with id 42).
pub fn packagedName(buffer: []u8, entry: Entry) []const u8 {
    return std.fmt.bufPrint(buffer, "{x:0>16}{s}", .{ entry.id, Packaged.of(entry.path).extension() }) catch unreachable;
}

/// An id for a file without a descriptor, the same whenever its path is.
pub fn pathId(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6567_6779, path);
}

/// `manifest` as ZON.
pub fn write(writer: *std.Io.Writer, manifest: Manifest) std.Io.Writer.Error!void {
    try std.zon.stringify.serialize(manifest, .{}, writer);
    try writer.writeByte('\n');
}

/// `text` (a manifest's ZON) read into `arena`.
pub fn parse(arena: std.mem.Allocator, text: [:0]const u8) !Manifest {
    return std.zon.parse.fromSliceAlloc(Manifest, arena, text, null, .{ .ignore_unknown_fields = true });
}

test "a manifest reads back, and names what it packaged after ids, not files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]Entry{ .{ .path = "resources/assets/rat.glb", .id = 0x2a }, .{ .path = "resources/scene/sewer.scene.zon", .id = 7 } };
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    try write(&text.writer, .{ .files = &files });
    const read = try parse(arena.allocator(), try arena.allocator().dupeZ(u8, text.written()));
    const rat = read.find("resources/assets/rat.glb").?;
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000002a.eggmodel", packagedName(&buffer, rat));
    try std.testing.expectEqualStrings("0000000000000007", packagedName(&buffer, read.find("resources/scene/sewer.scene.zon").?));
    try std.testing.expect(read.find("resources/rat.glb") == null);
}
