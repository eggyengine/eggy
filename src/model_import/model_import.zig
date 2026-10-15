//! The `eggy_model_import` module: model files imported through `eggy_assimp` (`library.zig`),
//! which whatever imports this links. The editor draws models with it; packaging converts them
//! to `.eggmodel` with it (`package.zig`).
const std = @import("std");
const assets = @import("eggy_assets");
const Imported = @import("abi.zig").Imported;

extern fn eggy_import_model(path: [*:0]const u8, scale: f32, out: *Imported) bool;
extern fn eggy_free_model(model: *Imported) void;
extern fn eggy_import_error() [*:0]const u8;

/// The model file at `path` (any path), imported with `settings` (from its descriptor), copied
/// into memory from `gpa` (see `assets.Model.deinit`). Fails with `error.ImportFailed` when
/// assimp can't read it; `lastError` says why.
pub fn import(gpa: std.mem.Allocator, path: [:0]const u8, settings: assets.descriptor.ModelImport) !assets.Model {
    var imported: Imported = undefined;
    if (!eggy_import_model(path.ptr, settings.scale, &imported)) return error.ImportFailed;
    defer eggy_free_model(&imported);
    const vertices = try gpa.dupe(assets.model.Vertex, imported.vertices[0..imported.vertex_count]);
    errdefer gpa.free(vertices);
    return .{ .vertices = vertices, .indices = try gpa.dupe(u32, imported.indices[0..imported.index_count]) };
}

/// Why the last `import` on this thread failed.
pub fn lastError() []const u8 {
    return std.mem.span(eggy_import_error());
}

test "an OBJ file imports as triangles, scaled by its settings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A square of two triangles, one metre across, facing up.
    try tmp.dir.writeFile(io, .{ .sub_path = "square.obj", .data =
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 0 1
        \\v 0 0 1
        \\f 1 3 2
        \\f 1 4 3
        \\
    });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ dir, "square.obj" });
    defer std.testing.allocator.free(path);

    var model = try import(std.testing.allocator, path, .{ .scale = 2 });
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), model.indices.len);
    var widest: f32 = 0;
    for (model.vertices) |vertex| widest = @max(widest, vertex.position[0]);
    try std.testing.expectEqual(@as(f32, 2), widest);
    // Smooth normals made for a file without them: up (or down), along y.
    try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(model.vertices[0].normal[1]), 0.001);
}

test "a file that isn't a model fails with assimp's reason" {
    try std.testing.expectError(error.ImportFailed, import(std.testing.allocator, "/nonexistent/ship.glb", .{}));
    try std.testing.expect(lastError().len > 0);
}
