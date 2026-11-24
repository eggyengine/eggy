//! The standalone `.inmap.zon` editor opened from Assets: the map and its controls in a rail,
//! the chosen one's settings beside it, each change saved as it is made.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const history_zig = @import("../history.zig");
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;
const control_page = @import("control_page.zig");
pub const Document = @import("document.zig").Document;

const rail_width: f32 = 208;
const add_height: f32 = 40;
const plus_glyph = "\u{f067}";

/// What the page shows: the whole map's settings, or one control by its index.
pub const Selection = union(enum) { map, control: usize };

/// Window-independent UI for an input-map asset.
pub const View = struct {
    selection: Selection = .map,
    rail_scroll: ui.Layout.ScrollState = .{},
    page_scroll: ui.Layout.ScrollState = .{},
    control: control_page.ControlPage = .{},
    priority: ui.TextEdit(32) = .{},
    priority_filled: bool = false,
    /// Why the last save or edit failed.
    last_error: ?anyerror = null,

    /// Fill every field from the document again, as after an undo, keeping what is selected.
    pub fn forget(self: *View) void {
        self.control.forget();
        self.priority_filled = false;
    }

    fn select(self: *View, selection: Selection) void {
        if (std.meta.eql(self.selection, selection)) return;
        self.selection = selection;
        self.control.forget();
        self.page_scroll = .{};
    }

    /// Build the editor page for `document`, editing it as fields change. `path` is the asset's
    /// project-relative path. UI allocation errors propagate; refused edits show on the page.
    ///
    /// ```zig
    /// try view.build(context, &document, "resources/player.inmap.zon");
    /// ```
    pub fn build(self: *View, context: *ui.Context, document: *Document, path: []const u8) !void {
        if (self.selection == .control and self.selection.control >= document.controls().len) self.select(.map);

        // Two panes the window's height, each scrolling on its own.
        const height = page_style.pageHeight(context);
        context.begin(.row);
        try self.rail(context, document, path, height);
        context.beginScroll(&self.page_scroll, height);
        if (!std.mem.startsWith(u8, path, "resources/")) context.alert("Not in resources/", "Move this file under resources/ to include it in builds.", false);
        if (self.last_error) |err| context.alert("Couldn't save the input map", describe(err), true);
        switch (self.selection) {
            .map => try self.mapPage(context, document),
            .control => |index| if (try self.control.build(context, document, index) == .removed) {
                const count = document.controls().len;
                self.select(if (count == 0) .map else .{ .control = @min(index, count - 1) });
            },
        }
        context.end();
        restyle(context, .{ .grow = 1, .gap = 14, .padding = .{ .left = 24, .right = 16, .top = 8, .bottom = 24 } });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 0, .align_items = .start });
    }

    /// The map, then each control with its value type, and Add control at the bottom.
    fn rail(self: *View, context: *ui.Context, document: *Document, path: []const u8, height: f32) !void {
        const arena = context.builder().allocator;
        const item_width = rail_width - 24;
        context.begin(.column);
        context.beginScroll(&self.rail_scroll, @max(1, height - add_height));
        const map_id = context.idFor("map settings");
        if (context.activated(map_id)) self.select(.map);
        page_style.navItem(context, map_id, mapTitle(path), .none, self.selection == .map, item_width, "Map settings");
        context.element(try context.builder().node(0, .{ .height = 8 }, .none, &.{}));
        for (document.controls(), 0..) |control, i| {
            const id = context.idFor(try std.fmt.allocPrint(arena, "control {d}", .{i}));
            if (context.activated(id)) self.select(.{ .control = i });
            const name = try arena.dupe(u8, control.name);
            const on = self.selection == .control and self.selection.control == i;
            page_style.navItem(context, id, name, .{ .detail = @tagName(control.kind) }, on, item_width, name);
        }
        context.end();
        restyle(context, .{ .gap = 2 });
        if (context.buttonVariant(plus_glyph ++ "  Add control", .ghost)) {
            var buffer: [32]u8 = undefined;
            if (document.addControl(document.freeName(&buffer), .button)) |_| {
                self.select(.{ .control = document.controls().len - 1 });
            } else |err| self.last_error = err;
        }
        restyle(context, .{ .width = item_width });
        context.end();
        if (context.last_added) |column| column.style = .{ .width = rail_width, .height = height, .justify = .space_between, .padding = .{ .right = 12 } };
        page_style.railBackdrop(context);
    }

    /// How the whole map starts and shares input with other maps.
    fn mapPage(self: *View, context: *ui.Context, document: *Document) !void {
        const settings = document.mapSettings();
        if (!self.priority_filled) {
            var buffer: [32]u8 = undefined;
            try self.priority.set(try std.fmt.bufPrint(&buffer, "{d}", .{settings.priority}));
            self.priority_filled = true;
        }
        var next = settings;
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        rows.begin(context, "Enabled at startup", "");
        _ = context.toggle("##enabled at startup", &next.enabled);
        rows.end(context);
        rows.begin(context, "Priority", "Higher maps read shared inputs first.");
        // In a row, like the control page's number fields, so it keeps its width; at the
        // row's end, in line with the toggles.
        context.begin(.row);
        page_style.spacer(context);
        const typed = context.textInput("##priority", &self.priority, "");
        restyle(context, .{ .width = 64 });
        page_style.endRow(context);
        restyle(context, .{ .width = SettingRows.control_width });
        const priority = std.fmt.parseInt(i32, std.mem.trim(u8, self.priority.text(), " "), 10) catch null;
        if (priority == null) {
            context.muted("A whole number.");
            page_style.smallText(context, 12);
        }
        if (typed) if (priority) |value| {
            next.priority = value;
        };
        rows.end(context);
        rows.begin(context, "Consume shared inputs", "Inputs this map uses don't reach lower-priority maps.");
        _ = context.toggle("##consume shared inputs", &next.consume);
        rows.end(context);
        setting_rows.endGroup(context);
        if (!std.meta.eql(next, settings)) document.setMapSettings(next) catch |err| {
            self.last_error = err;
        };
    }
};

