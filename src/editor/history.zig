//! Undo and redo: every change the editor makes, as steps to go back and forward through.
//! Changes to the scene are found rather than reported: a few times a second the world is
//! compared with the state last recorded, and a difference becomes a step (typing into a field
//! becomes one step, once the field is left or the typing pauses), and so is the dock's layout.
//! File changes, preference edits and opening scenes are recorded as they are made. The editor carries steps out (`Step` says what each
//! undoes and redoes); this keeps the order.
const std = @import("std");
const eggy = @import("eggy");

/// The most steps kept; older ones are forgotten.
const max_steps = 100;
/// How long typing must pause before what was typed becomes a step.
const typing_pause_ms = 1000;

/// One change, owning its text. The editor fills in what it learns while carrying a step out
/// (where a file went in the trash) so it can carry it back.
/// A change as the text before and after it, owned.
pub const Texts = eggy.Action([]u8);

/// Scene text plus optional traversal positions for an explicit entity command's selection.
pub const SceneChange = struct {
    before: []u8,
    after: []u8,
    selection_recorded: bool = false,
    selection_before: ?usize = null,
    selection_after: ?usize = null,

    pub fn value(self: SceneChange, direction: eggy.Direction) []u8 {
        return if (direction == .undo) self.before else self.after;
    }
};

pub const Step = union(enum) {
    /// The world went from `before` to `after` (both scene files' text).
    scene: SceneChange,
    /// Editor-only visibility of an entity at a scene traversal position.
    entity_visibility: struct { place: usize, before: bool, after: bool },
    /// Several changes presented as one user operation, owning the label and children.
    group: struct { label: []u8, steps: []Step },
    /// A file or folder was renamed (or moved).
    rename: struct { from: []u8, to: []u8 },
    /// A file or folder was deleted: moved into the trash at `trashed`.
    delete: struct { path: []u8, trashed: []u8 },
    /// A file or folder was made (a new folder, a duplicate); undone, it waits in `trashed`.
    create: struct { path: []u8, trashed: ?[]u8 = null },
    /// Plugin `key` was turned on (`on`) or off.
    plugin: struct { key: []u8, on: bool },
    /// A preference changed from `before` to `after` (ZON literals; null: not set).
    preference: struct { layer: eggy.preferences.Store.Layer, key: []u8, field: []u8, before: ?[]u8, after: ?[]u8 },
    /// The project's settings (`eggy.zon`) went from `before` to `after` (its text).
    project_settings: Texts,
    input_bindings: Texts,
    /// The complete defaults in one `.inmap.zon` asset.
    input_map: struct { path: []u8, text: Texts },
    /// An authored animation clip file went from `text.before` to `text.after`.
    animation_clip: struct { path: []u8, text: Texts },
    /// The dock's panels were rearranged from `before` to `after` (layout snapshots).
    layout: Texts,
    /// Another scene was opened, or a new one made (`created`; undone, its file waits in
    /// `trashed`): the open scene went from `from` (none: no scene) to `to`, each with its world
    /// (scene text) and the hash of what its file held.
    open_scene: struct {
        from: ?[]u8,
        from_world: []u8,
        from_saved: ?u64,
        to: []u8,
        to_world: []u8,
        to_saved: ?u64,
        created: bool,
        trashed: ?[]u8 = null,
    },

    /// Free this editor history step's owned strings and recursive children with their
    /// original allocator. Does not undo effects or delete files; do not reuse the step.
    ///
    /// ```zig
    /// var step = Step{ .plugin = .{ .key = try gpa.dupe(u8, "weather"), .on = true } };
    /// defer step.deinit(gpa); // Unless ownership is transferred to History.record.
    /// ```
    pub fn deinit(self: *Step, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .entity_visibility => {},
            .group => |group| {
                for (group.steps) |*step| step.deinit(gpa);
                gpa.free(group.steps);
                gpa.free(group.label);
            },
            .scene => |step| {
                gpa.free(step.before);
                gpa.free(step.after);
            },
            .rename => |step| {
                gpa.free(step.from);
                gpa.free(step.to);
            },
            .delete => |step| {
                gpa.free(step.path);
                gpa.free(step.trashed);
            },
            .create => |step| {
                gpa.free(step.path);
                if (step.trashed) |trashed| gpa.free(trashed);
            },
            .plugin => |step| gpa.free(step.key),
            .input_map => |step| {
                gpa.free(step.path);
                gpa.free(step.text.before);
                gpa.free(step.text.after);
            },
            .animation_clip => |step| {
                gpa.free(step.path);
                gpa.free(step.text.before);
                gpa.free(step.text.after);
            },
            .layout, .project_settings, .input_bindings => |step| {
                gpa.free(step.before);
                gpa.free(step.after);
            },
            .open_scene => |step| {
                if (step.from) |path| gpa.free(path);
                gpa.free(step.from_world);
                gpa.free(step.to);
                gpa.free(step.to_world);
                if (step.trashed) |trashed| gpa.free(trashed);
            },
            .preference => |step| {
                gpa.free(step.key);
                gpa.free(step.field);
                if (step.before) |text| gpa.free(text);
                if (step.after) |text| gpa.free(text);
            },
        }
    }

    /// What it was, for the Console and the Edit menu.
    /// Returns static text or a borrowed group label, valid while that step remains alive.
    ///
    /// ```zig
    /// if (history.peek(.undo)) |step| std.log.info("Undo {s}", .{step.describe()});
    /// ```
    pub fn describe(self: Step) []const u8 {
        return switch (self) {
            .group => |group| group.label,
            .scene => "a scene change",
            .entity_visibility => "editor visibility",
            .rename => "a rename",
            .delete => "a deletion",
            .create => "a new file",
            .preference => "a preference",
            .layout => "a layout change",
            .project_settings => "a project setting",
            .input_bindings => "input mappings",
            .input_map => "an input map",
            .animation_clip => "an animation edit",
            .open_scene => |step| if (step.created) "a new scene" else "opening a scene",
            .plugin => |step| if (step.on) "turning a plugin on" else "turning a plugin off",
        };
    }
};

