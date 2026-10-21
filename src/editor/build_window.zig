//! The Build progress window: while the open project's editor is rebuilt (on refocus, or to
//! upgrade or link its Eggy), what is being built and the build's output with each step's progress
//! pinned under it, over the editor, which is frozen until it closes.
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
    /// The fonts and graphics must outlive it; `title` is copied into a fixed heading buffer.
    /// Allocation/window errors propagate; unsupported modal/parent requests are ignored.
    ///
    /// ```zig
    /// // Editor host: parent is its SDL window; fonts are shared.
    /// const progress = try BuildWindow.open(gpa, graphics, font, mono, parent, "Space");
    /// defer progress.close(graphics);
    /// ```
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

    /// Free the build-output view, OS window, surface, and `self`, before shared fonts/device.
    /// The background build job belongs to the host and is not canceled here.
    ///
    /// ```zig
    /// // After the host finishes/cancels its job:
    /// progress.close(graphics);
    /// ```
    pub fn close(self: *BuildWindow, graphics: *eggy.Graphics) void {
        self.terminal.deinit();
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. The output view
    /// sees input first, so it can select and copy.
    /// No ownership of `curr_event` is retained.
    ///
    /// ```zig
    /// // Editor event loop, before routing events to the frozen main window:
    /// if (progress.handle(event)) return;
    /// ```
    pub fn handle(self: *BuildWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (weeoui_sdl3.translate(curr_event)) |input| if (self.terminal.handle(input)) return true;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame for the build's `status`; `changed` is whether a finished build made a new
    /// editor. Returns what the buttons asked for.
    /// `status` and `style` are borrowed during the call; rendering errors propagate.
    /// The host carries out `.cancel`, `.close`, or `.reload`, rather than this window.
    ///
    /// ```zig
    /// // status is the host's current job snapshot; changed compares output stamps.
    /// const action = try progress.update(graphics, style, status, changed);
    /// if (action == .cancel) host.cancelBuild(); // Host owns/destroys the job.
    /// ```
    pub fn update(self: *BuildWindow, graphics: *eggy.Graphics, style: *const ui.Context, status: Status, changed: bool) !Action {
        const Page = struct {
            window: *BuildWindow,
            status: Status,
            changed: bool,
            action: Action = .none,
            /// Internal `ToolWindow.present` adapter; build into its active frame and
            /// store the user's action on this stack-owned page.
            ///
            /// ```zig
            /// // Inside update, after constructing page:
            /// try self.window.present(graphics, style, &page);
            /// // present invokes page.build(&self.window.ui).
            /// ```
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
            },
        }
        // The window's height less the heading, status lines and buttons.
        // The build's output only grows, so its length tells when it changed.
        self.terminal.showSteps(status.steps, sdl3.timer.getMillisecondsSinceInit());
        self.terminal.add(context, status.log, status.log.len, @max(120, context.viewport.h - 180));

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
