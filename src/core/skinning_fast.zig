//! The loops over every corner of a posed model (`eggy_assets.rig.skinVertices` and
//! `cornerBounds`), built ReleaseFast even in Debug and linked into eggy
//! (`src/build/fast_library.zig`): posing animated models is the hottest work a frame does on
//! the CPU, many times slower unoptimized. `deformation.zig` calls them.
const std = @import("std");
const assets = @import("eggy_assets");
const Vertex = assets.model.Vertex;
const Influence = assets.model.Influence;
const Mat = assets.rig.Mat;

// `Influence` isn't `extern`; this copy and the caller's must lay it out alike.
comptime {
    std.debug.assert(@offsetOf(Influence, "joints") == 0 and @offsetOf(Influence, "weights") == 16);
}

export fn eggy_skin_vertices(corners: [*]Vertex, influences: [*]const Influence, count: usize, joints: [*]const Mat, joint_normals: [*]const [3][3]f32, joint_count: usize) void {
    assets.rig.skinVertices(corners[0..count], influences[0..count], joints[0..joint_count], joint_normals[0..joint_count]);
}

export fn eggy_corner_bounds(corners: [*]const Vertex, count: usize, min: *[3]f32, max: *[3]f32) void {
    const box = assets.rig.cornerBounds(corners[0..count]);
    min.* = box.min;
    max.* = box.max;
}
