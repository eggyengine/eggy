//! Undo and redo: every change the editor makes, as steps to go back and forward through.
//! Changes to the scene are found rather than reported: a few times a second the world is
//! compared with the state last recorded, and a difference becomes a step (typing into a field
//! becomes one step, once the field is left or the typing pauses). File changes and preference
//! edits are recorded as they are made. The editor carries steps out (`Step` says what each
//! undoes and redoes); this keeps the order.
const std = @import("std");
const eggy = @import("eggy");

/// The most steps kept; older ones are forgotten.
const max_steps = 100;
/// How long typing must pause before what was typed becomes a step.
const typing_pause_ms = 1000;

/// One change, owning its text. The editor fills in what it learns while carrying a step out
/// (where a file went in the trash) so it can carry it back.
pub const Step = union(enum) {
    /// The world went from `before` to `after` (both scene files' text).
    scene: struct { before: []u8, after: []u8 },
    /// A file or folder was renamed (or moved).
    rename: struct { from: []u8, to: []u8 },
    /// A file or folder was deleted: moved into the trash at `trashed`.
    delete: struct { path: []u8, trashed: []u8 },
    /// A file or folder was made (a new folder, a duplicate); undone, it waits in `trashed`.
    create: struct { path: []u8, trashed: ?[]u8 = null },
    /// A preference changed from `before` to `after` (ZON literals; null: not set).
    preference: struct { layer: eggy.preferences.Store.Layer, key: []u8, field: []u8, before: ?[]u8, after: ?[]u8 },

    pub fn deinit(self: *Step, gpa: std.mem.Allocator) void {
        switch (self.*) {
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
            .preference => |step| {
                gpa.free(step.key);
                gpa.free(step.field);
                if (step.before) |text| gpa.free(text);
                if (step.after) |text| gpa.free(text);
            },
        }
    }

    /// What it was, for the Console and the Edit menu.
    pub fn describe(self: Step) []const u8 {
        return switch (self) {
            .scene => "a scene change",
            .rename => "a rename",
            .delete => "a deletion",
            .create => "a new file",
            .preference => "a preference",
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

    pub fn deinit(self: *History) void {
        self.clear();
        self.undo_steps.deinit(self.gpa);
        self.redo_steps.deinit(self.gpa);
        if (self.baseline) |text| self.gpa.free(text);
    }

    /// Forget every step: a different scene was opened.
    pub fn clear(self: *History) void {
        for (self.undo_steps.items) |*step| step.deinit(self.gpa);
        for (self.redo_steps.items) |*step| step.deinit(self.gpa);
        self.undo_steps.clearRetainingCapacity();
        self.redo_steps.clearRetainingCapacity();
        self.changed_since_ms = null;
    }

    /// Take `scene_text` (owned now) as the world as it stands, without recording a step: it was
    /// just opened, or a step was just undone or redone.
    pub fn setBaseline(self: *History, scene_text: []u8) void {
        if (self.baseline) |text| self.gpa.free(text);
        self.baseline = scene_text;
        self.baseline_hash = std.hash.Wyhash.hash(0, scene_text);
        self.changed_since_ms = null;
    }

    /// Look at the world as it is now (`scene_text`, owned now): if it differs from the last
    /// recorded state, record the change, unless `typing` is under way (then wait until it ends
    /// or pauses).
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
        const before = self.baseline.?;
        self.baseline = null;
        self.record(.{ .scene = .{ .before = before, .after = self.gpa.dupe(u8, scene_text) catch {
            self.gpa.free(before);
            self.gpa.free(scene_text);
            return;
        } } });
        self.setBaseline(scene_text);
    }

    /// Record `step` (owned now), made just now: it can be undone, and what was undone before
    /// can't be redone any more.
    pub fn record(self: *History, step: Step) void {
        var owned = step;
        for (self.redo_steps.items) |*old| old.deinit(self.gpa);
        self.redo_steps.clearRetainingCapacity();
        if (self.undo_steps.items.len == max_steps) {
            var oldest = self.undo_steps.orderedRemove(0);
            oldest.deinit(self.gpa);
        }
        self.undo_steps.append(self.gpa, owned) catch owned.deinit(self.gpa);
    }

    /// Record that preference `field` of `key` in `layer` went from `before` to `after` (ZON
    /// literals; null: not set). Typing into a field changes it on every key, so a change to the
    /// same preference as the last step, within `typing_pause_ms`, joins that step.
    pub fn recordPreference(self: *History, layer: eggy.preferences.Store.Layer, key: []const u8, field: []const u8, before: ?[]const u8, after: ?[]const u8, now_ms: u64) void {
        if (self.undo_steps.items.len > 0 and self.redo_steps.items.len == 0 and now_ms -| self.preference_at_ms < typing_pause_ms) {
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

    /// The step to undo, moved onto the redo stack; the caller carries it back. Null with none.
    pub fn undo(self: *History) ?*Step {
        const step = self.undo_steps.pop() orelse return null;
        self.redo_steps.append(self.gpa, step) catch {
            var lost = step;
            lost.deinit(self.gpa);
            return null;
        };
        return &self.redo_steps.items[self.redo_steps.items.len - 1];
    }

    /// The step to redo, moved back onto the undo stack; the caller carries it out again.
    pub fn redo(self: *History) ?*Step {
        const step = self.redo_steps.pop() orelse return null;
        self.undo_steps.append(self.gpa, step) catch {
            var lost = step;
            lost.deinit(self.gpa);
            return null;
        };
        return &self.undo_steps.items[self.undo_steps.items.len - 1];
    }
};

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

    const undone = history.undo().?;
    try std.testing.expectEqualStrings("a", undone.scene.before);
    try std.testing.expect(history.undo() == null);
    try std.testing.expect(history.redo() != null);

    // A new change after an undo drops what could be redone.
    _ = history.undo();
    history.record(.{ .rename = .{ .from = try gpa.dupe(u8, "x"), .to = try gpa.dupe(u8, "y") } });
    try std.testing.expect(history.redo() == null);
}
