//! Components the editor shows and edits: the types a game or plugin lists in `components`, and
//! for each one its fields, which the Inspector reads and writes as ZON text. Every typed step
//! (has, add, remove, a field's value) happens here, in the code that has the types; in the
//! editor that is the game's library.
//!
//!     pub const Spin = struct { speed: f32 = 1, turns: f32 = 0 };
//!     pub const Plugin = struct {
//!         pub const components = .{Spin};
//!     };
//!
//! A component can depend on others, listed in its `dependencies`: adding it adds them, and the
//! editor won't remove one while another needs it. Its `icon`, a Nerd Font character, marks it
//! in the editor (`default_icon` otherwise).
//!
//!     pub const Spin = struct {
//!         pub const dependencies = .{eggy.Transform};
//!         pub const icon = "\u{f0464}"; // nf-md-rotate_3d_variant
//!         speed: f32 = 1,
//!     };
const std = @import("std");
const zon_file = @import("eggy_assets").zon;
const ecs = @import("clutch");
const refs = @import("refs.zig");
pub const max_field_bytes = 4096;

/// How the Inspector edits a field: references (`refs.zig`) take what is dragged onto them.
pub const Kind = enum(u8) { bool, int, float, @"enum", other, entity, asset };

pub const Field = struct {
    name: [:0]const u8,
    kind: Kind,
    /// Its type part by part, for the Inspector to draw a control for each: `parts[0]` is the
    /// field's own type, and each part's children follow later in the list.
    parts: []const Part = &.{},
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

/// What a part of a field's type is, for the control the Inspector draws for it.
pub const PartKind = enum(u8) {
    bool,
    int,
    float,
    @"enum",
    /// Two to four numbers: an array or `@Vector` of them, a struct of `x`, `y`, `z` and `w`, or
    /// an `eggy.math` vector. Its one child is the number's part.
    vector,
    /// Red, green, blue and maybe alpha: a struct of `r`, `g`, `b` (and `a`), or numbers in a
    /// field named `color` or `colour` (or ending `_color`, `_colour`). Its one child is the number's part.
    color,
    /// An `eggy.math` quaternion. Like `euler`, the Inspector shows it in a format to pick.
    quaternion,
    /// Three turns, about x, then y, then z: three numbers in a field named for a rotation
    /// (`rotation`, `orientation` or `euler` in its name), in degrees, or radians when the name
    /// ends `_rad`. Its one child is the number's part.
    euler,
    /// Its children are its fields.
    @"struct",
    /// A tagged union: its children are its variants, each named after its tag.
    @"union",
    /// Its one child is the element's part; `len` says how many.
    array,
    /// Its one child is what it holds when set.
    optional,
    entity,
    asset,
    /// A `void` union variant: nothing to show.
    none,
    /// Anything else (strings, pointers): shown as ZON where it can be, not edited.
    other,
};

/// One part of a field's type. Plain C data, so the list crosses from the editor's game library.
pub const Part = extern struct {
    kind: PartKind,
    /// Its name in the part holding it: a struct's field, a union's variant; empty otherwise.
    name: [*:0]const u8 = "",
    /// Its children: `parts[first..][0..count]` of the list it is in.
    first: u32 = 0,
    count: u32 = 0,
    /// A vector's, colour's or array's length.
    len: u32 = 0,
    /// An int's: whether it can't go below 0.
    unsigned: bool = false,
    /// A vector's or colour's: whether it is a struct (`.{ .x = 1, .y = 2 }`) rather than a list.
    named: bool = false,
    /// An `euler`'s: whether its turns are in radians rather than degrees.
    radians: bool = false,
    /// An enum's values, in order.
    options: [*]const [*:0]const u8 = &.{},
    option_count: u32 = 0,
    /// An entity reference's required component (empty for any), an asset reference's kind of file.
    requires: [*:0]const u8 = "",
    accepts: refs.AssetKind = .any,

    /// Borrow this part's immediate children from its original flat `parts` list.
    /// `first` and `count` must be valid for that list; no recursive descendants are copied.
    ///
    /// ```zig
    /// const child_parts = parts[0].children(parts);
    /// ```
    pub fn children(self: Part, parts: []const Part) []const Part {
        return parts[self.first..][0..self.count];
    }

    /// Borrow the enum tag names; empty for parts without options.
    /// Names and slice remain valid only while the originating registry/library is loaded.
    ///
    /// ```zig
    /// for (part.optionNames()) |name| {
    ///     const tag = std.mem.span(name);
    ///     _ = tag;
    /// }
    /// ```
    pub fn optionNames(self: Part) []const [*:0]const u8 {
        return self.options[0..self.option_count];
    }
};

/// The icon of a component that doesn't declare one: a puzzle piece (nf-md-puzzle_outline).
pub const default_icon = "\u{f0a66}";

pub const Info = struct {
    /// The type's own name: `Spin` for `my_game.Spin`.
    name: [:0]const u8,
    /// Whose it is: `game`, or the key of the plugin that lists it.
    owner: [:0]const u8,
    fields: []const Field,
    /// Whether the editor can add it to an entity: every field has a default.
    addable: bool,
    /// Its `icon`: a Nerd Font character, as UTF-8.
    icon: [:0]const u8 = default_icon,
    /// The components it depends on (its `dependencies`), as indices among the same types.
    dependencies: []const usize = &.{},
};

/// The components in `types`, listed by `owners` (one each), for a world's entities. `infos[i]`
/// describes `types[i]`, and the functions take `i` as `component`.
/// Host reflection adapter: types must be structs, owners must align one-for-one, and every
/// declared dependency must appear in `types`. Metadata has the loaded compilation's lifetime.
///
/// ```zig
/// const Health = struct { value: u32 = 100 };
/// const Components = Registry(&.{Health}, &.{"game"});
/// ```
pub fn Registry(comptime types: []const type, comptime owners: []const [:0]const u8) type {
    return struct {
        pub const infos: []const Info = blk: {
            var list: [types.len]Info = undefined;
            for (&list, types, owners) |*info, T, owner| {
                info.* = infoOf(T, owner);
                info.dependencies = dependencyIndices(T, types);
            }
            const frozen = list;
            break :blk &frozen;
        };

        /// Whether `entity` has component `component`.
        /// `component` indexes `infos`, not clutch's type numbering; out-of-range is false.
        ///
        /// ```zig
        /// const present = Components.has(world, entity, 0);
        /// ```
        pub fn has(world: *ecs.World, entity: ecs.EntityId, component: usize) bool {
            inline for (types, 0..) |T, i| if (i == component) return world.hasComponent(entity, T);
            return false;
        }

        /// Give `entity` component `component`, with its defaults. Fails with
        /// `error.NotAddable` for one whose fields aren't all defaulted.
        /// What it depends on comes first, each with its defaults, where the entity hasn't it.
        /// Mutates the world and propagates allocation errors; an invalid index gives
        /// `NoSuchComponent`. Dependencies already added are not rolled back on failure.
        ///
        /// ```zig
        /// try Components.add(world, entity, 0);
        /// ```
        pub fn add(world: *ecs.World, entity: ecs.EntityId, component: usize) anyerror!void {
            if (component >= types.len) return error.NoSuchComponent;
            for (infos[component].dependencies) |dependency| {
                if (!has(world, entity, dependency)) try add(world, entity, dependency);
            }
            inline for (types, 0..) |T, i| if (i == component) {
                if (comptime !infoOf(T, "").addable) return error.NotAddable;
                return world.addComponent(entity, T{});
            };
            unreachable;
        }

        /// Remove the indexed component; an unknown index does nothing.
        /// Host callers must enforce dependency constraints themselves before removing it.
        /// Structural changes can invalidate borrowed component pointers.
        ///
        /// ```zig
        /// Components.remove(world, entity, 0);
        /// ```
        pub fn remove(world: *ecs.World, entity: ecs.EntityId, component: usize) void {
            inline for (types, 0..) |T, i| if (i == component) return world.remove(entity, T);
        }

        /// Write field `field` of `entity`'s component `component` as ZON.
        /// Indices refer to `infos` and its `fields`; returns `NoComponent` or
        /// `NoSuchComponent` for missing data. Unshowable types write `...`; writer errors
        /// propagate. References serialize as their target ID/path.
        ///
        /// ```zig
        /// var buffer: [max_field_bytes]u8 = undefined;
        /// var writer: std.Io.Writer = .fixed(&buffer);
        /// try Components.writeField(world, entity, 0, 0, &writer);
        /// ```
        pub fn writeField(world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, writer: *std.Io.Writer) (std.Io.Writer.Error || error{ NoComponent, NoSuchComponent })!void {
            inline for (types, 0..) |T, i| if (i == component) {
                const value = world.get(entity, T) orelse return error.NoComponent;
                const info = @typeInfo(T).@"struct";
                inline for (info.field_names, info.field_types, 0..) |name, Member, j| if (j == field) {
                    if (comptime !showable(Member)) return writer.writeAll("...");
                    return std.zon.stringify.serialize(store(Member, &@field(value.*, name)), .{ .whitespace = false }, writer);
                };
            };
            return error.NoSuchComponent;
        }

        /// Set field `field` of `entity`'s component `component` from `text`, ZON for its type.
        /// Fails with `error.ParseZon` when it isn't, leaving the field as it was.
        /// Requires sentinel-terminated text and an editable field. Missing data,
        /// noneditable types and scratch-allocation exhaustion also fail without assignment.
        /// A successful assignment marks the component changed.
        ///
        /// ```zig
        /// try Components.setField(world, entity, 0, 0, "75");
        /// ```
        pub fn setField(world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, text: [:0]const u8) error{ NoComponent, NoSuchComponent, NotEditable, ParseZon, OutOfMemory }!void {
            inline for (types, 0..) |T, i| if (i == component) {
                const value = world.get(entity, T) orelse return error.NoComponent;
                const info = @typeInfo(T).@"struct";
                inline for (info.field_names, info.field_types, 0..) |name, Member, j| if (j == field) {
                    if (comptime !editableType(Member)) return error.NotEditable;
                    const target = &@field(value.*, name);
                    target.* = try parseFieldValue(Member, text);
                    world.markChanged(entity, T);
                    return;
                };
            };
            return error.NoSuchComponent;
        }
    };
}

/// Where each of component `T`'s `dependencies` is among `types`. A dependency nobody lists is
/// a compile error: the editor couldn't add it.
fn dependencyIndices(comptime T: type, comptime types: []const type) []const usize {
    if (!@hasDecl(T, "dependencies")) return &.{};
    var indices: [T.dependencies.len]usize = undefined;
    for (&indices, 0..) |*index, d| {
        const Dependency = T.dependencies[d];
        index.* = for (types, 0..) |Listed, i| {
            if (Listed == Dependency) break i;
        } else @compileError(@typeName(T) ++ " depends on " ++ @typeName(Dependency) ++ ", which no plugin lists in its `components`");
    }
    const frozen = indices;
    return &frozen;
}

/// The components `T` (a game or plugin type) lists in its `components`, if any.
/// Returns compile-time storage, or an empty list when the declaration is absent.
///
/// ```zig
/// const Plugin = struct { pub const components = .{u32}; };
/// const types = listedBy(Plugin);
/// ```
pub fn listedBy(comptime T: type) []const type {
    if (!@hasDecl(T, "components")) return &.{};
    var list: [T.components.len]type = undefined;
    for (&list, 0..) |*slot, i| slot.* = T.components[i];
    const frozen = list;
    return &frozen;
}

fn infoOf(comptime T: type, comptime owner: [:0]const u8) Info {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("component `" ++ @typeName(T) ++ "` must be a struct"),
    };
    var fields: [info.field_names.len]Field = undefined;
    var addable = true;
    for (info.field_names, info.field_types, info.field_attrs, &fields) |name, FieldType, attrs, *field| {
        if (attrs.default_value_ptr == null) addable = false;
        field.* = .{ .name = name, .kind = kindOf(FieldType), .editable = editableType(FieldType), .parts = partsOf(FieldType, name) };
        if (refs.refKind(FieldType)) |kind| switch (kind) {
            .entity => field.requires = if (FieldType.Required == void) "" else shortName(FieldType.Required),
            .asset => field.accepts = FieldType.accepts,
        };
        if (@typeInfo(FieldType) == .@"enum") field.options = @typeInfo(FieldType).@"enum".field_names;
    }
    const frozen = fields;
    const icon: [:0]const u8 = if (@hasDecl(T, "icon")) T.icon ++ "" else default_icon;
    return .{ .name = shortName(T), .owner = owner, .fields = &frozen, .addable = addable, .icon = icon };
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
/// Whether scene/editor values can be changed without retaining arbitrary owned pointers.
/// Recursively accepts plain fields, arrays, optionals and tagged unions; does not
/// promise the value fits the editor's serialization/parse budgets.
///
/// ```zig
/// const editable = editableType(struct { speed: f32 = 1 });
/// ```
pub fn editableType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        .array => |info| editableType(info.child),
        .vector => |info| editableType(info.child),
        .optional => |info| editableType(info.child),
        .@"struct" => |info| for (info.field_types, info.field_attrs) |Member, attrs| {
            if (attrs.@"comptime" or !editableType(Member)) break false;
        } else true,
        .@"union" => |info| info.tag_type != null and for (info.field_types) |Member| {
            if (Member != void and !editableType(Member)) break false;
        } else true,
        .void => true,
        else => false,
    };
}

