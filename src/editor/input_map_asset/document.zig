//! Editable input-map defaults, isolated from the running game's input state.
const std = @import("std");
const eggy = @import("eggy");
const File = eggy.input.asset.File;
const Control = eggy.input.asset.Control;

pub const Document = struct {
    gpa: std.mem.Allocator,
    state: eggy.input_backend.State,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    saved_configuration: u64 = 0,
    const map_id = 1;
    const owner = "asset";

    /// Parse into an independent resolver; opening an asset never changes live gameplay.
    /// Editor-only: copies validated source data into document-owned state using `gpa`.
    /// Parsing, validation and allocation errors propagate with partial state cleaned up;
    /// a successful document starts unmodified and must be released with `deinit`.
    ///
    /// ```zig
    /// var document = try Document.init(gpa, ".{}"); // Existing allocator.
    /// defer document.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, source: []const u8) !Document {
        var self = Document{ .gpa = gpa, .state = .init(gpa) };
        errdefer self.deinit();
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        try self.replace(try File.parse(arena.allocator(), try arena.allocator().dupeSentinel(u8, source, 0)));
        self.markSaved();
        return self;
    }

    /// Release editor document state once; invalidate control names/bindings and File snapshots
    /// borrowing them. Does not save or affect the live game's input resolver.
    ///
    /// ```zig
    /// var document = try Document.init(gpa, ".{}"); // Existing allocator.
    /// defer document.deinit();
    /// ```
    pub fn deinit(self: *Document) void {
        self.state.deinit();
    }

    /// Compare editor document/configuration revisions with the last `markSaved` baseline.
    /// This is revision-based, not a comparison with disk or serialized bytes.
    ///
    /// ```zig
    /// const unsaved = document.modified(); // Existing input-map Document.
    /// ```
    pub fn modified(self: *const Document) bool {
        return self.revision != self.saved_revision or self.state.configuration_revision != self.saved_configuration;
    }

    /// Accept current revisions as the editor's saved baseline without writing a file.
    /// Call after a successful save or when initializing from already-saved content.
    ///
    /// ```zig
    /// // After writing document successfully:
    /// document.markSaved();
    /// ```
    pub fn markSaved(self: *Document) void {
        self.saved_revision = self.revision;
        self.saved_configuration = self.state.configuration_revision;
    }

    /// Set whether this editor map consumes overlapping lower-priority input and bump revision.
    /// Requires an initialized document; even assigning the current value marks it modified.
    ///
    /// ```zig
    /// document.setConsume(true); // Existing Document; applies only to edited defaults.
    /// ```
    pub fn setConsume(self: *Document, value: bool) void {
        self.state.owners.getPtr(map_id).?.consume = value;
        self.revision +%= 1;
    }

    /// Snapshot effective editor values, not the temporary override representation.
    /// Editor-only: the controls array lives in `arena`, but names, bindings and chord strings
    /// borrow document state until its next mutation/deinit. Serialize/copy before editing again.
    /// The snapshot owns no resolver; allocation errors propagate.
    ///
    /// ```zig
    /// const defaults = try document.file(arena); // Existing Document and scratch arena allocator.
    /// try defaults.write(writer); // Existing std.Io.Writer pointer.
    /// ```
    pub fn file(self: *const Document, arena: std.mem.Allocator) !File {
        const controls = try arena.alloc(Control, self.state.controls.count());
        for (controls, self.state.controls.values()) |*destination, control| destination.* = .{
            .name = control.name,
            .kind = control.kind,
            .trigger = self.state.overrides.getTrigger(control.key) orelse control.trigger,
            .bindings = self.state.overrides.get(control.key) orelse control.defaults,
        };
        const map = self.state.owners.get(map_id).?;
        const defaults = self.state.overrides.maps.get(owner) orelse map.defaults;
        return .{ .priority = defaults.priority, .enabled = defaults.enabled, .consume = map.consume, .controls = controls };
    }

    fn replace(self: *Document, replacement: File) !void {
        try replacement.validate(self.gpa);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var next = eggy.input_backend.State.init(self.gpa);
        errdefer next.deinit();
        try next.register(.{
            .type_marker = map_id,
            .owner = owner,
            .priority = replacement.priority,
            .enabled = replacement.enabled,
            .consume = replacement.consume,
            .controls = try replacement.definitions(arena.allocator()),
        });
        self.state.deinit();
        self.state = next;
        self.revision +%= 1;
    }

    /// Append an editor control with default trigger/empty bindings, copying its name.
    /// Validates the complete replacement; duplicate/invalid names and allocation failures
    /// propagate without changing the document. Successful replacement invalidates old borrows.
    ///
    /// ```zig
    /// try document.addControl("move", .vector); // Existing Document without that control.
    /// ```
    pub fn addControl(self: *Document, name: []const u8, kind: eggy.input.Kind) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var snapshot = try self.file(arena.allocator());
        const controls = try arena.allocator().alloc(Control, snapshot.controls.len + 1);
        @memcpy(controls[0..snapshot.controls.len], snapshot.controls);
        controls[snapshot.controls.len] = .{ .name = name, .kind = kind };
        snapshot.controls = controls;
        try self.replace(snapshot);
    }

    /// Rename chord references together with their target.
    /// Editor-only: `index` must be a valid zero-based control index. Copies `name` and validates
    /// the replacement before swapping; failure leaves old state intact, success invalidates
    /// previously borrowed control data.
    ///
    /// ```zig
    /// try document.renameControl(0, "jump"); // Existing Document with a first control.
    /// ```
    pub fn renameControl(self: *Document, index: usize, name: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const snapshot = try self.file(arena.allocator());
        const controls = try arena.allocator().dupe(Control, snapshot.controls);
        const previous = controls[index].name;
        controls[index].name = name;
        for (controls) |*control| if (control.trigger == .chord and std.mem.eql(u8, control.trigger.chord, previous)) {
            control.trigger = .{ .chord = name };
        };
        var replacement = snapshot;
        replacement.controls = controls;
        try self.replace(replacement);
    }

    /// Refuse removal if another control still uses this control as its chord.
    /// Editor-only: use a current zero-based control index. Replacement validation/allocation
    /// failures leave the document intact; success invalidates old control borrows.
    ///
    /// ```zig
    /// try document.removeControl(0); // Existing Document; no remaining chord may reference it.
    /// ```
    pub fn removeControl(self: *Document, index: usize) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var snapshot = try self.file(arena.allocator());
        var controls: std.ArrayList(Control) = .empty;
        for (snapshot.controls, 0..) |control, i| if (i != index) try controls.append(arena.allocator(), control);
        snapshot.controls = controls.items;
        try self.replace(snapshot);
    }

    /// Changing value type explicitly clears incompatible bindings and the trigger.
    /// Editor-only: `index` must be valid; clears all bindings and sets an immediate trigger
    /// even if the kind is unchanged. Validates/swaps transactionally; errors leave old state
    /// intact, while success invalidates previous document borrows.
    ///
    /// ```zig
    /// try document.setKind(0, .axis); // Existing Document with a first control.
    /// ```
    pub fn setKind(self: *Document, index: usize, kind: eggy.input.Kind) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var snapshot = try self.file(arena.allocator());
        const controls = try arena.allocator().dupe(Control, snapshot.controls);
        controls[index].kind = kind;
        controls[index].bindings = &.{};
        controls[index].trigger = .immediate;
        snapshot.controls = controls;
        try self.replace(snapshot);
    }

    /// Validate and serialize effective editor defaults as ZON to a borrowed writer.
    /// Does not flush, save a file or mark the document saved; validation/allocation/writer
    /// failures propagate and the writer can contain a partial result.
    ///
    /// ```zig
    /// // Given Document and allocator gpa:
    /// var text: std.Io.Writer.Allocating = .init(gpa);
    /// defer text.deinit();
    /// try document.write(&text.writer);
    /// ```
    pub fn write(self: *const Document, writer: *std.Io.Writer) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const snapshot = try self.file(arena.allocator());
        try snapshot.validate(arena.allocator());
        try snapshot.write(writer);
    }
};

