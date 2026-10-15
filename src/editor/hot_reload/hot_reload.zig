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
    /// The component types the game and plugins list, copied into `manifest_arena` too.
    component_types: []const eggy.components.Info = &.{},
    manifest_arena: std.heap.ArenaAllocator,
    /// How many copies this editor has loaded, which names the next one.
    loads: u32 = 0,

    /// Load the library at `path` (absolute) and start the game on `app`. Then run
    /// `app.startWorld`, once, as for any start.
    pub fn load(gpa: std.mem.Allocator, path: []const u8, app: *eggy.App) !HotGame {
        var self = HotGame{ .gpa = gpa, .path = try gpa.dupe(u8, path), .copy_path = &.{}, .library = null, .game = undefined, .state = null, .panels = &.{}, .manifest_arena = .init(gpa) };
        errdefer gpa.free(self.path);
        errdefer self.manifest_arena.deinit();
        try self.open(app);
        return self;
    }

    /// Stop the game, empty the world, and unload the library.
    pub fn deinit(self: *HotGame, app: *eggy.App) void {
        self.close(app);
        self.manifest_arena.deinit();
        self.gpa.free(self.path);
    }

    /// Swap in the library rebuilt at `path`: stop the game and empty `app`'s world, unload the
    /// old library, then load the new one and start the game again. Then run `app.startWorld`.
    /// If the new library can't load, the editor carries on without a game until the next swap.
    pub fn reload(self: *HotGame, app: *eggy.App) !void {
        self.close(app);
        try self.open(app);
        log.info("swapped in the rebuilt game", .{});
    }

    /// Run a frame of the game, if it is running.
    pub fn update(self: *HotGame, app: *eggy.App) void {
        const state = self.state orelse return;
        if (!self.game.update(state, app)) self.pause(app);
    }

    pub fn event(self: *HotGame, app: *eggy.App, curr_event: eggy.Event) void {
        const state = self.state orelse return;
        if (!self.game.event(state, app, &curr_event)) self.pause(app);
    }

    pub fn editorUi(self: *HotGame, context: *eggy.ui.Context) void {
        const state = self.state orelse return context.muted("The game isn't running: see the Console. It starts again when its code is rebuilt.");
        self.game.editor_ui(state, context);
    }

    pub fn editorPanelUi(self: *HotGame, panel: usize, context: *eggy.ui.Context) void {
        const state = self.state orelse return;
        if (panel < self.panels.len) self.game.editor_panel_ui(state, panel, context);
    }

    /// Copy the library, load the copy, and start the game.
    fn open(self: *HotGame, app: *eggy.App) !void {
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
        self.* = .{ .gpa = gpa, .path = self.path, .copy_path = copy_path, .library = library, .game = game, .state = null, .panels = panels, .loads = self.loads, .preference_manifests = manifests, .component_types = component_types, .manifest_arena = self.manifest_arena };
        self.state = game.start(&host, &self.gpa, app);
        if (self.state == null) log.err("the game didn't start: see the errors above. It starts again when its code is rebuilt.", .{});
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

    /// A hook or one of the world's systems failed (and the game logged why): stop the game,
    /// emptying its world, until the next swap.
    pub fn pause(self: *HotGame, app: *eggy.App) void {
        log.err("the game stopped after an error: see above. It starts again when its code is rebuilt.", .{});
        if (self.state) |state| self.game.stop(state);
        self.state = null;
        app.resetWorld();
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
