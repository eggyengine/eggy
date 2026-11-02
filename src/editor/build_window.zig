//! The Build window: while the open project's editor is rebuilt (on refocus for hot reload, or to
//! upgrade or link its Eggy), the build as the loading screen shows it (`build_progress.zig`),
//! over the editor, which is frozen until it closes.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const Status = @import("projects/job.zig").Status;
const build_progress = @import("build_progress.zig");
const BuildProgress = build_progress.BuildProgress;
const project_tile = @import("projects/project_tile.zig");

/// What the window's buttons asked for this frame; the host carries it out.
pub const Action = build_progress.Action;

pub const BuildWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    progress: BuildProgress,

    /// Open the window over `parent`, modal to it, for the project titled `title` in `dir`
    /// (copied). On the heap, as the output view keeps a pointer to itself. The fonts and
    /// graphics must outlive it. Allocation/window errors propagate; unsupported modal/parent
    /// requests are ignored.
    ///
    /// ```zig
    /// const window = try BuildWindow.open(gpa, graphics, font, mono, parent, "Space", "/home/me/space");
    /// defer window.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font, parent: sdl3.video.Window, title: []const u8, dir: []const u8) !*BuildWindow {
        const self = try gpa.create(BuildWindow);
        errdefer gpa.destroy(self);
        var progress = try BuildProgress.init(gpa, mono, .{ .verb = .build, .title = title, .dir = dir, .logo = project_tile.projectLogo(gpa, font, dir) });
        errdefer progress.deinit();
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Build", .{ 560, 520 }, .{ .resizable = true }), .progress = progress };
        // Modal, so the window manager keeps it over the editor and the editor out of reach.
        const window = self.window.popout.window.window;
        window.setParent(parent) catch {};
        window.setModal(true) catch {};
        return self;
    }

    /// Free the progress view, OS window, surface, and `self`, before shared fonts/device.
    /// The background build job belongs to the host and is not canceled here.
    ///
    /// ```zig
    /// // After the host finishes/cancels its job:
    /// window.close(graphics);
    /// ```
    pub fn close(self: *BuildWindow, graphics: *eggy.Graphics) void {
        self.progress.deinit();
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. The output view
    /// sees input first, so it can select and copy.
    ///
    /// ```zig
    /// // Editor event loop, before routing events to the frozen main window:
    /// if (window.handle(event)) return;
    /// ```
    pub fn handle(self: *BuildWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (weeoui_sdl3.translate(curr_event)) |input| if (self.progress.handle(input)) return true;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame for the build's `status` with `options` (whether a finished build made a new
    /// editor, which code editor opens an error) and return what the buttons asked for. On
    /// `.retry` the host starts the build again; the view has already started over.
    /// `status` and `style` are borrowed during the call; rendering errors propagate.
    ///
    /// ```zig
    /// const action = try window.update(graphics, style, status, .{ .done = .rebuilt });
    /// if (action == .cancel) host.cancelBuild(); // Host owns/destroys the job.
    /// ```
    pub fn update(self: *BuildWindow, graphics: *eggy.Graphics, style: *const ui.Context, status: Status, options: build_progress.Options) !Action {
        const Page = struct {
            progress: *BuildProgress,
            status: Status,
            options: build_progress.Options,
            action: Action = .none,
            /// Internal `ToolWindow.present` adapter: build into its frame and keep the action.
            ///
            /// ```zig
            /// try self.window.present(graphics, style, &page);
            /// ```
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.action = page.progress.add(context, page.status, page.options);
            }
        };
        var page = Page{ .progress = &self.progress, .status = status, .options = options };
        try self.window.present(graphics, style, &page);
        if (page.action == .retry) self.progress.restart();
        return page.action;
    }
};
