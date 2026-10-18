//! The standalone `.inmap.zon` editor opened from Assets.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const MappingsView = @import("../input_mappings.zig").View;
const history_zig = @import("../history.zig");
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;
const beginSection = page_style.beginSection;
const endSection = page_style.endSection;
const endRow = page_style.endRow;
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

    /// Build the editor input-map page, mutating only the independent document and view state.
    /// `path` is a display/project-relative asset path; context must be building a UI frame.
    /// Returns a save/revert/close intent for the window host, not a disk write. UI errors
    /// propagate; invalid control edits are retained as `last_error` and leave the document intact.
    ///
    /// ```zig
    /// // Given View, building UI context and initialized Document:
    /// const action = try view.build(context, &document, "resources/player.inmap.zon");
    /// ```
    pub fn build(self: *View, context: *ui.Context, document: *Document, path: []const u8) !Action {
        // The file: its path and state, and saving it.
        context.begin(.row);
        context.begin(.column);
        context.heading(3, "Input Map");
        context.muted(try context.builder().allocator.dupe(u8, path));
        page_style.smallText(context, 12);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 2 });
        if (document.modified()) context.badge("Unsaved", .outline);
        var action: Action = .none;
        if (!self.confirm_close) {
            if (context.buttonVariant("Revert", .ghost)) action = .revert;
            if (context.buttonVariant("Save", .default)) action = .save;
        }
        endRow(context);
        if (!std.mem.startsWith(u8, path, "resources/")) context.alert("Not in resources/", "Move this file under resources/ to include it in runtime builds.", false);
        if (self.last_error) |err| context.alert("The file was not overwritten", @errorName(err), true);
        if (self.confirm_close) {
            context.alert("Unsaved changes", "Save this input map before closing?", false);
            context.begin(.row);
            if (context.buttonVariant("Save and close", .default)) action = .save_close;
            if (context.buttonVariant("Discard and close", .destructive)) action = .discard_close;
            if (context.buttonVariant("Keep editing", .ghost)) action = .cancel_close;
            endRow(context);
            return action;
        }
        if (action != .none) return action;

        beginSection(context, "Map");
        var consume = document.state.owners.get(1).?.consume;
        if (context.checkbox("Consume overlapping lower-priority input", &consume)) document.setConsume(consume);
        context.muted("Saved defaults load on the next Play or game reload.");
        page_style.smallText(context, 12);
        endSection(context);

        // Controls: add one, then rename, retype or remove the selected one.
        beginSection(context, "Controls");
        context.begin(.row);
        _ = context.textInput("New control name", &self.new_name, "jump, move, look...");
        restyle(context, .{ .grow = 1 });
        _ = context.select("New control value", kinds, &self.new_kind);
        const add = context.buttonVariant("Add control", .outline);
        endRow(context);
        if (add) self.addControl(document);
        if (document.state.controls.count() != 0) try self.editSelected(context, document) else context.muted("Add a control, then assign its bindings below.");
        endSection(context);
        try self.mappings.build(context, &document.state);
        return .none;
    }

    /// Add the control the new-control row describes; a refusal shows as `last_error`.
    fn addControl(self: *View, document: *Document) void {
        document.addControl(self.new_name.text(), @enumFromInt(self.new_kind)) catch |err| {
            self.last_error = err;
            return;
        };
        self.new_name.set("") catch {};
        self.resetMappings(document.state.controls.count() - 1);
    }

    /// The selected control's name and value type, and removing it; the document's refusals
    /// show as `last_error`.
    fn editSelected(self: *View, context: *ui.Context, document: *Document) !void {
        const index = @min(self.mappings.control_index, document.state.controls.count() - 1);
        const control = document.state.controls.values()[index];
        if (self.loaded_control != index) {
            try self.control_name.set(control.name);
            self.control_kind = @intFromEnum(control.kind);
            self.loaded_control = index;
        }
        context.separator();
        context.begin(.row);
        _ = context.textInput("Selected control name", &self.control_name, "Keep the FileMap enum in step with these names");
        restyle(context, .{ .grow = 1 });
        const rename = context.buttonVariant("Rename", .outline);
        endRow(context);
        context.begin(.row);
        _ = context.select("Selected control value", kinds, &self.control_kind);
        restyle(context, .{ .grow = 1 });
        const retype = context.buttonVariant("Change type", .outline);
        const remove = context.buttonVariant("Remove", .destructive);
        endRow(context);
        context.muted("Changing the type clears the control's bindings and trigger.");
        page_style.smallText(context, 12);
        const edited = if (rename)
            document.renameControl(index, self.control_name.text())
        else if (retype)
            document.setKind(index, @enumFromInt(self.control_kind))
        else if (remove)
            document.removeControl(index)
        else
            return;
        edited catch |err| {
            self.last_error = err;
            return;
        };
        self.resetMappings(if (remove) 0 else index);
    }
};

