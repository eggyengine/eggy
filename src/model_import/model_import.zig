//! The `eggy_model_import` module: model files imported, and image files decoded, through
//! `eggy_assimp` (`library.zig`), which whatever imports this links. The editor draws models and
//! textures with it; packaging converts them to `.eggmodel` and `.eggtexture` with it
//! (`package.zig`).
const std = @import("std");
const assets = @import("eggy_assets");
const Bytes = @import("abi.zig").Bytes;

extern fn eggy_import_model(path: [*:0]const u8, scale: f32, out: *Bytes) bool;
extern fn eggy_decode_image(path: [*:0]const u8, out: *Bytes) bool;
extern fn eggy_free_bytes(bytes: *Bytes) void;
extern fn eggy_import_error() [*:0]const u8;

/// The model file at `path` (any path), imported with `settings` (from its descriptor), with its
/// textures, in memory from `gpa` (see `assets.Model.deinit`). Fails with `error.ImportFailed`
/// when assimp can't read it; `lastError` says why.
pub fn import(gpa: std.mem.Allocator, path: [:0]const u8, settings: assets.descriptor.ModelImport) !assets.Model {
    var bytes: Bytes = undefined;
    if (!eggy_import_model(path.ptr, settings.scale, &bytes)) return error.ImportFailed;
    defer eggy_free_bytes(&bytes);
    var reader: std.Io.Reader = .fixed(bytes.ptr[0..bytes.len]);
    return assets.model.read(gpa, &reader);
}

/// The image file at `path` (any path: PNG, JPEG, BMP, TGA, GIF...), decoded, in memory from
/// `gpa` (see `assets.Texture.deinit`). Fails with `error.ImportFailed` when it can't be;
/// `lastError` says why.
pub fn decodeImage(gpa: std.mem.Allocator, path: [:0]const u8) !assets.Texture {
    var bytes: Bytes = undefined;
    if (!eggy_decode_image(path.ptr, &bytes)) return error.ImportFailed;
    defer eggy_free_bytes(&bytes);
    var reader: std.Io.Reader = .fixed(bytes.ptr[0..bytes.len]);
    return assets.texture.read(gpa, &reader);
}

/// Why the last `import` or `decodeImage` on this thread failed.
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

test "an image decodes into its pixels, and a model's material brings its texture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A 2 by 1 image as a BMP (stb_image reads it; red then green, stored blue, green, red).
    const bmp = [_]u8{ 'B', 'M', 62, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0 } ++
        [_]u8{ 40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++
        [_]u8{ 0, 0, 255, 0, 255, 0, 0, 0 };
    try tmp.dir.writeFile(io, .{ .sub_path = "pair.bmp", .data = &bmp });
    // A square whose material's texture is that image.
    try tmp.dir.writeFile(io, .{ .sub_path = "square.mtl", .data = "newmtl painted\nmap_Kd pair.bmp\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "square.obj", .data =
        \\mtllib square.mtl
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 0 1
        \\vt 0 0
        \\vt 1 0
        \\vt 1 1
        \\usemtl painted
        \\f 1/1 3/3 2/2
        \\
    });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);

    const image_path = try std.fs.path.joinZ(gpa, &.{ dir, "pair.bmp" });
    defer gpa.free(image_path);
    var image = try decodeImage(gpa, image_path);
    defer image.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, image.pixels);

    const model_path = try std.fs.path.joinZ(gpa, &.{ dir, "square.obj" });
    defer gpa.free(model_path);
    var model = try import(gpa, model_path, .{});
    defer model.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), model.textures.len);
    try std.testing.expect(model.parts[model.parts.len - 1].texture != null);
    try std.testing.expectError(error.ImportFailed, decodeImage(gpa, "/nonexistent/rat.png"));
}
