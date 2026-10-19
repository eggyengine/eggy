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
/// Editor/tool-only: `path` is null-terminated, and `settings.scale` multiplies imported
/// geometry. Also propagates packaged-format decoding and allocation errors; never returns
/// borrowed importer memory. Games should use `app.resources().loadModel` instead.
///
/// ```zig
/// var model = try model_import.import(gpa, "/project/resources/models/ship.glb", .{ .scale = 2 });
/// defer model.deinit(gpa);
/// ```
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
/// Editor/tool-only: requires a null-terminated path. The result owns RGBA8 pixels and must be
/// freed even when no GPU texture is created. Also propagates format/allocation errors.
///
/// ```zig
/// var texture = try model_import.decodeImage(gpa, "/project/resources/images/icon.png");
/// defer texture.deinit(gpa);
/// ```
pub fn decodeImage(gpa: std.mem.Allocator, path: [:0]const u8) !assets.Texture {
    var bytes: Bytes = undefined;
    if (!eggy_decode_image(path.ptr, &bytes)) return error.ImportFailed;
    defer eggy_free_bytes(&bytes);
    var reader: std.Io.Reader = .fixed(bytes.ptr[0..bytes.len]);
    return assets.texture.read(gpa, &reader);
}

/// Why the last `import` or `decodeImage` on this thread failed.
/// Borrowed importer diagnostics: copy before another import on this thread or library unload.
/// Read immediately after `ImportFailed`; it is not a general description of other Zig errors.
///
/// ```zig
/// var model = model_import.import(gpa, path, .{}) catch |err| {
///     std.log.err("cannot import {s}: {s}", .{ path, model_import.lastError() });
///     return err;
/// };
/// defer model.deinit(gpa);
/// ```
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

/// A glTF file written as `name` in a new temporary folder, imported with `settings`.
fn importGltf(tmp: *std.testing.TmpDir, name: []const u8, source: []const u8, settings: assets.descriptor.ModelImport) !assets.Model {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = source });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.joinZ(gpa, &.{ dir, name });
    defer gpa.free(path);
    return import(gpa, path, settings);
}

/// One triangle skinned to a root joint and a "bone" joint (at y = 1) that the "lift" clip
/// raises to y = 3 over one second; the third corner follows the bone.
const skinned_triangle =
    \\{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,2]}],"nodes":[{"name":"root","children":[1]},{"name":"bone","translation":[0,1,0]},{"name":"body","mesh":0,"skin":0}],"meshes":[{"name":"tri","primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2},"indices":3}]}],"skins":[{"joints":[0,1],"inverseBindMatrices":6}],"animations":[{"name":"lift","samplers":[{"input":4,"output":5,"interpolation":"LINEAR"}],"channels":[{"sampler":0,"target":{"node":1,"path":"translation"}}]}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5121,"count":3,"type":"VEC4"},{"bufferView":2,"componentType":5126,"count":3,"type":"VEC4"},{"bufferView":3,"componentType":5123,"count":3,"type":"SCALAR"},{"bufferView":4,"componentType":5126,"count":2,"type":"SCALAR","min":[0],"max":[1]},{"bufferView":5,"componentType":5126,"count":2,"type":"VEC3"},{"bufferView":6,"componentType":5126,"count":2,"type":"MAT4"}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":12},{"buffer":0,"byteOffset":48,"byteLength":48},{"buffer":0,"byteOffset":96,"byteLength":6},{"buffer":0,"byteOffset":104,"byteLength":8},{"buffer":0,"byteOffset":112,"byteLength":24},{"buffer":0,"byteOffset":136,"byteLength":128}],"buffers":[{"byteLength":264,"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAABAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAAAAAAABAAIAAAAAAAAAAACAPwAAAAAAAIA/AAAAAAAAAAAAAEBAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAAAAAAAAAAAAgD8AAIA/AAAAAAAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAACAvwAAAAAAAIA/"}]}
;

