//! Plugins: the game and everything that extends it. A plugin is a type with any of these hooks;
//! a hook it doesn't declare is skipped, and one without `init` starts as `.{}`.
//!
//!     pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Self
//!     pub fn deinit(self: *Self) void
//!     pub fn event(self: *Self, app: *eggy.App, event: eggy.Event) !void
//!     pub fn update(self: *Self, app: *eggy.App) !void  // in the editor, only while playing
//!     pub fn editorUpdate(self: *Self, app: *eggy.App) !void  // in the editor while not playing
//!     pub fn editorUi(self: *Self, ui: *eggy.ui.Context) void  // in the editor only
//!
//! A plugin can also add panels of its own to the editor's dock, each a page of UI it fills
//! every frame. Declare them, then draw panel `panel` (an index into the declaration):
//!
//!     pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .title = "Stats" }};
//!     pub fn editorPanelUi(self: *Self, panel: usize, ui: *eggy.ui.Context) void  // in the editor only
//!
//! A plugin can declare preferences, which people set in the editor's Preferences window, kept in
//! the project's `.eggy/` folder and baked into the runtime (see `preferences.zig`):
//!
//!     pub const Preferences = struct { volume: f32 = 0.8, show_gizmos: bool = true };
//!     // in any hook: app.preferences(Preferences).volume
//!
//! And it can list its ECS components, which the editor's Hierarchy and Inspector then show,
//! add and edit (see `components.zig`):
//!
//!     pub const components = .{ Spin, Health };
//!
//! A project can turn plugins off (not the game): one that is off doesn't start, and none of its
//! hooks run, but its preferences and components stay known, so scenes keep their values. The
//! project's `registry_file` says which are on; the editor writes it and the runtime has it baked
//! in.
//!
//! Plugins are stored by value and may move after `init`: keep no pointers to `self`, and use the
//! `app` each hook is given rather than storing it.
//!
//! In the editor, the game and its plugins run from a library that is swapped for a rebuilt one
//! when their code changes (`src/editor/hot_reload`): every `deinit` runs, the world is emptied,
//! and every `init` runs again. Errors from hooks stop the game there rather than the editor.
const std = @import("std");
const App = @import("app.zig").App;
const Event = @import("vitellus_sdl3").sdl.events.Event;
const ui = @import("weeoui");
const preferences = @import("preferences.zig");
const components = @import("components.zig");

/// Where a project lists its plugins, relative to the project: each one's key, whether it is on,
/// and the preferences it declares.
pub const registry_file = ".eggy/plugins.zon";

/// `registry_file`'s contents.
pub const Registry = struct {
    plugins: []const Entry = &.{},

    pub const Entry = struct {
        key: []const u8,
        on: bool = true,
        preferences: []const []const u8 = &.{},
    };
};

/// The keys of the plugins `source` (a `registry_file`) has off, in `arena`.
pub fn parseOff(arena: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    const registry = try std.zon.parse.fromSliceAlloc(Registry, arena, source, null, .{ .ignore_unknown_fields = true });
    var off: std.ArrayList([]const u8) = .empty;
    for (registry.plugins) |entry| if (!entry.on) try off.append(arena, entry.key);
    return off.items;
}

/// A panel a plugin adds to the editor's dock (see `editor_panels` above).
pub const EditorPanel = struct {
    /// Its tab's label, and its window's title when popped out.
    title: [:0]const u8,
};

