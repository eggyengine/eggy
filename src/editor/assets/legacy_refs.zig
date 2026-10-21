//! Turns the path references in a project's scene and material files into asset ids, so moving
//! or deleting a file can't leave a file that was never opened pointing at nothing.
//!
//! A scene is read through the game's component types: only the parts the types say are asset
//! references are rewritten, never other strings. A reference that can't be turned into an id
//! (an unknown asset, the wrong kind of file, a component the game doesn't have) is reported and
//! nothing is written, so the caller can refuse the move.
const std = @import("std");
const eggy = @import("eggy");
const assets = eggy.assets;
const components = eggy.components;
const Scene = eggy.scene.Scene;
const field_value = @import("../entities/field_value.zig");
const Value = field_value.Value;
const Node = field_value.Node;
const ProjectAssets = @import("project_assets.zig").ProjectAssets;
const fixtures = @import("project_fixtures.zig");

/// A file to replace with `text`, which means what the file did with its references as ids.
pub const Rewrite = struct { path: []const u8, text: []const u8 };

/// What making the references identities needs: the files to write, or why it can't be done.
pub const Plan = struct {
    rewrites: []const Rewrite = &.{},
    /// A sentence for the user naming the file, entity and field; null when the plan is sound.
    problem: ?[]const u8 = null,
};

/// Work out every rewrite in the project's scene and material files without writing any.
/// `types` are the game's component types (empty without a game library, which then refuses any
/// scene whose strings name project files). All results live in `arena`; `gpa` is scratch.
/// A path that names no project file is left as it is: it was dangling before the move.
///
/// ```zig
/// const plan = try legacy_refs.plan(gpa, arena, io, project_dir, project_assets, types);
/// if (plan.problem) |why| return showToUser(why);
/// ```
pub fn plan(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir, provider: *ProjectAssets, types: []const components.Info) !Plan {
    var migration: Migration = .{ .gpa = gpa, .arena = arena, .provider = provider, .types = types };
    var rewrites: std.ArrayList(Rewrite) = .empty;
    for (try provider.pathsOfKind(arena, .scene)) |path| {
        const text = try project.readFileAllocOptions(io, path, arena, .limited(64 << 20), .of(u8), 0);
        migration.file = path;
        const rewritten = migration.scene(text) catch |err| switch (err) {
            error.Unmigratable => return .{ .problem = migration.problem },
            else => |other| return other,
        };
        if (rewritten) |changed| try rewrites.append(arena, .{ .path = path, .text = changed });
    }
    for (try provider.pathsOfKind(arena, .material)) |path| {
        const text = try project.readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0);
        migration.file = path;
        const rewritten = migration.material(text) catch |err| switch (err) {
            error.Unmigratable => return .{ .problem = migration.problem },
            else => |other| return other,
        };
        if (rewritten) |changed| try rewrites.append(arena, .{ .path = path, .text = changed });
    }
    return .{ .rewrites = rewrites.items };
}

