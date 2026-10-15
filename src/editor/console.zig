//! The Console panel: the editor's log (see `console_log.zig`) in a terminal view, with a filter,
//! a toggle per level, Clear, and Copy.
const std = @import("std");
const ui = @import("eggy").ui;
const console_log = @import("console_log.zig");
const terminal_view = @import("terminal_view.zig");

const Filtered = struct { log: u64, levels: [4]bool, query_hash: u64 };

pub const Console = struct {
    gpa: std.mem.Allocator,
    query: ui.TextEdit(128),
    /// Levels shown, indexed by `std.log.Level`; debug (Vitellus's chatter) starts hidden.
    levels: [4]bool = .{ true, true, true, false },
    terminal: terminal_view.TerminalView,
    /// The messages shown, and what they were filtered from: a long log is filtered again only
    /// when it, the levels or the filter change, not every frame.
    shown: std.ArrayList(u8) = .empty,
    counts: console_log.Snapshot = .{ .shown = 0, .total = 0 },
    filtered: ?Filtered = null,
    /// Bumped whenever `shown` changes, for the terminal view.
    shown_version: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font) Console {
        return .{ .gpa = gpa, .query = ui.TextEdit(128).init("") catch unreachable, .terminal = .init(gpa, mono) };
    }

    pub fn deinit(self: *Console) void {
        self.terminal.deinit();
        self.shown.deinit(self.gpa);
    }

    /// Draw the panel's page into `context`.
    pub fn build(self: *Console, context: *ui.Context) void {
        // The log through the filter, again only if something changed since last time.
        const now = Filtered{ .log = console_log.changes(), .levels = self.levels, .query_hash = std.hash.Wyhash.hash(0, self.query.text()) };
        if (self.filtered == null or !std.meta.eql(self.filtered.?, now)) {
            self.counts = console_log.snapshot(self.gpa, &self.shown, .{ .levels = self.levels, .query = self.query.text() }) catch return;
            self.filtered = now;
            self.shown_version +%= 1;
        }
        const shown = .{ .text = self.shown.items, .shown = self.counts.shown, .total = self.counts.total };

        // The toolbar: filter, levels, then what to do with the messages.
        context.begin(.row);
        _ = context.textInput("Filter", &self.query, "Filter messages");
        _ = context.checkbox("Errors", &self.levels[@intFromEnum(std.log.Level.err)]);
        _ = context.checkbox("Warnings", &self.levels[@intFromEnum(std.log.Level.warn)]);
        _ = context.checkbox("Info", &self.levels[@intFromEnum(std.log.Level.info)]);
        _ = context.checkbox("Debug", &self.levels[@intFromEnum(std.log.Level.debug)]);
        if (context.buttonVariant("Clear", .outline)) console_log.clear();
        if (context.buttonVariant("Copy", .ghost)) terminal_view.copyToClipboard(self.terminal.selectedText() orelse shown.text);
        context.end();
        context.muted(std.fmt.allocPrint(context.builder().allocator, "{d} of {d} messages", .{ shown.shown, shown.total }) catch "");

        // The messages, filling the rest of the panel.
        self.terminal.add(context, shown.text, self.shown_version, @max(60, context.viewport.h - 130));
    }
};
