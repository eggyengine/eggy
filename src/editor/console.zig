//! The Console's clickable terminal lines with level filters and selectable diagnostic details.
const std = @import("std");
const ui = @import("eggy").ui;
const console_log = @import("console_log.zig");
const terminal_view = @import("terminal_view.zig");
const diagnostic = @import("diagnostic.zig");

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

    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font) Console {
        return .{ .gpa = gpa, .query = ui.TextEdit(128).init("") catch unreachable, .terminal = .init(gpa, mono) };
    }

    pub fn deinit(self: *Console) void {
        self.terminal.deinit();
        self.shown.deinit(self.gpa);
        self.hidden.deinit(self.gpa);
    }

    /// Draw the panel's page into `context`.
    pub fn build(self: *Console, context: *ui.Context, project_dir: ?[]const u8) ?diagnostic.Location {
        return self.buildPage(context, project_dir) catch |err| {
            context.err = context.err orelse err;
            return null;
        };
    }

    fn buildPage(self: *Console, context: *ui.Context, project_dir: ?[]const u8) !?diagnostic.Location {
        self.terminal.area = null;
        context.begin(.row);
        _ = context.textInput("Filter", &self.query, "Filter messages");
        if (context.buttonVariant("Clear", .outline)) {
            console_log.clear();
            self.hidden.clearRetainingCapacity();
            self.hidden_version +%= 1;
            self.selected = null;
        }
        if (self.hidden.count() > 0 and context.buttonVariant("Restore hidden", .ghost)) {
            self.hidden.clearRetainingCapacity();
            self.hidden_version +%= 1;
        }
        context.end();
        context.begin(.row);
        _ = context.checkbox("Errors", &self.levels[@intFromEnum(std.log.Level.err)]);
        _ = context.checkbox("Warnings", &self.levels[@intFromEnum(std.log.Level.warn)]);
        _ = context.checkbox("Info", &self.levels[@intFromEnum(std.log.Level.info)]);
        _ = context.checkbox("Debug", &self.levels[@intFromEnum(std.log.Level.debug)]);
        context.end();

        // Filtering whole entries keeps source context visible even when Info is switched off.
        try self.refresh();
        context.begin(.row);
        context.muted(try std.fmt.allocPrint(context.builder().allocator, "{d} of {d} messages ({d} hidden)", .{ self.counts.shown, self.counts.total, self.hidden.count() }));
        if (context.buttonVariant("Copy shown", .ghost)) terminal_view.copyToClipboard(self.shown.text.items);
        context.end();

        const available = @max(120, context.viewport.h - 190);
        const detail_height = @min(220, available * 0.5);
        try self.messageRows(context, if (self.selected != null) @max(60, available - detail_height - 44) else available);
        var source: ?diagnostic.Location = null;
        if (self.selectedEntry()) |entry| {
            context.begin(.row);
            if (project_dir) |dir| if (diagnostic.projectSource(self.shown.text.items[entry.start..entry.end], dir)) |at| {
                const label = try std.fmt.allocPrint(context.builder().allocator, "Open {s}:{d}:{d}", .{ at.path, at.line, at.column });
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
        return source;
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
        if (self.shown.entries.items.len == 0) try lines.append(b.allocator, try terminal_view.messageLine(b, self.terminal.mono, 0, "No matching messages.", false));
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
            try lines.append(b.allocator, try terminal_view.messageLine(b, self.terminal.mono, id, summary, self.selected == entry.id));
        }
        context.element(try terminal_view.messageList(b, context.contentWidth(), height, &self.scroll, lines.items));
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
    _ = console.build(&context, "/game");
    _ = try context.render();
    const summary = Find.labelled(context.last_root.?, "error(zig_build): src/root.zig:69:9: error: broken hook").?;
    try std.testing.expectEqual(@as(?bool, false), summary.accessibility.expanded);
    const summary_id = summary.id;
    context.newFrame(viewport);
    context.a11y_clicked = summary_id;
    _ = console.build(&context, "/game");
    _ = try context.render();
    try std.testing.expect(console.selected != null);
    try std.testing.expect(std.mem.indexOf(u8, console.terminal.content(), "source context") != null);
    const source_id = Find.labelled(context.last_root.?, "Open src/root.zig:69:9").?.id;
    context.newFrame(viewport);
    context.a11y_clicked = source_id;
    const source = console.build(&context, "/game").?;
    _ = try context.render();
    try std.testing.expectEqualStrings("src/root.zig", source.path);
    try std.testing.expectEqual(@as(u32, 69), source.line);
    const hide_id = Find.labelled(context.last_root.?, "Hide message").?.id;
    context.newFrame(viewport);
    context.a11y_clicked = hide_id;
    _ = console.build(&context, "/game");
    _ = try context.render();
    try std.testing.expect(console.selected == null);
    try std.testing.expectEqual(@as(usize, 1), console.hidden.count());
    context.newFrame(viewport);
    _ = console.build(&context, "/game");
    _ = try context.render();
    try std.testing.expectEqual(@as(usize, 0), console.counts.shown);
    const restore_id = Find.labelled(context.last_root.?, "Restore hidden").?.id;
    context.newFrame(viewport);
    context.a11y_clicked = restore_id;
    _ = console.build(&context, "/game");
    _ = try context.render();
    try std.testing.expectEqual(@as(usize, 1), console.counts.shown);
    try std.testing.expectEqual(@as(usize, 0), console.hidden.count());
}
