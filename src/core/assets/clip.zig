//! Authored animation clips (`.clip.zon`): keyframes of entity transforms, of the nodes and
//! blend shapes of the model an entity draws, and of what a cutscene needs besides: a camera's
//! field of view, UI text and visibility, sprite frames, sounds and named events. A track may
//! act on the animated entity, a descendant, or any entity in the scene (`/bee`). A clip is a
//! value that owns its memory; every edit (`withKey`, `withoutKey`, ...) builds a new clip, so an
//! editor's undo is a stack of clips.
const std = @import("std");
const zon_file = @import("zon.zig");

/// The `.clip.zon` layout this build writes. It reads this one and `1`, which had only transform
/// and blend-shape tracks; a file of another version is refused.
pub const format_version: u32 = 3;
const oldest_version: u32 = 1;

/// What a track animates. A rotation is Euler degrees about x, then y, then z, like `Transform`,
/// blended linearly.
pub const Property = enum {
    position,
    rotation_deg,
    scale,
    /// A blend shape's weight (the first number of a key); needs a `model:` target.
    morph_weight,
    /// A `Camera`'s field of view in degrees (`value[0]`).
    fov_deg,
    /// Shown when `value[0]` is above a half: the track's UI `node`, or with no node the
    /// entity's `UiScreen` or `UiBillboard`.
    visible,
    /// What the track's UI `node` says: the key's `text`.
    text,
    /// The sound asset (the key's `text`, an `AssetRef(.audio)` key) the entity's `AudioSource`
    /// starts when the key is passed.
    sound,
    /// A named marker (the key's `text`) plugins hear in `animationEvent` when it is passed.
    event,
    /// The first frame of the run a `SpriteAnimator` plays (`value[0]`).
    sprite_frame,

    /// Whether it changes in steps at its keys rather than blending between them, and acts only
    /// from its first key on.
    pub fn discrete(self: Property) bool {
        return switch (self) {
            .position, .rotation_deg, .scale, .morph_weight, .fov_deg => false,
            .visible, .text, .sound, .event, .sprite_frame => true,
        };
    }

    /// Whether its keys carry `text` rather than numbers.
    pub fn textual(self: Property) bool {
        return self == .text or self == .sound or self == .event;
    }

    /// Whether its keys fire once as the clip passes them (rather than setting a state).
    pub fn fires(self: Property) bool {
        return self == .sound or self == .event;
    }

    /// Whether a track of it names a UI node (`text` must, `visible` may).
    pub fn takesNode(self: Property) bool {
        return self == .text or self == .visible;
    }

    /// Whether it can act on a model's node or blend shape (`model:` targets).
    pub fn onModel(self: Property) bool {
        return switch (self) {
            .position, .rotation_deg, .scale, .morph_weight => true,
            else => false,
        };
    }
};

pub const Interpolation = enum { step, linear };

/// How a blending track speeds up and slows down across the span leaving a key, to the next.
pub const Ease = enum {
    linear,
    /// Starts slow and speeds up.
    ease_in,
    /// Starts fast and settles.
    ease_out,
    ease_in_out,

    /// How far along the span `t` (0 to 1) of the way through it is.
    pub fn apply(self: Ease, t: f32) f32 {
        return switch (self) {
            .linear => t,
            .ease_in => t * t,
            .ease_out => 1 - (1 - t) * (1 - t),
            .ease_in_out => t * t * (3 - 2 * t),
        };
    }
};

/// A value at a time. A `morph_weight`, `fov_deg`, `visible` or `sprite_frame` key uses only
/// `value[0]`; a `text`, `sound` or `event` key uses `text`.
pub const Key = struct {
    time_s: f32,
    value: [3]f32 = .{ 0, 0, 0 },
    text: []const u8 = "",
    /// The span to the next key; blending tracks only.
    ease: Ease = .linear,
};

/// Key `key` of track `track` in a clip.
pub const KeyRef = struct { track: usize, key: usize };

/// What `Clip.withKeysChanged` does to the keys it is given.
pub const KeyChange = union(enum) {
    /// Moved later by this many seconds (earlier when negative), stopping at 0.
    shift_s: f32,
    remove,
    ease: Ease,
};

