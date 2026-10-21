//! A model's imported animation as an independently loadable, identity-addressed asset.
const std = @import("std");
const s2s = @import("s2s");
const model = @import("model.zig");

pub const magic = "EGGYCLIP".*;
pub const format_version: u32 = 1;

pub const File = struct {
    signature: [8]u8 = magic,
    version: u32 = format_version,
    /// The geometry/skeleton asset this clip's node, part and morph indices belong to.
    source_model: u64,
    clip: model.Clip,

    /// Release a file returned by `read`; borrowed source-model clips must not be freed here.
    pub fn deinit(self: File, gpa: std.mem.Allocator) void {
        gpa.free(self.clip.name);
        for (self.clip.tracks) |track| {
            gpa.free(track.times);
            gpa.free(track.values);
        }
        gpa.free(self.clip.tracks);
    }

    /// Check standalone channel data; target indices are additionally checked against its model.
    pub fn validate(self: File) !void {
        if (!std.mem.eql(u8, &self.signature, &magic) or self.version != format_version) return error.UnsupportedClipVersion;
        if (self.source_model == 0 or self.clip.name.len == 0 or !std.unicode.utf8ValidateSlice(self.clip.name) or
            !std.math.isFinite(self.clip.duration_s) or self.clip.duration_s < 0) return error.InvalidClip;
        for (self.clip.tracks) |track| {
            const stride = switch (track.channel) {
                .translation, .scale => 3,
                .rotation => 4,
                .morph_weights, .vertex_cache => track.stride,
            };
            if (stride == 0 or track.times.len == 0 or track.stride != stride or (track.channel == .vertex_cache and stride % 3 != 0)) return error.InvalidClip;
            const count = std.math.mul(usize, track.times.len, stride) catch return error.InvalidClip;
            if (track.values.len != count) return error.InvalidClip;
            for (track.times, 0..) |time, index| {
                if (!std.math.isFinite(time) or time < 0 or time > self.clip.duration_s or
                    (index > 0 and time < track.times[index - 1])) return error.InvalidClip;
            }
            for (track.values) |value| if (!std.math.isFinite(value)) return error.InvalidClip;
        }
    }

    /// Refuse clips from another skeleton or channel indices outside this model.
    pub fn validateFor(self: File, model_id: u64, skeleton: model.Model) !void {
        try self.validate();
        if (self.source_model != model_id) return error.IncompatibleAnimationModel;
        if (!skeleton.clipIsWhole(self.clip)) return error.InvalidClip;
    }
};

/// Write a validated clip; its source model and channel arrays remain borrowed.
pub fn write(writer: *std.Io.Writer, file: File) !void {
    try file.validate();
    try s2s.serialize(writer, File, file);
}

/// Read independently owned clip arrays, rejecting corrupt headers and channels.
pub fn read(gpa: std.mem.Allocator, reader: *std.Io.Reader) !File {
    const file = try s2s.deserializeAlloc(reader, File, gpa);
    errdefer file.deinit(gpa);
    try file.validate();
    return file;
}

test "imported clips roundtrip independently of model geometry" {
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{ 0, 0, 0, 1, 2, 3 };
    var tracks = [_]model.Track{.{ .channel = .translation, .target = 0, .stride = 3, .times = &times, .values = &values }};
    const source = File{ .source_model = 42, .clip = .{ .name = "walk", .duration_s = 1, .tracks = &tracks } };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, source);
    var reader: std.Io.Reader = .fixed(bytes.written());
    const result = try read(std.testing.allocator, &reader);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), result.source_model);
    try std.testing.expectEqualStrings("walk", result.clip.name);
    try std.testing.expectEqualSlices(f32, &values, result.clip.tracks[0].values);
}

test "imported clips reject malformed channels and incompatible source models" {
    const file = File{ .source_model = 42, .clip = .{ .name = "walk", .duration_s = 1, .tracks = &.{} } };
    const empty = model.Model{ .vertices = &.{}, .indices = &.{}, .parts = &.{}, .textures = &.{} };
    try std.testing.expectError(error.IncompatibleAnimationModel, file.validateFor(43, empty));
    var invalid = file;
    invalid.source_model = 0;
    try std.testing.expectError(error.InvalidClip, invalid.validate());
    var times = [_]f32{ 0, 0 };
    var values = [_]f32{ 0, 0, 0, 1, 0, 0 };
    var tracks = [_]model.Track{.{ .channel = .translation, .target = 0, .stride = 3, .times = &times, .values = &values }};
    const repeated = File{ .source_model = 42, .clip = .{ .name = "step", .duration_s = 1, .tracks = &tracks } };
    try repeated.validate();
    try std.testing.expectError(error.InvalidClip, repeated.validateFor(42, empty));
    times[1] = -1;
    try std.testing.expectError(error.InvalidClip, repeated.validate());
    times[1] = 1;
    tracks[0].stride = 4;
    try std.testing.expectError(error.InvalidClip, repeated.validate());
}
