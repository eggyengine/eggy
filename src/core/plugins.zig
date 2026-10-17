//! Plugins: the game and everything that extends it. A plugin is a type with any of these hooks;
//! a hook it doesn't declare is skipped, and one without `init` starts as `.{}`.
//!
//!     pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Self
//!     pub fn deinit(self: *Self) void
//!     pub fn event(self: *Self, app: *eggy.App, event: eggy.Event) !void
//!     pub fn update(self: *Self, app: *eggy.App) !void  // in the editor, only while playing
//!     pub fn gameUi(self: *Self, app: *eggy.App, ui: *eggy.ui.Context) !void
//!     pub fn draw(self: *Self, app: *eggy.App, draw: eggy.DrawContext) !void
//!     pub fn uiEvent(self: *Self, app: *eggy.App, event: eggy.Event) !bool  // true consumes input
//!     pub fn editorUpdate(self: *Self, editor: *eggy.editor.Context) !void  // while not playing
//!     pub fn editorUi(self: *Self, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void
//!
//! A plugin can also add panels of its own to the editor's dock, each a page of UI it fills
//! every frame. Declare them, then draw panel `panel` (an index into the declaration):
//!
//!     pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .title = "Stats" }};
//!     pub fn editorPanelUi(self: *Self, panel: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void
//!
//! Commands declared in `editor_commands` appear in View and dispatch their local index:
//!
//!     pub const editor_commands = [_]eggy.plugins.EditorCommand{.{ .key = "raise", .title = "Raise" }};
//!     pub fn editorCommand(self: *Self, command: usize, editor: *eggy.editor.Context) !void
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
//! Eggy's own components (`builtin_components`: `Transform`, `Mesh`, which the scene draws, and
//! `Camera`, which the runtime looks through, and `SceneInstance`, a scene file made under an
//! entity) are listed first in every project, owned by `eggy`.
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
const EditorContext = @import("editor_api/editor_api.zig").Context;
const DrawContext = @import("game_ui/game_ui.zig").DrawContext;

/// The components every project has, before its plugins' own.
pub const builtin_components = .{ @import("transform.zig").Transform, @import("mesh.zig").Mesh, @import("camera.zig").Camera, @import("scene_instance.zig").SceneInstance };

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
    /// A stable local identity; set it to keep the layout when changing the title.
    key: [:0]const u8 = "",
    /// Its tab's label, and its window's title when popped out.
    title: [:0]const u8,
};