/// The asset's file name without `.inmap.zon`: "player" for `resources/player.inmap.zon`.
fn mapTitle(path: []const u8) []const u8 {
    const name = std.fs.path.basenamePosix(path);
    return if (std.mem.endsWith(u8, name, eggy.input.asset.extension)) name[0 .. name.len - eggy.input.asset.extension.len] else name;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.InputMapChangedExternally => "The file changed outside the editor, so it was read again without your last change.",
        error.InputMapTooLarge => "It would be over 1 MiB.",
        error.OutOfMemory => "Out of memory.",
        else => @errorName(err),
    };
}

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
    /// Every edit is already saved; the pointer becomes invalid.
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

    /// Route desktop editor events to this window, a binding capture first: a controller
    /// button may be captured without the window owning it. Returns true if consumed or
    /// window-owned. Borrowed event data is not retained.
    ///
    /// ```zig
    /// const used = window.handle(event); // Existing input-map Window and Eggy event.
    /// ```
    pub fn handle(self: *Window, event: eggy.Event) bool {
        if (self.view.control.capturing() and self.view.selection == .control and (self.window.owns(event) or eggy.game_ui.isControllerInput(event))) {
            if (self.view.control.captureEvent(event, &self.document, self.view.selection.control)) return true;
        }
        if (!self.window.owns(event)) return false;
        self.window.handle(event);
        return true;
    }

    /// Ctrl+Z (undo) or Ctrl+Shift+Z / Ctrl+Y (redo) pressed in this window outside a text
    /// field, for the editor's History; null for any other event.
    ///
    /// ```zig
    /// if (window.undoShortcut(event)) |direction| editor.undoOrRedo(direction);
    /// ```
    pub fn undoShortcut(self: *const Window, event: eggy.Event) ?eggy.Direction {
        if (!self.window.owns(event) or event != .key_down or self.window.ui.wants_text or self.view.control.capturing()) return null;
        const key_down = event.key_down;
        if (!key_down.mod.controlDown()) return null;
        const key = key_down.key orelse return null;
        return switch (key) {
            .z => if (key_down.mod.shiftDown()) .redo else .undo,
            .y => .redo,
            else => null,
        };
    }

    /// Whether `event` closes this window: its close button, or Escape when no key is being
    /// captured. Every edit is already saved, so it can close at once.
    ///
    /// ```zig
    /// if (window.closeRequested(event)) window.close(graphics); // Host-owned event/graphics.
    /// ```
    pub fn closeRequested(self: *Window, event: eggy.Event) bool {
        if (!self.window.owns(event)) return false;
        return event == .window_close_requested or (!self.view.control.capturing() and event == .key_down and event.key_down.scancode == .escape);
    }

    /// Write the document over the file and record the change in `history`, joining the last
    /// step while typing (`now_ms`, monotonic). Refuses (`error.InputMapChangedExternally`) when
    /// the file changed since it was read; validation/history/I/O errors propagate.
    ///
    /// ```zig
    /// try window.save(&history, now_ms); // Existing input-map Window and editor History.
    /// ```
    pub fn save(self: *Window, history: *history_zig.History, now_ms: u64) !void {
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
        self.loaded_hash = std.hash.Wyhash.hash(0, after);
        self.document.markSaved();
        history.recordFileEdit(.input_map, path, before, after, now_ms);
    }

    /// Re-read the asset from disk, replacing the document only after a valid parse and filling
    /// the page's fields again. I/O/parse failures keep the current state.
    ///
    /// ```zig
    /// try window.reload(); // Existing Window after the file changed outside the editor.
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
        self.view.forget();
    }

    /// Apply an undo/redo step to disk and this window. `dir` is the project directory;
    /// `expected` is the current history side and `text` the target side. Validates and
    /// atomically replaces before swapping the document; conflicts, parse and I/O errors
    /// propagate without changing it.
    ///
    /// ```zig
    /// try window.restore(io, project, after, before); // Undo with history bytes.
    /// ```
    pub fn restore(self: *Window, io: std.Io, dir: std.Io.Dir, expected: []const u8, text: []const u8) !void {
        const replacement = try restoreFile(self.gpa, io, dir, self.path, expected, text);
        self.document.deinit();
        self.document = replacement;
        self.loaded_hash = std.hash.Wyhash.hash(0, text);
        self.view.forget();
    }

    /// Present one frame, then save what it changed into `history` (`now_ms`: monotonic).
    /// Presentation failures propagate; save failures log and show on the page. Returns whether
    /// the file was written, for the host to refresh asset state.
    ///
    /// ```zig
    /// if (try window.update(graphics, style, &history, now_ms)) assets.refreshSoon();
    /// ```
    pub fn update(self: *Window, graphics: *eggy.Graphics, style: *const ui.Context, history: *history_zig.History, now_ms: u64) !bool {
        const Page = struct {
            owner: *Window,
            /// ToolWindow callback for this editor frame. UI failures are logged and shown.
            pub fn build(page: *@This(), context: *ui.Context) void {
                const view = &page.owner.view;
                view.build(context, &page.owner.document, page.owner.path) catch |err| {
                    view.last_error = err;
                    std.log.err("cannot draw input map {s}: {t}", .{ page.owner.path, err });
                };
            }
        };
        var page = Page{ .owner = self };
        try self.window.present(graphics, style, &page);
        if (!self.document.modified()) return false;
        self.save(history, now_ms) catch |err| {
            self.view.last_error = err;
            std.log.err("cannot save input map {s}: {t}", .{ self.path, err });
            if (err == error.InputMapChangedExternally) self.reload() catch |reload_err| std.log.err("cannot read input map {s} again: {t}", .{ self.path, reload_err });
            return false;
        };
        self.view.last_error = null;
        return true;
    }
};

