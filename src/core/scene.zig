//! Scenes: the entities of a world (each one's name, parent, and every component's fields as
//! ZON) as a value to save to a file, read back, and put into a world again. The editor saves a
//! project's scene, loads it at start, and carries the world across code changes with one; the
//! runtime starts from the project's, baked in. An entity reference (`eggy.EntityRef`) to an
//! entity of the scene is saved as its place, `.{ .scene = 3 }`, and points at the entity made
//! from it when the scene is put into a world. A `SceneInstance`'s entities come from its own
//! scene file, so they aren't captured, only the instance.
//!
//!     .{ .entities = .{
//!         .{ .name = "Sun", .parent = null, .components = .{
//!             .{ .type = "Body", .owner = "my_game", .fields = .{ .kind = .star, .radius = 5 } },
//!         } },
//!     } }
const std = @import("std");
const ecs = @import("clutch");
const components = @import("components.zig");
const Name = @import("name.zig").Name;
const scene_instance = @import("scene_instance.zig");
const log = std.log.scoped(.scene);

/// The typed steps a scene needs, done by whatever has the component types: their `Registry`
/// in the runtime (`registryAccess`), the game's library in the editor.
pub const Access = struct {
    context: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        types: *const fn (context: *const anyopaque) []const components.Info,
        has: *const fn (context: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize) bool,
        /// Add it with its defaults; false if it can't be.
        add: *const fn (context: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize) bool,
        /// A field as ZON in `buffer`; null if it can't be read whole.
        read_field: *const fn (context: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, buffer: []u8) ?[]const u8,
        /// Set a field from ZON; false if it doesn't parse.
        write_field: *const fn (context: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, text: [:0]const u8) bool,
        /// The entity's `Name` in `buffer`; null without one.
        name: *const fn (context: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, buffer: []u8) ?[]const u8,
        /// Give the entity `Name` `text`, or take its name away when `text` is empty.
        set_name: *const fn (context: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, text: []const u8) void,
    };

    pub fn types(self: Access) []const components.Info {
        return self.vtable.types(self.context);
    }
    pub fn has(self: Access, world: *ecs.World, entity: ecs.EntityId, component: usize) bool {
        return self.vtable.has(self.context, world, entity, component);
    }
    pub fn add(self: Access, world: *ecs.World, entity: ecs.EntityId, component: usize) bool {
        return self.vtable.add(self.context, world, entity, component);
    }
    pub fn readField(self: Access, world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, buffer: []u8) ?[]const u8 {
        return self.vtable.read_field(self.context, world, entity, component, field, buffer);
    }
    pub fn writeField(self: Access, world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, text: [:0]const u8) bool {
        return self.vtable.write_field(self.context, world, entity, component, field, text);
    }
    pub fn name(self: Access, world: *ecs.World, entity: ecs.EntityId, buffer: []u8) ?[]const u8 {
        return self.vtable.name(self.context, world, entity, buffer);
    }
    pub fn setName(self: Access, world: *ecs.World, entity: ecs.EntityId, text: []const u8) void {
        self.vtable.set_name(self.context, world, entity, text);
    }
};

test "captured scenes own component metadata independently of their registry" {
    const Value = struct { count: u32 = 1 };
    const Registry = components.Registry(&.{Value}, &.{"game"});
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{Value{}});
    var captured = try Scene.capture(std.testing.allocator, &world, registryAccess(Registry), null);
    defer captured.deinit();
    const saved = captured.entities[0].components[0];
    try std.testing.expect(saved.type.ptr != Registry.infos[0].name.ptr);
    try std.testing.expect(saved.owner.ptr != Registry.infos[0].owner.ptr);
    try std.testing.expect(saved.fields[0].name.ptr != Registry.infos[0].fields[0].name.ptr);
    try std.testing.expectEqualStrings("count", saved.fields[0].name);
}

