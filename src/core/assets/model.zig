//! The `.eggmodel` format: a model's triangles, ready to draw, in s2s's binary form. Packaging
//! writes one for each model file (imported through assimp); the runtime reads them, with no
//! importer of its own. The editor imports model files directly instead.
const std = @import("std");
const s2s = @import("s2s");
const Texture = @import("texture.zig").Texture;

/// What packaging adds to a model file's name for its `.eggmodel`.
pub const extension = ".eggmodel";

/// A corner of a triangle: where it is, which way its surface faces, and where on a texture it
/// is (from its top left corner, 0 to 1 across).
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32 = .{ 0, 0 },
};

/// A run of a model's `indices` drawn with one texture: its own, or none (the `Mesh`'s, or
/// plain colour).
pub const Part = struct {
    first_index: u32,
    index_count: u32,
    /// Which of the model's `textures`.
    texture: ?u32 = null,
};

/// A model's triangles, every three `indices` one, its parts already placed where the model
/// file puts them, and the textures its materials use.
pub const Model = struct {
    vertices: []Vertex,
    indices: []u32,
    parts: []Part,
    textures: []Texture,

    /// Free what `read` (or an importer) allocated with `gpa`.
    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        gpa.free(self.parts);
        for (self.textures) |*texture| texture.deinit(gpa);
        gpa.free(self.textures);
    }

    /// Whether every index points at a vertex, every part at indices and a texture there are,
    /// and every texture is whole.
    pub fn isWhole(self: Model) bool {
        for (self.indices) |index| if (index >= self.vertices.len) return false;
        for (self.parts) |part| {
            if (@as(usize, part.first_index) + part.index_count > self.indices.len) return false;
            if (part.texture) |texture| if (texture >= self.textures.len) return false;
        }
        for (self.textures) |texture| if (!texture.isWhole()) return false;
        return true;
    }
};

/// Write `model` as an `.eggmodel`.
pub fn write(writer: *std.Io.Writer, model: Model) std.Io.Writer.Error!void {
    try s2s.serialize(writer, Model, model);
}

/// Read an `.eggmodel`, allocating with `gpa` (see `Model.deinit`). Fails with
/// `error.UnexpectedData` for one of another version of the format.
pub fn read(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Model {
    var model = try s2s.deserializeAlloc(reader, Model, gpa);
    errdefer model.deinit(gpa);
    if (!model.isWhole()) return error.UnexpectedData;
    return model;
}

test "a model reads back as written" {
    var vertices = [_]Vertex{ .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } }, .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } }, .{ .position = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 } } };
    var indices = [_]u32{ 0, 2, 1 };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var parts = [_]Part{.{ .first_index = 0, .index_count = 3, .texture = 0 }};
    var pixels = [_]u8{ 1, 2, 3, 4 };
    var textures = [_]Texture{.{ .width = 1, .height = 1, .pixels = &pixels }};
    try write(&bytes.writer, .{ .vertices = &vertices, .indices = &indices, .parts = &parts, .textures = &textures });

    var reader: std.Io.Reader = .fixed(bytes.written());
    var model = try read(std.testing.allocator, &reader);
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &indices, model.indices);
    try std.testing.expectEqual(@as(?u32, 0), model.parts[0].texture);
    try std.testing.expectEqualSlices(u8, &pixels, model.textures[0].pixels);
    try std.testing.expectEqual(@as(f32, 1), model.vertices[1].position[0]);
}

test "a model pointing past its vertices is refused" {
    var vertices = [_]Vertex{.{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } }};
    var indices = [_]u32{ 0, 0, 5 };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .vertices = &vertices, .indices = &indices, .parts = &.{}, .textures = &.{} });
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.UnexpectedData, read(std.testing.allocator, &reader));
}
