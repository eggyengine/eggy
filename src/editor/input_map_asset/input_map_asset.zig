//! The standalone `.inmap.zon` editor opened from Assets.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const MappingsView = @import("../input_mappings.zig").View;
const history_zig = @import("../history.zig");
pub const Document = @import("document.zig").Document;

const kinds = std.meta.fieldNames(eggy.input.Kind);
const Action = enum { none, save, revert, save_close, discard_close, cancel_close };

/// Window-independent UI, sharing binding/trigger controls with Edit > Input Mappings.
pub const View = struct {
    mappings: MappingsView = .{ .source = .asset },
    scroll: ui.Layout.ScrollState = .{},
    new_name: ui.TextEdit(128) = .{},
    new_kind: usize = 0,
    control_name: ui.TextEdit(128) = .{},
    control_kind: usize = 0,
    loaded_control: ?usize = null,
    confirm_close: bool = false,
    last_error: ?anyerror = null,

    fn resetMappings(self: *View, index: usize) void {
        self.mappings = .{ .source = .asset, .control_index = index };
        self.loaded_control = null;
        self.last_error = null;
    }

    pub fn build(self: *View, context: *ui.Context, document: *Document, path: []const u8) !Action {
        context.heading(2, "Input Map");
        context.muted(try context.builder().allocator.dupe(u8, path));
        if (!std.mem.startsWith(u8, path, "resources/")) context.muted("Move this file under resources/ to include it in runtime builds.");
        if (document.modified()) context.muted("Unsaved changes");
        if (self.last_error) |err| context.label("Input map: {t}. The file was not overwritten.", .{err});
        if (self.confirm_close) {
            context.muted("Save this input map before closing?");
            if (context.button("Save and close")) return .save_close;
            if (context.button("Discard changes and close")) return .discard_close;
            if (context.button("Keep editing")) return .cancel_close;
            return .none;
        }
        context.begin(.row);
        var action: Action = .none;
        if (context.button("Save file")) action = .save;
        if (context.button("Revert file (discard edits)")) action = .revert;
        context.end();
        if (action != .none) return action;
        context.muted("Saved defaults load on the next Play or game reload.");
        var consume = document.state.owners.get(1).?.consume;
        if (context.checkbox("Consume overlapping lower-priority input", &consume)) document.setConsume(consume);
        _ = context.textInput("New control name", &self.new_name, "jump, move, look...");
        _ = context.select("New control value", kinds, &self.new_kind);
        if (context.button("Add control")) {
            document.addControl(self.new_name.text(), @enumFromInt(self.new_kind)) catch |err| {
                self.last_error = err;
                return .none;
            };
            try self.new_name.set("");
            self.resetMappings(document.state.controls.count() - 1);
        }
        if (document.state.controls.count() != 0) {
            const index = @min(self.mappings.control_index, document.state.controls.count() - 1);
            const control = document.state.controls.values()[index];
            if (self.loaded_control != index) {
                try self.control_name.set(control.name);
                self.control_kind = @intFromEnum(control.kind);
                self.loaded_control = index;
            }
            _ = context.textInput("Selected control name", &self.control_name, "Keep the FileMap enum in step with these names");
            if (context.button("Rename selected control")) {
                document.renameControl(index, self.control_name.text()) catch |err| {
                    self.last_error = err;
                    return .none;
                };
                self.resetMappings(index);
            }
            _ = context.select("Selected control value", kinds, &self.control_kind);
            if (context.button("Change value type (clears bindings and trigger)")) {
                document.setKind(index, @enumFromInt(self.control_kind)) catch |err| {
                    self.last_error = err;
                    return .none;
                };
                self.resetMappings(index);
            }
            if (context.button("Remove selected control")) {
                document.removeControl(index) catch |err| {
                    self.last_error = err;
                    return .none;
                };
                self.resetMappings(0);
            }
        } else context.muted("Add a control, then assign its bindings below.");
        try self.mappings.build(context, &document.state);
        return .none;
    }
};

/// Save only after the complete replacement is validated by the document.
pub fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    try atomic.replace(io);
}

