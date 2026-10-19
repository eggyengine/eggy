//! Playing a model's rig: sampling a clip's tracks into a `Pose`, placing the nodes, and
//! deforming a part's corners by its skin, blend shapes, baked frames and node. Pure maths on
//! `Model`s, so the importer's tests, the runtime and the editor all move a model the same way.
const std = @import("std");
const model_zig = @import("model.zig");
const Bounds = @import("bounds.zig").Bounds;
const Model = model_zig.Model;
const Vertex = model_zig.Vertex;
const Track = model_zig.Track;
const Clip = model_zig.Clip;

/// A 4 by 4 matrix as four columns, like the rest of Eggy's.
pub const Mat = [4][4]f32;

pub const identity: Mat = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };

/// `a` applied after `b`.
pub fn mul(a: Mat, b: Mat) Mat {
    var out: Mat = undefined;
    for (&out, b) |*column, from| {
        var sum: @Vector(4, f32) = @splat(0);
        for (0..4) |row| sum += @as(@Vector(4, f32), a[row]) * @as(@Vector(4, f32), @splat(from[row]));
        column.* = sum;
    }
    return out;
}

/// The matrix scaling by `scale`, turning by the unit quaternion `rotation` (x, y, z, w), then
/// moving by `translation`.
pub fn fromTrs(translation: [3]f32, rotation: [4]f32, scale: [3]f32) Mat {
    const x, const y, const z, const w = rotation;
    const xx = x * x;
    const yy = y * y;
    const zz = z * z;
    return .{
        .{ (1 - 2 * (yy + zz)) * scale[0], (2 * (x * y + z * w)) * scale[0], (2 * (x * z - y * w)) * scale[0], 0 },
        .{ (2 * (x * y - z * w)) * scale[1], (1 - 2 * (xx + zz)) * scale[1], (2 * (y * z + x * w)) * scale[1], 0 },
        .{ (2 * (x * z + y * w)) * scale[2], (2 * (y * z - x * w)) * scale[2], (1 - 2 * (xx + yy)) * scale[2], 0 },
        .{ translation[0], translation[1], translation[2], 1 },
    };
}

fn transformPoint(m: Mat, p: [3]f32) [3]f32 {
    var out: @Vector(4, f32) = m[3];
    for (0..3) |axis| out += @as(@Vector(4, f32), m[axis]) * @as(@Vector(4, f32), @splat(p[axis]));
    return .{ out[0], out[1], out[2] };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// The matrix carrying surface normals along with `m` (its inverse transpose, kept the right
/// way round through a mirror), as columns; its results still need normalizing.
fn normalMatrix(m: Mat) [3][3]f32 {
    const c0 = [3]f32{ m[0][0], m[0][1], m[0][2] };
    const c1 = [3]f32{ m[1][0], m[1][1], m[1][2] };
    const c2 = [3]f32{ m[2][0], m[2][1], m[2][2] };
    const flip: f32 = if (dot(c0, cross(c1, c2)) < 0) -1 else 1;
    const a = cross(c1, c2);
    const b = cross(c2, c0);
    const c = cross(c0, c1);
    return .{
        .{ a[0] * flip, a[1] * flip, a[2] * flip },
        .{ b[0] * flip, b[1] * flip, b[2] * flip },
        .{ c[0] * flip, c[1] * flip, c[2] * flip },
    };
}

fn transformNormal(m: [3][3]f32, n: [3]f32) [3]f32 {
    return .{
        m[0][0] * n[0] + m[1][0] * n[1] + m[2][0] * n[2],
        m[0][1] * n[0] + m[1][1] * n[1] + m[2][1] * n[2],
        m[0][2] * n[0] + m[1][2] * n[1] + m[2][2] * n[2],
    };
}

fn normalized(v: [3]f32, fallback: [3]f32) [3]f32 {
    const length = @sqrt(dot(v, v));
    if (!(length > 1e-12)) return fallback;
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerp3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{ lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t) };
}

fn normalizedQuaternion(q: [4]f32) [4]f32 {
    const length = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (!(length > 1e-12)) return .{ 0, 0, 0, 1 };
    return .{ q[0] / length, q[1] / length, q[2] / length, q[3] / length };
}