test "the map page and a control page lay out, and removing the last control shows the map" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, ".{}");
    defer document.deinit();
    var view = View{};
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    context.density = .compact;
    context.newFrame(.{ .x = 0, .y = 0, .w = 760, .h = 780 });
    try view.build(&context, &document, "resources/player.inmap.zon");
    try std.testing.expect((try context.render()).len > 0);
    try document.addControl("move", .vector);
    try document.setBindings(0, &.{ .{ .keys_2d = .{} }, .{ .controller_stick = .{} }, .{ .mouse_delta = .{} } });
    view.select(.{ .control = 0 });
    context.newFrame(.{ .x = 0, .y = 0, .w = 760, .h = 780 });
    try view.build(&context, &document, "resources/player.inmap.zon");
    try std.testing.expect((try context.render()).len > 0);
    try std.testing.expectEqualStrings("move", view.control.name.text());
    try document.removeControl(0);
    context.newFrame(.{ .x = 0, .y = 0, .w = 760, .h = 780 });
    try view.build(&context, &document, "resources/player.inmap.zon");
    try std.testing.expect(view.selection == .map);
    try std.testing.expectEqualStrings("player", mapTitle("resources/player.inmap.zon"));
}

test "a captured key goes into the binding and Escape cancels a capture" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, ".{ .controls = .{ .{ .name = \"move\", .kind = .vector, .bindings = .{ .{ .keys_2d = .{} } } } } }");
    defer document.deinit();
    var page = control_page.ControlPage{ .capture = .{ .binding = 0, .part = .left } };
    const press = struct {
        fn key(scancode: eggy.Key) eggy.Event {
            return .{ .key_down = .{ .common = undefined, .id = null, .scancode = scancode, .key = null, .mod = .{}, .raw = 0, .down = true, .repeat = false } };
        }
    };
    try std.testing.expect(page.captureEvent(press.key(.j), &document, 0));
    try std.testing.expectEqual(eggy.Key.j, document.controls()[0].defaults[0].keys_2d.keys.left);
    try std.testing.expect(document.modified());
    page.capture = .{ .binding = 0, .part = .up };
    try std.testing.expect(page.captureEvent(press.key(.escape), &document, 0));
    try std.testing.expect(!page.capturing());
    try std.testing.expectEqual(eggy.Key.w, document.controls()[0].defaults[0].keys_2d.keys.up);
}

