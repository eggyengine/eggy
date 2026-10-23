//! What a model's materials give its parts: colours, and the texture each one uses, decoded once.
const std = @import("std");
const c = @import("assimp");
const assets = @import("eggy_assets");
const gpa = std.heap.c_allocator;

pub const Surface = struct {
    color: [4]f32 = @splat(1),
    metallic_roughness: [2]f32 = .{ 0, 1 },
    emissive_color: [3]f32 = @splat(0),
};

pub fn materialOf(scene: *const c.struct_aiScene, index: u32) error{InvalidMaterial}!Surface {
    var surface = Surface{};
    if (index >= scene.mNumMaterials) return surface;
    const material = scene.mMaterials[index];
    var color: c.struct_aiColor4D = undefined;
    if (c.aiGetMaterialColor(material, "$clr.base", 0, 0, &color) == c.aiReturn_SUCCESS or
        c.aiGetMaterialColor(material, "$clr.diffuse", 0, 0, &color) == c.aiReturn_SUCCESS)
    {
        surface.color = .{ color.r, color.g, color.b, color.a };
    }
    if (c.aiGetMaterialColor(material, "$clr.emissive", 0, 0, &color) == c.aiReturn_SUCCESS) surface.emissive_color = .{ color.r, color.g, color.b };
    var count: c_uint = 1;
    _ = c.aiGetMaterialFloatArray(material, "$mat.metallicFactor", 0, 0, &surface.metallic_roughness[0], &count);
    count = 1;
    _ = c.aiGetMaterialFloatArray(material, "$mat.roughnessFactor", 0, 0, &surface.metallic_roughness[1], &count);
    for (surface.color) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidMaterial;
    for (surface.metallic_roughness) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidMaterial;
    for (surface.emissive_color) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMaterial;
    return surface;
}

/// The textures a model's materials use, each decoded once.
pub const Textures = struct {
    scene: *const c.struct_aiScene,
    /// The model file's folder, which a material's texture path is relative to.
    dir: []const u8,
    list: std.ArrayList(assets.Texture) = .empty,
    /// Which of `list` each material's texture is (null: it has none, or it didn't decode).
    by_material: std.AutoHashMapUnmanaged(u32, ?u32) = .empty,

    pub fn deinit(self: *Textures) void {
        for (self.list.items) |*texture| texture.deinit(gpa);
        self.list.deinit(gpa);
        self.by_material.deinit(gpa);
    }

    /// The texture of material `index` (its base colour's, else its diffuse one's).
    pub fn ofMaterial(self: *Textures, index: u32) !?u32 {
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
        const file = std.fmt.bufPrintSentinel(&buffer, "{s}/{s}", .{ self.dir, named }, 0) catch return null;
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
