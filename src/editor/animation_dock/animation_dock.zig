//! The Animation panel: scrub and play an `Animator`'s clips in the Scene, and edit the
//! authored clip's tracks: a row per track with its keys on a shared timeline, keys added for
//! any entity in the scene (transforms, a camera's field of view, UI text and visibility, sprite
//! frames, sounds and events), and Record, which keys whatever is moved or changed at the head.
//! The panel stays on the last entity with an `Animator` while others are selected, so a
//! cutscene's actors can be posed in turn.
//!
//! Posing goes through the game library (`HotGame.beginAnimationPreview`) and is undone whenever
//! the scene is captured, so the panel never leaves a pose in a saved scene. Clip edits are
//! written to the `.clip.zon` at once and recorded in History as the file's text before and
//! after.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const Clip = eggy.assets.clip.Clip;
const Key = eggy.assets.clip.Key;
const Property = eggy.assets.clip.Property;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const history_zig = @import("../history.zig");
const page_style = @import("../page_style.zig");
const clip_file = @import("clip_file.zig");
const timeline = @import("timeline.zig");

const NumberEdit = ui.TextEdit(12);
const NameEdit = ui.TextEdit(64);
const ValueEdit = ui.TextEdit(eggy.assets.clip.max_text_len);
const key_len = eggy.assets.id.key_len;
const max_target_len = 256;
const key_properties = [_]struct { label: []const u8, property: Property }{
    .{ .label = "Key Position", .property = .position },
    .{ .label = "Key Rotation", .property = .rotation_deg },
    .{ .label = "Key Scale", .property = .scale },
};
/// What the Key… form offers, beside the transform buttons.
const form_properties = [_]Property{ .fov_deg, .visible, .text, .sound, .event, .sprite_frame };
const form_labels = [_][]const u8{ "fov_deg (Camera)", "visible (UI)", "text (UI node)", "sound (AudioSource)", "event", "sprite_frame (SpriteAnimator)" };
/// Record keys a change bigger than this.
const record_epsilon: f32 = 1e-4;

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
    /// Whether a gizmo, 2D handle or Inspector number is being dragged: Record waits for it.
    steering: bool = false,
    now_ms: u64,
};

const KeyAt = struct { track: usize, key: usize };

/// A key to place: on the track for `target`, `property` and `node`, made if missing.
const NewKey = struct { target: []const u8, property: Property, node: []const u8 = "", key: Key };

/// What Record compares: the selected entity's transform and, for a camera, its field of view.
const Recorded = struct {
    target: [max_target_len]u8 = undefined,
    target_len: usize = 0,
    numbers: [9]f32 = undefined,
    fov_deg: ?f32 = null,

    fn targetText(self: *const Recorded) []const u8 {
        return self.target[0..self.target_len];
    }
};