/// Where a track acts, from its `target` text.
pub const Target = union(enum) {
    /// The animated entity itself (empty text) or a descendant by name: `Arm/Hand`.
    entity: []const u8,
    /// An entity anywhere in the scene, by names from the top: `/bee`, `/garden/gate`.
    scene: []const u8,
    /// A node (or, for `morph_weight`, a blend shape) of the animated entity's model: `model:Bone`.
    model: []const u8,
};

pub const model_prefix = "model:";
/// Starts a target that names an entity from the top of the scene.
pub const scene_prefix = "/";
/// The longest text a key holds, in bytes.
pub const max_text_len = 1024;

pub const Track = struct {
    /// `""`, a `/`-joined path of child names, `/` and a path from the top of the scene, or
    /// `model:` and a node or blend-shape name.
    target: []const u8,
    property: Property,
    /// The UI node a `text` or `visible` track sets, by name; empty for none.
    node: []const u8 = "",
    interpolation: Interpolation = .linear,
    /// Ascending in time.
    keys: []const Key,

    /// Where this track acts.
    pub fn where(self: Track) Target {
        if (std.mem.startsWith(u8, self.target, model_prefix)) return .{ .model = self.target[model_prefix.len..] };
        if (std.mem.startsWith(u8, self.target, scene_prefix)) return .{ .scene = self.target[scene_prefix.len..] };
        return .{ .entity = self.target };
    }

    /// The value at `time_s`: held before the first key and after the last; null with no keys.
    /// A discrete property's value changes at each key and is null before the first.
    ///
    /// ```zig
    /// const position = track.valueAt(0.5) orelse return;
    /// ```
    pub fn valueAt(self: Track, time_s: f32) ?[3]f32 {
        if (self.property.discrete()) return if (self.keyAt(time_s)) |key| key.value else null;
        if (self.keys.len == 0) return null;
        const keys = self.keys;
        if (time_s <= keys[0].time_s) return keys[0].value;
        if (time_s >= keys[keys.len - 1].time_s) return keys[keys.len - 1].value;
        // The first key after `time_s`; the one before it starts the span.
        var next: usize = 1;
        while (keys[next].time_s <= time_s) next += 1;
        const from = keys[next - 1];
        const to = keys[next];
        if (self.interpolation == .step) return from.value;
        const span = to.time_s - from.time_s;
        const t = from.ease.apply(if (span > 0) (time_s - from.time_s) / span else 0);
        var out: [3]f32 = undefined;
        for (&out, from.value, to.value) |*value, a, b| value.* = a + (b - a) * t;
        return out;
    }

    /// The last key at or before `time_s`; null before the first.
    pub fn keyAt(self: Track, time_s: f32) ?Key {
        var found: ?Key = null;
        for (self.keys) |key| {
            if (key.time_s > time_s) break;
            found = key;
        }
        return found;
    }

    /// The indices of keys in `from_s <= time < to_s`, the ones a clip playing forwards passes
    /// between two steps; empty when `to_s` isn't after `from_s`.
    pub fn passed(self: Track, from_s: f32, to_s: f32) Range {
        var range = Range{ .start = 0, .end = 0 };
        if (!(to_s > from_s)) return range;
        while (range.start < self.keys.len and self.keys[range.start].time_s < from_s) range.start += 1;
        range.end = range.start;
        while (range.end < self.keys.len and self.keys[range.end].time_s < to_s) range.end += 1;
        return range;
    }

    pub const Range = struct { start: usize, end: usize };

    /// How the track reads in an editor: its property, and its node when it has one (`text:line`).
    pub fn label(self: Track, buffer: []u8) []const u8 {
        if (self.node.len == 0) return @tagName(self.property);
        return std.fmt.bufPrint(buffer, "{t}:{s}", .{ self.property, self.node }) catch @tagName(self.property);
    }
};

