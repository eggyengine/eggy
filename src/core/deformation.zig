//! Poses the models entities animate: for each `Drawable` whose `Animator` plays something, works
//! out the model's pose (its model clips, and the `model:` tracks of its authored clips, faded
//! by `blendTo`), deforms the model's corners on the CPU (bones, blend shapes, baked frames) into
//! that entity's own vertex buffer, and measures the box round them for culling.
//!
//! Each entity has one buffer per frame in flight, written by `prepare` and read by every pass of
//! that frame (colour, shadows, selection), so a draw never overwrites vertices the GPU still reads.
//! One `Deformation` belongs to one `MeshRenderer`, so each window poses what it shows itself.
const std = @import("std");
const vit = @import("vitellus");
const assets = @import("eggy_assets");
const mesh = @import("mesh.zig");
const ModelCache = @import("model_cache.zig").ModelCache;
const TextureCache = @import("texture_cache.zig").TextureCache;
const ClipCache = @import("clip_cache.zig").ClipCache;
const Animator = @import("animation.zig").Animator;
const animation = @import("animation.zig");
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const log = std.log.scoped(.animation);

const Vertex = assets.model.Vertex;

pub const Deformation = struct {
    gpa: std.mem.Allocator,
    device: vit.Device,
    /// By entity, whose buffers it owns.
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    /// Buffers replaced or dropped while the GPU may still read them, freed once it can't.
    retired: std.ArrayList(Retired) = .empty,
    /// Poses and corners being worked on, emptied by each `prepare`.
    scratch: std.heap.ArenaAllocator,
    /// How many times `prepare` has run: picks the frame slot and dates each entry's last use.
    prepared: u64 = 0,
    /// Problems already logged, so one bad clip name says so once, not every frame.
    reported: std.StringHashMapUnmanaged(void) = .empty,

    const Entry = struct {
        buffers: [frames_in_flight]?vit.Buffer = @splat(null),
        size: usize = 0,
        used_at: u64 = 0,
    };
    const Retired = struct { buffer: vit.Buffer, at: u64 };

    pub fn init(gpa: std.mem.Allocator, device: vit.Device) Deformation {
        return .{ .gpa = gpa, .device = device, .scratch = .init(gpa) };
    }

    /// Free every buffer. The GPU must be done with them.
    pub fn deinit(self: *Deformation) void {
        var entries = self.entries.valueIterator();
        while (entries.next()) |entry| for (entry.buffers) |buffer| if (buffer) |made| made.deinit();
        self.entries.deinit(self.gpa);
        for (self.retired.items) |old| old.buffer.deinit();
        self.retired.deinit(self.gpa);
        var keys = self.reported.keyIterator();
        while (keys.next()) |owned| self.gpa.free(owned.*);
        self.reported.deinit(self.gpa);
        self.scratch.deinit();
    }

    /// Pose every drawable whose `Animator` plays something on a model with a rig, and set its
    /// `deformed` flag and `bounds_*` (the exact box round the posed corners, in model space).
    /// Others are left as they are: drawn at rest, from the model's own buffer. Call outside a
    /// render pass, once per frame, after the models are loaded (`clips` may be null: authored
    /// clips then play nothing). Failures are logged once and leave that entity at rest.
    pub fn prepare(self: *Deformation, drawables: []mesh.Drawable, models: *ModelCache, textures: *TextureCache, clips: ?*ClipCache) void {
        self.prepared += 1;
        _ = self.scratch.reset(.retain_capacity);
        self.releaseUnused();
        for (drawables) |*drawable| {
            drawable.deformed = 0;
            const animator = drawable.animator orelse continue;
            if (drawable.material_failed or !plays(animator.*)) continue;
            const path = drawable.modelFile() orelse continue;
            const gpu = models.get(path, textures) orelse continue;
            const model = gpu.rig orelse {
                self.reportOnce(path, "{s} has no nodes, blend shapes or clips to animate", .{path});
                continue;
            };
            self.pose(drawable, model, path, animator.*, clips) catch |err| {
                self.reportOnce(path, "cannot animate {s}: {t}", .{ path, err });
            };
        }
    }

    /// This frame's buffer index; the modulo is below `frames_in_flight`, so it fits `usize` on 32-bit targets.
    fn bufferSlot(self: *const Deformation) usize {
        return @intCast(self.prepared % frames_in_flight);
    }

    /// The vertex buffer holding `drawable`'s posed corners for this frame; null when it is
    /// drawn at rest (`deformed` is 0, or posing it failed).
    pub fn vertices(self: *const Deformation, drawable: mesh.Drawable) ?vit.Buffer {
        if (drawable.deformed == 0) return null;
        const entry = self.entries.get(key(drawable)) orelse return null;
        return entry.buffers[self.bufferSlot()];
    }

    fn pose(self: *Deformation, drawable: *mesh.Drawable, model: *const assets.Model, path: []const u8, animator: Animator, clips: ?*ClipCache) !void {
        const arena = self.scratch.allocator();
        var current = try assets.rig.Pose.init(arena, model.*);
        var deformer = try assets.rig.Deformer.init(arena, model.*);

        // A fade starts from the previous clips, then eases to the current ones.
        const fading = animator.isBlending();
        const weight = animator.blendWeight();
        if (fading) {
            self.layer(&current, model, path, clips, animator.previous_model_clip.key(), animator.previous_clip.key(), animator.previous_time_s, animator.repeat, 1);
        }
        self.layer(&current, model, path, clips, animator.model_clip.key(), animator.clip.key(), animator.time_s, animator.repeat, if (fading) weight else 1);

        // Every part's corners as the pose places them, and the box round them.
        const corners = try arena.alloc(Vertex, model.vertices.len);
        @memcpy(corners, model.vertices);
        deformer.place(model.*, current);
        for (model.parts, 0..) |part, index| deformer.part(model.*, current, index, corners[part.first_vertex..][0..part.vertex_count]);
        var box = assets.Bounds{ .min = @splat(std.math.inf(f32)), .max = @splat(-std.math.inf(f32)) };
        for (corners) |corner| box.include(corner.position);
        if (corners.len == 0) return error.NothingToPose;

        try self.store(drawable.*, std.mem.sliceAsBytes(corners));
        drawable.deformed = 1;
        drawable.bounds_min = box.min;
        drawable.bounds_max = box.max;
    }

    /// Lay one imported clip and one authored clip over `pose`, `weight` of the way. `path` is
    /// the model's key, the hex of its id, which an imported clip must have been made for.
    fn layer(self: *Deformation, pose_: *assets.rig.Pose, model: *const assets.Model, path: []const u8, clips: ?*ClipCache, imported: []const u8, authored: []const u8, time_s: f32, repeat: animation.Repeat, weight: f32) void {
        if (imported.len > 0) if (clips) |cache| {
            const model_id = assets.id.parse(path) catch 0;
            if (cache.importedFor(imported, model_id, model.*)) |found| {
                pose_.apply(model.*, found.*, animation.clipTime(time_s, found.duration_s, repeat), weight);
            }
        };
        if (authored.len == 0) return;
        const clip = (clips orelse return).authored(authored) orelse return;
        const at = animation.clipTime(time_s, clip.duration_s, repeat);
        for (clip.tracks) |track| {
            const target = switch (track.where()) {
                .model => |name| name,
                .entity => continue,
            };
            const value = track.valueAt(at) orelse continue;
            if (track.property == .morph_weight) {
                const target_at = for (model.rig.morph_targets, 0..) |blend_shape, i| {
                    if (std.mem.eql(u8, blend_shape.name, target)) break i;
                } else {
                    self.reportOnce(target, "{s} has no blend shape named {s}", .{ path, target });
                    continue;
                };
                pose_.blendMorph(target_at, value[0], weight);
                continue;
            }
            const node = model.rig.node(target) orelse {
                self.reportOnce(target, "{s} has no node named {s}", .{ path, target });
                continue;
            };
            switch (track.property) {
                .position => pose_.blendTranslation(node, value, weight),
                .rotation_deg => pose_.blendRotation(node, eulerQuaternion(value), weight),
                .scale => pose_.blendScale(node, value, weight),
                .morph_weight => unreachable,
            }
        }
    }

    /// Write `bytes` into the entity's buffer for this frame's slot, making the buffers first.
    fn store(self: *Deformation, drawable: mesh.Drawable, bytes: []const u8) !void {
        const found = try self.entries.getOrPut(self.gpa, key(drawable));
        if (!found.found_existing) found.value_ptr.* = .{};
        const entry = found.value_ptr;
        errdefer if (!found.found_existing) {
            _ = self.entries.remove(key(drawable));
        };

        // A model that changed size (reloaded) gets new buffers; the old ones may still be in use.
        if (entry.size != bytes.len) {
            for (&entry.buffers) |*buffer| if (buffer.*) |old| {
                try self.retired.append(self.gpa, .{ .buffer = old, .at = self.prepared });
                buffer.* = null;
            };
            entry.size = bytes.len;
        }
        const slot = self.bufferSlot();
        const buffer = entry.buffers[slot] orelse made: {
            const created = try vit.Buffer.init(self.device, .{ .label = "animated vertices", .size = bytes.len, .usage = .{ .vertex = true }, .memory = .upload });
            entry.buffers[slot] = created;
            break :made created;
        };
        const mapped = try buffer.map(.write, .{ .size = bytes.len });
        @memcpy(mapped[0..bytes.len], bytes);
        buffer.unmap(.{ .size = bytes.len });
        entry.used_at = self.prepared;
    }

    /// Free the buffers of entities that haven't been posed for as long as a frame stays in flight.
    fn releaseUnused(self: *Deformation) void {
        var at: usize = 0;
        while (at < self.retired.items.len) {
            if (self.prepared - self.retired.items[at].at > frames_in_flight) {
                self.retired.swapRemove(at).buffer.deinit();
            } else at += 1;
        }
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.gpa);
        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            if (self.prepared - entry.value_ptr.used_at <= frames_in_flight) continue;
            stale.append(self.gpa, entry.key_ptr.*) catch return;
        }
        for (stale.items) |gone| if (self.entries.fetchRemove(gone)) |removed| {
            for (removed.value.buffers) |buffer| if (buffer) |made| made.deinit();
        };
    }

    fn reportOnce(self: *Deformation, what: []const u8, comptime format: []const u8, args: anytype) void {
        if (self.reported.contains(what)) return;
        const owned = self.gpa.dupe(u8, what) catch return;
        self.reported.put(self.gpa, owned, {}) catch {
            self.gpa.free(owned);
            return;
        };
        log.warn(format, args);
    }
};

