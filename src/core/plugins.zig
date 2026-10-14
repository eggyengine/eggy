//! Plugins: the game and everything that extends it. A plugin is a type with any of these hooks;
//! a hook it doesn't declare is skipped, and one without `init` starts as `.{}`.
//!
//!     pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Self
//!     pub fn deinit(self: *Self) void
//!     pub fn event(self: *Self, app: *eggy.App, event: eggy.Event) !void
//!     pub fn update(self: *Self, app: *eggy.App) !void
//!     pub fn editorUi(self: *Self, ui: *eggy.ui.Context) void  // in the editor only
//!
//! Plugins are stored by value and may move after `init`: keep no pointers to `self`, and use the
//! `app` each hook is given rather than storing it.
const std = @import("std");
const App = @import("app.zig").App;
const Event = @import("vitellus_sdl3").sdl.events.Event;
const ui = @import("weeoui");

/// One instance of each type in `types` (a tuple such as `.{ Game, Stats }`). Hooks run in list
/// order, so the game, listed first, sees each frame before its plugins; `deinit` runs in reverse.
pub fn Set(comptime types: anytype) type {
    const list: [types.len]type = types;
    return struct {
        instances: std.meta.Tuple(&list),

        const Self = @This();

        /// Start every plugin. If one fails, those already started are stopped again.
        pub fn init(gpa: std.mem.Allocator, app: *App) !Self {
            var self: Self = undefined;
            inline for (list, 0..) |T, i| {
                self.instances[i] = start(T, gpa, app) catch |err| {
                    self.deinitFirst(i);
                    return err;
                };
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.deinitFirst(list.len);
        }

        pub fn event(self: *Self, app: *App, curr_event: Event) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "event")) try self.instances[i].event(app, curr_event);
        }

        pub fn update(self: *Self, app: *App) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "update")) try self.instances[i].update(app);
        }

        pub fn editorUi(self: *Self, context: *ui.Context) void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editorUi")) self.instances[i].editorUi(context);
        }

        fn start(comptime T: type, gpa: std.mem.Allocator, app: *App) !T {
            return if (@hasDecl(T, "init")) T.init(gpa, app) else .{};
        }

        /// Stop the first `count` plugins, last started first.
        fn deinitFirst(self: *Self, comptime count: usize) void {
            comptime var i = count;
            inline while (i > 0) {
                i -= 1;
                if (@hasDecl(list[i], "deinit")) self.instances[i].deinit();
            }
        }
    };
}

test "plugins start in order, stop in reverse, and skip hooks they don't declare" {
    const Log = struct {
        var entries: [8]u8 = undefined;
        var len: usize = 0;
        fn add(entry: u8) void {
            entries[len] = entry;
            len += 1;
        }
    };
    const Game = struct {
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            Log.add('g');
            return .{};
        }
        pub fn update(_: *@This(), _: *App) !void {
            Log.add('u');
        }
        pub fn deinit(_: *@This()) void {
            Log.add('G');
        }
    };
    const Quiet = struct {}; // no hooks at all
    const Stats = struct {
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            Log.add('s');
            return .{};
        }
        pub fn deinit(_: *@This()) void {
            Log.add('S');
        }
    };

    var set = try Set(.{ Game, Quiet, Stats }).init(std.testing.allocator, undefined);
    try set.update(undefined);
    set.deinit();
    try std.testing.expectEqualStrings("gsuSG", Log.entries[0..Log.len]);
}

test "a plugin that fails to start stops the ones started before it" {
    const Log = struct {
        var stopped: u32 = 0;
    };
    const Started = struct {
        pub fn deinit(_: *@This()) void {
            Log.stopped += 1;
        }
    };
    const Failing = struct {
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            return error.NoAudioDevice;
        }
    };

    try std.testing.expectError(error.NoAudioDevice, Set(.{ Started, Failing, Started }).init(std.testing.allocator, undefined));
    try std.testing.expectEqual(@as(u32, 1), Log.stopped);
}
