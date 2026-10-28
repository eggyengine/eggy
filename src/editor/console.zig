//! The Console's clickable terminal lines with level filters and selectable diagnostic details.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const console_log = @import("console_log.zig");
const terminal_view = @import("terminal_view.zig");
const diagnostic = @import("diagnostic.zig");
const restyle = @import("page_style.zig").restyle;

/// The level chips, in the order they sit in the toolbar.
const level_chips = [_]struct { level: std.log.Level, label: []const u8 }{
    .{ .level = .err, .label = "Errors" },
    .{ .level = .warn, .label = "Warnings" },
    .{ .level = .info, .label = "Info" },
    .{ .level = .debug, .label = "Debug" },
};
const chip_height: f32 = 26;
const chip_padding: f32 = 10;
const chip_gap: f32 = 6;
const chip_text_size: f32 = 12;
const dot_size: f32 = 7;
/// Room under the messages for the dev console's prompt and the candidates under it.
const command_line_height: f32 = 32 + 22 + 12;

/// The dev console's prompt under the messages: what it runs on and with. Its output is logged
/// (`DevConsole.log_output`), so it shows among the messages.
pub const CommandLine = struct {
    app: *eggy.App,
    commands: eggy.dev_console.Commands,
};

/// A level chip's paint state, for the frame it is drawn in.
const LevelChip = struct {
    id: u32,
    label: []const u8,
    count: []const u8,
    color: ui.Color,
    shown: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const LevelChip = @ptrCast(@alignCast(context));
        const theme = c.theme;
        const radius = r.h / 2;
        // Filled in the level's colour while shown, outlined while hidden, lifted under the pointer.
        if (self.shown) try c.roundRectAlpha(r, self.color, radius, 0.14) else try c.roundRectStroke(r, theme.border, radius, 1);
        if (c.hot_id == self.id) try c.roundRectAlpha(r, theme.foreground, radius, 0.06);
        const dot = ui.Rect{ .x = r.x + chip_padding, .y = r.y + (r.h - dot_size) / 2, .w = dot_size, .h = dot_size };
        if (self.shown) try c.roundRect(dot, self.color, dot_size / 2) else try c.roundRectStroke(dot, self.color, dot_size / 2, 1.2);
        // The name, then the count after it, quieter.
        const label_x = dot.x + dot_size + chip_gap;
        const label_w = c.font.measure(self.label, chip_text_size);
        try c.textIn(.{ .x = label_x, .y = r.y, .w = label_w + 1, .h = r.h }, self.label, chip_text_size, if (self.shown) theme.foreground else theme.muted_foreground, .start);
        try c.textIn(.{ .x = label_x + label_w + chip_gap, .y = r.y, .w = r.x + r.w - (label_x + label_w + chip_gap), .h = r.h }, self.count, chip_text_size, theme.muted_foreground, .start);
    }
};

const grip_height: f32 = 10;
const min_detail_height: f32 = 60;
const min_list_height: f32 = 60;

/// The resize bar's paint state: a short rounded grip, in the accent while held or hovered.
const Grip = struct {
    id: u32,
    held: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Grip = @ptrCast(@alignCast(context));
        const lit = self.held or c.hot_id == self.id;
        const bar = ui.Rect{ .x = r.x + (r.w - 36) / 2, .y = r.y + (r.h - 3) / 2, .w = 36, .h = 3 };
        try c.roundRect(bar, if (lit) c.theme.primary else c.theme.border, 1.5);
    }
};

const Filtered = struct { log: u64, levels: [4]bool, query_hash: u64, hidden: u64 };

