//! Developer control overrides saved beside eggy.zon.
const std = @import("std");
const eggy = @import("eggy");
const history_zig = @import("history.zig");

pub const InputSettings = struct {
    gpa: std.mem.Allocator,
    state: *eggy.input_backend.State,
    project_dir: []const u8,
    pending: ?history_zig.Texts = null,

    /// Connect a stable host writer before game controls register. Configuration failures
    /// propagate instead of quietly discarding developer mappings.
    /// Editor-host only: borrows `state` and `project_dir` through `close`; allocate the
    /// state first and close this writer before destroying it. Missing files mean defaults;
    /// allocation/I/O/parse failures propagate without installing a writer.
    ///
    /// ```zig
    /// const settings = try InputSettings.open(gpa, state, project_dir);
    /// defer settings.close();
    /// // Register game/plugin controls only after the overrides have loaded.
    /// ```
    pub fn open(gpa: std.mem.Allocator, state: *eggy.input_backend.State, project_dir: []const u8) !*InputSettings {
        const self = try gpa.create(InputSettings);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .state = state, .project_dir = project_dir };
        try self.reload();
        state.persistence = .{ .context = self, .save = save };
        return self;
    }
    /// Disconnect the input persistence callback, free pending history text, and destroy
    /// this heap object. Does not free borrowed state/project path or undo saved settings.
    ///
    /// ```zig
    /// settings.close(); // Before state.deinit or freeing project_dir.
    /// ```
    pub fn close(self: *InputSettings) void {
        self.state.persistence = null;
        if (self.pending) |change| {
            self.gpa.free(change.before);
            self.gpa.free(change.after);
        }
        self.gpa.destroy(self);
    }
    /// Reload project control overrides into the borrowed backend; missing files reset them
    /// to defaults. Propagates folder/read/parse errors and records no history entry.
    ///
    /// ```zig
    /// try settings.reload(); // Host reload after an external mappings-file change.
    /// ```
    pub fn reload(self: *InputSettings) !void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        const text = dir.readFileAllocOptions(io, eggy.project.controls_file, self.gpa, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return self.state.readOverrides(".{ .controls = .{} }"),
            else => return err,
        };

        defer self.gpa.free(text);
        try self.state.readOverrides(text);
    }
    fn save(raw: *anyopaque, text: []const u8) !void {
        const self: *InputSettings = @ptrCast(@alignCast(raw));
        const before = if (self.pending == null) try self.readCurrent() else null;
        errdefer if (before) |source| self.gpa.free(source);
        const after = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(after);
        try self.write(text);
        if (self.pending) |*change| {
            self.gpa.free(change.after);
            change.after = after;
        } else self.pending = .{ .before = before.?, .after = after };
    }
    fn readCurrent(self: *InputSettings) ![]u8 {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        return dir.readFileAlloc(io, eggy.project.controls_file, self.gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => self.gpa.dupe(u8, ".{ .version = 1, .controls = .{} }\n"),
            else => return err,
        };
    }
    fn write(self: *InputSettings, text: []const u8) !void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        var atomic = try dir.createFileAtomic(io, eggy.project.controls_file, .{ .replace = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(text);
        try writer.interface.flush();
        try atomic.replace(io);
    }
    /// Transfer coalesced, already-saved mappings changes to editor undo history.
    /// `history.gpa` must match this writer's allocator; no pending change is a no-op.
    /// Reservation failure preserves the pending change for retry.
    ///
    /// ```zig
    /// try settings.recordPending(&history); // Host frame, after mapping edits.
    /// ```
    pub fn recordPending(self: *InputSettings, history: *history_zig.History) !void {
        const change = self.pending orelse return;
        try history.reserve();
        history.record(.{ .input_bindings = change });
        self.pending = null;
    }
    /// Parse borrowed control-file text, atomically replace the project file, then install
    /// those overrides without generating another history entry. Parse/allocation/write
    /// errors propagate before the active resolver changes.
    ///
    /// ```zig
    /// // In the editor's history handler for an input_bindings step:
    /// try settings.restore(step.input_bindings.value(direction));
    /// ```
    pub fn restore(self: *InputSettings, text: []const u8) !void {
        const source = try self.gpa.dupeZ(u8, text);
        defer self.gpa.free(source);
        var replacement = try self.state.prepareOverrides(source);
        errdefer replacement.deinit();
        try self.write(text);
        self.state.installOverrides(replacement);
    }
};

test "project mappings save atomically, reload by stable names, and undo without recording again" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    var state = eggy.input_backend.State.init(gpa);
    defer state.deinit();
    const settings = try InputSettings.open(gpa, &state, path);
    defer settings.close();
    const Player = eggy.input.Map(enum { jump }, .{ .key = "player", .controls = &.{.{ .control = .jump, .bindings = &.{.{ .key = .space }} }} });
    var input = eggy.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    const player = input.map(Player);
    try player.rebind(.jump, .{ .key = .j });
    try state.setMapDefaults(state.controls.values()[0].map_id, .{ .priority = 12, .enabled = false });
    var history = history_zig.History{ .gpa = gpa };
    defer history.deinit();
    try settings.recordPending(&history);
    const Apply = struct {
        fn apply(target: *InputSettings, step: *history_zig.Step, direction: eggy.Direction) !void {
            try target.restore(step.input_bindings.value(direction));
        }
    };
    try std.testing.expect(try history.apply(.undo, settings, Apply.apply));
    var bindings: [1]eggy.input.Binding = undefined;
    try std.testing.expectEqual(eggy.Key.space, (try player.getBindings(.jump, &bindings))[0].key);
    try std.testing.expectEqual(@as(i32, 0), state.owners.get(state.controls.values()[0].map_id).?.priority);
    try std.testing.expect(settings.pending == null);
    try std.testing.expect(try history.apply(.redo, settings, Apply.apply));
    try settings.reload();
    try std.testing.expectEqual(eggy.Key.j, (try player.getBindings(.jump, &bindings))[0].key);
    const saved = try settings.readCurrent();
    defer gpa.free(saved);
    var fresh = eggy.input_backend.State.init(gpa);
    defer fresh.deinit();
    const source = try gpa.dupeZ(u8, saved);
    defer gpa.free(source);
    try fresh.readOverrides(source);
    var reloaded = eggy.Input{ .backend = fresh.interface() };
    try reloaded.registerMap(Player, "game/player");
    try std.testing.expectEqual(eggy.Key.j, (try reloaded.map(Player).getBindings(.jump, &bindings))[0].key);
    try std.testing.expectEqual(@as(i32, 12), fresh.owners.get(fresh.controls.values()[0].map_id).?.priority);
    try std.testing.expect(!fresh.owners.get(fresh.controls.values()[0].map_id).?.enabled);

    // Replacing a directory cannot commit a settings file or change the active resolver.
    try tmp.dir.deleteFile(std.testing.io, eggy.project.controls_file);
    try tmp.dir.createDir(std.testing.io, eggy.project.controls_file, .default_dir);
    try std.testing.expectError(error.IsDir, settings.restore(".{ .controls = .{} }"));
    try std.testing.expectEqual(eggy.Key.j, (try player.getBindings(.jump, &bindings))[0].key);
}
