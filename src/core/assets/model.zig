//! The `.eggmodel` format: a model's triangles, ready to draw, and the rig that moves them, in
//! s2s's binary form. Packaging writes one for each model file (imported through assimp); the
//! runtime reads them, with no importer of its own. The editor imports model files directly instead.
const std = @import("std");
const s2s = @import("s2s");
const Texture = @import("texture.zig").Texture;
const Bounds = @import("bounds.zig").Bounds;
const rig_zig = @import("rig.zig");

/// A corner of a triangle: where it is, which way its surface faces, and where on a texture it
/// is (from its top left corner, 0 to 1 across).
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32 = .{ 0, 0 },
    color: [4]f32 = @splat(1),
    metallic_roughness: [2]f32 = .{ 0, 1 },
    emissive_color: [3]f32 = @splat(0),
};

/// The `.eggmodel` layout this build reads and writes. A file of another version fails to read
/// with `error.UnexpectedData`; bump it whenever the stored types below change shape or meaning.
pub const format_version: u32 = 3;

/// A run of a model's `indices` drawn with one texture: its own, or none (the `Mesh`'s, or
/// plain colour).
pub const Part = struct {
    first_index: u32,
    index_count: u32,
    /// Which of the model's `textures`.
    texture: ?u32 = null,
    /// Which of the model's `materials` paints it; its colours are in its corners.
    material: ?u32 = null,
    /// The corners this part owns, which its indices point into. Only a model with a `Rig` fills
    /// them in; a part of a static model leaves them zero.
    first_vertex: u32 = 0,
    vertex_count: u32 = 0,
    /// The rig node whose world matrix places this part's corners (a mesh instance), and whose
    /// morph-weight channel drives it.
    node: ?u32 = null,
    /// The skin deforming this part's corners; they are then in the skin's bind space and the
    /// part's `node` places nothing.
    skin: ?u32 = null,
    /// This part's blend shapes: `rig.morph_targets[morph_first..][0..morph_count]`.
    morph_first: u32 = 0,
    morph_count: u32 = 0,
};

/// A material of the model file, as it names it, for the editor to show.
pub const Material = struct {
    name: []const u8,
};

/// A joint of the model's node tree. Parents come before their children.
pub const Node = struct {
    name: []const u8,
    parent: ?u32 = null,
    /// Rest pose, relative to the parent: translation in metres, rotation as x, y, z, w.
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
};

/// Up to four joints pulling a corner, by index into its part's skin, with their weights
/// (adding up to one, or all zero for a corner that stays where it is).
pub const Influence = struct {
    joints: [4]u32 = @splat(0),
    weights: [4]f32 = @splat(0),
};

/// The joints a skinned part is bound to, and each one's inverse bind matrix (columns).
pub const Skin = struct {
    joints: []u32,
    inverse_bind: [][4][4]f32,
};

/// How one corner of a part moves when its blend shape is fully on.
pub const MorphDelta = struct {
    /// Absolute index into the model's `vertices`, inside the owning part.
    vertex: u32,
    position: [3]f32,
    normal: [3]f32 = .{ 0, 0, 0 },
};

/// A blend shape (morph target) of one part: only the corners it moves.
pub const MorphTarget = struct {
    name: []const u8,
    default_weight: f32 = 0,
    deltas: []MorphDelta,
};

/// What a track moves, and how many numbers a key holds (`Track.stride`).
pub const Channel = enum {
    /// A node's translation: 3 numbers.
    translation,
    /// A node's rotation as x, y, z, w: 4 numbers.
    rotation,
    /// A node's scale: 3 numbers.
    scale,
    /// Every blend-shape weight of the parts at a node: one number each.
    morph_weights,
    /// Every corner of a part, baked: 3 numbers each.
    vertex_cache,
};

pub const Interpolation = enum { step, linear };