pub const Clip = struct {
    format_version: u32 = format_version,
    duration_s: f32,
    tracks: []const Track,

    pub const Error = error{ InvalidClip, UnsupportedVersion };

    /// Whether the clip is consistent: finite numbers, keys ascending inside `0...duration_s`,
    /// valid targets, UTF-8 texts, and at most one track for each target, property and node.
    pub fn validate(self: Clip) Error!void {
        if (self.format_version < oldest_version or self.format_version > format_version) return error.UnsupportedVersion;
        if (!std.math.isFinite(self.duration_s) or self.duration_s < 0) return error.InvalidClip;
        for (self.tracks, 0..) |track, index| {
            if (!validTarget(track)) return error.InvalidClip;
            for (self.tracks[0..index]) |other| {
                if (sameChannel(other, track.target, track.property, track.node)) return error.InvalidClip;
            }
            var previous: f32 = 0;
            for (track.keys, 0..) |key, at| {
                if (!std.math.isFinite(key.time_s) or key.time_s < 0 or key.time_s > self.duration_s) return error.InvalidClip;
                if (at > 0 and key.time_s <= previous) return error.InvalidClip;
                if (!validKey(key)) return error.InvalidClip;
                previous = key.time_s;
            }
        }
    }

    /// A copy owning its own memory; free it with `deinit`.
    pub fn clone(self: Clip, gpa: std.mem.Allocator) !Clip {
        return self.rebuilt(gpa, null);
    }

    /// Free what `parse` or an edit allocated with `gpa`.
    pub fn deinit(self: Clip, gpa: std.mem.Allocator) void {
        for (self.tracks) |track| freeTrack(gpa, track);
        gpa.free(self.tracks);
    }

    /// The track for `property` at `target` (and UI `node`, empty for none), if the clip has one.
    pub fn find(self: Clip, target: []const u8, property: Property, node: []const u8) ?usize {
        for (self.tracks, 0..) |track, index| {
            if (sameChannel(track, target, property, node)) return index;
        }
        return null;
    }

    /// This clip with an empty track added (the index of an existing one is `find`'s). A
    /// discrete property's track steps from key to key.
    /// `error.InvalidClip` when the target or node is not valid for the property or the track
    /// exists.
    pub fn withTrack(self: Clip, gpa: std.mem.Allocator, target: []const u8, property: Property, node: []const u8) !Clip {
        const added = Track{ .target = target, .property = property, .node = node, .interpolation = if (property.discrete()) .step else .linear, .keys = &.{} };
        if (!validTarget(added) or self.find(target, property, node) != null) return error.InvalidClip;
        return self.rebuilt(gpa, .{ .add = added });
    }

    /// This clip without track `index`.
    pub fn withoutTrack(self: Clip, gpa: std.mem.Allocator, index: usize) !Clip {
        std.debug.assert(index < self.tracks.len);
        return self.rebuilt(gpa, .{ .remove = index });
    }

    /// This clip with `key` in track `index`: replacing the one already there (within a
    /// thousandth of a second), and lengthening the clip to reach it. The key's text is copied.
    /// `error.InvalidClip` for a time that is negative or not finite, a value that is not, or a
    /// text that isn't UTF-8 or is too long.
    pub fn withKey(self: Clip, gpa: std.mem.Allocator, index: usize, key: Key) !Clip {
        std.debug.assert(index < self.tracks.len);
        if (!std.math.isFinite(key.time_s) or key.time_s < 0 or !validKey(key)) return error.InvalidClip;
        var clip = try self.rebuilt(gpa, .{ .set_key = .{ .track = index, .key = key } });
        clip.duration_s = @max(clip.duration_s, key.time_s);
        return clip;
    }

    /// This clip with `change` made to each of `keys` (any order; ones that don't exist are
    /// ignored). Shifted keys keep their value and text, replace a key already where they land,
    /// and lengthen the clip to reach them.
    /// `error.InvalidClip` for a shift that is not finite.
    pub fn withKeysChanged(self: Clip, gpa: std.mem.Allocator, keys: []const KeyRef, change: KeyChange) !Clip {
        if (change == .shift_s and !std.math.isFinite(change.shift_s)) return error.InvalidClip;
        var tracks: std.ArrayList(Track) = .empty;
        errdefer {
            for (tracks.items) |track| freeTrack(gpa, track);
            tracks.deinit(gpa);
        }
        var duration_s = self.duration_s;
        for (self.tracks, 0..) |track, track_index| {
            // The keys left where they are, and those shifted, placed among them after.
            var kept: std.ArrayList(Key) = .empty;
            defer kept.deinit(gpa);
            var shifted: std.ArrayList(Key) = .empty;
            defer shifted.deinit(gpa);
            for (track.keys, 0..) |key, key_index| {
                if (!refersTo(keys, track_index, key_index)) {
                    try kept.append(gpa, key);
                    continue;
                }
                var changed = key;
                switch (change) {
                    .remove => {},
                    .ease => |ease| {
                        changed.ease = ease;
                        try kept.append(gpa, changed);
                    },
                    .shift_s => |delta_s| {
                        changed.time_s = @max(0, key.time_s + delta_s);
                        try shifted.append(gpa, changed);
                    },
                }
            }
            for (shifted.items) |key| {
                try placeKey(gpa, &kept, key);
                duration_s = @max(duration_s, key.time_s);
            }
            var shaped = track;
            shaped.keys = kept.items;
            try tracks.ensureUnusedCapacity(gpa, 1);
            tracks.appendAssumeCapacity(try ownTrack(gpa, shaped));
        }
        return .{ .duration_s = duration_s, .tracks = try tracks.toOwnedSlice(gpa) };
    }

    /// This clip lasting `duration_s`, which must reach the last key of every track.
    pub fn withDuration(self: Clip, gpa: std.mem.Allocator, duration_s: f32) !Clip {
        var clip = try self.clone(gpa);
        errdefer clip.deinit(gpa);
        clip.duration_s = duration_s;
        try clip.validate();
        return clip;
    }

    const Edit = union(enum) {
        add: Track,
        remove: usize,
        set_key: struct { track: usize, key: Key },
    };

    /// A copy with `edit` applied, in the current format. Every slice is freshly allocated, so
    /// the copy is independent.
    fn rebuilt(self: Clip, gpa: std.mem.Allocator, edit: ?Edit) !Clip {
        var tracks: std.ArrayList(Track) = .empty;
        errdefer {
            for (tracks.items) |track| freeTrack(gpa, track);
            tracks.deinit(gpa);
        }
        for (self.tracks, 0..) |track, index| {
            if (edit) |change| switch (change) {
                .remove => |removed| if (removed == index) continue,
                else => {},
            };
            // The keys as they will be, still borrowing their texts; `ownTrack` copies those.
            var keys: std.ArrayList(Key) = .empty;
            defer keys.deinit(gpa);
            try keys.appendSlice(gpa, track.keys);
            if (edit) |change| switch (change) {
                .set_key => |set| if (set.track == index) try placeKey(gpa, &keys, set.key),
                else => {},
            };
            var shaped = track;
            shaped.keys = keys.items;
            try tracks.ensureUnusedCapacity(gpa, 1);
            tracks.appendAssumeCapacity(try ownTrack(gpa, shaped));
        }
        if (edit) |change| switch (change) {
            .add => |added| {
                try tracks.ensureUnusedCapacity(gpa, 1);
                tracks.appendAssumeCapacity(try ownTrack(gpa, added));
            },
            else => {},
        };
        return .{ .duration_s = self.duration_s, .tracks = try tracks.toOwnedSlice(gpa) };
    }

    /// Write the clip as `.clip.zon` text.
    pub fn write(self: Clip, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.zon.stringify.serialize(self, .{}, writer);
    }
};

