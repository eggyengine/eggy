//! Build-time asset inputs; installed payloads are addressed directly by identity.
const Kind = @import("kind.zig").Kind;
const ModelImport = @import("descriptor.zig").ModelImport;

/// A source retained by the hidden project catalog, never an installed runtime index.
pub const Entry = struct {
    path: []const u8,
    id: u64,
    kind: Kind,
    model: ModelImport = .{},
};

pub const Conversion = enum {
    model,
    texture,
    copy,

    /// Choose a source-file conversion before replacing its name with an opaque identity.
    pub fn of(path: []const u8) Conversion {
        if (Kind.of(path) == .model) return .model;
        if (Kind.isTexture(path)) return .texture;
        return .copy;
    }
};