/// Keys of one channel of a clip. `target` is a node (for every channel but `vertex_cache`) or
/// a part (`vertex_cache`); `values` holds `stride` numbers for each of `times` (seconds,
/// ascending). Rotations blend spherically, the rest linearly.
pub const Track = struct {
    channel: Channel,
    target: u32,
    interpolation: Interpolation = .linear,
    stride: u32,
    times: []f32,
    values: []f32,
};

/// A named animation of the rig.
pub const Clip = struct {
    name: []const u8,
    duration_s: f32,
    tracks: []Track,
};

/// What makes a model moveable: its node tree, skins, blend shapes and clips. All empty for a
/// static model.
pub const Rig = struct {
    nodes: []Node = &.{},
    /// One for each of the model's `vertices` when any part is skinned; else empty.
    influences: []Influence = &.{},
    skins: []Skin = &.{},
    morph_targets: []MorphTarget = &.{},
    clips: []Clip = &.{},

    /// The clip called `name`, if the rig has one.
    ///
    /// ```zig
    /// const walk = model.rig.clip("walk") orelse return error.NoSuchClip;
    /// ```
    pub fn clip(self: Rig, name: []const u8) ?*const Clip {
        for (self.clips) |*found| if (std.mem.eql(u8, found.name, name)) return found;
        return null;
    }

    /// The node called `name`; the first one when names repeat.
    pub fn node(self: Rig, name: []const u8) ?u32 {
        for (self.nodes, 0..) |found, index| if (std.mem.eql(u8, found.name, name)) return @intCast(index);
        return null;
    }

    /// Free what `read` (or an importer) allocated with `gpa`.
    pub fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
        for (self.nodes) |found| gpa.free(found.name);
        gpa.free(self.nodes);
        gpa.free(self.influences);
        for (self.skins) |skin| {
            gpa.free(skin.joints);
            gpa.free(skin.inverse_bind);
        }
        gpa.free(self.skins);
        for (self.morph_targets) |target| {
            gpa.free(target.name);
            gpa.free(target.deltas);
        }
        gpa.free(self.morph_targets);
        for (self.clips) |found| {
            gpa.free(found.name);
            for (found.tracks) |track| {
                gpa.free(track.times);
                gpa.free(track.values);
            }
            gpa.free(found.tracks);
        }
        gpa.free(self.clips);
    }
};

