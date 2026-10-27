//! The root of a game's library: the game and its plugins (`eggy_project`), which the editor
//! loads, and swaps for a rebuilt one when their code changes, through `game_api.Game`. `addGame`
//! builds it for the editor only; the runtime compiles the game in.
const std = @import("std");
const eggy = @import("eggy");
const project = @import("eggy_project");
const api = @import("game_api.zig");

/// The project's asset identities, which `AssetRef.init` resolves paths through at compile time.
pub const eggy_asset_ids = project.asset_ids;

const Plugins = eggy.plugins.Set(project.plugins, &project.plugin_keys);

/// The library's own log goes to the editor, which chooses what is shown (so every level is compiled in).
pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logThroughEditor };

/// The editor's side, from `start`; null before it.
var host: ?*const api.Host = null;

const State = struct {
    gpa: std.mem.Allocator,
    plugins: Plugins,
    /// The animation preview under way, if any; ended before the library unloads.
    preview: ?eggy.animation_preview.Preview = null,
};

const panels = blk: {
    var list: [Plugins.editor_panels.len]api.Panel = undefined;
    for (&list, Plugins.editor_panels) |*panel, editor_panel| panel.* = .{ .key = editor_panel.key.ptr, .title = editor_panel.title.ptr };
    break :blk list;
};
const commands = blk: {
    var list: [Plugins.editor_commands.len]api.Command = undefined;
    for (&list, Plugins.editor_commands) |*command, source| command.* = .{ .key = source.key.ptr, .title = source.title.ptr };
    break :blk list;
};
const bar_menus = blk: {
    var list: [Plugins.editor_menus.len]api.Menu = undefined;
    for (&list, Plugins.editor_menus) |*menu, source| menu.* = .{ .key = source.key.ptr, .title = source.title.ptr, .extends = if (source.extends) |builtin| @backingInt(builtin) else -1, .item_count = source.items.len };
    break :blk list;
};
const bar_menu_items = barItems(Plugins.editor_menus);
const bar_status_items = blk: {
    var list: [Plugins.editor_status_items.len]api.StatusItem = undefined;
    for (&list, Plugins.editor_status_items) |*status, source| status.* = .{ .key = source.key.ptr, .title = source.title.ptr, .side = @backingInt(source.side), .item_count = source.items.len };
    break :blk list;
};
const bar_status_menu_items = barItems(Plugins.editor_status_items);

/// Every entry's rows, one after another, as C data.
fn barItems(comptime owners: anytype) [barItemCount(owners)]api.MenuItem {
    var list: [barItemCount(owners)]api.MenuItem = undefined;
    var next: usize = 0;
    for (owners) |owner| for (owner.items) |source| {
        list[next] = .{ .key = source.key.ptr, .title = source.title.ptr, .shortcut = source.shortcut.ptr, .checkable = source.checkable };
        next += 1;
    };
    return list;
}

fn barItemCount(comptime owners: anytype) usize {
    var count: usize = 0;
    for (owners) |owner| count += owner.items.len;
    return count;
}
const file_types = blk: {
    var list: [Plugins.editor_file_types.len]api.FileType = undefined;
    for (&list, Plugins.editor_file_types) |*file_type, source| file_type.* = .{
        .key = source.key.ptr,
        .title = source.title.ptr,
        .extension = source.extension.ptr,
        .contents = source.contents.ptr,
        .contents_len = source.contents.len,
        .category = source.category.ptr,
    };
    break :blk list;
};
const ui_widgets = blk: {
    var list: [Plugins.ui_widgets.len]api.UiWidget = undefined;
    for (&list, Plugins.ui_widgets) |*widget, source| widget.* = .{ .key = source.key.ptr, .title = source.title.ptr };
    break :blk list;
};
const export_platforms = blk: {
    var list: [Plugins.export_platforms.len]api.ExportPlatform = undefined;
    for (&list, Plugins.export_platforms) |*platform, source| platform.* = .{
        .key = source.key.ptr,
        .title = source.title.ptr,
        .target = source.target.ptr,
        .note = source.note.ptr,
        .icon_png = source.icon_png.ptr,
        .icon_png_len = source.icon_png.len,
    };
    break :blk list;
};