/// One triangle with a blend shape that pushes its first corner 2 along z, which the "smile" clip
/// turns on over one second.
const morphing_triangle =
    \\{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"face","mesh":0}],"meshes":[{"name":"tri","weights":[0],"primitives":[{"attributes":{"POSITION":0},"indices":2,"targets":[{"POSITION":1}]}]}],"animations":[{"name":"smile","samplers":[{"input":3,"output":4}],"channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[0,0,2]},{"bufferView":2,"componentType":5123,"count":3,"type":"SCALAR"},{"bufferView":3,"componentType":5126,"count":2,"type":"SCALAR","min":[0],"max":[1]},{"bufferView":4,"componentType":5126,"count":2,"type":"SCALAR"}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36},{"buffer":0,"byteOffset":72,"byteLength":6},{"buffer":0,"byteOffset":80,"byteLength":8},{"buffer":0,"byteOffset":88,"byteLength":8}],"buffers":[{"byteLength":96,"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAIAAAAAAAAAAACAPwAAAAAAAIA/"}]}
;

/// The corners of part 0 of `model` with its clip `name` sampled at `time_s`.
fn deformedAt(model: assets.Model, name: []const u8, time_s: f32, out: []assets.model.Vertex) !void {
    const gpa = std.testing.allocator;
    var pose = try assets.rig.Pose.init(gpa, model);
    defer pose.deinit(gpa);
    var deformer = try assets.rig.Deformer.init(gpa, model);
    defer deformer.deinit(gpa);
    pose.apply(model, model.rig.clip(name).?.*, time_s, 1);
    deformer.place(model, pose);
    deformer.part(model, pose, 0, out);
}

test "a skinned glTF keeps its bones and clip, and its corners follow the bone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var model = try importGltf(&tmp, "rigged.gltf", skinned_triangle, .{ .scale = 2 });
    defer model.deinit(std.testing.allocator);

    // Nodes (translations scaled), one skin of two joints, and the clip's key times in seconds.
    try std.testing.expect(model.isRigged() and model.isWhole());
    try std.testing.expect(model.rig.node("bone") != null);
    try std.testing.expectEqual(@as(usize, 1), model.rig.skins.len);
    try std.testing.expectEqual(@as(usize, 2), model.rig.skins[0].joints.len);
    const lift = model.rig.clip("lift") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f32, 1), lift.duration_s, 1e-4);

    // At rest the triangle is where it was drawn, twice the size; a second later its third
    // corner is lifted by the bone (2 more metres in the file, doubled).
    var rest: [3]assets.model.Vertex = undefined;
    var lifted: [3]assets.model.Vertex = undefined;
    try deformedAt(model, "lift", 0, &rest);
    try deformedAt(model, "lift", 1, &lifted);
    var highest_rest: f32 = 0;
    var highest_lifted: f32 = 0;
    for (rest, lifted) |a, b| {
        highest_rest = @max(highest_rest, a.position[1]);
        highest_lifted = @max(highest_lifted, b.position[1]);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 2), highest_rest, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 6), highest_lifted, 1e-3);
    // The model's bounds cover the lifted pose, so culling by them never hides it.
    try std.testing.expect(model.bounds().max[1] >= 6 - 1e-3);
}

test "a glTF with blend shapes imports them as targets driven by a weights clip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var model = try importGltf(&tmp, "morph.gltf", morphing_triangle, .{});
    defer model.deinit(std.testing.allocator);

    try std.testing.expect(model.isRigged() and model.isWhole());
    try std.testing.expectEqual(@as(usize, 1), model.rig.morph_targets.len);
    try std.testing.expectEqual(@as(u32, 1), model.parts[0].morph_count);
    var off: [3]assets.model.Vertex = undefined;
    var on: [3]assets.model.Vertex = undefined;
    try deformedAt(model, "smile", 0, &off);
    try deformedAt(model, "smile", 1, &on);
    var moved: f32 = 0;
    for (off, on) |a, b| moved = @max(moved, @abs(b.position[2] - a.position[2]));
    try std.testing.expectApproxEqAbs(@as(f32, 2), moved, 1e-3);
    // The shape moves a corner out of the rest box, so the bounds are wider than the rest pose.
    try std.testing.expect(@max(model.bounds().max[2], -model.bounds().min[2]) >= 2 - 1e-3);
}

test "a model that doesn't move imports with no rig, parts already placed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "still.obj", .data = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ dir, "still.obj" });
    defer std.testing.allocator.free(path);
    var model = try import(std.testing.allocator, path, .{});
    defer model.deinit(std.testing.allocator);
    try std.testing.expect(!model.isRigged());
    try std.testing.expectEqual(@as(usize, 0), model.rig.clips.len);
    try std.testing.expectEqual(@as(u32, 0), model.parts[0].vertex_count);
}