pub const History = struct {
    gpa: std.mem.Allocator,
    undo_steps: std.ArrayList(Step) = .empty,
    redo_steps: std.ArrayList(Step) = .empty,
    /// The scene as last recorded, and its hash.
    baseline: ?[]u8 = null,
    baseline_hash: u64 = 0,
    /// When the world was first seen to differ from `baseline`, until that is recorded.
    changed_since_ms: ?u64 = null,
    /// When a preference change was last recorded, to join typing into one step.
    preference_at_ms: u64 = 0,
    group: ?struct { label: []u8, steps: std.ArrayList(Step) = .empty } = null,
    recovery_required: bool = false,

    /// Free all steps, any pending group, baseline, and list storage using `self.gpa`.
    /// Does not undo mutations; this editor-owned history must not be reused afterward.
    ///
    /// ```zig
    /// var history = History{ .gpa = gpa };
    /// defer history.deinit();
    /// ```
    pub fn deinit(self: *History) void {
        self.clear();
        self.undo_steps.deinit(self.gpa);
        self.redo_steps.deinit(self.gpa);
        if (self.baseline) |text| self.gpa.free(text);
    }

    /// Forget every step: a different scene was opened.
    /// Frees undo/redo/group entries but retains list capacity and the current baseline.
    /// Also clears pending typing and recovery state; it does not revert any effects.
    ///
    /// ```zig
    /// history.clear();
    /// history.setBaseline(try gpa.dupe(u8, opened_scene_text));
    /// ```
    pub fn clear(self: *History) void {
        if (self.group) |*group| {
            for (group.steps.items) |*step| step.deinit(self.gpa);
            group.steps.deinit(self.gpa);
            self.gpa.free(group.label);
            self.group = null;
        }
        for (self.undo_steps.items) |*step| step.deinit(self.gpa);
        for (self.redo_steps.items) |*step| step.deinit(self.gpa);
        self.undo_steps.clearRetainingCapacity();
        self.redo_steps.clearRetainingCapacity();
        self.changed_since_ms = null;
        self.recovery_required = false;
    }

    /// Take `scene_text` (owned now) as the world as it stands, without recording a step: it was
    /// just opened, or a step was just undone or redone.
    /// `scene_text` must be a distinct allocation from `self.gpa`; the old baseline is freed.
    ///
    /// ```zig
    /// history.setBaseline(try gpa.dupe(u8, scene_text));
    /// ```
    pub fn setBaseline(self: *History, scene_text: []u8) void {
        if (self.baseline) |text| self.gpa.free(text);
        self.baseline = scene_text;
        self.baseline_hash = std.hash.Wyhash.hash(0, scene_text);
        self.changed_since_ms = null;
    }

    /// Look at the world as it is now (`scene_text`, owned now): if it differs from the last
    /// recorded state, record the change, unless `typing` is under way (then wait until it ends
    /// or pauses).
    /// Always consumes a `self.gpa` allocation. `now_ms` is a monotonic millisecond clock;
    /// typing changes wait up to 1000 ms from the first difference. Allocation failures log
    /// and discard this observation rather than changing the saved baseline.
    ///
    /// ```zig
    /// // Host periodically serializes the current editor world.
    /// history.watch(try gpa.dupe(u8, scene_text), now_ms, context.wants_text);
    /// ```
    pub fn watch(self: *History, scene_text: []u8, now_ms: u64, typing: bool) void {
        const hash = std.hash.Wyhash.hash(0, scene_text);
        if (self.baseline == null) return self.setBaseline(scene_text);
        if (hash == self.baseline_hash) {
            self.gpa.free(scene_text);
            self.changed_since_ms = null;
            return;
        }
        const since = self.changed_since_ms orelse now_ms;
        self.changed_since_ms = since;
        if (typing and now_ms -| since < typing_pause_ms) {
            self.gpa.free(scene_text);
            return;
        }
        const after = self.gpa.dupe(u8, scene_text) catch |err| {
            self.gpa.free(scene_text);
            return std.log.err("cannot snapshot undo history: {t}", .{err});
        };
        self.reserve() catch |err| {
            self.gpa.free(after);
            self.gpa.free(scene_text);
            return std.log.err("cannot reserve undo history: {t}", .{err});
        };
        const before = self.baseline.?;
        self.baseline = null;
        self.record(.{ .scene = .{ .before = before, .after = after } });
        self.setBaseline(scene_text);
    }

    /// Reserve before a mutation whose history must be recorded. Does not clear redo entries.
    /// Reserves a slot in the active group or undo list; allocation failures and
    /// `HistoryNeedsRecovery` propagate before the caller changes external state.
    ///
    /// ```zig
    /// try history.reserve();
    /// // Perform the mutation, then transfer its already-allocated step:
    /// history.record(step);
    /// ```
    pub fn reserve(self: *History) !void {
        if (self.recovery_required) return error.HistoryNeedsRecovery;
        if (self.group) |*group| return group.steps.ensureUnusedCapacity(self.gpa, 1);
        try self.undo_steps.ensureUnusedCapacity(self.gpa, 1);
    }

    /// Record `step` (owned now), made just now: it can be undone, and what was undone before
    /// can't be redone any more.
    /// All step allocations must use `self.gpa`. Inside a group, appends a child instead;
    /// outside one, trims history to 100 steps. On reservation failure it frees the step and logs.
    ///
    /// ```zig
    /// history.record(.{ .rename = .{
    ///     .from = try gpa.dupe(u8, "resources/old.png"),
    ///     .to = try gpa.dupe(u8, "resources/new.png"),
    /// } });
    /// ```
    pub fn record(self: *History, step: Step) void {
        var owned = step;
        self.reserve() catch |err| {
            owned.deinit(self.gpa);
            return std.log.err("cannot record undo history: {t}", .{err});
        };
        if (self.group) |*group| {
            group.steps.appendAssumeCapacity(owned);
            return;
        }
        for (self.redo_steps.items) |*old| old.deinit(self.gpa);
        self.redo_steps.clearRetainingCapacity();
        if (self.undo_steps.items.len == max_steps) {
            var oldest = self.undo_steps.orderedRemove(0);
            oldest.deinit(self.gpa);
        }
        self.undo_steps.appendAssumeCapacity(owned);
    }

    /// Begin one named operation. Nested groups are rejected; use `cancelGroup` on failure.
    /// Copies the borrowed label; errors include `GroupAlreadyOpen`, recovery, and allocation.
    /// No external effects occur until the host performs and records its child operations.
    ///
    /// ```zig
    /// try history.beginGroup("Rename assets");
    /// // Perform changes and history.record each owned step.
    /// try history.commitGroup();
    /// ```
    pub fn beginGroup(self: *History, label: []const u8) !void {
        if (self.group != null) return error.GroupAlreadyOpen;
        try self.reserve();
        self.group = .{ .label = try self.gpa.dupe(u8, label) };
    }

    /// Commit the pending group as one entry. On allocation failure it remains open.
    /// Empty groups are discarded; `NoActionGroup` means no group was started.
    /// Success transfers all children to undo history and invalidates redo like `record`.
    ///
    /// ```zig
    /// try history.beginGroup("Batch edit");
    /// // Perform and record children here.
    /// try history.commitGroup();
    /// ```
    pub fn commitGroup(self: *History) !void {
        const group = if (self.group) |*group| group else return error.NoActionGroup;
        if (group.steps.items.len == 0) {
            group.steps.deinit(self.gpa);
            self.gpa.free(group.label);
            self.group = null;
            return;
        }
        try self.undo_steps.ensureUnusedCapacity(self.gpa, 1);
        const steps = try group.steps.toOwnedSlice(self.gpa);
        const label = group.label;
        self.group = null;
        self.record(.{ .group = .{ .label = label, .steps = steps } });
    }

    /// Revert a pending group, in reverse order. Successfully reverted children are removed;
    /// on failure the remaining group stays open for recovery and the error is propagated.
    /// `applyStep(context, *Step, eggy.Direction) !void` performs a leaf operation.
    /// Context is borrowed for this synchronous call; cancellation frees reverted children.
    ///
    /// ```zig
    /// // Host.applyStep implements the leaf handler using the supplied host pointer.
    /// try history.cancelGroup(host, Host.applyStep);
    /// ```
    pub fn cancelGroup(self: *History, context: anytype, comptime applyStep: anytype) !void {
        const group = if (self.group) |*group| group else return error.NoActionGroup;
        while (group.steps.items.len != 0) {
            const step = &group.steps.items[group.steps.items.len - 1];
            invoke(step, .undo, context, applyStep) catch |err| {
                if (err == error.HistoryNeedsRecovery) self.recovery_required = true;
                return err;
            };
            step.deinit(self.gpa);
            group.steps.items.len -= 1;
        }
        group.steps.deinit(self.gpa);
        self.gpa.free(group.label);
        self.group = null;
    }

    /// Record that preference `field` of `key` in `layer` went from `before` to `after` (ZON
    /// literals; null: not set). Typing into a field changes it on every key, so a change to the
    /// same preference as the last step, within `typing_pause_ms`, joins that step.
    /// Borrows and copies all supplied text with `self.gpa`; `now_ms` is monotonic milliseconds.
    /// This records an already-applied edit, not a write to the preference store;
    /// copying failures silently skip recording and later reservation failures log.
    ///
    /// ```zig
    /// history.recordPreference(.project, "game", "speed", "1", "2", now_ms);
    /// ```
    pub fn recordPreference(self: *History, layer: eggy.preferences.Store.Layer, key: []const u8, field: []const u8, before: ?[]const u8, after: ?[]const u8, now_ms: u64) void {
        if (self.group == null and self.undo_steps.items.len > 0 and self.redo_steps.items.len == 0 and now_ms -| self.preference_at_ms < typing_pause_ms) {
            const last = &self.undo_steps.items[self.undo_steps.items.len - 1];
            if (last.* == .preference and last.preference.layer == layer and std.mem.eql(u8, last.preference.key, key) and std.mem.eql(u8, last.preference.field, field)) {
                const copy = if (after) |text| self.gpa.dupe(u8, text) catch return else null;
                if (last.preference.after) |old| self.gpa.free(old);
                last.preference.after = copy;
                self.preference_at_ms = now_ms;
                return;
            }
        }
        const gpa = self.gpa;
        const step = Step{ .preference = .{
            .layer = layer,
            .key = gpa.dupe(u8, key) catch return,
            .field = gpa.dupe(u8, field) catch return,
            .before = if (before) |text| gpa.dupe(u8, text) catch return else null,
            .after = if (after) |text| gpa.dupe(u8, text) catch return else null,
        } };
        self.record(step);
        self.preference_at_ms = now_ms;
    }

    /// Record that the project's settings went from `before` to `after` (owned now). Typing
    /// changes them on every key, so a change within `typing_pause_ms` of the last one, when
    /// that was one too, joins it.
    /// Both texts must be allocated with `self.gpa`; ownership transfers even when merged.
    /// `now_ms` uses the same monotonic millisecond clock as preference recording.
    ///
    /// ```zig
    /// history.recordProjectSettings(
    ///     try gpa.dupe(u8, before_zon), try gpa.dupe(u8, after_zon), now_ms,
    /// );
    /// ```
    pub fn recordProjectSettings(self: *History, before: []u8, after: []u8, now_ms: u64) void {
        if (self.group == null and self.undo_steps.items.len > 0 and self.redo_steps.items.len == 0 and now_ms -| self.preference_at_ms < typing_pause_ms) {
            const last = &self.undo_steps.items[self.undo_steps.items.len - 1];
            if (last.* == .project_settings) {
                self.gpa.free(last.project_settings.after);
                last.project_settings.after = after;
                self.gpa.free(before);
                self.preference_at_ms = now_ms;
                return;
            }
        }
        self.record(.{ .project_settings = .{ .before = before, .after = after } });
        self.preference_at_ms = now_ms;
    }

    /// Inspect the next operation without changing history.
    /// Null means that direction is empty. The returned pointer is borrowed and invalidated
    /// by operations that mutate/reallocate the corresponding history list.
    ///
    /// ```zig
    /// if (history.peek(.redo)) |step| std.log.info("Redo {s}", .{step.describe()});
    /// ```
    pub fn peek(self: *History, direction: eggy.Direction) ?*Step {
        const source = if (direction == .undo) &self.undo_steps else &self.redo_steps;
        return if (source.items.len == 0) null else &source.items[source.items.len - 1];
    }

    /// Apply with one directional handler. Only a successful application moves the entry;
    /// allocation failure happens before effects. False means history is empty.
    /// `applyStep(context, *Step, eggy.Direction) !void` handles leaves; groups run in
    /// forward/reverse order with rollback on failure. Context is borrowed synchronously.
    /// Open groups/recovery block application; failed rollback requires explicit recovery.
    ///
    /// ```zig
    /// // Editor host's handler applies scene/file/settings leaves:
    /// const changed = try history.apply(.undo, host, Host.applyStep);
    /// if (changed) std.log.info("Undone", .{});
    /// ```
    pub fn apply(self: *History, direction: eggy.Direction, context: anytype, comptime applyStep: anytype) !bool {
        if (self.recovery_required) return error.HistoryNeedsRecovery;
        if (self.group != null) return error.ActionGroupOpen;
        const step = self.peek(direction) orelse return false;
        const source = if (direction == .undo) &self.undo_steps else &self.redo_steps;
        const target = if (direction == .undo) &self.redo_steps else &self.undo_steps;
        try target.ensureUnusedCapacity(self.gpa, 1);
        invoke(step, direction, context, applyStep) catch |err| {
            if (err == error.HistoryNeedsRecovery) self.recovery_required = true;
            return err;
        };
        target.appendAssumeCapacity(source.pop().?);
        return true;
    }
};