/// `T` as scenes and the Inspector write it: each reference (anywhere inside) as what it points
/// at, `null` or an entity for an `EntityRef`, a path for an `AssetRef`.
fn Stored(comptime T: type) type {
    // Every component of a project is walked in one evaluation; the default runs out with many.
    @setEvalBranchQuota(100_000);
    if (refs.refKind(T)) |kind| return switch (kind) {
        .entity => ?ecs.EntityId,
        .asset => []const u8,
    };
    if (!holdsRef(T)) return T;
    return switch (@typeInfo(T)) {
        .array => |info| [info.len]Stored(info.child),
        .optional => |info| ?Stored(info.child),
        .@"struct" => |info| @Struct(.auto, null, info.field_names, &storedTypes(info.field_types), &@splat(.{})),
        .@"union" => |info| @Union(.auto, info.tag_type, info.field_names, &storedTypes(info.field_types), &@splat(.{})),
        else => T,
    };
}

fn storedTypes(comptime types: []const type) [types.len]type {
    var stored: [types.len]type = undefined;
    for (&stored, types) |*slot, Member| slot.* = Stored(Member);
    return stored;
}

/// Whether `T` has a reference anywhere inside it.
fn holdsRef(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (refs.refKind(T) != null) return true;
    return switch (@typeInfo(T)) {
        .array => |info| holdsRef(info.child),
        .optional => |info| holdsRef(info.child),
        inline .@"struct", .@"union" => |info| for (info.field_types) |Member| {
            if (holdsRef(Member)) break true;
        } else false,
        else => false,
    };
}