/// `Access` straight through `Registry` (a `components.Registry`), for code that has the types.
pub fn registryAccess(comptime Registry: type) Access {
    const Through = struct {
        fn types(_: *const anyopaque) []const components.Info {
            return Registry.infos;
        }
        fn has(_: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize) bool {
            return Registry.has(world, entity, component);
        }
        fn add(_: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize) bool {
            Registry.add(world, entity, component) catch return false;
            return true;
        }
        fn readField(_: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, buffer: []u8) ?[]const u8 {
            var writer: std.Io.Writer = .fixed(buffer);
            Registry.writeField(world, entity, component, field, &writer) catch return null;
            return writer.buffered();
        }
        fn writeField(_: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, component: usize, field: usize, text: [:0]const u8) bool {
            Registry.setField(world, entity, component, field, text) catch return false;
            return true;
        }
        fn name(_: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, buffer: []u8) ?[]const u8 {
            const found = world.get(entity, Name) orelse return null;
            const text = found.text()[0..@min(found.text().len, buffer.len)];
            @memcpy(buffer[0..text.len], text);
            return buffer[0..text.len];
        }
        fn setName(_: *const anyopaque, world: *ecs.World, entity: ecs.EntityId, text: []const u8) void {
            if (text.len == 0) return world.remove(entity, Name);
            if (world.get(entity, Name)) |found| {
                found.* = .init(text);
                world.markChanged(entity, Name);
            } else world.addComponent(entity, Name.init(text)) catch {};
        }
        const vtable = Access.VTable{ .types = types, .has = has, .add = add, .read_field = readField, .write_field = writeField, .name = name, .set_name = setName };
    };
    return .{ .context = &Through.vtable, .vtable = &Through.vtable };
}