/// The quaternion `t` of the way from `a` to `b` along the shorter arc.
pub fn slerp(a: [4]f32, b_in: [4]f32, t: f32) [4]f32 {
    var b = b_in;
    var cosine = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    if (cosine < 0) {
        cosine = -cosine;
        b = .{ -b[0], -b[1], -b[2], -b[3] };
    }
    // Nearly the same turn: a straight blend is as good and avoids dividing by ~0.
    if (cosine > 0.9995) {
        var out: [4]f32 = undefined;
        for (&out, a, b) |*value, from, to| value.* = lerp(from, to, t);
        return normalizedQuaternion(out);
    }
    const angle = std.math.acos(cosine);
    const sine = @sin(angle);
    const wa = @sin((1 - t) * angle) / sine;
    const wb = @sin(t * angle) / sine;
    return .{ a[0] * wa + b[0] * wb, a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb };
}

/// Which two keys of `track` bracket `time_s`, and how far between them (0 at the first). Times
/// before the first key or after the last hold those keys; a step track stays on the first of a
/// pair until the second begins. `track.times` must not be empty.
pub fn bracket(track: Track, time_s: f32) struct { from: usize, to: usize, t: f32 } {
    const times = track.times;
    if (time_s <= times[0]) return .{ .from = 0, .to = 0, .t = 0 };
    const last = times.len - 1;
    if (time_s >= times[last]) return .{ .from = last, .to = last, .t = 0 };
    // The first key later than `time_s`; the one before it is the earlier of the pair.
    var low: usize = 0;
    var high: usize = last;
    while (high - low > 1) {
        const middle = (low + high) / 2;
        if (times[middle] <= time_s) low = middle else high = middle;
    }
    const span = times[high] - times[low];
    const t: f32 = if (track.interpolation == .step or span <= 0) 0 else (time_s - times[low]) / span;
    return .{ .from = low, .to = high, .t = t };
}

/// Write the value of `track` at `time_s` into `out` (`track.stride` long): linear, spherical
/// for rotations, or held for a step track. Allocates nothing; the track must be whole.
///
/// ```zig
/// var value: [3]f32 = undefined;
/// sample(track, 0.5, &value);
/// ```
pub fn sample(track: Track, time_s: f32, out: []f32) void {
    const found = bracket(track, time_s);
    const from = track.values[found.from * track.stride ..][0..track.stride];
    const to = track.values[found.to * track.stride ..][0..track.stride];
    if (track.channel == .rotation) {
        const turned = slerp(from[0..4].*, to[0..4].*, found.t);
        out[0..4].* = turned;
        return;
    }
    for (out, from, to) |*value, a, b| value.* = lerp(a, b, found.t);
}

/// `time_s` brought into a clip of `duration_s`: repeating when `repeat`, else held at the ends.
/// A clip of no length always sits at 0.
pub fn wrapTime(time_s: f32, duration_s: f32, repeat: bool) f32 {
    if (!(duration_s > 0)) return 0;
    if (!repeat) return std.math.clamp(time_s, 0, duration_s);
    const wrapped = @mod(time_s, duration_s);
    return if (wrapped < 0) wrapped + duration_s else wrapped;
}

/// One baked frame of a part: a vertex-cache track read at a time.
pub const CacheSample = struct { track: *const Track, time_s: f32 };

/// How a part's corners come from its baked frames: the `from` sample (null: the rest corners)
/// eased towards `to` by `mix`.
pub const CacheBlend = struct {
    from: ?CacheSample = null,
    to: ?CacheSample = null,
    mix: f32 = 0,
};

