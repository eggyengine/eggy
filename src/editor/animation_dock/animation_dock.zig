//! The Animation panel: scrub and play the selected entity's `Animator` clips in the Scene, and
//! add, move and delete keys of an authored clip's tracks. Posing goes through the game library
//! (`HotGame.beginAnimationPreview`) and is undone whenever the scene is captured, so the panel
//! never leaves a pose in a saved scene. Clip edits are written to the `.clip.zon` at once and
//! recorded in History as the file's text before and after.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const Clip = eggy.assets.clip.Clip;
const Property = eggy.assets.clip.Property;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const history_zig = @import("../history.zig");
const page_style = @import("../page_style.zig");
const clip_file = @import("clip_file.zig");
const timeline = @import("timeline.zig");

const NumberEdit = ui.TextEdit(12);
const key_len = eggy.assets.id.key_len;
const key_properties = [_]struct { label: []const u8, property: Property }{
    .{ .label = "Key Position", .property = .position },
    .{ .label = "Key Rotation", .property = .rotation_deg },
    .{ .label = "Key Scale", .property = .scale },
};

/// What the panel works on, borrowed for one call.
pub const Env = struct {
    game: *const HotGame,
    app: *eggy.App,
    assets: *ProjectAssets,
    project_dir: []const u8,
    history: *history_zig.History,
    selected: ?eggy.ecs.EntityId,
    /// Whether the game is playing, which the preview gives way to.
    playing: bool,
    now_ms: u64,
};

const KeyAt = struct { track: usize, key: usize };