/// Write the files of `rewrites`, each replaced whole (a half-written file is never seen).
/// A failure leaves the files before it rewritten; they still mean the same as before.
pub fn apply(io: std.Io, project: std.Io.Dir, rewrites: []const Rewrite) !void {
    for (rewrites) |rewrite| {
        var atomic = try project.createFileAtomic(io, rewrite.path, .{ .replace = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        writer.interface.writeAll(rewrite.text) catch return writer.err.?;
        writer.interface.flush() catch return writer.err.?;
        try atomic.file.sync(io);
        try atomic.replace(io);
    }
}

/// `plan` then `apply`: null when every reference is now an id (or already was), else the
/// problem, with nothing written. Call before a move or delete of `resources/` files.
///
/// ```zig
/// if (try legacy_refs.normalize(gpa, arena, io, dir, provider, types)) |why| return toast(why);
/// ```
pub fn normalize(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir, provider: *ProjectAssets, types: []const components.Info) !?[]const u8 {
    const made = try plan(gpa, arena, io, project, provider, types);
    if (made.problem) |why| return why;
    try apply(io, project, made.rewrites);
    return null;
}

/// `normalize` for the project in `project_dir` as it opens, before any scene loads: a scene that
/// can't be loaded with paths (a bare clip name needs its entity's model) keeps what it meant.
/// Failures and refusals are logged; files are then left as they were.
pub fn normalizeOnOpen(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8, provider: *ProjectAssets, types: []const components.Info) void {
    var project = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch |err| return std.log.warn("cannot open the project to update its references: {t}", .{err});
    defer project.close(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const made = plan(gpa, arena_state.allocator(), io, project, provider, types) catch |err| return std.log.warn("cannot read the project's references: {t}", .{err});
    if (made.problem) |why| return std.log.warn("references left as paths: {s}", .{why});
    if (made.rewrites.len == 0) return;
    apply(io, project, made.rewrites) catch |err| return std.log.err("cannot write the project's references as ids: {t}", .{err});
    std.log.info("{d} scene and material files now refer to assets by id", .{made.rewrites.len});
}

/// One asset reference found in a field's text.
const Leaf = struct { node: Node, accepts: assets.Kind, string: []const u8 };

const Edit = struct { node: Node, text: []const u8 };

const Migration = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    provider: *ProjectAssets,
    types: []const components.Info,
    file: []const u8 = "",
    problem: []const u8 = "",

    const Error = error{ Unmigratable, OutOfMemory } || std.Io.Writer.Error;

    fn fail(self: *Migration, comptime format: []const u8, args: anytype) error{ Unmigratable, OutOfMemory } {
        const detail = try std.fmt.allocPrint(self.arena, format, args);
        self.problem = try std.fmt.allocPrint(self.arena, "{s}: {s}. Open and save the file after fixing it, then move again.", .{ self.file, detail });
        return error.Unmigratable;
    }

    /// The scene's text with its references as ids; null when it needs no change.
    fn scene(self: *Migration, text: [:0]const u8) Error!?[]const u8 {
        var parsed = Scene.parse(self.gpa, text) catch return self.fail("the scene can't be read", .{});
        defer parsed.deinit();
        var changed = false;
        for (parsed.entities) |each| {
            if (try self.entity(each)) changed = true;
        }
        if (!changed) return null;
        var out: std.Io.Writer.Allocating = .init(self.arena);
        try parsed.write(&out.writer);
        return out.written();
    }

    /// Rewrite the references of one entity's component fields; whether any changed.
    fn entity(self: *Migration, entity_scene: Scene.Entity) Error!bool {
        var found: std.ArrayList(Found) = .empty;
        for (entity_scene.components, 0..) |component, component_index| {
            const info = self.typeOf(component);
            for (component.fields, 0..) |field, field_index| {
                const value = Value.parse(self.arena, field.value) orelse
                    return self.fail("{s}.{s} of \"{s}\" isn't valid ZON", .{ component.type, field.name, entity_scene.name });
                const field_info = if (info) |known| fieldOf(known, field.name) else null;
                var leaves: std.ArrayList(Leaf) = .empty;
                if (field_info) |known| {
                    try self.collect(&leaves, &value, .root, known.parts, 0, entity_scene.name, component.type, field.name);
                } else if (self.holdsPath(&value, .root)) {
                    return self.fail("{s}.{s} of \"{s}\" holds a project path, but the game has no such component field to read it with", .{ component.type, field.name, entity_scene.name });
                }
                for (leaves.items) |leaf| try found.append(self.arena, .{ .component = component_index, .field = field_index, .leaf = leaf, .value = value });
            }
        }
        if (found.items.len == 0) return false;

        // Paths first; then a bare clip name is read against the model those paths gave.
        var model_key: ?[]const u8 = null;
        const edits = try self.arena.alloc(?[]const u8, found.items.len);
        for (found.items, edits) |item, *edit| {
            edit.* = try self.byPath(item, entity_scene.name, entity_scene.components);
            const key = edit.* orelse item.leaf.string;
            if (item.leaf.accepts == .model and key.len == assets.id.key_len) model_key = key;
        }
        for (found.items, edits) |item, *edit| {
            if (edit.* != null or !self.needsName(item.leaf)) continue;
            edit.* = try self.byClipName(item, model_key, entity_scene.name, entity_scene.components);
        }

        // Splice each field's new keys into its text.
        var changed = false;
        for (entity_scene.components, 0..) |component, component_index| {
            for (component.fields, 0..) |_, field_index| {
                var splices: std.ArrayList(Edit) = .empty;
                var value: ?Value = null;
                for (found.items, edits) |item, edit| {
                    if (item.component != component_index or item.field != field_index) continue;
                    const key = edit orelse continue;
                    value = item.value;
                    try splices.append(self.arena, .{ .node = item.leaf.node, .text = try std.fmt.allocPrint(self.arena, "\"{s}\"", .{key}) });
                }
                if (splices.items.len == 0) continue;
                // The scene owns this text in an arena this migration is the only user of.
                @constCast(component.fields)[field_index].value = try splice(self.arena, &value.?, splices.items);
                changed = true;
            }
        }
        return changed;
    }

    const Found = struct { component: usize, field: usize, leaf: Leaf, value: Value };

    fn typeOf(self: *Migration, component: Scene.Component) ?components.Info {
        for (self.types) |info| {
            if (std.mem.eql(u8, info.name, component.type) and std.mem.eql(u8, info.owner, component.owner)) return info;
        }
        return null;
    }

    fn fieldOf(info: components.Info, name: []const u8) ?components.Field {
        for (info.fields) |field| if (std.mem.eql(u8, field.name, name)) return field;
        return null;
    }

    /// Find the asset references of the value at `node`, which has the type `parts[index]`.
    fn collect(self: *Migration, leaves: *std.ArrayList(Leaf), value: *const Value, node: Node, parts: []const components.Part, index: usize, entity_name: []const u8, component: []const u8, field: []const u8) Error!void {
        const part = parts[index];
        switch (part.kind) {
            .asset => switch (value.get(node)) {
                .string_literal => |string| try leaves.append(self.arena, .{ .node = node, .accepts = part.accepts, .string = string }),
                else => return self.fail("{s}.{s} of \"{s}\" holds an asset reference that isn't text", .{ component, field, entity_name }),
            },
            .@"struct" => for (part.children(parts), 0..) |inner, i| {
                const inner_node = value.field(node, std.mem.span(inner.name)) orelse continue;
                try self.collect(leaves, value, inner_node, parts, part.first + i, entity_name, component, field);
            },
            .@"union" => {
                const chosen = value.variant(node) orelse return;
                const payload = chosen.payload orelse return;
                for (part.children(parts), 0..) |variant, i| {
                    if (!std.mem.eql(u8, std.mem.span(variant.name), chosen.tag)) continue;
                    try self.collect(leaves, value, payload, parts, part.first + i, entity_name, component, field);
                }
            },
            .array => {
                var i: usize = 0;
                while (value.child(node, i)) |element| : (i += 1) try self.collect(leaves, value, element, parts, part.first, entity_name, component, field);
            },
            .optional => switch (value.get(node)) {
                .null => {},
                else => try self.collect(leaves, value, node, parts, part.first, entity_name, component, field),
            },
            .bool, .int, .float, .@"enum", .vector, .color, .quaternion, .euler, .entity, .none, .other => {},
        }
    }

    /// Whether any string under `node` is the path of a catalogued file.
    fn holdsPath(self: *Migration, value: *const Value, node: Node) bool {
        switch (value.get(node)) {
            .string_literal => |string| return self.pathKey(string) != null,
            else => {},
        }
        var i: usize = 0;
        while (value.child(node, i)) |inner| : (i += 1) if (self.holdsPath(value, inner)) return true;
        return false;
    }

    /// Whether `string` (not an identity, not empty) names a catalogued file or model child.
    fn pathKey(self: *Migration, string: []const u8) ?assets.Id {
        if (string.len == 0 or isKey(string)) return null;
        const found = self.reference(string) orelse return null;
        return assets.id.parse(found.key()) catch null;
    }

    fn isKey(string: []const u8) bool {
        if (string.len != assets.id.key_len) return false;
        for (string) |byte| if (!std.ascii.isHex(byte)) return false;
        return true;
    }

    /// The asset `string` names as a project path, with or without its `resources/` folder; a
    /// model's clips are found by opening the model.
    fn reference(self: *Migration, string: []const u8) ?@import("reference.zig").Reference {
        if (self.referenceExact(string)) |found| return found;
        const full = std.fmt.allocPrint(self.arena, "resources/{s}", .{string}) catch return null;
        return self.referenceExact(full);
    }

    fn referenceExact(self: *Migration, path: []const u8) ?@import("reference.zig").Reference {
        if (std.fs.path.dirname(path)) |parent| _ = self.provider.children(self.arena, parent) catch return null;
        return self.provider.referenceAt(path);
    }

    /// The key `item`'s path gives, null if it holds a key already, is unset or isn't a path.
    fn byPath(self: *Migration, item: Found, entity_name: []const u8, entity_components: []const Scene.Component) Error!?[]const u8 {
        const string = item.leaf.string;
        if (string.len == 0 or isKey(string)) return null;
        const found = self.reference(string) orelse return null;
        if (!found.fits(item.leaf.accepts)) {
            return self.fail("{s}.{s} of \"{s}\" holds {s}, which is {s}, not {s}", .{ entity_components[item.component].type, entity_components[item.component].fields[item.field].name, entity_name, string, @tagName(found.kind), @tagName(item.leaf.accepts) });
        }
        return try self.arena.dupe(u8, found.key());
    }

    /// Whether a leaf that no path explained may be a clip name an old Animator stored.
    fn needsName(self: *Migration, leaf: Leaf) bool {
        _ = self;
        return leaf.accepts == .animation and leaf.string.len > 0 and !isKey(leaf.string);
    }

    /// An imported clip of the entity's model, named by `item`'s string, as its key.
    fn byClipName(self: *Migration, item: Found, model_key: ?[]const u8, entity_name: []const u8, entity_components: []const Scene.Component) Error!?[]const u8 {
        const name = item.leaf.string;
        const field = entity_components[item.component];
        const model = model_key orelse
            return self.fail("{s}.{s} of \"{s}\" is \"{s}\", which is no asset, and the entity has no model to take it as a clip name of", .{ field.type, field.fields[item.field].name, entity_name, name });
        const model_path = self.provider.label(self.arena, model);
        const source = self.provider.idOf(model_path) orelse
            return self.fail("{s}.{s} of \"{s}\" is the clip name \"{s}\", but its model isn't in the project", .{ field.type, field.fields[item.field].name, entity_name, name });
        const wanted = assets.id.animation(source, name, 0);
        for (try self.provider.children(self.arena, model_path)) |child| {
            if (child.id != wanted) continue;
            var key: [assets.id.key_len]u8 = undefined;
            return try self.arena.dupe(u8, assets.id.key(&key, wanted));
        }
        return self.fail("{s}.{s} of \"{s}\" is \"{s}\", which is no clip of {s}", .{ field.type, field.fields[item.field].name, entity_name, name, model_path });
    }

    /// The material's text with its texture as an id; null when it needs no change.
    fn material(self: *Migration, text: [:0]const u8) Error!?[]const u8 {
        const value = Value.parse(self.arena, text) orelse return self.fail("the material can't be read", .{});
        const node = value.field(.root, "texture") orelse return null;
        const string = switch (value.get(node)) {
            .string_literal => |string| string,
            else => return self.fail("the material's texture isn't text", .{}),
        };
        if (string.len == 0 or isKey(string)) return null;
        const found = self.reference(string) orelse return self.fail("the texture \"{s}\" isn't a project asset", .{string});
        if (!found.fits(.image)) return self.fail("the texture \"{s}\" is {s}, not an image", .{ string, @tagName(found.kind) });
        const replacement = try std.fmt.allocPrint(self.arena, "\"{s}\"", .{found.key()});
        return try value.replace(self.arena, node, replacement);
    }
};

/// `value`'s text with each edit's node replaced; the edits mustn't hold one another.
fn splice(arena: std.mem.Allocator, value: *const Value, edits: []Edit) ![]const u8 {
    // From the last in the text to the first, so earlier offsets stay put.
    const Order = struct {
        fn later(value_of: *const Value, a: Edit, b: Edit) bool {
            return @intFromPtr(value_of.text(a.node).ptr) > @intFromPtr(value_of.text(b.node).ptr);
        }
    };
    std.mem.sort(Edit, edits, value, Order.later);
    var result: []const u8 = value.source;
    for (edits) |edit| {
        const old = value.text(edit.node);
        const start = @intFromPtr(old.ptr) - @intFromPtr(value.source.ptr);
        result = try std.mem.concat(arena, u8, &.{ result[0..start], edit.text, result[start + old.len ..] });
    }
    return result;
}

const Shot = struct {
    name: eggy.AssetRef(.image) = .{},
    model: eggy.AssetRef(.model) = .{},
    clip: eggy.AssetRef(.animation) = .{},
    skins: [2]eggy.AssetRef(.image) = .{ .{}, .{} },
    label: []const u8 = "",
};
const test_types = components.Registry(&.{Shot}, &.{"game"}).infos;

const Setup = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    fixture: fixtures.Fixture,
    project: ProjectAssets,
    arena_state: std.heap.ArenaAllocator,

    fn open() !*Setup {
        const gpa = std.testing.allocator;
        const self = try gpa.create(Setup);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.io = std.testing.io;
        self.fixture = try fixtures.Fixture.open(gpa, self.io);
        errdefer self.fixture.close(gpa, self.io);
        try self.fixture.dir.createDirPath(self.io, "resources");
        try self.fixture.dir.writeFile(self.io, .{ .sub_path = "resources/face.gltf", .data = fixtures.smiling_triangle });
        try self.fixture.dir.writeFile(self.io, .{ .sub_path = "resources/wood.png", .data = "png" });
        self.arena_state = .init(gpa);
        errdefer self.arena_state.deinit();
        self.project = try ProjectAssets.init(gpa, self.io, self.fixture.path);
        return self;
    }

    fn close(self: *Setup) void {
        self.project.deinit();
        self.arena_state.deinit();
        self.fixture.close(self.gpa, self.io);
        self.gpa.destroy(self);
    }

    fn write(self: *Setup, path: []const u8, text: []const u8) !void {
        try self.fixture.dir.writeFile(self.io, .{ .sub_path = path, .data = text });
        _ = try self.project.sync();
    }

    fn read(self: *Setup, path: []const u8) ![]u8 {
        return self.fixture.dir.readFileAlloc(self.io, path, self.arena_state.allocator(), .limited(1 << 20));
    }
};

test "a scene that was never opened has its paths turned into ids, and nothing else" {
    var setup = try Setup.open();
    defer setup.close();
    const arena = setup.arena_state.allocator();
    try setup.write("resources/level.scene.zon",
        \\.{ .entities = .{ .{ .name = "wood.png", .parent = null, .components = .{
        \\    .{ .type = "Shot", .owner = "game", .fields = .{ .name = "resources/wood.png", .model = "resources/face.gltf", .clip = "resources/face.gltf/smile", .skins = .{ "wood.png", "" }, .label = "resources/wood.png" } },
        \\} } } }
    );
    var wood_key: [assets.id.key_len]u8 = undefined;
    _ = setup.project.keyOf(&wood_key, "resources/wood.png").?;

    const problem = try normalize(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types);
    try std.testing.expectEqual(@as(?[]const u8, null), problem);

    // Asset leaves (also in arrays, with or without `resources/`) became ids; the label stayed text.
    const saved = try setup.read("resources/level.scene.zon");
    var parsed = try Scene.parse(setup.gpa, try arena.dupeZ(u8, saved));
    defer parsed.deinit();
    const fields = parsed.entities[0].components[0].fields;
    const expected_name = try std.fmt.allocPrint(arena, "\"{s}\"", .{wood_key});
    try std.testing.expectEqualStrings(expected_name, fields[0].value);
    try std.testing.expectEqual(assets.id.key_len + 2, fields[1].value.len);
    try std.testing.expectEqual(assets.id.key_len + 2, fields[2].value.len);
    try std.testing.expect(std.mem.indexOf(u8, fields[3].value, &wood_key) != null);
    try std.testing.expectEqualStrings("\"resources/wood.png\"", fields[4].value);
    try std.testing.expectEqualStrings("wood.png", parsed.entities[0].name);

    // The ids survive the file moving, and a second pass has nothing to do.
    try setup.fixture.dir.createDirPath(setup.io, "resources/art");
    try setup.fixture.dir.rename("resources/wood.png", setup.fixture.dir, "resources/art/wood.png", setup.io);
    setup.project.moved("resources/wood.png", "resources/art/wood.png");
    try std.testing.expectEqualStrings(&wood_key, setup.project.keyOf(&wood_key, "resources/art/wood.png").?);
    const again = try plan(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types);
    try std.testing.expectEqual(@as(usize, 0), again.rewrites.len);
}

test "a bare clip name is read against the model of the same entity" {
    var setup = try Setup.open();
    defer setup.close();
    const arena = setup.arena_state.allocator();
    try setup.write("resources/level.scene.zon",
        \\.{ .entities = .{ .{ .name = "face", .parent = null, .components = .{
        \\    .{ .type = "Shot", .owner = "game", .fields = .{ .model = "resources/face.gltf", .clip = "smile" } },
        \\} } } }
    );
    const made = try plan(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types);
    try std.testing.expectEqual(@as(?[]const u8, null), made.problem);
    try std.testing.expectEqual(@as(usize, 1), made.rewrites.len);
    var parsed = try Scene.parse(setup.gpa, try arena.dupeZ(u8, made.rewrites[0].text));
    defer parsed.deinit();
    const smile = setup.project.referenceAt("resources/face.gltf/smile").?;
    const expected = try std.fmt.allocPrint(arena, "\"{s}\"", .{smile.key()});
    try std.testing.expectEqualStrings(expected, parsed.entities[0].components[0].fields[1].value);
}

test "opening a project keeps a bare clip name by turning it into the clip's id" {
    var setup = try Setup.open();
    defer setup.close();
    try setup.write("resources/level.scene.zon",
        \\.{ .entities = .{ .{ .name = "face", .parent = null, .components = .{
        \\    .{ .type = "Shot", .owner = "game", .fields = .{ .model = "resources/face.gltf", .clip = "smile" } },
        \\} } } }
    );
    normalizeOnOpen(setup.gpa, setup.io, setup.fixture.path, &setup.project, test_types);
    const smile = setup.project.referenceAt("resources/face.gltf/smile").?;
    try std.testing.expect(std.mem.indexOf(u8, try setup.read("resources/level.scene.zon"), smile.key()) != null);
}

test "a reference that can't become an id refuses the move and writes nothing" {
    var setup = try Setup.open();
    defer setup.close();
    const arena = setup.arena_state.allocator();
    const good =
        \\.{ .entities = .{ .{ .name = "a", .parent = null, .components = .{
        \\    .{ .type = "Shot", .owner = "game", .fields = .{ .name = "resources/wood.png" } },
        \\} } } }
    ;
    try setup.write("resources/a.scene.zon", good);

    // The wrong kind of file, an unknown component and a clip name with no model are refused.
    try setup.write("resources/b.scene.zon",
        \\.{ .entities = .{ .{ .name = "b", .parent = null, .components = .{
        \\    .{ .type = "Shot", .owner = "game", .fields = .{ .name = "resources/face.gltf" } },
        \\} } } }
    );
    var made = try plan(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types);
    try std.testing.expect(std.mem.indexOf(u8, made.problem.?, "b.scene.zon") != null);
    try std.testing.expect(std.mem.indexOf(u8, made.problem.?, "model, not image") != null);
    try std.testing.expectEqual(@as(usize, 0), made.rewrites.len);

    try setup.write("resources/b.scene.zon",
        \\.{ .entities = .{ .{ .name = "b", .parent = null, .components = .{
        \\    .{ .type = "Stranger", .owner = "game", .fields = .{ .picture = "resources/wood.png" } },
        \\} } } }
    );
    made = try plan(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types);
    try std.testing.expect(std.mem.indexOf(u8, made.problem.?, "Stranger.picture") != null);

    try setup.write("resources/b.scene.zon",
        \\.{ .entities = .{ .{ .name = "b", .parent = null, .components = .{
        \\    .{ .type = "Shot", .owner = "game", .fields = .{ .clip = "smile" } },
        \\} } } }
    );
    made = try plan(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types);
    try std.testing.expect(std.mem.indexOf(u8, made.problem.?, "no model") != null);

    // Refused: the good scene beside them was not rewritten either.
    const problem = try normalize(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types);
    try std.testing.expect(problem != null);
    try std.testing.expectEqualStrings(good, try setup.read("resources/a.scene.zon"));
}

test "a material's texture path becomes an id" {
    var setup = try Setup.open();
    defer setup.close();
    const arena = setup.arena_state.allocator();
    try setup.write("resources/metal.material.zon", ".{ .roughness = 0.3, .texture = \"resources/wood.png\" }");
    try std.testing.expectEqual(@as(?[]const u8, null), try normalize(setup.gpa, arena, setup.io, setup.fixture.dir, &setup.project, test_types));
    const wood = setup.project.referenceAt("resources/wood.png").?;
    const expected = try std.fmt.allocPrint(arena, ".{{ .roughness = 0.3, .texture = \"{s}\" }}", .{wood.key()});
    try std.testing.expectEqualStrings(expected, try setup.read("resources/metal.material.zon"));
}
