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

        /// Resolve a live target. Typed references borrow its required component; `void`
        /// references return the entity ID. Component pointers expire when storage changes.
        /// Call `world.markChanged(entity, With)` after editing a borrowed component.
        pub fn get(self: @This(), world: *ecs.World) if (With == void) ?ecs.EntityId else ?*With {
            const entity = self.entity orelse return null;
            if (!world.isAlive(entity)) return null;
            if (With == void) return entity;
            return world.get(entity, With);
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

        /// A checked path known at compile time. Use `parse` for paths received at runtime.
        pub fn init(comptime project_path: []const u8) @This() {
            return comptime parse(project_path) catch |err| @compileError("invalid asset path: " ++ @errorName(err));
        }

        /// Keep a relative project path by value. Empty means unset. Reject overlong paths,
        /// traversal, platform separators and files of the wrong kind without clearing a value.
        pub fn parse(project_path: []const u8) error{ PathTooLong, InvalidPath, WrongAssetKind }!@This() {
            try validatePath(project_path);
            if (project_path.len != 0 and !kind.takes(project_path)) return error.WrongAssetKind;
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

/// Validate an optional project-relative path, using `/` separators. Does not access files.
pub fn validatePath(path: []const u8) error{ PathTooLong, InvalidPath }!void {
    if (path.len > max_path_len) return error.PathTooLong;
    if (path.len == 0) return;
    if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return error.InvalidPath;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
    }
}

/// The reference kind of type `T`, if it is one.
pub fn refKind(comptime T: type) ?RefKind {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "eggy_ref")) return null;
    return T.eggy_ref;
}

test "an asset reference keeps its path" {
    try std.testing.expectEqualStrings("art/ship.png", AssetRef(.image).init("art/ship.png").path());
    try std.testing.expectError(error.PathTooLong, AssetRef(.any).parse("x" ** (max_path_len + 1)));
    try std.testing.expectEqual(@as(usize, max_path_len), (try AssetRef(.any).parse("x" ** max_path_len)).path().len);
    for ([_][]const u8{ "/ship.png", "../ship.png", "art/../ship.png", "art\\ship.png", "C:/ship.png", "art//ship.png" }) |path| {
        try std.testing.expectError(error.InvalidPath, AssetRef(.image).parse(path));
    }
    try std.testing.expectError(error.WrongAssetKind, AssetRef(.audio).parse("ship.png"));
    try std.testing.expectEqual(@as(usize, 0), (try AssetRef(.image).parse("")).path().len);
}

test "entity references check generations and required components" {
    const Health = struct { value: u32 = 10 };
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{Health{}});
    const ref = EntityRef(Health).init(entity);
    try std.testing.expectEqual(@as(u32, 10), ref.get(&world).?.value);
    try std.testing.expect(EntityRef(void).init(entity).get(&world).?.eql(entity));
    try std.testing.expect(EntityRef(u32).init(entity).get(&world) == null);
    world.despawn(entity);
    _ = try world.spawn(.{Health{}});
    try std.testing.expect(ref.get(&world) == null);
    try std.testing.expect((EntityRef(Health){}).get(&world) == null);
}
