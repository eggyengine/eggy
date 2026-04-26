const std = @import("std");
const context = @import("ctx.zig");

pub const Schedule = enum {
    pre_init,
    init,
    post_init,
    
    pre_update,
    update,
    post_update,
    
    pre_fixed_update,
    fixed_update,
    post_fixed_update,
    
    pre_render,
    render,
    post_render,
    
    pre_deinit,
    deinit,
    post_deinit,
};

pub const Entity = struct {
    id: u32,
    generation: u16,

    pub fn isValid(self: Entity, world: *const World) bool {
        if (self.id >= world.generations.items.len) return false;
        return world.generations.items[self.id] == self.generation;
    }

    pub fn despawn(self: Entity, ctx: *context.Context) void {
        ctx.world.despawn(self);
    }
};

/// Type-erased component storage using sparse sets
pub const ComponentStorage = struct {
    sparse: std.ArrayListUnmanaged(?usize),
    dense: std.ArrayListUnmanaged(u32),
    data: *anyopaque,

    deinit_fn: *const fn (*ComponentStorage, std.mem.Allocator) void,
    remove_fn: *const fn (*ComponentStorage, u32) void,
    set_fn: *const fn (*ComponentStorage, std.mem.Allocator, u32, *const anyopaque) anyerror!void,

    pub fn initTyped(comptime T: type, allocator: std.mem.Allocator) !ComponentStorage {
        const data_list = try allocator.create(std.ArrayListUnmanaged(T));
        data_list.* = .{};

        return .{
            .sparse = .{},
            .dense = .{},
            .data = data_list,
            .deinit_fn = &makeDeInitFn(T).deinit,
            .remove_fn = &makeRemoveFn(T).remove,
            .set_fn = &makeSetFn(T).set,
        };
    }

    fn makeDeInitFn(comptime T: type) type {
        return struct {
            pub fn deinit(self: *ComponentStorage, allocator: std.mem.Allocator) void {
                const typed_data: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(self.data));
                typed_data.deinit(allocator);
                allocator.destroy(typed_data);
                self.sparse.deinit(allocator);
                self.dense.deinit(allocator);
            }
        };
    }

    fn makeRemoveFn(comptime T: type) type {
        return struct {
            pub fn remove(self: *ComponentStorage, entity_id: u32) void {
                if (entity_id >= self.sparse.items.len) return;
                const dense_idx = self.sparse.items[entity_id] orelse return;

                const typed_data: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(self.data));

                const last_entity = self.dense.items[self.dense.items.len - 1];

                self.dense.items[dense_idx] = last_entity;
                typed_data.items[dense_idx] = typed_data.items[typed_data.items.len - 1];

                self.sparse.items[last_entity] = dense_idx;
                self.sparse.items[entity_id] = null;

                _ = self.dense.pop();
                _ = typed_data.pop();
            }
        };
    }

    fn makeSetFn(comptime T: type) type {
        return struct {
            pub fn set(self: *ComponentStorage, allocator: std.mem.Allocator, entity_id: u32, value_ptr: *const anyopaque) !void {
                const value: T = @as(*const T, @ptrCast(@alignCast(value_ptr))).*;

                while (self.sparse.items.len <= entity_id) {
                    try self.sparse.append(allocator, null);
                }

                const typed_data: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(self.data));

                if (self.sparse.items[entity_id]) |dense_idx| {
                    typed_data.items[dense_idx] = value;
                } else {
                    const new_idx = self.dense.items.len;
                    try self.dense.append(allocator, entity_id);
                    try typed_data.append(allocator, value);
                    self.sparse.items[entity_id] = new_idx;
                }
            }
        };
    }

    pub fn getTyped(self: *ComponentStorage, comptime T: type, entity_id: u32) ?*T {
        if (entity_id >= self.sparse.items.len) return null;
        const dense_idx = self.sparse.items[entity_id] orelse return null;
        const typed_data: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(self.data));
        return &typed_data.items[dense_idx];
    }

    pub fn setTyped(self: *ComponentStorage, comptime T: type, allocator: std.mem.Allocator, entity_id: u32, value: T) !void {
        while (self.sparse.items.len <= entity_id) {
            try self.sparse.append(allocator, null);
        }

        const typed_data: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(self.data));

        if (self.sparse.items[entity_id]) |dense_idx| {
            typed_data.items[dense_idx] = value;
        } else {
            const new_idx = self.dense.items.len;
            try self.dense.append(allocator, entity_id);
            try typed_data.append(allocator, value);
            self.sparse.items[entity_id] = new_idx;
        }
    }

    pub fn has(self: *ComponentStorage, entity_id: u32) bool {
        if (entity_id >= self.sparse.items.len) return false;
        return self.sparse.items[entity_id] != null;
    }
};