pub const Console = struct {
    gpa: std.mem.Allocator,
    query: ui.TextEdit(128),
    /// Levels shown, indexed by `std.log.Level`; debug (Vitellus's chatter) starts hidden.
    levels: [4]bool = .{ true, true, true, false },
    /// Only the selected message is shown in the detail view.
    selected: ?u64 = null,
    terminal: terminal_view.TerminalView,
    scroll: ui.Layout.ScrollState = .{ .message_mode = true, .auto_scroll = true },
    hidden: std.AutoHashMapUnmanaged(u64, void) = .empty,
    hidden_version: u64 = 0,
    /// The messages shown, and what they were filtered from: a long log is filtered again only
    /// when it, the levels or the filter change, not every frame.
    shown: console_log.Messages = .{},
    counts: console_log.Snapshot = .{ .shown = 0, .total = 0 },
    filtered: ?Filtered = null,
    /// How tall the details are, as last dragged; and the drag in progress, from where it began.
    detail_height: f32 = 220,
    resizing: ?struct { pointer_y: f32, height: f32 } = null,

    /// Create the editor Console's lazy filter/selection state; `mono` is borrowed
    /// until `deinit` and must be a loaded font before the first `build`.
    ///
    /// ```zig
    /// var console = Console.init(gpa, mono);
    /// defer console.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font) Console {
        return .{ .gpa = gpa, .query = ui.TextEdit(128).init("") catch unreachable, .terminal = .init(gpa, mono) };
    }

    /// Free cached snapshots, hidden IDs, and the terminal; does not free `mono`
    /// or clear the process-wide log. Do not use the Console afterward.
    ///
    /// ```zig
    /// console.deinit(); // Before unloading its borrowed monospaced font.
    /// ```
    pub fn deinit(self: *Console) void {
        self.terminal.deinit();
        self.shown.deinit(self.gpa);
        self.hidden.deinit(self.gpa);
    }

    /// Draw the panel's page into `context`, with `command_line`'s prompt at the bottom if given.
    /// Call in an active UI frame. `project_dir` enables source links, or null disables them.
    /// A clicked location borrows cached diagnostic text until the next refresh/deinit;
    /// consume it promptly. Failures populate `context.err` and return null.
    ///
    /// ```zig
    /// // Editor panel builder, after context.newFrame:
    /// if (console.build(context, project_dir, null)) |source| {
    ///     std.log.info("open {s}:{d}:{d}", .{ source.path, source.line, source.column });
    /// }
    /// ```
    pub fn build(self: *Console, context: *ui.Context, project_dir: ?[]const u8, command_line: ?CommandLine) ?diagnostic.Location {
        return self.buildPage(context, project_dir, command_line) catch |err| {
            context.err = context.err orelse err;
            return null;
        };
    }

    fn buildPage(self: *Console, context: *ui.Context, project_dir: ?[]const u8, command_line: ?CommandLine) !?diagnostic.Location {
        self.terminal.area = null;
        const arena = context.builder().allocator;
        // Filtering whole entries keeps source context visible even when Info is switched off.
        try self.refresh();

        // One toolbar: the levels shown, the filter, what is shown of the log, and its actions.
        context.begin(.row);
        for (level_chips) |chip| try self.levelChip(context, chip.level, chip.label);
        _ = context.textInput("Filter", &self.query, "Filter messages");
        restyle(context, .{ .grow = 1 });
        context.muted(try std.fmt.allocPrint(arena, "{d} of {d}", .{ self.counts.shown, self.counts.total }));
        if (self.hidden.count() > 0 and context.buttonVariant(try std.fmt.allocPrint(arena, "Show {d} hidden", .{self.hidden.count()}), .ghost)) {
            self.hidden.clearRetainingCapacity();
            self.hidden_version +%= 1;
            try self.refresh();
        }
        if (context.buttonVariant("Copy shown", .ghost)) terminal_view.copyToClipboard(self.shown.text.items);
        if (context.buttonVariant("Clear", .ghost)) {
            console_log.clear();
            self.hidden.clearRetainingCapacity();
            self.hidden_version +%= 1;
            self.selected = null;
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 6, .align_items = .center });

        // The list takes what the details, dragged to the height wanted, leave of the page.
        const available = @max(120, context.viewport.h - 114 - if (command_line != null) command_line_height else 0);
        const detail_height = std.math.clamp(self.detail_height, min_detail_height, @max(min_detail_height, available - 44 - grip_height - min_list_height));
        try self.messageRows(context, if (self.selected != null) @max(min_list_height, available - detail_height - 44 - grip_height) else available);
        var source: ?diagnostic.Location = null;
        if (self.selectedEntry()) |entry| {
            try self.resizeGrip(context, detail_height);
            context.begin(.row);
            if (project_dir) |dir| if (diagnostic.projectSource(self.shown.text.items[entry.start..entry.end], dir)) |at| {
                const label = try std.fmt.allocPrint(arena, "Open {s}:{d}:{d}", .{ at.path, at.line, at.column });
                if (context.buttonVariant(label, .ghost)) source = at;
            };
            if (context.buttonVariant("Copy message", .ghost)) terminal_view.copyToClipboard(self.terminal.selectedText() orelse self.shown.text.items[entry.start..entry.end]);
            if (context.buttonVariant("Hide message", .ghost)) {
                try self.hidden.put(self.gpa, entry.id, {});
                self.hidden_version +%= 1;
                self.selected = null;
            }
            if (context.buttonVariant("Close details", .ghost)) self.selected = null;
            context.end();
            if (self.selected != null) {
                const changed = self.terminal.version != entry.id;
                self.terminal.add(context, self.shown.text.items[entry.start..entry.end], entry.id, detail_height);
                if (changed) self.terminal.scroll_rows = self.terminal.content().len;
            }
        }
        if (command_line) |line| line.app.dev_console.buildPrompt(line.app, line.commands, context, .{});
        return source;
    }

    /// The bar between the list and the details: dragging it up or down makes the details
    /// taller or shorter, from `shown_height` (their height this frame).
    fn resizeGrip(self: *Console, context: *ui.Context, shown_height: f32) !void {
        const b = context.builder();
        const id = context.idFor("console-details-resize");
        // A press on it holds the pointer, as weeoui's sliders do, until the button is let go.
        if (context.pressed_down) if (context.press) |press| if (press.widget == id) {
            context.active = id;
            self.resizing = .{ .pointer_y = context.pointer.y, .height = shown_height };
        };
        if (context.active != id) self.resizing = null;
        if (self.resizing) |start| self.detail_height = @max(min_detail_height, start.height + start.pointer_y - context.pointer.y);

        const grip = try b.allocator.create(Grip);
        grip.* = .{ .id = id, .held = self.resizing != null };
        const element = try b.node(id, .{ .width = context.contentWidth(), .height = grip_height }, .{ .custom = .{ .context = grip, .draw = Grip.draw } }, &.{});
        element.accessibility = .{ .role = .slider, .label = "Resize message details", .numeric_value = shown_height };
        element.cursor = .ns_resize;
        context.element(element);
    }

    fn refresh(self: *Console) !void {
        const now = Filtered{ .log = console_log.changes(), .levels = self.levels, .query_hash = std.hash.Wyhash.hash(0, self.query.text()), .hidden = self.hidden_version };
        if (self.filtered != null and std.meta.eql(self.filtered.?, now)) return;
        self.counts = try console_log.snapshot(self.gpa, &self.shown, .{ .levels = self.levels, .query = self.query.text(), .hidden = &self.hidden });
        self.filtered = now;
        if (self.selectedEntry() == null) self.selected = null;
    }

    fn messageRows(self: *Console, context: *ui.Context, height: f32) !void {
        const b = context.builder();
        var lines: std.ArrayList(*ui.Layout.Element) = .empty;
        if (self.shown.entries.items.len == 0) {
            const empty = if (self.counts.total == 0) "Nothing has been logged yet." else "No messages match. Clear the filter or turn on more levels.";
            try lines.append(b.allocator, try terminal_view.messageLine(b, self.terminal.mono, 0, empty, null, false));
        }
        for (self.shown.entries.items) |entry| {
            const id = context.idFor(try std.fmt.allocPrint(b.allocator, "console-message-{d}", .{entry.id}));
            if (context.activated(id)) {
                self.selected = if (self.selected == entry.id) null else entry.id;
                self.terminal.version = null;
                self.terminal.selection = null;
                self.terminal.focused = false;
                self.scroll.following_messages = false;
            }
            const summary = self.shown.text.items[entry.start..entry.summary_end];
            try lines.append(b.allocator, try terminal_view.messageLine(b, self.terminal.mono, id, summary, entry.level, self.selected == entry.id));
        }
        context.element(try terminal_view.messageList(b, context.contentWidth(), height, &self.scroll, lines.items));
    }

    /// A pill that shows or hides `level`'s messages: a dot in the level's colour, its name and
    /// how many there are; filled while they are shown, hollow while hidden.
    fn levelChip(self: *Console, context: *ui.Context, level: std.log.Level, label: []const u8) !void {
        const b = context.builder();
        const id = context.idFor(try std.fmt.allocPrint(b.allocator, "console-level-{t}", .{level}));
        const shown = &self.levels[@backingInt(level)];
        if (context.activated(id)) shown.* = !shown.*;
        const count = try std.fmt.allocPrint(b.allocator, "{d}", .{self.counts.per_level[@backingInt(level)]});
        const chip = try b.allocator.create(LevelChip);
        chip.* = .{ .id = id, .label = label, .count = count, .color = terminal_view.levelColor(level), .shown = shown.* };
        const width = chip_padding * 2 + dot_size + chip_gap + context.font.measure(label, chip_text_size) + chip_gap + context.font.measure(count, chip_text_size);
        const element = try b.node(id, .{ .width = width, .height = chip_height }, .{ .custom = .{ .context = chip, .draw = LevelChip.draw } }, &.{});
        element.accessibility = .{ .role = .checkbox, .label = try std.fmt.allocPrint(b.allocator, "{s} ({s})", .{ label, count }), .description = if (shown.*) "shown" else "hidden" };
        element.cursor = .pointer;
        context.element(element);
    }

    fn selectedEntry(self: *const Console) ?console_log.Entry {
        const selected = self.selected orelse return null;
        for (self.shown.entries.items) |entry| if (entry.id == selected) return entry;
        return null;
    }
};

