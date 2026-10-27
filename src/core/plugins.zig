//! Plugins: the game and everything that extends it. A plugin is a type with any of these hooks;
//! a hook it doesn't declare is skipped, and one without `init` starts as `.{}`.
//!
//!     pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Self
//!     pub fn deinit(self: *Self) void
//!     pub fn event(self: *Self, app: *eggy.App, event: eggy.Event) !void
//!     pub fn update(self: *Self, app: *eggy.App) !void  // in the editor, playing and not paused
//!     pub fn gameUi(self: *Self, app: *eggy.App, ui: *eggy.ui.Context) !void
//!     pub fn draw(self: *Self, app: *eggy.App, draw: eggy.DrawContext) !void
//!     pub fn uiEvent(self: *Self, app: *eggy.App, event: eggy.Event) !bool  // true consumes input
//!     pub fn editorUpdate(self: *Self, editor: *eggy.editor.Context) !void  // editing or paused
//!     pub fn editorUi(self: *Self, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void  // project Inspector
//!
//! These signatures apply equally to `Game` and `Plugin`; hooks belong inside that type,
//! not beside it in the module. `init` constructs each instance; editor restarts/reloads can
//! construct it again. Most hooks run game-first; `deinit` and `uiEvent` run in reverse order.
//! See `docs/docs/reference/plugin-hooks.md` for the hook reference and lifecycle.
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
//! Plugins can extend the top menu bar and the bottom status bar. A menu with `extends` adds its
//! rows to one of Eggy's menus (File, Edit, View, Window or Help); without it, it is a menu of
//! its own. A status item with no `items` is a button; with `items`, it opens a menu upward.
//! Entries are identified by `<plugin>/<key>`, never by index, and the editor reads them afresh
//! from the library on every reload, so nothing stale outlives a swap. A turned-off plugin's
//! entries show greyed out and do nothing:
//!
//!     pub const editor_menus = [_]eggy.plugins.EditorMenu{.{
//!         .key = "tools", .title = "Tools", .items = &.{.{ .key = "bake", .title = "Bake Lights" }},
//!     }};
//!     pub const editor_status_items = [_]eggy.plugins.EditorStatusItem{.{ .key = "fps", .title = "FPS", .side = .right }};
//!     pub fn editorBarAction(self: *Self, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) !void
//!     pub fn editorBarState(self: *Self, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context, state: *eggy.plugins.EditorBarState) !void
//!
//! `editorBarAction` runs when a row or button is pressed; `editorBarState` is optional and says
//! whether an entry is enabled or checked, and gives a status item its text. Both name an entry
//! by its place in the plugin's own declaration.
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
//! Named input maps register before `init`, under the published plugin key and map key:
//!
//!     pub const input_maps = .{PlayerInput}; // an eggy.input.Map or FileMap
//!     // in a hook: try app.input.map(PlayerInput).pressed(.jump)
//!
//! File templates extend both Assets > New menus without a creation hook:
//!
//!     pub const editor_file_types = [_]eggy.plugins.EditorFileType{.{
//!         .key = "material", .title = "Material", .extension = ".material.zon", .contents = ".{}\n",
//!     }};
//!
//! And platforms for File > Export, beside Eggy's own, with the settings each shows there and the
//! `zig build export` arguments it adds. Both hooks see every platform, so a plugin can also add
//! settings to Eggy's (`platform.builtin`) or another plugin's:
//!
//!     pub const export_platforms = [_]eggy.plugins.ExportPlatform{.{
//!         .key = "pi", .title = "Raspberry Pi", .target = "aarch64-linux-gnu",
//!     }};
//!     pub fn exportUi(self: *Self, platform: eggy.plugins.ExportTarget, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void
//!     pub fn exportArgs(self: *Self, platform: eggy.plugins.ExportTarget, args: *eggy.plugins.ExportArgs) !void
//!
//! Widgets of its own for UI scenes (`.ui.zon`): the UI Designer offers each in its palette, and
//! a node showing one asks the plugin to draw it in its box, with the node's `value` text to
//! read as it likes. Widgets are named `<plugin>/<key>` in files:
//!
//!     pub const ui_widgets = [_]eggy.plugins.UiWidget{.{ .key = "minimap", .title = "Minimap" }};
//!     pub fn uiWidget(self: *Self, widget: usize, draw: eggy.plugins.UiWidgetDraw) !void
//!
//! Eggy's own components (`builtin_components`: `Transform`, `Mesh`, which the scene draws, and
//! `Camera`, which the runtime looks through, and `SceneInstance`, a scene file made under an
//! entity, `Animator`, which plays clips, `AudioSource` and `AudioListener`, which play sound, and `Sprite`, an image drawn flat)
//! are listed first in every project, owned by `eggy`.
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
//! and every `init` runs again. The editor logs hook failures and keeps running; standalone
//! uncaught hook errors are fatal.
const std = @import("std");
const zon_file = @import("eggy_assets").zon;
const App = @import("app.zig").App;
const Event = @import("vitellus_sdl3").sdl.events.Event;
const ui = @import("weeoui");
const preferences = @import("preferences.zig");
const components = @import("components.zig");
const EditorContext = @import("editor_api/editor_api.zig").Context;
const DrawContext = @import("game_ui/game_ui.zig").DrawContext;
const ui_scenes = @import("ui_scenes/ui_scenes.zig");

/// The components every project has, before its plugins' own.
pub const builtin_components = .{ @import("transform.zig").Transform, @import("mesh.zig").Mesh, @import("camera.zig").Camera, @import("scene_instance.zig").SceneInstance, @import("material.zig").Material, @import("lighting.zig").SceneLight, @import("lighting.zig").Environment, @import("animation.zig").Animator, ui_scenes.UiScreen, ui_scenes.UiBillboard, @import("audio/audio.zig").AudioSource, @import("audio/audio.zig").AudioListener, @import("sprite.zig").Sprite };

/// Eggy's own platforms in File > Export, in the order it lists them.
/// Android comes from the Android plugin (`plugins/android/`), as a platform of its own.
pub const BuiltinPlatform = enum(u8) { windows, macos, linux, web };

