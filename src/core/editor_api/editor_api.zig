//! Borrowed editor services, expressed without importing the desktop editor.
const std = @import("std");
const App = @import("../app.zig").App;
const ecs = @import("clutch");
const action = @import("../action.zig");
const components = @import("../components.zig");
const project = @import("../project.zig");

/// Fixed-representation results shared by separately compiled editor and game libraries.
pub const Status = enum(u32) { ok, failed, out_of_memory, invalid_entity, no_project, not_editing, busy, buffer_too_small };
pub const Operation = enum(u32) {
    selection,
    select,
    begin_edit,
    commit_edit,
    cancel_edit,
    begin_group,
    commit_group,
    cancel_group,
    open_scene,
    save_scene,
    create_folder,
    rename_file,
    delete_file,
    duplicate_file,
    move_file,
    copy_file,
    import_file,
    project_settings,
    default_scene,
    request_build,
    request_reload,
    show_export,
    show_new_project,
    show_open_project,
    project_folder,
    show_panel,
    write_file,
};
pub const Entity = extern struct { id: u32 = 0, generation: u32 = 0 };
/// Strings are borrowed for this synchronous request only.
pub const Request = extern struct {
    operation: Operation,
    entity: Entity = .{},
    has_entity: bool = false,
    text: [*]const u8 = "",
    text_len: usize = 0,
    extra: [*]const u8 = "",
    extra_len: usize = 0,
    buffer: [*]u8 = undefined,
    capacity: usize = 0,
};
pub const Response = extern struct { entity: Entity = .{}, has_entity: bool = false, length: usize = 0 };
pub const Host = extern struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, *const Request, *Response) callconv(.c) Status,
};

