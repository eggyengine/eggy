//! What crosses between `eggy_assimp` (`library.zig`) and the code that calls it
//! (`model_import.zig`): plain C data, and the names of the library's functions. Models and
//! images cross in their packaged forms (`.eggmodel`, `.eggtexture`), so their shape can change
//! without the boundary changing.

/// Bytes the library made, which it owns until `eggy_free_bytes`.
pub const Bytes = extern struct {
    ptr: [*]u8,
    len: usize,
};