pub const SystemContext = struct {
    world: *World,
    delta_time: f32,
};

pub const SystemFn = *const fn (*SystemContext) void;

pub const World = struct {
    allocator: std.mem.Allocator,

    // entity stuff
    next_entity_id: u32 = 0,
    generations: std.ArrayListUnmanaged(u16),
    free_list: std.ArrayListUnmanaged(u32),

    // component storage
    storages: std.AutoHashMapUnmanaged(usize, ComponentStorage),

    // systems as per schedule
    systems: std.EnumArray(Schedule, std.ArrayListUnmanaged(SystemFn)),

    // resources (singleton data accessible by any system)
    resources: std.AutoHashMapUnmanaged(usize, *anyopaque),
    resource_deinit_fns: std.AutoHashMapUnmanaged(usize, *const fn (*anyopaque, std.mem.Allocator) void),

    pub fn init(allocator: std.mem.Allocator) World {
        const systems = std.EnumArray(Schedule, std.ArrayListUnmanaged(SystemFn)).initFill(.empty);

        return .{
            .allocator = allocator,
            .generations = .empty,
            .free_list = .empty,
            .storages = .empty,
            .systems = systems,
            .resources = .empty,
            .resource_deinit_fns = .empty,
        };
    }

    pub fn deinit(self: *World) void {
        // Clean up resources
        var res_it = self.resources.iterator();
        while (res_it.next()) |entry| {
            if (self.resource_deinit_fns.get(entry.key_ptr.*)) |deinit_fn| {
                deinit_fn(entry.value_ptr.*, self.allocator);
            }
        }
        self.resources.deinit(self.allocator);
        self.resource_deinit_fns.deinit(self.allocator);

        var it = self.storages.valueIterator();
        while (it.next()) |storage| {
            storage.deinit_fn(storage, self.allocator);
        }
        self.storages.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.free_list.deinit(self.allocator);

        inline for (std.meta.fields(Schedule)) |field| {
            self.systems.getPtr(@enumFromInt(field.value)).deinit(self.allocator);
        }
    }

    /// Get or create storage for a component type
    fn getStorage(self: *World, comptime T: type) !*ComponentStorage {
        const type_id = typeId(T);

        if (self.storages.getPtr(type_id)) |storage| {
            return storage;
        }

        const new_storage = try ComponentStorage.initTyped(T, self.allocator);
        try self.storages.put(self.allocator, type_id, new_storage);
        return self.storages.getPtr(type_id).?;
    }

    pub fn typeId(comptime T: type) usize {
        return @intFromPtr(&struct {
            var x: T = undefined;
        }.x);
    }

    /// Spawn an entity with the given components
    pub fn spawn(self: *World, components: anytype) !Entity {
        const entity = try self.createEntity();

        // add each component from the tuple
        inline for (std.meta.fields(@TypeOf(components))) |field| {
            const component = @field(components, field.name);
            try self.set(entity, component);
        }

        return entity;
    }

    fn createEntity(self: *World) !Entity {
        if (self.free_list.items.len > 0) {
            // Recycle an old ID
            const id = self.free_list.pop().?;
            return .{ .id = id, .generation = self.generations.items[id] };
        } else {
            // Create new ID
            const id = self.next_entity_id;
            self.next_entity_id += 1;
            try self.generations.append(self.allocator, 0);
            return .{ .id = id, .generation = 0 };
        }
    }

    /// Remove an entity and all its components
    pub fn despawn(self: *World, entity: Entity) void {
        if (!entity.isValid(self)) return;

        // Remove all components
        var it = self.storages.valueIterator();
        while (it.next()) |storage| {
            storage.remove_fn(storage, entity.id);
        }

        // Increment generation and add to free list
        self.generations.items[entity.id] +%= 1;
        self.free_list.append(self.allocator, entity.id) catch {};
    }

    /// Set a component on an entity
    pub fn set(self: *World, entity: Entity, component: anytype) !void {
        const T = @TypeOf(component);
        const storage = try self.getStorage(T);
        try storage.setTyped(T, self.allocator, entity.id, component);
    }

    /// Get a component from an entity (returns mutable pointer)
    pub fn get(self: *World, entity: Entity, comptime T: type) ?*T {
        const storage = self.storages.getPtr(typeId(T)) orelse return null;
        return storage.getTyped(T, entity.id);
    }

    /// Check if entity has a component
    pub fn has(self: *World, entity: Entity, comptime T: type) bool {
        const storage = self.storages.getPtr(typeId(T)) orelse return false;
        return storage.has(entity.id);
    }

    /// Create a query to iterate entities with specific components
    pub fn query(self: *World, comptime Components: type) Query(Components) {
        return Query(Components).init(self);
    }

    /// Create a mutable query to iterate entities with specific components (returns pointers)
    pub fn query_mut(self: *World, comptime Components: type) QueryMut(Components) {
        return QueryMut(Components).init(self);
    }

    /// Register a system to run on a specific schedule
    pub fn addSystem(self: *World, schedule: Schedule, system: SystemFn) !void {
        try self.systems.getPtr(schedule).append(self.allocator, system);
    }

    /// Run all systems registered for a schedule
    pub fn runSchedule(self: *World, schedule: Schedule, delta_time: f32) void {
        var ctx = SystemContext{ .world = self, .delta_time = delta_time };
        for (self.systems.getPtr(schedule).items) |system| {
            system(&ctx);
        }
    }

    /// Insert a resource (singleton data accessible by any system)
    /// If the resource already exists, it will be replaced
    pub fn insertResource(self: *World, resource: anytype) !void {
        const T = @TypeOf(resource);
        const type_id = typeId(T);

        // Allocate and store the resource
        const ptr = try self.allocator.create(T);
        ptr.* = resource;

        // Store deinit function
        const deinit_fn = struct {
            fn deinit(data: *anyopaque, allocator: std.mem.Allocator) void {
                const typed_ptr: *T = @ptrCast(@alignCast(data));
                allocator.destroy(typed_ptr);
            }
        }.deinit;

        // Remove old resource if exists
        if (self.resources.get(type_id)) |old_ptr| {
            if (self.resource_deinit_fns.get(type_id)) |old_deinit| {
                old_deinit(old_ptr, self.allocator);
            }
        }

        try self.resources.put(self.allocator, type_id, ptr);
        try self.resource_deinit_fns.put(self.allocator, type_id, deinit_fn);
    }

    /// Get a resource by type (returns mutable pointer)
    pub fn getResource(self: *World, comptime T: type) ?*T {
        const type_id = typeId(T);
        const ptr = self.resources.get(type_id) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Check if a resource exists
    pub fn hasResource(self: *World, comptime T: type) bool {
        return self.resources.contains(typeId(T));
    }

    /// Remove a resource
    pub fn removeResource(self: *World, comptime T: type) void {
        const type_id = typeId(T);
        if (self.resources.get(type_id)) |ptr| {
            if (self.resource_deinit_fns.get(type_id)) |deinit_fn| {
                deinit_fn(ptr, self.allocator);
            }
            _ = self.resources.remove(type_id);
            _ = self.resource_deinit_fns.remove(type_id);
        }
    }
};

/// Query iterator for entities with specific components
pub fn Query(comptime Components: type) type {
    const fields = std.meta.fields(Components);

    return struct {
        world: *World,
        current_idx: usize = 0,
        primary_storage: ?*ComponentStorage,

        const Self = @This();

        pub fn init(world: *World) Self {
            // Use first component type's storage as primary iterator
            const FirstType = fields[0].type;
            const type_id = World.typeId(FirstType);
            const storage = world.storages.getPtr(type_id);

            return .{
                .world = world,
                .primary_storage = storage,
            };
        }

        pub const QueryResult = struct {
            entity: Entity,
            components: Components,
        };

        pub fn next(self: *Self) ?QueryResult {
            const storage = self.primary_storage orelse return null;

            while (self.current_idx < storage.dense.items.len) {
                const entity_id = storage.dense.items[self.current_idx];
                self.current_idx += 1;

                // Check if entity has ALL requested components
                var components: Components = undefined;
                var has_all = true;

                inline for (fields) |field| {
                    const T = field.type;
                    const entity = Entity{
                        .id = entity_id,
                        .generation = self.world.generations.items[entity_id],
                    };
                    if (self.world.get(entity, T)) |ptr| {
                        @field(components, field.name) = ptr.*;
                    } else {
                        has_all = false;
                        break;
                    }
                }

                if (has_all) {
                    return .{
                        .entity = .{
                            .id = entity_id,
                            .generation = self.world.generations.items[entity_id],
                        },
                        .components = components,
                    };
                }
            }

            return null;
        }

        /// Reset iterator to beginning
        pub fn reset(self: *Self) void {
            self.current_idx = 0;
        }
    };
}

/// Mutable query iterator - returns pointers to components for modification
pub fn QueryMut(comptime Components: type) type {
    const fields = std.meta.fields(Components);

    const PointerComponents = blk: {
        var field_names: [fields.len][:0]const u8 = undefined;
        var field_types: [fields.len]type = undefined;
        var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        for (fields, 0..) |field, i| {
            field_names[i] = field.name;
            field_types[i] = *field.type;
            field_attrs[i] = .{};
        }
        break :blk @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    };

    return struct {
        world: *World,
        current_idx: usize = 0,
        primary_storage: ?*ComponentStorage,

        const Self = @This();

        pub fn init(world: *World) Self {
            const FirstType = fields[0].type;
            const type_id = World.typeId(FirstType);
            const storage = world.storages.getPtr(type_id);

            return .{
                .world = world,
                .primary_storage = storage,
            };
        }

        pub const QueryResult = struct {
            entity: Entity,
            components: PointerComponents,
        };

        pub fn next(self: *Self) ?QueryResult {
            const storage = self.primary_storage orelse return null;

            while (self.current_idx < storage.dense.items.len) {
                const entity_id = storage.dense.items[self.current_idx];
                self.current_idx += 1;

                var components: PointerComponents = undefined;
                var has_all = true;

                inline for (fields) |field| {
                    const T = field.type;
                    const entity = Entity{
                        .id = entity_id,
                        .generation = self.world.generations.items[entity_id],
                    };
                    if (self.world.get(entity, T)) |ptr| {
                        @field(components, field.name) = ptr;
                    } else {
                        has_all = false;
                        break;
                    }
                }

                if (has_all) {
                    return .{
                        .entity = .{
                            .id = entity_id,
                            .generation = self.world.generations.items[entity_id],
                        },
                        .components = components,
                    };
                }
            }

            return null;
        }

        pub fn reset(self: *Self) void {
            self.current_idx = 0;
        }
    };
}

pub fn Events(comptime T: type) type {
    return struct {
        events: std.ArrayListUnmanaged(T) = .empty,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Send an event (available until the next drain).
        pub fn send(self: *Self, event: T) void {
            self.events.append(self.allocator, event) catch {};
        }

        /// Read all pending events.
        pub fn read(self: *Self) []const T {
            return self.events.items;
        }

        /// Clear the queue. Call once per frame (e.g. at pre_update).
        pub fn drain(self: *Self) void {
            self.events.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            self.events.deinit(self.allocator);
        }
    };
}