/// Valid only during the current editor hook. Do not store it or pointers into App.
pub const Context = struct {
    app: *App,
    host: Host,

    /// Read the editor's selected live entity, or null when nothing is selected.
    /// The ID belongs to `app.world`, not this context; host failures propagate.
    ///
    /// ```zig
    /// // Inside an editor hook with editor: *eggy.editor.Context:
    /// const selected = try editor.selection();
    /// ```
    pub fn selection(self: *Context) !?ecs.EntityId {
        const response = try self.send(.{ .operation = .selection });
        return if (response.has_entity) ecs.EntityId.init(response.entity.id, response.entity.generation) else null;
    }

    /// Select a live entity in the current world, or clear selection with null.
    /// A dead/stale ID returns `InvalidEntity`; selection itself is not a component edit.
    ///
    /// ```zig
    /// // Inside an editor hook:
    /// try editor.select(null);
    /// ```
    pub fn select(self: *Context, entity: ?ecs.EntityId) !void {
        _ = try self.send(.{ .operation = .select, .entity = if (entity) |id| .{ .id = id.id, .generation = id.generation } else .{}, .has_entity = entity != null });
    }

    /// Apply a typed before/after edit, mark it changed, and record host-owned scene snapshots.
    /// No component pointer is retained in history. Reject a stale before-state or non-data
    /// component; errors before commit leave the component unchanged.
    /// Requires editing mode and a live entity with `T`; the Action's before-state must
    /// match its current value. A failed host commit restores and marks the before-state.
    ///
    /// ```zig
    /// // Editor hook, with entity carrying the registered plain-data Health component:
    /// const before = editor.app.world.get(entity, Health).?.*;
    /// var after = before;
    /// after.value = 100;
    /// try editor.changeComponent(entity, eggy.Action(Health){ .before = before, .after = after });
    /// ```
    pub fn changeComponent(self: *Context, entity: ecs.EntityId, change: anytype) !void {
        const T = @TypeOf(change.before);
        comptime {
            if (@typeInfo(T) != .@"struct") @compileError("component edits require a component struct");
            if (@TypeOf(change) != action.Action(T)) @compileError("changeComponent expects Action(Component)");
            if (!components.editableType(T)) @compileError("history edits require plain component data");
        }
        if (!self.app.world.isAlive(entity)) return error.InvalidEntity;
        const value = self.app.world.get(entity, T) orelse return error.NoComponent;
        try components.validateSnapshot(T, &change.before);
        try components.validateSnapshot(T, &change.after);
        if (!try components.valuesEqual(self.app.world.allocator, T, value, &change.before)) return error.StaleAction;
        if (try components.valuesEqual(self.app.world.allocator, T, &change.before, &change.after)) return;
        _ = try self.send(.{ .operation = .begin_edit });
        var committed = false;
        defer if (!committed) {
            value.* = change.before;
            self.app.world.markChanged(entity, T);
            if (self.send(.{ .operation = .cancel_edit })) |_| {} else |err| {
                std.log.err("cannot cancel an editor edit: {t}", .{err});
            }
        };
        value.* = change.after;
        self.app.world.markChanged(entity, T);
        _ = try self.send(.{ .operation = .commit_edit });
        committed = true;
    }

    /// Group several editor operations as one named action. Defer `Group.deinit`; commit
    /// explicitly. An uncommitted group is reverted, with cleanup failures logged.
    /// Requires editing mode and no already-open group. Keep the group within this hook;
    /// its context must remain alive until commit or cleanup.
    ///
    /// ```zig
    /// var group = try editor.beginAction("Restore health");
    /// defer group.deinit();
    /// try editor.changeComponent(entity, health_change); // A typed eggy.Action(Health).
    /// try group.commit();
    /// ```
    pub fn beginAction(self: *Context, label: []const u8) !Group {
        try self.textRequest(.begin_group, label, "");
        return .{ .editor = self };
    }

    /// Open a project-relative scene through the editor's undo-aware scene workflow, recording
    /// the previous world for undo rather than prompting to save it. Requires editing mode;
    /// path and host failures propagate.
    ///
    /// ```zig
    /// // Inside an editor hook:
    /// try editor.openScene("resources/level.scene.zon");
    /// ```
    pub fn openScene(self: *Context, path: []const u8) !void {
        try self.textRequest(.open_scene, path, "");
    }
    /// Save the currently open scene through the editor. Requires editing mode and a project;
    /// host/I/O failures propagate rather than reporting a successful save.
    ///
    /// ```zig
    /// // Inside an editor hook:
    /// try editor.saveScene();
    /// ```
    pub fn saveScene(self: *Context) !void {
        _ = try self.send(.{ .operation = .save_scene });
    }
    /// Create a uniquely named folder under project-relative `parent`, recording undo.
    /// Requires editing mode and a project; empty parent means the project root.
    /// The host owns generated paths; no path is returned.
    ///
    /// ```zig
    /// try editor.createFolder("resources");
    /// ```
    pub fn createFolder(self: *Context, parent: []const u8) !void {
        try self.textRequest(.create_folder, parent, "");
    }
    /// Rename a project-relative file/folder to the path-free leaf `name`, keeping its asset ids
    /// and recording undo history. Requires editing mode; invalid names and filesystem failures are errors.
    ///
    /// ```zig
    /// try editor.renameFile("resources/old.txt", "story.txt");
    /// ```
    pub fn renameFile(self: *Context, path: []const u8, name: []const u8) !void {
        try self.textRequest(.rename_file, path, name);
    }
    /// Delete a nonempty project-relative file/folder through the undo-aware editor workflow.
    /// Requires editing mode and a project; path/I/O errors propagate.
    ///
    /// ```zig
    /// try editor.deleteFile("resources/unused.txt");
    /// ```
    pub fn deleteFile(self: *Context, path: []const u8) !void {
        try self.textRequest(.delete_file, path, "");
    }
    /// Duplicate a project-relative file/folder under a unique name, recording undo.
    /// Requires editing mode; the host chooses and owns the destination path.
    ///
    /// ```zig
    /// try editor.duplicateFile("resources/enemy.scene.zon");
    /// ```
    pub fn duplicateFile(self: *Context, path: []const u8) !void {
        try self.textRequest(.duplicate_file, path, "");
    }
    /// Move a project-relative file/folder into project-relative `folder`, keeping its
    /// asset ids and recording undo. Requires editing mode; destination conflicts are errors.
    ///
    /// ```zig
    /// try editor.moveFile("resources/story.txt", "resources/dialogue");
    /// ```
    pub fn moveFile(self: *Context, path: []const u8, folder: []const u8) !void {
        try self.textRequest(.move_file, path, folder);
    }
    /// Copy a project-relative file/folder into `folder` with new asset identities and undo.
    /// Requires editing mode; source remains unchanged and host/I/O errors propagate.
    ///
    /// ```zig
    /// try editor.copyFile("resources/story.txt", "resources/dialogue");
    /// ```
    pub fn copyFile(self: *Context, path: []const u8, folder: []const u8) !void {
        try self.textRequest(.copy_file, path, folder);
    }
    /// Copy an external filesystem path into a project-relative folder and record creation
    /// in undo history. Requires editing mode; external source is not moved or deleted.
    ///
    /// ```zig
    /// // source_path is an existing external file chosen by the user:
    /// try editor.importFile(source_path, "resources");
    /// ```
    pub fn importFile(self: *Context, outside: []const u8, folder: []const u8) !void {
        try self.textRequest(.import_file, outside, folder);
    }
    /// Write `contents` to the project-relative file `path`, making the folders it needs, as one
    /// undo step: undone, a new file (and any folder made for it) goes to the trash, and an
    /// existing one gets its old text back. Writing what it already holds records nothing.
    /// Requires editing mode and a project; invalid paths and I/O failures are errors.
    ///
    /// ```zig
    /// try editor.writeFile(".mcp.json", "{}\n");
    /// ```
    pub fn writeFile(self: *Context, path: []const u8, contents: []const u8) !void {
        try self.textRequest(.write_file, path, contents);
    }
    /// Set the project's default scene to a project-relative scene path, recording a settings
    /// undo action. Requires editing mode; path validation and write failures propagate.
    /// This string-taking operation does not expose the settings field's null/clear state.
    ///
    /// ```zig
    /// try editor.setDefaultScene("resources/level.scene.zon");
    /// ```
    pub fn setDefaultScene(self: *Context, path: []const u8) !void {
        try self.textRequest(.default_scene, path, "");
    }

    /// Queue a project build after this hook unwinds. Progress/failures use the Build window.
    /// Requires an open project and no conflicting pending workflow/edit. Success means
    /// queued, not that compilation succeeded.
    ///
    /// ```zig
    /// try editor.requestBuild();
    /// ```
    pub fn requestBuild(self: *Context) !void {
        _ = try self.send(.{ .operation = .request_build });
    }
    /// Queue the editor's existing rebuild/reload workflow, including unsaved-change prompts.
    /// Requires an open project and no conflicting operation. Do not retain this hook's
    /// context or world pointers for the replacement library.
    ///
    /// ```zig
    /// try editor.requestReload();
    /// ```
    pub fn requestReload(self: *Context) !void {
        _ = try self.send(.{ .operation = .request_reload });
    }
    /// Queue opening the Export window after this hook returns. Requires a project and an
    /// available workflow slot; success does not mean the game has been exported.
    ///
    /// ```zig
    /// try editor.showExport();
    /// ```
    pub fn showExport(self: *Context) !void {
        _ = try self.send(.{ .operation = .show_export });
    }
    /// Queue the New Project wizard after the hook returns, with normal unsaved-change
    /// handling. No existing project is required; conflicting workflows return `EditorBusy`.
    ///
    /// ```zig
    /// try editor.showNewProject();
    /// ```
    pub fn showNewProject(self: *Context) !void {
        _ = try self.send(.{ .operation = .show_new_project });
    }
    /// Queue the project-folder picker after the hook returns, with normal unsaved-change
    /// handling. No existing project is required; conflicting workflows return `EditorBusy`.
    ///
    /// ```zig
    /// try editor.showOpenProject();
    /// ```
    pub fn showOpenProject(self: *Context) !void {
        _ = try self.send(.{ .operation = .show_open_project });
    }

    /// The open project's folder, an absolute path in `arena`. Requires a project; host and
    /// allocation failures propagate.
    ///
    /// ```zig
    /// const folder = try editor.projectFolder(arena.allocator());
    /// ```
    pub fn projectFolder(self: *Context, arena: std.mem.Allocator) ![]const u8 {
        const size = try self.send(.{ .operation = .project_folder });
        const buffer = try arena.alloc(u8, size.length);
        const read = try self.send(.{ .operation = .project_folder, .buffer = buffer.ptr, .capacity = buffer.len });
        return buffer[0..read.length];
    }

    /// Open the calling plugin's panel `key` (an `EditorPanel.key`, or its title when it has no
    /// key) and bring its tab forward, docking it again if it was closed. Fails with
    /// `error.Failed` when no plugin declares a panel with that key; when two plugins do, the
    /// first one's opens.
    ///
    /// ```zig
    /// try editor.showPanel("git");
    /// ```
    pub fn showPanel(self: *Context, key: []const u8) !void {
        try self.textRequest(.show_panel, key, "");
    }

    /// Parse settings into a caller-owned arena; all returned strings live in `arena`.
    /// Reads the open project's file through the host. Requires a project; changed size
    /// between reads, parse failures, allocation failures and host failures return errors.
    ///
    /// ```zig
    /// var arena = std.heap.ArenaAllocator.init(gpa);
    /// defer arena.deinit();
    /// const settings = try editor.projectSettings(arena.allocator());
    /// ```
    pub fn projectSettings(self: *Context, arena: std.mem.Allocator) !project.Config {
        const size = try self.send(.{ .operation = .project_settings });
        const buffer = try arena.allocSentinel(u8, size.length, 0);
        const read = try self.send(.{ .operation = .project_settings, .buffer = buffer.ptr, .capacity = buffer.len });
        if (read.length != buffer.len) return error.ProjectSettingsChanged;
        return project.parse(arena, buffer);
    }

    // ponytail: custom inspectors/importers/scene tools have no host registration, add one before exposing callbacks.
    /// Reserved importer registration; always returns `NotImplemented`, retaining no name
    /// or callbacks. Declaring a name does not enable custom asset importing.
    ///
    /// ```zig
    /// try std.testing.expectError(error.NotImplemented, editor.registerImporter("sprites"));
    /// ```
    pub fn registerImporter(_: *Context, name: []const u8) error{NotImplemented}!void {
        _ = name;
        return error.NotImplemented;
    }
    /// Reserved inspector registration; always returns `NotImplemented` and retains nothing.
    /// Existing component field editors are not replaced by this call.
    ///
    /// ```zig
    /// try std.testing.expectError(error.NotImplemented, editor.registerInspector("health"));
    /// ```
    pub fn registerInspector(_: *Context, name: []const u8) error{NotImplemented}!void {
        _ = name;
        return error.NotImplemented;
    }
    /// Reserved scene-tool registration; always returns `NotImplemented` and retains nothing.
    /// No tool is added to the Scene toolbar.
    ///
    /// ```zig
    /// try std.testing.expectError(error.NotImplemented, editor.registerSceneTool("paint"));
    /// ```
    pub fn registerSceneTool(_: *Context, name: []const u8) error{NotImplemented}!void {
        _ = name;
        return error.NotImplemented;
    }

    fn textRequest(self: *Context, operation: Operation, text: []const u8, extra: []const u8) !void {
        _ = try self.send(.{ .operation = operation, .text = text.ptr, .text_len = text.len, .extra = extra.ptr, .extra_len = extra.len });
    }

    fn send(self: *Context, request: Request) !Response {
        var response = Response{};
        switch (self.host.request(self.host.context, &request, &response)) {
            .ok => return response,
            .failed => return error.EditorOperationFailed,
            .out_of_memory => return error.OutOfMemory,
            .invalid_entity => return error.InvalidEntity,
            .no_project => return error.NoProject,
            .not_editing => return error.NotEditing,
            .busy => return error.EditorBusy,
            .buffer_too_small => return error.BufferTooSmall,
        }
    }
};

