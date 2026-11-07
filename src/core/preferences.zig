//! Preferences: settings a plugin (or the editor) declares as a struct of defaults, which people
//! change in the editor's Settings window and which are kept as ZON. Values come in layers,
//! each overriding the one below: the struct's defaults, the user's global preferences (the
//! editor's own only), then the project's (`.eggy/`). A plugin's are the project's, which the
//! runtime gets baked in when the game is built.
//!
//!     pub const Preferences = struct {
//!         volume: f32 = 0.8,
//!         show_gizmos: bool = true,
//!         difficulty: enum { easy, normal, hard } = .normal,
//!         // Optional: a line under each field in the Settings window.
//!         pub const descriptions = .{ .volume = "How loud the game is, 0 to 1." };
//!         // Optional: which fields share a card there, in order; unlisted ones come last.
//!         pub const groups = .{ .{ "volume", "difficulty" }, .{"show_gizmos"} };
//!         // Optional: fields only the global layer sets, which a project can't override.
//!         pub const global_only = .{"update_source"};
//!     };
//!
//!     const prefs = app.preferences(Preferences);
//!
//! Fields are bools, integers, floats, enums or strings (`[]const u8`), each with a default.
const std = @import("std");
const zon_file = @import("eggy_assets").zon;

/// A field's kind, as the Settings window edits it.
pub const Kind = enum(u8) { bool, int, float, @"enum", string };

/// Which layers may set a field.
pub const Scope = enum(u8) {
    /// The global layer, overridden by the project's.
    any,
    /// The global layer alone: a value the project's layer gives it is ignored.
    global_only,
};

/// What the Settings window needs to show and edit one field.
pub const Field = struct {
    name: [:0]const u8,
    kind: Kind,
    /// The default, as a ZON literal (`0.8`, `true`, `.normal`, `"main"`).
    default: [:0]const u8,
    /// An enum's values, in order; empty otherwise.
    options: []const [:0]const u8 = &.{},
    description: [:0]const u8 = "",
    /// Which card it shares in the Settings window: its index in the struct's `groups`.
    group: u8 = 0,
    scope: Scope = .any,
};

/// The preferences a plugin declares: its key and fields. The key names whose they are, and their
/// file (`plugins/<key>.zon`): `game` for the game's, a plugin module's name for a plugin's
/// (`addGame` works them out), and `editor` for the editor's own.
pub const Manifest = struct {
    key: [:0]const u8,
    fields: []const Field,
};

/// The manifest of `T`, a `Preferences` struct, kept under `key`.
/// Host-only metadata: fields must be defaulted bools, integers, floats, enums or strings.
/// The returned names/literals have static lifetime and require no allocator.
///
/// ```zig
/// const Settings = struct { volume: f32 = 0.8 };
/// const info = manifest(Settings, "game");
/// ```
pub fn manifest(comptime T: type, comptime key: [:0]const u8) Manifest {
    return comptime .{ .key = key, .fields = fieldsOf(T) };
}

/// A number only `T` has in this program, for `Store.register`. (`@typeName` won't do: it names
/// types after their file, so every plugin package's `root.zig` would collide.)
const typeMarker = @import("type_marker.zig").of;

fn fieldsOf(comptime T: type) []const Field {
    const info = @typeInfo(T).@"struct";
    var fields: [info.field_names.len]Field = undefined;
    for (info.field_names, info.field_types, info.field_attrs, &fields) |name, FieldType, attrs, *field| {
        const default = attrs.defaultValue(FieldType) orelse @compileError("preference `" ++ name ++ "` needs a default");
        field.* = .{ .name = name, .kind = undefined, .default = undefined };
        switch (@typeInfo(FieldType)) {
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
            .@"enum" => |enum_info| {
                field.kind = .@"enum";
                field.default = "." ++ @tagName(default);
                field.options = enum_info.field_names;
            },
            else => if (FieldType == []const u8) {
                field.kind = .string;
                field.default = std.fmt.comptimePrint("\"{f}\"", .{std.zig.fmtString(default)});
            } else @compileError("preference `" ++ name ++ "` must be a bool, integer, float, enum or []const u8"),
        }
        if (@hasDecl(T, "descriptions") and @hasField(@TypeOf(T.descriptions), name)) {
            field.description = @field(T.descriptions, name);
        }
        field.group = groupOf(T, name);
        field.scope = scopeOf(T, name);
    }
    const frozen = fields;
    return &frozen;
}

/// The index of the group in `T.groups` that lists `name`; one past the last for a field none
/// lists, and 0 when `T` declares no groups.
fn groupOf(comptime T: type, comptime name: []const u8) u8 {
    if (!@hasDecl(T, "groups")) return 0;
    inline for (T.groups, 0..) |group, index| {
        inline for (group) |member| if (comptime std.mem.eql(u8, member, name)) return index;
    }
    return T.groups.len;
}