pub const Scene = struct {
    arena: std.heap.ArenaAllocator,
    /// Parents come before their children.
    entities: []const Entity = &.{},
    /// For a scene `capture` made: the world's entity each of `entities` was made from.
    sources: []const ecs.EntityId = &.{},

    pub const Entity = struct {
        name: []const u8 = "",
        /// An index into `entities`; null at the top level.
        parent: ?usize = null,
        components: []const Component = &.{},
    };

    pub const Component = struct {
        /// The type's name (`components.Info.name`) and owner.
        type: []const u8,
        owner: []const u8,
        fields: []const Field,
    };

    pub const Field = struct { name: []const u8, value: []const u8 };

    pub fn deinit(self: *Scene) void {
        self.arena.deinit();
    }

    /// The entities of `world`, or with `roots` those and their descendants, parents first; a
    /// `SceneInstance`'s descendants are left out, as they come from its scene file.
    pub fn capture(gpa: std.mem.Allocator, world: *ecs.World, access: Access, roots: ?[]const ecs.EntityId) !Scene {
        var self = Scene{ .arena = .init(gpa) };
        errdefer self.deinit();
        const arena = self.arena.allocator();
        var entities: std.ArrayList(Entity) = .empty;
        var indices: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer indices.deinit(gpa);

        // Depth first from each root, so every parent is listed before its children.
        var captured: std.ArrayList(ecs.EntityId) = .empty;
        defer captured.deinit(gpa);
        var pending: std.ArrayList(ecs.EntityId) = .empty;
        defer pending.deinit(gpa);
        const instance_type = scene_instance.typeIndex(access.types());
        if (roots) |chosen| {
            var i = chosen.len;
            while (i > 0) : (i -= 1) try pending.append(gpa, chosen[i - 1]);
        } else {
            var i = world.slots.items.len;
            while (i > 0) : (i -= 1) {
                const slot = world.slots.items[i - 1];
                const entity = ecs.EntityId.init(@intCast(i - 1), slot.generation);
                if (slot.alive and world.getParent(entity) == null) try pending.append(gpa, entity);
            }
        }
        while (pending.pop()) |entity| {
            if (!world.isAlive(entity) or indices.contains(entity.id)) continue;
            try indices.put(gpa, entity.id, entities.items.len);
            try captured.append(gpa, entity);
            const parent = if (world.getParent(entity)) |up| indices.get(up.id) else null;
            try entities.append(arena, try captureEntity(arena, world, access, entity, parent));
            if (instance_type) |index| if (access.has(world, entity, index)) continue;
            // Children in reverse, so they come out in order.
            var children: std.ArrayList(ecs.EntityId) = .empty;
            defer children.deinit(gpa);
            var it = world.children(entity);
            while (it.next()) |child| try children.append(gpa, child);
            var i = children.items.len;
            while (i > 0) : (i -= 1) try pending.append(gpa, children.items[i - 1]);
        }
        self.entities = entities.items;
        self.sources = try arena.dupe(ecs.EntityId, captured.items);

        // References to entities of the scene become their places in it.
        for (self.entities) |entity| for (entity.components) |component| {
            const index = findType(access.types(), component.type, component.owner) orelse continue;
            for (@constCast(component.fields)) |*field| {
                if (fieldKind(access.types()[index], field.name) != .entity) continue;
                const target = (parseValue(?ecs.EntityId, field.value) orelse continue) orelse continue;
                const place = for (captured.items, 0..) |kept, i| {
                    if (kept.eql(target)) break i;
                } else continue;
                field.value = try std.fmt.allocPrint(arena, ".{{ .scene = {d} }}", .{place});
            }
        };
        return self;
    }

    fn captureEntity(arena: std.mem.Allocator, world: *ecs.World, access: Access, entity: ecs.EntityId, parent: ?usize) !Entity {
        var buffer: [components.max_field_bytes]u8 = undefined;
        const name = if (access.name(world, entity, &buffer)) |text| try arena.dupe(u8, text) else "";
        var list: std.ArrayList(Component) = .empty;
        for (access.types(), 0..) |info, component| {
            if (!access.has(world, entity, component)) continue;
            var fields: std.ArrayList(Field) = .empty;
            for (info.fields, 0..) |field, index| {
                const value = access.readField(world, entity, component, index, &buffer) orelse {
                    log.warn("{s}.{s} of an entity can't be saved", .{ info.name, field.name });
                    continue;
                };
                try fields.append(arena, .{ .name = try arena.dupe(u8, field.name), .value = try arena.dupe(u8, value) });
            }
            // A captured scene outlives the registry/library it came from during hot reload.
            try list.append(arena, .{ .type = try arena.dupe(u8, info.name), .owner = try arena.dupe(u8, info.owner), .fields = fields.items });
        }
        return .{ .name = name, .parent = parent, .components = list.items };
    }

    /// What `instantiate` made: the entities, in scene order (free with the allocator given),
    /// and how many components and fields it couldn't put back.
    pub const Instantiated = struct { entities: []ecs.EntityId, skipped: usize };

    /// Spawn the scene's entities into `world`, parented as saved, the top-level ones under
    /// `parent` if given. Components whose type is gone or can't be added, and fields that are
    /// gone or don't parse, are skipped (logged, and counted).
    pub fn instantiate(self: *const Scene, gpa: std.mem.Allocator, world: *ecs.World, access: Access, parent: ?ecs.EntityId) !Instantiated {
        const made = try gpa.alloc(ecs.EntityId, self.entities.len);
        errdefer gpa.free(made);
        var spawned: usize = 0;
        errdefer for (made[0..spawned]) |entity| world.despawn(entity);
        var skipped: usize = 0;
        const types = access.types();
        // References to the scene's own entities, set once every entity exists.
        const Deferred = struct { entity: ecs.EntityId, component: usize, field: usize, place: usize };
        var deferred: std.ArrayList(Deferred) = .empty;
        defer deferred.deinit(gpa);
        for (self.entities, made) |saved, *entity| {
            entity.* = try world.spawn(.{});
            spawned += 1;
            if (saved.name.len > 0) access.setName(world, entity.*, saved.name);
            for (saved.components) |component| {
                const index = findType(types, component.type, component.owner) orelse {
                    log.warn("no component {s} from {s}: it is left out", .{ component.type, component.owner });
                    skipped += 1;
                    continue;
                };
                if (!access.has(world, entity.*, index) and !access.add(world, entity.*, index)) {
                    log.warn("{s} can't be added (its fields need defaults): it is left out", .{component.type});
                    skipped += 1;
                    continue;
                }
                for (component.fields) |field| {
                    const field_index = for (types[index].fields, 0..) |known, i| {
                        if (std.mem.eql(u8, known.name, field.name)) break i;
                    } else {
                        skipped += 1;
                        continue;
                    };
                    if (types[index].fields[field_index].kind == .entity) if (parseValue(SceneRef, field.value)) |ref| {
                        try deferred.append(gpa, .{ .entity = entity.*, .component = index, .field = field_index, .place = ref.scene });
                        continue;
                    };
                    var buffer: [components.max_field_bytes + 1]u8 = undefined;
                    const text = std.fmt.bufPrintZ(&buffer, "{s}", .{field.value}) catch {
                        skipped += 1;
                        continue;
                    };
                    if (!access.writeField(world, entity.*, index, field_index, text)) {
                        log.warn("{s}.{s} = {s} doesn't parse: it keeps its default", .{ component.type, field.name, field.value });
                        skipped += 1;
                    }
                }
            }
        }
        // References, and parents, now that every entity exists.
        for (deferred.items) |ref| {
            if (ref.place >= made.len) {
                skipped += 1;
                continue;
            }
            var buffer: [64]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buffer, ".{{ .id = {d}, .generation = {d} }}", .{ made[ref.place].id, made[ref.place].generation }) catch unreachable;
            if (!access.writeField(world, ref.entity, ref.component, ref.field, text)) skipped += 1;
        }
        for (self.entities, made) |saved, entity| {
            const up = if (saved.parent) |index| (if (index < made.len) made[index] else null) else parent;
            if (up) |parent_entity| try world.setParent(entity, parent_entity);
        }
        return .{ .entities = made, .skipped = skipped };
    }

    /// The scene as a ZON file.
    pub fn write(self: *const Scene, writer: *std.Io.Writer) !void {
        try writer.writeAll(".{\n    .entities = .{\n");
        for (self.entities) |entity| {
            try writer.print("        .{{\n            .name = \"{f}\",\n", .{std.zig.fmtString(entity.name)});
            if (entity.parent) |parent| try writer.print("            .parent = {d},\n", .{parent}) else try writer.writeAll("            .parent = null,\n");
            try writer.writeAll("            .components = .{\n");
            for (entity.components) |component| {
                try writer.print("                .{{ .type = \"{f}\", .owner = \"{f}\", .fields = .{{", .{ std.zig.fmtString(component.type), std.zig.fmtString(component.owner) });
                for (component.fields, 0..) |field, i| try writer.print("{s}.{f} = {s}", .{ if (i == 0) " " else ", ", std.zig.fmtId(field.name), field.value });
                try writer.writeAll(if (component.fields.len > 0) " } },\n" else "} },\n");
            }
            try writer.writeAll("            },\n        },\n");
        }
        try writer.writeAll("    },\n}\n");
    }

    /// A scene read from `source` (as `write` writes it). Fails with `error.ParseZon` when it
    /// isn't one.
    pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Scene {
        var self = Scene{ .arena = .init(gpa) };
        errdefer self.deinit();
        const arena = self.arena.allocator();
        var ast = try std.zig.Ast.parse(gpa, source, .zon);
        defer ast.deinit(gpa);
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        defer zoir.deinit(gpa);
        if (zoir.hasCompileErrors()) return error.ParseZon;
        const reader = Reader{ .ast = &ast, .zoir = &zoir, .arena = arena };

        const root = Reader.Index.root;
        var entities: std.ArrayList(Entity) = .empty;
        const entity_nodes = reader.items(reader.field(root, "entities") orelse return self) orelse return error.ParseZon;
        for (0..entity_nodes.len) |i| {
            const node = entity_nodes.at(i);
            var entity = Entity{};
            if (reader.field(node, "name")) |name| entity.name = try reader.string(name);
            if (reader.field(node, "parent")) |parent| entity.parent = try reader.optionalIndex(parent);
            var list: std.ArrayList(Component) = .empty;
            if (reader.field(node, "components")) |component_nodes| {
                const nodes = reader.items(component_nodes) orelse return error.ParseZon;
                for (0..nodes.len) |j| {
                    const component = nodes.at(j);
                    var fields: std.ArrayList(Field) = .empty;
                    if (reader.field(component, "fields")) |field_nodes| try reader.collectFields(field_nodes, &fields);
                    try list.append(arena, .{
                        .type = try reader.string(reader.field(component, "type") orelse return error.ParseZon),
                        .owner = if (reader.field(component, "owner")) |owner| try reader.string(owner) else "",
                        .fields = fields.items,
                    });
                }
            }
            entity.components = list.items;
            if (entity.parent) |parent| if (parent >= i) return error.ParseZon; // parents come first
            try entities.append(arena, entity);
        }
        self.entities = entities.items;
        return self;
    }
};

