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

    pub fn selection(self: *Context) !?ecs.EntityId {
        const response = try self.send(.{ .operation = .selection });
        return if (response.has_entity) ecs.EntityId.init(response.entity.id, response.entity.generation) else null;
    }

    pub fn select(self: *Context, entity: ?ecs.EntityId) !void {
        _ = try self.send(.{ .operation = .select, .entity = if (entity) |id| .{ .id = id.id, .generation = id.generation } else .{}, .has_entity = entity != null });
    }

    /// Apply a typed before/after edit, mark it changed, and record host-owned scene snapshots.
    /// No component pointer is retained in history. Reject a stale before-state or non-data
    /// component; errors before commit leave the component unchanged.
    pub fn changeComponent(self: *Context, entity: ecs.EntityId, change: anytype) !void {
        const T = @TypeOf(change.before);
        comptime {
            if (@TypeOf(change) != action.Action(T)) @compileError("changeComponent expects Action(Component)");
            if (!components.editableType(T)) @compileError("history edits require plain component data");
        }
        if (!self.app.world.isAlive(entity)) return error.InvalidEntity;
        const value = self.app.world.get(entity, T) orelse return error.NoComponent;
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
    pub fn beginAction(self: *Context, label: []const u8) !Group {
        try self.textRequest(.begin_group, label, "");
        return .{ .editor = self };
    }

    pub fn openScene(self: *Context, path: []const u8) !void {
        try self.textRequest(.open_scene, path, "");
    }
    pub fn saveScene(self: *Context) !void {
        _ = try self.send(.{ .operation = .save_scene });
    }
    pub fn createFolder(self: *Context, parent: []const u8) !void {
        try self.textRequest(.create_folder, parent, "");
    }
    pub fn renameFile(self: *Context, path: []const u8, name: []const u8) !void {
        try self.textRequest(.rename_file, path, name);
    }
    pub fn deleteFile(self: *Context, path: []const u8) !void {
        try self.textRequest(.delete_file, path, "");
    }
    pub fn duplicateFile(self: *Context, path: []const u8) !void {
        try self.textRequest(.duplicate_file, path, "");
    }
    pub fn moveFile(self: *Context, path: []const u8, folder: []const u8) !void {
        try self.textRequest(.move_file, path, folder);
    }
    pub fn copyFile(self: *Context, path: []const u8, folder: []const u8) !void {
        try self.textRequest(.copy_file, path, folder);
    }
    pub fn importFile(self: *Context, outside: []const u8, folder: []const u8) !void {
        try self.textRequest(.import_file, outside, folder);
    }
    pub fn setDefaultScene(self: *Context, path: []const u8) !void {
        try self.textRequest(.default_scene, path, "");
    }

    /// Queue a project build after this hook unwinds. Progress/failures use the Build window.
    pub fn requestBuild(self: *Context) !void {
        _ = try self.send(.{ .operation = .request_build });
    }
    /// Queue the editor's existing rebuild/reload workflow, including unsaved-change prompts.
    pub fn requestReload(self: *Context) !void {
        _ = try self.send(.{ .operation = .request_reload });
    }
    pub fn showExport(self: *Context) !void {
        _ = try self.send(.{ .operation = .show_export });
    }
    pub fn showNewProject(self: *Context) !void {
        _ = try self.send(.{ .operation = .show_new_project });
    }
    pub fn showOpenProject(self: *Context) !void {
        _ = try self.send(.{ .operation = .show_open_project });
    }

    /// Parse settings into a caller-owned arena; all returned strings live in `arena`.
    pub fn projectSettings(self: *Context, arena: std.mem.Allocator) !project.Config {
        const size = try self.send(.{ .operation = .project_settings });
        const buffer = try arena.allocSentinel(u8, size.length, 0);
        const read = try self.send(.{ .operation = .project_settings, .buffer = buffer.ptr, .capacity = buffer.len });
        if (read.length != buffer.len) return error.ProjectSettingsChanged;
        return project.parse(arena, buffer);
    }

    // ponytail: custom inspectors/importers/scene tools have no host registration, add one before exposing callbacks.
    pub fn registerImporter(_: *Context, name: []const u8) error{NotImplemented}!void {
        _ = name;
        return error.NotImplemented;
    }
    pub fn registerInspector(_: *Context, name: []const u8) error{NotImplemented}!void {
        _ = name;
        return error.NotImplemented;
    }
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

    pub fn commit(self: *Group) !void {
        if (!self.active) return error.ActionAlreadyFinished;
        _ = try self.editor.send(.{ .operation = .commit_group });
        self.active = false;
    }
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
