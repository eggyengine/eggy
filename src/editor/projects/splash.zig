//! The loading screen while a project is made or opened, and built: what is happening and how
//! far along it is, or, if it failed, why.
const std = @import("std");
const ui = @import("eggy").ui;
const Status = @import("job.zig").Status;
const terminal_view = @import("../terminal_view.zig");
const TerminalView = terminal_view.TerminalView;

/// What the screen's buttons asked for this frame.
pub const Action = enum { none, close, cancel };

pub const Splash = struct {
    /// The heading ("Creating ...", "Opening ..."), kept here since the page reads it after
    /// `build` returns.
    heading_buffer: [96]u8 = undefined,
    heading_len: usize = 0,
    /// The egg, drawn from the window icon.
    egg: ?ui.Image,
    /// Whether the job's output is shown; it opens by itself if the job fails.
    show_output: bool = false,
    terminal: TerminalView,

    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font, heading: []const u8, egg: ?ui.Image) Splash {
        var self = Splash{ .egg = egg, .terminal = .init(gpa, mono) };
        self.heading_len = @min(heading.len, self.heading_buffer.len);
        @memcpy(self.heading_buffer[0..self.heading_len], heading[0..self.heading_len]);
        return self;
    }

    pub fn build(self: *Splash, context: *ui.Context, status: Status) Action {
        if (self.egg) |*egg| context.image(egg, 56);
        context.heading(2, self.heading_buffer[0..self.heading_len]);

        if (status.stage == .failed) {
            context.alert("Couldn't open the project", status.detail, true);
            self.terminal.add(context, status.log, 180);
            context.begin(.row);
            defer context.end();
            if (context.buttonVariant("Copy all", .outline)) terminal_view.copyToClipboard(status.log);
            return if (context.button("Close")) .close else .none;
        }

        // How far the whole job is, and what it is doing now.
        context.label("{s}...", .{status.stage.label()});
        context.progress(status.fraction);
        context.muted(if (status.detail.len > 0) status.detail else " ");

        // The job's output as it happens, behind a button.
        if (self.show_output) self.terminal.add(context, status.log, 150) else self.terminal.area = null;
        context.begin(.row);
        defer context.end();
        if (context.buttonVariant("Cancel", .ghost)) return .cancel;
        if (context.buttonVariant(if (self.show_output) "Hide output" else "Show output", .outline)) self.show_output = !self.show_output;
        if (self.show_output and context.buttonVariant("Copy all", .ghost)) terminal_view.copyToClipboard(status.log);
        return .none;
    }
};