/// How a scene saves a reference to one of its own entities.
const SceneRef = struct { scene: usize };

/// `text` (a field's ZON) as a `T`, if it is one; `T` holds no pointers.
fn parseValue(comptime T: type, text: []const u8) ?T {
    var buffer: [256]u8 = undefined;
    const source = std.fmt.bufPrintZ(&buffer, "{s}", .{text}) catch return null;
    // The parse's own scratch.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    return std.zon.parse.fromSlice(T, fba.allocator(), source, null, .{}) catch null;
}

/// The kind of field `name` of `info`; `.other` if it has none so named.
fn fieldKind(info: components.Info, name: []const u8) components.Kind {
    for (info.fields) |field| if (std.mem.eql(u8, field.name, name)) return field.kind;
    return .other;
}

fn findType(types: []const components.Info, name: []const u8, owner: []const u8) ?usize {
    var by_name: ?usize = null;
    for (types, 0..) |info, i| {
        if (!std.mem.eql(u8, info.name, name)) continue;
        if (std.mem.eql(u8, info.owner, owner)) return i;
        by_name = by_name orelse i;
    }
    return by_name;
}

/// Walking a parsed ZON file's values.
const Reader = struct {
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,
    arena: std.mem.Allocator,

    const Index = std.zig.Zoir.Node.Index;
    const Range = struct {
        start: u32,
        len: u32,
        fn at(range: Range, i: usize) Index {
            return @enumFromInt(range.start + @as(u32, @intCast(i)));
        }
    };

    /// Field `name` of struct literal `node`, if it has one.
    fn field(self: Reader, node: Index, name: []const u8) ?Index {
        switch (node.get(self.zoir.*)) {
            .struct_literal => |fields| for (fields.names, 0..) |field_name, i| {
                if (std.mem.eql(u8, field_name.get(self.zoir.*), name)) return @enumFromInt(@intFromEnum(fields.vals.start) + @as(u32, @intCast(i)));
            },
            else => {},
        }
        return null;
    }

    /// The elements of an array (or tuple) literal; null if `node` isn't one.
    fn items(self: Reader, node: Index) ?Range {
        return switch (node.get(self.zoir.*)) {
            .empty_literal => .{ .start = 0, .len = 0 },
            .array_literal => |range| .{ .start = @intFromEnum(range.start), .len = range.len },
            else => null,
        };
    }

    fn string(self: Reader, node: Index) ![]const u8 {
        return switch (node.get(self.zoir.*)) {
            .string_literal => |text| self.arena.dupe(u8, text),
            else => error.ParseZon,
        };
    }

    fn optionalIndex(self: Reader, node: Index) !?usize {
        return switch (node.get(self.zoir.*)) {
            .null => null,
            .int_literal => |int| switch (int) {
                .small => |small| std.math.cast(usize, small) orelse error.ParseZon,
                .big => error.ParseZon,
            },
            else => error.ParseZon,
        };
    }

    /// Each field of struct literal `node`, its value as ZON source.
    fn collectFields(self: Reader, node: Index, out: *std.ArrayList(Scene.Field)) !void {
        switch (node.get(self.zoir.*)) {
            .empty_literal => {},
            .struct_literal => |fields| for (fields.names, 0..) |name, i| {
                const value: Index = @enumFromInt(@intFromEnum(fields.vals.start) + @as(u32, @intCast(i)));
                try out.append(self.arena, .{ .name = try self.arena.dupe(u8, name.get(self.zoir.*)), .value = try self.arena.dupe(u8, self.ast.getNodeSource(value.getAstNode(self.zoir.*))) });
            },
            else => return error.ParseZon,
        }
    }
};

