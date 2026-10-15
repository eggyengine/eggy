//! Components the editor shows and edits: the types a game or plugin lists in `components`, and
//! for each one its fields, which the Inspector reads and writes as ZON text. Every typed step
//! (has, add, remove, a field's value) happens here, in the code that has the types; in the
//! editor that is the game's library.
//!
//!     pub const Spin = struct { speed: f32 = 1, turns: f32 = 0 };
//!     pub const Plugin = struct {
//!         pub const components = .{Spin};
//!     };
const std = @import("std");
const ecs = @import("clutch");
const refs = @import("refs.zig");

/// How the Inspector edits a field: references (`refs.zig`) take what is dragged onto them.
pub const Kind = enum(u8) { bool, int, float, @"enum", other, entity, asset };

pub const Field = struct {
    name: [:0]const u8,
    kind: Kind,
    /// An enum's values, in order; empty otherwise.
    options: []const [:0]const u8 = &.{},
    /// An entity reference's: the component (its short name) an entity needs to be set here;
    /// empty for any entity.
    requires: [:0]const u8 = "",
    /// An asset reference's: the kind of file it takes.
    accepts: refs.AssetKind = .any,
    /// Whether the Inspector can change it: its type is plain data, which ZON can parse without
    /// allocating. The others are shown, if they can be, but not edited.
    editable: bool,
};

pub const Info = struct {
    /// The type's own name: `Spin` for `my_game.Spin`.
    name: [:0]const u8,
    /// Whose it is: `game`, or the key of the plugin that lists it.
    owner: [:0]const u8,
    fields: []const Field,
    /// Whether the editor can add it to an entity: every field has a default.
    addable: bool,
};

/// The components in `types`, listed by `owners` (one each), for a world's entities. `infos[i]`
/// describes `types[i]`, and the functions take `i` as `component`.
pub fn Registry(comptime types: []const type, comptime owners: []const [:0]const u8) type {
    return struct {
        pub const infos: []const Info = blk: {
            var list: [types.len]Info = undefined;
            for (&list, types, owners) |*info, T, owner| info.* = infoOf(T, owner);
            const frozen = list;
            break :blk &frozen;
        };

        /// Whether `entity` has component `component`.
        pub fn has(world: *ecs.World, entity: ecs.EntityId, component: usize) bool {
            inline for (types, 0..) |T, i| if (i == component) return world.hasComponent(entity, T);
            return false;
        }

        /// Give `entity` component `component`, with its defaults. Fails with
        /// `error.NotAddable` for one whose fields aren't all defaulted.
        pub fn add(world: *ecs.World, entity: ecs.EntityId, component: usize) anyerror!void {
            inline for (types, 0..) |T, i| if (i == component) {
                if (comptime !infoOf(T, "").addable) return error.NotAddable;
                return world.addComponent(entity, T{});
            };
            return error.NoSuchComponent;
        }

        pub fn remove(world: *ecs.World, entity: ecs.EntityId, component: usize) void {
            inline for (types, 0..) |T, i| if (i == component) return world.remove(entity, T);
        }

        /// Write field `field` of `entity`'s component `component` as ZON.
        pub fn writeField(world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, writer: *std.Io.Writer) (std.Io.Writer.Error || error{ NoComponent, NoSuchComponent })!void {
            inline for (types, 0..) |T, i| if (i == component) {
                const value = world.get(entity, T) orelse return error.NoComponent;
                inline for (@typeInfo(T).@"struct".fields, 0..) |struct_field, j| if (j == field) {
                    const current = @field(value.*, struct_field.name);
                    // References as what they point at: `null`, an entity, or a path.
                    if (comptime refs.refKind(struct_field.type)) |kind| return switch (kind) {
                        .entity => std.zon.stringify.serialize(current.entity, .{ .whitespace = false }, writer),
                        .asset => std.zon.stringify.serialize(current.path(), .{ .whitespace = false }, writer),
                    };
                    if (comptime !showable(struct_field.type)) return writer.writeAll("...");
                    return std.zon.stringify.serialize(current, .{ .whitespace = false }, writer);
                };
            };
            return error.NoSuchComponent;
        }

        /// Set field `field` of `entity`'s component `component` from `text`, ZON for its type.
        /// Fails with `error.ParseZon` when it isn't, leaving the field as it was.
        pub fn setField(world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, text: [:0]const u8) error{ NoComponent, NoSuchComponent, NotEditable, ParseZon, OutOfMemory }!void {
            inline for (types, 0..) |T, i| if (i == component) {
                const value = world.get(entity, T) orelse return error.NoComponent;
                inline for (@typeInfo(T).@"struct".fields, 0..) |struct_field, j| if (j == field) {
                    if (comptime !editableType(struct_field.type)) return error.NotEditable;
                    var scratch: [16 * 1024]u8 = undefined;
                    var fba = std.heap.FixedBufferAllocator.init(&scratch);
                    const target = &@field(value.*, struct_field.name);
                    if (comptime refs.refKind(struct_field.type)) |kind| switch (kind) {
                        .entity => target.* = .init(try std.zon.parse.fromSlice(?ecs.EntityId, fba.allocator(), text, null, .{})),
                        .asset => {
                            const path = try std.zon.parse.fromSliceAlloc([]const u8, fba.allocator(), text, null, .{});
                            if (path.len > refs.max_path_len) return error.ParseZon;
                            target.* = .init(path);
                        },
                    } else target.* = try std.zon.parse.fromSlice(struct_field.type, fba.allocator(), text, null, .{});
                    world.markChanged(entity, T);
                    return;
                };
            };
            return error.NoSuchComponent;
        }
    };
}