fn invoke(step: *Step, direction: eggy.Direction, context: anytype, comptime applyStep: anytype) anyerror!void {
    if (step.* != .group) return applyStep(context, step, direction);
    const steps = step.group.steps;
    var applied: usize = 0;
    while (applied < steps.len) : (applied += 1) {
        const index = if (direction == .undo) steps.len - 1 - applied else applied;
        invoke(&steps[index], direction, context, applyStep) catch |err| {
            while (applied != 0) {
                applied -= 1;
                const rollback_index = if (direction == .undo) steps.len - 1 - applied else applied;
                invoke(&steps[rollback_index], if (direction == .undo) .redo else .undo, context, applyStep) catch |rollback_error| {
                    std.log.err("history rollback failed: {t}; original error: {t}", .{ rollback_error, err });
                    return error.HistoryNeedsRecovery;
                };
            }
            return err;
        };
    }
}

fn moveForTest(history: *History, direction: eggy.Direction) ?*Step {
    const Ignore = struct {
        fn apply(_: void, _: *Step, _: eggy.Direction) !void {}
    };
    if (!(history.apply(direction, {}, Ignore.apply) catch unreachable)) return null;
    const target = if (direction == .undo) &history.redo_steps else &history.undo_steps;
    return &target.items[target.items.len - 1];
}