const Spin = struct { speed: f32 = 1, axis: enum { x, y } = .y };
const Tag = struct { id: u32 };

test "a scene saves names, parents and fields, and reads back into a new world" {
    const gpa = std.testing.allocator;
    // Leaving Tag out is expected: its warning would fail the run.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const Components = components.Registry(&.{ Spin, Tag }, &.{ "game", "game" });
    const access = registryAccess(Components);

    var world = ecs.World.init(gpa);
    defer world.deinit();
    const sun = try world.spawn(.{Spin{ .speed = 2 }});
    access.setName(&world, sun, "Sun \"Sol\"");
    const planet = try world.spawn(.{ Spin{ .axis = .x }, Tag{ .id = 7 } });
    try world.setParent(planet, sun);

    var scene = try Scene.capture(gpa, &world, access, null);
    defer scene.deinit();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try scene.write(&text.writer);
    const source = try gpa.dupeZ(u8, text.written());
    defer gpa.free(source);
    var read = try Scene.parse(gpa, source);
    defer read.deinit();

    var copy = ecs.World.init(gpa);
    defer copy.deinit();
    const made = try read.instantiate(gpa, &copy, access, null);
    defer gpa.free(made.entities);
    try std.testing.expectEqual(@as(usize, 2), made.entities.len);
    // Tag has no default, so it can't be put back.
    try std.testing.expectEqual(@as(usize, 1), made.skipped);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Sun \"Sol\"", access.name(&copy, made.entities[0], &buffer).?);
    try std.testing.expectEqual(@as(f32, 2), copy.get(made.entities[0], Spin).?.speed);
    try std.testing.expectEqual(.x, copy.get(made.entities[1], Spin).?.axis);
    try std.testing.expect(copy.getParent(made.entities[1]).?.eql(made.entities[0]));
}