/// A platform a plugin adds to File > Export (see `export_platforms` above). Its identity is
/// scoped to the published plugin.
pub const ExportPlatform = struct {
    key: [:0]const u8,
    title: [:0]const u8,
    /// The `-Dtarget` it builds for, such as "aarch64-linux-gnu".
    target: [:0]const u8,
    /// A line under its title on what it builds and needs.
    note: [:0]const u8 = "",
    /// Its icon in the platform list: PNG bytes, 48 pixels square, drawn as they are. Empty for a
    /// generic package icon.
    icon_png: []const u8 = "",
    /// Whether its export is a folder File > Export can also zip; false for one that is a single
    /// file already, such as an installer or an APK.
    zips: bool = true,
};

/// The platform File > Export shows or exports for, as `exportUi` and `exportArgs` see it.
pub const ExportTarget = struct {
    /// Eggy's own platform, or null for one a plugin declared.
    builtin: ?BuiltinPlatform,
    /// Its index in this plugin's `export_platforms`, when this plugin declared it.
    own: ?usize,
    /// The `-Dtarget` it builds for, with the architecture chosen. Borrowed for the hook.
    target: []const u8,
};

/// The arguments `exportArgs` adds to `zig build export`, such as `-Dsteam=true` for an option
/// the game's build declares. Allocates in the hook's arena; nothing is freed separately.
pub const ExportArgs = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,
    /// The `-Dtarget` to build for instead of the platform's own, set by `buildFor`.
    target: ?[]const u8 = null,

    /// Add a copy of `arg`. Allocation failure propagates.
    ///
    /// ```zig
    /// try args.add("-Dsteam=true"); // Inside an exportArgs hook.
    /// ```
    pub fn add(self: *ExportArgs, arg: []const u8) !void {
        try self.list.append(self.arena, try self.arena.dupe(u8, arg));
    }

    /// Build for `target` instead of the platform's own `target`: for a plugin's own platform
    /// whose target depends on what `exportUi` offers (an architecture, an OS version). Only
    /// the platform's own plugin should call it; the last call wins. Allocation failure
    /// propagates.
    ///
    /// ```zig
    /// try args.buildFor("aarch64-linux-android.33"); // Inside an exportArgs hook.
    /// ```
    pub fn buildFor(self: *ExportArgs, target: []const u8) !void {
        self.target = try self.arena.dupe(u8, target);
    }
};

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
/// Host-only: accepts sentinel-terminated ZON and ignores unknown registry fields.
/// Returned list/strings live in `arena`, including parse allocations on failure.
///
/// ```zig
/// var arena = std.heap.ArenaAllocator.init(gpa);
/// defer arena.deinit();
/// const off = try parseOff(arena.allocator(), ".{ .plugins = .{.{ .key = \"stats\", .on = false }} }");
/// ```
pub fn parseOff(arena: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    const registry = try zon_file.parse(Registry, arena, source, .{ .ignore_unknown_fields = true });
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

/// One of Eggy's own menus, which a plugin's `EditorMenu` can extend.
pub const BuiltinMenu = enum(u8) { file, edit, view, window, help };

/// A row in a plugin's menu, or in a menu hanging off a status bar item. Keys are local to the
/// menu, and in the Set's metadata they are the full `<plugin>/<menu>/<item>` identity.
pub const EditorMenuItem = struct {
    key: [:0]const u8,
    title: [:0]const u8,
    shortcut: [:0]const u8 = "",
    /// Shows a check mark, set by `editorBarState`.
    checkable: bool = false,
};

/// A menu a plugin adds to the editor's top bar, or, with `extends`, rows it appends to one of
/// Eggy's. In the Set's metadata the key is `<plugin>/<menu>`.
pub const EditorMenu = struct {
    key: [:0]const u8,
    title: [:0]const u8,
    extends: ?BuiltinMenu = null,
    items: []const EditorMenuItem,
};

pub const StatusSide = enum(u8) { left, right };

/// An entry on the editor's bottom status bar: a button, or, with `items`, a button that opens a
/// menu above it. Its label is `title` unless `editorBarState` supplies text. The Set's key is
/// `<plugin>/<key>`.
pub const EditorStatusItem = struct {
    key: [:0]const u8,
    title: [:0]const u8,
    side: StatusSide = .left,
    items: []const EditorMenuItem = &.{},
};

/// What the editor asks about a menu or status bar entry. Indices are into this plugin's own
/// `editor_menus` / `editor_status_items`, and into that entry's `items`.
pub const EditorBarTarget = union(enum) {
    menu_item: struct { menu: usize, item: usize },
    /// The status item's own button, pressed when it has no `items`.
    status: usize,
    status_item: struct { status: usize, item: usize },
};

/// How an `EditorBarTarget` shows right now; `editorBarState` fills it in. Fixed size so it
/// crosses the hot-reload boundary by value.
pub const EditorBarState = extern struct {
    enabled: bool = true,
    checked: bool = false,
    text_len: u8 = 0,
    text_bytes: [max_text]u8 = undefined,

    pub const max_text = 61;

    /// Replace the label with `label` (a status item's only), cut to fit on a character boundary.
    ///
    /// ```zig
    /// state.setText("60 fps"); // Inside editorBarState for a status item.
    /// ```
    pub fn setText(self: *EditorBarState, label: []const u8) void {
        var len = @min(label.len, max_text);
        // Never leave half a UTF-8 sequence.
        while (len > 0 and len < label.len and label[len] & 0xC0 == 0x80) len -= 1;
        @memcpy(self.text_bytes[0..len], label[0..len]);
        self.text_len = @intCast(len);
    }

    /// The label set, or "" to keep the declared title. Borrows this state.
    pub fn text(self: *const EditorBarState) []const u8 {
        return self.text_bytes[0..self.text_len];
    }
};

/// A file template offered by Assets > New. Its identity is scoped to the published plugin.
/// The editor creates a uniquely named file with these bytes and tracks it in undo history.
pub const EditorFileType = struct {
    key: [:0]const u8,
    title: [:0]const u8,
    extension: [:0]const u8,
    contents: []const u8 = "",
};

/// A widget a plugin adds to UI scenes. In the Set's metadata the key is `<plugin>/<key>`.
pub const UiWidget = struct {
    key: [:0]const u8,
    title: [:0]const u8,
};

/// What `uiWidget` draws: its node's box on `canvas` (in the canvas's units), the node's `value`
/// text, how many canvas units a design pixel is, and a steady clock for animating. Borrowed
/// for the call.
pub const UiWidgetDraw = struct {
    canvas: *ui.Canvas,
    rect: ui.Rect,
    value: []const u8,
    scale: f32,
    time_ms: u64,
};

/// `items` with each key made `<owner>/<key>`; rows need a title and a key unique in their menu.
fn identifiedItems(comptime owner: []const u8, comptime items: []const EditorMenuItem) []const EditorMenuItem {
    comptime {
        var all: []const EditorMenuItem = &.{};
        for (items) |item| {
            if (item.key.len == 0 or item.title.len == 0) @compileError("editor menu items need a key and title");
            const identity = std.fmt.comptimePrint("{s}/{s}", .{ owner, item.key });
            for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate editor menu item key");
            var copy = item;
            copy.key = identity;
            all = all ++ .{copy};
        }
        return all;
    }
}

/// One instance of each type in `types` (a tuple such as `.{ Game, Stats }`). Hooks run in list
/// order, so the game, listed first, sees each frame before its plugins; `deinit` and `uiEvent`
/// run in reverse.
/// `keys` names each one's preferences (see `preferences.Manifest`), in the same order.
/// Host-only: provide at least the game type and one stable published key per type.
/// Returned instances own their hook-created resources; deinitialize before unloading their
/// code. Instances may move, so hooks must not retain self/App pointers. Compile-time
/// metadata includes disabled plugins; runtime dispatch skips them.
///
/// ```zig
/// // Host with Game/Stats plugin types and a live app:
/// const Plugins = Set(.{ Game, Stats }, &.{ "game", "stats" });
/// var plugins = try Plugins.init(gpa, app, Plugins.enabledExcept(&.{}));
/// defer plugins.deinit();
/// ```
pub fn Set(comptime types: anytype, comptime keys: []const [:0]const u8) type {
    const list: [types.len]type = types;
    if (keys.len != list.len) @compileError("one preference key per plugin");
    return struct {
        /// Each plugin, undefined while it is off.
        instances: @Tuple(&list),
        /// Which plugins are on, in list order.
        enabled: [list.len]bool,

        const Self = @This();
        /// Host-only: whether any enabled plugin declares gameUi, without calling hooks.
        /// Use to avoid creating an unused overlay; disabled instances are never inspected.
        ///
        /// ```zig
        /// const needs_overlay = plugins.hasGameUi(); // An initialized plugin set.
        /// ```
        pub fn hasGameUi(self: *const Self) bool {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "gameUi") and self.enabled[i]) return true;
            return false;
        }
        /// Host-only: whether any enabled plugin declares custom draw, without executing it.
        ///
        /// ```zig
        /// const needs_custom_draw = plugins.hasDraw(); // An initialized plugin set.
        /// ```
        pub fn hasDraw(self: *const Self) bool {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "draw") and self.enabled[i]) return true;
            return false;
        }

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

        /// Menus plugins add to the top bar or extend, keyed `<plugin>/<menu>`, their items keyed
        /// `<plugin>/<menu>/<item>`. Disabled plugins stay listed; dispatch skips them.
        pub const editor_menus: []const EditorMenu = blk: {
            var all: []const EditorMenu = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "editor_menus")) {
                for (T.editor_menus) |menu| {
                    if (menu.key.len == 0 or menu.title.len == 0) @compileError("editor menus need a key and title");
                    const identity = std.fmt.comptimePrint("{s}/{s}", .{ key, menu.key });
                    for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate editor menu key");
                    all = all ++ .{EditorMenu{ .key = identity, .title = menu.title, .extends = menu.extends, .items = identifiedItems(identity, menu.items) }};
                }
            };
            break :blk all;
        };

        /// Status bar entries, keyed `<plugin>/<key>`, their menu rows `<plugin>/<key>/<item>`.
        pub const editor_status_items: []const EditorStatusItem = blk: {
            var all: []const EditorStatusItem = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "editor_status_items")) {
                for (T.editor_status_items) |status| {
                    if (status.key.len == 0 or status.title.len == 0) @compileError("editor status items need a key and title");
                    const identity = std.fmt.comptimePrint("{s}/{s}", .{ key, status.key });
                    for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate editor status item key");
                    all = all ++ .{EditorStatusItem{ .key = identity, .title = status.title, .side = status.side, .items = identifiedItems(identity, status.items) }};
                }
            };
            break :blk all;
        };

        /// File templates copied by the editor before a game library can be unloaded.
        /// Every plugin's `ui_widgets`, keys made `<plugin>/<key>`, in plugin order.
        pub const ui_widgets: []const UiWidget = blk: {
            var all: []const UiWidget = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "ui_widgets")) {
                if (!@hasDecl(T, "uiWidget")) @compileError("a plugin with ui_widgets needs a uiWidget hook");
                for (T.ui_widgets) |widget| {
                    if (widget.key.len == 0 or widget.title.len == 0 or std.mem.indexOfScalar(u8, widget.key, '/') != null) @compileError("UI widgets need a title and a key without /");
                    const identity = std.fmt.comptimePrint("{s}/{s}", .{ key, widget.key });
                    for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate UI widget key");
                    all = all ++ .{UiWidget{ .key = identity, .title = widget.title }};
                }
            };
            break :blk all;
        };

        pub const editor_file_types: []const EditorFileType = blk: {
            var all: []const EditorFileType = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "editor_file_types")) {
                for (T.editor_file_types) |file_type| {
                    if (file_type.key.len == 0 or file_type.title.len == 0 or
                        file_type.extension.len < 2 or file_type.extension[0] != '.' or
                        std.mem.indexOfScalar(u8, file_type.key, 0) != null or
                        std.mem.indexOfScalar(u8, file_type.title, 0) != null or
                        std.mem.indexOfScalar(u8, file_type.extension, 0) != null or
                        std.mem.indexOfAny(u8, file_type.title, "/\\") != null or
                        std.mem.indexOfAny(u8, file_type.extension, "/\\") != null)
                        @compileError("editor file types need a key, title and path-free .extension");
                    const identity = std.fmt.comptimePrint("{s}/{s}", .{ key, file_type.key });
                    for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate editor file type key");
                    all = all ++ .{EditorFileType{ .key = identity, .title = file_type.title, .extension = file_type.extension, .contents = file_type.contents }};
                }
            };
            break :blk all;
        };

        /// Every plugin's `export_platforms`, in plugin order, with published-plugin/key identities.
        pub const export_platforms: []const ExportPlatform = blk: {
            var all: []const ExportPlatform = &.{};
            for (list, keys) |T, key| if (@hasDecl(T, "export_platforms")) {
                for (T.export_platforms) |platform| {
                    if (platform.key.len == 0 or platform.title.len == 0 or platform.target.len == 0)
                        @compileError("export platforms need a key, title and target");
                    const identity = std.fmt.comptimePrint("{s}/{s}", .{ key, platform.key });
                    for (all) |previous| if (std.mem.eql(u8, previous.key, identity)) @compileError("duplicate export platform key");
                    var copy = platform;
                    copy.key = identity;
                    all = all ++ .{copy};
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
        /// Host-only: unknown keys are ignored; returned flags are values with no ownership.
        ///
        /// ```zig
        /// const enabled = Plugins.enabledExcept(&.{"stats"}); // Plugins is a Set type.
        /// ```
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
        /// Host-only: registers preferences (including disabled plugins) and enabled input
        /// maps before init hooks, then constructs enabled instances in order. `app` is
        /// borrowed only during each hook; returned instances may move. Hook resources
        /// belong to the set until deinit. Registration side effects are not rolled back
        /// on failure; the host owns resetting run-local registrations before a fresh start.
        ///
        /// ```zig
        /// var plugins = try Plugins.init(gpa, app, Plugins.enabledExcept(&.{}));
        /// defer plugins.deinit(); // Before unloading the game library or destroying app.
        /// ```
        pub fn init(gpa: std.mem.Allocator, app: *App, enabled: [list.len]bool) !Self {
            // Their preferences first (even those off, which keep their values), so each `init`
            // can read them.
            inline for (list, keys) |T, key| if (@hasDecl(T, "Preferences")) try app.preference_values.register(T.Preferences, key);
            inline for (list, keys, 0..) |T, key, i| if (enabled[i] and @hasDecl(T, "input_maps")) {
                inline for (T.input_maps) |Mapping| {
                    const owner = comptime std.fmt.comptimePrint("{s}/{s}", .{ key, Mapping.key });
                    if (@hasDecl(Mapping, "file")) {
                        try registerFileMap(Mapping, gpa, app, owner);
                    } else try app.input.registerMap(Mapping, owner);
                }
            };

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

        /// Host-only: run enabled deinit hooks in reverse order, freeing hook-owned resources.
        /// Call once on a successfully initialized set while its code is still loaded.
        /// Does not clear host preference/input registrations or make the set reusable.
        ///
        /// ```zig
        /// var plugins = try Plugins.init(gpa, app, Plugins.enabledExcept(&.{}));
        /// defer plugins.deinit();
        /// ```
        pub fn deinit(self: *Self) void {
            self.deinitFirst(list.len);
        }

        /// Host-only: dispatch an SDL event to enabled event hooks in game-first order.
        /// Borrows app/event for the calls; hook side effects remain if a hook errors,
        /// and later hooks are skipped. Input capture/gating is the host's responsibility.
        ///
        /// ```zig
        /// try plugins.event(app, event); // Host with the current SDL event.
        /// ```
        pub fn event(self: *Self, app: *App, curr_event: Event) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "event") and self.enabled[i]) try self.instances[i].event(app, curr_event);
        }

        /// Host-only: invoke enabled gameplay update hooks in game-first order.
        /// Call only when gameplay should advance; this method does not check pause/play
        /// state. First hook failure propagates and skips subsequent hooks.
        ///
        /// ```zig
        /// try plugins.update(app); // Host's active gameplay frame.
        /// ```
        pub fn update(self: *Self, app: *App) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "update") and self.enabled[i]) try self.instances[i].update(app);
        }

        /// Default UI content in plugin order, after scene/custom drawing.
        /// Host-only: context must be in its widget-building frame. Hooks borrow it only
        /// for this call; first failure skips later hooks and leaves earlier UI declarations.
        ///
        /// ```zig
        /// // Host after overlay.begin, before overlay.render:
        /// try plugins.gameUi(app, &overlay.context);
        /// ```
        pub fn gameUi(self: *Self, app: *App, context: *ui.Context) !void {
            try ui_scenes.buildScreens(&app.ui_scenes, app.resources(), context, app.ui_layer, context.time_ms);
            inline for (list, 0..) |T, i| if (@hasDecl(T, "gameUi") and self.enabled[i]) try self.instances[i].gameUi(app, context);
        }

        /// Find this frame's UI screens and billboards in `app`'s world, drawing plugins'
        /// widgets with this set. Host-only, once per frame before drawing; the set must stay
        /// where it is until the world resets.
        ///
        /// ```zig
        /// plugins.gatherUiScenes(app);
        /// if (plugins.hasGameUi() or app.ui_scenes.screen_count != 0) try plugins.gameUi(app, &layer.context);
        /// ```
        pub fn gatherUiScenes(self: *Self, app: *App) void {
            ui_scenes.gatherInto(&app.world, &app.ui_scenes, .{ .context = self, .paint = paintUiWidget });
        }

        // Dispatch a UI scene's plugin widget to the plugin that declares it; false for none, or
        // when its hook failed (logged once).
        fn paintUiWidget(context: ?*anyopaque, request: *const ui_scenes.WidgetRequest) callconv(.c) bool {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const Reported = struct {
                var failed = false;
            };
            inline for (list, keys, 0..) |T, key, i| if (comptime @hasDecl(T, "ui_widgets")) {
                inline for (T.ui_widgets, 0..) |widget, w| {
                    if (std.mem.eql(u8, request.key(), key ++ "/" ++ widget.key)) {
                        if (!self.enabled[i]) return false;
                        self.instances[i].uiWidget(w, .{ .canvas = request.canvas, .rect = request.area(), .value = request.value(), .scale = request.scale, .time_ms = request.time_ms }) catch |err| {
                            if (!Reported.failed) std.log.err("UI widget {s} failed: {t}", .{ request.key(), err });
                            Reported.failed = true;
                            return false;
                        };
                        return true;
                    }
                }
            };
            return false;
        }

        /// Custom rendering outside a pass; the engine still owns frame submission.
        /// Host-only: pass the current engine-owned draw context. Each hook must finish
        /// outside a pass with the target in color-attachment state; never retain it.
        /// First hook error propagates without undoing already recorded commands.
        ///
        /// ```zig
        /// try plugins.draw(app, draw_context); // Host, outside any render pass.
        /// ```
        pub fn draw(self: *Self, app: *App, context: DrawContext) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "draw") and self.enabled[i]) try self.instances[i].draw(app, context);
        }

        /// Custom UI consumers are consulted in reverse visual order.
        /// Host-only: stops at the first true result or error. True means the host must
        /// withhold gameplay input; this dispatcher does not mutate App.input itself.
        ///
        /// ```zig
        /// const consumed = try plugins.uiEvent(app, event);
        /// ```
        pub fn uiEvent(self: *Self, app: *App, curr_event: Event) !bool {
            comptime var i = list.len;
            inline while (i > 0) {
                i -= 1;
                if (@hasDecl(list[i], "uiEvent") and self.enabled[i]) if (try self.instances[i].uiEvent(app, curr_event)) return true;
            }
            return false;
        }

        /// A frame in the editor while editing or paused: each plugin's `editorUpdate`.
        /// Host-only: caller enforces play state and supplies a hook-local editor context.
        /// Dispatches game-first; the first failure propagates and skips later hooks.
        ///
        /// ```zig
        /// try plugins.editorUpdate(&editor_context); // Host's editing/paused frame.
        /// ```
        pub fn editorUpdate(self: *Self, editor: *EditorContext) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editorUpdate") and self.enabled[i]) try self.instances[i].editorUpdate(editor);
        }

        /// Host-only: build the project Inspector UI through enabled editorUi hooks, game-first.
        /// Both contexts are borrowed for this call and UI must be in its building frame.
        /// First hook failure propagates without undoing earlier declarations.
        ///
        /// ```zig
        /// try plugins.editorUi(&editor_context, ui_context); // Host building Inspector.
        /// ```
        pub fn editorUi(self: *Self, editor: *EditorContext, context: *ui.Context) !void {
            inline for (list, 0..) |T, i| if (@hasDecl(T, "editorUi") and self.enabled[i]) try self.instances[i].editorUi(editor, context);
        }

        /// Fill panel `panel` of `editor_panels` through the plugin that declared it.
        /// Host-only: index is global within this Set's current metadata, converted to a
        /// plugin-local index. Disabled panels draw an explanation; missing hooks/out-of-range
        /// indices do nothing. Contexts are hook-local; UI/hook errors propagate.
        ///
        /// ```zig
        /// // Host building a panel from this generation's editor_panels list:
        /// try plugins.editorPanelUi(panel_index, &editor_context, ui_context);
        /// ```
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
        /// Host-only: `command` indexes this Set's flattened editor_commands, not a stable
        /// persisted ID. Returns PluginDisabled/NoEditorCommandHook/NoEditorCommand as needed,
        /// or propagates the hook's failure; context must not escape the call.
        ///
        /// ```zig
        /// try plugins.editorCommand(command_index, &editor_context); // Host menu dispatch.
        /// ```
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

        /// Run a menu row or status bar entry on the plugin that declared it. Host-only: indices
        /// are into this Set's `editor_menus` / `editor_status_items` for this generation, never
        /// persisted. Returns `PluginDisabled`, `NoEditorBarHook` or `NoEditorBarTarget`, or the
        /// hook's failure; the context must not escape the call.
        ///
        /// ```zig
        /// try plugins.editorBarAction(.{ .menu_item = .{ .menu = 0, .item = 1 } }, &editor_context);
        /// ```
        pub fn editorBarAction(self: *Self, target: EditorBarTarget, editor: *EditorContext) !void {
            const owner = locate(target) orelse return error.NoEditorBarTarget;
            if (!self.enabled[owner.plugin]) return error.PluginDisabled;
            inline for (list, 0..) |T, i| if (owner.plugin == i) {
                if (!@hasDecl(T, "editorBarAction")) return error.NoEditorBarHook;
                return self.instances[i].editorBarAction(owner.target, editor);
            };
            unreachable;
        }

        /// Ask the plugin how `target` shows now. A disabled plugin's entries come back disabled
        /// without running a hook, and a plugin without `editorBarState` shows its entries as
        /// declared. Hook failures propagate (the host should then show the declared look).
        ///
        /// ```zig
        /// var state = eggy.plugins.EditorBarState{};
        /// try plugins.editorBarState(.{ .status = 0 }, &editor_context, &state);
        /// ```
        pub fn editorBarState(self: *Self, target: EditorBarTarget, editor: *EditorContext, state: *EditorBarState) !void {
            state.* = .{};
            const owner = locate(target) orelse return error.NoEditorBarTarget;
            if (!self.enabled[owner.plugin]) {
                state.enabled = false;
                return;
            }
            inline for (list, 0..) |T, i| if (owner.plugin == i and @hasDecl(T, "editorBarState")) try self.instances[i].editorBarState(owner.target, editor, state);
        }

        const Owner = struct { plugin: usize, target: EditorBarTarget };

        /// Which plugin declared `target` (global indices), and the target in its own indices.
        fn locate(target: EditorBarTarget) ?Owner {
            comptime var first_menu: usize = 0;
            comptime var first_status: usize = 0;
            inline for (list, 0..) |T, i| {
                const menu_count = if (@hasDecl(T, "editor_menus")) T.editor_menus.len else 0;
                const status_count = if (@hasDecl(T, "editor_status_items")) T.editor_status_items.len else 0;
                switch (target) {
                    .menu_item => |t| if (t.menu >= first_menu and t.menu < first_menu + menu_count) {
                        if (t.item >= editor_menus[t.menu].items.len) return null;
                        return .{ .plugin = i, .target = .{ .menu_item = .{ .menu = t.menu - first_menu, .item = t.item } } };
                    },
                    .status => |s| if (s >= first_status and s < first_status + status_count) {
                        return .{ .plugin = i, .target = .{ .status = s - first_status } };
                    },
                    .status_item => |t| if (t.status >= first_status and t.status < first_status + status_count) {
                        if (t.item >= editor_status_items[t.status].items.len) return null;
                        return .{ .plugin = i, .target = .{ .status_item = .{ .status = t.status - first_status, .item = t.item } } };
                    },
                }
                first_menu += menu_count;
                first_status += status_count;
            }
            return null;
        }

        /// Draw every enabled plugin's `exportUi` for `platform`
        /// `BuiltinPlatform`s, then `export_platforms`, exporting for `target`.
        /// Host-only: contexts are hook-local. A disabled plugin's own platform says it is off.
        /// Hook errors propagate, leaving later plugins undrawn this frame.
        ///
        /// ```zig
        /// try plugins.exportUi(0, "x86_64-windows-gnu", &editor_context, ui_context);
        /// ```
        pub fn exportUi(self: *Self, platform: usize, target: []const u8, editor: *EditorContext, context: *ui.Context) !void {
            comptime var first: usize = @typeInfo(BuiltinPlatform).@"enum".field_names.len;
            inline for (list, 0..) |T, i| {
                const count = if (@hasDecl(T, "export_platforms")) T.export_platforms.len else 0;
                const seen = exportTarget(platform, first, count, target);
                if (!self.enabled[i]) {
                    if (seen.own != null) context.muted("This plugin is turned off, in Preferences > Plugins.");
                } else if (@hasDecl(T, "exportUi")) try self.instances[i].exportUi(seen, editor, context);
                first += count;
            }
        }

        /// Collect every enabled plugin's `exportArgs` for `platform` (as `exportUi` numbers it)
        /// into `args`. Host-only: returns PluginDisabled for a disabled plugin's own platform;
        /// hook and allocation errors propagate.
        ///
        /// ```zig
        /// var args = eggy.plugins.ExportArgs{ .arena = arena };
        /// try plugins.exportArgs(0, "x86_64-windows-gnu", &args);
        /// ```
        pub fn exportArgs(self: *Self, platform: usize, target: []const u8, args: *ExportArgs) !void {
            comptime var first: usize = @typeInfo(BuiltinPlatform).@"enum".field_names.len;
            inline for (list, 0..) |T, i| {
                const count = if (@hasDecl(T, "export_platforms")) T.export_platforms.len else 0;
                const seen = exportTarget(platform, first, count, target);
                if (!self.enabled[i]) {
                    if (seen.own != null) return error.PluginDisabled;
                } else if (@hasDecl(T, "exportArgs")) try self.instances[i].exportArgs(seen, args);
                first += count;
            }
        }

        /// `platform` as the plugin whose own platforms start at `first` (`count` of them) sees it.
        fn exportTarget(platform: usize, first: usize, count: usize, target: []const u8) ExportTarget {
            const builtin_count = @typeInfo(BuiltinPlatform).@"enum".field_names.len;
            return .{
                .builtin = if (platform < builtin_count) @fromBackingInt(@intCast(platform)) else null,
                .own = if (platform >= first and platform < first + count) platform - first else null,
                .target = target,
            };
        }

        /// Load through the executable's resource bridge, never library-local filesystem I/O.
        fn registerFileMap(comptime Mapping: type, gpa: std.mem.Allocator, app: *App, owner: []const u8) !void {
            const source = app.resources().read(gpa, @import("refs.zig").AssetRef(.input_map).init(Mapping.file)) catch |err| {
                std.log.err("cannot load input map {s} ({s}): {t}", .{ owner, Mapping.file, err });
                return err;
            };
            defer gpa.free(source);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const file = @import("input/asset.zig").File.parse(arena.allocator(), source) catch |err| {
                std.log.err("invalid input map {s} ({s}): {t}", .{ owner, Mapping.file, err });
                return err;
            };
            app.input.registerFileMap(Mapping, owner, file) catch |err| {
                std.log.err("cannot register input map {s} ({s}): {t}; match the FileMap enum to the file's control names", .{ owner, Mapping.file, err });
                return err;
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

        test "editor command keys include their plugin and dispatch local indices" {
            const Game = struct {
                last: ?usize = null,
                pub const editor_commands = [_]EditorCommand{ .{ .key = "raise", .title = "Raise" }, .{ .key = "lower", .title = "Lower" } };
                /// Test fixture: record the plugin-local command index without using editor services.
                ///
                /// ```zig
                /// // Within this fixture, with game: Game and an editor context:
                /// try game.editorCommand(1, editor);
                /// ```
                pub fn editorCommand(self: *@This(), command: usize, _: *EditorContext) !void {
                    self.last = command;
                }

                test "disabled UI plugins do not opt a game into overlay rendering" {
                    const Widget = struct {
                        /// Test fixture: a no-op UI hook used only to test enabled-hook detection.
                        ///
                        /// ```zig
                        /// // Within this fixture, with widget, app and a building UI context:
                        /// try widget.gameUi(app, context);
                        /// ```
                        pub fn gameUi(_: *@This(), _: *App, _: *ui.Context) !void {}
                        /// Test fixture: a no-op draw hook; records no commands and retains no context.
                        ///
                        /// ```zig
                        /// // Within this fixture, with widget and a current draw context:
                        /// try widget.draw(app, draw);
                        /// ```
                        pub fn draw(_: *@This(), _: *App, _: DrawContext) !void {}
                    };
                    const Plugins = Set(.{ struct {}, Widget }, &.{ "game", "widgets" });
                    var plugins = try Plugins.init(std.testing.allocator, undefined, .{ true, true });
                    try std.testing.expect(plugins.hasGameUi() and plugins.hasDraw());
                    plugins.enabled[1] = false;
                    try std.testing.expect(!plugins.hasGameUi() and !plugins.hasDraw());
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
        /// Test fixture: append the game's start marker and return an empty instance.
        /// Allocator/App are unused; no resources are acquired.
        ///
        /// ```zig
        /// // Within this fixture with a live app:
        /// var game = try Game.init(gpa, app);
        /// ```
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            Log.add('g');
            return .{};
        }
        /// Test fixture: append the update marker, without reading App or changing game state.
        ///
        /// ```zig
        /// // Within this fixture, after initialization:
        /// try game.update(app);
        /// ```
        pub fn update(_: *@This(), _: *App) !void {
            Log.add('u');
        }
        /// Test fixture: append the game's stop marker; no allocations are owned.
        ///
        /// ```zig
        /// // Within this fixture, after Game.init:
        /// game.deinit();
        /// ```
        pub fn deinit(_: *@This()) void {
            Log.add('G');
        }
    };
    const Quiet = struct {}; // no hooks at all
    const Stats = struct {
        /// Test fixture: append the Stats start marker and return an empty instance.
        /// Allocator/App are unused; there is no resource ownership.
        ///
        /// ```zig
        /// // Within this fixture:
        /// var stats = try Stats.init(gpa, app);
        /// ```
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            Log.add('s');
            return .{};
        }
        /// Test fixture: append the Stats stop marker to verify reverse teardown order.
        ///
        /// ```zig
        /// // Within this fixture, after Stats.init:
        /// stats.deinit();
        /// ```
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
        /// Test fixture: append 10 plus the plugin-local panel index to the bounded log.
        /// Caller must leave a free log slot; editor/UI pointers are unused.
        ///
        /// ```zig
        /// // Within this fixture, with game and hook contexts:
        /// try game.editorPanelUi(0, editor, context);
        /// ```
        pub fn editorPanelUi(_: *@This(), panel: usize, _: *EditorContext, _: *ui.Context) !void {
            Log.drawn[Log.len] = 10 + panel;
            Log.len += 1;
        }
    };
    const Stats = struct {
        pub const editor_panels = [_]EditorPanel{ .{ .title = "Frames" }, .{ .title = "Memory" } };
        /// Test fixture: append 20 plus the local panel index to verify global-to-local dispatch.
        /// Caller must leave a free log slot; no UI is constructed or retained.
        ///
        /// ```zig
        /// // Within this fixture, with stats and hook contexts:
        /// try stats.editorPanelUi(1, editor, context);
        /// ```
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
        /// Test fixture: increment the stop count, verifying cleanup after later init fails.
        ///
        /// ```zig
        /// var started = Started{};
        /// started.deinit();
        /// ```
        pub fn deinit(_: *@This()) void {
            Log.stopped += 1;
        }
    };
    const Failing = struct {
        /// Test fixture: always fail with `NoAudioDevice`, acquiring no resources.
        /// Allocator/App are unused; no initialized instance is returned.
        ///
        /// ```zig
        /// try std.testing.expectError(error.NoAudioDevice, Failing.init(gpa, app));
        /// ```
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
        /// Test fixture: count one successful game start; returns an allocation-free value.
        /// Allocator/App are unused.
        ///
        /// ```zig
        /// // Within this fixture:
        /// const game = try Game.init(gpa, app);
        /// ```
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            Log.started += 1;
            return .{};
        }
    };
    const Broken = struct {
        /// Test fixture: fail with `ShouldNotStart` if disabled-plugin filtering is broken.
        /// No resources or App pointers are retained.
        ///
        /// ```zig
        /// try std.testing.expectError(error.ShouldNotStart, Broken.init(gpa, app));
        /// ```
        pub fn init(_: std.mem.Allocator, _: *App) !@This() {
            return error.ShouldNotStart;
        }
        /// Test fixture: fail with `ShouldNotRun` if a disabled plugin receives an update.
        ///
        /// ```zig
        /// var broken = Broken{}; // Empty fixture, deliberately bypassing its failing init.
        /// try std.testing.expectError(error.ShouldNotRun, broken.update(app));
        /// ```
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

test "export platforms are scoped to their plugin, which sees its own by local index" {
    const Pi = struct {
        seen: ?ExportTarget = null,
        pub const export_platforms = [_]ExportPlatform{.{ .key = "pi", .title = "Raspberry Pi", .target = "aarch64-linux-gnu" }};
        /// Test fixture: remember the platform it was asked about and add one argument.
        ///
        /// ```zig
        /// try pi.exportArgs(platform, &args); // Within this fixture.
        /// ```
        pub fn exportArgs(self: *@This(), platform: ExportTarget, args: *ExportArgs) !void {
            self.seen = platform;
            try args.add("-Dpi=true");
        }
    };
    const Plugins = Set(.{ struct {}, Pi }, &.{ "game", "boards" });
    try std.testing.expectEqualStrings("boards/pi", Plugins.export_platforms[0].key);

    var plugins = try Plugins.init(std.testing.allocator, undefined, .{ true, true });
    defer plugins.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var args = ExportArgs{ .arena = arena.allocator() };

    // Eggy's Windows: a built-in, not its own.
    try plugins.exportArgs(@backingInt(BuiltinPlatform.windows), "x86_64-windows-gnu", &args);
    try std.testing.expectEqual(BuiltinPlatform.windows, plugins.instances[1].seen.?.builtin.?);
    try std.testing.expectEqual(@as(?usize, null), plugins.instances[1].seen.?.own);

    // Its own platform comes after Eggy's five.
    try plugins.exportArgs(@typeInfo(BuiltinPlatform).@"enum".field_names.len, "aarch64-linux-gnu", &args);
    try std.testing.expectEqual(@as(?usize, 0), plugins.instances[1].seen.?.own);
    try std.testing.expectEqual(@as(usize, 2), args.list.items.len);
}

test "plugin bars are scoped to their plugin and dispatch its local indices" {
    const Tools = struct {
        pressed: ?EditorBarTarget = null,
        pub const editor_menus = [_]EditorMenu{
            .{ .key = "tools", .title = "Tools", .items = &.{ .{ .key = "bake", .title = "Bake" }, .{ .key = "clean", .title = "Clean", .checkable = true } } },
            .{ .key = "more", .title = "More", .extends = .view, .items = &.{.{ .key = "grid", .title = "Grid" }} },
        };
        pub const editor_status_items = [_]EditorStatusItem{
            .{ .key = "fps", .title = "FPS", .side = .right },
            .{ .key = "mode", .title = "Mode", .items = &.{.{ .key = "fast", .title = "Fast" }} },
        };
        /// Test fixture: remember the target it was given, in this plugin's own indices.
        ///
        /// ```zig
        /// try tools.editorBarAction(.{ .status = 0 }, editor); // Within this fixture.
        /// ```
        pub fn editorBarAction(self: *@This(), target: EditorBarTarget, _: *EditorContext) !void {
            self.pressed = target;
        }
        /// Test fixture: check the second Tools row and give the first status item text.
        ///
        /// ```zig
        /// try tools.editorBarState(.{ .status = 0 }, editor, &state); // Within this fixture.
        /// ```
        pub fn editorBarState(_: *@This(), target: EditorBarTarget, _: *EditorContext, state: *EditorBarState) !void {
            switch (target) {
                .menu_item => |t| state.checked = t.menu == 0 and t.item == 1,
                .status => |s| if (s == 0) state.setText("60 fps"),
                .status_item => {},
            }
        }
    };
    const Other = struct {
        pub const editor_menus = [_]EditorMenu{.{ .key = "tools", .title = "Tools", .items = &.{.{ .key = "bake", .title = "Bake" }} }};
        pub const editor_status_items = [_]EditorStatusItem{.{ .key = "fps", .title = "FPS" }};
    };
    const Plugins = Set(.{ struct {}, Tools, Other }, &.{ "game", "tools", "other" });

    // The same local keys under different plugins don't collide.
    try std.testing.expectEqualStrings("tools/tools", Plugins.editor_menus[0].key);
    try std.testing.expectEqualStrings("tools/tools/clean", Plugins.editor_menus[0].items[1].key);
    try std.testing.expectEqualStrings("other/tools", Plugins.editor_menus[2].key);
    try std.testing.expectEqual(BuiltinMenu.view, Plugins.editor_menus[1].extends.?);
    try std.testing.expectEqualStrings("other/fps", Plugins.editor_status_items[2].key);

    var plugins = try Plugins.init(std.testing.allocator, undefined, .{ true, true, true });
    defer plugins.deinit();
    try plugins.editorBarAction(.{ .menu_item = .{ .menu = 1, .item = 0 } }, undefined);
    try std.testing.expectEqual(@as(usize, 1), plugins.instances[1].pressed.?.menu_item.menu);
    try plugins.editorBarAction(.{ .status_item = .{ .status = 1, .item = 0 } }, undefined);
    try std.testing.expectEqual(@as(usize, 1), plugins.instances[1].pressed.?.status_item.status);

    var state = EditorBarState{};
    try plugins.editorBarState(.{ .menu_item = .{ .menu = 0, .item = 1 } }, undefined, &state);
    try std.testing.expect(state.checked and state.enabled);
    try plugins.editorBarState(.{ .status = 0 }, undefined, &state);
    try std.testing.expectEqualStrings("60 fps", state.text());

    // Indices that nothing declared, or rows past a menu's end, are refused.
    try std.testing.expectError(error.NoEditorBarTarget, plugins.editorBarAction(.{ .menu_item = .{ .menu = 3, .item = 0 } }, undefined));
    try std.testing.expectError(error.NoEditorBarTarget, plugins.editorBarAction(.{ .menu_item = .{ .menu = 0, .item = 2 } }, undefined));
    // A plugin that declares no action hook says so.
    try std.testing.expectError(error.NoEditorBarHook, plugins.editorBarAction(.{ .menu_item = .{ .menu = 2, .item = 0 } }, undefined));
}

test "a turned-off plugin's bar entries are disabled and never run" {
    const Tools = struct {
        ran: u32 = 0,
        pub const editor_menus = [_]EditorMenu{.{ .key = "tools", .title = "Tools", .items = &.{.{ .key = "bake", .title = "Bake" }} }};
        pub const editor_status_items = [_]EditorStatusItem{.{ .key = "fps", .title = "FPS" }};
        /// Test fixture: count how often it runs.
        ///
        /// ```zig
        /// try tools.editorBarAction(.{ .status = 0 }, editor); // Within this fixture.
        /// ```
        pub fn editorBarAction(self: *@This(), _: EditorBarTarget, _: *EditorContext) !void {
            self.ran += 1;
        }
        /// Test fixture: ask for a different look, which a turned-off plugin must not get to.
        ///
        /// ```zig
        /// try tools.editorBarState(.{ .status = 0 }, editor, &state); // Within this fixture.
        /// ```
        pub fn editorBarState(_: *@This(), _: EditorBarTarget, _: *EditorContext, state: *EditorBarState) !void {
            state.setText("on");
        }
    };
    const Plugins = Set(.{ struct {}, Tools }, &.{ "game", "tools" });
    var plugins = try Plugins.init(std.testing.allocator, undefined, .{ true, true });
    defer plugins.deinit();
    plugins.enabled[1] = false;

    try std.testing.expectError(error.PluginDisabled, plugins.editorBarAction(.{ .status = 0 }, undefined));
    try std.testing.expectError(error.PluginDisabled, plugins.editorBarAction(.{ .menu_item = .{ .menu = 0, .item = 0 } }, undefined));
    var state = EditorBarState{};
    try plugins.editorBarState(.{ .status = 0 }, undefined, &state);
    try std.testing.expect(!state.enabled);
    try std.testing.expectEqualStrings("", state.text());

    // Turned back on, the same entries run.
    plugins.enabled[1] = true;
    try plugins.editorBarAction(.{ .status = 0 }, undefined);
    try std.testing.expectEqual(@as(u32, 1), plugins.instances[1].ran);
}

test "status text is cut on a character boundary" {
    var state = EditorBarState{};
    const long: [80]u8 = @bitCast(@as([40][2]u8, @splat("é".*)));
    state.setText(&long);
    try std.testing.expect(state.text().len <= EditorBarState.max_text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.text()));
}