/// Save only after the complete replacement is validated by the document.
/// Editor-only: caller supplies validated bytes and a path relative to `dir`. Writes and
/// flushes a sibling atomic file before replacing the destination; I/O errors propagate and
/// atomic scratch state is cleaned up. Does not check for external changes or record history.
///
/// ```zig
/// try writeFile(io, project, "resources/player.inmap.zon", validated_zon);
/// // Existing I/O, open project directory and validated source.
/// ```
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
/// Editor undo/redo helper: parse `text` before reading the existing file (limited to 1 MiB),
/// require byte-for-byte `expected`, then replace atomically. Returns a caller-owned, saved
/// Document to deinit; validation/conflict/I/O failures clean it up and propagate.
///
/// ```zig
/// // Given allocator, I/O, project directory and a history step's before/after bytes:
/// var restored = try restoreFile(gpa, io, project, path, after, before);
/// defer restored.deinit();
/// ```
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

    /// Open a desktop editor window for a project-relative input map, reading at most 1 MiB.
    /// Owns the copied asset path, parsed document and heap window; borrows `project_dir` and
    /// the live font/graphics resources until `close`. Parse/I/O/window failures unwind allocations.
    ///
    /// ```zig
    /// // Given live editor graphics/font, allocator and project directory:
    /// const window = try Window.open(gpa, graphics, font, project_dir, "resources/player.inmap.zon");
    /// defer window.close(graphics);
    /// ```
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

    /// Close desktop render/window resources and destroy this heap-owned editor window once.
    /// Does not save: resolve unsaved-close confirmation before calling; the pointer becomes invalid.
    ///
    /// ```zig
    /// window.close(graphics); // Existing Window pointer and its owning Graphics.
    /// ```
    pub fn close(self: *Window, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.document.deinit();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    /// Test whether a project-relative path names this editor asset or an ancestor folder.
    /// Uses slash boundaries, not a raw filename prefix; does not inspect disk.
    ///
    /// ```zig
    /// const affected = window.affectedBy("resources"); // Existing input-map Window.
    /// ```
    pub fn affectedBy(self: *const Window, path: []const u8) bool {
        return std.mem.eql(u8, self.path, path) or
            (std.mem.startsWith(u8, self.path, path) and self.path.len > path.len and self.path[path.len] == '/');
    }

    /// Follow a renamed asset or containing folder without discarding its working document.
    /// Editor-only: `from`/`to` are project-relative slash-separated paths for an already
    /// completed move. Does no filesystem work; unaffected paths no-op, allocation failures
    /// propagate leaving the previous path intact.
    ///
    /// ```zig
    /// try window.moved("resources/input", "resources/controls"); // After moving the folder.
    /// ```
    pub fn moved(self: *Window, from: []const u8, to: []const u8) !void {
        if (!self.affectedBy(from)) return;
        const replacement = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ to, self.path[from.len..] });
        self.gpa.free(self.path);
        self.path = replacement;
    }

    /// Route desktop editor events to this window, prioritizing an active binding capture.
    /// Controller input may be captured without owning its window; returns true if consumed
    /// or window-owned. Borrowed event data is not retained.
    ///
    /// ```zig
    /// const used = window.handle(event); // Existing input-map Window and Eggy event.
    /// ```
    pub fn handle(self: *Window, event: eggy.Event) bool {
        if (self.view.mappings.capture != null and (self.window.owns(event) or eggy.game_ui.isControllerInput(event))) {
            if (self.view.mappings.captureEvent(event)) return true;
        }
        if (!self.window.owns(event)) return false;
        self.window.handle(event);
        return true;
    }

    /// Return true when this desktop editor window can close immediately for close/Escape.
    /// Escape is ignored during binding capture; a modified document instead opens confirmation
    /// and returns false. Does not destroy the window or write its file.
    ///
    /// ```zig
    /// if (window.closeRequested(event)) window.close(graphics); // Host-owned event/graphics.
    /// ```
    pub fn closeRequested(self: *Window, event: eggy.Event) bool {
        if (!self.window.owns(event)) return false;
        const requested = event == .window_close_requested or (self.view.mappings.capture == null and event == .key_down and event.key_down.scancode == .escape);
        if (!requested) return false;
        if (!self.document.modified()) return true;
        self.view.confirm_close = true;
        return false;
    }

    /// Refuse external changes, and reserve history before replacing the file atomically.
    /// Editor-only: validates/serializes at most 1 MiB, checks the loaded file hash, and records
    /// an owned before/after step only after replacement succeeds. Marks saved on success;
    /// unchanged bytes need no history step. Conflict/validation/history/I/O errors propagate.
    ///
    /// ```zig
    /// try window.save(&history); // Existing input-map Window and editor History.
    /// ```
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

    /// Re-read the editor asset from disk, discarding unsaved changes only after a valid parse.
    /// Replaces document/view state and loaded hash; I/O/parse failures preserve current state.
    /// Does not record history or change the live game's input state.
    ///
    /// ```zig
    /// try window.reload(); // Existing Window after the user chooses Revert.
    /// ```
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

    /// Apply editor input-map undo/redo to disk and this window, rejecting unsaved/external edits.
    /// `dir` is the project directory; `expected` is the current history side and `text` the
    /// target side. Validates and atomically replaces before swapping document/view/hash;
    /// conflicts, parse and I/O errors propagate without replacing the working document.
    ///
    /// ```zig
    /// try window.restore(io, project, after, before); // Undo with history bytes.
    /// ```
    pub fn restore(self: *Window, io: std.Io, dir: std.Io.Dir, expected: []const u8, text: []const u8) !void {
        if (self.document.modified()) return error.UnsavedInputMap;
        const replacement = try restoreFile(self.gpa, io, dir, self.path, expected, text);
        self.document.deinit();
        self.document = replacement;
        self.loaded_hash = std.hash.Wyhash.hash(0, text);
        self.view = .{};
    }

    /// Present one desktop editor frame, carrying out save/revert intents using `history`.
    /// Borrows the main UI's style and owning graphics; presentation failures propagate,
    /// while save/revert/build failures log and show in the view. The caller destroys the
    /// window when `close` is true and refreshes asset state when `saved` is true.
    ///
    /// ```zig
    /// const result = try window.update(graphics, style, &history); // Existing host objects.
    /// if (result.close) window.close(graphics);
    /// ```
    pub fn update(self: *Window, graphics: *eggy.Graphics, style: *const ui.Context, history: *history_zig.History) !struct { close: bool = false, saved: bool = false } {
        const Page = struct {
            owner: *Window,
            action: Action = .none,
            /// ToolWindow callback for this editor frame: build a scrollable input-map page,
            /// retaining its intent in `page.action`. Borrows owner/context synchronously;
            /// UI failures are logged and stored in the view, not returned.
            ///
            /// ```zig
            /// // Inside Window.update, with its local Page and a building UI context:
            /// page.build(context);
            /// ```
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
