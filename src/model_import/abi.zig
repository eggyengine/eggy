//! What crosses between `eggy_assimp` (`library.zig`) and the code that calls it
//! (`model_import.zig`): plain C data, and the names of the library's functions.
const assets = @import("eggy_assets");

/// A model as the library imported it, in memory the library owns until `eggy_free_model`.
pub const Imported = extern struct {
    vertices: [*]assets.model.Vertex,
    vertex_count: usize,
    indices: [*]u32,
    index_count: usize,
};