test "asset controls can be added, renamed with their chords, and removed transactionally" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa,
        \\.{ .controls = .{
        \\    .{ .name = "sprint", .bindings = .{ .{ .key = .left_shift } } },
        \\    .{ .name = "dash", .trigger = .{ .chord = "sprint" }, .bindings = .{ .{ .key = .f } } },
        \\} }
    );
    defer document.deinit();
    try std.testing.expect(!document.modified());
    try document.renameControl(0, "modifier");
    try std.testing.expect(document.modified());
    try std.testing.expectEqualStrings("modifier", document.state.controls.values()[1].trigger.chord);
    try std.testing.expectError(error.InvalidTrigger, document.removeControl(0));
    try std.testing.expectEqual(@as(usize, 2), document.state.controls.count());
    try std.testing.expectError(error.DuplicateControls, document.addControl("dash", .button));
    try document.addControl("move", .vector);
    try document.removeControl(1);
    try document.removeControl(0);
    try std.testing.expectEqualStrings("move", document.state.controls.values()[0].name);
    try std.testing.expectEqual(eggy.input.Kind.vector, document.state.controls.values()[0].kind);
}

test "asset serialization folds binding and map edits into full defaults" {
    var document = try Document.init(std.testing.allocator, ".{ .controls = .{ .{ .name = \"jump\", .bindings = .{ .{ .key = .space } } } } }");
    defer document.deinit();
    const id = document.state.controls.keys()[0];
    try document.state.setMappings(id, &.{.{ .key = .j }}, .{ .hold = 0.3 });
    try document.state.setMapDefaults(1, .{ .priority = 8, .enabled = false });
    try std.testing.expect(document.modified());
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try document.write(&text.writer);
    var reopened = try Document.init(std.testing.allocator, text.written());
    defer reopened.deinit();
    try std.testing.expectEqual(eggy.Key.j, reopened.state.controls.values()[0].defaults[0].key);
    try std.testing.expectEqual(@as(f32, 0.3), reopened.state.controls.values()[0].trigger.hold);
    try std.testing.expectEqual(@as(i32, 8), reopened.state.owners.get(1).?.priority);
    try std.testing.expect(!reopened.state.owners.get(1).?.enabled);
    try std.testing.expect(!reopened.modified());
}