/// A model's triangles, every three `indices` one, and the textures its materials use. A static
/// model's parts are already placed where the model file puts them; one with a `rig` keeps its
/// parts in their own space, for the rig's nodes and clips to place and move.
pub const Model = struct {
    /// Always `format_version` when written.
    format_version: u32 = format_version,
    vertices: []Vertex,
    indices: []u32,
    parts: []Part,
    textures: []Texture,
    materials: []Material = &.{},
    rig: Rig = .{},

    /// Free what `read` (or an importer) allocated with `gpa`.
    /// Recursively frees textures and the rig too; all slices must belong to that allocator.
    /// Invalidates the model and any borrowed views; call once after GPU upload/use finishes.
    ///
    /// ```zig
    /// var model = try read(gpa, reader);
    /// defer model.deinit(gpa);
    /// ```
    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        gpa.free(self.parts);
        for (self.textures) |*texture| texture.deinit(gpa);
        gpa.free(self.textures);
        for (self.materials) |material| gpa.free(material.name);
        gpa.free(self.materials);
        self.rig.deinit(gpa);
    }

    /// Whether the rig has nodes, so parts need its nodes and clips to be placed.
    pub fn isRigged(self: Model) bool {
        return self.rig.nodes.len > 0;
    }

    /// The box round the model in its own space. A rigged model's holds every pose its clips
    /// reach, so culling by it never hides a moving part (see `rig.animatedBounds`).
    ///
    /// ```zig
    /// const box = model.bounds();
    /// ```
    pub fn bounds(self: Model) Bounds {
        if (self.isRigged()) return rig_zig.animatedBounds(self);
        var box = Bounds{ .min = @splat(std.math.inf(f32)), .max = @splat(-std.math.inf(f32)) };
        for (self.vertices) |vertex| box.include(vertex.position);
        if (self.vertices.len == 0) box = .{ .min = @splat(0), .max = @splat(0) };
        return box;
    }

    /// Whether every index points at a vertex, every part at indices and a texture there are,
    /// every texture is whole, and the rig is consistent: parents before children, every part,
    /// skin, blend shape, track and key inside the arrays they point at, numbers finite and
    /// times ascending.
    /// Allocates nothing and does not check triangle winding, normal lengths or index-count
    /// divisibility.
    ///
    /// ```zig
    /// if (!model.isWhole()) return error.InvalidModel;
    /// ```
    pub fn isWhole(self: Model) bool {
        if (self.format_version != format_version) return false;
        for (self.indices) |index| if (index >= self.vertices.len) return false;
        for (self.parts) |part| {
            if (@as(usize, part.first_index) + part.index_count > self.indices.len) return false;
            if (part.texture) |texture| if (texture >= self.textures.len) return false;
            if (part.material) |material| if (material >= self.materials.len) return false;
        }
        for (self.textures) |texture| if (!texture.isWhole()) return false;
        return self.rigIsWhole();
    }

    fn rigIsWhole(self: Model) bool {
        const rig = self.rig;
        if (rig.nodes.len == 0) {
            return rig.influences.len == 0 and rig.skins.len == 0 and rig.morph_targets.len == 0 and rig.clips.len == 0;
        }
        for (rig.nodes, 0..) |node, index| {
            if (node.parent) |parent| if (parent >= index) return false;
            if (!allFinite(&node.translation) or !allFinite(&node.rotation) or !allFinite(&node.scale)) return false;
            if (@reduce(.Add, @as(@Vector(4, f32), node.rotation) * @as(@Vector(4, f32), node.rotation)) < 1e-12) return false;
        }
        for (rig.skins) |skin| {
            if (skin.joints.len != skin.inverse_bind.len) return false;
            for (skin.joints) |joint| if (joint >= rig.nodes.len) return false;
            for (skin.inverse_bind) |matrix| for (matrix) |column| if (!allFinite(&column)) return false;
        }
        const skinned = for (self.parts) |part| {
            if (part.skin != null) break true;
        } else false;
        if (rig.influences.len != if (skinned) self.vertices.len else 0) return false;

        // Each part's corners, indices, node, skin and blend shapes; blend shapes belong to one part.
        var morphs_owned: usize = 0;
        for (self.parts) |part| {
            const end = @as(usize, part.first_vertex) + part.vertex_count;
            if (part.vertex_count == 0 or end > self.vertices.len) return false;
            for (self.indices[part.first_index..][0..part.index_count]) |index| if (index < part.first_vertex or index >= end) return false;
            if (part.node) |node| if (node >= rig.nodes.len) return false;
            if (part.skin) |skin| {
                if (skin >= rig.skins.len) return false;
                const joints = rig.skins[skin].joints.len;
                for (rig.influences[part.first_vertex..end]) |influence| for (influence.joints, influence.weights) |joint, weight| {
                    if (!std.math.isFinite(weight) or weight < 0) return false;
                    if (weight > 0 and joint >= joints) return false;
                };
            }
            if (@as(usize, part.morph_first) + part.morph_count > rig.morph_targets.len) return false;
            if (part.morph_count > 0 and part.node == null) return false;
            morphs_owned += part.morph_count;
            for (rig.morph_targets[part.morph_first..][0..part.morph_count]) |target| {
                if (!std.math.isFinite(target.default_weight)) return false;
                for (target.deltas) |delta| {
                    if (delta.vertex < part.first_vertex or delta.vertex >= end) return false;
                    if (!allFinite(&delta.position) or !allFinite(&delta.normal)) return false;
                }
            }
        }
        if (morphs_owned != rig.morph_targets.len) return false;
        for (rig.clips) |clip| if (!self.clipIsWhole(clip)) return false;
        return true;
    }

    /// Check channel indices and dimensions against this already validated model.
    pub fn clipIsWhole(self: Model, clip: Clip) bool {
        if (clip.name.len == 0 or !std.math.isFinite(clip.duration_s) or clip.duration_s < 0) return false;
        for (clip.tracks) |track| {
            const value_count = std.math.mul(usize, track.times.len, track.stride) catch return false;
            if (track.times.len == 0 or track.values.len != value_count) return false;
            if (!allFinite(track.times) or !allFinite(track.values)) return false;
            if (track.times[0] < 0 or track.times[track.times.len - 1] > clip.duration_s) return false;
            for (track.times[1..], track.times[0 .. track.times.len - 1]) |next, previous| if (next < previous) return false;
            switch (track.channel) {
                .translation, .scale => if (track.stride != 3 or track.target >= self.rig.nodes.len) return false,
                .rotation => if (track.stride != 4 or track.target >= self.rig.nodes.len) return false,
                .morph_weights => {
                    // Every part at the node must have exactly the weights it carries.
                    var parts: usize = 0;
                    for (self.parts) |part| if (part.node == track.target and part.morph_count > 0) {
                        if (part.morph_count != track.stride) return false;
                        parts += 1;
                    };
                    if (track.target >= self.rig.nodes.len or parts == 0) return false;
                },
                .vertex_cache => {
                    if (track.target >= self.parts.len) return false;
                    if (track.stride != @as(u64, self.parts[track.target].vertex_count) * 3) return false;
                },
            }
        }
        return true;
    }
};

