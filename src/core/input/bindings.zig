//! Versioned developer control overrides, independent of SDL device ownership.
const std = @import("std");
const types = @import("types.zig");
pub const file_name = @import("../project.zig").controls_file;
pub const Persistence = struct {
    context: *anyopaque,
    save: *const fn (*anyopaque, []const u8) anyerror!void,
};
const SavedBinding = union(enum) {
    key: types.Key,
    mouse: types.MouseButton,
    controller: struct { button: types.ControllerButton },
    key_axis: @FieldType(types.Binding, "key_axis"),
    keys_2d: @FieldType(types.Binding, "keys_2d"),
    controller_axis: struct { axis: @import("vitellus_sdl3").sdl.gamepad.Axis, dead_zone: f32 = 0.15, scale: f32 = 1 },
    controller_stick: struct { stick: types.Stick = .left, dead_zone: f32 = 0.15, scale: [2]f32 = .{ 1, 1 } },
    mouse_delta: @FieldType(types.Binding, "mouse_delta"),
    mouse_wheel: @FieldType(types.Binding, "mouse_wheel"),
};
pub const SavedControl = struct { owner: []const u8, name: []const u8, bindings: []const SavedBinding, trigger: ?types.Trigger = null };
const SavedMap = struct { owner: []const u8, priority: i32 = 0, enabled: bool = true };
const Saved = struct { version: u32 = 1, controls: []const SavedControl = &.{}, maps: []const SavedMap = &.{} };
const Change = union(enum) {
    control: struct { owner: []const u8, name: []const u8, bindings: ?[]const types.Binding, trigger: ?types.Trigger },
    map: struct { owner: []const u8, value: ?types.MapDefaults },
};

pub fn validate(mappings: []const types.Binding, persistent: bool) !void {
    for (mappings) |binding| switch (binding) {
        .key => |key| if (@intFromEnum(key) == 0 or @intFromEnum(key) >= types.key_count) return error.InvalidBinding,
        .mouse => {},
        .controller => |controller| if (controller.device) |device| {
            if (persistent) return error.TransientControllerBinding;
            if (@intFromEnum(device) == 0) return error.InvalidBinding;
        },
        .key_axis => |axis| {
            try validate(&.{ .{ .key = axis.negative }, .{ .key = axis.positive } }, persistent);
            if (!std.math.isFinite(axis.scale)) return error.InvalidBinding;
        },
        .keys_2d => |keys| {
            try validate(&.{ .{ .key = keys.keys.left }, .{ .key = keys.keys.right }, .{ .key = keys.keys.up }, .{ .key = keys.keys.down } }, persistent);
            for (keys.scale) |value| if (!std.math.isFinite(value)) return error.InvalidBinding;
        },
        .controller_axis => |axis| {
            try validate(&.{.{ .controller = .{ .device = axis.device, .button = .south } }}, persistent);
            if (!std.math.isFinite(axis.dead_zone) or axis.dead_zone < 0 or axis.dead_zone >= 1 or !std.math.isFinite(axis.scale)) return error.InvalidBinding;
        },
        .controller_stick => |stick| {
            try validate(&.{.{ .controller = .{ .device = stick.device, .button = .south } }}, persistent);
            if (!std.math.isFinite(stick.dead_zone) or stick.dead_zone < 0 or stick.dead_zone >= 1) return error.InvalidBinding;
            for (stick.scale) |value| if (!std.math.isFinite(value)) return error.InvalidBinding;
        },
        .mouse_delta => |delta| for (delta.scale) |value| {
            if (!std.math.isFinite(value)) return error.InvalidBinding;
        },
        .mouse_wheel => |wheel| if (!std.math.isFinite(wheel.scale)) return error.InvalidBinding,
    };
}

pub fn stableKey(gpa: std.mem.Allocator, owner: []const u8, name: []const u8) ![]u8 {
    if (owner.len == 0 or name.len == 0) return error.InvalidBinding;
    return std.fmt.allocPrint(gpa, "{d}:{s}{s}", .{ owner.len, owner, name });
}