/// A key in order among `keys`, replacing one at (nearly) the same time.
fn placeKey(gpa: std.mem.Allocator, keys: *std.ArrayList(Key), key: Key) !void {
    var at: usize = 0;
    while (at < keys.items.len and keys.items[at].time_s < key.time_s - same_time_s) at += 1;
    if (at < keys.items.len and @abs(keys.items[at].time_s - key.time_s) <= same_time_s) {
        keys.items[at] = key;
        return;
    }
    try keys.insert(gpa, at, key);
}

/// `track` with its target, node, keys and their texts copied into `gpa`'s memory.
fn ownTrack(gpa: std.mem.Allocator, track: Track) !Track {
    const target = try gpa.dupe(u8, track.target);
    errdefer gpa.free(target);
    const node = try gpa.dupe(u8, track.node);
    errdefer gpa.free(node);
    const keys = try gpa.dupe(Key, track.keys);
    var owned: usize = 0;
    errdefer {
        for (keys[0..owned]) |key| gpa.free(key.text);
        gpa.free(keys);
    }
    for (keys) |*key| {
        key.text = try gpa.dupe(u8, key.text);
        owned += 1;
    }
    var result = track;
    result.target = target;
    result.node = node;
    result.keys = keys;
    return result;
}

fn freeTrack(gpa: std.mem.Allocator, track: Track) void {
    for (track.keys) |key| gpa.free(key.text);
    gpa.free(track.keys);
    gpa.free(track.node);
    gpa.free(track.target);
}

