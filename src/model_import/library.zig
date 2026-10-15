//! `eggy_assimp`: a shared library holding assimp, so only the editor and packaging carry it,
//! and the editor links it rather than building it into itself. It imports a model file into
//! one list of triangles, every part placed where the file puts it, scaled, with smooth normals.
const std = @import("std");
const c = @import("assimp");
const Imported = @import("abi.zig").Imported;
const Vertex = @import("eggy_assets").model.Vertex;

/// What assimp does to every model: triangles only, each part moved to where its node puts it,
/// normals where the file has none, and shared corners joined.
const steps = c.aiProcess_Triangulate | c.aiProcess_PreTransformVertices | c.aiProcess_GenSmoothNormals | c.aiProcess_JoinIdenticalVertices | c.aiProcess_SortByPType;

/// Import the model file at `path`, `scale` times its size, into `out`. False when it can't be
/// (`eggy_import_error` says why).
export fn eggy_import_model(path: [*:0]const u8, scale: f32, out: *Imported) bool {
    failure = null;
    const scene: *const c.struct_aiScene = c.aiImportFile(path, steps) orelse return false;
    defer c.aiReleaseImport(scene);
    const meshes = if (scene.mMeshes) |list| list[0..scene.mNumMeshes] else return fail("it has no meshes");

    // Room for every mesh's corners and triangles (points and lines left out).
    var vertex_count: usize = 0;
    var index_count: usize = 0;
    for (meshes) |mesh| {
        vertex_count += mesh.*.mNumVertices;
        for (mesh.*.mFaces[0..mesh.*.mNumFaces]) |face| {
            if (face.mNumIndices == 3) index_count += 3;
        }
    }
    const vertices = std.heap.c_allocator.alloc(Vertex, vertex_count) catch return fail("out of memory");
    const indices = std.heap.c_allocator.alloc(u32, index_count) catch {
        std.heap.c_allocator.free(vertices);
        return fail("out of memory");
    };

    // Each mesh's corners, then its triangles pointing at them.
    var next_vertex: usize = 0;
    var next_index: usize = 0;
    for (meshes) |mesh| {
        const first: u32 = @intCast(next_vertex);
        for (0..mesh.*.mNumVertices) |i| {
            const at = mesh.*.mVertices[i];
            const normal: [3]f32 = if (mesh.*.mNormals) |normals| .{ normals[i].x, normals[i].y, normals[i].z } else .{ 0, 1, 0 };
            vertices[next_vertex] = .{ .position = .{ at.x * scale, at.y * scale, at.z * scale }, .normal = normal };
            next_vertex += 1;
        }
        for (mesh.*.mFaces[0..mesh.*.mNumFaces]) |face| {
            if (face.mNumIndices != 3) continue;
            for (face.mIndices[0..3]) |index| {
                indices[next_index] = first + index;
                next_index += 1;
            }
        }
    }
    out.* = .{ .vertices = vertices.ptr, .vertex_count = vertices.len, .indices = indices.ptr, .index_count = indices.len };
    return true;
}

/// Free what `eggy_import_model` put in `model`.
export fn eggy_free_model(model: *Imported) void {
    std.heap.c_allocator.free(model.vertices[0..model.vertex_count]);
    std.heap.c_allocator.free(model.indices[0..model.index_count]);
}

/// Why the last import on this thread failed.
export fn eggy_import_error() [*:0]const u8 {
    return failure orelse c.aiGetErrorString();
}

/// A failure of Eggy's own (rather than assimp's), for `eggy_import_error`.
threadlocal var failure: ?[*:0]const u8 = null;

fn fail(why: [*:0]const u8) bool {
    failure = why;
    return false;
}
