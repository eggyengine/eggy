//! The `eggy_assets` module: a project's files as Eggy sees them, without the engine, so the
//! importer library and the packaging tool can use it too. `eggy.assets` re-exports it.
pub const Kind = @import("kind.zig").Kind;
pub const id = @import("id.zig");
pub const Id = id.Id;
pub const registry = @import("registry.zig");
pub const catalog = @import("catalog.zig");
pub const subassets = @import("subassets.zig");
pub const descriptor = @import("descriptor.zig");
pub const Descriptor = descriptor.Descriptor;
pub const bounds = @import("bounds.zig");
pub const Bounds = bounds.Bounds;
pub const model = @import("model.zig");
pub const Model = model.Model;
pub const rig = @import("rig.zig");
pub const texture = @import("texture.zig");
pub const Texture = texture.Texture;
pub const package = @import("package.zig");
pub const clip = @import("clip.zig");
pub const imported_clip = @import("imported_clip.zig");

test {
    _ = id;
    _ = registry;
    _ = catalog;
    _ = subassets;
    _ = imported_clip;
    _ = @import("kind.zig");
    _ = @import("descriptor.zig");
    _ = @import("model.zig");
    _ = @import("rig.zig");
    _ = @import("texture.zig");
    _ = package;
    _ = @import("clip.zig");
}
