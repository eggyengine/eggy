//! Synchronous editor services for game-library hooks.
const std = @import("std");
const eggy = @import("eggy");
const api = eggy.editor;
const settings = @import("../project_settings.zig");
const file_ops = @import("../assets/file_ops.zig");
const workspace = @import("../workspace.zig");
const ProjectFlow = @import("../projects/flow.zig").ProjectFlow;
const ExportWindow = @import("../export/export.zig").ExportWindow;
const layout_file = @import("../layout_file.zig");
const sdl = eggy.sdl_adapter.sdl;

/// Owns snapshots only; it never retains game-library callbacks or component pointers.
pub const State = struct {
    before: ?[]u8 = null,
    pending: ?api.Operation = null,
    /// Free an editor extension's pending snapshot with its allocating `gpa`, then reset state.
    /// Host-only: discards queued lifecycle work; it does not restore the world or cancel an
    /// already-recorded history group. Safe to call again on the reset state.
    ///
    /// ```zig
    /// extension_state.deinit(gpa); // Host State and its snapshot allocator.
    /// ```
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.before) |before| gpa.free(before);
        self.* = .{};
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
    switch (request) {
        .build_project => {
            if (host.project == null) return error.NoProject;
            if (host.buildRunning()) return error.EditorBusy;
            host.cancelBuild();
            try host.startBuild(.rebuild);
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
        .request_build, .request_reload, .show_export, .show_new_project, .show_open_project => {
            if (host.extension_state.pending != null or host.extension_state.before != null or host.history.group != null or host.build_window != null or host.project_flow != null) return error.EditorBusy;
            if (request.operation != .show_new_project and request.operation != .show_open_project and host.project == null) return error.NoProject;
            host.extension_state.pending = request.operation;
            return;
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
        .begin_edit => {
            if (host.project == null) return error.NoProject;
            if (host.extension_state.before != null or host.extension_state.pending != null) return error.EditorBusy;
            try host.history.reserve();
            const before = try snapshot(host);
            errdefer host.gpa.free(before);
            host.history.watch(try host.gpa.dupe(u8, before), std.math.maxInt(u64), false);
            try host.history.reserve();
            host.extension_state.before = before;
        },
        .commit_edit => {
            const before = host.extension_state.before orelse return error.EditorBusy;
            const after = try snapshot(host);
            errdefer host.gpa.free(after);
            if (std.mem.eql(u8, before, after)) return error.ComponentNotInScene;
            const baseline = try host.gpa.dupe(u8, after);
            host.extension_state.before = null;
            host.history.record(.{ .scene = .{ .before = before, .after = after } });
            host.history.setBaseline(baseline);
        },
        .cancel_edit => host.extension_state.deinit(host.gpa),
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
                const path = if (request.operation == .copy_file)
                    try file_ops.copyInto(host.gpa, io, files, text, extra)
                else
                    try file_ops.import(host.gpa, io, files, text, extra);
                host.history.record(.{ .create = .{ .path = path } });
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
        .selection, .select, .show_panel, .project_settings, .project_folder, .request_build, .request_reload, .show_export, .show_new_project, .show_open_project => unreachable,
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