fn refersTo(keys: []const KeyRef, track: usize, key: usize) bool {
    for (keys) |ref| if (ref.track == track and ref.key == key) return true;
    return false;
}

fn sameChannel(track: Track, target: []const u8, property: Property, node: []const u8) bool {
    return track.property == property and std.mem.eql(u8, track.target, target) and std.mem.eql(u8, track.node, node);
}

/// Keys closer than this are the same key.
pub const same_time_s = 0.001;

fn validKey(key: Key) bool {
    for (key.value) |number| if (!std.math.isFinite(number)) return false;
    return key.text.len <= max_text_len and std.unicode.utf8ValidateSlice(key.text);
}

fn validName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfScalar(u8, name, 0) == null;
}

fn validPath(path: []const u8) bool {
    var names = std.mem.splitScalar(u8, path, '/');
    while (names.next()) |name| if (!validName(name)) return false;
    return true;
}

fn validTarget(track: Track) bool {
    // Only UI tracks name a node, and `text` must.
    if (track.node.len > 0 and (!track.property.takesNode() or !validName(track.node))) return false;
    if (track.property == .text and track.node.len == 0) return false;
    switch (track.where()) {
        .model => |name| return track.property.onModel() and validName(name),
        .scene => |path| return track.property != .morph_weight and validPath(path),
        .entity => |path| {
            if (track.property == .morph_weight) return false;
            return path.len == 0 or validPath(path);
        },
    }
}

/// Read `.clip.zon` text into a clip owning its memory (free with `deinit`). Fails with
/// `error.InvalidClip`, `error.UnsupportedVersion` or the parser's errors; nothing is leaked.
///
/// ```zig
/// const clip = try parse(gpa, source);
/// defer clip.deinit(gpa);
/// ```
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Clip {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = try zon_file.parse(Clip, arena.allocator(), source, .{});
    try parsed.validate();
    return parsed.clone(gpa);
}

test "a track holds before its first key, blends between keys and holds after the last" {
    const track = Track{ .target = "", .property = .position, .keys = &.{
        .{ .time_s = 1, .value = .{ 0, 0, 0 } },
        .{ .time_s = 3, .value = .{ 4, 8, 0 } },
    } };
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, track.valueAt(0).?);
    try std.testing.expectEqual([3]f32{ 2, 4, 0 }, track.valueAt(2).?);
    try std.testing.expectEqual([3]f32{ 4, 8, 0 }, track.valueAt(9).?);
    var stepped = track;
    stepped.interpolation = .step;
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, stepped.valueAt(2.9).?);
    try std.testing.expect((Track{ .target = "", .property = .scale, .keys = &.{} }).valueAt(0) == null);
}

test "keys are inserted in time order, replaced at the same time, moved and deleted" {
    const gpa = std.testing.allocator;
    var clip = Clip{ .duration_s = 1, .tracks = &.{} };
    var next = try clip.withTrack(gpa, "Arm", .position, "");
    clip = next;
    for ([_]struct { f32, f32 }{ .{ 0.5, 5 }, .{ 0, 1 }, .{ 2, 9 }, .{ 0.5, 6 } }) |entry| {
        next = try clip.withKey(gpa, 0, .{ .time_s = entry[0], .value = .{ entry[1], 0, 0 } });
        clip.deinit(gpa);
        clip = next;
    }
    defer clip.deinit(gpa);
    // Sorted; the second key at 0.5 replaced the first; the clip grew to reach 2 seconds.
    try std.testing.expectEqual(@as(usize, 3), clip.tracks[0].keys.len);
    try std.testing.expectEqual(@as(f32, 6), clip.tracks[0].keys[1].value[0]);
    try std.testing.expectEqual(@as(f32, 2), clip.duration_s);

    const moved = try clip.withKeysChanged(gpa, &.{.{ .track = 0, .key = 1 }}, .{ .shift_s = 1 });
    defer moved.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 1.5), moved.tracks[0].keys[1].time_s);
    try std.testing.expectEqual(@as(f32, 6), moved.tracks[0].keys[1].value[0]);
    try moved.validate();

    const deleted = try moved.withKeysChanged(gpa, &.{.{ .track = 0, .key = 0 }}, .remove);
    defer deleted.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), deleted.tracks[0].keys.len);
    try std.testing.expectEqual(@as(?usize, 0), deleted.find("Arm", .position, ""));
    try std.testing.expect(deleted.find("Arm", .scale, "") == null);
}