/// Each plugin's preferences, as C data.
const preference_sets = blk: {
    const manifests = Plugins.preference_manifests;
    var sets: [manifests.len]api.Preferences = undefined;
    for (&sets, manifests) |*set, manifest| {
        var fields: [manifest.fields.len]api.PreferenceField = undefined;
        for (&fields, manifest.fields) |*field, source| {
            var options: [source.options.len][*:0]const u8 = undefined;
            for (&options, source.options) |*option, name| option.* = name.ptr;
            const frozen_options = options;
            field.* = .{ .name = source.name.ptr, .kind = @backingInt(source.kind), .default = source.default.ptr, .options = &frozen_options, .option_count = frozen_options.len, .description = source.description.ptr };
        }
        const frozen_fields = fields;
        set.* = .{ .key = manifest.key.ptr, .fields = &frozen_fields, .field_count = frozen_fields.len };
    }
    break :blk sets;
};

/// The component types, as C data.
const component_types = blk: {
    const infos = Plugins.Components.infos;
    var types: [infos.len]api.ComponentType = undefined;
    for (&types, infos) |*component_type, info| {
        var fields: [info.fields.len]api.ComponentField = undefined;
        for (&fields, info.fields) |*field, source| {
            var options: [source.options.len][*:0]const u8 = undefined;
            for (&options, source.options) |*option, name| option.* = name.ptr;
            const frozen_options = options;
            field.* = .{ .name = source.name.ptr, .kind = @backingInt(source.kind), .options = &frozen_options, .option_count = frozen_options.len, .editable = source.editable, .requires = source.requires.ptr, .accepts = @backingInt(source.accepts), .parts = source.parts.ptr, .part_count = source.parts.len };
        }
        const frozen_fields = fields;
        component_type.* = .{ .name = info.name.ptr, .owner = info.owner.ptr, .fields = &frozen_fields, .field_count = frozen_fields.len, .addable = info.addable, .dependencies = info.dependencies.ptr, .dependency_count = info.dependencies.len, .icon = info.icon.ptr, .category = info.category.ptr };
    }
    break :blk types;
};

const plugin_keys = blk: {
    var list: [project.plugin_keys.len][*:0]const u8 = undefined;
    for (&list, project.plugin_keys) |*pointer, key| pointer.* = key.ptr;
    break :blk list;
};

const game = api.Game{
    .start = start,
    .plugin_keys = &plugin_keys,
    .plugin_count = plugin_keys.len,
    .stop = stop,
    .update = update,
    .has_game_ui = hasGameUi,
    .has_draw = hasDraw,
    .game_ui = gameUi,
    .draw = draw,
    .ui_event = uiEvent,
    .editor_update = editorUpdate,
    .event = event,
    .editor_ui = editorUi,
    .editor_panel_ui = editorPanelUi,
    .panels = &panels,
    .panel_count = panels.len,
    .commands = &commands,
    .command_count = commands.len,
    .file_types = &file_types,
    .file_type_count = file_types.len,
    .editor_command = editorCommand,
    .menus = &bar_menus,
    .menu_count = bar_menus.len,
    .menu_items = &bar_menu_items,
    .menu_item_count = bar_menu_items.len,
    .status_items = &bar_status_items,
    .status_item_count = bar_status_items.len,
    .status_menu_items = &bar_status_menu_items,
    .status_menu_item_count = bar_status_menu_items.len,
    .bar_action = barAction,
    .bar_state = barState,
    .export_platforms = &export_platforms,
    .export_platform_count = export_platforms.len,
    .export_ui = exportUi,
    .export_args = exportArgs,
    .preferences = &preference_sets,
    .preference_count = preference_sets.len,
    .components = &component_types,
    .component_count = component_types.len,
    .has_component = hasComponent,
    .add_component = addComponent,
    .remove_component = removeComponent,
    .read_field = readField,
    .read_field_alloc = readFieldAlloc,
    .write_field = writeField,
    .read_name = readName,
    .write_name = writeName,
    .gather_meshes = gatherMeshes,
    .gather_lights = gatherLights,
    .gather_ui_scenes = gatherUiScenes,
    .ui_widgets = &ui_widgets,
    .ui_widget_count = ui_widgets.len,
    .world_matrix = worldMatrix,
    .find_camera = findCamera,
    .animation_preview_begin = animationPreviewBegin,
    .animation_preview_show = animationPreviewShow,
    .animation_preview_end = animationPreviewEnd,
    .animation_targets = animationTargets,
    .animation_transform = animationTransform,
    .animation_model = animationModel,
    .animation_assign = animationAssign,
};