test "scene changes become steps, typing once it pauses, and undo and redo walk them" {
    const gpa = std.testing.allocator;
    var history = History{ .gpa = gpa };
    defer history.deinit();

    history.watch(try gpa.dupe(u8, "a"), 0, false); // the first look is the baseline
    try std.testing.expectEqual(@as(usize, 0), history.undo_steps.items.len);
    history.watch(try gpa.dupe(u8, "a"), 100, false);
    try std.testing.expectEqual(@as(usize, 0), history.undo_steps.items.len);

    history.watch(try gpa.dupe(u8, "ab"), 200, true); // typing: wait
    history.watch(try gpa.dupe(u8, "abc"), 500, true);
    try std.testing.expectEqual(@as(usize, 0), history.undo_steps.items.len);
    history.watch(try gpa.dupe(u8, "abc"), 1300, true); // paused long enough
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
    try std.testing.expectEqualStrings("a", history.undo_steps.items[0].scene.before);
    try std.testing.expectEqualStrings("abc", history.undo_steps.items[0].scene.after);

    const undone = moveForTest(&history, .undo).?;
    try std.testing.expectEqualStrings("a", undone.scene.before);
    try std.testing.expect(moveForTest(&history, .undo) == null);
    try std.testing.expect(moveForTest(&history, .redo) != null);

    // A new change after an undo drops what could be redone.
    _ = moveForTest(&history, .undo);
    history.record(.{ .rename = .{ .from = try gpa.dupe(u8, "x"), .to = try gpa.dupe(u8, "y") } });
    try std.testing.expect(moveForTest(&history, .redo) == null);
}