pub const Dock = struct {
    /// The entity being previewed (or last selected), and whether its pose is on in the library.
    entity: ?eggy.ecs.EntityId = null,
    posed: bool = false,
    /// The user scrubbed, played or keyed: the entity should show the pose at `time_s`.
    wanted: bool = false,
    /// The pose is out of date and must be shown again.
    dirty: bool = false,
    /// Showing failed twice for this entity and clips; wait for a change before trying again.
    failed: bool = false,
    retried: bool = false,
    time_s: f32 = 0,
    playing: bool = false,
    loop: bool = true,
    last_tick_ms: u64 = 0,
    /// Which clip the timeline shows: 0 the authored clip, 1 the imported one.
    source: usize = 0,
    target: usize = 0,
    selected_key: ?KeyAt = null,
    duration_edit: NumberEdit = NumberEdit.init("1") catch unreachable,
    duration_for: ?[key_len]u8 = null,
    /// The entity's clip keys, read before the first pose: posing rewrites its `Animator`.
    authored_key: [key_len]u8 = undefined,
    authored_len: usize = 0,
    imported_key: [key_len]u8 = undefined,
    imported_len: usize = 0,
    message: [160]u8 = undefined,
    message_len: usize = 0,

    /// Whether the scene is posed now: the editor then skips comparing the world with its last
    /// undo step, as the pose is not an edit.
    pub fn isPosed(self: *const Dock) bool {
        return self.posed;
    }

    /// Once a frame, before the panel is built: follow the selection, advance playback and show
    /// the pose. `visible` is whether the panel is on screen. Everything is put back when the
    /// panel hides, the game plays or another entity is selected.
    pub fn tick(self: *Dock, env: Env, visible: bool) void {
        const changed = !sameEntity(self.entity, env.selected);
        if (changed or !visible or env.playing) {
            self.release(env);
            self.entity = env.selected;
            if (changed) self.forgetEntity();
            return;
        }
        const dt_ms = if (self.last_tick_ms == 0) 0 else env.now_ms -| self.last_tick_ms;
        self.last_tick_ms = env.now_ms;
        if (!self.wanted) return;

        if (self.playing) self.advance(@as(f32, @floatFromInt(@min(dt_ms, 100))) / 1000);
        if (self.dirty and !self.failed) self.show(env);
    }

    /// Put the scene back as it was before the pose, keeping what the panel would show again.
    /// Returns whether a pose was on, for `restorePose`. Call before capturing the scene.
    pub fn liftPose(self: *Dock, env: Env) bool {
        if (!self.posed) return false;
        env.game.endAnimationPreview(env.app);
        self.posed = false;
        return true;
    }

    /// Pose the scene again after `liftPose` returned `was_posed`.
    pub fn restorePose(self: *Dock, env: Env, was_posed: bool) void {
        if (!was_posed) return;
        self.show(env);
    }

    /// Carry out an undo or redo of a clip edit: `text` becomes the file at `path` and the clip
    /// the game plays, and the pose follows.
    /// Errors: the file can't be written or `text` isn't a valid clip.
    pub fn restore(self: *Dock, env: Env, io: std.Io, project: std.Io.Dir, path: []const u8, text: []const u8) !void {
        const gpa = env.history.gpa;
        const source = try gpa.dupeZ(u8, text);
        defer gpa.free(source);
        const clip = try eggy.assets.clip.parse(gpa, source);
        defer clip.deinit(gpa);
        try clip_file.write(io, project, path, text);
        var buffer: [key_len]u8 = undefined;
        if (env.assets.keyOf(&buffer, path)) |key| try env.app.graphics.clips.replace(key, clip);
        self.selected_key = null;
        self.dirty = true;
    }

    /// Declare the panel's contents.
    pub fn build(self: *Dock, context: *ui.Context, env: Env) void {
        const arena = context.builder().allocator;
        const entity = env.selected orelse return context.muted("Select an entity with an Animator to animate it.");
        if (!self.posed) self.readClipKeys(env, entity);
        if (self.authored_len == 0 and self.imported_len == 0) {
            context.muted("This entity has no Animator clip. Add an Animator in the Inspector, then drop a clip on it.");
            return;
        }

        // The clips to choose from: the authored one can be keyed, the imported one only viewed.
        var names: std.ArrayList([]const u8) = .empty;
        var sources: std.ArrayList(usize) = .empty;
        if (self.authored_len > 0) {
            names.append(arena, env.assets.label(arena, self.authoredKey())) catch return;
            sources.append(arena, 0) catch return;
        }
        if (self.imported_len > 0) {
            names.append(arena, env.assets.label(arena, self.importedKey())) catch return;
            sources.append(arena, 1) catch return;
        }
        var chosen: usize = 0;
        for (sources.items, 0..) |source, index| if (source == self.source) {
            chosen = index;
        };
        if (names.items.len > 1) {
            if (context.select("##animation clip", names.items, &chosen)) self.markChanged();
        }
        self.source = sources.items[chosen];
        const key = if (self.source == 0) self.authoredKey() else self.importedKey();
        const path = names.items[chosen];
        const editable = self.source == 0 and clip_file.isAuthored(path);

        // The clip shown, its length, and the transport.
        const loaded = env.app.graphics.clips.get(key);
        const duration = if (loaded) |found| found.duration_s() else 0;
        self.clampTime(duration);
        context.begin(.row);
        if (context.buttonVariant(if (self.playing) "Pause" else "Play", .default)) self.togglePlay(env, duration);
        if (context.buttonVariant("Reset pose", .outline)) self.release(env);
        _ = context.checkbox("Loop", &self.loop);
        page_style.endRow(context);

        // The timeline: the keys, then the scrub head.
        const clip: ?*const Clip = if (editable) env.app.graphics.clips.authored(key) else null;
        self.timelineStrip(context, clip, duration);
        var head = self.time_s;
        if (context.slider("##scrub", &head, 0, @max(duration, 0.01))) {
            self.time_s = head;
            self.playing = false;
            self.request();
        }
        context.muted(std.fmt.allocPrint(arena, "{d:.2} / {d:.2} s", .{ self.time_s, duration }) catch "");

        if (!editable) {
            context.muted("Imported clips are read-only: scrub and play them here.");
            return;
        }
        const editing = clip orelse {
            context.muted("This clip can't be read; fix the file in the code editor.");
            return;
        };
        self.buildEditor(context, env, entity, editing, key, path);
        if (self.message_len > 0) context.alert("Animation", self.message[0..self.message_len], true);
    }

    // The authored clip's keys and what to do with them ---------------------------------------

    fn buildEditor(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, clip: *const Clip, key: []const u8, path: []const u8) void {
        const arena = context.builder().allocator;
        context.separator();

        // The clip's length: keys can't be placed past it.
        if (self.duration_for == null or !std.mem.eql(u8, &self.duration_for.?, key)) {
            self.duration_edit.set(std.fmt.allocPrint(arena, "{d:.2}", .{clip.duration_s}) catch "1") catch {};
            self.duration_for = key[0..key_len].*;
        }
        // An edit is carried out after the whole clip is drawn: it replaces the clip drawn from.
        var pending: ?Edit = null;
        context.begin(.row);
        context.text("Duration (s)");
        _ = context.textInput("##clip duration", &self.duration_edit, "1");
        if (context.buttonVariant("Set", .outline)) {
            if (std.fmt.parseFloat(f32, std.mem.trim(u8, self.duration_edit.text(), " "))) |seconds| {
                pending = .{ .duration = seconds };
            } else |_| self.say("The duration must be a number of seconds.");
        }
        page_style.endRow(context);

        // Key the entity (or one of its children) as it is now at the head.
        var targets: std.ArrayList([]const u8) = .empty;
        targets.append(arena, "This entity") catch return;
        const listed = env.game.animationTargets(arena, env.app, entity) catch "";
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        while (lines.next()) |line| targets.append(arena, line) catch break;
        if (self.target >= targets.items.len) self.target = 0;
        context.begin(.row);
        _ = context.select("##animation target", targets.items, &self.target);
        for (key_properties) |entry| {
            if (context.buttonVariant(entry.label, .outline)) {
                const path_of_target = if (self.target == 0) "" else targets.items[self.target];
                pending = .{ .key_now = .{ .entity = entity, .target = path_of_target, .property = entry.property, .time_s = self.time_s } };
            }
        }
        page_style.endRow(context);

        // Each track and its keys; a key picked can be moved to the head or deleted.
        for (clip.tracks, 0..) |track, track_index| {
            context.text(std.fmt.allocPrint(arena, "{s}  {s}", .{ if (track.target.len == 0) "This entity" else track.target, @tagName(track.property) }) catch "");
            context.begin(.row);
            for (track.keys, 0..) |at, key_index| {
                const label = std.fmt.allocPrint(arena, "{d:.2}##key{d}_{d}", .{ at.time_s, track_index, key_index }) catch continue;
                const picked = if (self.selected_key) |found| found.track == track_index and found.key == key_index else false;
                if (context.buttonVariant(label, if (picked) .default else .outline)) {
                    self.selected_key = .{ .track = track_index, .key = key_index };
                    self.time_s = at.time_s;
                    self.playing = false;
                    self.request();
                }
            }
            context.end();
        }
        if (self.selected_key) |picked| {
            if (picked.track >= clip.tracks.len or picked.key >= clip.tracks[picked.track].keys.len) {
                self.selected_key = null;
            } else {
                context.begin(.row);
                if (context.buttonVariant("Move key to head", .outline)) pending = .{ .move_key = .{ picked.track, picked.key, self.time_s } };
                if (context.buttonVariant("Delete key", .destructive)) pending = .{ .delete_key = .{ picked.track, picked.key } };
                if (context.buttonVariant("Remove track", .destructive)) pending = .{ .remove_track = picked.track };
                page_style.endRow(context);
            }
        }
        if (pending) |change| self.edit(env, clip, key, path, change);
    }

    /// An edit to the authored clip.
    const Edit = union(enum) {
        duration: f32,
        key_now: struct { entity: eggy.ecs.EntityId, target: []const u8, property: Property, time_s: f32 },
        move_key: struct { usize, usize, f32 },
        delete_key: struct { usize, usize },
        remove_track: usize,
    };

    /// Apply `change` to `clip`, write the file and record the step; a refusal shows in the panel.
    fn edit(self: *Dock, env: Env, clip: *const Clip, key: []const u8, path: []const u8, change: Edit) void {
        self.message_len = 0;
        const gpa = env.history.gpa;
        const edited = applied(env, gpa, clip, change) catch |err| return self.sayError("Can't edit the clip", err);
        defer edited.deinit(gpa);
        commit(env, edited, key, path) catch |err| return self.sayError("Can't save the clip", err);
        self.selected_key = null;
        self.dirty = true;
        self.duration_for = null;
        self.wanted = true;
    }

    fn applied(env: Env, gpa: std.mem.Allocator, clip: *const Clip, change: Edit) !Clip {
        switch (change) {
            .duration => |seconds| return clip.withDuration(gpa, seconds),
            .move_key => |move| return clip.withKeyMoved(gpa, move[0], move[1], move[2]),
            .delete_key => |gone| return clip.withoutKey(gpa, gone[0], gone[1]),
            .remove_track => |index| return clip.withoutTrack(gpa, index),
            .key_now => |now| {
                // The values as the entity (or its child) has them now, at the head.
                const numbers = env.game.animationTransform(env.app, now.entity, now.target) orelse return error.NoTransform;
                const value: [3]f32 = switch (now.property) {
                    .position => numbers[0..3].*,
                    .rotation_deg => numbers[3..6].*,
                    .scale => numbers[6..9].*,
                    .morph_weight => unreachable,
                };
                var held = try clip.clone(gpa);
                errdefer held.deinit(gpa);
                if (held.find(now.target, now.property) == null) {
                    const added = try held.withTrack(gpa, now.target, now.property);
                    held.deinit(gpa);
                    held = added;
                }
                const track = held.find(now.target, now.property).?;
                const keyed = try held.withKey(gpa, track, now.time_s, value);
                held.deinit(gpa);
                return keyed;
            },
        }
    }

    /// Write `edited` over the clip file, make the game play it, and record the step.
    fn commit(env: Env, edited: Clip, key: []const u8, path: []const u8) !void {
        const gpa = env.history.gpa;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, env.project_dir, .{});
        defer project.close(io);

        const before = try clip_file.read(gpa, io, project, path);
        errdefer gpa.free(before);
        const after = try clip_file.serialize(gpa, edited);
        errdefer gpa.free(after);
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        try clip_file.write(io, project, path, after);
        try env.app.graphics.clips.replace(key, edited);
        env.history.record(.{ .animation_clip = .{ .path = owned_path, .text = .{ .before = before, .after = after } } });
    }

    // Posing ------------------------------------------------------------------------------------

    fn show(self: *Dock, env: Env) void {
        const entity = env.selected orelse return;
        if (!self.posed) {
            if (!env.game.beginAnimationPreview(env.app, entity)) {
                self.failed = true;
                return;
            }
            self.posed = true;
        }
        if (env.game.showAnimationPreview(env.app, self.authoredKey(), self.importedKey(), self.time_s)) {
            self.dirty = false;
            self.retried = false;
            return;
        }
        // The game was restarted under the pose (an undo, a reload): begin again once.
        self.posed = false;
        if (self.retried) self.failed = true;
        self.retried = true;
    }

    /// Put the entity back and stop playing.
    fn release(self: *Dock, env: Env) void {
        if (self.posed) env.game.endAnimationPreview(env.app);
        self.posed = false;
        self.wanted = false;
        self.dirty = false;
        self.playing = false;
        self.time_s = 0;
        self.failed = false;
        self.retried = false;
    }

    fn forgetEntity(self: *Dock) void {
        self.authored_len = 0;
        self.imported_len = 0;
        self.selected_key = null;
        self.source = 0;
        self.target = 0;
        self.duration_for = null;
        self.message_len = 0;
    }

    /// Pose again at `time_s` from the next tick.
    fn request(self: *Dock) void {
        self.wanted = true;
        self.dirty = true;
        self.failed = false;
        self.retried = false;
    }

    /// Another clip was chosen: the pose, the keys and the head start over.
    fn markChanged(self: *Dock) void {
        self.selected_key = null;
        self.time_s = 0;
        self.duration_for = null;
        if (self.wanted) self.request();
    }

    fn togglePlay(self: *Dock, env: Env, duration: f32) void {
        self.playing = !self.playing;
        self.last_tick_ms = env.now_ms;
        // Playing from the end starts over.
        if (self.playing and self.time_s >= duration) self.time_s = 0;
        self.request();
    }

    fn advance(self: *Dock, dt_s: f32) void {
        if (dt_s <= 0) return;
        self.time_s += dt_s;
        self.dirty = true;
    }

    /// Keep the head inside the clip; a looping one wraps, otherwise playback stops at the end.
    fn clampTime(self: *Dock, duration: f32) void {
        if (self.time_s <= duration) return;
        if (self.loop and self.playing and duration > 0) {
            self.time_s = @mod(self.time_s, duration);
        } else {
            self.time_s = duration;
            self.playing = false;
        }
        self.dirty = true;
    }

    fn timelineStrip(self: *Dock, context: *ui.Context, clip: ?*const Clip, duration: f32) void {
        const arena = context.builder().allocator;
        var times: std.ArrayList(f32) = .empty;
        var selected: ?f32 = null;
        if (clip) |found| for (found.tracks, 0..) |track, track_index| for (track.keys, 0..) |at, key_index| {
            times.append(arena, at.time_s) catch break;
            if (self.selected_key) |picked| if (picked.track == track_index and picked.key == key_index) {
                selected = at.time_s;
            };
        };
        const strip = timeline.paint(arena, .{ .duration_s = duration, .head_s = self.time_s, .key_times_s = times.items, .selected_s = selected });
        const element = context.builder().node(0, .{ .height = 18 }, strip, &.{}) catch return;
        context.element(element);
    }

    // The entity's clips ---------------------------------------------------------------------

    fn authoredKey(self: *const Dock) []const u8 {
        return self.authored_key[0..self.authored_len];
    }

    fn importedKey(self: *const Dock) []const u8 {
        return self.imported_key[0..self.imported_len];
    }

    /// Read the keys of the clips `entity`'s `Animator` plays, from the world as it is.
    fn readClipKeys(self: *Dock, env: Env, entity: eggy.ecs.EntityId) void {
        self.authored_len = 0;
        self.imported_len = 0;
        const component = env.game.builtinComponent("Animator") orelse return;
        if (!env.game.hasComponent(env.app, entity, component)) return;
        const fields = env.game.component_types[component].fields;
        for (fields, 0..) |field, index| {
            const target: *[key_len]u8 = if (std.mem.eql(u8, field.name, "clip")) &self.authored_key else if (std.mem.eql(u8, field.name, "model_clip")) &self.imported_key else continue;
            const len: *usize = if (target == &self.authored_key) &self.authored_len else &self.imported_len;
            var buffer: [64]u8 = undefined;
            const zon = env.game.readField(env.app, entity, component, index, &buffer) orelse continue;
            const text = unquote(zon) orelse continue;
            if (text.len != key_len) continue;
            @memcpy(target, text);
            len.* = key_len;
        }
    }

    fn say(self: *Dock, text: []const u8) void {
        const shown = text[0..@min(text.len, self.message.len)];
        @memcpy(self.message[0..shown.len], shown);
        self.message_len = shown.len;
    }

    fn sayError(self: *Dock, what: []const u8, err: anyerror) void {
        const text = std.fmt.bufPrint(&self.message, "{s}: {t}", .{ what, err }) catch &self.message;
        self.message_len = text.len;
    }
};

fn sameEntity(a: ?eggy.ecs.EntityId, b: ?eggy.ecs.EntityId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

/// The text between a ZON string's quotes; null when `zon` isn't one.
fn unquote(zon: []const u8) ?[]const u8 {
    if (zon.len < 2 or zon[0] != '"' or zon[zon.len - 1] != '"') return null;
    return zon[1 .. zon.len - 1];
}

test "a ZON string's text is found between its quotes" {
    try std.testing.expectEqualStrings("00ab", unquote("\"00ab\"").?);
    try std.testing.expectEqualStrings("", unquote("\"\"").?);
    try std.testing.expect(unquote(".{}") == null);
}

test {
    _ = clip_file;
    _ = timeline;
}