/// Names go through the same code the runtime uses (`eggy.scene.registryAccess`).
const access = eggy.scene.registryAccess(Plugins.Components);

/// Expose the editor-only game ABI table to the dynamic-library host, without starting plugins.
/// The table, metadata and callbacks are library-owned and valid only until unload. Consumers
/// must check `version` before other table access, use the matching Eggy build, and stop/clear
/// every world containing library code before closing the library. No allocation or failure.
///
/// ```zig
/// // Host side, given an open better_dynlib.DynLib named library and this boundary's api module:
/// const entry = library.lookup(api.Entry, api.entry_symbol) orelse return error.NotAGameLibrary;
/// const table = entry(); // C ABI function-pointer call, not a library-local invocation.
/// if (table.version != api.version) return error.GameLibraryVersionMismatch;
/// ```
export fn eggy_game() callconv(.c) *const api.Game {
    return &game;
}

fn start(editor: *const api.Host, gpa_ptr: *const anyopaque, app_ptr: *anyopaque, enabled: [*]const bool) callconv(.c) ?*anyopaque {
    host = editor;
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(gpa_ptr));
    const state = gpa.create(State) catch return null;
    const app = appOf(app_ptr);
    app.scene_access = access;
    const plugins = Plugins.init(gpa.*, app, enabled[0..plugin_keys.len].*) catch |err| {
        std.log.err("the game failed to start: {t}", .{err});
        gpa.destroy(state);
        return null;
    };
    state.* = .{ .gpa = gpa.*, .plugins = plugins };
    failures = @splat(null);
    // The world's Init stages, for the schedules the plugins just registered.
    app.startWorld() catch |err| report(.world_start, err);
    return state;
}

/// What can fail each frame, and the error each last failed with: one failing every frame is
/// logged once, and again only when it fails differently or after it recovers.
const Hook = enum { update, game_ui, draw, ui_event, editor_update, editor_ui, editor_panel_ui, editor_command, bar_action, bar_state, export_ui, export_args, event, world_start, world_update, scene_lights };
var failures: [@typeInfo(Hook).@"enum".field_names.len]?anyerror = @splat(null);

fn report(hook: Hook, err: anyerror) void {
    const last = &failures[@backingInt(hook)];
    if (last.*) |previous| if (previous == err) return;
    last.* = err;
    const what = switch (hook) {
        .update => "an update hook",
        .game_ui => "a gameUi hook",
        .draw => "a draw hook",
        .ui_event => "a uiEvent hook",
        .editor_update => "an editorUpdate hook",
        .editor_ui => "an editorUi hook",
        .editor_panel_ui => "an editorPanelUi hook",
        .export_ui => "an exportUi hook",
        .export_args => "an exportArgs hook",
        .editor_command => "an editorCommand hook",
        .bar_action => "an editorBarAction hook",
        .bar_state => "an editorBarState hook",
        .event => "an event hook",
        .world_start => "a system in the world's Init stages",
        .world_update => "a system in the world's Update stages",
        .scene_lights => "gathering scene lights",
    };
    const detail = if (err == error.SdlError) eggy.sdl_adapter.sdl.errors.get() else null;
    std.log.err("{s} failed: {t}{s}{s}. The game keeps running; this is logged again only if it fails differently.", .{ what, err, if (detail != null) ": " else "", detail orelse "" });
}

fn recovered(hook: Hook) void {
    failures[@backingInt(hook)] = null;
}

fn stop(state_ptr: *anyopaque) callconv(.c) void {
    const state = stateOf(state_ptr);
    // The world may already be gone: free the snapshot without restoring it.
    if (state.preview) |preview| state.gpa.free(preview.saved);
    state.plugins.deinit();
    state.gpa.destroy(state);
}

fn update(state_ptr: *anyopaque, app_ptr: *anyopaque) callconv(.c) bool {
    const app = appOf(app_ptr);
    var ok = true;
    if (stateOf(state_ptr).plugins.update(app)) recovered(.update) else |err| {
        report(.update, err);
        ok = false;
    }
    // The world's systems run here, where their errors have their names.
    if (app.updateWorld()) recovered(.world_update) else |err| {
        report(.world_update, err);
        ok = false;
    }
    return ok;
}