/// Owns all strings/bindings. A failed save leaves active overrides unchanged.
pub const Overrides = struct {
    gpa: std.mem.Allocator,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    maps: std.StringArrayHashMapUnmanaged(types.MapDefaults) = .empty,
    const Entry = struct { owner: []u8, name: []u8, bindings: []types.Binding, trigger: ?types.Trigger = null };

    pub fn init(gpa: std.mem.Allocator) Overrides {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Overrides) void {
        for (self.entries.keys(), self.entries.values()) |key, entry| {
            self.gpa.free(key);
            self.free(entry);
        }
        self.entries.deinit(self.gpa);
        for (self.maps.keys()) |key| self.gpa.free(key);
        self.maps.deinit(self.gpa);
    }
    fn free(self: *Overrides, entry: Entry) void {
        self.gpa.free(entry.owner);
        self.gpa.free(entry.name);
        self.gpa.free(entry.bindings);
        if (entry.trigger) |trigger| if (trigger == .chord) self.gpa.free(trigger.chord);
    }
    pub fn get(self: *const Overrides, key: []const u8) ?[]const types.Binding {
        return if (self.entries.get(key)) |entry| entry.bindings else null;
    }
    pub fn getTrigger(self: *const Overrides, key: []const u8) ?types.Trigger {
        return if (self.entries.get(key)) |entry| entry.trigger else null;
    }
    pub fn setMap(self: *Overrides, owner: []const u8, value: ?types.MapDefaults, persistence: ?Persistence) !void {
        if (owner.len == 0) return error.InvalidBinding;
        const existing = self.maps.contains(owner);
        const key = try self.gpa.dupe(u8, owner);
        defer if (value == null or existing) self.gpa.free(key);
        errdefer if (value != null and !existing) self.gpa.free(key);
        try self.maps.ensureUnusedCapacity(self.gpa, 1);
        if (persistence) |sink| {
            var text: std.Io.Writer.Allocating = .init(self.gpa);
            defer text.deinit();
            try self.writeChanging(&text.writer, .{ .map = .{ .owner = owner, .value = value } });
            try sink.save(sink.context, text.written());
        }
        if (value) |defaults| {
            if (self.maps.getPtr(owner)) |previous| previous.* = defaults else self.maps.putAssumeCapacity(key, defaults);
        } else if (self.maps.getIndex(owner)) |index| {
            self.gpa.free(self.maps.keys()[index]);
            self.maps.orderedRemoveAt(index);
        }
    }
    pub fn set(self: *Overrides, owner: []const u8, name: []const u8, mappings: []const types.Binding, trigger: ?types.Trigger, persistence: ?Persistence) !void {
        try validate(mappings, persistence != null);
        const key = try stableKey(self.gpa, owner, name);
        errdefer self.gpa.free(key);
        const entry = Entry{ .owner = try self.gpa.dupe(u8, owner), .name = undefined, .bindings = undefined };
        errdefer self.gpa.free(entry.owner);
        var owned = entry;
        owned.name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned.name);
        owned.bindings = try self.gpa.dupe(types.Binding, mappings);
        errdefer self.gpa.free(owned.bindings);
        owned.trigger = if (trigger) |value| if (value == .chord) .{ .chord = try self.gpa.dupe(u8, value.chord) } else value else null;
        errdefer if (owned.trigger) |value| if (value == .chord) self.gpa.free(value.chord);
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        if (persistence) |sink| {
            var text: std.Io.Writer.Allocating = .init(self.gpa);
            defer text.deinit();
            try self.writeChanging(&text.writer, .{ .control = .{ .owner = owner, .name = name, .bindings = mappings, .trigger = trigger } });
            try sink.save(sink.context, text.written());
        }
        if (self.entries.getPtr(key)) |previous| {
            self.free(previous.*);
            previous.* = owned;
            self.gpa.free(key);
        } else self.entries.putAssumeCapacity(key, owned);
    }

    pub fn remove(self: *Overrides, owner: []const u8, name: []const u8, persistence: ?Persistence) !void {
        const key = try stableKey(self.gpa, owner, name);
        defer self.gpa.free(key);
        const index = self.entries.getIndex(key) orelse return;
        if (persistence) |sink| {
            var text: std.Io.Writer.Allocating = .init(self.gpa);
            defer text.deinit();
            try self.writeChanging(&text.writer, .{ .control = .{ .owner = owner, .name = name, .bindings = null, .trigger = null } });
            try sink.save(sink.context, text.written());
        }
        self.gpa.free(self.entries.keys()[index]);
        self.free(self.entries.values()[index]);
        self.entries.orderedRemoveAt(index);
    }

    fn writeChanging(self: *const Overrides, writer: *std.Io.Writer, change: Change) !void {
        try writer.writeAll(".{ .version = 1, .controls = .{\n");
        for (self.entries.values()) |entry| {
            if (change == .control and std.mem.eql(u8, change.control.owner, entry.owner) and std.mem.eql(u8, change.control.name, entry.name)) continue;
            try writeControl(writer, entry.owner, entry.name, entry.bindings, entry.trigger);
            try writer.writeAll(",\n");
        }
        if (change == .control) if (change.control.bindings) |replacement| {
            try writeControl(writer, change.control.owner, change.control.name, replacement, change.control.trigger);
            try writer.writeAll(",\n");
        };
        try writer.writeAll("}, .maps = .{\n");
        for (self.maps.keys(), self.maps.values()) |owner, defaults| {
            if (change == .map and std.mem.eql(u8, owner, change.map.owner)) continue;
            try std.zon.stringify.serialize(SavedMap{ .owner = owner, .priority = defaults.priority, .enabled = defaults.enabled }, .{}, writer);
            try writer.writeAll(",\n");
        }
        if (change == .map) if (change.map.value) |defaults| {
            try std.zon.stringify.serialize(SavedMap{ .owner = change.map.owner, .priority = defaults.priority, .enabled = defaults.enabled }, .{}, writer);
            try writer.writeAll(",\n");
        };
        try writer.writeAll("} }\n");
    }

    /// Parse all overrides transactionally. Unknown/unregistered controls remain available for
    /// later plugin registration; malformed bindings never replace a working configuration.
    pub fn read(self: *Overrides, source: [:0]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const saved = try std.zon.parse.fromSliceAlloc(Saved, arena.allocator(), source, null, .{});
        if (saved.version != 1) return error.UnsupportedInputSettings;
        var replacement = Overrides.init(self.gpa);
        errdefer replacement.deinit();
        for (saved.maps) |map| {
            if (replacement.maps.contains(map.owner)) return error.DuplicateControls;
            try replacement.setMap(map.owner, .{ .priority = map.priority, .enabled = map.enabled }, null);
        }
        for (saved.controls) |control| {
            const mappings = try self.gpa.alloc(types.Binding, control.bindings.len);
            defer self.gpa.free(mappings);
            for (mappings, control.bindings) |*mapping, saved_binding| mapping.* = switch (saved_binding) {
                .key => |key| .{ .key = key },
                .mouse => |button| .{ .mouse = button },
                .controller => |controller| .{ .controller = .{ .button = controller.button } },
                .key_axis => |value| .{ .key_axis = value },
                .keys_2d => |value| .{ .keys_2d = value },
                .controller_axis => |value| .{ .controller_axis = .{ .axis = value.axis, .dead_zone = value.dead_zone, .scale = value.scale } },
                .controller_stick => |value| .{ .controller_stick = .{ .stick = value.stick, .dead_zone = value.dead_zone, .scale = value.scale } },
                .mouse_delta => |value| .{ .mouse_delta = value },
                .mouse_wheel => |value| .{ .mouse_wheel = value },
            };
            try validate(mappings, true);
            const key = try stableKey(self.gpa, control.owner, control.name);
            defer self.gpa.free(key);
            if (replacement.entries.contains(key)) return error.DuplicateControls;
            if (control.trigger) |trigger| try @import("mapping.zig").validateTrigger(.button, trigger);
            try replacement.set(control.owner, control.name, mappings, control.trigger, null);
        }
        self.deinit();
        self.* = replacement;
    }
};