/// The components `T` (a game or plugin type) lists in its `components`, if any.
pub fn listedBy(comptime T: type) []const type {
    if (!@hasDecl(T, "components")) return &.{};
    var list: [T.components.len]type = undefined;
    for (&list, 0..) |*slot, i| slot.* = T.components[i];
    const frozen = list;
    return &frozen;
}

fn infoOf(comptime T: type, comptime owner: [:0]const u8) Info {
    const struct_fields = switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("component `" ++ @typeName(T) ++ "` must be a struct"),
    };
    var fields: [struct_fields.len]Field = undefined;
    var addable = true;
    for (struct_fields, &fields) |struct_field, *field| {
        if (struct_field.defaultValue() == null) addable = false;
        field.* = .{ .name = struct_field.name, .kind = kindOf(struct_field.type), .editable = editableType(struct_field.type) };
        if (refs.refKind(struct_field.type)) |kind| switch (kind) {
            .entity => field.requires = if (struct_field.type.Required == void) "" else shortName(struct_field.type.Required),
            .asset => field.accepts = struct_field.type.accepts,
        };
        if (@typeInfo(struct_field.type) == .@"enum") {
            const tags = @typeInfo(struct_field.type).@"enum".fields;
            var options: [tags.len][:0]const u8 = undefined;
            for (tags, &options) |tag, *option| option.* = tag.name;
            const frozen = options;
            field.options = &frozen;
        }
    }
    const frozen = fields;
    return .{ .name = shortName(T), .owner = owner, .fields = &frozen, .addable = addable };
}

fn kindOf(comptime T: type) Kind {
    if (refs.refKind(T)) |kind| return switch (kind) {
        .entity => .entity,
        .asset => .asset,
    };
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int, .comptime_int => .int,
        .float, .comptime_float => .float,
        .@"enum" => .@"enum",
        else => .other,
    };
}

/// `my_game.Spin` as `Spin`.
fn shortName(comptime T: type) [:0]const u8 {
    const name = @typeName(T);
    const start = if (comptime std.mem.lastIndexOfScalar(u8, name, '.')) |dot| dot + 1 else 0;
    return name[start..] ++ "";
}