/// One instance of each type in `types` (a tuple such as `.{ Game, Stats }`). Hooks run in list
/// order, so the game, listed first, sees each frame before its plugins; `deinit` runs in reverse.
/// `keys` names each one's preferences (see `preferences.Manifest`), in the same order.
pub fn Set(comptime types: anytype, comptime keys: []const [:0]const u8) type {
    const list: [types.len]type = types;
    if (keys.len != list.len) @compileError("one preference key per plugin");
    return struct {
        /// Each plugin, undefined while it is off.
        instances: std.meta.Tuple(&list),
        /// Which plugins are on, in list order.
        enabled: [list.len]bool,

        const Self = @This();

        /// Every plugin's `editor_panels`, in plugin order.
        pub const editor_panels: []const EditorPanel = blk: {
            var all: []const EditorPanel = &.{};
            for (list) |T| if (@hasDecl(T, "editor_panels")) {
                all = all ++ T.editor_panels;
            };
            break :blk all;
        };

        /// The preferences each plugin declares (its `Preferences`), in plugin order.
        pub const preference_manifests: []const preferences.Manifest = blk: {
            var all: []const preferences.Manifest = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "Preferences")) {
                all = all ++ .{preferences.manifest(T.Preferences, key)};
            };
            break :blk all;
        };

        /// Every component the plugins list (their `components`), in plugin order, each once, and
        /// what the editor does with them.
        pub const Components = blk: {
            var listed: []const type = &.{};
            var owners: []const [:0]const u8 = &.{};
            for (list, keys) |T, key| for (components.listedBy(T)) |C| {
                if (std.mem.indexOfScalar(type, listed, C) == null) {
                    listed = listed ++ .{C};
                    owners = owners ++ .{key};
                }
            };
            break :blk components.Registry(listed, owners);
        };

        /// Which plugins are on when those keyed in `off` aren't. The game (listed first) is
        /// always on.
        pub fn enabledExcept(off: []const []const u8) [list.len]bool {
            var enabled: [list.len]bool = @splat(true);
            for (keys[1..], enabled[1..]) |key, *on| {
                for (off) |off_key| if (std.mem.eql(u8, key, off_key)) {
                    on.* = false;
                };
            }
            return enabled;
        }

        /// Start every plugin that `enabled` has on. If one fails, those already started are
        /// stopped again.
        pub fn init(gpa: std.mem.Allocator, app: *App, enabled: [list.len]bool) !Self {
            // Their preferences first (even those off, which keep their values), so each `init`
            // can read them.
            inline for (list, keys) |T, key| if (@hasDecl(T, "Preferences")) try app.preference_values.register(T.Preferences, key);
            var self: Self = undefined;
            self.enabled = enabled;
            inline for (list, 0..) |T, i| if (enabled[i]) {
                self.instances[i] = start(T, gpa, app) catch |err| {
                    self.deinitFirst(i);
                    return err;
                };
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.deinitFirst(list.len);
        }

        pub fn event(self: *Self, app: *App, curr_event: Event) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "event") and self.enabled[i]) try self.instances[i].event(app, curr_event);
        }

        pub fn update(self: *Self, app: *App) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "update") and self.enabled[i]) try self.instances[i].update(app);
        }

        /// A frame in the editor while the game isn't playing: each plugin's `editorUpdate`.
        pub fn editorUpdate(self: *Self, app: *App) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editorUpdate") and self.enabled[i]) try self.instances[i].editorUpdate(app);
        }

        pub fn editorUi(self: *Self, context: *ui.Context) void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editorUi") and self.enabled[i]) self.instances[i].editorUi(context);
        }

        /// Fill panel `panel` of `editor_panels` through the plugin that declared it.
        pub fn editorPanelUi(self: *Self, panel: usize, context: *ui.Context) void {
            comptime var first: usize = 0;
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editor_panels")) {
                const count = T.editor_panels.len;
                if (panel >= first and panel < first + count) {
                    if (!self.enabled[i]) return context.muted("This plugin is turned off, in Preferences > Plugins.");
                    if (@hasDecl(T, "editorPanelUi")) self.instances[i].editorPanelUi(panel - first, context);
                    return;
                }
                first += count;
            };
        }

        fn start(comptime T: type, gpa: std.mem.Allocator, app: *App) !T {
            return if (@hasDecl(T, "init")) T.init(gpa, app) else .{};
        }

        /// Stop the first `count` plugins, last started first.
        fn deinitFirst(self: *Self, comptime count: usize) void {
            comptime var i = count;
            inline while (i > 0) {
                i -= 1;
                if (@hasDecl(list[i], "deinit") and self.enabled[i]) self.instances[i].deinit();
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

    var set = try Set(.{ Game, Quiet, Stats }, &.{ "game", "quiet", "stats" }).init(std.testing.allocator, undefined, @splat(true));
    try set.update(undefined);
    set.deinit();
    try std.testing.expectEqualStrings("gsuSG", Log.entries[0..Log.len]);
}

test "editor panels from every plugin are listed in order and reach the plugin that declared them" {
    const Log = struct {
        var drawn: [4]usize = undefined;
        var len: usize = 0;
    };
    const Game = struct {
        pub const editor_panels = [_]EditorPanel{.{ .title = "Level" }};
        pub fn editorPanelUi(_: *@This(), panel: usize, _: *ui.Context) void {
            Log.drawn[Log.len] = 10 + panel;
            Log.len += 1;
        }
    };
    const Stats = struct {
        pub const editor_panels = [_]EditorPanel{ .{ .title = "Frames" }, .{ .title = "Memory" } };
        pub fn editorPanelUi(_: *@This(), panel: usize, _: *ui.Context) void {
            Log.drawn[Log.len] = 20 + panel;
            Log.len += 1;
        }
    };
    const Plugins = Set(.{ Game, struct {}, Stats }, &.{ "game", "empty", "stats" });
    try std.testing.expectEqual(@as(usize, 3), Plugins.editor_panels.len);
    try std.testing.expectEqualStrings("Memory", Plugins.editor_panels[2].title);
    var set = try Plugins.init(std.testing.allocator, undefined, @splat(true));
    for (0..3) |panel| set.editorPanelUi(panel, undefined);
    try std.testing.expectEqualSlices(usize, &.{ 10, 20, 21 }, Log.drawn[0..Log.len]);
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

    try std.testing.expectError(error.NoAudioDevice, Set(.{ Started, Failing, Started }, &.{ "a", "b", "c" }).init(std.testing.allocator, undefined, @splat(true)));
    try std.testing.expectEqual(@as(u32, 1), Log.stopped);
}

test "a plugin that is off doesn't start or run, and the game can't be turned off" {
    const Log = struct {
        var started: u32 = 0;
    };
    const Game = struct {
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            Log.started += 1;
            return .{};
        }
    };
    const Broken = struct {
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            return error.ShouldNotStart;
        }
        pub fn update(_: *@This(), _: *App) !void {
            return error.ShouldNotRun;
        }
    };
    const Plugins = Set(.{ Game, Broken }, &.{ "game", "broken" });
    const enabled = Plugins.enabledExcept(&.{ "game", "broken" });
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &enabled);
    var set = try Plugins.init(std.testing.allocator, undefined, enabled);
    defer set.deinit();
    try set.update(undefined);
    try std.testing.expectEqual(@as(u32, 1), Log.started);
}