pub const Dock = struct {
    /// The entity whose clips are shown (the last selected with an `Animator`), and whether its
    /// pose is on in the library.
    entity: ?eggy.ecs.EntityId = null,
    posed: bool = false,
    /// The user scrubbed, played or keyed: the scene should show the pose at `time_s`.
    wanted: bool = false,
    /// The pose is out of date and must be shown again.
    dirty: bool = false,
    /// Showing failed twice for this entity and clips; wait for a change before trying again.
    failed: bool = false,
    retried: bool = false,
    time_s: f32 = 0,
    playing: bool = false,
    loop: bool = true,
    /// Changes made in the Scene or Inspector become keys at the head.
    recording: bool = false,
    last_tick_ms: u64 = 0,
    /// Which clip the timeline shows: 0 the authored clip, 1 the imported one.
    source: usize = 0,
    target: usize = 0,
    selected_key: ?KeyAt = null,
    duration_edit: NumberEdit = NumberEdit.init("1") catch unreachable,
    duration_for: ?[key_len]u8 = null,
    /// The Key… form: shown, which property, its UI node and its value.
    form_open: bool = false,
    form_property: usize = 0,
    form_node: NameEdit = NameEdit.init("") catch unreachable,
    form_value: ValueEdit = ValueEdit.init("") catch unreachable,
    form_shown: usize = 0,
    /// What Record last saw of the selection, posed; null until the next pose is shown.
    recorded: ?Recorded = null,
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

    /// Once a frame, before the panel is built: follow the selection, advance playback, key what
    /// Record saw change, and show the pose. `visible` is whether the panel is on screen.
    /// Everything is put back when the panel hides, the game plays or another entity with an
    /// `Animator` is selected.
    pub fn tick(self: *Dock, env: Env, visible: bool) void {
        const followed = self.follow(env);
        const changed = !sameEntity(self.entity, followed);
        if (changed or !visible or env.playing) {
            self.release(env);
            self.entity = followed;
            if (changed) self.forgetEntity();
            return;
        }
        const dt_ms = if (self.last_tick_ms == 0) 0 else env.now_ms -| self.last_tick_ms;
        self.last_tick_ms = env.now_ms;
        if (!self.wanted) return;

        if (self.playing) self.advance(@as(f32, @floatFromInt(@min(dt_ms, 100))) / 1000);
        if (self.recording and self.posed and !self.dirty and !self.playing and !env.steering) self.record(env);
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
        const source = try gpa.dupeSentinel(u8, text, 0);
        defer gpa.free(source);
        const clip = try eggy.assets.clip.parse(gpa, source);
        defer clip.deinit(gpa);
        try clip_file.write(io, project, path, text);
        var buffer: [key_len]u8 = undefined;
        if (env.assets.keyOf(&buffer, path)) |key| try env.app.graphics.clips.replace(key, clip);
        self.selected_key = null;
        self.dirty = true;
        self.recorded = null;
    }

    /// Declare the panel's contents.
    pub fn build(self: *Dock, context: *ui.Context, env: Env) void {
        const arena = context.builder().allocator;
        const entity = self.entity orelse return context.muted("Select an entity with an Animator to animate it.");
        if (!self.posed) self.readClipKeys(env, entity);
        if (self.authored_len == 0 and self.imported_len == 0) {
            context.muted("No Animator clip. Drop a clip on its Animator.");
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
        self.source = sources.items[chosen];
        const key = if (self.source == 0) self.authoredKey() else self.importedKey();
        const path = names.items[chosen];
        const editable = self.source == 0 and clip_file.isAuthored(path);
        const loaded = env.app.graphics.clips.get(key);
        const duration = if (loaded) |found| found.duration_s() else 0;
        self.clampTime(duration);
        const clip: ?*const Clip = if (editable) env.app.graphics.clips.authored(key) else null;

        // The transport: the clip, play, reset, loop, Record, where the head is, and the length.
        var pending: ?Edit = null;
        context.begin(.row);
        if (names.items.len > 1) {
            if (context.select("##animation clip", names.items, &chosen)) self.markChanged();
        } else context.text(std.fs.path.basename(path));
        if (context.buttonVariant(if (self.playing) "Pause" else "Play", .default)) self.togglePlay(env, duration);
        if (context.buttonVariant("Reset pose", .outline)) self.release(env);
        _ = context.checkbox("Loop", &self.loop);
        if (editable) {
            if (context.buttonVariant(if (self.recording) "Recording" else "Record", if (self.recording) .destructive else .outline)) {
                self.recording = !self.recording;
                self.recorded = null;
                if (self.recording) {
                    self.playing = false;
                    self.request();
                }
            }
        }
        context.muted(std.fmt.allocPrint(arena, "{d:.2} / {d:.2} s", .{ self.time_s, duration }) catch "");
        if (clip) |found| pending = self.durationField(context, found, key) orelse pending;
        page_style.endRow(context);

        // The timeline: a ruler to scrub on, then a row per track.
        self.ruler(context, duration);
        if (clip) |found| {
            if (found.tracks.len == 0) context.muted("No tracks yet. Key something below.");
            for (found.tracks, 0..) |track, index| self.trackRow(context, track, index, duration);
        } else if (!editable) {
            context.muted("Imported clips play as they are; key an authored clip (.clip.zon).");
        } else {
            context.muted("This clip can't be read.");
        }

        const editing = clip orelse return;
        if (self.buildKeying(context, env, entity)) |change| pending = change;
        if (self.selectedKeyRow(context, editing)) |change| pending = change;
        if (self.message_len > 0) context.alert("Animation", self.message[0..self.message_len], true);
        if (pending) |change| self.edit(env, editing, key, path, change);
    }

    // The timeline ------------------------------------------------------------------------------

    fn ruler(self: *Dock, context: *ui.Context, duration: f32) void {
        const arena = context.builder().allocator;
        const id = context.idFor("##animation ruler");
        const element = context.builder().node(id, .{ .width = context.contentWidth(), .height = timeline.heights.ruler }, timeline.rulerPaint(arena, .{ .duration_s = duration, .head_s = self.time_s, .recording = self.recording }), &.{}) catch return;
        element.accessibility = .{ .role = .slider, .label = "Animation time", .numeric_value = self.time_s };
        context.element(element);
        // Pressing on the ruler, or dragging from it, moves the head.
        const dragging = context.pointer_held and if (context.press) |press| press.widget == id else false;
        if (!context.activated(id) and !dragging) return;
        const bounds = (context.last_bounds.get(id) orelse return).rect;
        const layout = timeline.Layout{ .width = bounds.w, .duration_s = duration };
        const time = layout.timeAt(context.pointer.x - bounds.x) orelse return;
        self.time_s = time;
        self.playing = false;
        self.request();
    }

    fn trackRow(self: *Dock, context: *ui.Context, track: eggy.assets.clip.Track, index: usize, duration: f32) void {
        const arena = context.builder().allocator;
        const picked = if (self.selected_key) |found| if (found.track == index) found.key else null else null;
        const row = timeline.rowOf(arena, track, displayTarget(track.target), duration, self.time_s, picked, self.recording) catch return;
        const id = context.idFor(std.fmt.allocPrint(arena, "##animation track {d}", .{index}) catch return);
        const element = context.builder().node(id, .{ .width = context.contentWidth(), .height = timeline.heights.row }, timeline.rowPaint(arena, row), &.{}) catch return;
        element.accessibility = .{ .role = .button, .label = std.fmt.allocPrint(arena, "{s} {s}", .{ row.target, row.property }) catch "" };
        context.element(element);
        if (!context.activated(id)) return;

        // A key under the pointer is picked and the head goes to it; elsewhere the head moves.
        const bounds = (context.last_bounds.get(id) orelse return).rect;
        const layout = timeline.Layout{ .width = bounds.w, .duration_s = duration };
        const x = context.pointer.x - bounds.x;
        if (layout.keyNear(track.keys, x)) |key| {
            self.selected_key = .{ .track = index, .key = key };
            self.time_s = track.keys[key].time_s;
        } else if (layout.timeAt(x)) |time| {
            self.selected_key = null;
            self.time_s = time;
        } else {
            // The gutter picks the track itself (a key past its last), so it can be removed.
            self.selected_key = .{ .track = index, .key = track.keys.len };
        }
        self.playing = false;
        self.request();
    }

    // Keying ------------------------------------------------------------------------------------

    fn durationField(self: *Dock, context: *ui.Context, clip: *const Clip, key: []const u8) ?Edit {
        const arena = context.builder().allocator;
        if (self.duration_for == null or !std.mem.eql(u8, &self.duration_for.?, key)) {
            self.duration_edit.set(std.fmt.allocPrint(arena, "{d:.2}", .{clip.duration_s}) catch "1") catch {};
            self.duration_for = key[0..key_len].*;
        }
        context.text("Duration (s)");
        _ = context.textInput("##clip duration", &self.duration_edit, "1");
        if (!context.buttonVariant("Set", .outline)) return null;
        const seconds = std.fmt.parseFloat(f32, std.mem.trim(u8, self.duration_edit.text(), " ")) catch {
            self.say("The duration must be a number of seconds.");
            return null;
        };
        return .{ .duration = seconds };
    }

    /// The target picker, the transform keys, and the Key… form for the other properties.
    fn buildKeying(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId) ?Edit {
        const arena = context.builder().allocator;
        var pending: ?Edit = null;

        // Targets: the entity, its children, then everything else in the scene. The selection,
        // when it is one of them, is picked for it.
        var targets: std.ArrayList([]const u8) = .empty;
        var labels: std.ArrayList([]const u8) = .empty;
        targets.append(arena, "") catch return null;
        labels.append(arena, "This entity") catch return null;
        const listed = env.game.animationTargets(arena, env.app, entity) catch "";
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        while (lines.next()) |line| {
            targets.append(arena, line) catch break;
            labels.append(arena, displayTarget(line)) catch break;
        }
        if (self.target >= targets.items.len) self.target = 0;
        const target = targets.items[self.target];

        context.begin(.row);
        _ = context.select("##animation target", labels.items, &self.target);
        for (key_properties) |entry| {
            if (context.buttonVariant(entry.label, .outline)) {
                if (env.game.animationTransform(env.app, entity, target)) |numbers| {
                    pending = .{ .keys = oneKey(arena, .{ .target = target, .property = entry.property, .key = .{ .time_s = self.time_s, .value = transformPart(numbers, entry.property) } }) };
                } else self.say("That entity has no Transform.");
            }
        }
        if (context.buttonVariant("Key…", if (self.form_open) .secondary else .outline)) self.form_open = !self.form_open;
        page_style.endRow(context);

        if (self.form_open) if (self.keyForm(context, env, entity, target)) |change| {
            pending = change;
        };
        return pending;
    }

    /// Key any other property of `target` at the head: a camera's field of view, a UI node's text
    /// or visibility, a sound, an event, a sprite frame.
    fn keyForm(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, target: []const u8) ?Edit {
        const arena = context.builder().allocator;
        context.begin(.row);
        const before = self.form_property;
        _ = context.select("##key property", &form_labels, &self.form_property);
        const property = form_properties[self.form_property];
        // A number property starts from what the target has now.
        if (before != self.form_property and !property.textual() and property != .visible) {
            if (env.game.animationValue(env.app, entity, target, property)) |value| {
                self.form_value.set(std.fmt.allocPrint(arena, "{d}", .{value[0]}) catch "") catch {};
            }
        }
        if (property.takesNode()) _ = context.textInput("##key node", &self.form_node, if (property == .text) "UI node name" else "UI node (empty: whole screen)");
        switch (property) {
            .visible => _ = context.select("##key shown", &.{ "Shown", "Hidden" }, &self.form_shown),
            .sound => _ = context.textInput("##key value", &self.form_value, "resources/sounds/buzz.wav"),
            .text => _ = context.textInput("##key value", &self.form_value, "What the node says"),
            .event => _ = context.textInput("##key value", &self.form_value, "wait_for_choice"),
            else => _ = context.textInput("##key value", &self.form_value, "0"),
        }
        const add = context.buttonVariant("Add key", .default);
        page_style.endRow(context);
        if (!add) return null;

        const node = std.mem.trim(u8, self.form_node.text(), " ");
        const value_text = std.mem.trim(u8, self.form_value.text(), " ");
        var key = Key{ .time_s = self.time_s };
        switch (property) {
            .visible => key.value[0] = if (self.form_shown == 0) 1 else 0,
            .text, .event => {
                if (value_text.len == 0 and property == .event) return self.sayNull("An event needs a name.");
                key.text = arena.dupe(u8, if (property == .text) self.form_value.text() else value_text) catch return null;
            },
            .sound => {
                // The file's asset key, so the sound follows the file when it moves.
                var buffer: [key_len]u8 = undefined;
                const sound = env.assets.keyOf(&buffer, value_text) orelse return self.sayNull("That sound isn't in the project's resources.");
                key.text = arena.dupe(u8, sound) catch return null;
            },
            else => key.value[0] = std.fmt.parseFloat(f32, value_text) catch return self.sayNull("The value must be a number."),
        }
        if (property == .text and node.len == 0) return self.sayNull("Name the UI node whose text this sets.");
        return .{ .keys = oneKey(arena, .{ .target = target, .property = property, .node = arena.dupe(u8, node) catch return null, .key = key }) };
    }

    /// The picked key: what it is, and moving or deleting it or its track.
    fn selectedKeyRow(self: *Dock, context: *ui.Context, clip: *const Clip) ?Edit {
        const picked = self.selected_key orelse return null;
        if (picked.track >= clip.tracks.len) {
            self.selected_key = null;
            return null;
        }
        const track = clip.tracks[picked.track];
        const arena = context.builder().allocator;
        var pending: ?Edit = null;
        context.begin(.row);
        var buffer: [96]u8 = undefined;
        if (picked.key < track.keys.len) {
            const key = track.keys[picked.key];
            const label = timeline.keyLabel(arena, track.property, key) catch "";
            context.muted(std.fmt.allocPrint(arena, "{s}  {s} at {d:.2} s{s}{s}", .{ displayTarget(track.target), track.label(&buffer), key.time_s, if (label.len > 0) " · " else "", label }) catch "");
            if (context.buttonVariant("Move key to head", .outline)) pending = .{ .move_key = .{ picked.track, picked.key, self.time_s } };
            if (context.buttonVariant("Delete key", .destructive)) pending = .{ .delete_key = .{ picked.track, picked.key } };
        } else context.muted(std.fmt.allocPrint(arena, "{s}  {s}", .{ displayTarget(track.target), track.label(&buffer) }) catch "");
        if (context.buttonVariant("Remove track", .destructive)) pending = .{ .remove_track = picked.track };
        page_style.endRow(context);
        return pending;
    }

    /// Key what changed on the selection since the pose was shown: position, rotation, scale,
    /// and a camera's field of view, each at the head.
    fn record(self: *Dock, env: Env) void {
        const root = self.entity orelse return;
        const selected = env.selected orelse return;
        const clip = env.app.graphics.clips.authored(self.authoredKey()) orelse return;
        const now = readRecorded(env, root, selected) orelse return;
        const before = self.recorded orelse {
            self.recorded = now;
            return;
        };
        if (!std.mem.eql(u8, before.targetText(), now.targetText())) {
            self.recorded = now;
            return;
        }
        var keys: [4]NewKey = undefined;
        var count: usize = 0;
        const target = now.targetText();
        for ([_]Property{ .position, .rotation_deg, .scale }, 0..) |property, part| {
            const was = before.numbers[part * 3 ..][0..3];
            const is = now.numbers[part * 3 ..][0..3];
            if (!differs(was, is)) continue;
            keys[count] = .{ .target = target, .property = property, .key = .{ .time_s = self.time_s, .value = is.* } };
            count += 1;
        }
        if (before.fov_deg != null and now.fov_deg != null and @abs(before.fov_deg.? - now.fov_deg.?) > record_epsilon) {
            keys[count] = .{ .target = target, .property = .fov_deg, .key = .{ .time_s = self.time_s, .value = .{ now.fov_deg.?, 0, 0 } } };
            count += 1;
        }
        self.recorded = now;
        if (count == 0) return;
        var label_buffer: [512]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&label_buffer);
        const path = env.assets.label(fixed.allocator(), self.authoredKey());
        self.edit(env, clip, self.authoredKey(), path, .{ .keys = keys[0..count] });
    }

    /// An edit to the authored clip.
    const Edit = union(enum) {
        duration: f32,
        keys: []const NewKey,
        move_key: struct { usize, usize, f32 },
        delete_key: struct { usize, usize },
        remove_track: usize,
    };

    /// Apply `change` to `clip`, write the file and record the step; a refusal shows in the panel.
    fn edit(self: *Dock, env: Env, clip: *const Clip, key: []const u8, path: []const u8, change: Edit) void {
        self.message_len = 0;
        const gpa = env.history.gpa;
        const edited = applied(gpa, clip, change) catch |err| return self.sayError("Can't edit the clip", err);
        defer edited.deinit(gpa);
        commit(env, edited, key, path) catch |err| return self.sayError("Can't save the clip", err);
        self.selected_key = null;
        self.dirty = true;
        self.duration_for = null;
        self.wanted = true;
    }

    fn applied(gpa: std.mem.Allocator, clip: *const Clip, change: Edit) !Clip {
        switch (change) {
            .duration => |seconds| return clip.withDuration(gpa, seconds),
            .move_key => |move| return clip.withKeyMoved(gpa, move[0], move[1], move[2]),
            .delete_key => |gone| return clip.withoutKey(gpa, gone[0], gone[1]),
            .remove_track => |index| return clip.withoutTrack(gpa, index),
            .keys => |keys| {
                var held = try clip.clone(gpa);
                errdefer held.deinit(gpa);
                for (keys) |new| {
                    if (held.find(new.target, new.property, new.node) == null) {
                        const added = try held.withTrack(gpa, new.target, new.property, new.node);
                        held.deinit(gpa);
                        held = added;
                    }
                    const track = held.find(new.target, new.property, new.node).?;
                    const keyed = try held.withKey(gpa, track, new.key);
                    held.deinit(gpa);
                    held = keyed;
                }
                return held;
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
        const entity = self.entity orelse return;
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
            // Record compares against the pose just shown.
            self.recorded = if (env.selected) |selected| readRecorded(env, entity, selected) else null;
            return;
        }
        // The game was restarted under the pose (an undo, a reload): begin again once.
        self.posed = false;
        if (self.retried) self.failed = true;
        self.retried = true;
    }

    /// Put the scene back and stop playing.
    fn release(self: *Dock, env: Env) void {
        if (self.posed) env.game.endAnimationPreview(env.app);
        self.posed = false;
        self.wanted = false;
        self.dirty = false;
        self.playing = false;
        self.time_s = 0;
        self.failed = false;
        self.retried = false;
        self.recorded = null;
    }

    fn forgetEntity(self: *Dock) void {
        self.authored_len = 0;
        self.imported_len = 0;
        self.selected_key = null;
        self.source = 0;
        self.target = 0;
        self.duration_for = null;
        self.message_len = 0;
        self.recording = false;
    }

    /// The entity to show: the selection when it has an `Animator`, else the one shown so far
    /// while it still has one, so its cutscene's actors can be selected and posed.
    fn follow(self: *const Dock, env: Env) ?eggy.ecs.EntityId {
        if (env.selected) |selected| if (hasAnimator(env, selected)) return selected;
        if (self.entity) |shown| if (hasAnimator(env, shown)) return shown;
        return env.selected;
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

    // The entity's clips ---------------------------------------------------------------------

    fn authoredKey(self: *const Dock) []const u8 {
        return self.authored_key[0..self.authored_len];
    }

    fn importedKey(self: *const Dock) []const u8 {
        return self.imported_key[0..self.imported_len];
    }

    /// Read the keys of the clips `entity`'s `Animator` plays, from the world as it is.
    fn readClipKeys(self: *Dock, env: Env, entity: eggy.ecs.EntityId) void {
        const keys = clipKeysOf(env.game, env.app, entity);
        self.authored_key = keys.authored;
        self.authored_len = keys.authored_len;
        self.imported_key = keys.imported;
        self.imported_len = keys.imported_len;
    }

    fn say(self: *Dock, text: []const u8) void {
        const shown = text[0..@min(text.len, self.message.len)];
        @memcpy(self.message[0..shown.len], shown);
        self.message_len = shown.len;
    }

    fn sayNull(self: *Dock, text: []const u8) ?Edit {
        self.say(text);
        return null;
    }

    fn sayError(self: *Dock, what: []const u8, err: anyerror) void {
        const text = std.fmt.bufPrint(&self.message, "{s}: {t}", .{ what, err }) catch &self.message;
        self.message_len = text.len;
    }
};

/// The asset keys of the clips an entity's `Animator` names; a length of 0 where unset.
pub const ClipKeys = struct {
    authored: [key_len]u8 = undefined,
    authored_len: usize = 0,
    imported: [key_len]u8 = undefined,
    imported_len: usize = 0,
};

/// Read the clips `entity`'s `Animator` names through the game library, from the world as it is;
/// none without an `Animator`.
pub fn clipKeysOf(game: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId) ClipKeys {
    var keys = ClipKeys{};
    const component = game.builtinComponent("Animator") orelse return keys;
    if (!game.hasComponent(app, entity, component)) return keys;
    const fields = game.component_types[component].fields;
    for (fields, 0..) |field, index| {
        const authored = std.mem.eql(u8, field.name, "clip");
        if (!authored and !std.mem.eql(u8, field.name, "model_clip")) continue;
        var buffer: [64]u8 = undefined;
        const zon = game.readField(app, entity, component, index, &buffer) orelse continue;
        const text = unquote(zon) orelse continue;
        if (text.len != key_len) continue;
        if (authored) {
            keys.authored = text[0..key_len].*;
            keys.authored_len = key_len;
        } else {
            keys.imported = text[0..key_len].*;
            keys.imported_len = key_len;
        }
    }
    return keys;
}

fn hasAnimator(env: Env, entity: eggy.ecs.EntityId) bool {
    const component = env.game.builtinComponent("Animator") orelse return false;
    return env.game.hasComponent(env.app, entity, component);
}

/// What Record compares for `selected`, as a clip played by `root` names it; null when no path
/// reaches it or it has no `Transform`.
fn readRecorded(env: Env, root: eggy.ecs.EntityId, selected: eggy.ecs.EntityId) ?Recorded {
    var recorded = Recorded{};
    const target = env.game.animationTargetFor(env.app, root, selected, &recorded.target) orelse return null;
    recorded.target_len = target.len;
    recorded.numbers = env.game.animationTransform(env.app, root, target) orelse return null;
    recorded.fov_deg = if (env.game.animationValue(env.app, root, target, .fov_deg)) |value| value[0] else null;
    return recorded;
}

fn differs(a: *const [3]f32, b: *const [3]f32) bool {
    for (a, b) |x, y| if (@abs(x - y) > record_epsilon) return true;
    return false;
}

fn transformPart(numbers: [9]f32, property: Property) [3]f32 {
    return switch (property) {
        .position => numbers[0..3].*,
        .rotation_deg => numbers[3..6].*,
        else => numbers[6..9].*,
    };
}

fn oneKey(arena: std.mem.Allocator, key: NewKey) []const NewKey {
    const keys = arena.alloc(NewKey, 1) catch return &.{};
    keys[0] = key;
    return keys;
}

/// A target as a person reads it: `bee` for `/bee`, "This entity" for the animated one.
fn displayTarget(target: []const u8) []const u8 {
    if (target.len == 0) return "This entity";
    if (std.mem.startsWith(u8, target, eggy.assets.clip.scene_prefix)) return target[eggy.assets.clip.scene_prefix.len..];
    return target;
}

fn sameEntity(a: ?eggy.ecs.EntityId, b: ?eggy.ecs.EntityId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

/// The text between a ZON string's quotes; null when `zon` isn't one.
fn unquote(zon: []const u8) ?[]const u8 {
    if (zon.len < 2 or zon[0] != '"' or zon[zon.len - 1] != '"') return null;
    return zon[1 .. zon.len - 1];
}

test "targets read as names, from the top of the scene or below the entity" {
    try std.testing.expectEqualStrings("bee", displayTarget("/bee"));
    try std.testing.expectEqualStrings("Arm/Hand", displayTarget("Arm/Hand"));
    try std.testing.expectEqualStrings("This entity", displayTarget(""));
}

test "an edit keys several properties at once, adding the tracks it needs" {
    const gpa = std.testing.allocator;
    const clip = Clip{ .duration_s = 2, .tracks = &.{} };
    const keys = [_]NewKey{
        .{ .target = "/bee", .property = .position, .key = .{ .time_s = 1, .value = .{ 1, 2, 3 } } },
        .{ .target = "/dialogue", .property = .text, .node = "line", .key = .{ .time_s = 1.5, .text = "Bzz!" } },
        .{ .target = "/bee", .property = .position, .key = .{ .time_s = 3, .value = .{ 4, 5, 6 } } },
    };
    const edited = try Dock.applied(gpa, &clip, .{ .keys = &keys });
    defer edited.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), edited.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), edited.tracks[0].keys.len);
    try std.testing.expectEqualStrings("Bzz!", edited.tracks[1].keys[0].text);
    try std.testing.expectEqual(@as(f32, 3), edited.duration_s);
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
