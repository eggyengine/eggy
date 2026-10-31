//! `eggy_assimp`: a shared library holding assimp and stb_image, so only the editor and
//! packaging carry them, and the editor links it rather than building it into itself. It
//! imports a model file into one list of triangles, every part placed where the file puts it,
//! scaled, with smooth normals, each mesh a part with its material's texture (an image file
//! beside the model, or one inside it); and it decodes image files. A model that moves (bones,
//! blend shapes, baked frames or clips) keeps its node tree, skins and clips instead (`rig_import.zig`).
const std = @import("std");
const c = @import("assimp");
const Bytes = @import("abi.zig").Bytes;
const assets = @import("eggy_assets");
const Vertex = assets.model.Vertex;
const surfaces = @import("surfaces.zig");
const rig_import = @import("rig_import.zig");
const gpa = std.heap.c_allocator;

/// What assimp does to a model that doesn't move: triangles only, each part moved to where its
/// node puts it, normals where the file has none, shared corners joined, textures' rows top first, and sizes in
/// metres, whatever unit the file is in (an FBX file's centimetres, say), so a model is as big as
/// it was made.
const static_steps = c.aiProcess_Triangulate | c.aiProcess_PreTransformVertices | c.aiProcess_GenSmoothNormals | c.aiProcess_JoinIdenticalVertices | c.aiProcess_SortByPType | c.aiProcess_FlipUVs | c.aiProcess_GlobalScale;

/// The same for one that moves, minus pretransforming: its nodes stay, and a corner is pulled by
/// at most four bones.
const moving_steps = (static_steps & ~@as(c_uint, c.aiProcess_PreTransformVertices)) | c.aiProcess_LimitBoneWeights;

/// Import the model file at `path`, `scale` times its size, into `out` as an `.eggmodel`'s
/// bytes. False when it can't be (`eggy_import_error` says why).
/// C ABI for editor/tools; `path` must be null-terminated and `out` writable.
/// Only a true result initializes `out`; release those C-allocated bytes exactly once with
/// `eggy_free_bytes`, not the caller's allocator. Resets this thread's Eggy diagnostic first.
///
/// ```zig
/// var bytes: Bytes = undefined;
/// if (!eggy_import_model("ship.glb", 1, &bytes)) return error.ImportFailed;
/// defer eggy_free_bytes(&bytes);
/// const encoded = bytes.ptr[0..bytes.len]; // Decode before the deferred free.
/// ```
export fn eggy_import_model(path: [*:0]const u8, scale: f32, out: *Bytes) bool {
    failure = null;
    // Read it untouched, to see whether anything moves, then process it for what it is.
    const scene: *const c.struct_aiScene = c.aiImportFile(path, 0) orelse return false;
    const dir = std.fs.path.dirname(std.mem.span(path)) orelse ".";
    const moves = rig_import.isAnimated(scene);
    const processed = c.aiApplyPostProcessing(scene, if (moves) moving_steps else static_steps) orelse return false;
    // Post-processing frees the scene itself when it fails, so only now is it ours to release.
    defer c.aiReleaseImport(processed);
    var model = (if (moves) rig_import.import(processed, dir, scale) else importScene(processed, dir, scale)) catch |err| return fail(switch (err) {
        error.NoMeshes => "it has no meshes",
        error.InvalidMaterial => "it has invalid material parameters",
        error.OutOfMemory => "out of memory",
        error.UnknownJoint => "a bone has no node in the file",
        error.MismatchedBlendShape => "a blend shape or baked frame doesn't match its mesh",
    });
    defer model.deinit(gpa);
    if (!model.isWhole()) return fail("its animation data is inconsistent");
    return serialize(assets.model.write, model, out);
}

/// Decode the image file at `path` into `out` as an `.eggtexture`'s bytes. False when it can't
/// be (`eggy_import_error` says why).
/// C ABI: `path` is null-terminated and `out` writable. Success initializes C-owned serialized
/// RGBA8 texture bytes; failure leaves `out` unusable and exposes diagnostics on this thread.
///
/// ```zig
/// var bytes: Bytes = undefined;
/// if (!eggy_decode_image("icon.png", &bytes)) return error.ImportFailed;
/// defer eggy_free_bytes(&bytes);
/// ```
export fn eggy_decode_image(path: [*:0]const u8, out: *Bytes) bool {
    failure = null;
    if (decodeGif(path, out)) |decoded| return decoded;
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load(path, &width, &height, &channels, 4) orelse return fail(c.stbi_failure_reason());
    defer c.stbi_image_free(pixels);
    const size: usize = @intCast(width * height * 4);
    return serialize(assets.texture.write, assets.Texture{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels[0..size] }, out);
}

/// Decode the GIF at `path` with every frame into `out`, as `eggy_decode_image` does; null when
/// the file isn't a GIF (or can't be read), for the still-image decoder to try.
fn decodeGif(path: [*:0]const u8, out: *Bytes) ?bool {
    const file = c.fopen(path, "rb") orelse return null;
    defer _ = c.fclose(file);
    var magic: [4]u8 = undefined;
    if (c.fread(&magic, 1, magic.len, file) != magic.len or !std.mem.eql(u8, &magic, "GIF8")) return null;
    if (c.fseek(file, 0, c.SEEK_END) != 0) return null;
    const length = c.ftell(file);
    if (length <= 0 or length > std.math.maxInt(c_int) or c.fseek(file, 0, c.SEEK_SET) != 0) return null;
    const bytes = gpa.alloc(u8, @intCast(length)) catch return fail("out of memory");
    defer gpa.free(bytes);
    if (c.fread(bytes.ptr, 1, bytes.len, file) != bytes.len) return fail("the file can't be read");

    var delays: [*c]c_int = null;
    var width: c_int = 0;
    var height: c_int = 0;
    var frames: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load_gif_from_memory(bytes.ptr, @intCast(bytes.len), &delays, &width, &height, &frames, &channels, 4) orelse return fail(c.stbi_failure_reason());
    defer c.stbi_image_free(pixels);
    defer if (delays != null) c.stbi_image_free(delays);
    const count: usize = @intCast(@max(frames, 1));
    // Browsers show GIF delays under 20 ms as 100 ms; so do we.
    const frame_delays = gpa.alloc(u32, if (count > 1) count else 0) catch return fail("out of memory");
    defer gpa.free(frame_delays);
    for (frame_delays, 0..) |*delay, i| delay.* = if (delays == null or delays[i] < 20) 100 else @intCast(delays[i]);
    const size: usize = @as(usize, @intCast(width * height * 4)) * count;
    return serialize(assets.texture.write, assets.Texture{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels[0..size], .frame_delays_ms = frame_delays }, out);
}

