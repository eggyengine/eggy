//! Editable input-map defaults, isolated from the running game's input state.
const std = @import("std");
const eggy = @import("eggy");
const File = eggy.input.asset.File;
const Control = eggy.input.asset.Control;

/// How the whole map starts and shares input with other maps.
pub const MapSettings = struct { enabled: bool, priority: i32, consume: bool };

pub const Document = struct {
    gpa: std.mem.Allocator,
    state: eggy.input_backend.State,
    revision: u64 = 0,
    saved_revision: u64 = 0,
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

    /// Whether an edit came after the last `markSaved`. Revision-based, not a comparison with disk.
    ///
    /// ```zig
    /// if (document.modified()) try window.save(&history, now_ms);
    /// ```
    pub fn modified(self: *const Document) bool {
        return self.revision != self.saved_revision;
    }

    /// Accept the current revision as written, without writing a file.
    ///
    /// ```zig
    /// // After writing document successfully:
    /// document.markSaved();
    /// ```
    pub fn markSaved(self: *Document) void {
        self.saved_revision = self.revision;
    }

    /// The controls, in file order: names, kinds, triggers and bindings borrow the document
    /// until its next edit.
    ///
    /// ```zig
    /// for (document.controls()) |control| std.log.info("{s}", .{control.name});
    /// ```
    pub fn controls(self: *const Document) []const @TypeOf(self.state.controls.values()[0]) {
        return self.state.controls.values();
    }

    /// The map's startup state, priority and consumption.
    ///
    /// ```zig
    /// const settings = document.mapSettings();
    /// ```
    pub fn mapSettings(self: *const Document) MapSettings {
        const map = self.state.owners.get(map_id).?;
        return .{ .enabled = map.defaults.enabled, .priority = map.defaults.priority, .consume = map.consume };
    }

    /// Snapshot the document as a file. The controls array lives in `arena`; names, bindings and
    /// chord strings borrow document state until its next edit or deinit.
    ///
    /// ```zig
    /// const defaults = try document.file(arena); // Existing Document and scratch arena allocator.
    /// try defaults.write(writer); // Existing std.Io.Writer pointer.
    /// ```
    pub fn file(self: *const Document, arena: std.mem.Allocator) !File {
        const result = try arena.alloc(Control, self.state.controls.count());
        for (result, self.state.controls.values()) |*destination, control| destination.* = .{
            .name = control.name,
            .kind = control.kind,
            .trigger = control.trigger,
            .bindings = control.defaults,
        };
        const settings = self.mapSettings();
        return .{ .priority = settings.priority, .enabled = settings.enabled, .consume = settings.consume, .controls = result };
    }

    /// Validate `replacement` and swap it in, copying what it borrows; a refusal leaves the
    /// document as it was.
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

    /// The document as a file whose controls array (in `arena`) can be changed before `replace`.
    fn editable(self: *const Document, arena: std.mem.Allocator) !struct { file: File, controls: []Control } {
        var snapshot = try self.file(arena);
        const copy = try arena.dupe(Control, snapshot.controls);
        snapshot.controls = copy;
        return .{ .file = snapshot, .controls = copy };
    }

    /// Append a `kind` control with no bindings, copying its name.
    /// Duplicate/invalid names and allocation failures leave the document unchanged.
    ///
    /// ```zig
    /// try document.addControl("move", .vector); // Existing Document without that control.
    /// ```
    pub fn addControl(self: *Document, name: []const u8, kind: eggy.input.Kind) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var snapshot = try self.file(arena.allocator());
        const grown = try arena.allocator().alloc(Control, snapshot.controls.len + 1);
        @memcpy(grown[0..snapshot.controls.len], snapshot.controls);
        grown[snapshot.controls.len] = .{ .name = name, .kind = kind };
        snapshot.controls = grown;
        try self.replace(snapshot);
    }

    /// `control`, or `control_2`, `control_3`... whichever no control has yet, in `buffer`.
    ///
    /// ```zig
    /// var buffer: [32]u8 = undefined;
    /// try document.addControl(document.freeName(&buffer), .button);
    /// ```
    pub fn freeName(self: *const Document, buffer: []u8) []const u8 {
        var n: usize = 1;
        while (true) : (n += 1) {
            const name = if (n == 1) "control" else std.fmt.bufPrint(buffer, "control_{d}", .{n}) catch return "control";
            for (self.state.controls.values()) |control| {
                if (std.mem.eql(u8, control.name, name)) break;
            } else return name;
        }
    }

    /// Rename control `index` and the chords that name it. Invalid or taken names leave the
    /// document unchanged.
    ///
    /// ```zig
    /// try document.renameControl(0, "jump"); // Existing Document with a first control.
    /// ```
    pub fn renameControl(self: *Document, index: usize, name: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const edit = try self.editable(arena.allocator());
        const previous = edit.controls[index].name;
        edit.controls[index].name = name;
        for (edit.controls) |*control| if (control.trigger == .chord and std.mem.eql(u8, control.trigger.chord, previous)) {
            control.trigger = .{ .chord = name };
        };
        try self.replace(edit.file);
    }

    /// Remove control `index`; refused (`error.InvalidTrigger`) while another control chords
    /// with it.
    ///
    /// ```zig
    /// try document.removeControl(0); // Existing Document; no remaining chord may reference it.
    /// ```
    pub fn removeControl(self: *Document, index: usize) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var snapshot = try self.file(arena.allocator());
        var kept: std.ArrayList(Control) = .empty;
        for (snapshot.controls, 0..) |control, i| if (i != index) try kept.append(arena.allocator(), control);
        snapshot.controls = kept.items;
        try self.replace(snapshot);
    }

    /// Change control `index`'s value type, which clears its bindings (they read another type)
    /// and its trigger.
    ///
    /// ```zig
    /// try document.setKind(0, .axis); // Existing Document with a first control.
    /// ```
    pub fn setKind(self: *Document, index: usize, kind: eggy.input.Kind) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const edit = try self.editable(arena.allocator());
        edit.controls[index] = .{ .name = edit.controls[index].name, .kind = kind };
        try self.replace(edit.file);
    }

    /// Replace control `index`'s bindings with `bindings` (copied). Bindings of the wrong type
    /// or with bad numbers leave the document unchanged.
    ///
    /// ```zig
    /// try document.setBindings(0, &.{.{ .key = .space }});
    /// ```
    pub fn setBindings(self: *Document, index: usize, bindings: []const eggy.input.Binding) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const edit = try self.editable(arena.allocator());
        edit.controls[index].bindings = bindings;
        try self.replace(edit.file);
    }

    /// Set control `index`'s trigger. Chords must name another button control without a loop.
    ///
    /// ```zig
    /// try document.setTrigger(0, .{ .hold = 0.3 });
    /// ```
    pub fn setTrigger(self: *Document, index: usize, trigger: eggy.input.Trigger) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const edit = try self.editable(arena.allocator());
        edit.controls[index].trigger = trigger;
        try self.replace(edit.file);
    }

    /// Set how the map starts and shares input.
    ///
    /// ```zig
    /// try document.setMapSettings(.{ .enabled = true, .priority = 2, .consume = false });
    /// ```
    pub fn setMapSettings(self: *Document, settings: MapSettings) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var snapshot = try self.file(arena.allocator());
        snapshot.enabled = settings.enabled;
        snapshot.priority = settings.priority;
        snapshot.consume = settings.consume;
        try self.replace(snapshot);
    }

    /// Validate and serialize the document as ZON to a borrowed writer.
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
    try std.testing.expectEqualStrings("modifier", document.controls()[1].trigger.chord);
    try std.testing.expectError(error.InvalidTrigger, document.removeControl(0));
    try std.testing.expectEqual(@as(usize, 2), document.controls().len);
    try std.testing.expectError(error.DuplicateControls, document.addControl("dash", .button));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("control", document.freeName(&buffer));
    try document.addControl("control", .button);
    try std.testing.expectEqualStrings("control_2", document.freeName(&buffer));
    try document.addControl("move", .vector);
    try document.removeControl(2);
    try document.removeControl(1);
    try document.removeControl(0);
    try std.testing.expectEqualStrings("move", document.controls()[0].name);
    try std.testing.expectEqual(eggy.input.Kind.vector, document.controls()[0].kind);
}

