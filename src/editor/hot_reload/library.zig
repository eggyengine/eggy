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
    for (&list, Plugins.editor_panels) |*panel, editor_panel| panel.* = .{ .title = editor_panel.title.ptr };
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
            field.* = .{ .name = source.name.ptr, .kind = @intFromEnum(source.kind), .options = &frozen_options, .option_count = frozen_options.len, .editable = source.editable };
        }
        const frozen_fields = fields;
        component_type.* = .{ .name = info.name.ptr, .owner = info.owner.ptr, .fields = &frozen_fields, .field_count = frozen_fields.len, .addable = info.addable };
    }
    break :blk types;
};

const game = api.Game{
    .start = start,
    .stop = stop,
    .update = update,
    .editor_update = editorUpdate,
    .event = event,
    .editor_ui = editorUi,
    .editor_panel_ui = editorPanelUi,
    .panels = &panels,
    .panel_count = panels.len,
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
};

/// Names go through the same code the runtime uses (`eggy.scene.registryAccess`).
const access = eggy.scene.registryAccess(Plugins.Components);

export fn eggy_game() callconv(.c) *const api.Game {
    return &game;
}

fn start(editor: *const api.Host, gpa_ptr: *const anyopaque, app_ptr: *anyopaque) callconv(.c) ?*anyopaque {
    host = editor;
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(gpa_ptr));
    const state = gpa.create(State) catch return null;
    const app = appOf(app_ptr);
    const plugins = Plugins.init(gpa.*, app) catch |err| {
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
const Hook = enum { update, editor_update, event, world_start, world_update };
var failures: [std.meta.fields(Hook).len]?anyerror = @splat(null);

fn report(hook: Hook, err: anyerror) void {
    const last = &failures[@intFromEnum(hook)];
    if (last.*) |previous| if (previous == err) return;
    last.* = err;
    const what = switch (hook) {
        .update => "an update hook",
        .editor_update => "an editorUpdate hook",
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

fn editorUpdate(state_ptr: *anyopaque, app_ptr: *anyopaque) callconv(.c) bool {
    stateOf(state_ptr).plugins.editorUpdate(appOf(app_ptr)) catch |err| {
        report(.editor_update, err);
        return false;
    };
    recovered(.editor_update);
    return true;
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

fn editorUi(state_ptr: *anyopaque, context: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorUi(@ptrCast(@alignCast(context)));
}

fn editorPanelUi(state_ptr: *anyopaque, panel: usize, context: *anyopaque) callconv(.c) void {
    stateOf(state_ptr).plugins.editorPanelUi(panel, @ptrCast(@alignCast(context)));
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
