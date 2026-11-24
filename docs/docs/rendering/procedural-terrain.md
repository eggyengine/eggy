---
title: Procedural terrain
sidebar_position: 7
description: Build ground from noise in code, draw it, stand on it, and change it while the game runs.
---

Terrain made in code is a height for every point on the ground, turned into triangles and
handed to `app.meshes()` under a name. A Mesh with the `.generated` shape draws those
triangles, and a `mesh` Collider makes them solid.

Start with the height. Any function of `x` and `z` will do; layered noise gives rolling hills.
Eggy has no noise function of its own, so this one stands alone: `random` gives a fixed number
for each whole-number point, `smoothNoise` blends between them, and `height` adds five layers,
each half as tall and twice as fine as the one before.

```zig
const std = @import("std");
const eggy = @import("eggy");

/// Another number gives another world; the same number always gives the same one.
const seed: u32 = 1234;

/// The ground's height in metres at `x`, `z`.
fn height(x: f32, z: f32) f32 {
    var total: f32 = 0;
    var amplitude_m: f32 = 8;
    var frequency: f32 = 1.0 / 40.0;
    for (0..5) |_| {
        total += amplitude_m * smoothNoise(x * frequency, z * frequency);
        amplitude_m *= 0.5;
        frequency *= 2;
    }
    return total;
}

/// -1 to 1, smooth between whole-number points.
fn smoothNoise(x: f32, z: f32) f32 {
    const left = @floor(x);
    const top = @floor(z);
    const ix: i32 = @intFromFloat(left);
    const iz: i32 = @intFromFloat(top);
    const tx = ease(x - left);
    const tz = ease(z - top);
    const near = std.math.lerp(random(ix, iz), random(ix + 1, iz), tx);
    const far = std.math.lerp(random(ix, iz + 1), random(ix + 1, iz + 1), tx);
    return std.math.lerp(near, far, tz);
}

fn ease(t: f32) f32 {
    return t * t * (3 - 2 * t);
}

/// -1 to 1, the same every time for the same point.
fn random(x: i32, z: i32) f32 {
    var hash: u32 = seed ^ @as(u32, @bitCast(x)) *% 0x27d4eb2d ^ @as(u32, @bitCast(z)) *% 0x165667b1;
    hash ^= hash >> 16;
    hash *%= 0x7feb352d;
    hash ^= hash >> 15;
    hash *%= 0x846ca68b;
    hash ^= hash >> 16;
    return @as(f32, @floatFromInt(hash >> 8)) / 16777215.0 * 2 - 1;
}
```

The ground is cut into square chunks, each a mesh of its own, so a big world can be made and
changed a piece at a time. A chunk is a grid of `cells` by `cells` squares, two triangles each.
Its corners are placed in world space, so every chunk's entity sits at the origin. Each corner
takes its height and normal from `height` itself, not from the grid, so neighbouring chunks
meet without a seam.

```zig
const cells = 64;
const cell_m: f32 = 1;
const chunk_m: f32 = cells * cell_m;

/// Make the chunk `chunk_x`, `chunk_z` the mesh `name`.
fn makeChunk(gpa: std.mem.Allocator, meshes: *eggy.GeneratedMeshes, name: []const u8, chunk_x: i32, chunk_z: i32) !void {
    const side = cells + 1;
    const vertices = try gpa.alloc(eggy.generated_meshes.Vertex, side * side);
    defer gpa.free(vertices);
    const indices = try gpa.alloc(u32, cells * cells * 6);
    defer gpa.free(indices);

    const start_x = @as(f32, @floatFromInt(chunk_x)) * chunk_m;
    const start_z = @as(f32, @floatFromInt(chunk_z)) * chunk_m;
    for (0..side) |row| {
        for (0..side) |column| {
            const x = start_x + @as(f32, @floatFromInt(column)) * cell_m;
            const z = start_z + @as(f32, @floatFromInt(row)) * cell_m;
            const y = height(x, z);
            vertices[row * side + column] = .{
                .position = .{ x, y, z },
                .normal = normalAt(x, z),
                .uv = .{ x / 4, z / 4 },
                .color = colorAt(y),
            };
        }
    }

    // Counter-clockwise seen from above, the side the ground faces.
    var at: usize = 0;
    for (0..cells) |row| {
        for (0..cells) |column| {
            const corner: u32 = @intCast(row * side + column);
            const right = corner + 1;
            const below = corner + side;
            const below_right = below + 1;
            indices[at..][0..6].* = .{ corner, below_right, right, corner, below, below_right };
            at += 6;
        }
    }
    try meshes.set(name, vertices, indices);
}

/// Which way the ground faces at `x`, `z`: up, tilted away from the slope.
fn normalAt(x: f32, z: f32) [3]f32 {
    const step_m: f32 = 0.5;
    const n = [3]f32{ height(x - step_m, z) - height(x + step_m, z), 2 * step_m, height(x, z - step_m) - height(x, z + step_m) };
    const length = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    return .{ n[0] / length, n[1] / length, n[2] / length };
}

/// Sand low down, grass above it, rock on the tops.
fn colorAt(y: f32) [4]f32 {
    if (y < -3) return .{ 0.76, 0.7, 0.5, 1 };
    if (y < 5) return .{ 0.3, 0.55, 0.25, 1 };
    return .{ 0.5, 0.5, 0.52, 1 };
}
```

Triangles wound the other way would face down, and from above you'd see nothing. The normals
are what light the hills and shade the valleys. A Mesh's `color` tints the corners' colours,
so give it white to keep them as they are; a Material on the entity paints over them with its
own. The `uv` repeats every 4 metres, for an image set as the Mesh's `texture`.

Make the chunks when the game starts, and an entity to draw each. A Collider alone is static
scenery, which is all a `mesh` collider can be.

```zig
pub const Game = struct {
    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Game {
        // Five by five chunks around the origin.
        const radius = 2;
        var chunk_z: i32 = -radius;
        while (chunk_z <= radius) : (chunk_z += 1) {
            var chunk_x: i32 = -radius;
            while (chunk_x <= radius) : (chunk_x += 1) {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "terrain {d} {d}", .{ chunk_x, chunk_z });
                try makeChunk(gpa, app.meshes(), name, chunk_x, chunk_z);
                _ = try app.world.spawn(.{
                    eggy.Name.init(name),
                    eggy.Transform{},
                    eggy.Mesh{ .shape = .{ .generated = .init(name) }, .color = .{ 1, 1, 1 } },
                    eggy.physics.Collider{ .shape = .mesh },
                });
            }
        }
        return .{};
    }
};
```

`init` runs again on every Play and every hot reload, and setting a name that is already there
replaces it, so nothing piles up. In the editor the terrain shows once you press Play. A mesh
name is up to 64 bytes and can't be 16 hexadecimal digits, which is what an asset key looks like.

To stand something on the ground, ask `height` rather than the physics world: a tree at `x`, `z`
goes at `.init(x, height(x, z), z)`. For anything that has moved since, cast down with
[`eggy.physics.raycast`](../physics/use-physics.md).

The ground can change while the game runs. Keep the changes in the game, such as a list of
craters that `height` subtracts, then call `makeChunk` again for each chunk a change touches.
Setting a name again draws its new triangles from the next frame and rebuilds its collider, so
make only the chunks that changed: each one is sent to the GPU and rebuilt for physics in full.
For a world without edges, make the chunks around `app.viewer()` in `update` and drop the ones
far from it with `app.meshes().remove(name)` and `app.world.despawn(entity)`. The viewer is
where the frame is seen from, so it is the game's camera while playing and the Scene panel's
own while you Simulate and fly around.
