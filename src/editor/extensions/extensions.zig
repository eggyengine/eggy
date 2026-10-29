//! Synchronous editor services for game-library hooks.
const std = @import("std");
const eggy = @import("eggy");
const api = eggy.editor;
const settings = @import("../project_settings.zig");
const file_ops = @import("../assets/file_ops.zig");
const history = @import("../history.zig");
const workspace = @import("../workspace.zig");
const ProjectFlow = @import("../projects/flow.zig").ProjectFlow;
const ExportWindow = @import("../export/export.zig").ExportWindow;
const layout_file = @import("../layout_file.zig");
const console_log = @import("../console_log.zig");
const entity_snapshot = @import("../entities/snapshot.zig");
const sdl = eggy.sdl_adapter.sdl;

/// Owns snapshots only; it never retains game-library callbacks or component pointers.
pub const State = struct {
    before: ?[]u8 = null,
    pending: ?api.Operation = null,
    /// When play started or resumed by a tool pauses by itself (`play`'s seconds), in ms.
    pause_at_ms: ?u64 = null,
    /// `pending`'s seconds, for play and resume.
    pending_seconds: f64 = 0,
    /// The last build a tool asked for, its output's end (owned), and whether its Build window
    /// still waits to close by itself.
    build: @FieldType(api.EditorStatus, "build") = .none,
    build_log: ?[]u8 = null,
    closes_build_window: bool = false,
    /// Free an editor extension's pending snapshot with its allocating `gpa`, then reset state.
    /// Host-only: discards queued lifecycle work; it does not restore the world or cancel an
    /// already-recorded history group. Safe to call again on the reset state.
    ///
    /// ```zig
    /// extension_state.deinit(gpa); // Host State and its snapshot allocator.
    /// ```
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.before) |before| gpa.free(before);
        if (self.build_log) |log| gpa.free(log);
        self.* = .{};
    }

    /// Drop an open edit's snapshot (`begin_edit`), keeping the rest.
    pub fn cancelEdit(self: *State, gpa: std.mem.Allocator) void {
        if (self.before) |before| gpa.free(before);
        self.before = null;
    }

    /// Keep the outcome of a build a tool asked for (the end of `log`), once it finishes.
    /// Host-only: call when the editor's rebuild reaches `done` or `failed`; others are ignored.
    pub fn noteBuild(self: *State, gpa: std.mem.Allocator, failed: bool, log: []const u8) void {
        if (self.build != .building) return;
        const kept_bytes = 64 * 1024;
        if (self.build_log) |old| gpa.free(old);
        self.build_log = gpa.dupe(u8, log[log.len -| kept_bytes..]) catch null;
        self.build = if (failed) .failed else .succeeded;
    }

    /// Whether play a tool started is due to pause now, at `now_ms`; forgets it once due.
    pub fn pauseDue(self: *State, now_ms: u64) bool {
        const at = self.pause_at_ms orelse return false;
        if (now_ms < at) return false;
        self.pause_at_ms = null;
        return true;
    }

    /// Take a lifecycle request only after game-library hooks have returned.
    /// Host-only: clears the single queued request, returning its workspace outcome or null.
    /// Queue only lifecycle operations; any other stored operation is unreachable.
    ///
    /// ```zig
    /// // After all hooks return, given the host's extension State:
    /// const request = extension_state.takeRequest();
    /// ```
    pub fn takeRequest(self: *State) ?workspace.Outcome {
        const request = self.pending orelse return null;
        self.pending = null;
        return switch (request) {
            .request_build => .build_project,
            .request_reload => .reload,
            .show_export => .export_game,
            .show_new_project => .new_project,
            .show_open_project => .open_project,
            .undo => .undo,
            .redo => .redo,
            .play => .{ .play = true },
            .stop_play => .{ .play = false },
            .pause => .{ .pause = true },
            .resume_play => .{ .pause = false },
            else => unreachable,
        };
    }
};