fn editorUpdate(state_ptr: *anyopaque, editor_ptr: *anyopaque) callconv(.c) bool {
    stateOf(state_ptr).plugins.editorUpdate(@ptrCast(@alignCast(editor_ptr))) catch |err| {
        report(.editor_update, err);
        return false;
    };
    recovered(.editor_update);
    return true;
}

fn hasGameUi(state: *anyopaque) callconv(.c) bool {
    return stateOf(state).plugins.hasGameUi();
}

fn hasDraw(state: *anyopaque) callconv(.c) bool {
    return stateOf(state).plugins.hasDraw();
}

fn gameUi(state_ptr: *anyopaque, app_ptr: *anyopaque, context: *anyopaque) callconv(.c) bool {
    stateOf(state_ptr).plugins.gameUi(appOf(app_ptr), @ptrCast(@alignCast(context))) catch |err| {
        report(.game_ui, err);
        return false;
    };
    recovered(.game_ui);
    return true;
}

fn draw(state_ptr: *anyopaque, app_ptr: *anyopaque, context: *const anyopaque) callconv(.c) bool {
    const target: *const eggy.DrawContext = @ptrCast(@alignCast(context));
    stateOf(state_ptr).plugins.draw(appOf(app_ptr), target.*) catch |err| {
        report(.draw, err);
        return false;
    };
    recovered(.draw);
    return true;
}

fn uiEvent(state_ptr: *anyopaque, app_ptr: *anyopaque, event_ptr: *const anyopaque) callconv(.c) i32 {
    const input: *const eggy.Event = @ptrCast(@alignCast(event_ptr));
    const consumed = stateOf(state_ptr).plugins.uiEvent(appOf(app_ptr), input.*) catch |err| {
        report(.ui_event, err);
        return -1;
    };
    recovered(.ui_event);
    return if (consumed) 1 else 0;
}

fn event(state_ptr: *anyopaque, app_ptr: *anyopaque, event_ptr: *const anyopaque) callconv(.c) bool {
    const curr_event: *const eggy.Event = @ptrCast(@alignCast(event_ptr));
    stateOf(state_ptr).plugins.event(appOf(app_ptr), curr_event.*) catch |err| {
        report(.event, err);
        return false;
    };
    recovered(.event);
    return true;
}

fn editorUi(state_ptr: *anyopaque, editor_ptr: *anyopaque, context: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorUi(@ptrCast(@alignCast(editor_ptr)), @ptrCast(@alignCast(context))) catch |err| return report(.editor_ui, err);
    recovered(.editor_ui);
}

fn editorPanelUi(state_ptr: *anyopaque, panel: usize, editor_ptr: *anyopaque, context: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorPanelUi(panel, @ptrCast(@alignCast(editor_ptr)), @ptrCast(@alignCast(context))) catch |err| return report(.editor_panel_ui, err);
    recovered(.editor_panel_ui);
}

fn editorCommand(state_ptr: *anyopaque, command: usize, editor_ptr: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorCommand(command, @ptrCast(@alignCast(editor_ptr))) catch |err| return report(.editor_command, err);
    recovered(.editor_command);
}

fn barTarget(kind: api.BarKind, owner: usize, item: usize) eggy.plugins.EditorBarTarget {
    return switch (kind) {
        .menu_item => .{ .menu_item = .{ .menu = owner, .item = item } },
        .status => .{ .status = owner },
        .status_item => .{ .status_item = .{ .status = owner, .item = item } },
    };
}

fn barAction(state_ptr: *anyopaque, kind: api.BarKind, owner: usize, item: usize, editor_ptr: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorBarAction(barTarget(kind, owner, item), @ptrCast(@alignCast(editor_ptr))) catch |err| {
        // A turned-off plugin's entry is shown greyed out; pressing it is not a failure.
        if (err != error.PluginDisabled) report(.bar_action, err);
        return;
    };
    recovered(.bar_action);
}

fn barState(state_ptr: *anyopaque, kind: api.BarKind, owner: usize, item: usize, editor_ptr: *anyopaque, out: *anyopaque) callconv(.c) bool {
    const bar_state: *eggy.plugins.EditorBarState = @ptrCast(@alignCast(out));
    stateOf(state_ptr).plugins.editorBarState(barTarget(kind, owner, item), @ptrCast(@alignCast(editor_ptr)), bar_state) catch |err| {
        report(.bar_state, err);
        bar_state.* = .{};
        return false;
    };
    recovered(.bar_state);
    return true;
}