test "binding, trigger and map edits round-trip, and bad ones change nothing" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, ".{ .controls = .{ .{ .name = \"jump\", .bindings = .{ .{ .key = .space } } }, .{ .name = \"move\", .kind = .vector } } }");
    defer document.deinit();
    try document.setBindings(0, &.{ .{ .key = .j }, .{ .controller = .{ .button = .south } } });
    try document.setTrigger(0, .{ .hold = 0.3 });
    try document.setMapSettings(.{ .enabled = false, .priority = 8, .consume = false });
    try std.testing.expectError(error.WrongControlKind, document.setBindings(1, &.{.{ .key = .w }}));
    try std.testing.expectError(error.InvalidTrigger, document.setTrigger(0, .{ .chord = "jump" }));
    try std.testing.expectError(error.InvalidTrigger, document.setTrigger(0, .{ .chord = "move" }));
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try document.write(&text.writer);
    var reopened = try Document.init(gpa, text.written());
    defer reopened.deinit();
    try std.testing.expectEqual(eggy.Key.j, reopened.controls()[0].defaults[0].key);
    try std.testing.expectEqual(@as(usize, 2), reopened.controls()[0].defaults.len);
    try std.testing.expectEqual(@as(f32, 0.3), reopened.controls()[0].trigger.hold);
    try std.testing.expectEqual(MapSettings{ .enabled = false, .priority = 8, .consume = false }, reopened.mapSettings());
    try std.testing.expectEqual(@as(usize, 0), reopened.controls()[1].defaults.len);
}

test "changing a control's type clears its bindings and trigger" {
    var document = try Document.init(std.testing.allocator, ".{ .controls = .{ .{ .name = \"jump\", .trigger = .{ .tap = 0.2 }, .bindings = .{ .{ .key = .space } } } } }");
    defer document.deinit();
    try document.setKind(0, .axis);
    try std.testing.expectEqual(eggy.input.Kind.axis, document.controls()[0].kind);
    try std.testing.expectEqual(@as(usize, 0), document.controls()[0].defaults.len);
    try std.testing.expect(document.controls()[0].trigger == .immediate);
}
