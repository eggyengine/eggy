//! Editor-only hierarchy folds and inherited visibility, never serialized into game scenes.
//! They are kept by each entity's name path in its scene (`kept`), which outlives the world
//! being made anew (Play, Stop, reopening, a rebuild) and the editor (see `view_file.zig`); the
//! entity sets the editor asks about are worked out from it by `follow`.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;
const Row = @import("tree.zig").Row;

/// Folded or hidden.
pub const Fold = enum { collapsed, hidden };

/// Name paths ("fence/fence north 1", "#2" after a name its earlier siblings share), owned.
pub const Paths = std.StringArrayHashMapUnmanaged(void);

pub const ViewState = struct {
    gpa: std.mem.Allocator,
    collapsed: std.AutoHashMapUnmanaged(ecs.EntityId, void) = .empty,
    hidden: std.AutoHashMapUnmanaged(ecs.EntityId, void) = .empty,
    /// What is folded and hidden, by name path: what lasts.
    kept: [2]Paths = .{ .empty, .empty },
    /// Whether `kept` changed since it was last saved.
    dirty: bool = false,
    /// Folds and hides made since the last `follow`, which records them by path.
    pending: std.ArrayList(struct { entity: ecs.EntityId, fold: Fold, on: bool }) = .empty,

    pub fn deinit(self: *ViewState) void {
        self.collapsed.deinit(self.gpa);
        self.hidden.deinit(self.gpa);
        self.forgetKept();
        for (&self.kept) |*paths| paths.deinit(self.gpa);
        self.pending.deinit(self.gpa);
    }

    /// Forget the entity sets whenever a new world is installed, even if IDs are reused; `kept`
    /// stays, and `follow` finds its entities in the new world.
    pub fn reset(self: *ViewState) void {
        self.collapsed.clearRetainingCapacity();
        self.hidden.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
    }

    /// Replace what is kept (another scene's, read back): `collapsed` and `hidden` name paths,
    /// copied. Not dirty after.
    pub fn keep(self: *ViewState, collapsed: []const []const u8, hidden: []const []const u8) !void {
        self.forgetKept();
        for ([_][]const []const u8{ collapsed, hidden }, &self.kept) |paths, *into| for (paths) |path| {
            const owned = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(owned);
            const entry = try into.getOrPut(self.gpa, owned);
            if (entry.found_existing) self.gpa.free(owned);
        };
        self.dirty = false;
    }

    fn forgetKept(self: *ViewState) void {
        for (&self.kept) |*paths| {
            for (paths.keys()) |path| self.gpa.free(path);
            paths.clearRetainingCapacity();
        }
    }

    /// Record the folds and hides made since last time by path, then work out which of `world`'s
    /// entities (from `roots`, named through `access`) are folded or hidden. Call each frame.
    /// ponytail: walks every entity each frame; track world changes if scenes reach tens of thousands.
    pub fn follow(self: *ViewState, world: *ecs.World, roots: []const ecs.EntityId, access: eggy.scene.Access) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var paths: std.AutoArrayHashMapUnmanaged(ecs.EntityId, []const u8) = .empty;
        try namePaths(arena, world, access, roots, "", &paths);

        for (self.pending.items) |change| {
            const path = paths.get(change.entity) orelse continue;
            const kept = &self.kept[@backingInt(change.fold)];
            if (change.on) {
                if (kept.contains(path)) continue;
                const owned = try self.gpa.dupe(u8, path);
                kept.put(self.gpa, owned, {}) catch |err| {
                    self.gpa.free(owned);
                    return err;
                };
            } else if (kept.fetchSwapRemove(path)) |removed| self.gpa.free(removed.key) else continue;
            self.dirty = true;
        }
        self.pending.clearRetainingCapacity();

        self.collapsed.clearRetainingCapacity();
        self.hidden.clearRetainingCapacity();
        for (paths.keys(), paths.values()) |entity, path| {
            if (self.kept[@backingInt(Fold.collapsed)].contains(path)) try self.collapsed.put(self.gpa, entity, {});
            if (self.kept[@backingInt(Fold.hidden)].contains(path)) try self.hidden.put(self.gpa, entity, {});
        }
    }

    pub fn prune(self: *ViewState, world: *ecs.World) void {
        inline for (.{ &self.collapsed, &self.hidden }) |map| {
            var it = map.keyIterator();
            while (it.next()) |entity| if (!world.isAlive(entity.*)) {
                _ = map.remove(entity.*);
            };
        }
    }

    pub fn toggleCollapse(self: *ViewState, entity: ecs.EntityId) !void {
        const on = !self.collapsed.contains(entity);
        try self.pending.append(self.gpa, .{ .entity = entity, .fold = .collapsed, .on = on });
        if (on) try self.collapsed.put(self.gpa, entity, {}) else _ = self.collapsed.remove(entity);
    }

    pub fn setHidden(self: *ViewState, entity: ecs.EntityId, hidden: bool) !void {
        try self.pending.append(self.gpa, .{ .entity = entity, .fold = .hidden, .on = hidden });
        if (hidden) try self.hidden.put(self.gpa, entity, {}) else _ = self.hidden.remove(entity);
    }

    /// A hidden parent hides its whole subtree, including generated scene-instance children.
    pub fn isHidden(self: *const ViewState, world: *ecs.World, entity: ecs.EntityId) bool {
        var current: ?ecs.EntityId = entity;
        while (current) |at| {
            if (self.hidden.contains(at)) return true;
            current = world.getParent(at);
        }
        return false;
    }

    /// Search temporarily opens folds; it does not change the saved collapse state.
    pub fn rows(self: *const ViewState, arena: std.mem.Allocator, world: *ecs.World, all: []const Row, searching: bool) ![]const Row {
        var shown: std.ArrayList(Row) = .empty;
        var skip_below: ?usize = null;
        for (all) |original| {
            if (skip_below) |depth| {
                if (original.depth > depth) continue;
                skip_below = null;
            }
            var row = original;
            row.collapsed = !searching and self.collapsed.contains(row.entity);
            row.self_hidden = self.hidden.contains(row.entity);
            row.hidden = self.isHidden(world, row.entity);
            try shown.append(arena, row);
            if (row.collapsed) skip_below = row.depth;
        }
        return shown.items;
    }

    /// Compact the gathered meshes in place so hidden entities cannot be drawn or picked.
    pub fn visibleMeshes(self: *const ViewState, world: *ecs.World, meshes: []eggy.mesh.Drawable) []eggy.mesh.Drawable {
        var count: usize = 0;
        for (meshes) |mesh| {
            if (!world.isAlive(mesh.entity()) or self.isHidden(world, mesh.entity())) continue;
            meshes[count] = mesh;
            count += 1;
        }
        return meshes[0..count];
    }

    /// Remove hidden lights in place, keeping their plain-C source identities aligned. The
    /// frame's shadow-light index (`options[2]`) follows its light to its new place, or becomes
    /// -1 when that light is hidden.
    pub fn visibleLights(self: *const ViewState, world: *ecs.World, frame: *eggy.lighting.Frame) void {
        const shadow_index: ?usize = if (frame.options[2] >= 0) @intFromFloat(frame.options[2]) else null;
        var shadow_now: f32 = -1;
        var count: u32 = 0;
        for (0..frame.count) |index| {
            const source = frame.entities[index];
            const entity = ecs.EntityId.init(source.id, source.generation);
            if (!world.isAlive(entity) or self.isHidden(world, entity)) continue;
            if (shadow_index == index) shadow_now = @floatFromInt(count);
            frame.lights[count] = frame.lights[index];
            frame.entities[count] = source;
            count += 1;
        }
        frame.count = count;
        frame.options[2] = shadow_now;
    }
};

