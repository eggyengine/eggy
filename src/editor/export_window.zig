//! File > Export: a window to build the open project's game to ship. Pick where it runs and
//! press Export; it runs `zig build export` (see `src/build/export.zig`) in the background,
//! showing the step under way, a bar for the whole build, and Zig's output as it comes. Once
//! done, the folder and its zip are in the project's `zig-out/export/`, which it can show.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const job_zig = @import("projects/job.zig");
const Job = job_zig.Job;
const terminal_view = @import("terminal_view.zig");
const TerminalView = terminal_view.TerminalView;
const file_manager = @import("file_manager.zig");

/// Where a game can be exported to run: what people see, what `-Dtarget` it is, and what that
/// needs beyond Zig.
const Platform = struct { label: []const u8, target: []const u8, note: []const u8 };
const platforms = [_]Platform{
    .{ .label = "This computer's system", .target = "native", .note = "Runs on any computer with the same system and kind of processor." },
    .{ .label = "Windows (x86-64)", .target = "x86_64-windows-gnu", .note = "Built from here: Zig carries what Windows needs." },
    .{ .label = "macOS (Apple silicon)", .target = "aarch64-macos", .note = "Needs a MacOSX.sdk in ~/SDKs (or -Dmacos-sdk)." },
    .{ .label = "Web", .target = "wasm32-emscripten", .note = "Needs emsdk ($EMSDK, or ~/emsdk)." },
};

pub const ExportWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    terminal: TerminalView,
    /// The project's folder, owned.
    project_dir: []u8,
    /// Which of `platforms`.
    platform: usize = 0,
    /// The export under way or finished; none until Export is pressed.
    job: ?*Job = null,
    /// Whether the window asked to close.
    closing: bool = false,

    /// Open the window for the project in `project_dir`. On the heap, as the output view keeps a
    /// pointer to itself.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font, project_dir: []const u8) !*ExportWindow {
        const self = try gpa.create(ExportWindow);
        errdefer gpa.destroy(self);
        const dir = try gpa.dupe(u8, project_dir);
        errdefer gpa.free(dir);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Export", .{ 680, 520 }, .{ .resizable = true }), .terminal = .init(gpa, mono), .project_dir = dir };
        return self;
    }

    /// Close the window, stopping an export under way.
    pub fn close(self: *ExportWindow, graphics: *eggy.Graphics) void {
        if (self.job) |job| job.deinit();
        self.terminal.deinit();
        self.window.close(graphics);
        self.gpa.free(self.project_dir);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. The output view
    /// sees input first, so it can select and copy. Closing the window asks to close it.
    pub fn handle(self: *ExportWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) {
            self.closing = true;
            return true;
        }
        if (weeoui_sdl3.translate(curr_event)) |input| if (self.terminal.handle(input)) return true;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame. Returns false once the window should close.
    pub fn update(self: *ExportWindow, graphics: *eggy.Graphics, style: *const ui.Context) !bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const status: ?job_zig.Status = if (self.job) |job| try job.status(arena.allocator()) else null;
        const Page = struct {
            window: *ExportWindow,
            status: ?job_zig.Status,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context, page.status);
            }
        };
        var page = Page{ .window = self, .status = status };
        try self.window.present(graphics, style, &page);
        return !self.closing;
    }

    fn build(self: *ExportWindow, context: *ui.Context, maybe_status: ?job_zig.Status) void {
        context.heading(3, "Export the game");
        const status = maybe_status orelse return self.choose(context);

        // How far it is, above Zig's output.
        switch (status.stage) {
            .failed => context.alert("The export failed", status.detail, true),
            .done => {
                context.label("Exported to zig-out/export/, as a folder and a zip to hand out.", .{});
                context.progress(1);
            },
            else => {
                context.label("{s}...", .{status.stage.label()});
                context.progress(status.fraction);
                context.muted(if (status.detail.len > 0) status.detail else " ");
            },
        }
        // The window's height less the heading, status lines and buttons. The output only grows,
        // so its length tells when it changed.
        self.terminal.add(context, status.log, status.log.len, @max(120, context.viewport.h - 200));

        context.begin(.row);
        defer context.end();
        if (context.buttonVariant("Copy all", .ghost)) terminal_view.copyToClipboard(status.log);
        switch (status.stage) {
            .done, .failed => {
                if (status.stage == .done and context.button("Show in file manager")) self.showExports();
                if (context.buttonVariant("Export again", .outline)) self.forgetJob();
                if (context.buttonVariant("Close", .outline)) self.closing = true;
            },
            else => if (context.buttonVariant("Cancel", .outline)) self.forgetJob(),
        }
    }

    /// Before an export: where it should run, and Export.
    fn choose(self: *ExportWindow, context: *ui.Context) void {
        context.muted("Builds the game as fast as it runs, with everything it needs, ready to hand out.");
        var labels: [platforms.len][]const u8 = undefined;
        for (&labels, platforms) |*label, platform| label.* = platform.label;
        _ = context.select("Runs on", &labels, &self.platform);
        context.muted(platforms[self.platform].note);
        if (context.button("Export")) self.start();
    }

    fn start(self: *ExportWindow) void {
        const folders = job_zig.editorFolders(self.gpa) catch |err| return std.log.err("cannot export: {t}", .{err});
        defer self.gpa.free(folders.resources_dir);
        defer self.gpa.free(folders.engines_dir);
        self.job = Job.start(self.gpa, .{ .dir = self.project_dir, .resources_dir = folders.resources_dir, .engines_dir = folders.engines_dir, .action = .{ .export_game = platforms[self.platform].target } }) catch |err| blk: {
            std.log.err("cannot export: {t}", .{err});
            break :blk null;
        };
    }

    /// Stop the export, if it is still going, and go back to choosing.
    fn forgetJob(self: *ExportWindow) void {
        if (self.job) |job| job.deinit();
        self.job = null;
    }

    fn showExports(self: *ExportWindow) void {
        const folder = std.fs.path.join(self.gpa, &.{ self.project_dir, "zig-out", "export" }) catch return;
        defer self.gpa.free(folder);
        file_manager.showFolder(self.gpa, folder) catch |err| std.log.err("cannot show {s}: {t}", .{ folder, err });
    }
};