/// Start existing desktop workflows only after the requesting library hook has unwound.
/// True means the editor's reload workflow launched its replacement.
/// Host-only: `host` is the concrete editor pointer providing the workflow fields/methods
/// used here, not a plugin context. May start builds, create windows or open a folder picker;
/// cancelled navigation returns false, and busy/no-project/invalid-request/I/O errors propagate.
/// Never call while a game hook or extension edit transaction is on the stack.
///
/// ```zig
/// // Given the concrete editor pointer after game-library hooks unwind:
/// if (editor.extension_state.takeRequest()) |request| {
///     const replaced = try processRequest(editor, request);
///     _ = replaced; // Quit the old editor if its replacement launched.
/// }
/// ```
pub fn processRequest(host: anytype, request: workspace.Outcome) !bool {
    const seconds = host.extension_state.pending_seconds;
    host.extension_state.pending_seconds = 0;
    switch (request) {
        .build_project => {
            if (host.project == null) return error.NoProject;
            if (host.buildRunning()) return error.EditorBusy;
            host.cancelBuild();
            try host.startBuild(.rebuild);
            host.extension_state.build = .building;
            host.extension_state.closes_build_window = true;
        },
        .undo => host.undoOrRedo(.undo),
        .redo => host.undoOrRedo(.redo),
        .play => |on| {
            if (on) host.startPlaying() else host.stopPlaying();
            host.extension_state.pause_at_ms = if (on and seconds > 0) sdl.timer.getMillisecondsSinceInit() + @as(u64, @intFromFloat(seconds * 1000)) else null;
        },
        .pause => |paused| {
            if (!host.play_mode.playing()) return error.NotPlaying;
            host.setPaused(paused);
            host.extension_state.pause_at_ms = if (!paused and seconds > 0) sdl.timer.getMillisecondsSinceInit() + @as(u64, @intFromFloat(seconds * 1000)) else null;
        },
        .reload => return host.forceReload(),
        .export_game => {
            const project = host.project orelse return error.NoProject;
            if (host.export_window != null) return error.EditorBusy;
            host.export_window = try ExportWindow.open(host.gpa, &host.app.graphics, host.ui.font, host.mono, project.dir);
        },
        .new_project => {
            if (!host.mayLeave(.new_project)) return false;
            layout_file.save(host.gpa, host.preference_folders.global, &host.workspace.dock, &host.workspace.tabs, host.workspace.seen_plugin_panels.items);
            host.project_flow = try ProjectFlow.create(host.gpa, &host.app.graphics, host.ui.font, host.mono);
        },
        .open_project => if (host.mayLeave(.open_project)) {
            host.picking_to_link = false;
            sdl.dialog.showOpenFolder(@TypeOf(host.*), @TypeOf(host.*).pickedProject, host, host.app.window.window, null, false);
        },
        else => return error.InvalidEditorRequest,
    }
    return false;
}

/// Construct a hook-local view after the concrete editor has reached its final address.
/// Host-only: `editor` must be a pointer to the concrete editor with extension/history/project
/// services. The view borrows it and its App; never retain it in a plugin or move the editor.
/// Requests run synchronously except lifecycle work, which is queued for after hooks unwind.
///
/// ```zig
/// // Given a stably stored concrete editor pointer and loaded HotGame pointer:
/// var view = context(editor);
/// game.editorUpdate(&view);
/// ```
pub fn context(editor: anytype) api.Context {
    const Through = struct {
        fn request(raw: *anyopaque, input: *const api.Request, output: *api.Response) callconv(.c) api.Status {
            const host: @TypeOf(editor) = @ptrCast(@alignCast(raw));
            apply(host, input.*, output) catch |err| {
                std.log.err("editor extension {t} failed: {t}", .{ input.operation, err });
                return switch (err) {
                    error.OutOfMemory => .out_of_memory,
                    error.InvalidEntity => .invalid_entity,
                    error.NoProject => .no_project,
                    error.NotEditing => .not_editing,
                    error.EditorBusy, error.GroupAlreadyOpen => .busy,
                    error.BufferTooSmall => .buffer_too_small,
                    else => .failed,
                };
            };
            return .ok;
        }
    };
    return .{ .app = &editor.app, .host = .{ .context = editor, .request = Through.request } };
}