/// Whether `animator` asks for anything that moves a model.
fn plays(animator: Animator) bool {
    return animator.clip.len > 0 or animator.model_clip.len > 0 or animator.previous_clip.len > 0 or animator.previous_model_clip.len > 0;
}

fn key(drawable: mesh.Drawable) u64 {
    return @as(u64, drawable.entity_generation) << 32 | drawable.entity_id;
}

/// The quaternion (x, y, z, w) of a rotation in degrees about x, then y, then z, as `Transform`
/// turns.
pub fn eulerQuaternion(degrees: [3]f32) [4]f32 {
    const half = std.math.rad_per_deg * 0.5;
    const x = [4]f32{ @sin(degrees[0] * half), 0, 0, @cos(degrees[0] * half) };
    const y = [4]f32{ 0, @sin(degrees[1] * half), 0, @cos(degrees[1] * half) };
    const z = [4]f32{ 0, 0, @sin(degrees[2] * half), @cos(degrees[2] * half) };
    return multiply(z, multiply(y, x));
}

fn multiply(a: [4]f32, b: [4]f32) [4]f32 {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

test "a quaternion from degrees turns as a Transform does" {
    const transform = @import("transform.zig").Transform{ .position = .{ 1, 2, 3 }, .rotation_deg = .{ 30, 45, 60 }, .scale = .{ 2, 3, 4 } };
    const expected = transform.matrix().data;
    const made = assets.rig.fromTrs(transform.position, eulerQuaternion(transform.rotation_deg), transform.scale);
    for (expected, made) |column, mine| {
        const wanted: [4]f32 = column;
        for (wanted, mine) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-4);
    }
}