/// Whether values of `T` are plain data: no pointers, functions or other things ZON can't parse
/// without allocating.
fn editableType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        .array => |info| editableType(info.child),
        .vector => |info| editableType(info.child),
        .optional => |info| editableType(info.child),
        .@"struct" => |info| for (info.fields) |field| {
            if (field.is_comptime or !editableType(field.type)) break false;
        } else true,
        else => false,
    };
}

/// Whether ZON can show values of `T`: plain data, or strings.
fn showable(comptime T: type) bool {
    if (editableType(T)) return true;
    return switch (@typeInfo(T)) {
        .pointer => |info| info.size == .slice and info.child == u8,
        else => false,
    };
}

const Spin = struct {
    speed: f32 = 1,
    axis: enum { x, y, z } = .y,
    offset: [2]f32 = .{ 0, 0 },
};
const Tag = struct { id: u32 };

test "a component's fields are described for the Inspector" {
    const Components = Registry(&.{ Spin, Tag }, &.{ "game", "game" });
    const spin = Components.infos[0];
    try std.testing.expectEqualStrings("Spin", spin.name);
    try std.testing.expect(spin.addable);
    try std.testing.expectEqual(Kind.@"enum", spin.fields[1].kind);
    try std.testing.expectEqualStrings("z", spin.fields[1].options[2]);
    try std.testing.expectEqual(Kind.other, spin.fields[2].kind);
    try std.testing.expect(spin.fields[2].editable);
    try std.testing.expect(!Components.infos[1].addable); // `id` has no default
}

test "fields are read and written as ZON, and bad text leaves them be" {
    const Components = Registry(&.{Spin}, &.{"game"});
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{});
    try std.testing.expect(!Components.has(&world, entity, 0));
    try Components.add(&world, entity, 0);
    try std.testing.expect(Components.has(&world, entity, 0));

    try Components.setField(&world, entity, 0, 0, "2.5");
    try Components.setField(&world, entity, 0, 2, ".{ 1, 2 }");
    try std.testing.expectError(error.ParseZon, Components.setField(&world, entity, 0, 1, ".sideways"));
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try Components.writeField(&world, entity, 0, 2, &text.writer);
    try std.testing.expectEqualStrings(".{1,2}", text.written());
    try std.testing.expectEqual(@as(f32, 2.5), world.get(entity, Spin).?.speed);
    try std.testing.expectEqual(.y, world.get(entity, Spin).?.axis);

    Components.remove(&world, entity, 0);
    try std.testing.expect(!Components.has(&world, entity, 0));
}

test "references are read and written as what they point at" {
    const Target = struct { size: f32 = 1 };
    const Orbit = struct {
        around: refs.EntityRef(Target) = .{},
        sound: refs.AssetRef(.audio) = .{},
    };
    const Components = Registry(&.{Orbit}, &.{"game"});
    const info = Components.infos[0];
    try std.testing.expectEqual(Kind.entity, info.fields[0].kind);
    try std.testing.expectEqualStrings("Target", info.fields[0].requires);
    try std.testing.expectEqual(Kind.asset, info.fields[1].kind);
    try std.testing.expectEqual(refs.AssetKind.audio, info.fields[1].accepts);

    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{Orbit{}});
    try Components.setField(&world, entity, 0, 0, ".{ .id = 4, .generation = 2 }");
    try Components.setField(&world, entity, 0, 1, "\"sounds/hum.ogg\"");
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try Components.writeField(&world, entity, 0, 0, &text.writer);
    try std.testing.expectEqualStrings(".{.id=4,.generation=2}", text.written());
    text.clearRetainingCapacity();
    try Components.writeField(&world, entity, 0, 1, &text.writer);
    try std.testing.expectEqualStrings("\"sounds/hum.ogg\"", text.written());
    try Components.setField(&world, entity, 0, 0, "null");
    try std.testing.expect(world.get(entity, Orbit).?.around.entity == null);
}
