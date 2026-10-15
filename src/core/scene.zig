//! Scenes: the entities of a world (each one's name, parent, and every component's fields as
//! ZON) as a value to save to a file, read back, and put into a world again. The editor saves a
//! project's scene, loads it at start, and carries the world across code changes with one; the
//! runtime starts from the project's, baked in.
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

    /// The entities of `world`, or with `roots` those and their descendants, parents first.
    pub fn capture(gpa: std.mem.Allocator, world: *ecs.World, access: Access, roots: ?[]const ecs.EntityId) !Scene {
        var self = Scene{ .arena = .init(gpa) };
        errdefer self.deinit();
        const arena = self.arena.allocator();
        var entities: std.ArrayList(Entity) = .empty;
        var indices: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer indices.deinit(gpa);

        // Depth first from each root, so every parent is listed before its children.
        var pending: std.ArrayList(ecs.EntityId) = .empty;
        defer pending.deinit(gpa);
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
            const parent = if (world.getParent(entity)) |up| indices.get(up.id) else null;
            try entities.append(arena, try captureEntity(arena, world, access, entity, parent));
            // Children in reverse, so they come out in order.
            var children: std.ArrayList(ecs.EntityId) = .empty;
            defer children.deinit(gpa);
            var it = world.children(entity);
            while (it.next()) |child| try children.append(gpa, child);
            var i = children.items.len;
            while (i > 0) : (i -= 1) try pending.append(gpa, children.items[i - 1]);
        }
        self.entities = entities.items;
        return self;
    }

    fn captureEntity(arena: std.mem.Allocator, world: *ecs.World, access: Access, entity: ecs.EntityId, parent: ?usize) !Entity {
        var buffer: [4096]u8 = undefined;
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
                try fields.append(arena, .{ .name = field.name, .value = try arena.dupe(u8, value) });
            }
            try list.append(arena, .{ .type = info.name, .owner = info.owner, .fields = fields.items });
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
        var skipped: usize = 0;
        const types = access.types();
        for (self.entities, made) |saved, *entity| {
            entity.* = try world.spawn(.{});
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
                    var buffer: [4097]u8 = undefined;
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
        // Parents, now that every entity exists.
        for (self.entities, made) |saved, entity| {
            const up = if (saved.parent) |index| (if (index < made.len) made[index] else null) else parent;
            if (up) |parent_entity| world.setParent(entity, parent_entity) catch {};
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
    const holder = try world.spawn(.{});
    const made = try scene.instantiate(gpa, &world, access, holder);
    defer gpa.free(made.entities);
    try std.testing.expect(world.getParent(made.entities[0]).?.eql(holder));
    try std.testing.expect(world.getParent(made.entities[1]).?.eql(made.entities[0]));
}