/// A command shown in the editor's View menu. Keys are local to the declaring plugin.
pub const EditorCommand = struct { key: [:0]const u8, title: [:0]const u8 };

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
        pub const has_game_ui = blk: {
            for (list) |T| if (@hasDecl(T, "gameUi")) break :blk true;
            break :blk false;
        };
        pub const has_draw = blk: {
            for (list) |T| if (@hasDecl(T, "draw")) break :blk true;
            break :blk false;
        };

        /// Every plugin's `editor_panels`, in plugin order.
        pub const editor_panels: []const EditorPanel = blk: {
            var all: []const EditorPanel = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "editor_panels")) {
                for (T.editor_panels) |panel| {
                    const local_key = if (panel.key.len != 0) panel.key else panel.title;
                    const identity = std.fmt.comptimePrint("{s}/{s}", .{ key, local_key });
                    for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate editor panel key");
                    all = all ++ .{EditorPanel{ .key = identity, .title = panel.title }};
                }
            };
            break :blk all;
        };

        /// Commands with stable published-plugin/key identities, independent of their labels.
        pub const editor_commands: []const EditorCommand = blk: {
            var all: []const EditorCommand = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "editor_commands")) {
                for (T.editor_commands) |command| {
                    if (command.key.len == 0) @compileError("editor command keys cannot be empty");
                    const identity = std.fmt.comptimePrint("{s}/{s}", .{ key, command.key });
                    for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate editor command key");
                    all = all ++ .{EditorCommand{ .key = identity, .title = command.title }};
                }
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

        /// Eggy's built-in components, then every component the plugins list (their
        /// `components`), in plugin order, each once, and what the editor does with them.
        pub const Components = blk: {
            var listed: []const type = &.{};
            var owners: []const [:0]const u8 = &.{};
            for (0..builtin_components.len) |i| {
                listed = listed ++ .{builtin_components[i]};
                owners = owners ++ .{"eggy"};
            }
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

        /// Default UI content in plugin order, after scene/custom drawing.
        pub fn gameUi(self: *Self, app: *App, context: *ui.Context) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "gameUi") and self.enabled[i]) try self.instances[i].gameUi(app, context);
        }

        /// Custom rendering outside a pass; the engine still owns frame submission.
        pub fn draw(self: *Self, app: *App, context: DrawContext) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "draw") and self.enabled[i]) try self.instances[i].draw(app, context);
        }

        /// Custom UI consumers are consulted in reverse visual order.
        pub fn uiEvent(self: *Self, app: *App, curr_event: Event) !bool {
            comptime var i = list.len;
            inline while (i > 0) {
                i -= 1;
                if (@hasDecl(list[i], "uiEvent") and self.enabled[i]) if (try self.instances[i].uiEvent(app, curr_event)) return true;
            }
            return false;
        }

        /// A frame in the editor while the game isn't playing: each plugin's `editorUpdate`.
        pub fn editorUpdate(self: *Self, editor: *EditorContext) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editorUpdate") and self.enabled[i]) try self.instances[i].editorUpdate(editor);
        }

        pub fn editorUi(self: *Self, editor: *EditorContext, context: *ui.Context) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editorUi") and self.enabled[i]) try self.instances[i].editorUi(editor, context);
        }

        /// Fill panel `panel` of `editor_panels` through the plugin that declared it.
        pub fn editorPanelUi(self: *Self, panel: usize, editor: *EditorContext, context: *ui.Context) !void {
            comptime var first: usize = 0;
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editor_panels")) {
                const count = T.editor_panels.len;
                if (panel >= first and panel < first + count) {
                    if (!self.enabled[i]) return context.muted("This plugin is turned off, in Preferences > Plugins.");
                    if (@hasDecl(T, "editorPanelUi")) try self.instances[i].editorPanelUi(panel - first, editor, context);
                    return;
                }
                first += count;
            };
        }

        /// Dispatch a current-generation command to its declaring plugin's local index.
        pub fn editorCommand(self: *Self, command: usize, editor: *EditorContext) !void {
            comptime var first: usize = 0;
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editor_commands")) {
                const count = T.editor_commands.len;
                if (command >= first and command < first + count) {
                    if (!self.enabled[i]) return error.PluginDisabled;
                    if (@hasDecl(T, "editorCommand")) return self.instances[i].editorCommand(command - first, editor);
                    return error.NoEditorCommandHook;
                }
                first += count;
            };
            return error.NoEditorCommand;
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

        test "editor command keys include their plugin and dispatch local indices" {
            const Game = struct {
                last: ?usize = null,
                pub const editor_commands = [_]EditorCommand{ .{ .key = "raise", .title = "Raise" }, .{ .key = "lower", .title = "Lower" } };
                pub fn editorCommand(self: *@This(), command: usize, _: *EditorContext) !void {
                    self.last = command;
                }
            };
            const Plugins = Set(.{Game}, &.{"game"});
            var plugins = try Plugins.init(std.testing.allocator, undefined, @splat(true));
            try std.testing.expectEqualStrings("game/lower", Plugins.editor_commands[1].key);
            try plugins.editorCommand(1, undefined);
            try std.testing.expectEqual(@as(?usize, 1), plugins.instances[0].last);
            try std.testing.expectError(error.NoEditorCommand, plugins.editorCommand(2, undefined));
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
        pub fn editorPanelUi(_: *@This(), panel: usize, _: *EditorContext, _: *ui.Context) !void {
            Log.drawn[Log.len] = 10 + panel;
            Log.len += 1;
        }
    };
    const Stats = struct {
        pub const editor_panels = [_]EditorPanel{ .{ .title = "Frames" }, .{ .title = "Memory" } };
        pub fn editorPanelUi(_: *@This(), panel: usize, _: *EditorContext, _: *ui.Context) !void {
            Log.drawn[Log.len] = 20 + panel;
            Log.len += 1;
        }
    };
    const Plugins = Set(.{ Game, struct {}, Stats }, &.{ "game", "empty", "stats" });
    try std.testing.expectEqual(@as(usize, 3), Plugins.editor_panels.len);
    try std.testing.expectEqualStrings("Memory", Plugins.editor_panels[2].title);
    var set = try Plugins.init(std.testing.allocator, undefined, @splat(true));
    for (0..3) |panel| try set.editorPanelUi(panel, undefined, undefined);
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

test "every project has Eggy's own components first" {
    const infos = Set(.{struct {}}, &.{"game"}).Components.infos;
    try std.testing.expectEqualStrings("Transform", infos[0].name);
    try std.testing.expectEqualStrings("Mesh", infos[1].name);
    try std.testing.expectEqualStrings("eggy", infos[1].owner);
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
    const infos = Set(.{ Game, Combat }, &.{ "game", "combat" }).Components.infos[builtin_components.len..];
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expectEqualStrings("game", infos[0].owner);
    try std.testing.expectEqualStrings("combat", infos[1].owner);
}