fn exportUi(state_ptr: *anyopaque, platform: usize, target_ptr: [*]const u8, target_len: usize, editor_ptr: *anyopaque, context: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.exportUi(platform, target_ptr[0..target_len], @ptrCast(@alignCast(editor_ptr)), @ptrCast(@alignCast(context))) catch |err| return report(.export_ui, err);
    recovered(.export_ui);
}

/// Logged every time: each call is an export the person asked for, not a frame.
fn exportArgs(state_ptr: *anyopaque, platform: usize, target_ptr: [*]const u8, target_len: usize, args: *anyopaque) callconv(.c) bool {
    stateOf(state_ptr).plugins.exportArgs(platform, target_ptr[0..target_len], @ptrCast(@alignCast(args))) catch |err| {
        std.log.err("an exportArgs hook failed: {t}", .{err});
        return false;
    };
    return true;
}

fn hasComponent(world: *anyopaque, entity: api.Entity, component: usize) callconv(.c) bool {
    return Plugins.Components.has(worldOf(world), entityOf(entity), component);
}

fn addComponent(world: *anyopaque, entity: api.Entity, component: usize) callconv(.c) bool {
    const had_light = worldOf(world).get(entityOf(entity), eggy.SceneLight) != null;
    Plugins.Components.add(worldOf(world), entityOf(entity), component) catch |err| {
        std.log.err("cannot add component {d}: {t}", .{ component, err });
        return false;
    };
    if (!had_light) eggy.lighting.aimNewLight(worldOf(world), entityOf(entity));
    return true;
}

fn removeComponent(world: *anyopaque, entity: api.Entity, component: usize) callconv(.c) void {
    Plugins.Components.remove(worldOf(world), entityOf(entity), component);
}

fn readField(world: *anyopaque, entity: api.Entity, component: usize, field: usize, buffer: [*]u8, capacity: usize) callconv(.c) usize {
    var writer: std.Io.Writer = .fixed(buffer[0..capacity]);
    Plugins.Components.writeField(worldOf(world), entityOf(entity), component, field, &writer) catch |err| return switch (err) {
        error.WriteFailed => capacity + 1,
        else => 0,
    };
    return writer.end;
}

fn readFieldAlloc(world: *anyopaque, allocator: *const anyopaque, entity: api.Entity, component: usize, field: usize, out: *api.FieldBytes) callconv(.c) api.FieldStatus {
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(allocator));
    const text = access.readFieldAlloc(gpa.*, worldOf(world), entityOf(entity), component, field) catch |err| return switch (err) {
        error.NoComponent => .no_component,
        error.NoSuchComponent => .no_such_component,
        error.OutOfMemory => .out_of_memory,
    };
    out.* = .{ .ptr = text.ptr, .len = text.len };
    return .ok;
}

fn writeField(world: *anyopaque, entity: api.Entity, component: usize, field: usize, text: [*:0]const u8) callconv(.c) bool {
    Plugins.Components.setField(worldOf(world), entityOf(entity), component, field, std.mem.span(text)) catch return false;
    return true;
}

fn readName(world: *anyopaque, entity: api.Entity, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    const name = access.name(worldOf(world), entityOf(entity), buffer[0..capacity]) orelse return -1;
    return @intCast(name.len);
}

fn writeName(world: *anyopaque, entity: api.Entity, text: [*]const u8, len: usize) callconv(.c) void {
    access.setName(worldOf(world), entityOf(entity), text[0..len]);
}

fn gatherMeshes(world: *anyopaque, out: [*]eggy.mesh.Drawable, capacity: usize) callconv(.c) usize {
    return eggy.mesh.gather(worldOf(world), out[0..capacity]);
}

fn gatherLights(world: *anyopaque, out: *eggy.lighting.Frame) callconv(.c) bool {
    const frame = eggy.lighting.gather(worldOf(world)) catch |err| {
        report(.scene_lights, err);
        return false;
    };
    out.* = frame;
    recovered(.scene_lights);
    eggy.lighting.reportInvalid(frame, &invalid_lights_reported);
    return true;
}

