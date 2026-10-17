//! Preferences: settings a plugin (or the editor) declares as a struct of defaults, which people
//! change in the editor's Preferences window and which are kept as ZON. Values come in layers,
//! each overriding the one below: the struct's defaults, the user's global preferences (the
//! editor's own only), then the project's (`.eggy/`). A plugin's are the project's, which the
//! runtime gets baked in when the game is built.
//!
//!     pub const Preferences = struct {
//!         volume: f32 = 0.8,
//!         show_gizmos: bool = true,
//!         difficulty: enum { easy, normal, hard } = .normal,
//!         // Optional: a line under each field in the Preferences window.
//!         pub const descriptions = .{ .volume = "How loud the game is, 0 to 1." };
//!     };
//!
//!     const prefs = app.preferences(Preferences);
//!
//! Fields are bools, integers, floats or enums, each with a default.
const std = @import("std");

/// A field's kind, as the Preferences window edits it.
pub const Kind = enum(u8) { bool, int, float, @"enum" };

/// What the Preferences window needs to show and edit one field.
pub const Field = struct {
    name: [:0]const u8,
    kind: Kind,
    /// The default, as a ZON literal (`0.8`, `true`, `.normal`).
    default: [:0]const u8,
    /// An enum's values, in order; empty otherwise.
    options: []const [:0]const u8 = &.{},
    description: [:0]const u8 = "",
};

/// The preferences a plugin declares: its key and fields. The key names whose they are, and their
/// file (`plugins/<key>.zon`): `game` for the game's, a plugin module's name for a plugin's
/// (`addGame` works them out), and `editor` for the editor's own.
pub const Manifest = struct {
    key: [:0]const u8,
    fields: []const Field,
};

/// The manifest of `T`, a `Preferences` struct, kept under `key`.
pub fn manifest(comptime T: type, comptime key: [:0]const u8) Manifest {
    return comptime .{ .key = key, .fields = fieldsOf(T) };
}

/// A number only `T` has in this program, for `Store.register`. (`@typeName` won't do: it names
/// types after their file, so every plugin package's `root.zig` would collide.)
const typeMarker = @import("type_marker.zig").of;

fn fieldsOf(comptime T: type) []const Field {
    const struct_fields = @typeInfo(T).@"struct".fields;
    var fields: [struct_fields.len]Field = undefined;
    for (struct_fields, &fields) |struct_field, *field| {
        const default = struct_field.defaultValue() orelse @compileError("preference `" ++ struct_field.name ++ "` needs a default");
        field.* = .{ .name = struct_field.name, .kind = undefined, .default = undefined };
        switch (@typeInfo(struct_field.type)) {
            .bool => {
                field.kind = .bool;
                field.default = if (default) "true" else "false";
            },
            .int => {
                field.kind = .int;
                field.default = std.fmt.comptimePrint("{d}", .{default});
            },
            .float => {
                field.kind = .float;
                field.default = std.fmt.comptimePrint("{d}", .{default});
            },
            .@"enum" => |info| {
                field.kind = .@"enum";
                field.default = "." ++ @tagName(default);
                var options: [info.fields.len][:0]const u8 = undefined;
                for (info.fields, &options) |tag, *option| option.* = tag.name;
                const frozen = options;
                field.options = &frozen;
            },
            else => @compileError("preference `" ++ struct_field.name ++ "` must be a bool, integer, float or enum"),
        }
        if (@hasDecl(T, "descriptions") and @hasField(@TypeOf(T.descriptions), struct_field.name)) {
            field.description = @field(T.descriptions, struct_field.name);
        }
    }
    const frozen = fields;
    return &frozen;
}

/// One file's values: field name to its ZON literal.
pub const Values = std.StringArrayHashMapUnmanaged([]const u8);