test "level filters retain error details and close a filtered or hidden selection" {
    defer console_log.clear();
    console_log.logFn(.err, .zig_build, "src/main.zig:1:1: error: broken\n    source context", .{});
    console_log.logFn(.warn, .default, "warning", .{});
    console_log.logFn(.info, .default, "info", .{});
    console_log.logFn(.debug, .default, "debug", .{});
    var console = Console.init(std.testing.allocator, undefined);
    defer console.deinit();
    console.levels = .{ true, false, false, false };
    try console.refresh();
    try std.testing.expectEqual(@as(usize, 1), console.shown.entries.items.len);
    console.selected = console.shown.entries.items[0].id;
    try std.testing.expect(std.mem.indexOf(u8, console.shown.text.items, "source context") != null);
    console.levels = .{ false, true, false, false };
    try console.refresh();
    try std.testing.expect(console.selected == null);
    try std.testing.expectEqual(std.log.Level.warn, console.shown.entries.items[0].level);
    console.levels = .{ false, false, true, false };
    try console.refresh();
    try std.testing.expectEqual(std.log.Level.info, console.shown.entries.items[0].level);
    console.levels = .{ false, false, false, true };
    try console.refresh();
    try std.testing.expectEqual(std.log.Level.debug, console.shown.entries.items[0].level);
    console.selected = console.shown.entries.items[0].id;
    try console.hidden.put(std.testing.allocator, console.selected.?, {});
    console.hidden_version +%= 1;
    try console.refresh();
    try std.testing.expect(console.selected == null);
    try std.testing.expectEqual(@as(usize, 0), console.counts.shown);
}

