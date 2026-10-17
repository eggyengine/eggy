//! Synchronous editor services for game-library hooks.
const std = @import("std");
const eggy = @import("eggy");
const api = eggy.editor;
const settings = @import("../project_settings.zig");
const file_ops = @import("../assets/file_ops.zig");

/// Owns snapshots only; it never retains game-library callbacks or component pointers.
pub const State = struct {
    before: ?[]u8 = null,
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.before) |before| gpa.free(before);
        self.* = .{};
    }
};

/// Construct a hook-local view after the concrete editor has reached its final address.
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
        .selection => {
            host.entity_editor.forgetDead(&host.app);
            if (host.entity_editor.selected) |entity| {
                response.has_entity = true;
                response.entity = .{ .id = entity.id, .generation = entity.generation };
            }
            return;
        },
        .select => {
            const entity = eggy.ecs.EntityId.init(request.entity.id, request.entity.generation);
            if (request.has_entity and !host.app.world.isAlive(entity)) return error.InvalidEntity;
            host.entity_editor.selected = if (request.has_entity) entity else null;
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
            if (host.extension_state.before != null) return error.EditorBusy;
            try host.history.reserve();
            const before = try snapshot(host);
            errdefer host.gpa.free(before);
            host.history.watch(try host.gpa.dupe(u8, before), std.math.maxInt(u64), false);
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
        .begin_group => try host.history.beginGroup(text),
        .commit_group => try host.history.commitGroup(),
        .cancel_group => {
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
        .default_scene => {
            _ = try eggy.AssetRef(.scene).parse(text);
            const project = host.project orelse return error.NoProject;
            try host.history.reserve();
            if (try settings.setDefaultScene(host.gpa, project.dir, text)) |change| host.history.recordProjectSettings(change.before, change.after, host.workspace.time_ms);
        },
        .selection, .select, .project_settings => unreachable,
    }
}

/// Scene text for history, captured through the current library's typed registry.
pub fn snapshot(host: anytype) ![]u8 {
    const game = if (host.game) |*loaded| loaded else return error.NoGameLibrary;
    var scene = try eggy.scene.Scene.capture(host.gpa, &host.app.world, game.sceneAccess(), host.entity_editor.roots(&host.app.world));
    defer scene.deinit();
    var text: std.Io.Writer.Allocating = .init(host.gpa);
    defer text.deinit();
    try scene.write(&text.writer);
    return text.toOwnedSlice();
}
