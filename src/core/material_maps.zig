//! The bind groups holding a surface's maps (normal, metallic-roughness, emissive, occlusion)
//! for the meshes' set 2, one per combination drawn, made the first time it is.
const std = @import("std");
const vit = @import("vitellus");

/// A map's texture and the view the group samples; the texture is what identifies it.
pub const Map = struct { texture: vit.Texture, view: vit.TextureView };

/// Which maps a surface has, in `assets.model.Maps`' order; null stands in a neutral one.
pub const Set = [4]?Map;

/// What the shader learns from a group besides its maps.
const Params = extern struct {
    /// x: 1 when it has a normal map, y: an imported part's alpha cutoff.
    flags: [4]f32,
};

// ponytail: a linear list, fine for the handful of surfaces a scene has; hash it if scenes
// reach hundreds.
const Entry = struct { set: Set, cutoff: f32, params: vit.Buffer, group: vit.BindGroup };

pub const MaterialMaps = struct {
    gpa: std.mem.Allocator,
    device: vit.Device,
    layout: vit.BindGroupLayout,
    sampler: vit.Sampler,
    /// What a missing map samples: `normal` faces straight out, `white` leaves the rest as the
    /// surface's own numbers say.
    neutral_normal: vit.TextureView,
    white: vit.TextureView,
    entries: std.ArrayList(Entry) = .empty,

    /// Borrows `sampler` and the two neutral views, which must outlive it.
    pub fn init(gpa: std.mem.Allocator, device: vit.Device, sampler: vit.Sampler, neutral_normal: vit.TextureView, white: vit.TextureView) !MaterialMaps {
        const fragment: vit.hal.binding.ShaderVisibility = .{ .fragment = true };
        const layout = try vit.BindGroupLayout.init(device, .{ .label = "material maps", .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = fragment },
            .{ .binding = 1, .kind = .{ .sampled_texture = .{} }, .visibility = fragment },
            .{ .binding = 2, .kind = .{ .sampled_texture = .{} }, .visibility = fragment },
            .{ .binding = 3, .kind = .{ .sampled_texture = .{} }, .visibility = fragment },
            .{ .binding = 4, .kind = .{ .sampler = .filtering }, .visibility = fragment },
            .{ .binding = 5, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = fragment },
        } });
        return .{ .gpa = gpa, .device = device, .layout = layout, .sampler = sampler, .neutral_normal = neutral_normal, .white = white };
    }

    /// Free every group and the layout. The GPU must be done with them.
    pub fn deinit(self: *MaterialMaps) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
        self.layout.deinit();
    }

    /// The group for `set`, with `cutoff` an imported part's alpha cutoff; null when it can't be
    /// made (logged).
    pub fn group(self: *MaterialMaps, set: Set, cutoff: f32) ?vit.BindGroup {
        for (self.entries.items) |entry| if (sameSet(entry.set, set) and entry.cutoff == cutoff) return entry.group;
        const made = self.make(set, cutoff) catch |err| {
            std.log.err("cannot make a material's maps: {t}", .{err});
            return null;
        };
        self.entries.append(self.gpa, made) catch {
            made.group.deinit();
            made.params.deinit();
            return null;
        };
        return made.group;
    }

    /// Forget every group sampling `texture`, which is about to be freed. The GPU must be done
    /// with them.
    pub fn forget(self: *MaterialMaps, texture: vit.Texture) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            const uses = for (entry.set) |map| {
                if (map) |known| if (std.meta.eql(known.texture, texture)) break true;
            } else false;
            if (!uses) {
                index += 1;
                continue;
            }
            entry.group.deinit();
            entry.params.deinit();
            _ = self.entries.swapRemove(index);
        }
    }

    pub fn forgetAll(self: *MaterialMaps) void {
        for (self.entries.items) |entry| {
            entry.group.deinit();
            entry.params.deinit();
        }
        self.entries.clearRetainingCapacity();
    }

    fn make(self: *MaterialMaps, set: Set, cutoff: f32) !Entry {
        const params = Params{ .flags = .{ if (set[0] != null) 1 else 0, cutoff, 0, 0 } };
        const buffer = try vit.Buffer.init(self.device, .{ .label = "material maps", .size = @sizeOf(Params), .usage = .{ .uniform = true }, .initial_data = std.mem.asBytes(&params) });
        errdefer buffer.deinit();
        var views: [4]vit.TextureView = undefined;
        for (&views, set, 0..) |*view, map, slot| view.* = if (map) |known| known.view else if (slot == 0) self.neutral_normal else self.white;
        const made = try vit.BindGroup.init(self.device, .{ .layout = self.layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = views[0] } },
            .{ .binding = 1, .resource = .{ .texture_view = views[1] } },
            .{ .binding = 2, .resource = .{ .texture_view = views[2] } },
            .{ .binding = 3, .resource = .{ .texture_view = views[3] } },
            .{ .binding = 4, .resource = .{ .sampler = self.sampler } },
            .{ .binding = 5, .resource = .{ .buffer = .{ .buffer = buffer } } },
        } });
        return .{ .set = set, .cutoff = cutoff, .params = buffer, .group = made };
    }
};

fn sameSet(a: Set, b: Set) bool {
    for (a, b) |left, right| {
        if ((left == null) != (right == null)) return false;
        if (left) |known| if (!std.meta.eql(known.texture, right.?.texture)) return false;
    }
    return true;
}

test "sets match by their textures, a missing map only another missing one" {
    const texture: vit.Texture = undefined;
    const view: vit.TextureView = undefined;
    const normal: Set = .{ .{ .texture = texture, .view = view }, null, null, null };
    try std.testing.expect(sameSet(normal, normal));
    try std.testing.expect(!sameSet(normal, .{ null, null, null, null }));
    try std.testing.expect(sameSet(.{ null, null, null, null }, .{ null, null, null, null }));
}