test "console summaries expand, link to project source, hide and restore through the UI" {
    defer console_log.clear();
    console_log.logFn(.err, .zig_build, "src/root.zig:69:9: error: broken hook\n    source context", .{});
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var console = Console.init(std.testing.allocator, context.font);
    defer console.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 640, .h = 600 };
    const Find = struct {
        fn labelled(root: *const ui.Layout.Element, label: []const u8) ?*const ui.Layout.Element {
            const value = root.accessibility.label orelse switch (root.paint_kind) {
                .button => |button| button.label,
                else => "",
            };
            if (std.mem.eql(u8, value, label)) return root;
            for (root.children) |child| if (labelled(child, label)) |found| return found;
            return null;
        }
    };
    context.newFrame(viewport);
    _ = console.build(&context, "/game", null);
    _ = try context.render();
    const summary = Find.labelled(context.last_root.?, "error(zig_build): src/root.zig:69:9: error: broken hook").?;
    try std.testing.expectEqual(@as(?bool, false), summary.accessibility.expanded);
    const summary_id = summary.id;
    context.newFrame(viewport);
    context.a11y_clicked = summary_id;
    _ = console.build(&context, "/game", null);
    _ = try context.render();
    try std.testing.expect(console.selected != null);
    try std.testing.expect(std.mem.indexOf(u8, console.terminal.content(), "source context") != null);
    const source_id = Find.labelled(context.last_root.?, "Open src/root.zig:69:9").?.id;
    context.newFrame(viewport);
    context.a11y_clicked = source_id;
    const source = console.build(&context, "/game", null).?;
    _ = try context.render();
    try std.testing.expectEqualStrings("src/root.zig", source.path);
    try std.testing.expectEqual(@as(u32, 69), source.line);
    const hide_id = Find.labelled(context.last_root.?, "Hide message").?.id;
    context.newFrame(viewport);
    context.a11y_clicked = hide_id;
    _ = console.build(&context, "/game", null);
    _ = try context.render();
    try std.testing.expect(console.selected == null);
    try std.testing.expectEqual(@as(usize, 1), console.hidden.count());
    context.newFrame(viewport);
    _ = console.build(&context, "/game", null);
    _ = try context.render();
    try std.testing.expectEqual(@as(usize, 0), console.counts.shown);
    const restore_id = Find.labelled(context.last_root.?, "Show 1 hidden").?.id;
    context.newFrame(viewport);
    context.a11y_clicked = restore_id;
    _ = console.build(&context, "/game", null);
    _ = try context.render();
    try std.testing.expectEqual(@as(usize, 1), console.counts.shown);
    try std.testing.expectEqual(@as(usize, 0), console.hidden.count());
}

