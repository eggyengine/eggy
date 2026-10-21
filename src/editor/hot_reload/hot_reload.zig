//! The editor's side of the game's library (`library.zig`): loading it, running the game's hooks
//! through it, and swapping in a rebuilt one while the editor keeps running. The game starts over
//! on each swap, with an empty world, on the same window and GPU.
const std = @import("std");
const eggy = @import("eggy");
const api = @import("game_api.zig");
const log = std.log.scoped(.hot_reload);
const game_log = std.log.scoped(.game);

/// Where the loaded copies of the library go, beside the library: a copy can be swapped out
/// and deleted without the build ever finding the library locked (Windows) or a stale copy cached
/// under the same name (dlopen).
const copies_dir = ".eggy-hot";

pub const HotGame = struct {
    gpa: std.mem.Allocator,
    /// The library's path, absolute; rebuilt in place by the project's build.
    path: []u8,
    /// The copy loaded, and the game in it; null once a swap's library failed to load.
    copy_path: []u8,
    library: ?std.DynLib,
    game: *const api.Game,
    /// The started game and plugins; null while they aren't running: they failed to start, or a
    /// hook failed, which pauses them until the next swap rather than closing the editor.
    state: ?*anyopaque,
    /// The game's panels, copied out of the library, as the editor shows them across swaps.
    panels: []eggy.plugins.EditorPanel,
    commands: []const eggy.plugins.EditorCommand = &.{},
    file_types: []const eggy.plugins.EditorFileType = &.{},
    /// The plugins' top-bar menus and status bar entries, rebuilt from the library on every
    /// load and copied into `manifest_arena` (rows included): the editor keeps no callbacks.
    menus: []const eggy.plugins.EditorMenu = &.{},
    status_items: []const eggy.plugins.EditorStatusItem = &.{},
    /// The plugins' File > Export platforms, copied into `manifest_arena` too.
    export_platforms: []const eggy.plugins.ExportPlatform = &.{},
    /// Each plugin's preferences, copied out of the library into `manifest_arena`.
    preference_manifests: []const eggy.preferences.Manifest = &.{},
    /// The game's and each plugin's key, the game first, copied into `manifest_arena` too.
    plugin_keys: []const [:0]const u8 = &.{},
    /// The component types the game and plugins list, copied into `manifest_arena` too.
    component_types: []const eggy.components.Info = &.{},
    manifest_arena: std.heap.ArenaAllocator,
    /// How many copies this editor has loaded, which names the next one.
    loads: u32 = 0,

    /// Load a private copy of the game library at absolute `path`, without starting plugins.
    /// Editor host only: owns copied paths/metadata until `deinit`; file, dynamic-loader,
    /// ABI-version and allocation failures propagate with incomplete loads cleaned up.
    /// After loading, restore any scene before calling `start` (which runs world Init stages).
    ///
    /// ```zig
    /// // Given allocator gpa, absolute game-library path and App pointer:
    /// var game = try HotGame.load(gpa, library_path);
    /// defer game.deinit(app);
    /// game.start(app, &.{}, .discard);
    /// ```
    pub fn load(gpa: std.mem.Allocator, path: []const u8) !HotGame {
        var self = HotGame{ .gpa = gpa, .path = try gpa.dupe(u8, path), .copy_path = &.{}, .library = null, .game = undefined, .state = null, .panels = &.{}, .manifest_arena = .init(gpa) };
        errdefer gpa.free(self.path);
        errdefer self.manifest_arena.deinit();
        try self.open();
        return self;
    }

    /// What becomes of the entities the plugins' `init` hooks spawn: kept, as when the game
    /// plays (as it does when it ships, starting on its scene), or dropped, as while editing,
    /// where the world is the scene and nothing else, so they don't pile up in it each time the
    /// plugins start again.
    pub const Spawned = enum { keep, discard };

    /// Start the game and its plugins, but those keyed in `off`, on `app`, whose world may
    /// already hold a scene, and run the world's Init stages; what they spawn goes as `spawned`
    /// says. If a plugin fails to start (logged), the game stays stopped until the next swap.
    /// Editor host only: `app` and this library must use the same Eggy ABI; the game itself
    /// is always enabled. Already-running/unloaded games are no-ops. `.discard` preserves
    /// pre-existing entity generations but cannot discard init-spawned entities if its
    /// bookkeeping allocation fails; startup failures are logged, not returned.
    ///
    /// ```zig
    /// // Given a loaded HotGame and its App pointer, after restoring the scene:
    /// game.start(app, &.{"optional_plugin"}, .discard);
    /// ```
    pub fn start(self: *HotGame, app: *eggy.App, off: []const []const u8, spawned: Spawned) void {
        if (self.library == null or self.state != null) return;
        // The entities there before, to tell those the plugins made.
        const before = app.world.slots.items.len;
        var generations: std.ArrayList(?u32) = .empty;
        defer generations.deinit(self.gpa);
        if (spawned == .discard) for (app.world.slots.items) |slot| generations.append(self.gpa, if (slot.alive) slot.generation else null) catch {};
        const enabled = self.gpa.alloc(bool, self.plugin_keys.len) catch return log.err("the game didn't start: out of memory", .{});
        defer self.gpa.free(enabled);
        // The game is always on; a plugin unless `off` names it.
        for (enabled, self.plugin_keys, 0..) |*on, key, i| {
            on.* = true;
            if (i > 0) for (off) |off_key| if (std.mem.eql(u8, key, off_key)) {
                on.* = false;
            };
        }
        self.state = self.game.start(&host, &self.gpa, app, enabled.ptr);
        if (self.state == null) log.err("the game didn't start: see the errors above. It starts again when its code is rebuilt.", .{});
        if (spawned == .keep or generations.items.len != before) return;
        var dropped: usize = 0;
        for (app.world.slots.items, 0..) |slot, i| {
            if (!slot.alive) continue;
            if (i < before) if (generations.items[i]) |generation| if (generation == slot.generation) continue;
            app.world.despawn(eggy.ecs.EntityId.init(@intCast(i), slot.generation));
            dropped += 1;
        }
        if (dropped > 0) log.debug("left out {d} entities the plugins spawned as they started: the scene is what was saved", .{dropped});
    }

    /// Stop the game, empty the world, and unload the library.
    /// Editor host only: call once while `app` is alive, after all hooks have returned.
    /// Clears the world before unloading its component code, forgets preference type bindings,
    /// releases copied metadata/paths and attempts to delete the private library copy.
    ///
    /// ```zig
    /// var game = try HotGame.load(gpa, library_path); // Existing allocator/absolute path.
    /// defer game.deinit(app); // App outlives game.
    /// ```
    pub fn deinit(self: *HotGame, app: *eggy.App) void {
        self.close(app);
        self.manifest_arena.deinit();
        self.gpa.free(self.path);
    }

    /// Stop the game, clear `app`'s world and load the rebuilt library from the stored path.
    /// Editor host only: call after hooks unwind, capturing the old scene beforehand if needed.
    /// Invalidates all borrowed metadata/access results; a failed load propagates and leaves
    /// no library running. The caller must restore the scene and call `start` after success.
    ///
    /// ```zig
    /// // Given HotGame game, App pointer and a scene captured before reload:
    /// try game.reload(app);
    /// game.restart(app, &scene, &.{}, .discard);
    /// ```
    pub fn reload(self: *HotGame, app: *eggy.App) !void {
        self.close(app);
        try self.open();
        log.info("swapped in the rebuilt game", .{});
    }

    /// Run a frame of the game and its world (playing), if it is running. Failures are logged
    /// by the library and don't stop it.
    /// Editor host only: updates plugin hooks then world systems; stopped games are no-ops.
    ///
    /// ```zig
    /// game.update(app); // Existing running HotGame and its App pointer, while playing.
    /// ```
    pub fn update(self: *HotGame, app: *eggy.App) void {
        const state = self.state orelse return;
        _ = self.game.update(state, app);
    }

    /// Ask whether a running game's enabled plugins provide UI; false when stopped.
    /// Editor host only: does not build UI or transfer ownership.
    ///
    /// ```zig
    /// const has_ui = game.hasGameUi(); // Existing HotGame.
    /// ```
    pub fn hasGameUi(self: *const HotGame) bool {
        return self.game.has_game_ui(self.state orelse return false);
    }

    /// Ask whether a running game's enabled plugins provide custom drawing; false when stopped.
    /// Editor host only: this is a capability query, not a rendering call.
    ///
    /// ```zig
    /// const has_draw = game.hasDraw(); // Existing HotGame.
    /// ```
    pub fn hasDraw(self: *const HotGame) bool {
        return self.game.has_draw(self.state orelse return false);
    }

    /// Build running game UI into the supplied live frame context; stopped games do nothing.
    /// Editor host only: borrows `app`/`context` for the synchronous hook; hook errors are logged.
    ///
    /// ```zig
    /// game.gameUi(app, context); // Existing HotGame, App and building UI context.
    /// ```
    pub fn gameUi(self: *HotGame, app: *eggy.App, context: *eggy.ui.Context) void {
        const state = self.state orelse return;
        _ = self.game.game_ui(state, app, context);
    }

    /// Invoke running plugin drawing with the host's recording command buffer and render target.
    /// Editor host only: call outside a render pass; hooks open/close their own passes through
    /// DrawContext. Target/frame resources are borrowed for the call; stopped games do nothing
    /// and hook failures are logged without ending the game.
    ///
    /// ```zig
    /// game.draw(app, draw_context); // Host-provided eggy.DrawContext, outside a render pass.
    /// ```
    pub fn draw(self: *HotGame, app: *eggy.App, context: eggy.DrawContext) void {
        const state = self.state orelse return;
        _ = self.game.draw(state, app, &context);
    }

    /// Route UI-priority input to running game plugins, before ordinary gameplay routing.
    /// Editor host only: returns true when consumed, or when the ABI reports a hook error
    /// (logged); a stopped game returns false. Event storage is borrowed only for this call.
    ///
    /// ```zig
    /// const used = game.uiEvent(app, event); // Existing HotGame, App and Eggy event.
    /// ```
    pub fn uiEvent(self: *HotGame, app: *eggy.App, event_value: eggy.Event) bool {
        const state = self.state orelse return false;
        return self.game.ui_event(state, app, &event_value) != 0;
    }

    /// Run a frame of the plugins' editor tools (not playing), if the game is running.
    /// Editor host only: `editor` is a hook-local service view of this game's App; do not
    /// process pending reload/lifecycle requests until the hook returns. Errors are logged.
    ///
    /// ```zig
    /// game.editorUpdate(&editor_context); // Existing HotGame and hook-local editor context.
    /// ```
    pub fn editorUpdate(self: *HotGame, editor: *eggy.editor.Context) void {
        const state = self.state orelse return;
        _ = self.game.editor_update(state, editor);
    }

    /// Start the game over on `scene` without reloading it: stop its plugins, empty the world,
    /// put `scene` in, and start them again (with the world's Init stages), but those keyed in
    /// `off`, what they spawn going as `spawned` says. Play does this, keeping what they spawn,
    /// as the shipped game starts; Stop does it dropping that, so the world is the scene as it
    /// was before Play, its entity count included.
    /// Editor host only: `scene` must own its snapshot independently of the old world.
    /// Invalidates old entity ids/component pointers; logs restore/start failures and frees
    /// the temporary made-entity list. Without a loaded library it does nothing.
    ///
    /// ```zig
    /// game.restart(app, &scene, &.{}, .keep); // Independent captured scene; enter Play.
    /// ```
    pub fn restart(self: *HotGame, app: *eggy.App, scene: *const eggy.scene.Scene, off: []const []const u8, spawned: Spawned) void {
        const made = self.restartMaking(app, scene, off, spawned);
        self.gpa.free(made);
    }

    /// `restart`, returning the entities made from `scene`, in its order (caller-owned; empty
    /// when it couldn't be put back).
    /// Editor host only: `scene` must survive resetting the old world. Free the returned
    /// list with `self.gpa`; its ids refer to the new world, not the snapshot's original ids.
    /// Restore/start failures are logged; startup is still attempted after a restore failure.
    ///
    /// ```zig
    /// const made = game.restartMaking(app, &scene, &.{}, .discard);
    /// defer game.gpa.free(made); // Existing HotGame, App and independent scene snapshot.
    /// ```
    pub fn restartMaking(self: *HotGame, app: *eggy.App, scene: *const eggy.scene.Scene, off: []const []const u8, spawned: Spawned) []eggy.ecs.EntityId {
        if (self.library == null) return &.{};
        if (self.state) |state| self.game.stop(state);
        self.state = null;
        app.resetWorld();
        const made: []eggy.ecs.EntityId = if (scene.instantiate(self.gpa, &app.world, self.sceneAccess(), null)) |result| result.entities else |err| blk: {
            log.err("cannot put the scene back: {t}", .{err});
            break :blk &.{};
        };
        self.start(app, off, spawned);
        return made;
    }

    /// Deliver ordinary gameplay input to running plugins after higher-priority UI routing.
    /// Editor host only: borrows the event for the call; stopped games do nothing and errors log.
    ///
    /// ```zig
    /// game.event(app, event); // Existing HotGame and App; unconsumed Eggy event.
    /// ```
    pub fn event(self: *HotGame, app: *eggy.App, curr_event: eggy.Event) void {
        const state = self.state orelse return;
        _ = self.game.event(state, app, &curr_event);
    }

    /// Build the combined plugin editor UI, or a stopped-game message, into this UI frame.
    /// Editor host only: both contexts are hook-local; handle deferred lifecycle requests
    /// after return. Hook failures are logged rather than propagated.
    ///
    /// ```zig
    /// game.editorUi(&editor_context, context); // Existing HotGame and building UI context.
    /// ```
    pub fn editorUi(self: *HotGame, editor: *eggy.editor.Context, context: *eggy.ui.Context) void {
        const state = self.state orelse return context.muted("The game isn't running: see the Console. It starts again when its code is rebuilt.");
        self.game.editor_ui(state, editor, context);
    }

    /// Build zero-based `panels[panel]` through the running game's hook into this UI frame.
    /// Editor host only: stopped/out-of-range calls do nothing; contexts are borrowed and
    /// hook failures log. Process deferred lifecycle requests only after return.
    ///
    /// ```zig
    /// game.editorPanelUi(0, &editor_context, context); // Live host contexts and HotGame.
    /// ```
    pub fn editorPanelUi(self: *HotGame, panel: usize, editor: *eggy.editor.Context, context: *eggy.ui.Context) void {
        const state = self.state orelse return;
        if (panel < self.panels.len) self.game.editor_panel_ui(state, panel, editor, context);
    }

    /// Execute zero-based `commands[command]` synchronously through the running game.
    /// Editor host only: stopped/out-of-range calls do nothing and hook failures log.
    /// The hook-local editor context may queue lifecycle work; process it only after return.
    ///
    /// ```zig
    /// game.editorCommand(0, &editor_context); // Existing HotGame and host service context.
    /// ```
    pub fn editorCommand(self: *HotGame, command: usize, editor: *eggy.editor.Context) void {
        const state = self.state orelse return;
        if (command >= self.commands.len) return;
        self.game.editor_command(state, command, editor);
    }

    /// Press a plugin's menu row or status bar entry, by its place in `menus` / `status_items`
    /// (`item` for `.menu_item` and `.status_item`). Editor host only: does nothing while the
    /// game isn't running, for a turned-off plugin's entry or an index past the metadata; hook
    /// failures log. The hook-local editor context may queue lifecycle work; process it only
    /// after return.
    ///
    /// ```zig
    /// game.barAction(.{ .menu_item = .{ .menu = 0, .item = 1 } }, &editor_context);
    /// ```
    pub fn barAction(self: *HotGame, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) void {
        const state = self.state orelse return;
        if (!self.hasBarTarget(target)) return;
        const call = barCall(target);
        self.game.bar_action(state, call.kind, call.owner, call.item, editor);
    }

    /// How a plugin's menu row or status bar entry looks now. While the game isn't running its
    /// entries are disabled; a failed hook (logged) leaves the declared look. Editor host only.
    ///
    /// ```zig
    /// const look = game.barState(.{ .status = 0 }, &editor_context);
    /// ```
    pub fn barState(self: *HotGame, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) eggy.plugins.EditorBarState {
        var result = eggy.plugins.EditorBarState{};
        const state = self.state orelse return .{ .enabled = false };
        if (!self.hasBarTarget(target)) return .{ .enabled = false };
        const call = barCall(target);
        if (!self.game.bar_state(state, call.kind, call.owner, call.item, editor, &result)) return .{};
        return result;
    }

    fn hasBarTarget(self: *const HotGame, target: eggy.plugins.EditorBarTarget) bool {
        return switch (target) {
            .menu_item => |t| t.menu < self.menus.len and t.item < self.menus[t.menu].items.len,
            .status => |s| s < self.status_items.len,
            .status_item => |t| t.status < self.status_items.len and t.item < self.status_items[t.status].items.len,
        };
    }

    const BarCall = struct { kind: api.BarKind, owner: usize, item: usize };

    fn barCall(target: eggy.plugins.EditorBarTarget) BarCall {
        return switch (target) {
            .menu_item => |t| .{ .kind = .menu_item, .owner = t.menu, .item = t.item },
            .status => |s| .{ .kind = .status, .owner = s, .item = 0 },
            .status_item => |t| .{ .kind = .status_item, .owner = t.status, .item = t.item },
        };
    }

    /// Draw the plugins' File > Export settings for `platform` (Eggy's `BuiltinPlatform`s, then
    /// `export_platforms`) exporting for `target`, into this UI frame.
    /// Editor host only: does nothing while the game isn't running; hook failures log.
    ///
    /// ```zig
    /// game.exportUi(0, "x86_64-windows-gnu", &editor_context, context);
    /// ```
    pub fn exportUi(self: *HotGame, platform: usize, target: []const u8, editor: *eggy.editor.Context, context: *eggy.ui.Context) void {
        const state = self.state orelse return;
        self.game.export_ui(state, platform, target.ptr, target.len, editor, context);
    }

    /// Add the plugins' `zig build export` arguments for `platform` (numbered as `exportUi`
    /// does) to `args`. Fails with GameNotRunning while it isn't, or ExportArgsFailed when a
    /// hook failed (logged).
    ///
    /// ```zig
    /// var args = eggy.plugins.ExportArgs{ .arena = arena };
    /// try game.exportArgs(0, "x86_64-windows-gnu", &args);
    /// ```
    pub fn exportArgs(self: *HotGame, platform: usize, target: []const u8, args: *eggy.plugins.ExportArgs) !void {
        const state = self.state orelse return error.GameNotRunning;
        if (!self.game.export_args(state, platform, target.ptr, target.len, args)) return error.ExportArgsFailed;
    }

    /// Copy the library and load the copy.
    fn open(self: *HotGame) !void {
        const gpa = self.gpa;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        // A copy of its own, named apart from other editors' and this one's earlier loads.
        const dir = std.fs.path.dirname(self.path) orelse ".";
        const base = std.fs.path.basename(self.path);
        const extension = std.fs.path.extension(base);
        const copies = try std.fs.path.join(gpa, &.{ dir, copies_dir });
        defer gpa.free(copies);
        try std.Io.Dir.cwd().createDirPath(io, copies);
        self.loads += 1;
        var tag: [4]u8 = undefined;
        io.random(&tag);
        const copy_name = try std.fmt.allocPrint(gpa, "{s}-{x}-{d}{s}", .{ base[0 .. base.len - extension.len], tag, self.loads, extension });
        defer gpa.free(copy_name);
        const copy_path = try std.fs.path.join(gpa, &.{ copies, copy_name });
        errdefer gpa.free(copy_path);
        try std.Io.Dir.cwd().copyFile(self.path, std.Io.Dir.cwd(), copy_path, io, .{});
        errdefer std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};

        // Its game, if it was built for this editor.
        var library = try std.DynLib.open(copy_path);
        errdefer library.close();
        const entry = library.lookup(api.Entry, api.entry_symbol) orelse return error.NotAGameLibrary;
        const game = entry();
        if (game.version != api.version) return error.GameLibraryVersionMismatch;
        const panels = try gpa.alloc(eggy.plugins.EditorPanel, game.panel_count);
        errdefer gpa.free(panels);
        var panel_count: usize = 0;
        errdefer for (panels[0..panel_count]) |panel| {
            gpa.free(panel.key);
            gpa.free(panel.title);
        };
        for (panels, game.panels[0..game.panel_count]) |*panel, source| {
            const key = try gpa.dupeZ(u8, std.mem.span(source.key));
            errdefer gpa.free(key);
            panel.* = .{ .key = key, .title = try gpa.dupeZ(u8, std.mem.span(source.title)) };
            panel_count += 1;
        }

        const manifests = try copyManifests(self.manifest_arena.allocator(), game.preferences[0..game.preference_count]);
        const component_types = try copyComponentTypes(self.manifest_arena.allocator(), game.components[0..game.component_count]);
        const plugin_keys = try self.manifest_arena.allocator().alloc([:0]const u8, game.plugin_count);
        for (plugin_keys, game.plugin_keys[0..game.plugin_count]) |*key, source| key.* = try self.manifest_arena.allocator().dupeZ(u8, std.mem.span(source));
        const commands = try self.manifest_arena.allocator().alloc(eggy.plugins.EditorCommand, game.command_count);
        for (commands, game.commands[0..game.command_count]) |*command, source| command.* = .{
            .key = try self.manifest_arena.allocator().dupeZ(u8, std.mem.span(source.key)),
            .title = try self.manifest_arena.allocator().dupeZ(u8, std.mem.span(source.title)),
        };
        const arena = self.manifest_arena.allocator();
        const file_types = try arena.alloc(eggy.plugins.EditorFileType, game.file_type_count);
        for (file_types, game.file_types[0..game.file_type_count]) |*file_type, source| file_type.* = .{
            .key = try arena.dupeZ(u8, std.mem.span(source.key)),
            .title = try arena.dupeZ(u8, std.mem.span(source.title)),
            .extension = try arena.dupeZ(u8, std.mem.span(source.extension)),
            .contents = try arena.dupe(u8, source.contents[0..source.contents_len]),
        };
        const menus = try copyMenus(arena, game);
        const status_items = try copyStatusItems(arena, game);
        const export_platforms = try arena.alloc(eggy.plugins.ExportPlatform, game.export_platform_count);
        for (export_platforms, game.export_platforms[0..game.export_platform_count]) |*platform, source| platform.* = .{
            .key = try arena.dupeZ(u8, std.mem.span(source.key)),
            .title = try arena.dupeZ(u8, std.mem.span(source.title)),
            .target = try arena.dupeZ(u8, std.mem.span(source.target)),
            .note = try arena.dupeZ(u8, std.mem.span(source.note)),
            .icon_png = try arena.dupe(u8, source.icon_png[0..source.icon_png_len]),
        };
        self.* = .{ .gpa = gpa, .path = self.path, .copy_path = copy_path, .library = library, .game = game, .state = null, .panels = panels, .commands = commands, .file_types = file_types, .menus = menus, .status_items = status_items, .export_platforms = export_platforms, .loads = self.loads, .preference_manifests = manifests, .component_types = component_types, .plugin_keys = plugin_keys, .manifest_arena = self.manifest_arena };
    }

    /// Copy the game's menus, with their rows, out of the library's memory.
    fn copyMenus(arena: std.mem.Allocator, game: *const api.Game) ![]eggy.plugins.EditorMenu {
        const menus = try arena.alloc(eggy.plugins.EditorMenu, game.menu_count);
        var next: usize = 0;
        for (menus, game.menus[0..game.menu_count]) |*menu, source| {
            if (next + source.item_count > game.menu_item_count) return error.MalformedGameLibrary;
            menu.* = .{
                .key = try arena.dupeZ(u8, std.mem.span(source.key)),
                .title = try arena.dupeZ(u8, std.mem.span(source.title)),
                .extends = std.enums.fromInt(eggy.plugins.BuiltinMenu, source.extends),
                .items = try copyMenuItems(arena, game.menu_items[next..][0..source.item_count]),
            };
            next += source.item_count;
        }
        return menus;
    }

    /// Copy the game's status bar entries, with their menu rows, out of the library's memory.
    fn copyStatusItems(arena: std.mem.Allocator, game: *const api.Game) ![]eggy.plugins.EditorStatusItem {
        const items = try arena.alloc(eggy.plugins.EditorStatusItem, game.status_item_count);
        var next: usize = 0;
        for (items, game.status_items[0..game.status_item_count]) |*item, source| {
            if (next + source.item_count > game.status_menu_item_count) return error.MalformedGameLibrary;
            item.* = .{
                .key = try arena.dupeZ(u8, std.mem.span(source.key)),
                .title = try arena.dupeZ(u8, std.mem.span(source.title)),
                .side = std.enums.fromInt(eggy.plugins.StatusSide, source.side) orelse return error.MalformedGameLibrary,
                .items = try copyMenuItems(arena, game.status_menu_items[next..][0..source.item_count]),
            };
            next += source.item_count;
        }
        return items;
    }

    fn copyMenuItems(arena: std.mem.Allocator, sources: []const api.MenuItem) ![]eggy.plugins.EditorMenuItem {
        const items = try arena.alloc(eggy.plugins.EditorMenuItem, sources.len);
        for (items, sources) |*item, source| item.* = .{
            .key = try arena.dupeZ(u8, std.mem.span(source.key)),
            .title = try arena.dupeZ(u8, std.mem.span(source.title)),
            .shortcut = try arena.dupeZ(u8, std.mem.span(source.shortcut)),
            .checkable = source.checkable,
        };
        return items;
    }

    /// Stop the game, empty the world while its code is still loaded, and unload and delete the copy.
    fn close(self: *HotGame, app: *eggy.App) void {
        var library = self.library orelse return;
        if (self.state) |state| self.game.stop(state);
        self.state = null;
        app.resetWorld();
        // The types the game registered its preferences under go with its code.
        app.preference_values.forgetTypes();
        for (self.panels) |panel| {
            self.gpa.free(panel.key);
            self.gpa.free(panel.title);
        }
        self.gpa.free(self.panels);
        self.panels = &.{};
        self.commands = &.{};
        self.file_types = &.{};
        self.menus = &.{};
        self.status_items = &.{};
        self.export_platforms = &.{};
        self.preference_manifests = &.{};
        self.component_types = &.{};
        self.plugin_keys = &.{};
        _ = self.manifest_arena.reset(.free_all);
        library.close();
        self.library = null;
        var threaded: std.Io.Threaded = .init_single_threaded;
        std.Io.Dir.cwd().deleteFile(threaded.io(), self.copy_path) catch {};
        self.gpa.free(self.copy_path);
        self.copy_path = &.{};
    }

    /// Where Eggy's own component `name` (`Transform`, `Mesh`...) is among `component_types`.
    /// Editor host only: matches owner "eggy" and exact type name; null if absent/unloaded.
    /// Returned indices must be rediscovered after reload.
    ///
    /// ```zig
    /// const mesh_index = game.builtinComponent("Mesh"); // Existing HotGame.
    /// ```
    pub fn builtinComponent(self: *const HotGame, name: []const u8) ?usize {
        for (self.component_types, 0..) |info, index| {
            if (std.mem.eql(u8, info.name, name) and std.mem.eql(u8, info.owner, "eggy")) return index;
        }
        return null;
    }

    /// Whether `entity` of `app`'s world has component type `component` (of `component_types`).
    /// Editor host only: uses the loaded library's type numbering, even before plugins start.
    /// False covers missing library/out-of-range component; use ids from this App's world.
    ///
    /// ```zig
    /// const present = game.hasComponent(app, entity, component); // Host-owned inputs.
    /// ```
    pub fn hasComponent(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize) bool {
        if (self.library == null or component >= self.component_types.len) return false;
        return self.game.has_component(&app.world, entityOf(entity), component);
    }

    /// Give `entity` component type `component` with its defaults; false if it couldn't (logged).
    /// Editor host only: use a live entity and a current metadata index. Adds required
    /// dependencies through the typed registry; missing library/invalid index returns false.
    /// The surrounding editor owns undo snapshots and dependency-removal policy.
    ///
    /// ```zig
    /// // Given HotGame, App pointer and a live entity:
    /// if (game.builtinComponent("Mesh")) |index| _ = game.addComponent(app, entity, index);
    /// ```
    pub fn addComponent(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize) bool {
        if (self.library == null or component >= self.component_types.len) return false;
        return self.game.add_component(&app.world, entityOf(entity), component);
    }

    /// Remove a component by the loaded library's current index; unloaded/invalid indices no-op.
    /// Editor host only: callers enforce dependency/undo policy before mutating a live entity.
    /// Any pointers into the removed component become invalid.
    ///
    /// ```zig
    /// game.removeComponent(app, entity, component); // Validated host removal request.
    /// ```
    pub fn removeComponent(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize) void {
        if (self.library == null or component >= self.component_types.len) return;
        self.game.remove_component(&app.world, entityOf(entity), component);
    }

    /// Field `field` of `entity`'s component `component` as ZON, in `buffer` (cut short with
    /// "..." when it doesn't fit); null if it can't be read.
    /// Editor host only: `buffer.len` must be at least three for truncation; result borrows
    /// that buffer. Component/field indices refer to current game metadata; truncated text
    /// is for display only and must not be saved back as ZON.
    ///
    /// ```zig
    /// var buffer: [4096]u8 = undefined;
    /// const zon = game.readField(app, entity, component, field, &buffer);
    /// // Existing HotGame, App, entity and current component/field indices.
    /// ```
    pub fn readField(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize, field: usize, buffer: []u8) ?[]const u8 {
        if (self.library == null or component >= self.component_types.len) return null;
        const len = self.game.read_field(&app.world, entityOf(entity), component, field, buffer.ptr, buffer.len);
        if (len == 0) return null;
        if (len <= buffer.len) return buffer[0..len];
        @memcpy(buffer[buffer.len - 3 ..], "...");
        return buffer;
    }

    /// Set field `field` of `entity`'s component `component` from ZON `text`; false if it
    /// doesn't parse as the field's type.
    /// Editor host only: `text` must be sentinel-terminated and survive the synchronous call.
    /// Missing library/component/field also rejects the write; use indices from current metadata.
    /// Successful writes mutate the world immediately; the host owns undo tracking.
    ///
    /// ```zig
    /// const changed = game.writeField(app, entity, component, field, "2.5");
    /// // Existing host inputs for a numeric component field.
    /// ```
    pub fn writeField(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize, field: usize, text: [:0]const u8) bool {
        if (self.library == null or component >= self.component_types.len) return false;
        return self.game.write_field(&app.world, entityOf(entity), component, field, text.ptr);
    }

    /// `entity`'s `eggy.Name` in `buffer`; null without one (or without a library).
    /// Editor host only: result borrows caller storage and may be shortened to its capacity.
    /// Use `eggy.Name.max_len` bytes to retain the full name.
    ///
    /// ```zig
    /// var buffer: [eggy.Name.max_len]u8 = undefined;
    /// const name = game.readName(app, entity, &buffer); // Existing host game/App/entity.
    /// ```
    pub fn readName(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, buffer: []u8) ?[]const u8 {
        if (self.library == null) return null;
        const len = self.game.read_name(&app.world, entityOf(entity), buffer.ptr, buffer.len);
        if (len < 0) return null;
        return buffer[0..@intCast(len)];
    }

    /// Name `entity` `text`, or take its name away when `text` is empty.
    /// Editor host only: copies text through the typed registry; no library is a no-op.
    /// Name capacity limits apply, and write/allocation failures are not returned to the host.
    ///
    /// ```zig
    /// game.writeName(app, entity, "Player"); // Existing HotGame, App and live entity.
    /// ```
    pub fn writeName(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, text: []const u8) void {
        if (self.library == null) return;
        self.game.write_name(&app.world, entityOf(entity), text.ptr, text.len);
    }

    /// The meshes of `app`'s world to draw, into `out`; none without a library.
    /// Editor host only: returns an initialized prefix borrowing `out`, capped by its length.
    /// Drawable references must be consumed before relevant world/library storage changes.
    ///
    /// ```zig
    /// var drawables: [256]eggy.mesh.Drawable = undefined;
    /// const meshes = game.gatherMeshes(app, &drawables); // Existing HotGame and App.
    /// ```
    pub fn gatherMeshes(self: *const HotGame, app: *eggy.App, out: []eggy.mesh.Drawable) []eggy.mesh.Drawable {
        if (self.library == null) return out[0..0];
        return out[0..self.game.gather_meshes(&app.world, out.ptr, out.len)];
    }

    /// Refresh lights through the library; keep the last valid frame on a logged failure.
    pub fn gatherLights(self: *const HotGame, app: *eggy.App, out: *eggy.lighting.Frame) void {
        if (self.library == null) {
            out.* = .{};
            return;
        }
        _ = self.game.gather_lights(&app.world, out);
    }

    /// `entity`'s transform within `app`'s world, as columns; null if it isn't alive (or there
    /// is no library).
    /// Editor host only: composes ancestor transforms in scene units, returning a value copy;
    /// no component pointer crosses the shared-library boundary.
    ///
    /// ```zig
    /// const matrix = game.worldMatrix(app, entity); // Existing host game/App/entity.
    /// ```
    pub fn worldMatrix(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId) ?[4][4]f32 {
        if (self.library == null) return null;
        var matrix: [4][4]f32 = undefined;
        if (!self.game.world_matrix(&app.world, entityOf(entity), &matrix)) return null;
        return matrix;
    }

    /// The view through the game's camera (`eggy.camera.find`); null without one.
    /// Editor host only: queries via library-local component types; returns a view value copy
    /// and also returns null when the library is unloaded.
    ///
    /// ```zig
    /// const view = game.findCamera(app); // Existing HotGame and its App pointer.
    /// ```
    pub fn findCamera(self: *const HotGame, app: *eggy.App) ?eggy.camera.View {
        if (self.library == null) return null;
        var view: eggy.camera.View = undefined;
        return if (self.game.find_camera(&app.world, &view)) view else null;
    }

    /// Start previewing animation on `entity`, remembering what the preview will move. False
    /// without a library or game, or when the entity can't be previewed (logged).
    /// Editor host only: end it with `endAnimationPreview` before the library reloads or the
    /// scene is saved, played or snapshotted.
    pub fn beginAnimationPreview(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId) bool {
        const state = self.state orelse return false;
        return self.game.animation_preview_begin(state, &app.world, entityOf(entity));
    }

    /// Pose the previewed entity in the authored clip `clip` and/or the imported clip
    /// `model_clip` (animation asset keys, either may be empty) at `time_s`, using
    /// `app.graphics.clips`. False without a preview, or for keys the entity can't hold.
    pub fn showAnimationPreview(self: *const HotGame, app: *eggy.App, clip: []const u8, model_clip: []const u8, time_s: f32) bool {
        const state = self.state orelse return false;
        var clip_z: [eggy.refs.max_path_len + 1:0]u8 = undefined;
        var model_z: [eggy.refs.max_path_len + 1:0]u8 = undefined;
        if (clip.len > eggy.refs.max_path_len or model_clip.len > eggy.refs.max_path_len) return false;
        @memcpy(clip_z[0..clip.len], clip);
        clip_z[clip.len] = 0;
        @memcpy(model_z[0..model_clip.len], model_clip);
        model_z[model_clip.len] = 0;
        return self.game.animation_preview_show(state, &app.world, &app.graphics.clips, &clip_z, &model_z, time_s);
    }

    /// Put the previewed entity back as it was; does nothing without a preview.
    pub fn endAnimationPreview(self: *const HotGame, app: *eggy.App) void {
        const state = self.state orelse return;
        self.game.animation_preview_end(state, &app.world);
    }

    /// The child paths below `entity` a clip track can name, one per line, allocated with `gpa`.
    pub fn animationTargets(self: *const HotGame, gpa: std.mem.Allocator, app: *eggy.App, entity: eggy.ecs.EntityId) ![]u8 {
        if (self.library == null) return gpa.alloc(u8, 0);
        var buffer = try gpa.alloc(u8, 512);
        errdefer gpa.free(buffer);
        const needed = self.game.animation_targets(&app.world, entityOf(entity), buffer.ptr, buffer.len);
        if (needed > buffer.len) {
            buffer = try gpa.realloc(buffer, needed);
            _ = self.game.animation_targets(&app.world, entityOf(entity), buffer.ptr, buffer.len);
        }
        return gpa.realloc(buffer, needed);
    }

    /// Position, rotation (degrees) and scale of the child of `entity` at `path` (empty: itself).
    pub fn animationTransform(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, path: []const u8) ?[9]f32 {
        if (self.library == null) return null;
        var out: [9]f32 = undefined;
        return if (self.game.animation_transform(&app.world, entityOf(entity), path.ptr, path.len, &out)) out else null;
    }

    /// The key of the model `entity` draws, copied into `buffer`; null when it draws none or the
    /// key is longer than `buffer`.
    pub fn animationModel(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, buffer: []u8) ?[]const u8 {
        if (self.library == null) return null;
        const len = self.game.animation_model(&app.world, entityOf(entity), buffer.ptr, buffer.len);
        if (len < 0 or len > buffer.len) return null;
        return buffer[0..@intCast(len)];
    }

    /// Give `entity` an `Animator` playing the animation asset with key `clip` (its imported
    /// clip when `imported`, else its authored one), adding the component if needed. A scene
    /// change, so undo covers it. False when it can't be done.
    pub fn assignAnimation(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, clip: []const u8, imported: bool) bool {
        if (self.library == null) return false;
        var clip_z: [eggy.refs.max_path_len + 1:0]u8 = undefined;
        if (clip.len > eggy.refs.max_path_len) return false;
        @memcpy(clip_z[0..clip.len], clip);
        clip_z[clip.len] = 0;
        return self.game.animation_assign(&app.world, entityOf(entity), &clip_z, imported);
    }

    /// The typed steps scenes need, through the library (see `eggy.scene.Access`).
    /// Editor host only: retains a pointer to this HotGame, which must stay at a stable address.
    /// Its world argument must be exactly the enclosing App's `world`, not a standalone World.
    /// Access/metadata must not be used across library teardown or reload.
    ///
    /// ```zig
    /// // Given a stably stored HotGame and its App pointer:
    /// var scene = try eggy.scene.Scene.capture(gpa, &app.world, game.sceneAccess(), roots);
    /// defer scene.deinit();
    /// ```
    pub fn sceneAccess(self: *const HotGame) eggy.scene.Access {
        return .{ .context = self, .vtable = &scene_vtable };
    }

    /// Whether the game is running: it started (a plugin's `init` failing stops it until the
    /// next swap).
    /// Editor host only: this reports started state, not Play mode; editing tools also run
    /// with started plugins. Ordinary hook failures are logged without clearing that state.
    ///
    /// ```zig
    /// const started = game.running(); // Existing HotGame.
    /// ```
    pub fn running(self: *const HotGame) bool {
        return self.state != null;
    }
};