test "layout and scene-opening steps own their text" {
    const gpa = std.testing.allocator;
    var history = History{ .gpa = gpa };
    defer history.deinit();
    history.record(.{ .layout = .{ .before = try gpa.dupe(u8, "a"), .after = try gpa.dupe(u8, "b") } });
    history.record(.{ .open_scene = .{
        .from = null,
        .from_world = try gpa.dupe(u8, ".{}"),
        .from_saved = null,
        .to = try gpa.dupe(u8, "resources/scene/sewer.scene.zon"),
        .to_world = try gpa.dupe(u8, ".{}"),
        .to_saved = 1,
        .created = true,
    } });
    try std.testing.expectEqualStrings("a new scene", moveForTest(&history, .undo).?.describe());
    try std.testing.expectEqualStrings("a layout change", moveForTest(&history, .undo).?.describe());
}

test "typing into the project's settings is one step" {
    const gpa = std.testing.allocator;
    var history = History{ .gpa = gpa };
    defer history.deinit();
    history.recordProjectSettings(try gpa.dupe(u8, "a"), try gpa.dupe(u8, "ab"), 0);
    history.recordProjectSettings(try gpa.dupe(u8, "ab"), try gpa.dupe(u8, "abc"), 300);
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
    try std.testing.expectEqualStrings("a", history.undo_steps.items[0].project_settings.before);
    try std.testing.expectEqualStrings("abc", history.undo_steps.items[0].project_settings.after);
    // After a pause, another.
    history.recordProjectSettings(try gpa.dupe(u8, "abc"), try gpa.dupe(u8, "abcd"), 5000);
    try std.testing.expectEqual(@as(usize, 2), history.undo_steps.items.len);
}