test "capturing roots takes their descendants only, which go under a new parent" {
    const gpa = std.testing.allocator;
    const access = registryAccess(components.Registry(&.{Spin}, &.{"game"}));
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const a = try world.spawn(.{Spin{}});
    const b = try world.spawn(.{Spin{}});
    try world.setParent(b, a);
    _ = try world.spawn(.{Spin{}}); // not under `a`

    var scene = try Scene.capture(gpa, &world, access, &.{a});
    defer scene.deinit();
    try std.testing.expectEqual(@as(usize, 2), scene.entities.len);
    try std.testing.expectEqualSlices(ecs.EntityId, &.{ a, b }, scene.sources);
    const holder = try world.spawn(.{});
    const made = try scene.instantiate(gpa, &world, access, holder);
    defer gpa.free(made.entities);
    try std.testing.expect(world.getParent(made.entities[0]).?.eql(holder));
    try std.testing.expect(world.getParent(made.entities[1]).?.eql(made.entities[0]));
}

test "a scene instance is saved without the entities made from its file" {
    const gpa = std.testing.allocator;
    const SceneInstance = scene_instance.SceneInstance;
    const Transform = @import("transform.zig").Transform;
    const access = registryAccess(components.Registry(&.{ Spin, Transform, SceneInstance }, &.{ "game", "eggy", "eggy" }));
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const rat = try world.spawn(.{SceneInstance{ .scene = .init("resources/scene/rat.scene.zon") }});
    const hat = try world.spawn(.{Spin{}});
    try world.setParent(hat, rat);

    var scene = try Scene.capture(gpa, &world, access, null);
    defer scene.deinit();
    try std.testing.expectEqual(@as(usize, 1), scene.entities.len);
    try std.testing.expectEqualStrings("SceneInstance", scene.entities[0].components[0].type);
    try std.testing.expectEqualStrings("\"resources/scene/rat.scene.zon\"", scene.entities[0].components[0].fields[0].value);
}

test "references to the scene's own entities point at their copies" {
    const gpa = std.testing.allocator;
    const refs = @import("refs.zig");
    const Follow = struct { leader: refs.EntityRef(void) = .{} };
    const access = registryAccess(components.Registry(&.{Follow}, &.{"game"}));
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const leader = try world.spawn(.{});
    const follower = try world.spawn(.{Follow{ .leader = .init(leader) }});
    const outside = try world.spawn(.{});
    const stray = try world.spawn(.{Follow{ .leader = .init(outside) }});

    // Duplicating the pair: the copy follows the copied leader.
    var pair = try Scene.capture(gpa, &world, access, &.{ leader, follower });
    defer pair.deinit();
    try std.testing.expectEqualStrings(".{ .scene = 0 }", pair.entities[1].components[0].fields[0].value);
    const made = try pair.instantiate(gpa, &world, access, null);
    defer gpa.free(made.entities);
    try std.testing.expect(world.get(made.entities[1], Follow).?.leader.entity.?.eql(made.entities[0]));

    // One pointing outside what is captured keeps pointing there.
    var alone = try Scene.capture(gpa, &world, access, &.{stray});
    defer alone.deinit();
    const again = try alone.instantiate(gpa, &world, access, null);
    defer gpa.free(again.entities);
    try std.testing.expect(world.get(again.entities[0], Follow).?.leader.entity.?.eql(outside));
}