test "each edit saves with one coalesced undo step and refuses external changes" {
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
    try window.save(&history, 1000);
    try window.document.renameControl(0, "jum");
    try window.save(&history, 1200);
    try std.testing.expect(!window.document.modified());
    try std.testing.expectEqual(@as(usize, 1), history.undo_steps.items.len);
    try window.document.renameControl(0, "hop");
    try window.save(&history, 5000);
    try std.testing.expectEqual(@as(usize, 2), history.undo_steps.items.len);
    const change = history.undo_steps.items[1].input_map;
    try window.restore(io, tmp.dir, change.text.after, change.text.before);
    try std.testing.expectEqualStrings("jum", window.document.controls()[0].name);
    try window.restore(io, tmp.dir, change.text.before, change.text.after);
    try std.testing.expectEqualStrings("hop", window.document.controls()[0].name);
    try tmp.dir.writeFile(io, .{ .sub_path = "player.inmap.zon", .data = ".{ .priority = 9 }" });
    try window.document.renameControl(0, "jump");
    try std.testing.expectError(error.InputMapChangedExternally, window.save(&history, 9000));
    try std.testing.expectEqual(@as(usize, 2), history.undo_steps.items.len);
    try window.reload();
    try std.testing.expect(!window.document.modified());
    try std.testing.expectEqual(@as(i32, 9), window.document.mapSettings().priority);
    try std.testing.expectError(error.InputMapChangedExternally, window.restore(io, tmp.dir, change.text.after, change.text.before));
    try window.moved("player.inmap.zon", "menu.inmap.zon");
    try std.testing.expectEqualStrings("menu.inmap.zon", window.path);
    try std.testing.expect(!window.affectedBy("menu.inmap"));
}

test {
    _ = @import("document.zig");
    _ = @import("control_page.zig");
}
