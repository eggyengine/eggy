//! Complete input maps stored as `.inmap.zon` resources.
const std = @import("std");
const zon_file = @import("eggy_assets").zon;
const t = @import("types.zig");
const bindings = @import("bindings.zig");
const resolution = @import("resolution.zig");

pub const extension = ".inmap.zon";
pub const Control = struct {
    name: []const u8,
    kind: t.Kind = .button,
    trigger: t.Trigger = .immediate,
    bindings: []const t.Binding = &.{},
};
const SavedControl = struct {
    name: []const u8,
    kind: t.Kind = .button,
    trigger: t.Trigger = .immediate,
    bindings: []const bindings.SavedBinding = &.{},
};
const Saved = struct {
    version: u32 = 1,
    priority: i32 = 0,
    enabled: bool = true,
    consume: bool = true,
    controls: []const SavedControl = &.{},
};

/// Defaults for one map; its published owner/key comes from the game's FileMap declaration.
pub const File = struct {
    version: u32 = 1,
    priority: i32 = 0,
    enabled: bool = true,
    consume: bool = true,
    controls: []const Control = &.{},

    /// Parse and validate into caller-owned arena storage. Invalid files never register controls.
    /// `source` is sentinel-terminated ZON. Returned strings, bindings and controls live in
    /// `arena`; release the arena even after failure, since partial parse allocations remain.
    ///
    /// ```zig
    /// var arena = std.heap.ArenaAllocator.init(gpa);
    /// defer arena.deinit();
    /// const file = try File.parse(arena.allocator(), ".{ .controls = .{} }");
    /// ```
    pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) !File {
        const saved = try zon_file.parse(Saved, arena, source, .{});
        const controls = try arena.alloc(Control, saved.controls.len);
        for (controls, saved.controls) |*control, source_control| {
            const mappings = try arena.alloc(t.Binding, source_control.bindings.len);
            for (mappings, source_control.bindings) |*mapping, saved_binding| mapping.* = saved_binding.binding();
            control.* = .{ .name = source_control.name, .kind = source_control.kind, .trigger = source_control.trigger, .bindings = mappings };
        }
        const file = File{ .version = saved.version, .priority = saved.priority, .enabled = saved.enabled, .consume = saved.consume, .controls = controls };
        try file.validate(arena);
        return file;
    }

    /// Validate names, persistent bindings, value kinds and the complete chord graph.
    /// Host/tool helper: borrows the file and uses `gpa` only for scratch allocations.
    /// Rejects unsupported versions, duplicate/invalid names, transient devices and bad chords.
    ///
    /// ```zig
    /// const file = File{ .controls = &.{.{ .name = "jump", .bindings = &.{.{ .key = .space }} }} };
    /// try file.validate(gpa);
    /// ```
    pub fn validate(self: File, gpa: std.mem.Allocator) !void {
        if (self.version != 1) return error.UnsupportedInputMap;
        const checked = try gpa.alloc(struct {
            owner: []const u8 = "",
            key: []const u8,
            name: []const u8,
            kind: t.Kind,
            trigger: t.Trigger,
            defaults: []const t.Binding,
        }, self.controls.len);
        defer gpa.free(checked);
        for (self.controls, checked, 0..) |control, *entry, i| {
            if (control.name.len == 0 or std.mem.indexOfScalar(u8, control.name, 0) != null) return error.InvalidControlName;
            for (self.controls[0..i]) |previous| if (std.mem.eql(u8, previous.name, control.name)) return error.DuplicateControls;
            try bindings.validate(control.bindings, true);
            entry.* = .{ .key = control.name, .name = control.name, .kind = control.kind, .trigger = control.trigger, .defaults = control.bindings };
        }
        var overrides = bindings.Overrides.init(gpa);
        defer overrides.deinit();
        try resolution.validate(checked, &overrides, null);
    }

    /// Describe this file to a host-local editor resolver, preserving its file order.
    /// Host-only: allocate the outer array in `arena`; names, triggers and bindings still
    /// borrow this file's storage. Tags are zero-based file indices, not a game's enum tags.
    /// Requires a validated file; allocation errors propagate.
    ///
    /// ```zig
    /// // Host with validated file and an arena that outlives registration:
    /// const definitions = try file.definitions(arena.allocator());
    /// ```
    pub fn definitions(self: File, arena: std.mem.Allocator) ![]t.ControlDefinition {
        const result = try arena.alloc(t.ControlDefinition, self.controls.len);
        for (result, self.controls, 0..) |*definition, control, i| definition.* = .{
            .tag = i,
            .name = control.name,
            .kind = control.kind,
            .trigger = control.trigger,
            .bindings = control.bindings,
        };
        return result;
    }

    /// Write an already validated map as editable ZON.
    /// Host/tool helper: borrows `writer` and propagates writer/portable-binding conversion
    /// failures. Does not validate the complete map, flush, or save to disk.
    ///
    /// ```zig
    /// var text: std.Io.Writer.Allocating = .init(gpa);
    /// defer text.deinit();
    /// try file.write(&text.writer); // file was validated before writing.
    /// ```
    pub fn write(self: File, writer: *std.Io.Writer) !void {
        try writer.print(".{{\n    .version = {d},\n    .priority = {d},\n    .enabled = {},\n    .consume = {},\n    .controls = .{{\n", .{ self.version, self.priority, self.enabled, self.consume });
        for (self.controls) |control| {
            try writer.writeAll("        .{ .name = ");
            try std.zon.stringify.serialize(control.name, .{ .whitespace = false }, writer);
            try writer.writeAll(", .kind = ");
            try std.zon.stringify.serialize(control.kind, .{ .whitespace = false }, writer);
            try writer.writeAll(", .trigger = ");
            try std.zon.stringify.serialize(control.trigger, .{ .whitespace = false }, writer);
            try writer.writeAll(", .bindings = .{");
            for (control.bindings) |mapping| {
                try std.zon.stringify.serialize(try bindings.SavedBinding.from(mapping), .{ .whitespace = false }, writer);
                try writer.writeByte(',');
            }
            try writer.writeAll("} },\n");
        }
        try writer.writeAll("    },\n}\n");
    }
};
