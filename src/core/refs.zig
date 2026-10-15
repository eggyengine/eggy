//! References a component's field can hold: another entity (`EntityRef`) or a file of the
//! project (`AssetRef`). The editor's Inspector takes them by dragging an entity from the
//! Hierarchy or a file from Assets onto the field, and only one the field accepts: an entity with
//! the component it asks for, a file of the kind it asks for. Scenes save entity references by
//! their place in the scene, so they point at the same entities when it is loaded again.
//!
//!     pub const Orbit = struct {
//!         around: eggy.EntityRef(Body) = .{},
//!         sound: eggy.AssetRef(.audio) = .{},
//!     };
const std = @import("std");
const ecs = @import("clutch");
/// What kind of file an `AssetRef` takes (see `eggy.assets.Kind`).
pub const AssetKind = @import("eggy_assets").Kind;

/// An entity, if set, that has component `With` (`void`: any entity).
pub fn EntityRef(comptime With: type) type {
    return struct {
        entity: ?ecs.EntityId = null,

        /// What the editor and scenes look for to treat the field as an entity reference.
        pub const eggy_ref: RefKind = .entity;
        pub const Required = With;

        pub fn init(entity: ?ecs.EntityId) @This() {
            return .{ .entity = entity };
        }
    };
}

/// A file of the project, if set, of kind `kind`: its path relative to the project, with `/`
/// between parts. Kept in a fixed buffer, like `Name`, so it holds no pointers.
pub fn AssetRef(comptime kind: AssetKind) type {
    return struct {
        buffer: [max_path_len]u8 = undefined,
        len: u16 = 0,

        pub const eggy_ref: RefKind = .asset;
        pub const accepts = kind;

        /// `project_path`, or empty when longer than `max_path_len`.
        pub fn init(project_path: []const u8) @This() {
            if (project_path.len > max_path_len) return .{};
            var self = @This(){ .len = @intCast(project_path.len) };
            @memcpy(self.buffer[0..project_path.len], project_path);
            return self;
        }

        /// The path; empty when unset.
        pub fn path(self: *const @This()) []const u8 {
            return self.buffer[0..self.len];
        }
    };
}

/// The longest path an `AssetRef` holds.
pub const max_path_len = 256;

pub const RefKind = enum { entity, asset };

/// The reference kind of type `T`, if it is one.
pub fn refKind(comptime T: type) ?RefKind {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "eggy_ref")) return null;
    return T.eggy_ref;
}

test "an asset reference keeps its path" {
    try std.testing.expectEqualStrings("art/ship.png", AssetRef(.image).init("art/ship.png").path());
    try std.testing.expectEqual(@as(usize, 0), AssetRef(.image).init("x" ** (max_path_len + 1)).path().len);
}
