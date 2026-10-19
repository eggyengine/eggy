//! Authored animation clips (`.clip.zon`): keyframes of entity transforms and of the nodes and
//! blend shapes of the model an entity draws. A clip is a value that owns its memory; every edit
//! (`withKey`, `withoutKey`, ...) builds a new clip, so an editor's undo is a stack of clips.
const std = @import("std");

/// The `.clip.zon` layout this build reads and writes; a file of another version is refused.
pub const format_version: u32 = 1;

/// What a track animates. A rotation is Euler degrees about x, then y, then z, like `Transform`,
/// blended linearly.
pub const Property = enum {
    position,
    rotation_deg,
    scale,
    /// A blend shape's weight (the first number of a key); needs a `model:` target.
    morph_weight,
};

pub const Interpolation = enum { step, linear };

/// A value at a time. A `morph_weight` key uses only `value[0]`.
pub const Key = struct {
    time_s: f32,
    value: [3]f32,
};

/// Where a track acts, from its `target` text.
pub const Target = union(enum) {
    /// The animated entity itself (empty text) or a descendant by name: `Arm/Hand`.
    entity: []const u8,
    /// A node (or, for `morph_weight`, a blend shape) of the animated entity's model: `model:Bone`.
    model: []const u8,
};

pub const model_prefix = "model:";

pub const Track = struct {
    /// `""`, a `/`-joined path of child names, or `model:` and a node or blend-shape name.
    target: []const u8,
    property: Property,
    interpolation: Interpolation = .linear,
    /// Ascending in time.
    keys: []const Key,

    /// Where this track acts.
    pub fn where(self: Track) Target {
        if (std.mem.startsWith(u8, self.target, model_prefix)) return .{ .model = self.target[model_prefix.len..] };
        return .{ .entity = self.target };
    }

    /// The value at `time_s`: held before the first key and after the last; null with no keys.
    ///
    /// ```zig
    /// const position = track.valueAt(0.5) orelse return;
    /// ```
    pub fn valueAt(self: Track, time_s: f32) ?[3]f32 {
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
        const t = if (span > 0) (time_s - from.time_s) / span else 0;
        var out: [3]f32 = undefined;
        for (&out, from.value, to.value) |*value, a, b| value.* = a + (b - a) * t;
        return out;
    }
};

