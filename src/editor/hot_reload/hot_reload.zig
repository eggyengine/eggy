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
    /// Each plugin's preferences, copied out of the library into `manifest_arena`.
    preference_manifests: []const eggy.preferences.Manifest = &.{},
    /// The game's and each plugin's key, the game first, copied into `manifest_arena` too.
    plugin_keys: []const [:0]const u8 = &.{},
    /// The component types the game and plugins list, copied into `manifest_arena` too.
    component_types: []const eggy.components.Info = &.{},
    manifest_arena: std.heap.ArenaAllocator,
    /// How many copies this editor has loaded, which names the next one.
    loads: u32 = 0,

    /// Load the library at `path` (absolute). Then put any scene into `app`'s world, `start`
    /// the game, and run `app.startWorld`.
    pub fn load(gpa: std.mem.Allocator, path: []const u8) !HotGame {
        var self = HotGame{ .gpa = gpa, .path = try gpa.dupe(u8, path), .copy_path = &.{}, .library = null, .game = undefined, .state = null, .panels = &.{}, .manifest_arena = .init(gpa) };
        errdefer gpa.free(self.path);
        errdefer self.manifest_arena.deinit();
        try self.open();
        return self;
    }

    /// Start the game and its plugins, but those keyed in `off`, on `app`, whose world may
    /// already hold a scene, and run the world's Init stages. If a plugin fails to start
    /// (logged), the game stays stopped until the next swap.
    pub fn start(self: *HotGame, app: *eggy.App, off: []const []const u8) void {
        if (self.library == null or self.state != null) return;
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
    }

    /// Stop the game, empty the world, and unload the library.
    pub fn deinit(self: *HotGame, app: *eggy.App) void {
        self.close(app);
        self.manifest_arena.deinit();
        self.gpa.free(self.path);
    }

    /// Swap in the library rebuilt at `path`: stop the game and empty `app`'s world, unload the
    /// old library, and load the new one. Then put the scene back, `start` the game, and run
    /// `app.startWorld`. If the new library can't load, the editor carries on without a game
    /// until the next swap.
    pub fn reload(self: *HotGame, app: *eggy.App) !void {
        self.close(app);
        try self.open();
        log.info("swapped in the rebuilt game", .{});
    }

    /// Run a frame of the game and its world (playing), if it is running. Failures are logged
    /// by the library and don't stop it.
    pub fn update(self: *HotGame, app: *eggy.App) void {
        const state = self.state orelse return;
        _ = self.game.update(state, app);
    }

    /// Run a frame of the plugins' editor tools (not playing), if the game is running.
    pub fn editorUpdate(self: *HotGame, app: *eggy.App) void {
        const state = self.state orelse return;
        _ = self.game.editor_update(state, app);
    }

    /// Start the game over on `scene` without reloading it: stop its plugins, empty the world,
    /// put `scene` in, and start them again (with the world's Init stages), but those keyed in
    /// `off`. Stopping play does this, so nothing that happened while playing stays.
    pub fn restart(self: *HotGame, app: *eggy.App, scene: *const eggy.scene.Scene, off: []const []const u8) void {
        if (self.library == null) return;
        if (self.state) |state| self.game.stop(state);
        self.state = null;
        app.resetWorld();
        if (scene.instantiate(self.gpa, &app.world, self.sceneAccess(), null)) |made| {
            self.gpa.free(made.entities);
        } else |err| log.err("cannot put the scene back: {t}", .{err});
        self.start(app, off);
    }

    pub fn event(self: *HotGame, app: *eggy.App, curr_event: eggy.Event) void {
        const state = self.state orelse return;
        _ = self.game.event(state, app, &curr_event);
    }

    pub fn editorUi(self: *HotGame, context: *eggy.ui.Context) void {
        const state = self.state orelse return context.muted("The game isn't running: see the Console. It starts again when its code is rebuilt.");
        self.game.editor_ui(state, context);
    }

    pub fn editorPanelUi(self: *HotGame, panel: usize, context: *eggy.ui.Context) void {
        const state = self.state orelse return;
        if (panel < self.panels.len) self.game.editor_panel_ui(state, panel, context);
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
        for (panels, game.panels[0..game.panel_count]) |*panel, source| panel.* = .{ .title = try gpa.dupeZ(u8, std.mem.span(source.title)) };

        const manifests = try copyManifests(self.manifest_arena.allocator(), game.preferences[0..game.preference_count]);
        const component_types = try copyComponentTypes(self.manifest_arena.allocator(), game.components[0..game.component_count]);
        const plugin_keys = try self.manifest_arena.allocator().alloc([:0]const u8, game.plugin_count);
        for (plugin_keys, game.plugin_keys[0..game.plugin_count]) |*key, source| key.* = try self.manifest_arena.allocator().dupeZ(u8, std.mem.span(source));
        self.* = .{ .gpa = gpa, .path = self.path, .copy_path = copy_path, .library = library, .game = game, .state = null, .panels = panels, .loads = self.loads, .preference_manifests = manifests, .component_types = component_types, .plugin_keys = plugin_keys, .manifest_arena = self.manifest_arena };
    }

    /// Stop the game, empty the world while its code is still loaded, and unload and delete the copy.
    fn close(self: *HotGame, app: *eggy.App) void {
        var library = self.library orelse return;
        if (self.state) |state| self.game.stop(state);
        self.state = null;
        app.resetWorld();
        // The types the game registered its preferences under go with its code.
        app.preference_values.forgetTypes();
        for (self.panels) |panel| self.gpa.free(panel.title);
        self.gpa.free(self.panels);
        self.panels = &.{};
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

    /// Whether `entity` of `app`'s world has component type `component` (of `component_types`).
    pub fn hasComponent(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize) bool {
        if (self.library == null or component >= self.component_types.len) return false;
        return self.game.has_component(&app.world, entityOf(entity), component);
    }

    /// Give `entity` component type `component` with its defaults; false if it couldn't (logged).
    pub fn addComponent(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize) bool {
        if (self.library == null or component >= self.component_types.len) return false;
        return self.game.add_component(&app.world, entityOf(entity), component);
    }

    pub fn removeComponent(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize) void {
        if (self.library == null or component >= self.component_types.len) return;
        self.game.remove_component(&app.world, entityOf(entity), component);
    }

    /// Field `field` of `entity`'s component `component` as ZON, in `buffer` (cut short with
    /// "..." when it doesn't fit); null if it can't be read.
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
    pub fn writeField(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize, field: usize, text: [:0]const u8) bool {
        if (self.library == null or component >= self.component_types.len) return false;
        return self.game.write_field(&app.world, entityOf(entity), component, field, text.ptr);
    }

    /// `entity`'s `eggy.Name` in `buffer`; null without one (or without a library).
    pub fn readName(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, buffer: []u8) ?[]const u8 {
        if (self.library == null) return null;
        const len = self.game.read_name(&app.world, entityOf(entity), buffer.ptr, buffer.len);
        if (len < 0) return null;
        return buffer[0..@intCast(len)];
    }

    /// Name `entity` `text`, or take its name away when `text` is empty.
    pub fn writeName(self: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, text: []const u8) void {
        if (self.library == null) return;
        self.game.write_name(&app.world, entityOf(entity), text.ptr, text.len);
    }

    /// The meshes of `app`'s world to draw, into `out`; none without a library.
    pub fn gatherMeshes(self: *const HotGame, app: *eggy.App, out: []eggy.mesh.Drawable) []eggy.mesh.Drawable {
        if (self.library == null) return out[0..0];
        return out[0..self.game.gather_meshes(&app.world, out.ptr, out.len)];
    }

    /// The typed steps scenes need, through the library (see `eggy.scene.Access`).
    pub fn sceneAccess(self: *const HotGame) eggy.scene.Access {
        return .{ .context = self, .vtable = &scene_vtable };
    }

    /// Whether the game is running: it started (a plugin's `init` failing stops it until the
    /// next swap).
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
            };
        }
        info.* = .{ .name = try arena.dupeZ(u8, std.mem.span(source.name)), .owner = try arena.dupeZ(u8, std.mem.span(source.owner)), .fields = fields, .addable = source.addable };
    }
    return infos;
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