/// `value` as `Stored(T)`; an asset path points into `value`, so it must outlive the result.
fn store(comptime T: type, value: *const T) Stored(T) {
    if (comptime refs.refKind(T)) |kind| return switch (kind) {
        .entity => value.entity,
        .asset => value.key(),
    };
    if (comptime !holdsRef(T)) return value.*;
    var out: Stored(T) = undefined;
    switch (@typeInfo(T)) {
        .array => for (&out, value) |*part, *source| {
            part.* = store(@TypeOf(source.*), source);
        },
        .optional => |info| out = if (value.*) |*inner| store(info.child, inner) else null,
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Member| {
            @field(out, name) = store(Member, &@field(value.*, name));
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, tag| out = @unionInit(Stored(T), @tagName(tag), store(@TypeOf(payload.*), payload)),
        },
        else => comptime unreachable,
    }
    return out;
}

fn parseFieldValue(comptime T: type, text: [:0]const u8) error{ ParseZon, OutOfMemory }!T {
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const stored = try zon_file.parse(Stored(T), fba.allocator(), text, .{});
    return restore(T, stored);
}

/// Check that every field fits the current scene buffer and can be parsed back before an
/// editor action changes it. Runtime-only pointer data is rejected by `editableType`.
/// Host preflight for a plain component struct (or `Name`): does not mutate `value`.
/// Oversized serialized fields give `ValueTooLarge`; parse/restore errors propagate.
/// Callers must reject noneditable types before invoking this serialization check.
///
/// ```zig
/// const Health = struct { value: u32 = 100 };
/// try validateSnapshot(Health, &Health{});
/// ```
pub fn validateSnapshot(comptime T: type, value: *const T) !void {
    if (T == @import("name.zig").Name) return;
    // ponytail: fields have a 4 KiB text/16 KiB parse budget, add sized field reads to the ABI before accepting larger snapshots.
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, Member| {
        var buffer: [max_field_bytes + 1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(buffer[0..max_field_bytes]);
        std.zon.stringify.serialize(store(Member, &@field(value.*, name)), .{ .whitespace = false }, &writer) catch return error.ValueTooLarge;
        buffer[writer.end] = 0;
        _ = try parseFieldValue(Member, buffer[0..writer.end :0]);
    }
}

test "typed snapshots preflight the actual field size and parse budget" {
    const Small = struct { value: u32 = 42, texture: refs.AssetRef(.image) = .init("ship.png") };
    try validateSnapshot(Small, &Small{});
    const Large = struct { values: [max_field_bytes]u8 = @splat(1) };
    try std.testing.expectError(error.ValueTooLarge, validateSnapshot(Large, &Large{}));
}

/// Compare values as scenes store them, excluding unused reference buffers. Allocates
/// temporary serialization buffers; never compares borrowed addresses.
/// Borrows both values; releases its buffers before returning and propagates writer or
/// allocation errors. `Name` compares only its active text.
///
/// ```zig
/// const Health = struct { value: u32 = 100 };
/// const same = try valuesEqual(gpa, Health, &Health{}, &Health{ .value = 75 });
/// ```
pub fn valuesEqual(gpa: std.mem.Allocator, comptime T: type, a: *const T, b: *const T) !bool {
    if (T == @import("name.zig").Name) return std.mem.eql(u8, a.text(), b.text());
    var left: std.Io.Writer.Allocating = .init(gpa);
    defer left.deinit();
    var right: std.Io.Writer.Allocating = .init(gpa);
    defer right.deinit();
    try std.zon.stringify.serialize(store(T, a), .{ .whitespace = false }, &left.writer);
    try std.zon.stringify.serialize(store(T, b), .{ .whitespace = false }, &right.writer);
    return std.mem.eql(u8, left.written(), right.written());
}

/// `stored` back as a `T`. Fails with `error.ParseZon` for an invalid `AssetRef`.
fn restore(comptime T: type, stored: Stored(T)) error{ParseZon}!T {
    if (comptime refs.refKind(T)) |kind| switch (kind) {
        .entity => return .init(stored),
        .asset => {
            return T.parse(stored) catch return error.ParseZon;
        },
    };
    if (comptime !holdsRef(T)) return stored;
    var out: T = undefined;
    switch (@typeInfo(T)) {
        .array => for (&out, stored) |*part, source| {
            part.* = try restore(@TypeOf(part.*), source);
        },
        .optional => |info| out = if (stored) |inner| try restore(info.child, inner) else null,
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Member| {
            @field(out, name) = try restore(Member, @field(stored, name));
        },
        .@"union" => switch (stored) {
            inline else => |payload, tag| out = @unionInit(T, @tagName(tag), try restore(@FieldType(T, @tagName(tag)), payload)),
        },
        else => comptime unreachable,
    }
    return out;
}

/// The parts of type `T` (a field named `name`), breadth first so each part's children sit
/// together: `[0]` is `T` itself.
fn partsOf(comptime T: type, comptime name: [:0]const u8) []const Part {
    comptime {
        @setEvalBranchQuota(100_000);
        var queue: []const type = &.{T};
        var names: []const [:0]const u8 = &.{name};
        var parts: []const Part = &.{};
        var next = 0;
        while (next < queue.len) : (next += 1) {
            const Type = queue[next];
            var part = describePart(Type, names[next]);
            part.name = if (next == 0) "" else names[next].ptr;
            // Children: a vector's, colour's, array's or optional's one; a struct's fields; a union's variants.
            var child_types: []const type = &.{};
            var child_names: []const [:0]const u8 = &.{};
            switch (part.kind) {
                .vector, .color, .euler => {
                    child_types = &.{numberOf(Type).?};
                    child_names = &.{""};
                },
                .array => {
                    child_types = &.{@typeInfo(Type).array.child};
                    child_names = &.{""};
                },
                // What an optional holds keeps its name, so `tint_color: ?[4]f32` is still a colour.
                .optional => {
                    child_types = &.{@typeInfo(Type).optional.child};
                    child_names = &.{names[next]};
                },
                .@"struct" => {
                    child_types = @typeInfo(Type).@"struct".field_types;
                    child_names = @typeInfo(Type).@"struct".field_names;
                },
                .@"union" => {
                    child_types = @typeInfo(Type).@"union".field_types;
                    child_names = @typeInfo(Type).@"union".field_names;
                },
                else => {},
            }
            part.first = queue.len;
            part.count = child_types.len;
            queue = queue ++ child_types;
            names = names ++ child_names;
            parts = parts ++ &[_]Part{part};
        }
        const frozen = parts[0..parts.len].*;
        return &frozen;
    }
}

/// `T`'s part, without its children; `name` is the field's (or struct field's) name.
fn describePart(comptime T: type, comptime name: []const u8) Part {
    if (refs.refKind(T)) |kind| return switch (kind) {
        .entity => .{ .kind = .entity, .requires = if (T.Required == void) "" else shortName(T.Required) },
        .asset => .{ .kind = .asset, .accepts = T.accepts },
    };
    if (isQuaternion(T)) return .{ .kind = .quaternion, .len = 4 };
    const named = @typeInfo(T) == .@"struct";
    if (colorLen(T, name)) |len| return .{ .kind = .color, .len = len, .named = named };
    if (isEuler(T, name)) return .{ .kind = .euler, .len = 3, .named = named, .radians = std.mem.endsWith(u8, name, "_rad") };
    if (vectorLen(T)) |len| return .{ .kind = .vector, .len = len, .named = named };
    return switch (@typeInfo(T)) {
        .bool => .{ .kind = .bool },
        .int => |info| .{ .kind = .int, .unsigned = info.signedness == .unsigned },
        .float => .{ .kind = .float },
        .@"enum" => |info| blk: {
            var options: [info.field_names.len][*:0]const u8 = undefined;
            for (info.field_names, &options) |tag, *option| option.* = tag.ptr;
            const frozen = options;
            break :blk .{ .kind = .@"enum", .options = &frozen, .option_count = frozen.len };
        },
        .void => .{ .kind = .none },
        .@"struct" => |info| if (info.field_names.len > 0 and editableType(T)) .{ .kind = .@"struct" } else .{ .kind = .other },
        .@"union" => |info| if (info.tag_type != null and editableType(T)) .{ .kind = .@"union" } else .{ .kind = .other },
        .array => |info| if (editableType(info.child)) .{ .kind = .array, .len = info.len } else .{ .kind = .other },
        .optional => |info| if (editableType(info.child)) .{ .kind = .optional } else .{ .kind = .other },
        else => .{ .kind = .other },
    };
}

/// The number type a vector or colour `T` is made of, if it is one.
fn numberOf(comptime T: type) ?type {
    const Number = switch (@typeInfo(T)) {
        .array => |info| info.child,
        .vector => |info| info.child,
        .@"struct" => |info| if (info.field_types.len > 0) info.field_types[0] else return null,
        else => return null,
    };
    return switch (@typeInfo(Number)) {
        .int, .float => Number,
        else => null,
    };
}

/// How many numbers vector `T` has: 2 to 4 in an array, a `@Vector`, or a struct of `x`, `y`,
/// `z` and `w` (as `eggy.math` vectors are); null for anything else.
fn vectorLen(comptime T: type) ?u32 {
    return numbersLen(T, &.{ "x", "y", "z", "w" });
}

/// How many channels colour `T` has (3 or 4): a struct of `r`, `g`, `b` and maybe `a`, or numbers
/// in a field named after a colour.
fn colorLen(comptime T: type, comptime name: []const u8) ?u32 {
    const len = numbersLen(T, &.{ "r", "g", "b", "a" }) orelse return null;
    if (len < 3) return null;
    if (@typeInfo(T) == .@"struct") return len;
    for ([_][]const u8{ "color", "colour" }) |word| {
        if (std.mem.eql(u8, name, word) or (std.mem.endsWith(u8, name, word) and name.len > word.len and name[name.len - word.len - 1] == '_')) return len;
    }
    return null;
}

/// How many numbers `T` holds, 2 to 4: an array or `@Vector` of one number type, or a struct of
/// fields named `labels` in order, all of one number type.
fn numbersLen(comptime T: type, comptime labels: []const []const u8) ?u32 {
    const Number = numberOf(T) orelse return null;
    const len: u32 = switch (@typeInfo(T)) {
        .array => |info| info.len,
        .vector => |info| info.len,
        .@"struct" => |info| blk: {
            if (info.field_names.len > labels.len) return null;
            for (info.field_names, info.field_types, 0..) |name, Member, i| {
                if (Member != Number or !std.mem.eql(u8, name, labels[i])) return null;
            }
            break :blk info.field_names.len;
        },
        else => return null,
    };
    return if (len >= 2 and len <= 4) len else null;
}

/// Whether `T`, in a field named `name`, holds turns: three floats in a field named for a rotation.
fn isEuler(comptime T: type, comptime name: []const u8) bool {
    if (vectorLen(T) != 3 or @typeInfo(numberOf(T).?) != .float) return false;
    for ([_][]const u8{ "rotation", "orientation", "euler" }) |word| {
        if (std.mem.indexOf(u8, name, word) != null) return true;
    }
    return false;
}

/// Whether `T` is an `eggy.math` quaternion: four numbers in one `@Vector` field `v`.
fn isQuaternion(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "fromAxisAngle")) return false;
    const info = @typeInfo(T).@"struct";
    return info.field_names.len == 1 and std.mem.eql(u8, info.field_names[0], "v") and vectorLen(info.field_types[0]) == 4;
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
    const sound = refs.AssetRef(.audio).init("sounds/hum.ogg");
    try std.testing.expectEqual(sound.id(), world.get(entity, Orbit).?.sound.id());
    var expected: [18]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "\"{s}\"", .{sound.key()}), text.written());
    try Components.setField(&world, entity, 0, 0, "null");
    try std.testing.expect(world.get(entity, Orbit).?.around.entity == null);
}