fn allFinite(values: []const f32) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Write `model` as an `.eggmodel`.
/// Borrows its slices without validating them; propagates writer errors.
///
/// ```zig
/// var output: std.Io.Writer.Allocating = .init(gpa);
/// defer output.deinit();
/// try write(&output.writer, model);
/// ```
pub fn write(writer: *std.Io.Writer, model: Model) std.Io.Writer.Error!void {
    try s2s.serialize(writer, Model, model);
}

/// Read an `.eggmodel`, allocating with `gpa` (see `Model.deinit`). Fails with
/// `error.UnexpectedData` for one of another version of the format.
/// Also rejects invalid index/texture ranges via `isWhole`; reader and allocation errors
/// propagate. The caller owns all returned slices, including embedded textures.
///
/// ```zig
/// var input: std.Io.Reader = .fixed(eggmodel_bytes);
/// var model = try read(gpa, &input);
/// defer model.deinit(gpa);
/// ```
pub fn read(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Model {
    var model = try s2s.deserializeAlloc(reader, Model, gpa);
    errdefer model.deinit(gpa);
    if (!model.isWhole()) return error.UnexpectedData;
    return model;
}

test "a model reads back as written" {
    var vertices = [_]Vertex{ .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 0.5, 0.2, 1 }, .metallic_roughness = .{ 0.8, 0.3 }, .emissive_color = .{ 0.1, 0.2, 0.3 } }, .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } }, .{ .position = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 } } };
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
    try std.testing.expectEqualSlices(f32, &vertices[0].color, &model.vertices[0].color);
    try std.testing.expectEqualSlices(f32, &vertices[0].metallic_roughness, &model.vertices[0].metallic_roughness);
    try std.testing.expectEqualSlices(f32, &vertices[0].emissive_color, &model.vertices[0].emissive_color);
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

