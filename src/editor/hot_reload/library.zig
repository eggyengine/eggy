//! The root of a game's library: the game and its plugins (`eggy_project`), which the editor
//! loads, and swaps for a rebuilt one when their code changes, through `game_api.Game`. `addGame`
//! builds it for the editor only; the runtime compiles the game in.
const std = @import("std");
const eggy = @import("eggy");
const project = @import("eggy_project");
const api = @import("game_api.zig");

const Plugins = eggy.plugins.Set(project.plugins);

/// The library's own log goes to the editor's Console.
pub const std_options: std.Options = .{ .logFn = logThroughEditor };

/// The editor's side, from `start`; null before it.
var host: ?*const api.Host = null;

const State = struct {
    gpa: std.mem.Allocator,
    plugins: Plugins,
};

const panels = blk: {
    var list: [Plugins.editor_panels.len]api.Panel = undefined;
    for (&list, Plugins.editor_panels) |*panel, editor_panel| panel.* = .{ .title = editor_panel.title.ptr };
    break :blk list;
};

const game = api.Game{
    .start = start,
    .stop = stop,
    .update = update,
    .event = event,
    .editor_ui = editorUi,
    .editor_panel_ui = editorPanelUi,
    .panels = &panels,
    .panel_count = panels.len,
};

export fn eggy_game() callconv(.c) *const api.Game {
    return &game;
}

fn start(editor: *const api.Host, gpa_ptr: *const anyopaque, app_ptr: *anyopaque) callconv(.c) ?*anyopaque {
    host = editor;
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(gpa_ptr));
    const state = gpa.create(State) catch return null;
    const plugins = Plugins.init(gpa.*, appOf(app_ptr)) catch |err| {
        std.log.err("the game failed to start: {t}", .{err});
        gpa.destroy(state);
        return null;
    };
    state.* = .{ .gpa = gpa.*, .plugins = plugins };
    return state;
}

fn stop(state_ptr: *anyopaque) callconv(.c) void {
    const state = stateOf(state_ptr);
    state.plugins.deinit();
    state.gpa.destroy(state);
}

fn update(state_ptr: *anyopaque, app_ptr: *anyopaque) callconv(.c) bool {
    stateOf(state_ptr).plugins.update(appOf(app_ptr)) catch |err| {
        std.log.err("the game's update failed: {t}", .{err});
        return false;
    };
    return true;
}

fn event(state_ptr: *anyopaque, app_ptr: *anyopaque, event_ptr: *const anyopaque) callconv(.c) bool {
    const curr_event: *const eggy.Event = @ptrCast(@alignCast(event_ptr));
    stateOf(state_ptr).plugins.event(appOf(app_ptr), curr_event.*) catch |err| {
        std.log.err("the game's event hook failed: {t}", .{err});
        return false;
    };
    return true;
}

fn editorUi(state_ptr: *anyopaque, context: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorUi(@ptrCast(@alignCast(context)));
}

fn editorPanelUi(state_ptr: *anyopaque, panel: usize, context: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorPanelUi(panel, @ptrCast(@alignCast(context)));
}

fn stateOf(ptr: *anyopaque) *State {
    return @ptrCast(@alignCast(ptr));
}

fn appOf(ptr: *anyopaque) *eggy.App {
    return @ptrCast(@alignCast(ptr));
}

fn logThroughEditor(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const editor = host orelse return std.log.defaultLog(level, scope, format, args);
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    const scope_name = @tagName(scope);
    editor.log(@intFromEnum(level), scope_name.ptr, scope_name.len, text.ptr, text.len);
}