/// A hook-local undo group. Its Context must outlive it.
pub const Group = struct {
    editor: *Context,
    active: bool = true,

    /// Finish this hook-local undo group as one action. Host failure leaves it active so
    /// deferred `deinit` can revert it; a second commit returns `ActionAlreadyFinished`.
    ///
    /// ```zig
    /// var group = try editor.beginAction("Edit objects");
    /// defer group.deinit();
    /// // Apply editor operations here.
    /// try group.commit();
    /// ```
    pub fn commit(self: *Group) !void {
        if (!self.active) return error.ActionAlreadyFinished;
        _ = try self.editor.send(.{ .operation = .commit_group });
        self.active = false;
    }
    /// Revert an active uncommitted group; a committed/finished group is a no-op.
    /// Must run before its editor hook ends. Cleanup failures are logged, not returned.
    ///
    /// ```zig
    /// var group = try editor.beginAction("Edit objects");
    /// defer group.deinit(); // Also rolls back when an intervening operation fails.
    /// ```
    pub fn deinit(self: *Group) void {
        if (!self.active) return;
        if (self.editor.send(.{ .operation = .cancel_group })) |_| {} else |err| {
            std.log.err("cannot revert uncommitted editor action: {t}", .{err});
        }
        self.active = false;
    }
};