pub const Clip = struct {
    format_version: u32 = format_version,
    duration_s: f32,
    tracks: []const Track,

    pub const Error = error{ InvalidClip, UnsupportedVersion };

    /// Whether the clip is consistent: finite numbers, keys ascending inside `0...duration_s`,
    /// valid targets and at most one track for each target and property.
    pub fn validate(self: Clip) Error!void {
        if (self.format_version != format_version) return error.UnsupportedVersion;
        if (!std.math.isFinite(self.duration_s) or self.duration_s < 0) return error.InvalidClip;
        for (self.tracks, 0..) |track, index| {
            if (!validTarget(track)) return error.InvalidClip;
            for (self.tracks[0..index]) |other| {
                if (other.property == track.property and std.mem.eql(u8, other.target, track.target)) return error.InvalidClip;
            }
            var previous: f32 = 0;
            for (track.keys, 0..) |key, at| {
                if (!std.math.isFinite(key.time_s) or key.time_s < 0 or key.time_s > self.duration_s) return error.InvalidClip;
                if (at > 0 and key.time_s <= previous) return error.InvalidClip;
                for (key.value) |number| if (!std.math.isFinite(number)) return error.InvalidClip;
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
        for (self.tracks) |track| {
            gpa.free(track.target);
            gpa.free(track.keys);
        }
        gpa.free(self.tracks);
    }

    /// The track for `property` at `target`, if the clip has one.
    pub fn find(self: Clip, target: []const u8, property: Property) ?usize {
        for (self.tracks, 0..) |track, index| {
            if (track.property == property and std.mem.eql(u8, track.target, target)) return index;
        }
        return null;
    }

    /// This clip with an empty track added (the index of an existing one is `find`'s).
    /// `error.InvalidClip` when the target is not valid for the property or the track exists.
    pub fn withTrack(self: Clip, gpa: std.mem.Allocator, target: []const u8, property: Property) !Clip {
        const added = Track{ .target = target, .property = property, .keys = &.{} };
        if (!validTarget(added) or self.find(target, property) != null) return error.InvalidClip;
        return self.rebuilt(gpa, .{ .add = added });
    }

    /// This clip without track `index`.
    pub fn withoutTrack(self: Clip, gpa: std.mem.Allocator, index: usize) !Clip {
        std.debug.assert(index < self.tracks.len);
        return self.rebuilt(gpa, .{ .remove = index });
    }

    /// This clip with a key at `time_s` in track `index`: replacing the one already there (within
    /// a thousandth of a second), and lengthening the clip to reach it.
    /// `error.InvalidClip` for a time that is negative or not finite, or a value that is not.
    pub fn withKey(self: Clip, gpa: std.mem.Allocator, index: usize, time_s: f32, value: [3]f32) !Clip {
        std.debug.assert(index < self.tracks.len);
        if (!std.math.isFinite(time_s) or time_s < 0) return error.InvalidClip;
        for (value) |number| if (!std.math.isFinite(number)) return error.InvalidClip;
        var clip = try self.rebuilt(gpa, .{ .set_key = .{ .track = index, .key = .{ .time_s = time_s, .value = value } } });
        clip.duration_s = @max(clip.duration_s, time_s);
        return clip;
    }

    /// This clip without key `key` of track `index`.
    pub fn withoutKey(self: Clip, gpa: std.mem.Allocator, index: usize, key: usize) !Clip {
        std.debug.assert(index < self.tracks.len and key < self.tracks[index].keys.len);
        return self.rebuilt(gpa, .{ .remove_key = .{ .track = index, .key = key } });
    }

    /// This clip with key `key` of track `index` moved to `time_s` (keeping its value), replacing a
    /// key already there, and lengthened to reach it.
    pub fn withKeyMoved(self: Clip, gpa: std.mem.Allocator, index: usize, key: usize, time_s: f32) !Clip {
        std.debug.assert(index < self.tracks.len and key < self.tracks[index].keys.len);
        const value = self.tracks[index].keys[key].value;
        const without = try self.withoutKey(gpa, index, key);
        defer without.deinit(gpa);
        return without.withKey(gpa, index, time_s, value);
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
        remove_key: struct { track: usize, key: usize },
    };

    /// A copy with `edit` applied. Every slice is freshly allocated, so the copy is independent.
    fn rebuilt(self: Clip, gpa: std.mem.Allocator, edit: ?Edit) !Clip {
        var tracks: std.ArrayList(Track) = .empty;
        errdefer {
            for (tracks.items) |track| {
                gpa.free(track.target);
                gpa.free(track.keys);
            }
            tracks.deinit(gpa);
        }
        for (self.tracks, 0..) |track, index| {
            if (edit) |change| switch (change) {
                .remove => |removed| if (removed == index) continue,
                else => {},
            };
            const target = try gpa.dupe(u8, track.target);
            errdefer gpa.free(target);
            var keys: std.ArrayList(Key) = .empty;
            errdefer keys.deinit(gpa);
            try keys.appendSlice(gpa, track.keys);
            if (edit) |change| switch (change) {
                .set_key => |set| if (set.track == index) try placeKey(gpa, &keys, set.key),
                .remove_key => |gone| if (gone.track == index) {
                    _ = keys.orderedRemove(gone.key);
                },
                else => {},
            };
            try tracks.append(gpa, .{ .target = target, .property = track.property, .interpolation = track.interpolation, .keys = try keys.toOwnedSlice(gpa) });
        }
        if (edit) |change| switch (change) {
            .add => |added| {
                const target = try gpa.dupe(u8, added.target);
                errdefer gpa.free(target);
                const keys = try gpa.dupe(Key, added.keys);
                errdefer gpa.free(keys);
                try tracks.append(gpa, .{ .target = target, .property = added.property, .interpolation = added.interpolation, .keys = keys });
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

/// Keys closer than this are the same key.
pub const same_time_s = 0.001;

fn validTarget(track: Track) bool {
    switch (track.where()) {
        .model => |name| return name.len > 0 and std.mem.indexOfScalar(u8, name, 0) == null,
        .entity => |path| {
            if (track.property == .morph_weight) return false;
            if (path.len == 0) return true;
            var names = std.mem.splitScalar(u8, path, '/');
            while (names.next()) |name| if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return false;
            return true;
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
    const parsed = try std.zon.parse.fromSliceAlloc(Clip, gpa, source, null, .{});
    errdefer parsed.deinit(gpa);
    try parsed.validate();
    return parsed;
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
    var next = try clip.withTrack(gpa, "Arm", .position);
    clip = next;
    for ([_]struct { f32, f32 }{ .{ 0.5, 5 }, .{ 0, 1 }, .{ 2, 9 }, .{ 0.5, 6 } }) |entry| {
        next = try clip.withKey(gpa, 0, entry[0], .{ entry[1], 0, 0 });
        clip.deinit(gpa);
        clip = next;
    }
    defer clip.deinit(gpa);
    // Sorted; the second key at 0.5 replaced the first; the clip grew to reach 2 seconds.
    try std.testing.expectEqual(@as(usize, 3), clip.tracks[0].keys.len);
    try std.testing.expectEqual(@as(f32, 6), clip.tracks[0].keys[1].value[0]);
    try std.testing.expectEqual(@as(f32, 2), clip.duration_s);

    const moved = try clip.withKeyMoved(gpa, 0, 1, 1.5);
    defer moved.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 1.5), moved.tracks[0].keys[1].time_s);
    try std.testing.expectEqual(@as(f32, 6), moved.tracks[0].keys[1].value[0]);
    try moved.validate();

    const deleted = try moved.withoutKey(gpa, 0, 0);
    defer deleted.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), deleted.tracks[0].keys.len);
    try std.testing.expectEqual(@as(?usize, 0), deleted.find("Arm", .position));
    try std.testing.expect(deleted.find("Arm", .scale) == null);
}

test "a clip survives writing and parsing, and a bad one is refused" {
    const gpa = std.testing.allocator;
    var clip = try (Clip{ .duration_s = 2, .tracks = &.{} }).withTrack(gpa, "", .rotation_deg);
    var next = try clip.withKey(gpa, 0, 0, .{ 0, 0, 0 });
    clip.deinit(gpa);
    clip = next;
    next = try clip.withKey(gpa, 0, 2, .{ 0, 90, 0 });
    clip.deinit(gpa);
    clip = next;
    next = try clip.withTrack(gpa, "model:smile", .morph_weight);
    clip.deinit(gpa);
    clip = next;
    defer clip.deinit(gpa);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try clip.write(&text.writer);
    const source = try gpa.dupeZ(u8, text.written());
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
