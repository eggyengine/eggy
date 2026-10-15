//! The Build progress window: while the open project's editor is rebuilt (on refocus, or to
//! upgrade or link its Eggy), what is being built and the build's output, over the editor, which
//! is frozen until it closes.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const Status = @import("projects/job.zig").Status;
const terminal_view = @import("terminal_view.zig");
const TerminalView = terminal_view.TerminalView;

/// What the window's buttons asked for this frame.
pub const Action = enum { none, cancel, close, reload };

pub const BuildWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    terminal: TerminalView,
    /// "Building <project>", kept here since the page reads it after `open` returns.
    heading_buffer: [96]u8 = undefined,
    heading_len: usize = 0,

    /// Open the window over `parent`, modal to it, for project `title`. On the heap, as the
    /// output view keeps a pointer to itself.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font, parent: sdl3.video.Window, title: []const u8) !*BuildWindow {
        const self = try gpa.create(BuildWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Build progress", .{ 640, 480 }, .{ .resizable = true }), .terminal = .init(gpa, mono) };
        const heading = std.fmt.bufPrint(&self.heading_buffer, "Building {s}", .{title}) catch "Building";
        self.heading_len = heading.len;
        // Modal, so the window manager keeps it over the editor and the editor out of reach.
        const window = self.window.popout.window.window;
        window.setParent(parent) catch {};
        window.setModal(true) catch {};
        return self;
    }

    pub fn close(self: *BuildWindow, graphics: *eggy.Graphics) void {
        self.terminal.deinit();
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. The output view
    /// sees input first, so it can select and copy.
    pub fn handle(self: *BuildWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (weeoui_sdl3.translate(curr_event)) |input| if (self.terminal.handle(input)) return true;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame for the build's `status`; `changed` is whether a finished build made a new
    /// editor. Returns what the buttons asked for.
    pub fn update(self: *BuildWindow, graphics: *eggy.Graphics, style: *const ui.Context, status: Status, changed: bool) !Action {
        const Page = struct {
            window: *BuildWindow,
            status: Status,
            changed: bool,
            action: Action = .none,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.action = page.window.build(context, page.status, page.changed);
            }
        };
        var page = Page{ .window = self, .status = status, .changed = changed };
        try self.window.present(graphics, style, &page);
        return page.action;
    }

    fn build(self: *BuildWindow, context: *ui.Context, status: Status, changed: bool) Action {
        context.heading(3, self.heading_buffer[0..self.heading_len]);

        // What happened or is happening, above the build's output.
        switch (status.stage) {
            .failed => context.alert("The build failed", status.detail, true),
            .done => {
                context.label("{s}", .{if (changed) "Built. Reload the editor to use it." else "Built: nothing changed."});
                context.progress(1);
            },
            else => {
                context.label("{s}...", .{status.stage.label()});
                context.progress(status.fraction);
                context.muted(if (status.detail.len > 0) status.detail else " ");
            },
        }
        // The window's height less the heading, status lines and buttons.
        self.terminal.add(context, status.log, @max(120, context.viewport.h - 200));

        context.begin(.row);
        defer context.end();
        if (context.buttonVariant("Copy all", .ghost)) terminal_view.copyToClipboard(status.log);
        return switch (status.stage) {
            .failed => if (context.button("Close")) .close else .none,
            .done => blk: {
                if (context.buttonVariant("Later", .outline)) break :blk .close;
                break :blk if (changed and context.button("Reload")) .reload else .none;
            },
            else => if (context.buttonVariant("Cancel", .outline)) .cancel else .none,
        };
    }
};