/// Whether `T.global_only` lists `name`.
fn scopeOf(comptime T: type, comptime name: []const u8) Scope {
    if (!@hasDecl(T, "global_only")) return .any;
    inline for (T.global_only) |member| if (comptime std.mem.eql(u8, member, name)) return .global_only;
    return .any;
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

    /// Host-only: create an empty layered store backed by an owned arena using `gpa`.
    /// Pair with `deinit`; no preferences files are read automatically.
    ///
    /// ```zig
    /// var store = Store.init(gpa);
    /// defer store.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .arena = .init(gpa) };
    }

    /// Host-only: free all copied keys, literals and type registrations.
    /// Every slice borrowed from this store becomes invalid; do not deinitialize twice.
    ///
    /// ```zig
    /// var store = Store.init(gpa);
    /// defer store.deinit();
    /// ```
    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    /// Keep `T`'s values under `key` from now on (see `Manifest`). `eggy.plugins.Set` registers
    /// each plugin's `Preferences` as it starts them.
    /// Host-only: copies the key into the arena; allocation failures propagate.
    ///
    /// ```zig
    /// const Settings = struct { volume: f32 = 0.8 };
    /// try store.register(Settings, "game");
    /// ```
    pub fn register(self: *Store, comptime T: type, key: []const u8) !void {
        try self.keys.put(self.arena.allocator(), typeMarker(T), try self.arena.allocator().dupe(u8, key));
    }

    /// Forget every registered type: their code is about to be unloaded (the editor swapping
    /// the game).
    /// Host-only: preserves layered text so rebuilt types can register against it again.
    ///
    /// ```zig
    /// // Before unloading the game library:
    /// store.forgetTypes();
    /// ```
    pub fn forgetTypes(self: *Store) void {
        self.keys.clearRetainingCapacity();
    }

    /// `T`'s values: its defaults, overridden by the global layer, then the project's (except
    /// for fields `T.global_only` lists). A value that doesn't parse as its field's type keeps the
    /// lower layer's value (or default). A type never registered gets all defaults. String
    /// fields borrow the store's text, valid until `deinit`.
    /// Games normally use `app.preferences(T)` instead.
    ///
    /// ```zig
    /// const Settings = struct { volume: f32 = 0.8 };
    /// const settings = store.get(Settings);
    /// ```
    pub fn get(self: *const Store, comptime T: type) T {
        const key = self.keys.get(typeMarker(T)) orelse return .{};
        return self.getKeyed(T, key);
    }

    /// `T`'s values kept under `key`, as `get` finds them, for a type with a known key (the
    /// editor's own) rather than a registered one.
    /// Host-only: invalid literals leave lower-layer values unchanged; does not register `T`.
    /// String fields borrow the store's text, valid until `deinit`.
    ///
    /// ```zig
    /// const Settings = struct { volume: f32 = 0.8 };
    /// const settings = store.getKeyed(Settings, "editor");
    /// ```
    pub fn getKeyed(self: *const Store, comptime T: type, key: []const u8) T {
        var result: T = .{};
        for (self.layers, 0..) |layer, index| {
            const values = layer.get(key) orelse continue;
            inline for (@typeInfo(T).@"struct".field_names) |name| if (values.get(name)) |text| {
                const ignored = index == @backingInt(Layer.project) and comptime scopeOf(T, name) == .global_only;
                if (!ignored) if (parseField(T, name, text)) |value| {
                    @field(result, name) = value;
                };
            };
        }
        return result;
    }

    /// The literal `layer` gives `field` of `key`, if it sets one.
    /// Host-only: the returned text is borrowed until store deinitialization; no fallback
    /// to other layers or type validation is performed.
    ///
    /// ```zig
    /// const explicit_volume = store.literal(.project, "game", "volume");
    /// ```
    pub fn literal(self: *const Store, layer: Layer, key: []const u8, field: []const u8) ?[]const u8 {
        const values = self.layers[@backingInt(layer)].get(key) orelse return null;
        return values.get(field);
    }

    /// Set `field` of `key` in `layer` to `value` (a ZON literal), or clear it with null.
    /// Host-only: copies text, but does not validate it or write to disk. Arena allocation
    /// failures propagate; typed reads ignore literals they cannot parse.
    ///
    /// ```zig
    /// try store.set(.project, "game", "volume", "0.5");
    /// try store.set(.project, "game", "volume", null); // Reveal the lower layer.
    /// ```
    pub fn set(self: *Store, layer: Layer, key: []const u8, field: []const u8, value: ?[]const u8) !void {
        const allocator = self.arena.allocator();
        const entry = try self.layers[@backingInt(layer)].getOrPut(allocator, key);
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
    /// Host-only: copies literals into the store; `source` need not outlive the call.
    /// Not transactional: a bad root or allocation failure can leave previous values cleared
    /// or partially replaced. Field types are checked only during typed reads.
    ///
    /// ```zig
    /// try store.read(.project, "game", ".{ .volume = 0.5 }");
    /// ```
    pub fn read(self: *Store, layer: Layer, key: []const u8, source: [:0]const u8) !void {
        const gpa = self.arena.child_allocator;
        var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
        defer ast.deinit(gpa);
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        defer zoir.deinit(gpa);
        if (zoir.hasCompileErrors()) return error.ParseZon;
        if (self.layers[@backingInt(layer)].getPtr(key)) |values| values.clearRetainingCapacity();
        switch (std.zig.Zoir.Node.Index.root.get(&zoir)) {
            .empty_literal => {},
            .struct_literal => |fields| for (fields.names, 0..) |name, i| {
                const value: std.zig.Zoir.Node.Index = @fromBackingInt(@intCast(@backingInt(fields.vals.start) + i));
                try self.set(layer, key, name.get(&zoir), ast.getNodeSource(value.getAstNode(&zoir)));
            },
            else => return error.ParseZon,
        }
    }

    /// `key`'s values in `layer` as a ZON file, its fields in the order they were set.
    /// Host-only: serializes only explicit literals, not defaults or lower layers. Borrows
    /// `writer` for the call and propagates write failures; does not flush or persist it.
    ///
    /// ```zig
    /// var text: std.Io.Writer.Allocating = .init(gpa);
    /// defer text.deinit();
    /// try store.write(.project, "game", &text.writer);
    /// ```
    pub fn write(self: *const Store, layer: Layer, key: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll(".{\n");
        if (self.layers[@backingInt(layer)].get(key)) |values| {
            var it = values.iterator();
            while (it.next()) |entry| try writer.print("    .{f} = {s},\n", .{ std.zig.fmtId(entry.key_ptr.*), entry.value_ptr.* });
        }
        try writer.writeAll("}\n");
    }
};