/// The library's preference manifests, copied into `arena`.
fn copyManifests(arena: std.mem.Allocator, sets: []const api.Preferences) ![]const eggy.preferences.Manifest {
    const manifests = try arena.alloc(eggy.preferences.Manifest, sets.len);
    for (manifests, sets) |*manifest, set| {
        const fields = try arena.alloc(eggy.preferences.Field, set.field_count);
        for (fields, set.fields[0..set.field_count]) |*field, source| {
            const options = try arena.alloc([:0]const u8, source.option_count);
            for (options, source.options[0..source.option_count]) |*option, name| option.* = try arena.dupeZ(u8, std.mem.span(name));
            field.* = .{
                .name = try arena.dupeZ(u8, std.mem.span(source.name)),
                .kind = std.enums.fromInt(eggy.preferences.Kind, source.kind) orelse return error.GameLibraryVersionMismatch,
                .default = try arena.dupeZ(u8, std.mem.span(source.default)),
                .options = options,
                .description = try arena.dupeZ(u8, std.mem.span(source.description)),
            };
        }
        manifest.* = .{ .key = try arena.dupeZ(u8, std.mem.span(set.key)), .fields = fields };
    }
    return manifests;
}

/// `HotGame` as an `eggy.scene.Access`. The world given is always the app's (`HotGame`'s calls
/// take the app, and the world is its field).
const scene_vtable = eggy.scene.Access.VTable{
    .types = struct {
        fn f(context: *const anyopaque) []const eggy.components.Info {
            return gameOf(context).component_types;
        }
    }.f,
    .has = struct {
        fn f(context: *const anyopaque, world: *eggy.ecs.World, entity: eggy.ecs.EntityId, component: usize) bool {
            return gameOf(context).hasComponent(appOf(world), entity, component);
        }
    }.f,
    .add = struct {
        fn f(context: *const anyopaque, world: *eggy.ecs.World, entity: eggy.ecs.EntityId, component: usize) bool {
            return gameOf(context).addComponent(appOf(world), entity, component);
        }
    }.f,
    .read_field = struct {
        fn f(context: *const anyopaque, world: *eggy.ecs.World, entity: eggy.ecs.EntityId, component: usize, field: usize, buffer: []u8) ?[]const u8 {
            const game = gameOf(context);
            if (game.library == null or component >= game.component_types.len) return null;
            // Whole values only: one cut short isn't worth saving.
            const len = game.game.read_field(world, entityOf(entity), component, field, buffer.ptr, buffer.len);
            return if (len == 0 or len > buffer.len) null else buffer[0..len];
        }
    }.f,
    .read_field_alloc = struct {
        fn f(context: *const anyopaque, gpa: std.mem.Allocator, world: *eggy.ecs.World, entity: eggy.ecs.EntityId, component: usize, field: usize) eggy.scene.Access.FieldReadError![]u8 {
            const game = gameOf(context);
            if (game.library == null) return error.NoComponent;
            if (component >= game.component_types.len) return error.NoSuchComponent;
            var result: api.FieldBytes = undefined;
            switch (game.game.read_field_alloc(world, &gpa, entityOf(entity), component, field, &result)) {
                .ok => return result.ptr[0..result.len],
                .no_component => return error.NoComponent,
                .no_such_component => return error.NoSuchComponent,
                .out_of_memory => return error.OutOfMemory,
            }
        }
    }.f,
    .write_field = struct {
        fn f(context: *const anyopaque, world: *eggy.ecs.World, entity: eggy.ecs.EntityId, component: usize, field: usize, text: [:0]const u8) bool {
            return gameOf(context).writeField(appOf(world), entity, component, field, text);
        }
    }.f,
    .name = struct {
        fn f(context: *const anyopaque, world: *eggy.ecs.World, entity: eggy.ecs.EntityId, buffer: []u8) ?[]const u8 {
            return gameOf(context).readName(appOf(world), entity, buffer);
        }
    }.f,
    .set_name = struct {
        fn f(context: *const anyopaque, world: *eggy.ecs.World, entity: eggy.ecs.EntityId, text: []const u8) void {
            gameOf(context).writeName(appOf(world), entity, text);
        }
    }.f,
};

