//! The Animation panel: scrub and play an `Animator`'s clips in the Scene, and edit the
//! authored clip's tracks: a row per track with its keys on a shared timeline, keys added for
//! any entity in the scene (transforms, a camera's field of view, UI text and visibility, sprite
//! frames, sounds and events), and Record, which keys whatever is moved or changed at the head.
//! The panel stays on the last entity with an `Animator` while others are selected, so a
//! cutscene's actors can be posed in turn.
//!
//! Keys are picked by pressing them (Shift adds or takes one away, Ctrl+A picks all) and dragged
//! along their rows together, landing on frames (Ctrl drags freely). Delete removes them, Ctrl+C
//! and Ctrl+V copy them to the head, and an ease shapes the spans leaving them. Ctrl+wheel over
//! the timeline zooms it, Shift+wheel pans.
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
const KeyRef = eggy.assets.clip.KeyRef;
const Ease = eggy.assets.clip.Ease;
const Property = eggy.assets.clip.Property;
const sdl3 = eggy.sdl_adapter.sdl;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const history_zig = @import("../history.zig");
const page_style = @import("../page_style.zig");
const clip_file = @import("clip_file.zig");
const timeline = @import("timeline.zig");
const add_track = @import("add_track.zig");
const file_ops = @import("../assets/file_ops.zig");
const creation = @import("../assets/creation.zig");

const NumberEdit = ui.TextEdit(12);
const NameEdit = ui.TextEdit(64);
const ValueEdit = ui.TextEdit(eggy.assets.clip.max_text_len);
const key_len = eggy.assets.id.key_len;
const max_target_len = 256;
/// What the Key… form offers, beside the transform buttons.
const form_properties = [_]Property{ .camera, .fov_deg, .visible, .text, .sound, .event, .sprite_frame };
const form_labels = [_][]const u8{ "camera cut (This entity: back to the game's)", "fov_deg (Camera)", "visible (UI)", "text (UI node)", "sound (AudioSource)", "event", "sprite_frame (SpriteAnimator)" };
/// Record keys a change bigger than this.
const record_epsilon: f32 = 1e-4;
/// The most keys picked at once.
// ponytail: a fixed list; make it grow if cutscenes ever need more picked together.
const max_picked = 512;
const ease_labels = [_][]const u8{ "Linear", "Ease in", "Ease out", "Ease in-out" };
/// How much each wheel step zooms the timeline, and how far it pans, as a share of the view.
const zoom_per_step: f32 = 1.25;
const pan_per_step: f32 = 0.1;

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

/// A key to place: on the track for `target`, `property` and `node`, made if missing.
const NewKey = struct { target: []const u8, property: Property, node: []const u8 = "", key: Key };

/// A shortcut pressed over the panel, carried out when it is next built.
const Shortcut = enum { delete, copy, paste, pick_all };

/// Picked keys being dragged along their rows.
const Drag = struct {
    /// Where the pointer pressed, as a time, on the key at `key_s`.
    anchor_s: f32,
    key_s: f32,
    /// The row pressed on, whose lane maps the pointer to times.
    row: ui.Rect,
    shift_s: f32 = 0,
};