/// History must not overwrite a file edited outside the editor.
pub fn restoreFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, expected: []const u8, text: []const u8) !Document {
    var replacement = try Document.init(gpa, text);
    errdefer replacement.deinit();
    const current = try dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(current);
    if (!std.mem.eql(u8, current, expected)) return error.InputMapChangedExternally;
    try writeFile(io, dir, path, text);
    return replacement;
}

pub const Window = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    project_dir: []const u8,
    path: []u8,
    document: Document,
    loaded_hash: u64,
    view: View = .{},

    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, project_dir: []const u8, path: []const u8) !*Window {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
        defer dir.close(io);
        const source = try dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(source);
        var document = try Document.init(gpa, source);
        errdefer document.deinit();
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .window = try ToolWindow.open(gpa, graphics, font, "Input Map", .{ 760, 780 }, .{ .resizable = true }),
            .project_dir = project_dir,
            .path = owned_path,
            .document = document,
            .loaded_hash = std.hash.Wyhash.hash(0, source),
        };
        return self;
    }

    pub fn close(self: *Window, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.document.deinit();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    pub fn affectedBy(self: *const Window, path: []const u8) bool {
        return std.mem.eql(u8, self.path, path) or
            (std.mem.startsWith(u8, self.path, path) and self.path.len > path.len and self.path[path.len] == '/');
    }

    /// Follow a renamed asset or containing folder without discarding its working document.
    pub fn moved(self: *Window, from: []const u8, to: []const u8) !void {
        if (!self.affectedBy(from)) return;
        const replacement = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ to, self.path[from.len..] });
        self.gpa.free(self.path);
        self.path = replacement;
    }

    pub fn handle(self: *Window, event: eggy.Event) bool {
        if (self.view.mappings.capture != null and (self.window.owns(event) or eggy.game_ui.isControllerInput(event))) {
            if (self.view.mappings.captureEvent(event)) return true;
        }
        if (!self.window.owns(event)) return false;
        self.window.handle(event);
        return true;
    }

    pub fn closeRequested(self: *Window, event: eggy.Event) bool {
        if (!self.window.owns(event)) return false;
        const requested = event == .window_close_requested or (self.view.mappings.capture == null and event == .key_down and event.key_down.scancode == .escape);
        if (!requested) return false;
        if (!self.document.modified()) return true;
        self.view.confirm_close = true;
        return false;
    }

    /// Refuse external changes, and reserve history before replacing the file atomically.
    pub fn save(self: *Window, history: *history_zig.History) !void {
        var text: std.Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        try self.document.write(&text.writer);
        if (text.written().len > 1 << 20) return error.InputMapTooLarge;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        const before = try dir.readFileAlloc(io, self.path, self.gpa, .limited(1 << 20));
        errdefer self.gpa.free(before);
        if (std.hash.Wyhash.hash(0, before) != self.loaded_hash) return error.InputMapChangedExternally;
        if (std.mem.eql(u8, before, text.written())) {
            self.gpa.free(before);
            self.document.markSaved();
            return;
        }
        const after = try self.gpa.dupe(u8, text.written());
        errdefer self.gpa.free(after);
        const path = try self.gpa.dupe(u8, self.path);
        errdefer self.gpa.free(path);
        try history.reserve();
        try writeFile(io, dir, self.path, after);
        history.record(.{ .input_map = .{ .path = path, .text = .{ .before = before, .after = after } } });
        self.loaded_hash = std.hash.Wyhash.hash(0, after);
        self.document.markSaved();
    }

    pub fn reload(self: *Window) !void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        const text = try dir.readFileAlloc(io, self.path, self.gpa, .limited(1 << 20));
        defer self.gpa.free(text);
        const replacement = try Document.init(self.gpa, text);
        self.document.deinit();
        self.document = replacement;
        self.loaded_hash = std.hash.Wyhash.hash(0, text);
        self.view = .{};
    }

    pub fn restore(self: *Window, io: std.Io, dir: std.Io.Dir, expected: []const u8, text: []const u8) !void {
        if (self.document.modified()) return error.UnsavedInputMap;
        const replacement = try restoreFile(self.gpa, io, dir, self.path, expected, text);
        self.document.deinit();
        self.document = replacement;
        self.loaded_hash = std.hash.Wyhash.hash(0, text);
        self.view = .{};
    }

    pub fn update(self: *Window, graphics: *eggy.Graphics, style: *const ui.Context, history: *history_zig.History) !struct { close: bool = false, saved: bool = false } {
        const Page = struct {
            owner: *Window,
            action: Action = .none,
            pub fn build(page: *@This(), context: *ui.Context) void {
                const view = &page.owner.view;
                context.beginScroll(&view.scroll, @max(1, context.viewport.h - 24));
                defer context.end();
                page.action = view.build(context, &page.owner.document, page.owner.path) catch |err| {
                    view.last_error = err;
                    std.log.err("cannot draw input map {s}: {t}", .{ page.owner.path, err });
                    return;
                };
            }
        };
        var page = Page{ .owner = self };
        try self.window.present(graphics, style, &page);
        switch (page.action) {
            .none => {},
            .cancel_close => self.view.confirm_close = false,
            .discard_close => return .{ .close = true },
            .revert => self.reload() catch |err| {
                self.report(err);
            },
            .save, .save_close => {
                self.save(history) catch |err| {
                    self.report(err);
                    return .{};
                };
                self.view.last_error = null;
                return .{ .saved = true, .close = page.action == .save_close };
            },
        }
        return .{};
    }

    fn report(self: *Window, err: anyerror) void {
        self.view.last_error = err;
        std.log.err("input map {s}: {t}; revert to read the file again after external changes", .{ self.path, err });
    }
};

