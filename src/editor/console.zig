//! The Console panel: the editor's log (see `console_log.zig`) in a terminal view, with a filter,
//! a toggle per level, Clear, and Copy.
const std = @import("std");
const ui = @import("eggy").ui;
const console_log = @import("console_log.zig");
const terminal_view = @import("terminal_view.zig");

pub const Console = struct {
    query: ui.TextEdit(128),
    /// Levels shown, indexed by `std.log.Level`; debug (Vitellus's chatter) starts hidden.
    levels: [4]bool = .{ true, true, true, false },
    terminal: terminal_view.TerminalView,

    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font) Console {
        return .{ .query = ui.TextEdit(128).init("") catch unreachable, .terminal = .init(gpa, mono) };
    }

    pub fn deinit(self: *Console) void {
        self.terminal.deinit();
    }

    /// Draw the panel's page into `context`.
    pub fn build(self: *Console, context: *ui.Context) void {
        const shown = console_log.snapshot(context.builder().allocator, .{ .levels = self.levels, .query = self.query.text() }) catch return;

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
        self.terminal.add(context, shown.text, @max(60, context.viewport.h - 130));
    }
};