fn apply(host: anytype, request: api.Request, response: *api.Response) !void {
    const text = request.text[0..request.text_len];
    const extra = request.extra[0..request.extra_len];
    switch (request.operation) {
        .request_build, .request_reload, .show_export, .show_new_project, .show_open_project, .undo, .redo, .play, .pause, .resume_play, .stop_play => {
            if (host.extension_state.pending != null or host.extension_state.before != null or host.history.group != null or host.build_window != null or host.project_flow != null) return error.EditorBusy;
            if (request.operation != .show_new_project and request.operation != .show_open_project and host.project == null) return error.NoProject;
            host.extension_state.pending = request.operation;
            host.extension_state.pending_seconds = if (std.math.isFinite(request.number)) @max(0, request.number) else 0;
            return;
        },
        .status => {
            const state = &host.extension_state;
            const activity = &host.activity;
            const now_ms = sdl.timer.getMillisecondsSinceInit();
            var written: std.Io.Writer.Allocating = .init(host.gpa);
            defer written.deinit();
            try std.zon.stringify.serialize(api.EditorStatus{
                .open_scene = if (host.open_scene) |*scene| scene.path else null,
                .unsaved = host.workspace.scene_unsaved,
                .play = if (!host.play_mode.playing()) .editing else if (host.play_mode.paused) .paused else .playing,
                .build = state.build,
                .build_log = state.build_log orelse "",
                .undo = if (host.history.peek(.undo)) |step| step.describe() else null,
                .redo = if (host.history.peek(.redo)) |step| step.describe() else null,
                .idle_ms = now_ms -| activity.last_input_ms,
                .unfocused_ms = if (activity.focus_lost_ms) |lost_ms| now_ms -| lost_ms else null,
                .saves = activity.saves,
                .plays = activity.plays,
                .builds = activity.builds,
            }, .{}, &written.writer);
            return respondText(request, response, written.written());
        },
        .scene_text => {
            const scene = try snapshot(host);
            defer host.gpa.free(scene);
            return respondText(request, response, scene);
        },
        .component_types => {
            const types = try componentTypes(host);
            defer host.gpa.free(types);
            return respondText(request, response, types);
        },
        .console_text => {
            const messages = try consoleText(host.gpa, if (std.math.isFinite(request.number)) @intFromFloat(std.math.clamp(request.number, 1, 10_000)) else 200);
            defer host.gpa.free(messages);
            return respondText(request, response, messages);
        },
        .selection => {
            host.entity_editor.forgetDead(&host.app);
            if (host.entity_editor.selected) |entity| {
                response.has_entity = true;
                response.entity = .{ .id = entity.id, .generation = entity.generation };
            }
            return;
        },
        .show_panel => return host.workspace.showPluginPanel(text),
        .select => {
            const entity = eggy.ecs.EntityId.init(request.entity.id, request.entity.generation);
            if (request.has_entity and !host.app.world.isAlive(entity)) return error.InvalidEntity;
            host.entity_editor.selected = if (request.has_entity) entity else null;
            return;
        },
        .project_folder => {
            const project = host.project orelse return error.NoProject;
            response.length = project.dir.len;
            if (request.capacity == 0) return;
            if (project.dir.len > request.capacity) return error.BufferTooSmall;
            @memcpy(request.buffer[0..project.dir.len], project.dir);
            return;
        },
        .project_settings => {
            const project = host.project orelse return error.NoProject;
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var dir = try std.Io.Dir.cwd().openDir(io, project.dir, .{});
            defer dir.close(io);
            const source = try dir.readFileAlloc(io, eggy.project.file_name, host.gpa, .limited(1 << 20));
            defer host.gpa.free(source);
            response.length = source.len;
            if (request.capacity == 0) return;
            if (source.len > request.capacity) return error.BufferTooSmall;
            @memcpy(request.buffer[0..source.len], source);
            return;
        },
        else => {},
    }
    if (host.play_mode.playing()) return error.NotEditing;
    switch (request.operation) {
        .begin_edit => try beginEdit(host),
        .commit_edit => if (!try commitEdit(host)) return error.ComponentNotInScene,
        .cancel_edit => host.extension_state.cancelEdit(host.gpa),
        .begin_group => {
            if (host.input_settings) |controls| try controls.recordPending(&host.history);
            try host.history.beginGroup(text);
        },
        .commit_group => {
            if (host.input_settings) |controls| try controls.recordPending(&host.history);
            try host.history.commitGroup();
        },
        .cancel_group => {
            if (host.input_settings) |controls| try controls.recordPending(&host.history);
            try host.history.cancelGroup(host, @TypeOf(host.*).carry);
            host.history.setBaseline(try snapshot(host));
        },
        .open_scene => {
            try eggy.refs.validatePath(text);
            try host.openSceneStep(.{ .open_scene = text });
        },
        .save_scene => try host.saveSceneForExtension(),
        .create_folder, .rename_file, .delete_file, .duplicate_file => {
            try eggy.refs.validatePath(text);
            if (text.len == 0 and request.operation != .create_folder) return error.InvalidPath;
            const project = host.project orelse return error.NoProject;
            try host.history.reserve();
            try host.changeFiles(project.dir, switch (request.operation) {
                .create_folder => .{ .create_folder = text },
                .rename_file => .{ .rename = .{ .path = text, .name = extra } },
                .delete_file => .{ .delete = text },
                .duplicate_file => .{ .duplicate = text },
                else => unreachable,
            });
        },
        .move_file, .copy_file, .import_file => {
            if (text.len == 0) return error.InvalidPath;
            if (request.operation != .import_file) try eggy.refs.validatePath(text);
            try eggy.refs.validatePath(extra);
            const project = host.project orelse return error.NoProject;
            try host.history.reserve();
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var files = try std.Io.Dir.cwd().openDir(io, project.dir, .{});
            defer files.close(io);
            if (request.operation == .move_file) {
                const from = try host.gpa.dupe(u8, text);
                errdefer host.gpa.free(from);
                const to = try file_ops.moveInto(host.gpa, io, files, text, extra);
                if (host.open_scene) |*scene| scene.moved(text, to);
                host.history.record(.{ .rename = .{ .from = from, .to = to } });
            } else {
                if (request.operation == .copy_file) {
                    host.history.record(.{ .create = .{ .path = try file_ops.copyInto(host.gpa, io, files, text, extra) } });
                } else {
                    host.history.record(try history.Step.created(host.gpa, try host.importFile(io, files, text, extra)));
                }
            }
            host.filesChanged();
        },
        .write_file => {
            try eggy.refs.validatePath(text);
            if (text.len == 0) return error.InvalidPath;
            const project = host.project orelse return error.NoProject;
            try host.history.reserve();
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var files = try std.Io.Dir.cwd().openDir(io, project.dir, .{});
            defer files.close(io);
            defer host.filesChanged();
            // An existing file keeps its old text for undo.
            if (files.readFileAlloc(io, text, host.gpa, .limited(16 << 20))) |before| {
                errdefer host.gpa.free(before);
                if (std.mem.eql(u8, before, extra)) return host.gpa.free(before);
                const path = try host.gpa.dupe(u8, text);
                errdefer host.gpa.free(path);
                const after = try host.gpa.dupe(u8, extra);
                errdefer host.gpa.free(after);
                try files.writeFile(io, .{ .sub_path = text, .data = extra });
                host.history.record(.{ .file_text = .{ .path = path, .text = .{ .before = before, .after = after } } });
                return;
            } else |err| if (err != error.FileNotFound) return err;
            // A new one is a creation: of its topmost new folder, so undo takes the folders too.
            const created = try host.gpa.dupe(u8, firstMissing(io, files, text));
            errdefer host.gpa.free(created);
            if (std.fs.path.dirnamePosix(text)) |folder| try files.createDirPath(io, folder);
            try files.writeFile(io, .{ .sub_path = text, .data = extra });
            host.history.record(.{ .create = .{ .path = created } });
        },
        .default_scene => {
            _ = try eggy.AssetRef(.scene).parse(text);
            const project = host.project orelse return error.NoProject;
            try host.history.reserve();
            if (try settings.setDefaultScene(host.gpa, project.dir, text)) |change| host.history.recordProjectSettings(change.before, change.after, host.workspace.time_ms);
        },
        .replace_scene, .add_to_scene => response.length = try changeScene(host, request.operation == .replace_scene, text, request.number),
        .selection, .select, .show_panel, .project_settings, .project_folder, .request_build, .request_reload, .show_export, .show_new_project, .show_open_project, .status, .scene_text, .component_types, .console_text, .undo, .redo, .play, .pause, .resume_play, .stop_play => unreachable,
    }
}