/// Free what `eggy_import_model` or `eggy_decode_image` put in `bytes`.
/// C ABI; only pass a successful result from this library, exactly once. Does not clear
/// the struct: its pointer becomes dangling. Never pass caller/Zig-allocator-owned storage.
///
/// ```zig
/// if (!eggy_decode_image(path, &bytes)) return error.ImportFailed;
/// defer eggy_free_bytes(&bytes);
/// ```
export fn eggy_free_bytes(bytes: *Bytes) void {
    gpa.free(bytes.ptr[0..bytes.len]);
}

/// Why the last import on this thread failed.
/// C ABI returning a borrowed null-terminated string, not memory to free.
/// Query immediately after a failed call, before another import or unloading the library.
///
/// ```zig
/// if (!eggy_import_model(path, 1, &bytes)) {
///     std.log.err("import failed: {s}", .{std.mem.span(eggy_import_error())});
///     return error.ImportFailed;
/// }
/// ```
export fn eggy_import_error() [*:0]const u8 {
    return failure orelse c.aiGetErrorString();
}

/// A failure of Eggy's own (rather than assimp's), for `eggy_import_error`.
threadlocal var failure: ?[*:0]const u8 = null;

fn fail(why: [*:0]const u8) bool {
    failure = why;
    return false;
}

/// `value` written by `write` into new bytes in `out`.
fn serialize(comptime write: anytype, value: anytype, out: *Bytes) bool {
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    write(&bytes.writer, value) catch {
        bytes.deinit();
        return fail("out of memory");
    };
    const owned = bytes.toOwnedSlice() catch return fail("out of memory");
    out.* = .{ .ptr = owned.ptr, .len = owned.len };
    return true;
}

/// `scene`'s meshes as one model, each mesh a part, from the file in folder `dir`.
fn importScene(scene: *const c.struct_aiScene, dir: []const u8, scale: f32) !assets.Model {
    const meshes = if (scene.mMeshes) |list| list[0..scene.mNumMeshes] else return error.NoMeshes;

    // Room for every mesh's corners and triangles (points and lines left out).
    var vertex_count: usize = 0;
    var index_count: usize = 0;
    for (meshes) |mesh| {
        vertex_count += mesh.*.mNumVertices;
        for (mesh.*.mFaces[0..mesh.*.mNumFaces]) |face| {
            if (face.mNumIndices == 3) index_count += 3;
        }
    }
    const vertices = try gpa.alloc(Vertex, vertex_count);
    errdefer gpa.free(vertices);
    const indices = try gpa.alloc(u32, index_count);
    errdefer gpa.free(indices);
    const parts = try gpa.alloc(assets.model.Part, meshes.len);
    errdefer gpa.free(parts);
    var textures = surfaces.Textures{ .scene = scene, .dir = dir };
    errdefer textures.deinit();

    // Each mesh's corners, then its triangles pointing at them, as a part with its material's texture.
    var next_vertex: usize = 0;
    var next_index: usize = 0;
    for (meshes, parts) |mesh, *part| {
        const material = try surfaces.materialOf(scene, mesh.*.mMaterialIndex);
        const first: u32 = @intCast(next_vertex);
        const channels = mesh.*.mTextureCoords;
        const uvs: [*c]c.struct_aiVector3D = channels[0];
        for (0..mesh.*.mNumVertices) |i| {
            const at = mesh.*.mVertices[i];
            const normal: [3]f32 = if (mesh.*.mNormals) |normals| .{ normals[i].x, normals[i].y, normals[i].z } else .{ 0, 1, 0 };
            const uv: [2]f32 = if (uvs != null) .{ uvs[i].x, uvs[i].y } else .{ 0, 0 };
            vertices[next_vertex] = .{ .position = .{ at.x * scale, at.y * scale, at.z * scale }, .normal = normal, .uv = uv, .color = material.color, .metallic_roughness = material.metallic_roughness, .emissive_color = material.emissive_color };
            next_vertex += 1;
        }

        part.* = try surfaces.partOf(scene, &textures, mesh.*.mMaterialIndex);
        part.first_index = @intCast(next_index);
        for (mesh.*.mFaces[0..mesh.*.mNumFaces]) |face| {
            if (face.mNumIndices != 3) continue;
            for (face.mIndices[0..3]) |index| {
                indices[next_index] = first + index;
                next_index += 1;
            }
        }
        part.index_count = @intCast(next_index - part.first_index);
    }
    const materials = try surfaces.materialNames(scene);
    const decoded = try textures.list.toOwnedSlice(gpa);
    textures.by_material.deinit(gpa);
    textures.forgetNames();
    return .{ .vertices = vertices, .indices = indices, .parts = parts, .textures = decoded, .materials = materials };
}