/// Keys copied with Ctrl+C, at times from the earliest of them; their memory is `arena`'s.
const Copied = struct {
    arena: std.heap.ArenaAllocator,
    keys: []const NewKey,
};

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
    /// The keys picked, and a track picked by its gutter.
    picked: [max_picked]KeyRef = undefined,
    picked_count: usize = 0,
    picked_track: ?usize = null,
    drag: ?Drag = null,
    /// The stretch of the clip the timeline shows.
    view: timeline.View = .{ .duration_s = 0 },
    /// Where the ruler and rows were last drawn, for the wheel.
    lanes: ?ui.Rect = null,
    shortcut: ?Shortcut = null,
    copied: ?Copied = null,
    ease_choice: usize = 0,
    duration_edit: NumberEdit = NumberEdit.init("1") catch unreachable,
    duration_for: ?[key_len]u8 = null,
    add_track: add_track.AddTrack = .{},
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
    /// What Record keyed last, shown while it records.
    keyed: [160]u8 = undefined,
    keyed_len: usize = 0,

    /// Free the copied keys.
    pub fn deinit(self: *Dock) void {
        if (self.copied) |*copied| copied.arena.deinit();
        self.copied = null;
    }

    /// A key pressed while the panel has focus: Delete, Ctrl+C, Ctrl+V, Ctrl+A and Escape act on
    /// the timeline's keys. Returns whether it was used; a text field typing takes none.
    pub fn keyDown(self: *Dock, key_down: @FieldType(ui.input.Event, "key_down"), typing: bool) bool {
        if (typing or self.entity == null) return false;
        const control = key_down.modifiers.control;
        const wanted: ?Shortcut = switch (key_down.key) {
            .delete, .backspace => if (self.picked_count > 0) .delete else null,
            .c => if (control and self.picked_count > 0) .copy else null,
            .v => if (control and self.copied != null) .paste else null,
            .a => if (control) .pick_all else null,
            .escape => {
                const any = self.picked_count > 0 or self.picked_track != null or self.drag != null;
                self.clearPicked();
                return any;
            },
            else => null,
        };
        self.shortcut = wanted orelse return false;
        return true;
    }

    /// A wheel over the timeline: with Ctrl it zooms about the pointer, with Shift (or sideways)
    /// it pans. Returns whether it was used; a plain wheel scrolls the panel.
    pub fn wheel(self: *Dock, event: @FieldType(ui.input.Event, "wheel")) bool {
        const lanes = self.lanes orelse return false;
        if (!lanes.contains(event.position.x, event.position.y)) return false;
        const held = sdl3.keyboard.getModState();
        const layout = timeline.Layout{ .width = lanes.w, .view = self.view };
        if (held.controlDown()) {
            self.view = self.view.zoomed(std.math.pow(f32, zoom_per_step, event.delta.y), layout.timeAtAny(event.position.x - lanes.x));
            return true;
        }
        const sideways = if (event.delta.x != 0) event.delta.x else if (held.shiftDown()) -event.delta.y else return false;
        self.view = self.view.panned(sideways * self.view.shown_s() * pan_per_step);
        return true;
    }

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
        self.clearPicked();
        self.dirty = true;
        self.recorded = null;
    }

    /// Declare the panel's contents.
    pub fn build(self: *Dock, context: *ui.Context, env: Env) void {
        const arena = context.builder().allocator;
        const entity = self.entity orelse return context.muted("Select an entity with an Animator to animate it.");
        if (!self.posed) self.readClipKeys(env, entity);
        if (self.authored_len == 0 and self.imported_len == 0) return self.buildEmpty(context, env, entity);

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
        if (clip) |found| self.keepPicked(found.*) else self.clearPicked();
        self.view = self.view.resized(duration);
        if (self.playing) self.view = self.view.following(self.time_s);

        // The transport: to the start, the key before, play, the key after, the end; loop and
        // Record; the frame the head is on; the clip; reset, fit and the length.
        var pending: ?Edit = null;
        context.begin(.row);
        if (page_style.iconButton(context, "\u{f049}", "Go to start", false)) self.jumpTo(0);
        if (page_style.iconButton(context, "\u{f053}", "Previous key", false)) if (clip) |found| if (stepAll(found.*, self.time_s, .previous)) |time| self.jumpTo(time);
        if (page_style.iconButton(context, if (self.playing) "\u{f04c}" else "\u{f04b}", if (self.playing) "Pause" else "Play", self.playing)) self.togglePlay(env, duration);
        if (page_style.iconButton(context, "\u{f054}", "Next key", false)) if (clip) |found| if (stepAll(found.*, self.time_s, .next)) |time| self.jumpTo(time);
        if (page_style.iconButton(context, "\u{f050}", "Go to end", false)) self.jumpTo(duration);
        if (page_style.iconButton(context, "\u{f01e}", "Loop", self.loop)) self.loop = !self.loop;
        if (editable) {
            if (context.buttonVariant(if (self.recording) "Recording" else "Record", if (self.recording) .destructive else .outline)) {
                self.recording = !self.recording;
                self.recorded = null;
                self.keyed_len = 0;
                if (self.recording) {
                    self.playing = false;
                    self.request();
                }
            }
        }
        if (self.recording and self.keyed_len > 0) context.muted(self.keyed[0..self.keyed_len]);
        context.text(std.fmt.allocPrint(arena, "{d:0>4}", .{timeline.frameOf(self.time_s)}) catch "");
        context.muted(std.fmt.allocPrint(arena, "{d:.2} s of {d:.2}", .{ self.time_s, duration }) catch "");
        if (names.items.len > 1) {
            if (context.select("##animation clip", names.items, &chosen)) self.markChanged();
        } else context.muted(std.fs.path.basename(path));
        page_style.spacer(context);
        if (context.buttonVariant("Reset pose", .outline)) self.release(env);
        if (self.view.span_s > 0 and context.buttonVariant("Fit", .outline)) self.view = .{ .duration_s = duration };
        if (clip) |found| pending = self.durationField(context, found, key) orelse pending;
        page_style.endRow(context);

        // The timeline: a ruler to scrub on, the camera cuts, then the tracks under what they
        // act on.
        self.lanes = null;
        self.ruler(context);
        if (clip) |found| {
            if (self.shotsRow(context, env, entity, found)) |change| pending = change;
            if (found.tracks.len == 0) context.muted("No tracks yet. Key something below.");
            if (self.groupedRows(context, env, entity, found)) |change| pending = change;
            if (self.dragged(context, found.*)) |change| pending = change;
            if (self.takeShortcut(env, found.*)) |change| pending = change;
        } else if (!editable) {
            context.muted("Imported clips play as they are; key an authored clip (.clip.zon).");
        } else {
            context.muted("This clip can't be read.");
        }

        const editing = clip orelse return;
        if (self.buildKeying(context, env, entity, editing)) |change| pending = change;
        if (self.pickedRow(context, env, entity, editing)) |change| pending = change;
        if (self.message_len > 0) context.alert("Animation", self.message[0..self.message_len], true);
        if (pending) |change| self.edit(env, editing, key, path, change);
    }

    // The timeline ------------------------------------------------------------------------------

    fn ruler(self: *Dock, context: *ui.Context) void {
        const arena = context.builder().allocator;
        const id = context.idFor("##animation ruler");
        const element = context.builder().node(id, .{ .width = context.contentWidth(), .height = timeline.heights.ruler }, timeline.rulerPaint(arena, .{ .view = self.view, .head_s = self.time_s, .recording = self.recording }), &.{}) catch return;
        element.accessibility = .{ .role = .slider, .label = "Animation time", .numeric_value = self.time_s };
        context.element(element);
        const bounds = (context.last_bounds.get(id) orelse return).rect;
        self.coverLanes(bounds);
        // Pressing on the ruler, or dragging from it, moves the head.
        const dragging = context.pointer_held and if (context.press) |press| press.widget == id else false;
        if (!context.activated(id) and !dragging) return;
        const layout = timeline.Layout{ .width = bounds.w, .view = self.view };
        const time = layout.timeAt(context.pointer.x - bounds.x) orelse return;
        self.time_s = time;
        self.playing = false;
        self.request();
    }

    /// The tracks of `clip`, but its camera cuts, each under a row for what it acts on.
    fn groupedRows(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, clip: *const Clip) ?Edit {
        const arena = context.builder().allocator;
        var owners: std.ArrayList([]const u8) = .empty;
        for (clip.tracks) |track| {
            if (track.property == .camera) continue;
            const owner = trackOwner(track);
            for (owners.items) |known| {
                if (std.mem.eql(u8, known, owner)) break;
            } else owners.append(arena, owner) catch return null;
        }
        var pending: ?Edit = null;
        for (owners.items, 0..) |owner, group| {
            var times: std.ArrayList(f32) = .empty;
            var kind: []const u8 = "";
            for (clip.tracks) |track| {
                if (track.property == .camera or !std.mem.eql(u8, trackOwner(track), owner)) continue;
                for (track.keys) |key| times.append(arena, key.time_s) catch {};
                kind = switch (track.property) {
                    .fov_deg => "Camera",
                    .text, .visible => if (kind.len == 0) "UI" else kind,
                    .sprite_frame => if (kind.len == 0) "Sprite" else kind,
                    else => kind,
                };
            }
            self.groupRow(context, group, owner, kind, times.items);
            for (clip.tracks, 0..) |track, index| {
                if (track.property == .camera or !std.mem.eql(u8, trackOwner(track), owner)) continue;
                if (self.trackRow(context, env, entity, track, index)) |change| pending = change;
            }
        }
        return pending;
    }

    fn groupRow(self: *Dock, context: *ui.Context, group: usize, name: []const u8, kind: []const u8, times: []const f32) void {
        const arena = context.builder().allocator;
        const id = context.idFor(std.fmt.allocPrint(arena, "##animation group {d}", .{group}) catch return);
        const paint = timeline.groupPaint(arena, .{ .name = name, .kind = kind, .times_s = times, .view = self.view, .head_s = self.time_s, .recording = self.recording });
        const element = context.builder().node(id, .{ .width = context.contentWidth(), .height = timeline.heights.group }, paint, &.{}) catch return;
        element.accessibility = .{ .role = .group, .label = name };
        context.element(element);
        const bounds = (context.last_bounds.get(id) orelse return).rect;
        self.coverLanes(bounds);
        // Pressing along it moves the head.
        if (!context.activated(id)) return;
        const layout = timeline.Layout{ .width = bounds.w, .view = self.view };
        const time = layout.timeAt(context.pointer.x - bounds.x) orelse return;
        self.jumpTo(time);
    }

    fn trackRow(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, track: eggy.assets.clip.Track, index: usize) ?Edit {
        const arena = context.builder().allocator;
        const picked = arena.alloc(bool, track.keys.len) catch return null;
        for (picked, 0..) |*on, key| on.* = self.isPicked(.{ .track = index, .key = key });
        const row = timeline.rowOf(arena, track, trackOwner(track), .{
            .view = self.view,
            .head_s = self.time_s,
            .picked = picked,
            .track_picked = self.picked_track == index,
            .drag_s = if (self.drag) |drag| drag.shift_s else 0,
            .recording = self.recording,
            .nested = true,
        }) catch return null;
        const id = context.idFor(std.fmt.allocPrint(arena, "##animation track {d}", .{index}) catch return null);
        const element = context.builder().node(id, .{ .width = context.contentWidth(), .height = timeline.heights.row }, timeline.rowPaint(arena, row), &.{}) catch return null;
        element.accessibility = .{ .role = .button, .label = std.fmt.allocPrint(arena, "{s} {s}", .{ row.target, row.property }) catch "" };
        context.element(element);
        const bounds = (context.last_bounds.get(id) orelse return null).rect;
        self.coverLanes(bounds);
        const pressed = context.pressed_down and if (context.press) |press| press.widget == id else false;
        if (!pressed) return null;

        // The gutter's buttons step the head between this track's keys, or key it at the head.
        const x = context.pointer.x - bounds.x;
        if (timeline.navAt(x)) |nav| switch (nav) {
            .previous, .next => {
                if (timeline.stepKey(track.keys, self.time_s, if (nav == .previous) .previous else .next)) |time| self.jumpTo(time);
                return null;
            },
            .key => return self.keyHere(arena, env, entity, track),
        };

        // A key pressed is picked (Shift adds it or takes it away) and the picked keys follow the
        // pointer from there; elsewhere in the lane the head moves; the gutter picks the track.
        const layout = timeline.Layout{ .width = bounds.w, .view = self.view };
        const adding = sdl3.keyboard.getModState().shiftDown();
        if (layout.keyNear(track.keys, x)) |key| {
            const ref = KeyRef{ .track = index, .key = key };
            self.picked_track = null;
            if (adding and self.isPicked(ref)) {
                self.unpick(ref);
            } else {
                if (!adding and !self.isPicked(ref)) self.clearPicked();
                self.pick(ref);
                self.drag = .{ .anchor_s = layout.timeAtAny(x), .key_s = track.keys[key].time_s, .row = bounds };
            }
            self.time_s = track.keys[key].time_s;
        } else if (layout.timeAt(x)) |time| {
            if (!adding) self.clearPicked();
            self.time_s = time;
        } else {
            self.clearPicked();
            self.picked_track = index;
        }
        self.playing = false;
        self.request();
        return null;
    }

    /// A key on `track` at the head holding what it shows now: the target's transform or value,
    /// or for a text, sound, event or camera track the key in force there.
    fn keyHere(self: *Dock, arena: std.mem.Allocator, env: Env, entity: eggy.ecs.EntityId, track: eggy.assets.clip.Track) ?Edit {
        var key = Key{ .time_s = self.time_s };
        switch (track.property) {
            .position, .rotation_deg, .scale => {
                const numbers = env.game.animationTransform(env.app, entity, track.target) orelse return self.sayNull("That entity has no Transform.");
                key.value = transformPart(numbers, track.property);
            },
            .fov_deg, .visible, .sprite_frame => {
                key.value = env.game.animationValue(env.app, entity, track.target, track.property) orelse return self.sayNull("Can't read that value from its entity.");
            },
            .morph_weight, .text, .sound, .event, .camera => {
                const held = track.keyAt(self.time_s) orelse return self.sayNull("No key before the head to hold.");
                key.value = held.value;
                key.text = held.text;
                key.ease = held.ease;
            },
        }
        return .{ .keys = oneKey(arena, .{ .target = track.target, .property = track.property, .node = track.node, .key = key }) };
    }

    // Camera cuts ------------------------------------------------------------------------------

    /// The camera cuts lane: a block per shot to pick and drag, and "Add shot" in its gutter.
    fn shotsRow(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, clip: *const Clip) ?Edit {
        const arena = context.builder().allocator;
        const track_index = clip.find("", .camera, "");
        const keys: []const Key = if (track_index) |index| clip.tracks[index].keys else &.{};
        const starts = arena.alloc(f32, keys.len) catch return null;
        const shots = arena.alloc(timeline.Shot, keys.len) catch return null;
        var named: std.ArrayList([]const u8) = .empty;
        for (keys, shots, starts, 0..) |key, *shot, *start, index| {
            const picked = if (track_index) |track| self.isPicked(.{ .track = track, .key = index }) else false;
            const shift_s = if (picked) if (self.drag) |drag| drag.shift_s else 0 else 0;
            start.* = key.time_s;
            const end_s = if (index + 1 < keys.len) keys[index + 1].time_s else clip.duration_s;
            shot.* = .{
                .start_s = @max(0, key.time_s + shift_s),
                .end_s = end_s + shift_s,
                .blend_s = key.value[0],
                .ease = key.ease,
                .name = shotName(key.text),
                .detail = if (key.value[0] > 0) std.fmt.allocPrint(arena, "{d} frame {s} blend", .{ timeline.frameOf(key.value[0]), easeName(key.ease) }) catch "" else "Cut",
                .color = shotColorOf(arena, &named, key.text),
                .from_color = if (index == 0) timeline.game_color else shotColorOf(arena, &named, keys[index - 1].text),
                .picked = picked,
            };
        }
        const id = context.idFor("##animation shots");
        const paint = timeline.shotsPaint(arena, .{ .shots = shots, .view = self.view, .head_s = self.time_s, .recording = self.recording });
        const element = context.builder().node(id, .{ .width = context.contentWidth(), .height = timeline.heights.shots }, paint, &.{}) catch return null;
        element.accessibility = .{ .role = .group, .label = "Camera cuts" };
        context.element(element);
        const bounds = (context.last_bounds.get(id) orelse return null).rect;
        self.coverLanes(bounds);
        const pressed = context.pressed_down and if (context.press) |press| press.widget == id else false;
        if (!pressed) return null;

        // "Add shot" cuts at the head to the next camera; a shot pressed is picked and can be
        // dragged; elsewhere the head moves.
        const x = context.pointer.x - bounds.x;
        if (timeline.addShotAt(x)) return self.addShot(arena, env, entity, keys);
        const layout = timeline.Layout{ .width = bounds.w, .view = self.view };
        const time = layout.timeAt(x) orelse return null;
        if (timeline.shotNear(layout, starts, clip.duration_s, x)) |index| if (track_index) |track| {
            const ref = KeyRef{ .track = track, .key = index };
            const adding = sdl3.keyboard.getModState().shiftDown();
            self.picked_track = null;
            if (adding and self.isPicked(ref)) {
                self.unpick(ref);
            } else {
                if (!adding and !self.isPicked(ref)) self.clearPicked();
                self.pick(ref);
                self.drag = .{ .anchor_s = layout.timeAtAny(x), .key_s = keys[index].time_s, .row = bounds };
            }
            self.jumpTo(time);
            return null;
        };
        self.clearPicked();
        self.jumpTo(time);
        return null;
    }

    /// A cut at the head to the camera after the one showing there (the first camera in the
    /// scene when none is).
    fn addShot(self: *Dock, arena: std.mem.Allocator, env: Env, entity: eggy.ecs.EntityId, keys: []const Key) ?Edit {
        const cameras = cameraTargets(arena, env, entity);
        if (cameras.len == 0) return self.sayNull("Put a Camera on an entity in the scene to cut to it.");
        var showing: []const u8 = "";
        for (keys) |key| {
            if (key.time_s > self.time_s) break;
            showing = key.text;
        }
        var next: usize = 0;
        for (cameras, 0..) |camera, index| if (std.mem.eql(u8, camera, showing)) {
            next = (index + 1) % cameras.len;
        };
        return .{ .keys = oneKey(arena, .{ .target = "", .property = .camera, .key = .{ .time_s = self.time_s, .text = cameras[next] } }) };
    }

    /// The picked shot's camera, how it comes in (a cut, or a blend of some frames and ease),
    /// and removing it.
    fn shotSettings(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, clip: *const Clip, ref: KeyRef) ?Edit {
        const arena = context.builder().allocator;
        const track = clip.tracks[ref.track];
        const key = track.keys[ref.key];
        const end_s = if (ref.key + 1 < track.keys.len) track.keys[ref.key + 1].time_s else clip.duration_s;
        var pending: ?Edit = null;
        context.begin(.row);
        context.text(shotName(key.text));
        context.muted(std.fmt.allocPrint(arena, "frames {d} to {d}", .{ timeline.frameOf(key.time_s), timeline.frameOf(end_s) }) catch "");

        // The camera: the game's own, or any in the scene.
        const cameras = cameraTargets(arena, env, entity);
        const labels = arena.alloc([]const u8, cameras.len + 1) catch return null;
        labels[0] = "Game camera";
        var chosen: usize = 0;
        for (cameras, labels[1..], 1..) |camera, *label, index| {
            label.* = displayTarget(camera);
            if (std.mem.eql(u8, camera, key.text)) chosen = index;
        }
        if (context.select("##shot camera", labels, &chosen)) {
            var changed = key;
            changed.text = if (chosen == 0) "" else cameras[chosen - 1];
            pending = .{ .keys = oneKey(arena, .{ .target = "", .property = .camera, .key = changed }) };
        }

        // Cut, or blend over a number of frames with an ease.
        const blending = key.value[0] > 0;
        if (context.buttonVariant("Cut", if (blending) .outline else .secondary) and blending) {
            var changed = key;
            changed.value[0] = 0;
            pending = .{ .keys = oneKey(arena, .{ .target = "", .property = .camera, .key = changed }) };
        }
        if (context.buttonVariant("Blend", if (blending) .secondary else .outline) and !blending) {
            var changed = key;
            changed.value[0] = 15 / timeline.snap_fps;
            changed.ease = .ease_in_out;
            pending = .{ .keys = oneKey(arena, .{ .target = "", .property = .camera, .key = changed }) };
        }
        if (blending) {
            var frames: usize = 0;
            const now = timeline.frameOf(key.value[0]);
            for (blend_frames, 0..) |option, index| if (option <= now) {
                frames = index;
            };
            if (context.select("##shot blend", &blend_labels, &frames)) {
                var changed = key;
                changed.value[0] = @as(f32, @floatFromInt(blend_frames[frames])) / timeline.snap_fps;
                pending = .{ .keys = oneKey(arena, .{ .target = "", .property = .camera, .key = changed }) };
            }
            self.ease_choice = @backingInt(key.ease);
            if (context.select("##shot ease", &ease_labels, &self.ease_choice)) {
                pending = .{ .change_keys = .{ .keys = self.picked[0..self.picked_count], .change = .{ .ease = @fromBackingInt(@intCast(self.ease_choice)) } } };
            }
        }
        page_style.spacer(context);
        if (context.buttonVariant("Remove shot", .destructive)) pending = .{ .change_keys = .{ .keys = self.picked[0..self.picked_count], .change = .remove } };
        page_style.endRow(context);
        return pending;
    }

    /// Follow a drag of the picked keys; once let go, the edit moving them.
    fn dragged(self: *Dock, context: *ui.Context, clip: Clip) ?Edit {
        const drag = if (self.drag) |*held| held else return null;
        const layout = timeline.Layout{ .width = drag.row.w, .view = self.view };
        if (context.pointer_held) {
            const pointer_s = layout.timeAtAny(context.pointer.x - drag.row.x);
            const free = sdl3.keyboard.getModState().controlDown();
            drag.shift_s = timeline.dragShift(layout, drag.anchor_s, drag.key_s, pointer_s, self.time_s, self.earliestPicked(clip), free);
            return null;
        }
        const shift_s = drag.shift_s;
        self.drag = null;
        if (shift_s == 0) return null;
        self.time_s = @max(0, self.time_s + shift_s);
        return .{ .change_keys = .{ .keys = self.picked[0..self.picked_count], .change = .{ .shift_s = shift_s } } };
    }

    /// Carry out the shortcut pressed since the last build.
    fn takeShortcut(self: *Dock, env: Env, clip: Clip) ?Edit {
        const shortcut = self.shortcut orelse return null;
        self.shortcut = null;
        switch (shortcut) {
            .delete => if (self.picked_count > 0) return .{ .change_keys = .{ .keys = self.picked[0..self.picked_count], .change = .remove } },
            .copy => self.copy(env.history.gpa, clip),
            .paste => if (self.copied) |copied| return .{ .paste = .{ .keys = copied.keys, .at_s = self.time_s } },
            .pick_all => {
                self.clearPicked();
                for (clip.tracks, 0..) |track, index| for (0..track.keys.len) |key| self.pick(.{ .track = index, .key = key });
            },
        }
        return null;
    }

    /// Keep the picked keys, at times from the earliest of them, for Ctrl+V.
    fn copy(self: *Dock, gpa: std.mem.Allocator, clip: Clip) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const keys = arena.allocator().alloc(NewKey, self.picked_count) catch return arena.deinit();
        const earliest = self.earliestPicked(clip);
        for (keys, self.picked[0..self.picked_count]) |*copied, ref| {
            const track = clip.tracks[ref.track];
            var key = track.keys[ref.key];
            key.time_s -= earliest;
            key.text = arena.allocator().dupe(u8, key.text) catch return arena.deinit();
            copied.* = .{
                .target = arena.allocator().dupe(u8, track.target) catch return arena.deinit(),
                .property = track.property,
                .node = arena.allocator().dupe(u8, track.node) catch return arena.deinit(),
                .key = key,
            };
        }
        self.deinit();
        self.copied = .{ .arena = arena, .keys = keys };
    }

    /// Grow the area the wheel zooms and pans over to take in `bounds`.
    fn coverLanes(self: *Dock, bounds: ui.Rect) void {
        const lanes = self.lanes orelse {
            self.lanes = bounds;
            return;
        };
        const bottom = @max(lanes.y + lanes.h, bounds.y + bounds.h);
        self.lanes = .{ .x = lanes.x, .y = @min(lanes.y, bounds.y), .w = lanes.w, .h = bottom - @min(lanes.y, bounds.y) };
    }

    // Picking -----------------------------------------------------------------------------------

    fn isPicked(self: *const Dock, ref: KeyRef) bool {
        for (self.picked[0..self.picked_count]) |other| if (std.meta.eql(other, ref)) return true;
        return false;
    }

    fn pick(self: *Dock, ref: KeyRef) void {
        if (self.isPicked(ref) or self.picked_count == max_picked) return;
        self.picked[self.picked_count] = ref;
        self.picked_count += 1;
    }

    fn unpick(self: *Dock, ref: KeyRef) void {
        for (self.picked[0..self.picked_count], 0..) |other, index| if (std.meta.eql(other, ref)) {
            self.picked[index] = self.picked[self.picked_count - 1];
            self.picked_count -= 1;
            return;
        };
    }

    fn clearPicked(self: *Dock) void {
        self.picked_count = 0;
        self.picked_track = null;
        self.drag = null;
    }

    /// Let go of picks `clip` no longer has (an undo, another clip).
    fn keepPicked(self: *Dock, clip: Clip) void {
        if (self.picked_track) |track| if (track >= clip.tracks.len) {
            self.picked_track = null;
        };
        var index: usize = 0;
        while (index < self.picked_count) {
            const ref = self.picked[index];
            if (ref.track < clip.tracks.len and ref.key < clip.tracks[ref.track].keys.len) {
                index += 1;
                continue;
            }
            self.unpick(ref);
        }
        if (self.picked_count == 0) self.drag = null;
    }

    fn earliestPicked(self: *const Dock, clip: Clip) f32 {
        var earliest: f32 = std.math.inf(f32);
        for (self.picked[0..self.picked_count]) |ref| earliest = @min(earliest, clip.tracks[ref.track].keys[ref.key].time_s);
        return if (std.math.isFinite(earliest)) earliest else 0;
    }

    /// Pick the keys of `clip` at `landed`, where an edit put them.
    fn pickLanded(self: *Dock, clip: Clip, landed: []const Landed) void {
        self.clearPicked();
        for (landed) |place| {
            const track = clip.find(place.target, place.property, place.node) orelse continue;
            for (clip.tracks[track].keys, 0..) |key, index| {
                if (@abs(key.time_s - place.time_s) > eggy.assets.clip.same_time_s) continue;
                self.pick(.{ .track = track, .key = index });
                break;
            }
        }
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

    /// Add track, keying what is picked from it at the head, and the Key… form for a key that
    /// needs a value typed (a text, a sound, an event) or another target.
    fn buildKeying(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, clip: *const Clip) ?Edit {
        const arena = context.builder().allocator;
        var pending: ?Edit = null;

        // Targets: the entity, its children, then everything else in the scene.
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

        context.begin(.row);
        // What each target offers is read only while the menu is open.
        const offered = if (self.add_track.open) offersFor(arena, env, entity, clip, targets.items, labels.items) else &.{};
        if (self.add_track.build(context, offered)) |chosen| {
            pending = self.keyPicked(arena, env, entity, targets.items[chosen.target], chosen.target, chosen.property);
        }
        if (context.buttonVariant("Key…", if (self.form_open) .secondary else .outline)) self.form_open = !self.form_open;
        page_style.endRow(context);

        if (self.form_open) {
            context.begin(.row);
            _ = context.select("##animation target", labels.items, &self.target);
            page_style.endRow(context);
            if (self.keyForm(context, env, entity, targets.items[self.target])) |change| pending = change;
        }
        return pending;
    }

    /// The key for `property` of `target` picked from Add track: at the head, holding what the
    /// target has now; a text, sound or event opens the Key… form for its value instead.
    fn keyPicked(self: *Dock, arena: std.mem.Allocator, env: Env, entity: eggy.ecs.EntityId, target: []const u8, target_index: usize, property: Property) ?Edit {
        var key = Key{ .time_s = self.time_s };
        switch (property) {
            .position, .rotation_deg, .scale => {
                const numbers = env.game.animationTransform(env.app, entity, target) orelse return self.sayNull("That entity has no Transform.");
                key.value = transformPart(numbers, property);
            },
            .fov_deg, .visible, .sprite_frame => {
                key.value = env.game.animationValue(env.app, entity, target, property) orelse return self.sayNull("Can't read that value from its entity.");
            },
            .camera => {
                key.text = target;
                return .{ .keys = oneKey(arena, .{ .target = "", .property = .camera, .key = key }) };
            },
            .text, .sound, .event, .morph_weight => {
                self.target = target_index;
                self.form_open = true;
                for (form_properties, 0..) |offered, index| if (offered == property) {
                    self.form_property = index;
                };
                return null;
            },
        }
        return .{ .keys = oneKey(arena, .{ .target = target, .property = property, .key = key }) };
    }

    /// Key any other property of `target` at the head: a camera's field of view, a UI node's text
    /// or visibility, a sound, an event, a sprite frame.
    fn keyForm(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, target: []const u8) ?Edit {
        const arena = context.builder().allocator;
        context.begin(.row);
        const before = self.form_property;
        _ = context.select("##key property", &form_labels, &self.form_property);
        const property = form_properties[self.form_property];
        // A number property starts from what the target has now; a cut from no blend.
        if (before != self.form_property and property == .camera) self.form_value.set("0") catch {};
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
            .camera => _ = context.textInput("##key value", &self.form_value, "Blend seconds (0 cuts)"),
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
            .camera => {
                const blend_s = std.fmt.parseFloat(f32, if (value_text.len == 0) "0" else value_text) catch return self.sayNull("The blend must be a number of seconds.");
                if (!(blend_s >= 0)) return self.sayNull("The blend can't be negative.");
                key.value[0] = blend_s;
                key.ease = .ease_in_out;
                key.text = target;
            },
            else => key.value[0] = std.fmt.parseFloat(f32, value_text) catch return self.sayNull("The value must be a number."),
        }
        if (property == .text and node.len == 0) return self.sayNull("Name the UI node whose text this sets.");
        // A clip has one camera track, on no target; its keys name the shots.
        const track_target = if (property == .camera) "" else target;
        return .{ .keys = oneKey(arena, .{ .target = track_target, .property = property, .node = arena.dupe(u8, node) catch return null, .key = key }) };
    }

    /// The picked keys or track: what they are, their ease, and moving or deleting them.
    fn pickedRow(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId, clip: *const Clip) ?Edit {
        const picked = self.picked[0..self.picked_count];
        if (picked.len == 0 and self.picked_track == null) return null;
        if (picked.len == 1 and clip.tracks[picked[0].track].property == .camera) return self.shotSettings(context, env, entity, clip, picked[0]);
        const arena = context.builder().allocator;
        var pending: ?Edit = null;
        var buffer: [96]u8 = undefined;
        context.begin(.row);
        if (self.picked_track) |index| {
            const track = clip.tracks[index];
            context.muted(std.fmt.allocPrint(arena, "{s}  {s}", .{ trackOwner(track), track.label(&buffer) }) catch "");
            if (context.buttonVariant("Remove track", .destructive)) pending = .{ .remove_track = index };
            page_style.endRow(context);
            return pending;
        }
        if (picked.len == 1) {
            const track = clip.tracks[picked[0].track];
            const key = track.keys[picked[0].key];
            const label = timeline.keyLabel(arena, track.property, key) catch "";
            context.muted(std.fmt.allocPrint(arena, "{s}  {s} at {d:.2} s{s}{s}", .{ trackOwner(track), track.label(&buffer), key.time_s, if (label.len > 0) " · " else "", label }) catch "");
            if (context.buttonVariant("Move key to head", .outline)) pending = .{ .change_keys = .{ .keys = picked, .change = .{ .shift_s = self.time_s - key.time_s } } };
        } else context.muted(std.fmt.allocPrint(arena, "{d} keys", .{picked.len}) catch "");

        // An ease for the keys that start a blend; the list shows the first one's.
        const blending = for (picked) |ref| {
            if (!clip.tracks[ref.track].property.discrete()) break ref;
        } else null;
        if (blending) |ref| {
            self.ease_choice = @backingInt(clip.tracks[ref.track].keys[ref.key].ease);
            if (context.select("##key ease", &ease_labels, &self.ease_choice)) {
                pending = .{ .change_keys = .{ .keys = picked, .change = .{ .ease = @fromBackingInt(@intCast(self.ease_choice)) } } };
            }
        }
        if (context.buttonVariant(if (picked.len == 1) "Delete key" else "Delete keys", .destructive)) pending = .{ .change_keys = .{ .keys = picked, .change = .remove } };
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
        const shown = std.fmt.bufPrint(&self.keyed, "Keyed {s} {s} at {d}", .{ displayTarget(target), propertyName(keys[0].property), timeline.frameOf(self.time_s) }) catch "";
        self.keyed_len = shown.len;
    }

    /// An edit to the authored clip.
    const Edit = union(enum) {
        duration: f32,
        keys: []const NewKey,
        /// Copied keys, placed from `at_s` on.
        paste: struct { keys: []const NewKey, at_s: f32 },
        change_keys: struct { keys: []const KeyRef, change: eggy.assets.clip.KeyChange },
        remove_track: usize,
    };

    /// Apply `change` to `clip`, write the file and record the step; a refusal shows in the panel.
    fn edit(self: *Dock, env: Env, clip: *const Clip, key: []const u8, path: []const u8, change: Edit) void {
        self.message_len = 0;
        const gpa = env.history.gpa;
        // Where the keys an edit moves or adds land, to stay picked there.
        var landed: std.ArrayList(Landed) = .empty;
        defer landed.deinit(gpa);
        switch (change) {
            .change_keys => |keys| switch (keys.change) {
                .shift_s => |shift_s| for (keys.keys) |ref| {
                    const track = clip.tracks[ref.track];
                    landed.append(gpa, .{ .target = track.target, .property = track.property, .node = track.node, .time_s = @max(0, track.keys[ref.key].time_s + shift_s) }) catch {};
                },
                .ease => for (keys.keys) |ref| {
                    const track = clip.tracks[ref.track];
                    landed.append(gpa, .{ .target = track.target, .property = track.property, .node = track.node, .time_s = track.keys[ref.key].time_s }) catch {};
                },
                .remove => {},
            },
            .paste => |paste| for (paste.keys) |new| {
                landed.append(gpa, .{ .target = new.target, .property = new.property, .node = new.node, .time_s = new.key.time_s + paste.at_s }) catch {};
            },
            else => {},
        }
        const edited = applied(gpa, clip, change) catch |err| return self.sayError("Can't edit the clip", err);
        defer edited.deinit(gpa);
        commit(env, edited, key, path) catch |err| return self.sayError("Can't save the clip", err);
        self.pickLanded(edited, landed.items);
        self.dirty = true;
        self.duration_for = null;
        self.wanted = true;
    }

    fn applied(gpa: std.mem.Allocator, clip: *const Clip, change: Edit) !Clip {
        switch (change) {
            .duration => |seconds| return clip.withDuration(gpa, seconds),
            .change_keys => |keys| return clip.withKeysChanged(gpa, keys.keys, keys.change),
            .remove_track => |index| return clip.withoutTrack(gpa, index),
            .keys, .paste => {
                const keys, const at_s = switch (change) {
                    .paste => |paste| .{ paste.keys, paste.at_s },
                    else => .{ change.keys, 0 },
                };
                var held = try clip.clone(gpa);
                errdefer held.deinit(gpa);
                for (keys) |copied| {
                    var new = copied;
                    new.key.time_s += at_s;
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
        self.clearPicked();
        self.view = .{ .duration_s = 0 };
        self.source = 0;
        self.target = 0;
        self.duration_for = null;
        self.message_len = 0;
        self.recording = false;
    }

    /// The entity to show: the selection when it has an `Animator`, else the one shown so far
    /// while it still has one, so its cutscene's actors can be selected and posed.
    /// An entity that plays no clip: make it a cutscene or a clip, or give it an Animator.
    fn buildEmpty(self: *Dock, context: *ui.Context, env: Env, entity: eggy.ecs.EntityId) void {
        const arena = context.builder().allocator;
        var name_buffer: [eggy.Name.max_len]u8 = undefined;
        const name = env.game.readName(env.app, entity, &name_buffer) orelse "This entity";
        const animator = hasAnimator(env, entity);
        context.begin(.column);
        context.muted(std.fmt.allocPrint(arena, "{s} {s}", .{ name, if (animator) "plays no clip" else "has no Animator" }) catch "");
        context.begin(.row);
        const make = std.fmt.allocPrint(arena, "Make a cutscene on {s}##make cutscene", .{name}) catch "Make a cutscene##make cutscene";
        if (context.button(make)) self.makeClip(env, entity, name, .cutscene);
        if (animator) {
            if (context.buttonVariant("Make a clip", .outline)) self.makeClip(env, entity, name, .clip);
        } else if (context.buttonVariant("Add an Animator", .outline)) {
            if (env.game.builtinComponent("Animator")) |component| _ = env.game.addComponent(env.app, entity, component);
        }
        page_style.endRow(context);
        context.end();
        page_style.restyle(context, .{ .gap = 10 });
    }

    const Made = enum { cutscene, clip };

    /// Write a new empty clip into `resources/cutscenes/` (or `animations/`) named after the
    /// entity, and have its `Animator` play it, set up as a cutscene's (`makeCutscene`).
    /// The new file and the scene change are each undoable.
    fn makeClip(self: *Dock, env: Env, entity: eggy.ecs.EntityId, name: []const u8, made: Made) void {
        self.makeClipOrFail(env, entity, name, made) catch |err| std.log.err("cannot make a clip for {s}: {t}", .{ name, err });
    }

    fn makeClipOrFail(self: *Dock, env: Env, entity: eggy.ecs.EntityId, name: []const u8, made: Made) !void {
        const gpa = env.history.gpa;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, env.project_dir, .{});
        defer project.close(io);

        // Named after the entity where it can be, else after what it is.
        var title_buffer: [eggy.Name.max_len + 1]u8 = undefined;
        const fallback: [:0]const u8 = if (made == .cutscene) "Cutscene" else "Animation";
        const title: [:0]const u8 = if (file_ops.checkName(name)) std.fmt.bufPrintSentinel(&title_buffer, "{s}", .{name}, 0) catch fallback else |_| fallback;
        try env.history.reserve();
        const path = try file_ops.createFile(gpa, io, project, if (made == .cutscene) "resources/cutscenes" else "resources/animations", .{
            .key = if (made == .cutscene) "eggy/cutscene" else "eggy/animation_clip",
            .title = title,
            .extension = ".clip.zon",
            .contents = creation.cutscene_template,
        });
        env.history.record(.{ .create = .{ .path = path } });

        // Catalogue it now, so it has a key for the Animator and the clip is there to key.
        _ = try env.assets.sync();
        var key_buffer: [key_len]u8 = undefined;
        const key = env.assets.keyOf(&key_buffer, path) orelse return error.NotCatalogued;
        const source = try gpa.dupeSentinel(u8, creation.cutscene_template, 0);
        defer gpa.free(source);
        const clip = try eggy.assets.clip.parse(gpa, source);
        defer clip.deinit(gpa);
        try env.app.graphics.clips.replace(key, clip);
        if (!env.game.assignAnimation(env.app, entity, key, false)) return error.CannotAssign;
        if (made == .cutscene) makeCutscene(env, entity);
        self.source = 0;
        self.markChanged();
    }

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
        self.clearPicked();
        self.view = .{ .duration_s = 0 };
        self.time_s = 0;
        self.duration_for = null;
        if (self.wanted) self.request();
    }

    /// Put the head at `time_s`, stopping playback.
    fn jumpTo(self: *Dock, time_s: f32) void {
        self.time_s = time_s;
        self.playing = false;
        self.request();
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

/// Where a key lands after an edit, by its track and time.
const Landed = struct { target: []const u8, property: Property, node: []const u8, time_s: f32 };

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

/// Set `entity`'s `Animator` up as a cutscene's: waiting for the game, played once, and
/// taking the player's input and HUD while it plays.
fn makeCutscene(env: Env, entity: eggy.ecs.EntityId) void {
    const component = env.game.builtinComponent("Animator") orelse return;
    const settings = [_][2][:0]const u8{ .{ "playing", "false" }, .{ "repeat", ".once" }, .{ "takes_over", ".input_and_hud" } };
    for (env.game.component_types[component].fields, 0..) |field, index| for (settings) |setting| {
        if (!std.mem.eql(u8, field.name, setting[0])) continue;
        if (!env.game.writeField(env.app, entity, component, index, setting[1])) std.log.warn("cannot set the Animator's {s}", .{setting[0]});
    };
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
/// The blend lengths a shot offers, in frames at `timeline.snap_fps`.
const blend_frames = [_]u32{ 3, 6, 10, 15, 20, 30, 45, 60, 90 };
const blend_labels = [_][]const u8{ "3 frames", "6 frames", "10 frames", "15 frames", "20 frames", "30 frames", "45 frames", "60 frames", "90 frames" };

/// The shot a camera key names, as the lane shows it.
fn shotName(text: []const u8) []const u8 {
    return if (text.len == 0) "Game camera" else displayTarget(text);
}

/// A property as people read it.
fn propertyName(property: Property) []const u8 {
    return switch (property) {
        .position => "Position",
        .rotation_deg => "Rotation",
        .scale => "Scale",
        .morph_weight => "Blend shape",
        .fov_deg => "Field of view",
        .visible => "Visible",
        .text => "Text",
        .sound => "Sound",
        .event => "Event",
        .sprite_frame => "Sprite frame",
        .camera => "Camera cut",
    };
}

fn easeName(ease: Ease) []const u8 {
    return switch (ease) {
        .linear => "linear",
        .ease_in => "ease in",
        .ease_out => "ease out",
        .ease_in_out => "ease in-out",
    };
}

/// The lane color of the camera `text` names: the game's own, or the next of the palette for
/// each camera in the order `named` met them.
fn shotColorOf(arena: std.mem.Allocator, named: *std.ArrayList([]const u8), text: []const u8) [3]f32 {
    if (text.len == 0) return timeline.game_color;
    for (named.items, 0..) |known, index| if (std.mem.eql(u8, known, text)) return timeline.shotColor(index);
    named.append(arena, text) catch {};
    return timeline.shotColor(named.items.len - 1);
}

/// The targets in the scene with a `Camera`, as `animationTargets` names them.
fn cameraTargets(arena: std.mem.Allocator, env: Env, entity: eggy.ecs.EntityId) []const []const u8 {
    const listed = env.game.animationTargets(arena, env.app, entity) catch return &.{};
    var cameras: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        if (env.game.animationValue(env.app, entity, line, .fov_deg) == null) continue;
        cameras.append(arena, line) catch break;
    }
    return cameras.items;
}

/// What each of `targets` can be animated by in Add track, read through the game library.
fn offersFor(arena: std.mem.Allocator, env: Env, entity: eggy.ecs.EntityId, clip: *const Clip, targets: []const []const u8, labels: []const []const u8) []const add_track.Target {
    var listed: std.ArrayList(add_track.Target) = .empty;
    for (targets, labels) |target, label| {
        var offers: std.ArrayList(add_track.Offer) = .empty;
        const has = struct {
            fn track(c: *const Clip, t: []const u8, property: Property) bool {
                return c.find(t, property, "") != null;
            }
        }.track;
        var kind: []const u8 = "";
        if (env.game.animationTransform(env.app, entity, target) != null) {
            offers.append(arena, .{ .property = .position, .label = "Position", .on_timeline = has(clip, target, .position) }) catch {};
            offers.append(arena, .{ .property = .rotation_deg, .label = "Rotation", .on_timeline = has(clip, target, .rotation_deg) }) catch {};
            offers.append(arena, .{ .property = .scale, .label = "Scale", .on_timeline = has(clip, target, .scale) }) catch {};
        }
        if (env.game.animationValue(env.app, entity, target, .fov_deg) != null) {
            kind = "Camera";
            offers.append(arena, .{ .property = .fov_deg, .label = "Field of view", .on_timeline = has(clip, target, .fov_deg) }) catch {};
            if (target.len > 0) offers.append(arena, .{ .property = .camera, .label = "Cut to it", .on_timeline = false }) catch {};
        }
        if (env.game.animationValue(env.app, entity, target, .visible) != null) {
            kind = "UI";
            offers.append(arena, .{ .property = .visible, .label = "Visible", .on_timeline = has(clip, target, .visible) }) catch {};
            offers.append(arena, .{ .property = .text, .label = "Text of a node", .on_timeline = false }) catch {};
        }
        if (env.game.animationValue(env.app, entity, target, .sprite_frame) != null) {
            kind = "Sprite";
            offers.append(arena, .{ .property = .sprite_frame, .label = "Sprite frame", .on_timeline = has(clip, target, .sprite_frame) }) catch {};
        }
        offers.append(arena, .{ .property = .sound, .label = "Play a sound", .on_timeline = false }) catch {};
        if (target.len == 0) offers.append(arena, .{ .property = .event, .label = "Event marker", .on_timeline = false }) catch {};
        listed.append(arena, .{ .label = label, .kind = kind, .offers = offers.items }) catch break;
    }
    return listed.items;
}

/// The nearest key of any track before (or after) `head_s`.
fn stepAll(clip: Clip, head_s: f32, toward: enum { previous, next }) ?f32 {
    var found: ?f32 = null;
    for (clip.tracks) |track| {
        const time = timeline.stepKey(track.keys, head_s, if (toward == .previous) .previous else .next) orelse continue;
        found = if (found) |best| (if (toward == .previous) @max(best, time) else @min(best, time)) else time;
    }
    return found;
}

/// What a track's row is named for: its target, or the clip's camera cuts.
fn trackOwner(track: eggy.assets.clip.Track) []const u8 {
    return if (track.property == .camera) "Camera cuts" else displayTarget(track.target);
}

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

test "copied keys paste from the head onto their tracks, and stay picked there" {
    const gpa = std.testing.allocator;
    const clip = Clip{ .duration_s = 2, .tracks = &.{
        .{ .target = "/bee", .property = .position, .keys = &.{ .{ .time_s = 0.5, .value = .{ 1, 0, 0 } }, .{ .time_s = 1, .value = .{ 2, 0, 0 } } } },
        .{ .target = "", .property = .event, .interpolation = .step, .keys = &.{.{ .time_s = 1.25, .text = "buzz" }} },
    } };
    var dock = Dock{};
    defer dock.deinit();
    dock.pick(.{ .track = 0, .key = 1 });
    dock.pick(.{ .track = 1, .key = 0 });
    dock.copy(gpa, clip);
    try std.testing.expectEqual(@as(f32, 0), dock.copied.?.keys[0].key.time_s);
    try std.testing.expectEqual(@as(f32, 0.25), dock.copied.?.keys[1].key.time_s);

    const pasted = try Dock.applied(gpa, &clip, .{ .paste = .{ .keys = dock.copied.?.keys, .at_s = 1.75 } });
    defer pasted.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 2), pasted.duration_s);
    try std.testing.expectEqual(@as(usize, 3), pasted.tracks[0].keys.len);
    try std.testing.expectEqual(@as(f32, 2), pasted.tracks[0].keys[2].value[0]);
    try std.testing.expectEqualStrings("buzz", pasted.tracks[1].keys[1].text);

    dock.pickLanded(pasted, &.{ .{ .target = "/bee", .property = .position, .node = "", .time_s = 1.75 }, .{ .target = "", .property = .event, .node = "", .time_s = 2 } });
    try std.testing.expect(dock.isPicked(.{ .track = 0, .key = 2 }));
    try std.testing.expect(dock.isPicked(.{ .track = 1, .key = 1 }));
    try std.testing.expectEqual(@as(usize, 2), dock.picked_count);
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
