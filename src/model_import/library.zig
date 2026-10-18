//! `eggy_assimp`: a shared library holding assimp and stb_image, so only the editor and
//! packaging carry them, and the editor links it rather than building it into itself. It
//! imports a model file into one list of triangles, every part placed where the file puts it,
//! scaled, with smooth normals, each mesh a part with its material's texture (an image file
//! beside the model, or one inside it); and it decodes image files.
const std = @import("std");
const c = @import("assimp");
const Bytes = @import("abi.zig").Bytes;
const assets = @import("eggy_assets");
const Vertex = assets.model.Vertex;
const gpa = std.heap.c_allocator;

/// What assimp does to every model: triangles only, each part moved to where its node puts it,
/// normals where the file has none, shared corners joined, textures' rows top first, and sizes in
/// metres, whatever unit the file is in (an FBX file's centimetres, say), so a model is as big as
/// it was made.
const steps = c.aiProcess_Triangulate | c.aiProcess_PreTransformVertices | c.aiProcess_GenSmoothNormals | c.aiProcess_JoinIdenticalVertices | c.aiProcess_SortByPType | c.aiProcess_FlipUVs | c.aiProcess_GlobalScale;

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
    const scene: *const c.struct_aiScene = c.aiImportFile(path, steps) orelse return false;
    defer c.aiReleaseImport(scene);
    var model = importScene(scene, std.fs.path.dirname(std.mem.span(path)) orelse ".", scale) catch |err| return fail(switch (err) {
        error.NoMeshes => "it has no meshes",
        error.OutOfMemory => "out of memory",
    });
    defer model.deinit(gpa);
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
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load(path, &width, &height, &channels, 4) orelse return fail(c.stbi_failure_reason());
    defer c.stbi_image_free(pixels);
    const size: usize = @intCast(width * height * 4);
    return serialize(assets.texture.write, assets.Texture{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels[0..size] }, out);
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
    var textures = Textures{ .scene = scene, .dir = dir };
    errdefer textures.deinit();

    // Each mesh's corners, then its triangles pointing at them, as a part with its material's texture.
    var next_vertex: usize = 0;
    var next_index: usize = 0;
    for (meshes, parts) |mesh, *part| {
        const first: u32 = @intCast(next_vertex);
        const channels = mesh.*.mTextureCoords;
        const uvs: [*c]c.struct_aiVector3D = channels[0];
        for (0..mesh.*.mNumVertices) |i| {
            const at = mesh.*.mVertices[i];
            const normal: [3]f32 = if (mesh.*.mNormals) |normals| .{ normals[i].x, normals[i].y, normals[i].z } else .{ 0, 1, 0 };
            const uv: [2]f32 = if (uvs != null) .{ uvs[i].x, uvs[i].y } else .{ 0, 0 };
            vertices[next_vertex] = .{ .position = .{ at.x * scale, at.y * scale, at.z * scale }, .normal = normal, .uv = uv };
            next_vertex += 1;
        }
        part.* = .{ .first_index = @intCast(next_index), .index_count = 0, .texture = try textures.ofMaterial(mesh.*.mMaterialIndex) };
        for (mesh.*.mFaces[0..mesh.*.mNumFaces]) |face| {
            if (face.mNumIndices != 3) continue;
            for (face.mIndices[0..3]) |index| {
                indices[next_index] = first + index;
                next_index += 1;
            }
        }
        part.index_count = @intCast(next_index - part.first_index);
    }
    const decoded = try textures.list.toOwnedSlice(gpa);
    textures.by_material.deinit(gpa);
    return .{ .vertices = vertices, .indices = indices, .parts = parts, .textures = decoded };
}

/// The textures a model's materials use, each decoded once.
const Textures = struct {
    scene: *const c.struct_aiScene,
    /// The model file's folder, which a material's texture path is relative to.
    dir: []const u8,
    list: std.ArrayList(assets.Texture) = .empty,
    /// Which of `list` each material's texture is (null: it has none, or it didn't decode).
    by_material: std.AutoHashMapUnmanaged(u32, ?u32) = .empty,

    fn deinit(self: *Textures) void {
        for (self.list.items) |*texture| texture.deinit(gpa);
        self.list.deinit(gpa);
        self.by_material.deinit(gpa);
    }

    /// The texture of material `index` (its base colour's, else its diffuse one's).
    fn ofMaterial(self: *Textures, index: u32) !?u32 {
        if (self.by_material.get(index)) |known| return known;
        const found = self.decode(index);
        if (found) |texture| try self.list.append(gpa, texture);
        const result: ?u32 = if (found != null) @intCast(self.list.items.len - 1) else null;
        try self.by_material.put(gpa, index, result);
        return result;
    }

    fn decode(self: *Textures, index: u32) ?assets.Texture {
        if (index >= self.scene.mNumMaterials) return null;
        const material = self.scene.mMaterials[index];
        var path: c.aiString = undefined;
        const kinds = [_]c_uint{ c.aiTextureType_BASE_COLOR, c.aiTextureType_DIFFUSE };
        const named = for (kinds) |kind| {
            if (c.aiGetMaterialTexture(material, kind, 0, &path, null, null, null, null, null, null) == c.aiReturn_SUCCESS) break path.data[0..path.length];
        } else return null;
        if (self.embedded(named)) |texture| return decodeEmbedded(texture);
        // A file beside the model.
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file = std.fmt.bufPrintZ(&buffer, "{s}/{s}", .{ self.dir, named }) catch return null;
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const pixels = c.stbi_load(file.ptr, &width, &height, &channels, 4) orelse return null;
        defer c.stbi_image_free(pixels);
        return copied(pixels, width, height);
    }

    /// The texture inside the model file that `named` refers to (`*2`, or its file name).
    fn embedded(self: *const Textures, named: []const u8) ?*const c.struct_aiTexture {
        const all = if (self.scene.mTextures) |list| list[0..self.scene.mNumTextures] else return null;
        if (named.len > 1 and named[0] == '*') {
            const at = std.fmt.parseInt(usize, named[1..], 10) catch return null;
            return if (at < all.len) all[at] else null;
        }
        for (all) |texture| {
            const name = texture.*.mFilename.data[0..texture.*.mFilename.length];
            if (std.mem.eql(u8, std.fs.path.basename(name), std.fs.path.basename(named))) return texture;
        }
        return null;
    }
};

/// An embedded texture's pixels: a compressed image (PNG, JPEG...) decoded, or its texels.
fn decodeEmbedded(texture: *const c.struct_aiTexture) ?assets.Texture {
    if (texture.mHeight == 0) {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const pixels = c.stbi_load_from_memory(@ptrCast(texture.pcData), @intCast(texture.mWidth), &width, &height, &channels, 4) orelse return null;
        defer c.stbi_image_free(pixels);
        return copied(pixels, width, height);
    }
    // Texels are blue, green, red and alpha.
    const count = @as(usize, texture.mWidth) * texture.mHeight;
    const pixels = gpa.alloc(u8, count * 4) catch return null;
    for (texture.pcData[0..count], 0..) |texel, i| pixels[i * 4 ..][0..4].* = .{ texel.r, texel.g, texel.b, texel.a };
    return .{ .width = texture.mWidth, .height = texture.mHeight, .pixels = pixels };
}

/// stb_image's `pixels` (`width` by `height`, four bytes each) in memory of our own.
fn copied(pixels: [*c]u8, width: c_int, height: c_int) ?assets.Texture {
    const size: usize = @intCast(width * height * 4);
    return .{ .width = @intCast(width), .height = @intCast(height), .pixels = gpa.dupe(u8, pixels[0..size]) catch return null };
}