test "a clip survives writing and parsing, and a bad one is refused" {
    const gpa = std.testing.allocator;
    var clip = try (Clip{ .duration_s = 2, .tracks = &.{} }).withTrack(gpa, "", .rotation_deg, "");
    var next = try clip.withKey(gpa, 0, .{ .time_s = 0 });
    clip.deinit(gpa);
    clip = next;
    next = try clip.withKey(gpa, 0, .{ .time_s = 2, .value = .{ 0, 90, 0 } });
    clip.deinit(gpa);
    clip = next;
    next = try clip.withTrack(gpa, "model:smile", .morph_weight, "");
    clip.deinit(gpa);
    clip = next;
    defer clip.deinit(gpa);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try clip.write(&text.writer);
    const source = try gpa.dupeSentinel(u8, text.written(), 0);
    defer gpa.free(source);
    const again = try parse(gpa, source);
    defer again.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), again.tracks.len);
    try std.testing.expectEqual(@as(f32, 90), again.tracks[0].keys[1].value[1]);
    try std.testing.expectEqualStrings("model:smile", again.tracks[1].target);

    // Another version, keys out of order, a key past the end and a morph track on an entity.
    try std.testing.expectError(error.UnsupportedVersion, parse(gpa, ".{ .format_version = 9, .duration_s = 1, .tracks = .{} }"));
    try std.testing.expectError(error.InvalidClip, parse(gpa, ".{ .format_version = 1, .duration_s = 1, .tracks = .{ .{ .target = \"\", .property = .position, .keys = .{ .{ .time_s = 0.5, .value = .{ 0, 0, 0 } }, .{ .time_s = 0.2, .value = .{ 0, 0, 0 } } } } } }"));
    try std.testing.expectError(error.InvalidClip, parse(gpa, ".{ .format_version = 1, .duration_s = 1, .tracks = .{ .{ .target = \"\", .property = .scale, .keys = .{ .{ .time_s = 4, .value = .{ 1, 1, 1 } } } } } }"));
    try std.testing.expectError(error.InvalidClip, parse(gpa, ".{ .format_version = 1, .duration_s = 1, .tracks = .{ .{ .target = \"Arm\", .property = .morph_weight, .keys = .{} } } }"));
}

test "cutscene tracks keep text, step from key to key, and say which keys a step passed" {
    const gpa = std.testing.allocator;
    var clip = try (Clip{ .duration_s = 4, .tracks = &.{} }).withTrack(gpa, "/dialogue", .text, "line");
    var next = try clip.withKey(gpa, 0, .{ .time_s = 1, .text = "Bzz! You there" });
    clip.deinit(gpa);
    clip = next;
    next = try clip.withKey(gpa, 0, .{ .time_s = 3, .text = "Someone took my flower" });
    clip.deinit(gpa);
    clip = next;
    next = try clip.withTrack(gpa, "", .event, "");
    clip.deinit(gpa);
    clip = next;
    next = try clip.withKey(gpa, 1, .{ .time_s = 2, .text = "wait_for_choice" });
    clip.deinit(gpa);
    clip = next;
    defer clip.deinit(gpa);

    // Nothing before the first line, then each line holds until the next.
    const lines = clip.tracks[0];
    try std.testing.expectEqual(Interpolation.step, lines.interpolation);
    try std.testing.expect(lines.keyAt(0.5) == null);
    try std.testing.expectEqualStrings("Bzz! You there", lines.keyAt(2.9).?.text);
    try std.testing.expectEqualStrings("Someone took my flower", lines.keyAt(3).?.text);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("text:line", lines.label(&buffer));

    // A step from 1.5 s to 2.5 s passes the event; one ending on it doesn't yet.
    const passed = clip.tracks[1].passed(1.5, 2.5);
    try std.testing.expectEqual(@as(usize, 1), passed.end - passed.start);
    const short = clip.tracks[1].passed(1.5, 2);
    try std.testing.expectEqual(short.start, short.end);

    // Texts survive writing and parsing; a version 1 file still reads.
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try clip.write(&text.writer);
    const source = try gpa.dupeSentinel(u8, text.written(), 0);
    defer gpa.free(source);
    const again = try parse(gpa, source);
    defer again.deinit(gpa);
    try std.testing.expectEqualStrings("wait_for_choice", again.tracks[1].keys[0].text);
    try std.testing.expectEqualStrings("line", again.tracks[0].node);
    const old = try parse(gpa, ".{ .format_version = 1, .duration_s = 1, .tracks = .{ .{ .target = \"Arm\", .property = .position, .keys = .{ .{ .time_s = 0, .value = .{ 1, 2, 3 } } } } } }");
    defer old.deinit(gpa);
    try std.testing.expectEqual(format_version, old.format_version);

    // A text track needs a node, a model target only moves the model, and scene paths need names.
    const empty = Clip{ .duration_s = 1, .tracks = &.{} };
    try std.testing.expectError(error.InvalidClip, empty.withTrack(gpa, "/dialogue", .text, ""));
    try std.testing.expectError(error.InvalidClip, empty.withTrack(gpa, "model:Head", .fov_deg, ""));
    try std.testing.expectError(error.InvalidClip, empty.withTrack(gpa, "/", .position, ""));
    try std.testing.expectError(error.InvalidClip, empty.withTrack(gpa, "camera", .position, "line"));
}

