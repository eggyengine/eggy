//! Imports a model that moves (bones, blend shapes, baked vertex animation or clips) as a rigged
//! `assets.Model`: the file's node tree, every mesh instance as its own part in mesh space, skins,
//! blend shapes and clips. A model that doesn't move is imported by `library.zig` instead, with
//! its parts already placed.
const std = @import("std");
const c = @import("assimp");
const assets = @import("eggy_assets");
const surfaces = @import("surfaces.zig");
const model = assets.model;
const gpa = std.heap.c_allocator;

/// Why a moving model can't be imported; `library.zig` words each for the user.
pub const Error = error{ NoMeshes, InvalidMaterial, OutOfMemory, UnknownJoint, MismatchedBlendShape };

/// Seconds per tick for a clip whose file doesn't say (assimp's own convention).
const default_ticks_per_second = 25;

/// Whether `scene` has anything that moves: animations, bones or blend shapes.
pub fn isAnimated(scene: *const c.struct_aiScene) bool {
    if (scene.mNumAnimations > 0) return true;
    const meshes = if (scene.mMeshes) |list| list[0..scene.mNumMeshes] else return false;
    for (meshes) |mesh| if (mesh.*.mNumBones > 0 or mesh.*.mNumAnimMeshes > 0) return true;
    return false;
}

/// `scene` (already triangulated, with smooth normals) as a rigged model, sizes `scale` times
/// the file's, textures from the folder `dir`. The result is whole (`Model.isWhole`) or an error.
pub fn import(scene: *const c.struct_aiScene, dir: []const u8, scale: f32) Error!assets.Model {
    const meshes = if (scene.mMeshes) |list| list[0..scene.mNumMeshes] else return error.NoMeshes;
    const root = scene.mRootNode orelse return error.NoMeshes;
    var builder = Builder{ .scale = scale };
    errdefer builder.deinit();
    var textures = surfaces.Textures{ .scene = scene, .dir = dir };
    errdefer textures.deinit();

    // The node tree, parents first, then each mesh where a node places it.
    try builder.addNode(root, null);
    const skin_of = try gpa.alloc(?u32, meshes.len);
    defer gpa.free(skin_of);
    @memset(skin_of, null);
    for (builder.sources.items, 0..) |node, node_index| {
        for (cArray(node.*.mMeshes, node.*.mNumMeshes)) |mesh_index| {
            try builder.addPart(scene, &textures, mesh_index, @intCast(node_index), skin_of);
        }
    }
    if (builder.parts.items.len == 0) return error.NoMeshes;

    try builder.addClips(scene);

    const skinned = for (builder.parts.items) |part| {
        if (part.skin != null) break true;
    } else false;
    if (!skinned) builder.influences.clearAndFree(gpa);
    const decoded = try textures.list.toOwnedSlice(gpa);
    textures.by_material.deinit(gpa);
    errdefer for (decoded) |*texture| texture.deinit(gpa);
    const result = assets.Model{
        .vertices = try builder.vertices.toOwnedSlice(gpa),
        .indices = try builder.indices.toOwnedSlice(gpa),
        .parts = try builder.parts.toOwnedSlice(gpa),
        .textures = decoded,
        .materials = try surfaces.materialNames(scene),
        .rig = .{
            .nodes = try builder.nodes.toOwnedSlice(gpa),
            .influences = try builder.influences.toOwnedSlice(gpa),
            .skins = try builder.skins.toOwnedSlice(gpa),
            .morph_targets = try builder.morphs.toOwnedSlice(gpa),
            .clips = try builder.clips.toOwnedSlice(gpa),
        },
    };
    builder.release();
    return result;
}