/// The shortest prefix of the project-relative `path` that doesn't exist yet in `files`.
fn firstMissing(io: std.Io, files: std.Io.Dir, path: []const u8) []const u8 {
    var end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
        files.access(io, path[0..slash], .{}) catch return path[0..slash];
    }
    return path;
}

test "a written file's first missing folder is what undo trashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, ".vscode");
    try std.testing.expectEqualStrings(".vscode/mcp.json", firstMissing(io, tmp.dir, ".vscode/mcp.json"));
    try std.testing.expectEqualStrings(".cursor", firstMissing(io, tmp.dir, ".cursor/rules/mcp.json"));
    try std.testing.expectEqualStrings(".mcp.json", firstMissing(io, tmp.dir, ".mcp.json"));
}

test "deferred workflow requests are taken once without retaining callbacks" {
    var state = State{ .pending = .request_reload };
    try std.testing.expectEqual(workspace.Outcome.reload, state.takeRequest().?);
    try std.testing.expect(state.takeRequest() == null);
    state.pending = .request_build;
    try std.testing.expectEqual(workspace.Outcome.build_project, state.takeRequest().?);
}

/// Open one undo step for a plugin Scene tool's stroke, from press to release: what it changes
/// in the world in between is undone together. A failure is logged and the stroke goes unrecorded.
pub fn beginStroke(host: anytype) void {
    beginEdit(host) catch |err| std.log.err("cannot record the Scene tool's stroke: {t}", .{err});
}