/// `literal` parsed as field `name` of `T`; null if it isn't one. A string borrows `literal`.
fn parseField(comptime T: type, comptime name: []const u8, literal: []const u8) ?@FieldType(T, name) {
    if (@FieldType(T, name) == []const u8) return stringValue(literal);
    var source_buffer: [512]u8 = undefined;
    const source = std.fmt.bufPrintSentinel(&source_buffer, ".{{ .{f} = {s} }}", .{ std.zig.fmtId(name), literal }, 0) catch return null;
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = zon_file.parse(T, fba.allocator(), source, .{}) catch return null;
    return @field(parsed, name);
}

/// The text of `literal`, a ZON string, borrowed from it; null for anything else.
/// ponytail: strings with escapes are refused, as unescaping needs memory `getKeyed` has none of; store the unescaped text if a preference ever needs quotes or backslashes.
pub fn stringValue(literal: []const u8) ?[]const u8 {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const text = literal[1 .. literal.len - 1];
    return if (std.mem.indexOfAny(u8, text, "\\\"\n") == null) text else null;
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

test "fields are grouped as the struct's groups list them, unlisted ones last" {
    const Grouped = struct {
        volume: f32 = 0.8,
        muted: bool = false,
        difficulty: enum { easy, hard } = .easy,
        pub const groups = .{ .{"difficulty"}, .{ "volume", "muted" } };
    };
    const m = manifest(Grouped, "grouped");
    try std.testing.expectEqual(@as(u8, 1), m.fields[0].group);
    try std.testing.expectEqual(@as(u8, 1), m.fields[1].group);
    try std.testing.expectEqual(@as(u8, 0), m.fields[2].group);
    try std.testing.expectEqual(@as(u8, 0), manifest(Example, "example").fields[0].group);
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
    const written = try std.testing.allocator.dupeSentinel(u8, out.written(), 0);
    defer std.testing.allocator.free(written);
    var again = Store.init(std.testing.allocator);
    defer again.deinit();
    try again.read(.project, "game", written);
    try std.testing.expectEqualStrings(".easy", again.literal(.project, "game", "difficulty").?);
}

test "string fields default and read as text, and global-only ones ignore the project" {
    const Sources = struct {
        update_source: []const u8 = "https://example.com/eggy#main",
        mirror: []const u8 = "",
        pub const global_only = .{"update_source"};
    };
    const m = manifest(Sources, "sources");
    try std.testing.expectEqual(Kind.string, m.fields[0].kind);
    try std.testing.expectEqualStrings("\"https://example.com/eggy#main\"", m.fields[0].default);
    try std.testing.expectEqual(Scope.global_only, m.fields[0].scope);
    try std.testing.expectEqual(Scope.any, m.fields[1].scope);

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.read(.global, "sources", ".{ .update_source = \"https://mine.example/eggy#dev\", .mirror = \"a\" }");
    try store.read(.project, "sources", ".{ .update_source = \"https://other.example/eggy\", .mirror = \"b\" }");
    const values = store.getKeyed(Sources, "sources");
    try std.testing.expectEqualStrings("https://mine.example/eggy#dev", values.update_source);
    try std.testing.expectEqualStrings("b", values.mirror);
    try std.testing.expect(stringValue("\"a\\\\b\"") == null);
    try std.testing.expect(stringValue(".main") == null);
}
