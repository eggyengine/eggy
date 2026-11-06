//! What the status carries across the editor restarting plugins (Play, Stop, a rebuilt game
//! library): that this is the editor, when it opened, and the project and scene last seen. It
//! lives in the process's environment, which outlives the library a rebuild swaps.
const std = @import("std");
const eggy = @import("eggy");
const c = eggy.sdl_adapter.sdl.c;

const editor_variable = "EGGY_DISCORD_IN_EDITOR";
const since_variable = "EGGY_DISCORD_SINCE";
const title_variable = "EGGY_DISCORD_TITLE";
const scene_variable = "EGGY_DISCORD_SCENE";

/// Whether an editor frame has run in this process; the runtime never marks it.
pub fn inEditor() bool {
    return get(editor_variable) != null;
}

pub fn markEditor() void {
    set(editor_variable, "1");
}

/// When the editor first showed a status, in Unix seconds: Discord counts the time since.
pub fn since(io: std.Io) i64 {
    if (get(since_variable)) |text| if (std.fmt.parseInt(i64, text, 10)) |seconds| return seconds else |_| {};
    const now_s = std.Io.Clock.real.now(io).toSeconds();
    var buffer: [24]u8 = undefined;
    set(since_variable, std.fmt.bufPrintSentinel(&buffer, "{d}", .{now_s}, 0) catch unreachable);
    return now_s;
}

/// Keep the project's title and the open scene for while the game plays.
pub fn remember(title: []const u8, scene: []const u8) void {
    var buffer: [512]u8 = undefined;
    set(title_variable, std.fmt.bufPrintSentinel(&buffer, "{s}", .{title[0..@min(title.len, 256)]}, 0) catch unreachable);
    set(scene_variable, std.fmt.bufPrintSentinel(&buffer, "{s}", .{scene[0..@min(scene.len, 256)]}, 0) catch unreachable);
}

pub const Remembered = struct { title: []const u8, scene: []const u8 };

/// What `remember` kept, copied into the buffers given (cut to fit).
pub fn recall(title_buffer: []u8, scene_buffer: []u8) Remembered {
    return .{ .title = copy(title_buffer, get(title_variable) orelse ""), .scene = copy(scene_buffer, get(scene_variable) orelse "") };
}

fn copy(buffer: []u8, text: []const u8) []const u8 {
    const len = @min(buffer.len, text.len);
    @memcpy(buffer[0..len], text[0..len]);
    return buffer[0..len];
}

fn get(name: [:0]const u8) ?[]const u8 {
    const environment = c.SDL_GetEnvironment() orelse return null;
    const value = c.SDL_GetEnvironmentVariable(environment, name) orelse return null;
    return std.mem.span(value);
}

fn set(name: [:0]const u8, value: [:0]const u8) void {
    const environment = c.SDL_GetEnvironment() orelse return;
    _ = c.SDL_SetEnvironmentVariable(environment, name, value, true);
}

test "the title and scene come back as remembered, cut to the buffers" {
    remember("testing project", "resources/scene/garden.scene.zon");
    var title: [7]u8 = undefined;
    var scene: [64]u8 = undefined;
    const back = recall(&title, &scene);
    try std.testing.expectEqualStrings("testing", back.title);
    try std.testing.expectEqualStrings("resources/scene/garden.scene.zon", back.scene);
}