test "failed applications and failed reservations leave history in place" {
    const Handler = struct {
        fn apply(fail: *bool, _: *Step, _: eggy.Direction) !void {
            if (fail.*) return error.CannotApply;
        }
    };
    const gpa = std.testing.allocator;
    var history = History{ .gpa = gpa };
    defer history.deinit();
    history.record(.{ .project_settings = .{ .before = try gpa.dupe(u8, "a"), .after = try gpa.dupe(u8, "b") } });
    var fail = true;
    try std.testing.expectError(error.CannotApply, history.apply(.undo, &fail, Handler.apply));
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
    try std.testing.expectEqual(@as(usize, 0), history.redo_steps.items.len);

    history.redo_steps.deinit(gpa);
    history.redo_steps = .empty;
    var allocator = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    history.gpa = allocator.allocator();
    fail = false;
    try std.testing.expectError(error.OutOfMemory, history.apply(.undo, &fail, Handler.apply));
    history.gpa = gpa;
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
    try std.testing.expect(try history.apply(.undo, &fail, Handler.apply));
    try std.testing.expect(try history.apply(.redo, &fail, Handler.apply));
}

test "grouped actions undo together and failed redo rolls earlier children back" {
    const State = struct {
        value: u32 = 2,
        reject: ?u32 = null,
        fn apply(self: *@This(), step: *Step, direction: eggy.Direction) !void {
            const value = try std.fmt.parseInt(u32, step.project_settings.value(direction), 10);
            if (self.reject == value) return error.RejectedValue;
            self.value = value;
        }
    };
    const gpa = std.testing.allocator;
    var history = History{ .gpa = gpa };
    defer history.deinit();
    try history.beginGroup("two edits");
    try std.testing.expectError(error.GroupAlreadyOpen, history.beginGroup("nested"));
    history.record(.{ .project_settings = .{ .before = try gpa.dupe(u8, "0"), .after = try gpa.dupe(u8, "1") } });
    history.record(.{ .project_settings = .{ .before = try gpa.dupe(u8, "1"), .after = try gpa.dupe(u8, "2") } });
    try history.commitGroup();
    var state = State{};
    try std.testing.expect(try history.apply(.undo, &state, State.apply));
    try std.testing.expectEqual(@as(u32, 0), state.value);
    state.reject = 2;
    try std.testing.expectError(error.RejectedValue, history.apply(.redo, &state, State.apply));
    try std.testing.expectEqual(@as(u32, 0), state.value);
    try std.testing.expectEqual(@as(usize, 1), history.redo_steps.items.len);
    state.reject = null;
    try std.testing.expect(try history.apply(.redo, &state, State.apply));
    try std.testing.expectEqual(@as(u32, 2), state.value);

    try history.beginGroup("cancel me");
    history.record(.{ .project_settings = .{ .before = try gpa.dupe(u8, "2"), .after = try gpa.dupe(u8, "3") } });
    state.value = 3;
    try history.cancelGroup(&state, State.apply);
    try std.testing.expectEqual(@as(u32, 2), state.value);
    try std.testing.expect(history.group == null);
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
}