fn riggedFixture() Model {
    const S = struct {
        var vertices = [_]Vertex{
            .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 } },
            .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 0, 1 } },
            .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0, 1 } },
        };
        var indices = [_]u32{ 0, 1, 2 };
        var nodes = [_]Node{ .{ .name = "root" }, .{ .name = "arm", .parent = 0 } };
        var joints = [_]u32{ 0, 1 };
        var binds = [_][4][4]f32{ rig_zig.identity, rig_zig.identity };
        var skins = [_]Skin{.{ .joints = &joints, .inverse_bind = &binds }};
        var influences = [_]Influence{ .{ .weights = .{ 1, 0, 0, 0 } }, .{ .joints = .{ 1, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } }, .{} };
        var deltas = [_]MorphDelta{.{ .vertex = 2, .position = .{ 0, 1, 0 } }};
        var targets = [_]MorphTarget{.{ .name = "tall", .deltas = &deltas }};
        var parts = [_]Part{.{ .first_index = 0, .index_count = 3, .vertex_count = 3, .node = 0, .skin = 0, .morph_count = 1 }};
        var times = [_]f32{ 0, 1 };
        var move = [_]f32{ 0, 0, 0, 0, 2, 0 };
        var weights = [_]f32{ 0, 1 };
        var tracks = [_]Track{
            .{ .channel = .translation, .target = 1, .stride = 3, .times = &times, .values = &move },
            .{ .channel = .morph_weights, .target = 0, .stride = 1, .times = &times, .values = &weights },
        };
        var clips = [_]Clip{.{ .name = "lift", .duration_s = 1, .tracks = &tracks }};
    };
    return .{ .vertices = &S.vertices, .indices = &S.indices, .parts = &S.parts, .textures = &.{}, .rig = .{ .nodes = &S.nodes, .influences = &S.influences, .skins = &S.skins, .morph_targets = &S.targets, .clips = &S.clips } };
}

test "a rigged model reads back with its nodes, skin, blend shapes and clips" {
    const model = riggedFixture();
    try std.testing.expect(model.isWhole());
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, model);
    var reader: std.Io.Reader = .fixed(bytes.written());
    var read_back = try read(std.testing.allocator, &reader);
    defer read_back.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("arm", read_back.rig.nodes[1].name);
    try std.testing.expectEqual(@as(?u32, 0), read_back.rig.nodes[1].parent);
    try std.testing.expectEqual(@as(f32, 1), read_back.rig.influences[1].weights[0]);
    try std.testing.expectEqualStrings("tall", read_back.rig.morph_targets[0].name);
    const lift = read_back.rig.clip("lift").?;
    try std.testing.expectEqual(@as(usize, 2), lift.tracks.len);
    try std.testing.expectEqual(@as(f32, 2), lift.tracks[0].values[4]);
    try std.testing.expectEqual(@as(?u32, 1), read_back.rig.node("arm"));
}

test "a rig with a broken reference, key or number is refused" {
    // Each case damages one thing a good rigged model holds, then checks it is refused.
    var model = riggedFixture();
    model.format_version = 1;
    try std.testing.expect(!model.isWhole());

    model = riggedFixture();
    model.parts[0].vertex_count = 4;
    try std.testing.expect(!model.isWhole());
    model.parts[0].vertex_count = 3;

    model.rig.skins[0].joints[1] = 9;
    try std.testing.expect(!model.isWhole());
    model.rig.skins[0].joints[1] = 1;

    model.rig.clips[0].tracks[0].times[1] = -1;
    try std.testing.expect(!model.isWhole());
    model.rig.clips[0].tracks[0].times[1] = 1;

    model.rig.clips[0].tracks[0].values[1] = std.math.nan(f32);
    try std.testing.expect(!model.isWhole());
    model.rig.clips[0].tracks[0].values[1] = 0;

    model.rig.clips[0].tracks[1].stride = 2;
    try std.testing.expect(!model.isWhole());
    model.rig.clips[0].tracks[1].stride = 1;

    model.rig.nodes[0].parent = 1;
    try std.testing.expect(!model.isWhole());
    model.rig.nodes[0].parent = null;

    model.rig.morph_targets[0].deltas[0].vertex = 7;
    try std.testing.expect(!model.isWhole());
    model.rig.morph_targets[0].deltas[0].vertex = 2;

    // Undamaged again, it is whole, so each refusal above was down to its own damage.
    try std.testing.expect(model.isWhole());
}

test "a model's box holds the poses of its clips" {
    const model = riggedFixture();
    try std.testing.expect(model.bounds().max[1] >= 2);
    try std.testing.expect(model.bounds().min[0] <= 0);
}
