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
const asset_id = @import("eggy_assets").id;
/// What kind of file an `AssetRef` takes (see `eggy.assets.Kind`).
pub const AssetKind = @import("eggy_assets").Kind;

/// An entity, if set, that has component `With` (`void`: any entity).
/// Constructs a reference type, not a world lookup; references carry IDs by value.
///
/// ```zig
/// const Target = EntityRef(void);
/// const target = Target.init(entity);
/// ```
pub fn EntityRef(comptime With: type) type {
    return struct {
        entity: ?ecs.EntityId = null,

        /// What the editor and scenes look for to treat the field as an entity reference.
        pub const eggy_ref: RefKind = .entity;
        pub const Required = With;

        /// Store an optional entity ID without checking liveness or required components.
        /// Use `get` against the owning world to resolve it safely.
        ///
        /// ```zig
        /// const target = EntityRef(void).init(entity);
        /// const unset = EntityRef(void).init(null);
        /// ```
        pub fn init(entity: ?ecs.EntityId) @This() {
            return .{ .entity = entity };
        }

        /// Resolve a live target. Typed references borrow its required component; `void`
        /// references return the entity ID. Component pointers expire when storage changes.
        /// Call `world.markChanged(entity, With)` after editing a borrowed component.
        /// Returns null for unset, dead, or component-missing targets; `world` must be
        /// the world from which the ID originated.
        ///
        /// ```zig
        /// const target = EntityRef(void).init(entity);
        /// const live_id = target.get(world) orelse return error.TargetGone;
        /// ```
        pub fn get(self: @This(), world: *ecs.World) if (With == void) ?ecs.EntityId else ?*With {
            const entity = self.entity orelse return null;
            if (!world.isAlive(entity)) return null;
            if (With == void) return entity;
            return world.get(entity, With);
        }
    };
}

/// An opaque asset identity, if set, of kind `kind`. Authoring paths passed to `init`
/// resolve at compile time; stored references never retain those paths.
///
/// ```zig
/// const Image = AssetRef(.image);
/// const image = Image.init("resources/portrait.png");
/// ```
pub fn AssetRef(comptime kind: AssetKind) type {
    return struct {
        buffer: [asset_id.key_len]u8 = undefined,
        len: u8 = 0,

        pub const eggy_ref: RefKind = .asset;
        pub const accepts = kind;

        /// Resolve a project or virtual asset path at compile time, or accept its identity.
        /// Missing assets and kind mismatches fail compilation, not the first rendered frame.
        ///
        /// ```zig
        /// const image = AssetRef(.image).init("resources/portrait.png");
        /// ```
        pub fn init(comptime project_path: []const u8) @This() {
            return comptime block: {
                @setEvalBranchQuota(1_000_000);
                break :block parse(project_path) catch |err| @compileError("cannot resolve asset `" ++ project_path ++ "`: " ++ @errorName(err));
            };
        }

        /// Construct an identity received from the editor catalog or another validated source.
        /// Zero is unset; the caller must ensure the identity has the declared asset kind.
        pub fn fromId(value: asset_id.Id) @This() {
            if (value == 0) return .{};
            var self = @This(){ .len = asset_id.key_len };
            _ = asset_id.key(&self.buffer, value);
            return self;
        }

        /// Parse an identity. Legacy serialized paths resolve through the compiled project
        /// catalog and are immediately converted; the next save writes only the identity.
        pub fn parse(project_path: []const u8) error{ PathTooLong, InvalidPath, WrongAssetKind, InvalidAssetId, UnknownAsset }!@This() {
            if (project_path.len == 0) return .{};
            if (project_path.len == asset_id.key_len) {
                const hex = for (project_path) |byte| {
                    if (!std.ascii.isHex(byte)) break false;
                } else true;
                if (hex) return fromId(try asset_id.parse(project_path));
            }
            const root = @import("root");
            if (comptime @hasDecl(root, "eggy_asset_ids")) {
                if (root.eggy_asset_ids.find(project_path)) |entry| {
                    if (kind != .any and entry.kind != @backingInt(kind)) return error.WrongAssetKind;
                    return fromId(entry.id);
                }
            }
            try validatePath(project_path);
            if (comptime @import("builtin").is_test) {
                // Unit fixtures need identities without a project directory or imported files.
                if (!kind.takes(project_path)) return error.WrongAssetKind;
                return fromId(std.hash.Wyhash.hash(0x6567_6779, project_path));
            }
            return error.UnknownAsset;
        }

        /// The canonical identity key; empty when unset.
        /// Returns a borrowed, non-sentinel slice valid until this reference moves or changes.
        ///
        /// ```zig
        /// const image = AssetRef(.image).init("resources/portrait.png");
        /// const key = image.key();
        /// ```
        pub fn key(self: *const @This()) []const u8 {
            return self.buffer[0..self.len];
        }

        /// The numeric identity, or zero when unset.
        pub fn id(self: *const @This()) asset_id.Id {
            return if (self.len == 0) 0 else asset_id.parse(self.key()) catch unreachable;
        }
    };
}

/// The longest project path accepted during authoring or legacy-reference migration.
pub const max_path_len = 256;

pub const RefKind = enum { entity, asset };

/// Validate an optional project-relative path, using `/` separators. Does not access files.
/// Rejects paths over 256 bytes, absolute/traversing/empty segments, colons, backslashes
/// and NUL bytes. An empty path is valid and means unset.
///
/// ```zig
/// try validatePath("resources/portrait.png");
/// ```
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
/// Uses the struct's `eggy_ref` declaration; unrelated types return null.
///
/// ```zig
/// const kind = refKind(AssetRef(.image)); // .asset
/// ```
pub fn refKind(comptime T: type) ?RefKind {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "eggy_ref")) return null;
    return T.eggy_ref;
}

test "asset references retain identities instead of their authoring paths" {
    const image = AssetRef(.image).init("art/ship.png");
    try std.testing.expectEqual(@as(usize, asset_id.key_len), image.key().len);
    try std.testing.expectEqual(image.id(), (try AssetRef(.image).parse(image.key())).id());
    try std.testing.expectEqualStrings("000000000000002a", AssetRef(.image).fromId(42).key());
    try std.testing.expectError(error.PathTooLong, AssetRef(.any).parse(&@as([max_path_len + 1]u8, @splat('x'))));
    try std.testing.expectEqual(@as(usize, asset_id.key_len), (try AssetRef(.any).parse(&@as([max_path_len]u8, @splat('x')))).key().len);
    for ([_][]const u8{ "/ship.png", "../ship.png", "art/../ship.png", "art\\ship.png", "C:/ship.png", "art//ship.png" }) |path| {
        try std.testing.expectError(error.InvalidPath, AssetRef(.image).parse(path));
    }
    try std.testing.expectError(error.WrongAssetKind, AssetRef(.audio).parse("ship.png"));
    try std.testing.expectEqual(@as(usize, 0), (try AssetRef(.image).parse("")).key().len);
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