/// Close the stroke `beginStroke` opened, recording it when the world changed.
pub fn endStroke(host: anytype) void {
    if (host.extension_state.before == null) return;
    const recorded = commitEdit(host) catch |err| blk: {
        std.log.err("cannot record the Scene tool's stroke: {t}", .{err});
        break :blk false;
    };
    if (!recorded) host.extension_state.cancelEdit(host.gpa);
}

/// Start a scene edit: keep the world as it is now for the undo step `commitEdit` records.
fn beginEdit(host: anytype) !void {
    if (host.project == null) return error.NoProject;
    if (host.extension_state.before != null or host.extension_state.pending != null) return error.EditorBusy;
    try host.history.reserve();
    const before = try snapshot(host);
    errdefer host.gpa.free(before);
    host.history.watch(try host.gpa.dupe(u8, before), std.math.maxInt(u64), false);
    try host.history.reserve();
    host.extension_state.before = before;
}

/// Record the world since `beginEdit` as one undo step; false (the edit still open) when it
/// didn't change.
fn commitEdit(host: anytype) !bool {
    const before = host.extension_state.before orelse return error.EditorBusy;
    const after = try snapshot(host);
    errdefer host.gpa.free(after);
    if (std.mem.eql(u8, before, after)) {
        host.gpa.free(after);
        return false;
    }
    const baseline = try host.gpa.dupe(u8, after);
    host.extension_state.before = null;
    host.history.record(.{ .scene = .{ .before = before, .after = after } });
    host.history.setBaseline(baseline);
    return true;
}

/// Put the scene `zon`'s entities in place of the world's, as one step to undo: a recovered
/// copy of a scene never saved. Returns how many components and fields were left out.
pub fn restoreScene(host: anytype, zon: []const u8) !usize {
    return changeScene(host, true, zon, -1);
}

/// Put the scene `zon`'s entities into the world, after its own (or in place of them, when
/// `replace`), under the entity at place `parent_place` when that is 0 or more; one undo step.
/// Returns how many components and fields were left out. Fails before changing anything when
/// `zon` isn't a scene or the parent isn't there.
fn changeScene(host: anytype, replace: bool, zon: []const u8, parent_place: f64) !usize {
    const game = if (host.game) |*loaded| loaded else return error.NoGameLibrary;
    const access = game.sceneAccess();
    const world = &host.app.world;
    const source = try host.gpa.dupeSentinel(u8, zon, 0);
    defer host.gpa.free(source);
    var scene = try eggy.scene.Scene.parse(host.gpa, source);
    defer scene.deinit();

    // The parent, by its place in the scene as `scene_text` lists it.
    const parent: ?eggy.ecs.EntityId = if (replace or !std.math.isFinite(parent_place) or parent_place < 0) null else blk: {
        var captured = try entity_snapshot.capture(host.gpa, world, access, host.entity_editor.roots(world));
        defer captured.deinit();
        const place: usize = @intFromFloat(parent_place);
        if (place >= captured.sources.len) return error.NoSuchEntity;
        break :blk captured.sources[place];
    };

    try beginEdit(host);
    // From here the world changes: whatever happens is recorded, so Undo can take it back.
    defer {
        const recorded = commitEdit(host) catch |err| blk: {
            std.log.err("cannot record the scene change: {t}", .{err});
            break :blk false;
        };
        if (!recorded) host.extension_state.cancelEdit(host.gpa);
    }
    if (replace) {
        const roots = try host.gpa.dupe(eggy.ecs.EntityId, host.entity_editor.roots(world));
        defer host.gpa.free(roots);
        for (roots) |root| world.despawnRecursive(root);
        host.entity_editor.forgetDead(&host.app);
    }
    const made = try scene.instantiate(host.gpa, world, access, parent);
    defer host.gpa.free(made.entities);
    // Top-level entities follow the scene's order, after the world's own.
    if (parent == null) {
        _ = host.entity_editor.roots(world);
        for (scene.entities, made.entities) |saved, entity| if (saved.parent == null) try host.entity_editor.root_order.place(entity, std.math.maxInt(usize));
    }
    return made.skipped;
}