/// A moment of a rig: every node's local transform, every blend shape's weight, and which baked
/// frames each part shows. Starts at the model's rest pose; `apply` layers clips over it.
pub const Pose = struct {
    translation: [][3]f32,
    rotation: [][4]f32,
    scale: [][3]f32,
    morph_weights: []f32,
    cache: []CacheBlend,

    /// A pose of `model` at rest. Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, model: Model) !Pose {
        const rig = model.rig;
        const translation = try gpa.alloc([3]f32, rig.nodes.len);
        errdefer gpa.free(translation);
        const rotation = try gpa.alloc([4]f32, rig.nodes.len);
        errdefer gpa.free(rotation);
        const scale = try gpa.alloc([3]f32, rig.nodes.len);
        errdefer gpa.free(scale);
        const morph_weights = try gpa.alloc(f32, rig.morph_targets.len);
        errdefer gpa.free(morph_weights);
        const cache = try gpa.alloc(CacheBlend, model.parts.len);
        var pose = Pose{ .translation = translation, .rotation = rotation, .scale = scale, .morph_weights = morph_weights, .cache = cache };
        pose.reset(model);
        return pose;
    }

    pub fn deinit(self: *Pose, gpa: std.mem.Allocator) void {
        gpa.free(self.translation);
        gpa.free(self.rotation);
        gpa.free(self.scale);
        gpa.free(self.morph_weights);
        gpa.free(self.cache);
    }

    /// Back to `model`'s rest pose. `model` must be the one this pose was made for.
    pub fn reset(self: *Pose, model: Model) void {
        for (model.rig.nodes, self.translation, self.rotation, self.scale) |node, *t, *r, *s| {
            t.* = node.translation;
            r.* = node.rotation;
            s.* = node.scale;
        }
        for (model.rig.morph_targets, self.morph_weights) |target, *weight| weight.* = target.default_weight;
        @memset(self.cache, .{});
    }

    /// Ease node `node`'s translation `weight` (0 to 1) of the way to `value`.
    pub fn blendTranslation(self: *Pose, node: usize, value: [3]f32, weight: f32) void {
        self.translation[node] = lerp3(self.translation[node], value, weight);
    }

    pub fn blendRotation(self: *Pose, node: usize, value: [4]f32, weight: f32) void {
        self.rotation[node] = slerp(self.rotation[node], normalizedQuaternion(value), weight);
    }

    pub fn blendScale(self: *Pose, node: usize, value: [3]f32, weight: f32) void {
        self.scale[node] = lerp3(self.scale[node], value, weight);
    }

    pub fn blendMorph(self: *Pose, target: usize, value: f32, weight: f32) void {
        self.morph_weights[target] = lerp(self.morph_weights[target], value, weight);
    }

    /// Layer `clip` at `time_s` over the pose, `weight` (0 to 1) of the way: 1 replaces what
    /// the tracks move, less eases it from what is already there. Tracks the clip doesn't have
    /// keep their values. `time_s` must already be inside the clip (see `wrapTime`).
    pub fn apply(self: *Pose, model: Model, clip: Clip, time_s: f32, weight: f32) void {
        var buffer: [4]f32 = undefined;
        for (clip.tracks) |*track| {
            switch (track.channel) {
                .translation => {
                    sample(track.*, time_s, buffer[0..3]);
                    self.blendTranslation(track.target, buffer[0..3].*, weight);
                },
                .rotation => {
                    sample(track.*, time_s, buffer[0..4]);
                    self.blendRotation(track.target, buffer, weight);
                },
                .scale => {
                    sample(track.*, time_s, buffer[0..3]);
                    self.blendScale(track.target, buffer[0..3].*, weight);
                },
                .morph_weights => for (model.parts) |part| {
                    if (part.node != track.target or part.morph_count == 0) continue;
                    const key = bracket(track.*, time_s);
                    for (0..part.morph_count) |at| {
                        const from = track.values[key.from * track.stride + at];
                        const to = track.values[key.to * track.stride + at];
                        self.blendMorph(part.morph_first + at, lerp(from, to, key.t), weight);
                    }
                },
                .vertex_cache => {
                    const blend = &self.cache[track.target];
                    const frame = CacheSample{ .track = track, .time_s = time_s };
                    if (blend.from == null and blend.to == null and weight >= 1) {
                        blend.from = frame;
                    } else if (blend.to == null) {
                        blend.to = frame;
                        blend.mix = weight;
                    }
                },
            }
        }
    }
};