fn gameOf(context: *const anyopaque) *const HotGame {
    return @ptrCast(@alignCast(context));
}

fn appOf(world: *eggy.ecs.World) *eggy.App {
    return @fieldParentPtr("world", world);
}

/// The library's component types, copied into `arena`.
fn copyComponentTypes(arena: std.mem.Allocator, types: []const api.ComponentType) ![]const eggy.components.Info {
    const infos = try arena.alloc(eggy.components.Info, types.len);
    for (infos, types) |*info, source| {
        const fields = try arena.alloc(eggy.components.Field, source.field_count);
        for (fields, source.fields[0..source.field_count]) |*field, field_source| {
            const options = try arena.alloc([:0]const u8, field_source.option_count);
            for (options, field_source.options[0..field_source.option_count]) |*option, name| option.* = try arena.dupeZ(u8, std.mem.span(name));
            field.* = .{
                .name = try arena.dupeZ(u8, std.mem.span(field_source.name)),
                .kind = std.enums.fromInt(eggy.components.Kind, field_source.kind) orelse return error.GameLibraryVersionMismatch,
                .options = options,
                .editable = field_source.editable,
                .requires = try arena.dupeZ(u8, std.mem.span(field_source.requires)),
                .accepts = std.enums.fromInt(eggy.refs.AssetKind, field_source.accepts) orelse return error.GameLibraryVersionMismatch,
                .parts = try copyParts(arena, field_source.parts[0..field_source.part_count]),
            };
        }
        info.* = .{ .name = try arena.dupeZ(u8, std.mem.span(source.name)), .owner = try arena.dupeZ(u8, std.mem.span(source.owner)), .fields = fields, .addable = source.addable, .dependencies = try arena.dupe(usize, source.dependencies[0..source.dependency_count]), .icon = try arena.dupeZ(u8, std.mem.span(source.icon)) };
    }
    return infos;
}