/// Every component type with its fields' defaults as ZON (see `Context.componentTypes`),
/// owned by `host.gpa`. Defaults are read from a component added to an entity of a scratch world.
fn componentTypes(host: anytype) ![]u8 {
    const game = if (host.game) |*loaded| loaded else return error.NoGameLibrary;
    const access = game.sceneAccess();
    var scratch = eggy.ecs.World.init(host.gpa);
    defer scratch.deinit();
    var text: std.Io.Writer.Allocating = .init(host.gpa);
    errdefer text.deinit();
    const out = &text.writer;
    try out.writeAll(".{\n");
    for (access.types(), 0..) |info, index| {
        const entity = try scratch.spawn(.{});
        const added = access.add(&scratch, entity, index);
        try out.print("    .{{ .type = \"{f}\", .owner = \"{f}\", .addable = {}, .fields = .{{", .{ std.zig.fmtString(info.name), std.zig.fmtString(info.owner), info.addable });
        for (info.fields, 0..) |field, field_index| {
            const default: ?[]u8 = if (added) access.readFieldAlloc(host.gpa, &scratch, entity, index, field_index) catch null else null;
            defer if (default) |value| host.gpa.free(value);
            try out.print("\n        .{{ .name = \"{f}\", .kind = .{t}, .default = \"{f}\" }},", .{ std.zig.fmtString(field.name), field.kind, std.zig.fmtString(default orelse "") });
        }
        try out.writeAll(if (info.fields.len > 0) "\n    } },\n" else "} },\n");
    }
    try out.writeAll("}\n");
    return text.toOwnedSlice();
}

/// The Console's last `max_messages` messages, oldest first, owned by `gpa`.
fn consoleText(gpa: std.mem.Allocator, max_messages: usize) ![]u8 {
    var messages: console_log.Messages = .{};
    defer messages.deinit(gpa);
    _ = try console_log.snapshot(gpa, &messages, .{ .levels = .{ true, true, true, true } });
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    const entries = messages.entries.items;
    for (entries[entries.len -| max_messages..]) |entry| {
        try text.appendSlice(gpa, messages.text.items[entry.start..entry.end]);
        try text.append(gpa, '\n');
    }
    return text.toOwnedSlice(gpa);
}

/// Answer a two-call text read: its size when the request has no buffer, else the text.
fn respondText(request: api.Request, response: *api.Response, text: []const u8) !void {
    response.length = text.len;
    if (request.capacity == 0) return;
    if (text.len > request.capacity) return error.BufferTooSmall;
    @memcpy(request.buffer[0..text.len], text);
}

/// Scene text for history, captured through the current library's typed registry.
/// Host-only: `host` supplies gpa, App, optional HotGame and EntityEditor; capture uses ordered
/// roots. Returns caller-owned ZON bytes allocated by `host.gpa`; temporary scene storage is
/// released. Missing library, capture and writer/allocation failures propagate.
///
/// ```zig
/// const before = try snapshot(editor); // Concrete editor pointer, outside library reload.
/// defer editor.gpa.free(before);
/// ```
pub fn snapshot(host: anytype) ![]u8 {
    const game = if (host.game) |*loaded| loaded else return error.NoGameLibrary;
    var scene = try @import("../entities/snapshot.zig").capture(host.gpa, &host.app.world, game.sceneAccess(), host.entity_editor.roots(&host.app.world));
    defer scene.deinit();
    var text: std.Io.Writer.Allocating = .init(host.gpa);
    defer text.deinit();
    try scene.write(&text.writer);
    return text.toOwnedSlice();
}