/// Places a model's nodes and deforms its parts, reusing its scratch space between calls.
pub const Deformer = struct {
    world: []Mat,
    joint: []Mat,
    joint_normal: [][3][3]f32,

    pub fn init(gpa: std.mem.Allocator, model: Model) !Deformer {
        var most_joints: usize = 0;
        for (model.rig.skins) |skin| most_joints = @max(most_joints, skin.joints.len);
        const world = try gpa.alloc(Mat, model.rig.nodes.len);
        errdefer gpa.free(world);
        const joint = try gpa.alloc(Mat, most_joints);
        errdefer gpa.free(joint);
        const joint_normal = try gpa.alloc([3][3]f32, most_joints);
        return .{ .world = world, .joint = joint, .joint_normal = joint_normal };
    }

    pub fn deinit(self: *Deformer, gpa: std.mem.Allocator) void {
        gpa.free(self.world);
        gpa.free(self.joint);
        gpa.free(self.joint_normal);
    }

    /// Work out every node's matrix in the model's space from `pose`. Parents come first.
    pub fn place(self: *Deformer, model: Model, pose: Pose) void {
        for (model.rig.nodes, 0..) |node, at| {
            const local = fromTrs(pose.translation[at], pose.rotation[at], pose.scale[at]);
            self.world[at] = if (node.parent) |parent| mul(self.world[parent], local) else local;
        }
    }

    /// Write part `index`'s corners as `pose` puts them into `out` (`part.vertex_count` long):
    /// baked frames, then blend shapes, then its skin (or its node's matrix). `place` must have
    /// run for this pose.
    pub fn part(self: *Deformer, model: Model, pose: Pose, index: usize, out: []Vertex) void {
        const part_info = model.parts[index];
        const source = model.vertices[part_info.first_vertex..][0..part_info.vertex_count];
        @memcpy(out, source);
        applyCache(pose.cache[index], out);
        applyMorph(model, pose, part_info, out);
        if (part_info.skin) |skin_at| {
            const skin = model.rig.skins[skin_at];
            for (skin.joints, skin.inverse_bind, self.joint[0..skin.joints.len], self.joint_normal[0..skin.joints.len]) |joint, bind, *matrix, *normal| {
                matrix.* = mul(self.world[joint], bind);
                normal.* = normalMatrix(matrix.*);
            }
            const influences = model.rig.influences[part_info.first_vertex..][0..part_info.vertex_count];
            for (out, influences) |*vertex, influence| self.skinVertex(vertex, influence);
        } else if (part_info.node) |node| {
            const matrix = self.world[node];
            const normal = normalMatrix(matrix);
            for (out) |*vertex| {
                vertex.position = transformPoint(matrix, vertex.position);
                vertex.normal = normalized(transformNormal(normal, vertex.normal), vertex.normal);
            }
        }
    }

    fn skinVertex(self: *const Deformer, vertex: *Vertex, influence: model_zig.Influence) void {
        var position: [3]f32 = @splat(0);
        var normal: [3]f32 = @splat(0);
        var total: f32 = 0;
        for (influence.joints, influence.weights) |joint, weight| {
            if (weight <= 0) continue;
            total += weight;
            const moved = transformPoint(self.joint[joint], vertex.position);
            const turned = transformNormal(self.joint_normal[joint], vertex.normal);
            for (0..3) |axis| {
                position[axis] += moved[axis] * weight;
                normal[axis] += turned[axis] * weight;
            }
        }
        // A corner no joint pulls stays where it is.
        if (!(total > 1e-6)) return;
        vertex.position = position;
        vertex.normal = normalized(normal, vertex.normal);
    }
};

fn cachedPosition(sample_at: CacheSample, corner: usize) [3]f32 {
    const track = sample_at.track.*;
    const key = bracket(track, sample_at.time_s);
    const from = track.values[key.from * track.stride + corner * 3 ..][0..3];
    const to = track.values[key.to * track.stride + corner * 3 ..][0..3];
    return lerp3(from[0..3].*, to[0..3].*, key.t);
}

fn applyCache(blend: CacheBlend, out: []Vertex) void {
    if (blend.from == null and blend.to == null) return;
    for (out, 0..) |*vertex, corner| {
        const from = if (blend.from) |frame| cachedPosition(frame, corner) else vertex.position;
        vertex.position = if (blend.to) |frame| lerp3(from, cachedPosition(frame, corner), blend.mix) else from;
    }
}