/// A field's parts, with their text copied into `arena`.
fn copyParts(arena: std.mem.Allocator, source: []const eggy.components.Part) ![]const eggy.components.Part {
    const parts = try arena.dupe(eggy.components.Part, source);
    for (parts) |*part| {
        part.name = (try arena.dupeZ(u8, std.mem.span(part.name))).ptr;
        part.requires = (try arena.dupeZ(u8, std.mem.span(part.requires))).ptr;
        const options = try arena.alloc([*:0]const u8, part.option_count);
        for (options, part.optionNames()) |*option, name| option.* = (try arena.dupeZ(u8, std.mem.span(name))).ptr;
        part.options = options.ptr;
    }
    return parts;
}

fn entityOf(entity: eggy.ecs.EntityId) api.Entity {
    return .{ .id = entity.id, .generation = entity.generation };
}

/// What the library may call in the editor.
const host = api.Host{ .log = logFromGame };

fn logFromGame(level: u8, scope_ptr: [*]const u8, scope_len: usize, text_ptr: [*]const u8, text_len: usize) callconv(.c) void {
    const scope = scope_ptr[0..scope_len];
    const text = text_ptr[0..text_len];
    const prefix: []const u8 = if (std.mem.eql(u8, scope, "default")) "" else scope;
    const separator: []const u8 = if (prefix.len > 0) ": " else "";
    switch (std.enums.fromInt(std.log.Level, level) orelse .info) {
        .err => game_log.err("{s}{s}{s}", .{ prefix, separator, text }),
        .warn => game_log.warn("{s}{s}{s}", .{ prefix, separator, text }),
        .info => game_log.info("{s}{s}{s}", .{ prefix, separator, text }),
        .debug => game_log.debug("{s}{s}{s}", .{ prefix, separator, text }),
    }
}

test "the boundary compiles" {
    std.testing.refAllDecls(HotGame);
}