/// Everything a rigged import has made so far; owns it until `import` hands it over.
const Builder = struct {
    scale: f32,
    vertices: std.ArrayList(model.Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    parts: std.ArrayList(model.Part) = .empty,
    nodes: std.ArrayList(model.Node) = .empty,
    /// The file's node for each of `nodes`.
    sources: std.ArrayList(*const c.struct_aiNode) = .empty,
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    influences: std.ArrayList(model.Influence) = .empty,
    skins: std.ArrayList(model.Skin) = .empty,
    morphs: std.ArrayList(model.MorphTarget) = .empty,
    clips: std.ArrayList(model.Clip) = .empty,
    /// The part each placed mesh instance became, by the file's mesh index.
    placements: std.ArrayList(struct { mesh: u32, part: u32 }) = .empty,

    /// Free everything still owned.
    fn deinit(self: *Builder) void {
        for (self.nodes.items) |node| gpa.free(node.name);
        for (self.skins.items) |skin| {
            gpa.free(skin.joints);
            gpa.free(skin.inverse_bind);
        }
        for (self.morphs.items) |target| {
            gpa.free(target.name);
            gpa.free(target.deltas);
        }
        for (self.clips.items) |clip| freeClip(clip);
        self.release();
    }

    /// Free the lists themselves, once their items belong to someone else (or were freed).
    fn release(self: *Builder) void {
        self.vertices.deinit(gpa);
        self.indices.deinit(gpa);
        self.parts.deinit(gpa);
        self.nodes.deinit(gpa);
        self.sources.deinit(gpa);
        self.by_name.deinit(gpa);
        self.influences.deinit(gpa);
        self.skins.deinit(gpa);
        self.morphs.deinit(gpa);
        self.clips.deinit(gpa);
        self.placements.deinit(gpa);
    }

    /// Add `node` and then its children, so parents always come first.
    fn addNode(self: *Builder, node: *const c.struct_aiNode, parent: ?u32) Error!void {
        var scaling: c.aiVector3D = undefined;
        var rotation: c.aiQuaternion = undefined;
        var position: c.aiVector3D = undefined;
        c.aiDecomposeMatrix(&node.mTransformation, &scaling, &rotation, &position);
        const label = try gpa.dupe(u8, text(&node.mName));
        const index: u32 = @intCast(self.nodes.items.len);
        self.nodes.append(gpa, .{
            .name = label,
            .parent = parent,
            .translation = .{ position.x * self.scale, position.y * self.scale, position.z * self.scale },
            .rotation = .{ rotation.x, rotation.y, rotation.z, rotation.w },
            .scale = .{ scaling.x, scaling.y, scaling.z },
        }) catch |err| {
            gpa.free(label);
            return err;
        };
        try self.sources.append(gpa, node);
        const entry = try self.by_name.getOrPut(gpa, label);
        if (!entry.found_existing) entry.value_ptr.* = index;
        for (cArray(node.mChildren, node.mNumChildren)) |child| try self.addNode(child, index);
    }

    /// The node a channel or bone names; a morph channel's `name*3` suffix is ignored.
    fn findNode(self: *const Builder, name: []const u8) ?u32 {
        if (self.by_name.get(name)) |found| return found;
        const star = std.mem.indexOfScalar(u8, name, '*') orelse return null;
        return self.by_name.get(name[0..star]);
    }

    /// Place `mesh_index` at `node`: its corners (in mesh space), triangles, skin and blend shapes
    /// as one part.
    fn addPart(self: *Builder, scene: *const c.struct_aiScene, textures: *surfaces.Textures, mesh_index: u32, node: u32, skin_of: []?u32) Error!void {
        const mesh = scene.mMeshes[mesh_index];
        var triangles: usize = 0;
        for (cArray(mesh.*.mFaces, mesh.*.mNumFaces)) |face| {
            if (face.mNumIndices == 3) triangles += 1;
        }
        if (triangles == 0 or mesh.*.mNumVertices == 0) return;
        const surface = try surfaces.materialOf(scene, mesh.*.mMaterialIndex);
        const texture = try textures.ofMaterial(mesh.*.mMaterialIndex);
        const first_vertex: u32 = @intCast(self.vertices.items.len);
        const count = mesh.*.mNumVertices;

        // Corners, then what pulls each one.
        const channels = mesh.*.mTextureCoords;
        const uvs: [*c]c.struct_aiVector3D = channels[0];
        try self.vertices.ensureUnusedCapacity(gpa, count);
        for (0..count) |i| {
            const at = mesh.*.mVertices[i];
            const normal: [3]f32 = if (mesh.*.mNormals) |normals| .{ normals[i].x, normals[i].y, normals[i].z } else .{ 0, 1, 0 };
            const uv: [2]f32 = if (uvs != null) .{ uvs[i].x, uvs[i].y } else .{ 0, 0 };
            self.vertices.appendAssumeCapacity(.{
                .position = .{ at.x * self.scale, at.y * self.scale, at.z * self.scale },
                .normal = normal,
                .uv = uv,
                .color = surface.color,
                .metallic_roughness = surface.metallic_roughness,
                .emissive_color = surface.emissive_color,
            });
        }
        try self.addInfluences(mesh, first_vertex);
        const skin: ?u32 = if (mesh.*.mNumBones > 0) skin_of[mesh_index] orelse blk: {
            skin_of[mesh_index] = try self.addSkin(mesh);
            break :blk skin_of[mesh_index];
        } else null;

        // Triangles, pointing at this part's own corners.
        const first_index: u32 = @intCast(self.indices.items.len);
        try self.indices.ensureUnusedCapacity(gpa, triangles * 3);
        for (cArray(mesh.*.mFaces, mesh.*.mNumFaces)) |face| {
            if (face.mNumIndices != 3) continue;
            for (face.mIndices[0..3]) |index| self.indices.appendAssumeCapacity(first_vertex + index);
        }

        const morph_first: u32 = @intCast(self.morphs.items.len);
        if (!isCacheMesh(scene, mesh)) try self.addMorphTargets(mesh, first_vertex);
        try self.placements.append(gpa, .{ .mesh = mesh_index, .part = @intCast(self.parts.items.len) });
        try self.parts.append(gpa, .{
            .first_index = first_index,
            .index_count = @intCast(triangles * 3),
            .texture = texture,
            .material = surfaces.materialIndex(scene, mesh.*.mMaterialIndex),
            .first_vertex = first_vertex,
            .vertex_count = count,
            .node = node,
            .skin = skin,
            .morph_first = morph_first,
            .morph_count = @intCast(self.morphs.items.len - morph_first),
        });
    }

    /// The four strongest joints pulling each corner of `mesh`, weights adding up to one; a
    /// corner no bone holds gets none.
    fn addInfluences(self: *Builder, mesh: *const c.struct_aiMesh, first_vertex: u32) Error!void {
        const count = mesh.mNumVertices;
        try self.influences.appendNTimes(gpa, .{}, count);
        const mine = self.influences.items[first_vertex..][0..count];
        if (mesh.mNumBones == 0) return;
        for (cArray(mesh.mBones, mesh.mNumBones), 0..) |bone, joint| {
            for (cArray(bone.*.mWeights, bone.*.mNumWeights)) |pull| {
                if (pull.mVertexId >= count or !(pull.mWeight > 0)) continue;
                const slot = &mine[pull.mVertexId];
                // Take a free slot, else displace the weakest if this is stronger.
                var weakest: usize = 0;
                for (slot.weights, 0..) |weight, i| {
                    if (weight < slot.weights[weakest]) weakest = i;
                }
                if (slot.weights[weakest] < pull.mWeight) {
                    slot.joints[weakest] = @intCast(joint);
                    slot.weights[weakest] = pull.mWeight;
                }
            }
        }
        for (mine) |*slot| {
            const total = @reduce(.Add, @as(@Vector(4, f32), slot.weights));
            if (total > 0) for (&slot.weights) |*weight| {
                weight.* /= total;
            };
        }
    }

    /// The skin of `mesh`: each bone's node, and its inverse bind matrix.
    fn addSkin(self: *Builder, mesh: *const c.struct_aiMesh) Error!u32 {
        const joints = try gpa.alloc(u32, mesh.mNumBones);
        errdefer gpa.free(joints);
        const inverse_bind = try gpa.alloc([4][4]f32, mesh.mNumBones);
        errdefer gpa.free(inverse_bind);
        for (cArray(mesh.mBones, mesh.mNumBones), joints, inverse_bind) |bone, *joint, *matrix| {
            joint.* = self.findNode(text(&bone.*.mName)) orelse return error.UnknownJoint;
            matrix.* = columns(bone.*.mOffsetMatrix, self.scale);
        }
        try self.skins.append(gpa, .{ .joints = joints, .inverse_bind = inverse_bind });
        return @intCast(self.skins.items.len - 1);
    }

    /// The blend shapes of `mesh` as targets of the part about to be added: how far each moves
    /// each corner it moves.
    fn addMorphTargets(self: *Builder, mesh: *const c.struct_aiMesh, first_vertex: u32) Error!void {
        if (mesh.mNumAnimMeshes == 0) return;
        for (cArray(mesh.mAnimMeshes, mesh.mNumAnimMeshes), 0..) |shape, number| {
            if (shape.*.mNumVertices != mesh.mNumVertices) return error.MismatchedBlendShape;
            var deltas: std.ArrayList(model.MorphDelta) = .empty;
            errdefer deltas.deinit(gpa);
            for (0..mesh.mNumVertices) |i| {
                var position: [3]f32 = @splat(0);
                var normal: [3]f32 = @splat(0);
                if (shape.*.mVertices) |moved| {
                    const base = mesh.mVertices[i];
                    position = .{ (moved[i].x - base.x) * self.scale, (moved[i].y - base.y) * self.scale, (moved[i].z - base.z) * self.scale };
                }
                if (shape.*.mNormals != null and mesh.mNormals != null) {
                    const moved = shape.*.mNormals[i];
                    const base = mesh.mNormals[i];
                    normal = .{ moved.x - base.x, moved.y - base.y, moved.z - base.z };
                }
                if (std.mem.allEqual(f32, &position, 0) and std.mem.allEqual(f32, &normal, 0)) continue;
                try deltas.append(gpa, .{ .vertex = first_vertex + @as(u32, @intCast(i)), .position = position, .normal = normal });
            }
            const label = if (shape.*.mName.length > 0) try gpa.dupe(u8, text(&shape.*.mName)) else try std.fmt.allocPrint(gpa, "target{d}", .{number});
            errdefer gpa.free(label);
            const owned = try deltas.toOwnedSlice(gpa);
            errdefer gpa.free(owned);
            try self.morphs.append(gpa, .{ .name = label, .default_weight = shape.*.mWeight, .deltas = owned });
        }
    }

    /// Every animation of the file as a clip: node tracks, blend-shape weights and baked frames.
    fn addClips(self: *Builder, scene: *const c.struct_aiScene) Error!void {
        const animations = if (scene.mAnimations) |list| list[0..scene.mNumAnimations] else return;
        for (animations, 0..) |animation, number| {
            const ticks: f64 = if (animation.*.mTicksPerSecond > 0) animation.*.mTicksPerSecond else default_ticks_per_second;
            var tracks: std.ArrayList(model.Track) = .empty;
            errdefer {
                for (tracks.items) |track| freeTrack(track);
                tracks.deinit(gpa);
            }
            var duration_s: f32 = 0;

            // Node keys: translation, rotation and scale.
            if (animation.*.mChannels) |channels| for (channels[0..animation.*.mNumChannels]) |channel| {
                const node = self.findNode(text(&channel.*.mNodeName)) orelse {
                    std.log.warn("animation {d} moves {s}, which is not a node; skipped", .{ number, text(&channel.*.mNodeName) });
                    continue;
                };
                try self.addVectorTrack(&tracks, .translation, node, cArray(channel.*.mPositionKeys, channel.*.mNumPositionKeys), ticks, self.scale, &duration_s);
                try self.addRotationTrack(&tracks, node, cArray(channel.*.mRotationKeys, channel.*.mNumRotationKeys), ticks, &duration_s);
                try self.addVectorTrack(&tracks, .scale, node, cArray(channel.*.mScalingKeys, channel.*.mNumScalingKeys), ticks, 1, &duration_s);
            };

            // Blend-shape weights, one number for each target of the parts at the node.
            if (animation.*.mMorphMeshChannels) |channels| for (channels[0..animation.*.mNumMorphMeshChannels]) |channel| {
                const node = self.findNode(text(&channel.*.mName)) orelse continue;
                const stride = self.morphCountAt(node);
                if (stride == 0) continue;
                try self.addMorphTrack(&tracks, node, stride, cArray(channel.*.mKeys, channel.*.mNumKeys), ticks, &duration_s);
            };

            // Baked frames: the absolute corners of the mesh's anim mesh at each key.
            if (animation.*.mMeshChannels) |channels| for (channels[0..animation.*.mNumMeshChannels]) |channel| {
                try self.addCacheTracks(scene, &tracks, channel, ticks, &duration_s);
            };

            if (tracks.items.len == 0) continue;
            const length: f32 = @floatCast(animation.*.mDuration / ticks);
            if (std.math.isFinite(length)) duration_s = @max(duration_s, length);
            const label = if (animation.*.mName.length > 0) try gpa.dupe(u8, text(&animation.*.mName)) else try std.fmt.allocPrint(gpa, "animation{d}", .{number});
            errdefer gpa.free(label);
            const owned = try tracks.toOwnedSlice(gpa);
            errdefer gpa.free(owned);
            try self.clips.append(gpa, .{ .name = label, .duration_s = duration_s, .tracks = owned });
        }
    }

    /// How many blend-shape weights the parts at `node` have (they all have the same).
    fn morphCountAt(self: *const Builder, node: u32) u32 {
        for (self.parts.items) |part| if (part.node == node and part.morph_count > 0) return part.morph_count;
        return 0;
    }

    fn addVectorTrack(self: *Builder, tracks: *std.ArrayList(model.Track), channel: model.Channel, node: u32, keys: []const c.struct_aiVectorKey, ticks: f64, factor: f32, duration_s: *f32) Error!void {
        _ = self;
        if (keys.len == 0) return;
        const times = try gpa.alloc(f32, keys.len);
        errdefer gpa.free(times);
        const values = try gpa.alloc(f32, keys.len * 3);
        errdefer gpa.free(values);
        var last: f32 = 0;
        for (keys, times, 0..) |key, *time, i| {
            time.* = keyTime(key.mTime, ticks, last);
            last = time.*;
            values[i * 3 ..][0..3].* = .{ key.mValue.x * factor, key.mValue.y * factor, key.mValue.z * factor };
        }
        duration_s.* = @max(duration_s.*, last);
        try tracks.append(gpa, .{ .channel = channel, .target = node, .stride = 3, .times = times, .values = values });
    }

    fn addRotationTrack(self: *Builder, tracks: *std.ArrayList(model.Track), node: u32, keys: []const c.struct_aiQuatKey, ticks: f64, duration_s: *f32) Error!void {
        _ = self;
        if (keys.len == 0) return;
        const times = try gpa.alloc(f32, keys.len);
        errdefer gpa.free(times);
        const values = try gpa.alloc(f32, keys.len * 4);
        errdefer gpa.free(values);
        var last: f32 = 0;
        for (keys, times, 0..) |key, *time, i| {
            time.* = keyTime(key.mTime, ticks, last);
            last = time.*;
            const q = key.mValue;
            values[i * 4 ..][0..4].* = .{ q.x, q.y, q.z, q.w };
        }
        duration_s.* = @max(duration_s.*, last);
        try tracks.append(gpa, .{ .channel = .rotation, .target = node, .stride = 4, .times = times, .values = values });
    }

    fn addMorphTrack(self: *Builder, tracks: *std.ArrayList(model.Track), node: u32, stride: u32, keys: []const c.struct_aiMeshMorphKey, ticks: f64, duration_s: *f32) Error!void {
        _ = self;
        if (keys.len == 0) return;
        const times = try gpa.alloc(f32, keys.len);
        errdefer gpa.free(times);
        const values = try gpa.alloc(f32, keys.len * stride);
        errdefer gpa.free(values);
        @memset(values, 0);
        var last: f32 = 0;
        for (keys, times, 0..) |key, *time, i| {
            time.* = keyTime(key.mTime, ticks, last);
            last = time.*;
            for (cArray(key.mValues, key.mNumValuesAndWeights), cArray(key.mWeights, key.mNumValuesAndWeights)) |target, weight| {
                if (target < stride) values[i * stride + target] = @floatCast(weight);
            }
        }
        duration_s.* = @max(duration_s.*, last);
        try tracks.append(gpa, .{ .channel = .morph_weights, .target = node, .stride = stride, .times = times, .values = values });
    }

    /// One baked-vertex track for each part that places the mesh the channel names.
    fn addCacheTracks(self: *Builder, scene: *const c.struct_aiScene, tracks: *std.ArrayList(model.Track), channel: *const c.struct_aiMeshAnim, ticks: f64, duration_s: *f32) Error!void {
        const keys = cArray(channel.mKeys, channel.mNumKeys);
        if (keys.len == 0) return;
        for (self.placements.items) |placed| {
            const mesh = scene.mMeshes[placed.mesh];
            if (!std.mem.eql(u8, text(&mesh.*.mName), text(&channel.mName))) continue;
            const stride = mesh.*.mNumVertices * 3;
            const times = try gpa.alloc(f32, keys.len);
            errdefer gpa.free(times);
            const values = try gpa.alloc(f32, keys.len * stride);
            errdefer gpa.free(values);
            var last: f32 = 0;
            for (keys, times, 0..) |key, *time, i| {
                time.* = keyTime(key.mTime, ticks, last);
                last = time.*;
                if (key.mValue >= mesh.*.mNumAnimMeshes) return error.MismatchedBlendShape;
                const frame = mesh.*.mAnimMeshes[key.mValue];
                if (frame.*.mNumVertices != mesh.*.mNumVertices or frame.*.mVertices == null) return error.MismatchedBlendShape;
                for (cArray(frame.*.mVertices, frame.*.mNumVertices), 0..) |at, v| {
                    values[i * stride + v * 3 ..][0..3].* = .{ at.x * self.scale, at.y * self.scale, at.z * self.scale };
                }
            }
            duration_s.* = @max(duration_s.*, last);
            try tracks.append(gpa, .{ .channel = .vertex_cache, .target = placed.part, .stride = stride, .times = times, .values = values });
        }
    }
};

/// Whether some animation bakes `mesh`'s anim meshes as frames (so they aren't blend shapes).
fn isCacheMesh(scene: *const c.struct_aiScene, mesh: *const c.struct_aiMesh) bool {
    const animations = if (scene.mAnimations) |list| list[0..scene.mNumAnimations] else return false;
    for (animations) |animation| {
        const channels = animation.*.mMeshChannels orelse continue;
        for (channels[0..animation.*.mNumMeshChannels]) |channel| {
            if (std.mem.eql(u8, text(&channel.*.mName), text(&mesh.mName))) return true;
        }
    }
    return false;
}

/// A key's time in seconds, never earlier than the key before it.
fn keyTime(ticks_at: f64, ticks_per_second: f64, previous_s: f32) f32 {
    const seconds: f32 = @floatCast(ticks_at / ticks_per_second);
    return if (std.math.isFinite(seconds)) @max(seconds, previous_s) else previous_s;
}

/// A matrix as columns, its translation `scale` times as long.
fn columns(m: c.aiMatrix4x4, scale: f32) [4][4]f32 {
    return .{
        .{ m.a1, m.b1, m.c1, m.d1 },
        .{ m.a2, m.b2, m.c2, m.d2 },
        .{ m.a3, m.b3, m.c3, m.d3 },
        .{ m.a4 * scale, m.b4 * scale, m.c4 * scale, m.d4 },
    };
}

/// `count` items from a C array that may be null when empty.
fn cArray(pointer: anytype, count: anytype) []std.meta.Child(@TypeOf(pointer)) {
    if (count == 0) return &.{};
    return pointer[0..count];
}

fn text(name: *const c.aiString) []const u8 {
    return name.data[0..name.length];
}

fn freeTrack(track: model.Track) void {
    gpa.free(track.times);
    gpa.free(track.values);
}

fn freeClip(clip: model.Clip) void {
    gpa.free(clip.name);
    for (clip.tracks) |track| freeTrack(track);
    gpa.free(clip.tracks);
}