fn applyMorph(model: Model, pose: Pose, part: model_zig.Part, out: []Vertex) void {
    for (0..part.morph_count) |at| {
        const weight = pose.morph_weights[part.morph_first + at];
        if (weight == 0) continue;
        for (model.rig.morph_targets[part.morph_first + at].deltas) |delta| {
            const vertex = &out[delta.vertex - part.first_vertex];
            for (0..3) |axis| {
                vertex.position[axis] += delta.position[axis] * weight;
                vertex.normal[axis] += delta.normal[axis] * weight;
            }
        }
    }
    if (part.morph_count == 0) return;
    for (out) |*vertex| vertex.normal = normalized(vertex.normal, .{ 0, 1, 0 });
}

/// The corners of every part of `model` as its rest pose places them, in new memory from `gpa`:
/// what to draw when nothing is playing. A static model's are its own.
pub fn restVertices(gpa: std.mem.Allocator, model: Model) ![]Vertex {
    const out = try gpa.dupe(Vertex, model.vertices);
    errdefer gpa.free(out);
    if (!model.isRigged()) return out;
    var pose = try Pose.init(gpa, model);
    defer pose.deinit(gpa);
    var deformer = try Deformer.init(gpa, model);
    defer deformer.deinit(gpa);
    deformer.place(model, pose);
    for (model.parts, 0..) |part, index| deformer.part(model, pose, index, out[part.first_vertex..][0..part.vertex_count]);
    return out;
}

/// The most poses of one clip `animatedBounds` looks at; a clip with more keys is sampled evenly.
const sampled_poses_per_clip = 64;

/// A box holding the model in every pose its clips reach: its rest corners, the corners at each
/// key time (or evenly spaced times for a long clip, and halfway between), every baked frame,
/// and room for its blend shapes at the largest weight a clip or default gives. Culling by it
/// never hides a moving part. Costs a few poses of the whole model; out of memory gives the
/// plain box of the stored corners.
pub fn animatedBounds(model: Model) Bounds {
    var box = Bounds{ .min = @splat(std.math.inf(f32)), .max = @splat(-std.math.inf(f32)) };
    for (model.vertices) |vertex| box.include(vertex.position);
    if (model.vertices.len == 0) return .{ .min = @splat(0), .max = @splat(0) };
    const gpa = std.heap.page_allocator;
    posedBounds(gpa, model, &box) catch return box;
    return box;
}

fn posedBounds(gpa: std.mem.Allocator, model: Model, box: *Bounds) !void {
    var pose = try Pose.init(gpa, model);
    defer pose.deinit(gpa);
    var deformer = try Deformer.init(gpa, model);
    defer deformer.deinit(gpa);
    const scratch = try gpa.alloc(Vertex, model.vertices.len);
    defer gpa.free(scratch);

    includePose(model, &pose, &deformer, scratch, box);
    var largest_weight: f32 = 1;
    for (model.rig.morph_targets) |target| largest_weight = @max(largest_weight, @abs(target.default_weight));
    for (model.rig.clips) |clip| {
        for (clip.tracks) |track| {
            switch (track.channel) {
                .vertex_cache => for (0..track.times.len) |key| {
                    var corner: usize = 0;
                    while (corner < track.stride) : (corner += 3) box.include(track.values[key * track.stride + corner ..][0..3].*);
                },
                .morph_weights => for (track.values) |value| {
                    largest_weight = @max(largest_weight, @abs(value));
                },
                else => {},
            }
        }
        const poses: usize = sampled_poses_per_clip;
        for (0..poses + 1) |step| {
            const time_s = clip.duration_s * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(poses));
            pose.reset(model);
            pose.apply(model, clip, time_s, 1);
            includePose(model, &pose, &deformer, scratch, box);
        }
        // Each key's own pose, for sharp moves between the evenly spaced ones.
        for (clip.tracks) |track| {
            const keys = @min(track.times.len, sampled_poses_per_clip);
            for (0..keys) |step| {
                const key = step * track.times.len / keys;
                pose.reset(model);
                pose.apply(model, clip, track.times[key], 1);
                includePose(model, &pose, &deformer, scratch, box);
            }
        }
    }

    // Blend shapes add their deltas at the weight posed above (at most 1); room for more.
    if (largest_weight > 1) {
        var spread: [3]f32 = @splat(0);
        for (model.rig.morph_targets) |target| for (target.deltas) |delta| for (0..3) |axis| {
            spread[axis] = @max(spread[axis], @abs(delta.position[axis]));
        };
        for (0..3) |axis| {
            box.min[axis] -= spread[axis] * (largest_weight - 1);
            box.max[axis] += spread[axis] * (largest_weight - 1);
        }
    }
}