test "an empty input-map asset has a usable editor and controls fit a scrollable page" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, ".{}");
    defer document.deinit();
    var view = View{};
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    context.density = .compact;
    context.newFrame(.{ .x = 0, .y = 0, .w = 760, .h = 780 });
    try std.testing.expectEqual(Action.none, try view.build(&context, &document, "resources/player.inmap.zon"));
    try std.testing.expect((try context.render()).len > 0);
    try document.addControl("move", .vector);
    context.newFrame(.{ .x = 0, .y = 0, .w = 760, .h = 400 });
    context.beginScroll(&view.scroll, 376);
    _ = try view.build(&context, &document, "resources/player.inmap.zon");
    context.end();
    try std.testing.expect((try context.render()).len > 0);
    try std.testing.expect(view.scroll.content.y > view.scroll.viewport.h);
}

test "saving an input-map asset records atomic undo and refuses external or unsaved conflicts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "player.inmap.zon", .data = ".{}" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var window = Window{
        .gpa = gpa,
        .window = undefined,
        .project_dir = dir,
        .path = try gpa.dupe(u8, "player.inmap.zon"),
        .document = try Document.init(gpa, ".{}"),
        .loaded_hash = std.hash.Wyhash.hash(0, ".{}"),
    };
    defer window.document.deinit();
    defer gpa.free(window.path);
    var history = history_zig.History{ .gpa = gpa };
    defer history.deinit();
    try window.document.addControl("jump", .button);
    try window.save(&history);
    try std.testing.expect(!window.document.modified());
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
    const change = history.undo_steps.items[0].input_map;
    try window.restore(io, tmp.dir, change.text.after, change.text.before);
    try std.testing.expectEqual(@as(usize, 0), window.document.state.controls.count());
    try window.restore(io, tmp.dir, change.text.before, change.text.after);
    try std.testing.expectEqualStrings("jump", window.document.state.controls.values()[0].name);
    try window.document.addControl("move", .vector);
    try std.testing.expectError(error.UnsavedInputMap, window.restore(io, tmp.dir, change.text.after, change.text.before));
    try tmp.dir.writeFile(io, .{ .sub_path = "player.inmap.zon", .data = ".{ .priority = 9 }" });
    try std.testing.expectError(error.InputMapChangedExternally, window.save(&history));
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
    try window.reload();
    try std.testing.expect(!window.document.modified());
    try std.testing.expectEqual(@as(i32, 9), window.document.state.owners.get(1).?.priority);
    try std.testing.expectError(error.InputMapChangedExternally, window.restore(io, tmp.dir, change.text.after, change.text.before));
    try window.moved("player.inmap.zon", "menu.inmap.zon");
    try std.testing.expectEqualStrings("menu.inmap.zon", window.path);
    try std.testing.expect(!window.affectedBy("menu.inmap"));
}

test {
    _ = @import("document.zig");
}
