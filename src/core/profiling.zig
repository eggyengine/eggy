//! Frame-local CPU timing samples and numeric counters exposed to games and DevTools.
const std = @import("std");
const sdl = @import("vitellus_sdl3").sdl;
pub const support: @import("support.zig").Support = .available;
pub const Sample = enum(u64) { _ };
pub const max_samples = 128;
pub const max_counters = 64;

pub const Name = struct {
    bytes: [96]u8 = undefined,
    len: u8 = 0,

    pub fn text(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    fn init(text_value: []const u8) !Name {
        if (text_value.len == 0 or text_value.len > 96) return error.InvalidProfileName;
        if (!std.unicode.utf8ValidateSlice(text_value)) return error.InvalidProfileName;
        var name = Name{ .len = @intCast(text_value.len) };
        @memcpy(name.bytes[0..text_value.len], text_value);
        return name;
    }
};

pub const Timing = struct { name: Name, start_ns: u64, duration_ns: u64 = 0, finished: bool = false };
pub const Counter = struct { name: Name, value: f64 };

/// The last completed host frame; remains readable while the next frame is collected.
pub const Snapshot = struct {
    samples: [max_samples]Timing = undefined,
    sample_count: usize = 0,
    counters: [max_counters]Counter = undefined,
    counter_count: usize = 0,
    frame_duration_ns: u64 = 0,
};

/// Main-thread, allocation-free collector. Sample handles expire at the next frame.
pub const Profiling = struct {
    samples: [max_samples]Timing = undefined,
    sample_count: usize = 0,
    counters: [max_counters]Counter = undefined,
    counter_count: usize = 0,
    generation: u32 = 0,
    frame_start_ns: u64 = 0,
    frame_duration_ns: u64 = 0,
    last: Snapshot = .{},

    pub fn beginFrame(self: *Profiling, now_ns: u64) void {
        self.generation +%= 1;
        self.sample_count = 0;
        self.counter_count = 0;
        self.frame_start_ns = now_ns;
    }

    /// Complete host CPU frame timing; unfinished author samples are reported explicitly.
    pub fn finishFrame(self: *Profiling, now_ns: u64) !void {
        self.frame_duration_ns = now_ns -| self.frame_start_ns;
        self.last.sample_count = self.sample_count;
        self.last.counter_count = self.counter_count;
        self.last.frame_duration_ns = self.frame_duration_ns;
        @memcpy(self.last.samples[0..self.sample_count], self.samples[0..self.sample_count]);
        @memcpy(self.last.counters[0..self.counter_count], self.counters[0..self.counter_count]);
        for (self.samples[0..self.sample_count]) |sample| if (!sample.finished) return error.UnfinishedProfileSample;
    }

    pub fn begin(self: *Profiling, name: []const u8) !Sample {
        return self.beginAt(name, sdl.timer.getNanosecondsSinceInit());
    }

    fn beginAt(self: *Profiling, name: []const u8, now_ns: u64) !Sample {
        const copied = try Name.init(name);
        if (self.sample_count == max_samples) return error.ProfileCapacity;
        const index = self.sample_count;
        self.samples[index] = .{ .name = copied, .start_ns = now_ns };
        self.sample_count += 1;
        return @fromBackingInt(@intCast((@as(u64, self.generation) << 32) | index));
    }

    pub fn end(self: *Profiling, sample: Sample) !void {
        return self.endAt(sample, sdl.timer.getNanosecondsSinceInit());
    }

    fn endAt(self: *Profiling, sample: Sample, now_ns: u64) !void {
        const id = @backingInt(sample);
        const index: u32 = @truncate(id);
        if (id >> 32 != self.generation or index >= self.sample_count) return error.InvalidProfileSample;
        const timing = &self.samples[index];
        if (timing.finished or now_ns < timing.start_ns) return error.InvalidProfileSample;
        timing.duration_ns = now_ns - timing.start_ns;
        timing.finished = true;
    }

    /// Repeated names update this frame's value rather than accumulating duplicate counters.
    pub fn counter(self: *Profiling, name: []const u8, value: f64) !void {
        const copied = try Name.init(name);
        if (!std.math.isFinite(value)) return error.InvalidProfileValue;
        for (self.counters[0..self.counter_count]) |*existing| {
            if (std.mem.eql(u8, existing.name.text(), name)) {
                existing.value = value;
                return;
            }
        }
        if (self.counter_count == max_counters) return error.ProfileCapacity;
        self.counters[self.counter_count] = .{ .name = copied, .value = value };
        self.counter_count += 1;
    }
};

test "profile samples time nested work and reject expired or completed handles" {
    var profile = Profiling{};
    profile.beginFrame(10);
    const outer = try profile.beginAt("outer", 20);
    const inner = try profile.beginAt("inner", 30);
    try profile.endAt(inner, 40);
    try profile.endAt(outer, 60);
    try std.testing.expectEqual(@as(u64, 40), profile.samples[0].duration_ns);
    try std.testing.expectEqual(@as(u64, 10), profile.samples[1].duration_ns);
    try std.testing.expectError(error.InvalidProfileSample, profile.endAt(inner, 70));
    try profile.finishFrame(80);
    try std.testing.expectEqual(@as(u64, 70), profile.frame_duration_ns);
    profile.beginFrame(90);
    try std.testing.expectEqual(@as(usize, 2), profile.last.sample_count);
    try std.testing.expectEqual(@as(u64, 70), profile.last.frame_duration_ns);
    try std.testing.expectError(error.InvalidProfileSample, profile.endAt(outer, 100));
    _ = try profile.beginAt("forgotten", 100);
    try std.testing.expectError(error.UnfinishedProfileSample, profile.finishFrame(110));
}

test "profile counters copy names, update in place and reject invalid values" {
    var profile = Profiling{};
    var name = [_]u8{ 'A', 'I' };
    try profile.counter(&name, 2);
    name[0] = 'X';
    try profile.counter("AI", 4);
    try std.testing.expectEqual(@as(usize, 1), profile.counter_count);
    try std.testing.expectEqual(@as(f64, 4), profile.counters[0].value);
    try std.testing.expectEqualStrings("AI", profile.counters[0].name.text());
    try std.testing.expectError(error.InvalidProfileValue, profile.counter("bad", std.math.nan(f64)));
    try std.testing.expectError(error.InvalidProfileName, profile.beginAt("", 0));
}