test "a key's ease shapes the span leaving it" {
    var track = Track{ .target = "", .property = .position, .keys = &.{
        .{ .time_s = 0, .value = .{ 0, 0, 0 }, .ease = .ease_in },
        .{ .time_s = 2, .value = .{ 8, 0, 0 } },
    } };
    // A quarter of the way in at half time, then all the way at the key.
    try std.testing.expectEqual(@as(f32, 2), track.valueAt(1).?[0]);
    try std.testing.expectEqual(@as(f32, 8), track.valueAt(2).?[0]);
    track.keys = &.{ .{ .time_s = 0, .value = .{ 0, 0, 0 }, .ease = .ease_out }, .{ .time_s = 2, .value = .{ 8, 0, 0 } } };
    try std.testing.expectEqual(@as(f32, 6), track.valueAt(1).?[0]);
    try std.testing.expectEqual(@as(f32, 0.5), Ease.ease_in_out.apply(0.5));
}

test "several keys across tracks shift, ease and go together" {
    const gpa = std.testing.allocator;
    const source = Clip{ .duration_s = 2, .tracks = &.{
        .{ .target = "", .property = .position, .keys = &.{ .{ .time_s = 0 }, .{ .time_s = 1 }, .{ .time_s = 2 } } },
        .{ .target = "/bee", .property = .scale, .keys = &.{ .{ .time_s = 0.5 }, .{ .time_s = 1.5 } } },
    } };
    const picked = [_]KeyRef{ .{ .track = 0, .key = 1 }, .{ .track = 1, .key = 1 }, .{ .track = 1, .key = 9 } };

    // Shifted later: the clip grows to reach the last; the first track's middle key lands on
    // the one at 2 s and takes its place.
    const later = try source.withKeysChanged(gpa, &picked, .{ .shift_s = 1 });
    defer later.deinit(gpa);
    try later.validate();
    try std.testing.expectEqual(@as(f32, 2.5), later.duration_s);
    try std.testing.expectEqual(@as(usize, 2), later.tracks[0].keys.len);
    try std.testing.expectEqual(@as(f32, 2.5), later.tracks[1].keys[1].time_s);

    // Earlier than the start, they stop at 0.
    const earlier = try source.withKeysChanged(gpa, &.{.{ .track = 1, .key = 0 }}, .{ .shift_s = -3 });
    defer earlier.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 0), earlier.tracks[1].keys[0].time_s);

    const eased = try source.withKeysChanged(gpa, &picked, .{ .ease = .ease_out });
    defer eased.deinit(gpa);
    try std.testing.expectEqual(Ease.ease_out, eased.tracks[0].keys[1].ease);
    try std.testing.expectEqual(Ease.linear, eased.tracks[0].keys[0].ease);

    const removed = try source.withKeysChanged(gpa, &picked, .remove);
    defer removed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), removed.tracks[0].keys.len);
    try std.testing.expectEqual(@as(usize, 1), removed.tracks[1].keys.len);
    try std.testing.expectError(error.InvalidClip, source.withKeysChanged(gpa, &picked, .{ .shift_s = std.math.inf(f32) }));
}
