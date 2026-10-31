//! What a model's materials give its parts: colours, the textures each one uses (decoded once),
//! how its alpha shows and whether it has a back.
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

/// A part painted with material `index`: its textures, alpha and sides, the rest left for the
/// caller to fill in. glTF's opaque surfaces ignore alpha; masked ones cut it at their cutoff.
pub fn partOf(scene: *const c.struct_aiScene, textures: *Textures, index: u32) !assets.model.Part {
    var part = assets.model.Part{ .first_index = 0, .index_count = 0, .material = materialIndex(scene, index) };
    part.texture = try textures.ofMaterial(index, .base);
    inline for (@typeInfo(assets.model.Maps).@"struct".field_names) |name| {
        @field(part.maps, name) = try textures.ofMaterial(index, @field(Slot, name));
    }
    if (index >= scene.mNumMaterials) return part;
    const material = scene.mMaterials[index];
    var mode: c.struct_aiString = undefined;
    if (c.aiGetMaterialString(material, "$mat.gltf.alphaMode", 0, 0, &mode) == c.aiReturn_SUCCESS) {
        const named = mode.data[0..mode.length];
        if (std.mem.eql(u8, named, "BLEND")) part.alpha_mode = .blend;
        if (std.mem.eql(u8, named, "OPAQUE")) part.alpha_cutoff = 0;
        if (std.mem.eql(u8, named, "MASK")) {
            var cutoff: f32 = 0.5;
            var count: c_uint = 1;
            _ = c.aiGetMaterialFloatArray(material, "$mat.gltf.alphaCutoff", 0, 0, &cutoff, &count);
            if (!std.math.isFinite(cutoff) or cutoff < 0 or cutoff > 1) return error.InvalidMaterial;
            part.alpha_cutoff = cutoff;
        }
    }
    var two_sided: c_int = 0;
    var count: c_uint = 1;
    if (c.aiGetMaterialIntegerArray(material, "$mat.twosided", 0, 0, &two_sided, &count) == c.aiReturn_SUCCESS) part.double_sided = two_sided != 0;
    return part;
}

/// Which texture of a material: its colour, or one of its maps (`assets.model.Maps`).
pub const Slot = enum(u3) {
    base,
    normal,
    metallic_roughness,
    emissive,
    occlusion,

    /// Where assimp keeps it, most specific first (glTF's metallic-roughness texture is its
    /// `UNKNOWN` one, and its occlusion its lightmap).
    fn kinds(self: Slot) []const c_uint {
        return switch (self) {
            .base => &.{ c.aiTextureType_BASE_COLOR, c.aiTextureType_DIFFUSE },
            .normal => &.{ c.aiTextureType_NORMALS, c.aiTextureType_NORMAL_CAMERA },
            .metallic_roughness => &.{ c.aiTextureType_UNKNOWN, c.aiTextureType_DIFFUSE_ROUGHNESS, c.aiTextureType_METALNESS },
            .emissive => &.{ c.aiTextureType_EMISSIVE, c.aiTextureType_EMISSION_COLOR },
            .occlusion => &.{ c.aiTextureType_LIGHTMAP, c.aiTextureType_AMBIENT_OCCLUSION },
        };
    }
};

/// Which of `scene`'s materials `index` is, when it is one.
pub fn materialIndex(scene: *const c.struct_aiScene, index: u32) ?u32 {
    return if (index < scene.mNumMaterials) index else null;
}

/// Each of `scene`'s materials by the name the file gives it ("Material N" when it has none),
/// allocated with `gpa` for the model to own.
pub fn materialNames(scene: *const c.struct_aiScene) error{OutOfMemory}![]assets.model.Material {
    const materials = try gpa.alloc(assets.model.Material, scene.mNumMaterials);
    var made: usize = 0;
    errdefer {
        for (materials[0..made]) |material| gpa.free(material.name);
        gpa.free(materials);
    }
    for (materials, 0..) |*material, index| {
        var name: c.struct_aiString = undefined;
        const named = c.aiGetMaterialString(scene.mMaterials[index], "?mat.name", 0, 0, &name) == c.aiReturn_SUCCESS and name.length > 0;
        material.name = if (named) try gpa.dupe(u8, name.data[0..name.length]) else try std.fmt.allocPrint(gpa, "Material {d}", .{index + 1});
        made += 1;
    }
    return materials;
}

/// The textures a model's materials use, each decoded once.
pub const Textures = struct {
    scene: *const c.struct_aiScene,
    /// The model file's folder, which a material's texture path is relative to.
    dir: []const u8,
    list: std.ArrayList(assets.Texture) = .empty,
    /// Which of `list` each material's texture in each slot is (null: it has none, or it didn't
    /// decode), by material index times eight plus slot.
    by_material: std.AutoHashMapUnmanaged(u32, ?u32) = .empty,
    /// Which of `list` each file or embedded texture already is, by the name the material gives
    /// it, so a map shared by slots (an ORM texture) is decoded once. Keys are owned.
    by_name: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *Textures) void {
        for (self.list.items) |*texture| texture.deinit(gpa);
        self.list.deinit(gpa);
        self.by_material.deinit(gpa);
        self.forgetNames();
    }

    /// Free the name index, once the list has been taken.
    pub fn forgetNames(self: *Textures) void {
        var names = self.by_name.keyIterator();
        while (names.next()) |name| gpa.free(name.*);
        self.by_name.deinit(gpa);
    }

    /// Material `index`'s texture in `slot`.
    pub fn ofMaterial(self: *Textures, index: u32, slot: Slot) !?u32 {
        const key = index * 8 + @backingInt(slot);
        if (self.by_material.get(key)) |known| return known;
        const result = try self.find(index, slot);
        try self.by_material.put(gpa, key, result);
        return result;
    }

    fn find(self: *Textures, index: u32, slot: Slot) !?u32 {
        if (index >= self.scene.mNumMaterials) return null;
        const material = self.scene.mMaterials[index];
        var path: c.aiString = undefined;
        const named = for (slot.kinds()) |kind| {
            if (c.aiGetMaterialTexture(material, kind, 0, &path, null, null, null, null, null, null) == c.aiReturn_SUCCESS) break path.data[0..path.length];
        } else return null;
        if (self.by_name.get(named)) |known| return known;
        const texture = self.decode(named) orelse return null;
        try self.list.append(gpa, texture);
        const at: u32 = @intCast(self.list.items.len - 1);
        const key = try gpa.dupe(u8, named);
        self.by_name.put(gpa, key, at) catch |err| {
            gpa.free(key);
            return err;
        };
        return at;
    }

    fn decode(self: *Textures, named: []const u8) ?assets.Texture {
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