fn gatherUiScenes(state_ptr: *anyopaque, app_ptr: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.gatherUiScenes(appOf(app_ptr));
}

/// How many invalid lights were last reported, so the warning comes once per change.
var invalid_lights_reported: u32 = 0;

fn worldMatrix(world: *anyopaque, entity: api.Entity, out: *[4][4]f32) callconv(.c) bool {
    const id = entityOf(entity);
    if (!worldOf(world).isAlive(id)) return false;
    for (out, eggy.transform.worldMatrix(worldOf(world), id).data) |*column, data| column.* = data;
    return true;
}

fn findCamera(world: *anyopaque, out: *eggy.camera.View) callconv(.c) bool {
    out.* = eggy.camera.find(worldOf(world)) orelse return false;
    return true;
}

fn animationPreviewBegin(state_ptr: *anyopaque, world: *anyopaque, entity: api.Entity) callconv(.c) bool {
    const state = stateOf(state_ptr);
    animationPreviewEnd(state_ptr, world);
    state.preview = eggy.animation_preview.Preview.begin(state.gpa, worldOf(world), entityOf(entity)) catch |err| {
        std.log.err("cannot preview animation: {t}", .{err});
        return false;
    };
    return true;
}

fn animationPreviewShow(state_ptr: *anyopaque, world: *anyopaque, clips: *anyopaque, clip: [*:0]const u8, model_clip: [*:0]const u8, time_s: f32) callconv(.c) bool {
    const preview = stateOf(state_ptr).preview orelse return false;
    const cache: *eggy.ClipCache = @ptrCast(@alignCast(clips));
    preview.show(worldOf(world), cache, .{ .clip = std.mem.span(clip), .model_clip = std.mem.span(model_clip), .time_s = time_s }) catch |err| {
        std.log.err("cannot show the animation: {t}", .{err});
        return false;
    };
    return true;
}

fn animationPreviewEnd(state_ptr: *anyopaque, world: *anyopaque) callconv(.c) void {
    const state = stateOf(state_ptr);
    var preview = state.preview orelse return;
    state.preview = null;
    preview.end(worldOf(world));
}

fn animationTargets(world: *anyopaque, entity: api.Entity, buffer: [*]u8, capacity: usize) callconv(.c) usize {
    var writer = std.Io.Writer.fixed(buffer[0..capacity]);
    var total: usize = 0;
    // Count everything written, even past the buffer, so the host can ask again with more room.
    var counting = std.Io.Writer.Discarding.init(&.{});
    eggy.animation_preview.writeTargets(worldOf(world), entityOf(entity), &counting.writer) catch return 0;
    total = @intCast(counting.fullCount());
    eggy.animation_preview.writeTargets(worldOf(world), entityOf(entity), &writer) catch {};
    return total;
}

fn animationTransform(world: *anyopaque, entity: api.Entity, path: [*]const u8, path_len: usize, out: *[9]f32) callconv(.c) bool {
    out.* = eggy.animation_preview.transformAt(worldOf(world), entityOf(entity), path[0..path_len]) orelse return false;
    return true;
}

fn animationModel(world: *anyopaque, entity: api.Entity, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    const mesh = worldOf(world).get(entityOf(entity), eggy.Mesh) orelse return -1;
    const model = switch (mesh.shape) {
        .model => |drawn| drawn.key(),
        else => return -1,
    };
    @memcpy(buffer[0..@min(model.len, capacity)], model[0..@min(model.len, capacity)]);
    return @intCast(model.len);
}

fn animationAssign(world: *anyopaque, entity: api.Entity, clip: [*:0]const u8, imported: bool) callconv(.c) bool {
    const asset = eggy.refs.AssetRef(.animation).parse(std.mem.span(clip)) catch return false;
    const playing: eggy.animation.Clip = if (imported) .{ .imported = asset } else .{ .asset = asset };
    (eggy.animation.Animation{ .world = worldOf(world) }).play(entityOf(entity), playing, .{ .repeat = .loop }) catch return false;
    return true;
}

fn worldOf(ptr: *anyopaque) *eggy.ecs.World {
    return @ptrCast(@alignCast(ptr));
}

fn entityOf(entity: api.Entity) eggy.ecs.EntityId {
    return .init(entity.id, entity.generation);
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
    editor.log(@backingInt(level), scope_name.ptr, scope_name.len, text.ptr, text.len);
}
