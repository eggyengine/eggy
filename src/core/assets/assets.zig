//! The `eggy_assets` module: a project's files as Eggy sees them, without the engine, so the
//! importer library and the packaging tool can use it too. `eggy.assets` re-exports it.
pub const Kind = @import("kind.zig").Kind;
pub const descriptor = @import("descriptor.zig");
pub const Descriptor = descriptor.Descriptor;
pub const model = @import("model.zig");
pub const Model = model.Model;
pub const texture = @import("texture.zig");
pub const Texture = texture.Texture;
pub const manifest = @import("manifest.zig");

test {
    _ = @import("kind.zig");
    _ = @import("descriptor.zig");
    _ = @import("model.zig");
    _ = @import("texture.zig");
    _ = @import("manifest.zig");
}