test "a field's parts describe vectors, colours, unions and what they hold" {
    const Shape = union(enum) { cube, model: refs.AssetRef(.any) };
    const Look = struct {
        position: [3]f32 = .{ 0, 0, 0 },
        tint_color: [4]f32 = .{ 1, 1, 1, 1 },
        shape: Shape = .cube,
        count: ?u8 = null,
    };
    const fields = Registry(&.{Look}, &.{"game"}).infos[0].fields;
    try std.testing.expectEqual(PartKind.vector, fields[0].parts[0].kind);
    try std.testing.expectEqual(@as(u32, 3), fields[0].parts[0].len);
    try std.testing.expectEqual(PartKind.float, fields[0].parts[0].children(fields[0].parts)[0].kind);
    try std.testing.expectEqual(PartKind.color, fields[1].parts[0].kind);
    const Turned = struct { rotation_deg: [3]f32 = .{ 0, 0, 0 }, spin_rad: [3]f32 = .{ 0, 0, 0 }, orientation_rad: [3]f32 = .{ 0, 0, 0 } };
    const turned = Registry(&.{Turned}, &.{"game"}).infos[0].fields;
    try std.testing.expectEqual(PartKind.euler, turned[0].parts[0].kind);
    try std.testing.expect(!turned[0].parts[0].radians);
    try std.testing.expectEqual(PartKind.vector, turned[1].parts[0].kind); // not named for a rotation
    try std.testing.expect(turned[2].parts[0].radians);

    const shape = fields[2].parts;
    try std.testing.expectEqual(PartKind.@"union", shape[0].kind);
    const variants = shape[0].children(shape);
    try std.testing.expectEqualStrings("cube", std.mem.span(variants[0].name));
    try std.testing.expectEqual(PartKind.none, variants[0].kind);
    try std.testing.expectEqual(PartKind.asset, variants[1].kind);

    const count = fields[3].parts;
    try std.testing.expectEqual(PartKind.optional, count[0].kind);
    try std.testing.expect(count[0].children(count)[0].unsigned);
}