fn writeControl(writer: *std.Io.Writer, owner: []const u8, name: []const u8, mappings: []const types.Binding, trigger: ?types.Trigger) !void {
    try writer.writeAll(".{ .owner = ");
    try std.zon.stringify.serialize(owner, .{ .whitespace = false }, writer);
    try writer.writeAll(", .name = ");
    try std.zon.stringify.serialize(name, .{ .whitespace = false }, writer);
    try writer.writeAll(", .bindings = .{");
    for (mappings) |mapping| {
        const saved: SavedBinding = switch (mapping) {
            .key => |key| .{ .key = key },
            .mouse => |button| .{ .mouse = button },
            .controller => |controller| blk: {
                if (controller.device != null) return error.TransientControllerBinding;
                break :blk .{ .controller = .{ .button = controller.button } };
            },
            .key_axis => |value| .{ .key_axis = value },
            .keys_2d => |value| .{ .keys_2d = value },
            .controller_axis => |value| blk: {
                if (value.device != null) return error.TransientControllerBinding;
                break :blk .{ .controller_axis = .{ .axis = value.axis, .dead_zone = value.dead_zone, .scale = value.scale } };
            },
            .controller_stick => |value| blk: {
                if (value.device != null) return error.TransientControllerBinding;
                break :blk .{ .controller_stick = .{ .stick = value.stick, .dead_zone = value.dead_zone, .scale = value.scale } };
            },
            .mouse_delta => |value| .{ .mouse_delta = value },
            .mouse_wheel => |value| .{ .mouse_wheel = value },
        };
        try std.zon.stringify.serialize(saved, .{ .whitespace = false }, writer);
        try writer.writeByte(',');
    }
    try writer.writeAll("}, .trigger = ");
    try std.zon.stringify.serialize(trigger, .{ .whitespace = false }, writer);
    try writer.writeAll(" }");
}

test "saved overrides use stable owner/tag names and failed saves preserve the active binding" {
    const Sink = struct {
        fn fail(_: *anyopaque, _: []const u8) !void {
            return error.AccessDenied;
        }
    };
    var overrides = Overrides.init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.read(".{ .controls = .{ .{ .owner = \"game\", .name = \"jump\", .bindings = .{ .{ .key = .space } } } } }");
    const key = try stableKey(std.testing.allocator, "game", "jump");
    defer std.testing.allocator.free(key);
    var context: u8 = 0;
    try std.testing.expectError(error.AccessDenied, overrides.set("game", "jump", &.{.{ .key = .j }}, null, .{ .context = &context, .save = Sink.fail }));
    try std.testing.expectEqual(types.Key.space, overrides.get(key).?[0].key);
    try std.testing.expectError(error.TransientControllerBinding, validate(&.{.{ .controller = .{ .device = @enumFromInt(1), .button = .south } }}, true));
}
