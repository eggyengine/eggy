//! What the Discord status says the person is doing in the editor: its two lines, made from the
//! project, the open scene and whether the game is playing.
const std = @import("std");

/// Discord cuts each line at 128 bytes.
pub const max_line_bytes = 128;

pub const Play = enum { editing, playing, paused };

/// The status's two lines: `details` on top, `state` below. Owns its text.
pub const Activity = struct {
    details_buffer: [max_line_bytes]u8 = undefined,
    details_len: usize = 0,
    state_buffer: [max_line_bytes]u8 = undefined,
    state_len: usize = 0,

    pub fn details(self: *const Activity) []const u8 {
        return self.details_buffer[0..self.details_len];
    }

    pub fn state(self: *const Activity) []const u8 {
        return self.state_buffer[0..self.state_len];
    }

    pub fn eql(a: *const Activity, b: *const Activity) bool {
        return std.mem.eql(u8, a.details(), b.details()) and std.mem.eql(u8, a.state(), b.state());
    }
};

/// The status for `project` (its title) with `scene_path` open (empty for none, or to keep it
/// private), as `play` is.
pub fn describe(project: []const u8, scene_path: []const u8, play: Play) Activity {
    var out: Activity = .{};
    const verb = switch (play) {
        .editing => "Editing",
        .playing => "Playtesting",
        .paused => "Paused in",
    };
    out.details_len = fit(&out.details_buffer, "{s} {s}", .{ verb, project });
    const scene = sceneName(scene_path);
    out.state_len = if (scene.len == 0) 0 else fit(&out.state_buffer, "Scene: {s}", .{scene});
    return out;
}

/// A scene file's name without its folders and `.scene.zon`: `garden` for
/// `resources/scene/garden.scene.zon`.
pub fn sceneName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const suffix = ".scene.zon";
    return if (std.mem.endsWith(u8, base, suffix)) base[0 .. base.len - suffix.len] else base;
}

/// Format into `buffer`, cutting what doesn't fit; returns the length written.
fn fit(buffer: []u8, comptime format: []const u8, args: anytype) usize {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print(format, args) catch {};
    return writer.end;
}

test "the status names the project and the open scene" {
    const editing = describe("testing project", "resources/scene/garden.scene.zon", .editing);
    try std.testing.expectEqualStrings("Editing testing project", editing.details());
    try std.testing.expectEqualStrings("Scene: garden", editing.state());
    try std.testing.expectEqualStrings("Playtesting testing project", describe("testing project", "", .playing).details());
    try std.testing.expectEqualStrings("", describe("testing project", "", .paused).state());
}

test "a long title is cut at Discord's limit" {
    const long: [300]u8 = @splat('x');
    const cut = describe(&long, "", .editing);
    try std.testing.expectEqual(@as(usize, max_line_bytes), cut.details().len);
}

test "the same lines are equal, so an unchanged status isn't sent again" {
    const a = describe("p", "a.scene.zon", .editing);
    const b = describe("p", "a.scene.zon", .editing);
    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&describe("p", "a.scene.zon", .paused)));
}
