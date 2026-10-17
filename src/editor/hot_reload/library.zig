//! The root of a game's library: the game and its plugins (`eggy_project`), which the editor
//! loads, and swaps for a rebuilt one when their code changes, through `game_api.Game`. `addGame`
//! builds it for the editor only; the runtime compiles the game in.
const std = @import("std");
const eggy = @import("eggy");
const project = @import("eggy_project");
const api = @import("game_api.zig");

const Plugins = eggy.plugins.Set(project.plugins, &project.plugin_keys);

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
    for (&list, Plugins.editor_panels) |*panel, editor_panel| panel.* = .{ .key = editor_panel.key.ptr, .title = editor_panel.title.ptr };
    break :blk list;
};
const commands = blk: {
    var list: [Plugins.editor_commands.len]api.Command = undefined;
    for (&list, Plugins.editor_commands) |*command, source| command.* = .{ .key = source.key.ptr, .title = source.title.ptr };
    break :blk list;
};
const file_types = blk: {
    var list: [Plugins.editor_file_types.len]api.FileType = undefined;
    for (&list, Plugins.editor_file_types) |*file_type, source| file_type.* = .{
        .key = source.key.ptr,
        .title = source.title.ptr,
        .extension = source.extension.ptr,
        .contents = source.contents.ptr,
        .contents_len = source.contents.len,
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
            field.* = .{ .name = source.name.ptr, .kind = @intFromEnum(source.kind), .default = source.default.ptr, .options = &frozen_options, .option_count = frozen_options.len, .description = source.description.ptr };
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
            field.* = .{ .name = source.name.ptr, .kind = @intFromEnum(source.kind), .options = &frozen_options, .option_count = frozen_options.len, .editable = source.editable, .requires = source.requires.ptr, .accepts = @intFromEnum(source.accepts), .parts = source.parts.ptr, .part_count = source.parts.len };
        }
        const frozen_fields = fields;
        component_type.* = .{ .name = info.name.ptr, .owner = info.owner.ptr, .fields = &frozen_fields, .field_count = frozen_fields.len, .addable = info.addable, .dependencies = info.dependencies.ptr, .dependency_count = info.dependencies.len };
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
    .preferences = &preference_sets,
    .preference_count = preference_sets.len,
    .components = &component_types,
    .component_count = component_types.len,
    .has_component = hasComponent,
    .add_component = addComponent,
    .remove_component = removeComponent,
    .read_field = readField,
    .write_field = writeField,
    .read_name = readName,
    .write_name = writeName,
    .gather_meshes = gatherMeshes,
    .world_matrix = worldMatrix,
    .find_camera = findCamera,
};

/// Names go through the same code the runtime uses (`eggy.scene.registryAccess`).
const access = eggy.scene.registryAccess(Plugins.Components);

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
const Hook = enum { update, game_ui, draw, ui_event, editor_update, editor_ui, editor_panel_ui, editor_command, event, world_start, world_update };
var failures: [std.meta.fields(Hook).len]?anyerror = @splat(null);

fn report(hook: Hook, err: anyerror) void {
    const last = &failures[@intFromEnum(hook)];
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
        .editor_command => "an editorCommand hook",
        .event => "an event hook",
        .world_start => "a system in the world's Init stages",
        .world_update => "a system in the world's Update stages",
    };
    std.log.err("{s} failed: {t}. The game keeps running; this is logged again only if it fails differently.", .{ what, err });
}

fn recovered(hook: Hook) void {
    failures[@intFromEnum(hook)] = null;
}

fn stop(state_ptr: *anyopaque) callconv(.c) void {
    const state = stateOf(state_ptr);
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

fn hasComponent(world: *anyopaque, entity: api.Entity, component: usize) callconv(.c) bool {
    return Plugins.Components.has(worldOf(world), entityOf(entity), component);
}

fn addComponent(world: *anyopaque, entity: api.Entity, component: usize) callconv(.c) bool {
    Plugins.Components.add(worldOf(world), entityOf(entity), component) catch |err| {
        std.log.err("cannot add component {d}: {t}", .{ component, err });
        return false;
    };
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
    editor.log(@intFromEnum(level), scope_name.ptr, scope_name.len, text.ptr, text.len);
}