fn includePose(model: Model, pose: *Pose, deformer: *Deformer, scratch: []Vertex, box: *Bounds) void {
    deformer.place(model, pose.*);
    for (model.parts, 0..) |part, index| {
        const out = scratch[part.first_vertex..][0..part.vertex_count];
        deformer.part(model, pose.*, index, out);
        for (out) |vertex| box.include(vertex.position);
    }
}

fn testTriangle() struct { vertices: [3]Vertex, indices: [3]u32 } {
    return .{
        .vertices = .{
            .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 } },
            .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 0, 1 } },
            .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0, 1 } },
        },
        .indices = .{ 0, 1, 2 },
    };
}

test "a track samples linearly, slerps rotations and holds step keys" {
    var times = [_]f32{ 0, 1, 2 };
    var values = [_]f32{ 0, 0, 0, 10, 0, 0, 10, 20, 0 };
    var track = Track{ .channel = .translation, .target = 0, .stride = 3, .times = &times, .values = &values };
    var out: [3]f32 = undefined;
    sample(track, 0.5, &out);
    try std.testing.expectEqualSlices(f32, &.{ 5, 0, 0 }, &out);
    sample(track, 1.5, &out);
    try std.testing.expectEqualSlices(f32, &.{ 10, 10, 0 }, &out);
    sample(track, 9, &out);
    try std.testing.expectEqualSlices(f32, &.{ 10, 20, 0 }, &out);
    sample(track, -3, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, &out);
    track.interpolation = .step;
    sample(track, 0.99, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, &out);

    // Half of a quarter turn about z is an eighth of one, whichever way the arc is stored.
    const half = @sin(std.math.pi / 8.0);
    var turn_times = [_]f32{ 0, 1 };
    var turn_values = [_]f32{ 0, 0, 0, 1, 0, 0, @sin(std.math.pi / 4.0), @cos(std.math.pi / 4.0) };
    const turn = Track{ .channel = .rotation, .target = 0, .stride = 4, .times = &turn_times, .values = &turn_values };
    var quaternion: [4]f32 = undefined;
    sample(turn, 0.5, &quaternion);
    try std.testing.expectApproxEqAbs(half, quaternion[2], 1e-5);
}

test "time wraps when repeating and holds at the ends otherwise" {
    try std.testing.expectEqual(@as(f32, 0.5), wrapTime(2.5, 1, true));
    try std.testing.expectEqual(@as(f32, 0.75), wrapTime(-0.25, 1, true));
    try std.testing.expectEqual(@as(f32, 1), wrapTime(2.5, 1, false));
    try std.testing.expectEqual(@as(f32, 0), wrapTime(7, 0, true));
}

test "a skinned strip bends with its joint and stays put under a weightless corner" {
    const gpa = std.testing.allocator;
    const tri = testTriangle();
    var vertices = tri.vertices;
    var indices = tri.indices;
    var nodes = [_]model_zig.Node{
        .{ .name = "root" },
        .{ .name = "arm", .parent = 0 },
    };
    var joints = [_]u32{ 0, 1 };
    var binds = [_]Mat{ identity, identity };
    var skins = [_]model_zig.Skin{.{ .joints = &joints, .inverse_bind = &binds }};
    // Corner 0 follows the root, 1 the arm, 2 no joint at all.
    var influences = [_]model_zig.Influence{
        .{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } },
        .{ .joints = .{ 1, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } },
        .{},
    };
    var parts = [_]model_zig.Part{.{ .first_index = 0, .index_count = 3, .vertex_count = 3, .node = 0, .skin = 0 }};
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{ 0, 0, 0, 0, 4, 0 };
    var tracks = [_]Track{.{ .channel = .translation, .target = 1, .stride = 3, .times = &times, .values = &values }};
    var clips = [_]Clip{.{ .name = "lift", .duration_s = 1, .tracks = &tracks }};
    const model = Model{ .vertices = &vertices, .indices = &indices, .parts = &parts, .textures = &.{}, .rig = .{ .nodes = &nodes, .influences = &influences, .skins = &skins, .clips = &clips } };
    try std.testing.expect(model.isWhole());

    var pose = try Pose.init(gpa, model);
    defer pose.deinit(gpa);
    var deformer = try Deformer.init(gpa, model);
    defer deformer.deinit(gpa);
    var out: [3]Vertex = undefined;

    deformer.place(model, pose);
    deformer.part(model, pose, 0, &out);
    try std.testing.expectEqual(@as(f32, 1), out[1].position[0]);
    try std.testing.expectEqual(@as(f32, 0), out[1].position[1]);

    pose.apply(model, clips[0], 0.5, 1);
    deformer.place(model, pose);
    deformer.part(model, pose, 0, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, &out[0].position);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 0 }, &out[1].position);
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 0 }, &out[2].position);

    // The model's box holds the lifted pose, not only the rest one.
    try std.testing.expect(model.bounds().max[1] >= 4);
}