/// Values by key, in layers: `global` under `project`. Owns its text.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    layers: [2]std.StringHashMapUnmanaged(Values) = .{ .empty, .empty },
    /// Each registered `Preferences` type's key, by `typeMarker`.
    keys: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,

    pub const Layer = enum(u1) { global, project };

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    /// Keep `T`'s values under `key` from now on (see `Manifest`). `eggy.plugins.Set` registers
    /// each plugin's `Preferences` as it starts them.
    pub fn register(self: *Store, comptime T: type, key: []const u8) !void {
        try self.keys.put(self.arena.allocator(), typeMarker(T), try self.arena.allocator().dupe(u8, key));
    }

    /// Forget every registered type: their code is about to be unloaded (the editor swapping
    /// the game).
    pub fn forgetTypes(self: *Store) void {
        self.keys.clearRetainingCapacity();
    }

    /// `T`'s values: its defaults, overridden by the global layer, then the project's. A value
    /// that doesn't parse as its field's type keeps the default, and so does every field of a
    /// type never registered.
    pub fn get(self: *const Store, comptime T: type) T {
        const key = self.keys.get(typeMarker(T)) orelse return .{};
        return self.getKeyed(T, key);
    }

    /// `T`'s values kept under `key`, as `get` finds them, for a type with a known key (the
    /// editor's own) rather than a registered one.
    pub fn getKeyed(self: *const Store, comptime T: type, key: []const u8) T {
        var result: T = .{};
        for (self.layers) |layer| {
            const values = layer.get(key) orelse continue;
            inline for (@typeInfo(T).@"struct".fields) |field| if (values.get(field.name)) |text| {
                if (parseField(T, field.name, text)) |value| @field(result, field.name) = value;
            };
        }
        return result;
    }

    /// The literal `layer` gives `field` of `key`, if it sets one.
    pub fn literal(self: *const Store, layer: Layer, key: []const u8, field: []const u8) ?[]const u8 {
        const values = self.layers[@intFromEnum(layer)].get(key) orelse return null;
        return values.get(field);
    }

    /// Set `field` of `key` in `layer` to `value` (a ZON literal), or clear it with null.
    pub fn set(self: *Store, layer: Layer, key: []const u8, field: []const u8, value: ?[]const u8) !void {
        const allocator = self.arena.allocator();
        const entry = try self.layers[@intFromEnum(layer)].getOrPut(allocator, key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, key);
            entry.value_ptr.* = .empty;
        }
        if (value) |text| {
            const field_entry = try entry.value_ptr.getOrPut(allocator, field);
            if (!field_entry.found_existing) field_entry.key_ptr.* = try allocator.dupe(u8, field);
            field_entry.value_ptr.* = try allocator.dupe(u8, text);
        } else _ = entry.value_ptr.orderedRemove(field);
    }

    /// Read `source` (a ZON struct of `field = value`) as `key`'s values in `layer`, replacing
    /// what it had. Fails with `error.ParseZon` if it isn't one.
    pub fn read(self: *Store, layer: Layer, key: []const u8, source: [:0]const u8) !void {
        const gpa = self.arena.child_allocator;
        var ast = try std.zig.Ast.parse(gpa, source, .zon);
        defer ast.deinit(gpa);
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        defer zoir.deinit(gpa);
        if (zoir.hasCompileErrors()) return error.ParseZon;
        if (self.layers[@intFromEnum(layer)].getPtr(key)) |values| values.clearRetainingCapacity();
        switch (std.zig.Zoir.Node.Index.root.get(zoir)) {
            .empty_literal => {},
            .struct_literal => |fields| for (fields.names, 0..) |name, i| {
                const value: std.zig.Zoir.Node.Index = @enumFromInt(@intFromEnum(fields.vals.start) + i);
                try self.set(layer, key, name.get(zoir), ast.getNodeSource(value.getAstNode(zoir)));
            },
            else => return error.ParseZon,
        }
    }

    /// `key`'s values in `layer` as a ZON file, its fields in the order they were set.
    pub fn write(self: *const Store, layer: Layer, key: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll(".{\n");
        if (self.layers[@intFromEnum(layer)].get(key)) |values| {
            var it = values.iterator();
            while (it.next()) |entry| try writer.print("    .{f} = {s},\n", .{ std.zig.fmtId(entry.key_ptr.*), entry.value_ptr.* });
        }
        try writer.writeAll("}\n");
    }
};

/// `literal` parsed as field `name` of `T`; null if it isn't one.
fn parseField(comptime T: type, comptime name: []const u8, literal: []const u8) ?@FieldType(T, name) {
    var source_buffer: [512]u8 = undefined;
    const source = std.fmt.bufPrintZ(&source_buffer, ".{{ .{f} = {s} }}", .{ std.zig.fmtId(name), literal }) catch return null;
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.zon.parse.fromSlice(T, fba.allocator(), source, null, .{}) catch return null;
    return @field(parsed, name);
}

const Example = struct {
    volume: f32 = 0.8,
    show_gizmos: bool = true,
    difficulty: enum { easy, normal, hard } = .normal,
    pub const descriptions = .{ .volume = "How loud." };
};

test "a manifest lists each field with its kind, default and description" {
    const m = manifest(Example, "example");
    try std.testing.expectEqualStrings("example", m.key);
    try std.testing.expectEqual(@as(usize, 3), m.fields.len);
    try std.testing.expectEqual(Kind.float, m.fields[0].kind);
    try std.testing.expectEqualStrings("0.8", m.fields[0].default);
    try std.testing.expectEqualStrings("How loud.", m.fields[0].description);
    try std.testing.expectEqualStrings(".normal", m.fields[2].default);
    try std.testing.expectEqualStrings("hard", m.fields[2].options[2]);
}

test "project values override global ones, which override defaults, and bad ones are skipped" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const key = "example";
    try std.testing.expectEqual(@as(f32, 0.8), store.get(Example).volume); // not registered yet
    try store.register(Example, key);
    try store.read(.global, key, ".{ .volume = 0.5, .difficulty = .hard }");
    try store.read(.project, key, ".{ .volume = 0.25, .show_gizmos = \"yes\" }");
    const prefs = store.get(Example);
    try std.testing.expectEqual(@as(f32, 0.25), prefs.volume);
    try std.testing.expect(prefs.show_gizmos); // "yes" isn't a bool: the default stays
    try std.testing.expectEqual(.hard, prefs.difficulty);

    try store.set(.project, key, "volume", null);
    try std.testing.expectEqual(@as(f32, 0.5), store.get(Example).volume);
}

test "values written out read back the same" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.set(.project, "game", "volume", "0.3");
    try store.set(.project, "game", "difficulty", ".easy");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try store.write(.project, "game", &out.writer);
    try std.testing.expectEqualStrings(".{\n    .volume = 0.3,\n    .difficulty = .easy,\n}\n", out.written());
    const written = try std.testing.allocator.dupeZ(u8, out.written());
    defer std.testing.allocator.free(written);
    var again = Store.init(std.testing.allocator);
    defer again.deinit();
    try again.read(.project, "game", written);
    try std.testing.expectEqualStrings(".easy", again.literal(.project, "game", "difficulty").?);
}