test "the registry says which plugins are off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const off = try parseOff(arena.allocator(),
        \\.{ .plugins = .{
        \\    .{ .key = "game", .preferences = .{"volume"} },
        \\    .{ .key = "stats", .on = false },
        \\} }
    );
    try std.testing.expectEqual(@as(usize, 1), off.len);
    try std.testing.expectEqualStrings("stats", off[0]);
}

test "plugins' preferences are listed under their keys" {
    const Game = struct {
        pub const Preferences = struct { volume: f32 = 0.8 };
    };
    const manifests = Set(.{ Game, struct {} }, &.{ "game", "empty" }).preference_manifests;
    try std.testing.expectEqual(@as(usize, 1), manifests.len);
    try std.testing.expectEqualStrings("game", manifests[0].key);
    try std.testing.expectEqualStrings("volume", manifests[0].fields[0].name);
}

test "plugins' components are listed once each, under the plugin that lists them first" {
    const Spin = struct { speed: f32 = 1 };
    const Health = struct { points: u32 = 100 };
    const Game = struct {
        pub const components = .{Spin};
    };
    const Combat = struct {
        pub const components = .{ Health, Spin };
    };
    const infos = Set(.{ Game, Combat }, &.{ "game", "combat" }).Components.infos;
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expectEqualStrings("game", infos[0].owner);
    try std.testing.expectEqualStrings("combat", infos[1].owner);
}