test "typed editor edits commit once, reject stale values, and restore failed commits" {
    const TestHost = struct {
        commits: usize = 0,
        cancels: usize = 0,
        fail: bool = false,
        fn request(raw: *anyopaque, input: *const Request, _: *Response) callconv(.c) Status {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (input.operation) {
                .commit_edit => {
                    if (self.fail) return .failed;
                    self.commits += 1;
                },
                .cancel_edit => self.cancels += 1,
                else => {},
            }
            return .ok;
        }
    };
    const Health = struct { value: u32 = 10 };
    var app: App = undefined;
    app.world = .init(std.testing.allocator);
    defer app.world.deinit();
    const entity = try app.world.spawn(.{Health{}});
    var host = TestHost{};
    var editor = Context{ .app = &app, .host = .{ .context = &host, .request = TestHost.request } };
    const change = action.Action(Health){ .before = .{}, .after = .{ .value = 20 } };
    try editor.changeComponent(entity, change);
    try std.testing.expectEqual(@as(u32, 20), app.world.get(entity, Health).?.value);
    try std.testing.expectEqual(@as(usize, 1), host.commits);
    try std.testing.expectError(error.StaleAction, editor.changeComponent(entity, change));
    host.fail = true;
    try std.testing.expectError(error.EditorOperationFailed, editor.changeComponent(entity, action.Action(Health){ .before = .{ .value = 20 }, .after = .{ .value = 30 } }));
    try std.testing.expectEqual(@as(u32, 20), app.world.get(entity, Health).?.value);
    try std.testing.expectEqual(@as(usize, 1), host.cancels);
    try std.testing.expectError(error.NotImplemented, editor.registerImporter("example"));
    try std.testing.expectError(error.NotImplemented, editor.registerInspector("example"));
    try std.testing.expectError(error.NotImplemented, editor.registerSceneTool("example"));
}