test "a blend shape moves its corners by its weight, and a node places an unskinned part" {
    const gpa = std.testing.allocator;
    const tri = testTriangle();
    var vertices = tri.vertices;
    var indices = tri.indices;
    var nodes = [_]model_zig.Node{.{ .name = "mesh", .translation = .{ 0, 0, 5 } }};
    var deltas = [_]model_zig.MorphDelta{.{ .vertex = 1, .position = .{ 0, 2, 0 } }};
    var targets = [_]model_zig.MorphTarget{.{ .name = "grin", .deltas = &deltas }};
    var parts = [_]model_zig.Part{.{ .first_index = 0, .index_count = 3, .vertex_count = 3, .node = 0, .morph_count = 1 }};
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{ 0, 1 };
    var tracks = [_]Track{.{ .channel = .morph_weights, .target = 0, .stride = 1, .times = &times, .values = &values }};
    var clips = [_]Clip{.{ .name = "grin", .duration_s = 1, .tracks = &tracks }};
    const model = Model{ .vertices = &vertices, .indices = &indices, .parts = &parts, .textures = &.{}, .rig = .{ .nodes = &nodes, .morph_targets = &targets, .clips = &clips } };
    try std.testing.expect(model.isWhole());

    const rest = try restVertices(gpa, model);
    defer gpa.free(rest);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0, 5 }, &rest[1].position);

    var pose = try Pose.init(gpa, model);
    defer pose.deinit(gpa);
    var deformer = try Deformer.init(gpa, model);
    defer deformer.deinit(gpa);
    deformer.place(model, pose);
    pose.apply(model, clips[0], 0.5, 1);
    var out: [3]Vertex = undefined;
    deformer.part(model, pose, 0, &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 5 }, &out[1].position);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 5 }, &out[0].position);
}

test "baked frames replace the corners and ease into the next" {
    const gpa = std.testing.allocator;
    const tri = testTriangle();
    var vertices = tri.vertices;
    var indices = tri.indices;
    var nodes = [_]model_zig.Node{.{ .name = "mesh" }};
    var parts = [_]model_zig.Part{.{ .first_index = 0, .index_count = 3, .vertex_count = 3, .node = 0 }};
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{
        0, 0, 0, 1, 0, 0, 0, 1, 0,
        0, 0, 2, 1, 0, 2, 0, 1, 2,
    };
    var tracks = [_]Track{.{ .channel = .vertex_cache, .target = 0, .stride = 9, .times = &times, .values = &values }};
    var clips = [_]Clip{.{ .name = "rise", .duration_s = 1, .tracks = &tracks }};
    const model = Model{ .vertices = &vertices, .indices = &indices, .parts = &parts, .textures = &.{}, .rig = .{ .nodes = &nodes, .clips = &clips } };
    try std.testing.expect(model.isWhole());

    var pose = try Pose.init(gpa, model);
    defer pose.deinit(gpa);
    var deformer = try Deformer.init(gpa, model);
    defer deformer.deinit(gpa);
    pose.apply(model, clips[0], 0.25, 1);
    deformer.place(model, pose);
    var out: [3]Vertex = undefined;
    deformer.part(model, pose, 0, &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0, 0.5 }, &out[1].position);
    // Every baked frame lies inside the model's box.
    try std.testing.expect(model.bounds().max[2] >= 2);
}