test "references inside a union are written as what they point at" {
    const Shape = union(enum) { cube, model: refs.AssetRef(.any) };
    const Look = struct { shape: Shape = .cube };
    const Components = Registry(&.{Look}, &.{"game"});
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{Look{}});
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try Components.writeField(&world, entity, 0, 0, &text.writer);
    try std.testing.expectEqualStrings(".cube", text.written());

    try Components.setField(&world, entity, 0, 0, ".{ .model = \"art/ship.glb\" }");
    const model = refs.AssetRef(.any).init("art/ship.glb");
    try std.testing.expectEqual(model.id(), world.get(entity, Look).?.shape.model.id());
    text.clearRetainingCapacity();
    try Components.writeField(&world, entity, 0, 0, &text.writer);
    var expected: [32]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, ".{{.model=\"{s}\"}}", .{model.key()}), text.written());
}

test "adding a component adds what it depends on" {
    const Body = struct { mass: f32 = 1 };
    const Wheel = struct {
        pub const dependencies = .{Body};
        radius: f32 = 0.5,
    };
    const Components = Registry(&.{ Wheel, Body }, &.{ "game", "game" });
    try std.testing.expectEqualSlices(usize, &.{1}, Components.infos[0].dependencies);
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{});
    try Components.add(&world, entity, 0);
    try std.testing.expect(Components.has(&world, entity, 1));
}