test "dragging the grip above the details makes them taller, and letting go stops it" {
    defer console_log.clear();
    console_log.logFn(.err, .default, "broken\n    source context", .{});
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var console = Console.init(std.testing.allocator, context.font);
    defer console.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 640, .h = 600 };
    try console.refresh();
    console.selected = console.shown.entries.items[0].id;
    context.newFrame(viewport);
    _ = console.build(&context, null, null);
    _ = try context.render();
    const grip = gripId(context.last_root.?).?;

    // Pressed on the grip, then moved 50 up while held: the details grow by 50.
    context.newFrame(viewport);
    context.pointer = .{ .x = 320, .y = 300 };
    context.pressed_down = true;
    context.pointer_held = true;
    context.press = .{ .at = context.pointer, .widget = grip };
    _ = console.build(&context, null, null);
    _ = try context.render();
    context.newFrame(viewport);
    context.pointer.y = 250;
    _ = console.build(&context, null, null);
    _ = try context.render();
    try std.testing.expectEqual(@as(f32, 270), console.detail_height);

    // Let go, and moving no longer resizes.
    context.newFrame(viewport);
    context.active = 0;
    context.pointer_held = false;
    context.pointer.y = 100;
    _ = console.build(&context, null, null);
    _ = try context.render();
    try std.testing.expectEqual(@as(f32, 270), console.detail_height);
}

/// The id of the details' resize grip in a rendered tree, found by its label.
fn gripId(root: *const ui.Layout.Element) ?u32 {
    if (root.accessibility.label) |label| if (std.mem.eql(u8, label, "Resize message details")) return root.id;
    for (root.children) |child| if (gripId(child)) |found| return found;
    return null;
}