/// Each entity under `roots` (and their children) with its name path below `prefix`, into `out`.
/// Siblings sharing a name are told apart by "#2", "#3" and so on, in order.
fn namePaths(arena: std.mem.Allocator, world: *ecs.World, access: eggy.scene.Access, roots: anytype, prefix: []const u8, out: *std.AutoArrayHashMapUnmanaged(ecs.EntityId, []const u8)) !void {
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    var name_buffer: [eggy.Name.max_len]u8 = undefined;
    var siblings = roots;
    while (nextOf(&siblings)) |entity| {
        const name = try arena.dupe(u8, access.name(world, entity, &name_buffer) orelse "");
        const count = try seen.getOrPut(arena, name);
        count.value_ptr.* = if (count.found_existing) count.value_ptr.* + 1 else 1;
        const own = if (count.value_ptr.* == 1) name else try std.fmt.allocPrint(arena, "{s}#{d}", .{ name, count.value_ptr.* });
        const path = if (prefix.len == 0) own else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, own });
        try out.put(arena, entity, path);
        try namePaths(arena, world, access, world.children(entity), path, out);
    }
}

/// The next of `siblings`: a slice of roots, or a world's children iterator.
fn nextOf(siblings: anytype) ?ecs.EntityId {
    if (@typeInfo(@TypeOf(siblings.*)) == .pointer) {
        if (siblings.len == 0) return null;
        const first = siblings.*[0];
        siblings.* = siblings.*[1..];
        return first;
    }
    return siblings.next();
}
