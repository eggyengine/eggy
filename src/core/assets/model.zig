//! The `.eggmodel` format: a model's triangles, ready to draw, in s2s's binary form. Packaging
//! writes one for each model file (imported through assimp); the runtime reads them, with no
//! importer of its own. The editor imports model files directly instead.
const std = @import("std");
const s2s = @import("s2s");

/// What packaging adds to a model file's name for its `.eggmodel`.
pub const extension = ".eggmodel";

/// A corner of a triangle: where it is, and which way its surface faces.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

/// A model's triangles, every three `indices` one, its parts already placed where the model
/// file puts them.
pub const Model = struct {
    vertices: []Vertex,
    indices: []u32,

    /// Free what `read` (or an importer) allocated with `gpa`.
    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
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
    for (model.indices) |index| if (index >= model.vertices.len) return error.UnexpectedData;
    return model;
}

test "a model reads back as written" {
    var vertices = [_]Vertex{ .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } }, .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } }, .{ .position = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 } } };
    var indices = [_]u32{ 0, 2, 1 };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .vertices = &vertices, .indices = &indices });

    var reader: std.Io.Reader = .fixed(bytes.written());
    var model = try read(std.testing.allocator, &reader);
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &indices, model.indices);
    try std.testing.expectEqual(@as(f32, 1), model.vertices[1].position[0]);
}

test "a model pointing past its vertices is refused" {
    var vertices = [_]Vertex{.{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } }};
    var indices = [_]u32{ 0, 0, 5 };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .vertices = &vertices, .indices = &indices });
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.UnexpectedData, read(std.testing.allocator, &reader));
}
