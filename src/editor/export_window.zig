//! File > Export: a window to build the open project's game to ship. It first asks which scene
//! the game starts in on launch (the project's default scene picked; the choice becomes the new
//! default, a step to undo), then where it runs; Export runs `zig build export` (see
//! `src/build/export.zig`) in the background, showing the step under way, a bar for the whole
//! build, and Zig's output as it comes. Once done, the folder and its zip are in the project's
//! `zig-out/export/`, which it can show.
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
const listing = @import("assets/listing.zig");
const project_settings = @import("project_settings.zig");

/// Where a game can be exported to run: what people see, what `-Dtarget` it is, and what that
/// needs beyond Zig.
const Platform = struct { label: []const u8, target: []const u8, note: []const u8 };
pub const platforms = [_]Platform{
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
    /// The project's scenes (in `scenes_arena`), and which it starts in.
    scenes: []const []const u8 = &.{},
    scenes_arena: std.heap.ArenaAllocator,
    scene: usize = 0,
    /// Whether the scene was chosen yet: the window asks for it first.
    scene_chosen: bool = false,
    /// The default scene changed this frame, for `update` to hand back.
    change: ?project_settings.Change = null,
    /// The export under way or finished; none until Export is pressed.
    job: ?*Job = null,
    /// Whether the window asked to close.
    closing: bool = false,

    /// Open the window for the project in `project_dir`. On the heap, as the output view keeps a
    /// pointer to itself.
    /// Copies `project_dir`; shared graphics/fonts must outlive the window.
    /// Allocation/window errors propagate; failure to discover scenes leaves an empty list.
    ///
    /// ```zig
    /// // Editor host with an open project:
    /// const export_ui = try ExportWindow.open(gpa, graphics, font, mono, project_dir);
    /// defer export_ui.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font, project_dir: []const u8) !*ExportWindow {
        const self = try gpa.create(ExportWindow);
        errdefer gpa.destroy(self);
        const dir = try gpa.dupe(u8, project_dir);
        errdefer gpa.free(dir);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Export", .{ 680, 520 }, .{ .resizable = true }), .terminal = .init(gpa, mono), .project_dir = dir, .scenes_arena = .init(gpa) };
        self.findScenes();
        return self;
    }

    /// Close the window, stopping an export under way.
    /// Releases any unclaimed settings change and all owned state, including `self`;
    /// call before destroying shared fonts or graphics.
    ///
    /// ```zig
    /// export_ui.close(graphics); // Do not use the pointer afterward.
    /// ```
    pub fn close(self: *ExportWindow, graphics: *eggy.Graphics) void {
        if (self.job) |job| job.deinit();
        if (self.change) |change| {
            self.gpa.free(change.before);
            self.gpa.free(change.after);
        }
        self.scenes_arena.deinit();
        self.terminal.deinit();
        self.window.close(graphics);
        self.gpa.free(self.project_dir);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. The output view
    /// sees input first, so it can select and copy. Closing the window asks to close it.
    /// The host must read `update().open` and perform destruction; events are not retained.
    ///
    /// ```zig
    /// if (export_ui.handle(event)) return; // Editor event loop.
    /// ```
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

    /// Draw a frame. Returns the project's default scene's change this frame (caller-owned, for
    /// the editor to record), and whether the window should stay open.
    /// Both change texts were allocated with the window's `gpa`; transfer them to history
    /// or free them. Status/render failures propagate before any pending change transfers.
    ///
    /// ```zig
    /// const result = try export_ui.update(graphics, style);
    /// if (result.change) |change|
    ///     history.recordProjectSettings(change.before, change.after, now_ms);
    /// if (!result.open) {
    ///     export_ui.close(graphics);
    ///     return;
    /// }
    /// ```
    pub fn update(self: *ExportWindow, graphics: *eggy.Graphics, style: *const ui.Context) !struct { change: ?project_settings.Change, open: bool } {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const status: ?job_zig.Status = if (self.job) |job| try job.status(arena.allocator()) else null;
        const Page = struct {
            window: *ExportWindow,
            status: ?job_zig.Status,
            /// Internal synchronous tool-page adapter; borrows status and window for
            /// this frame, recording export/settings actions in the window.
            ///
            /// ```zig
            /// // Inside update, with its current status snapshot:
            /// var page = Page{ .window = self, .status = status };
            /// try self.window.present(graphics, style, &page);
            /// ```
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context, page.status);
            }
        };
        var page = Page{ .window = self, .status = status };
        try self.window.present(graphics, style, &page);
        defer self.change = null;
        return .{ .change = self.change, .open = !self.closing };
    }

    fn build(self: *ExportWindow, context: *ui.Context, maybe_status: ?job_zig.Status) void {
        if (!self.scene_chosen) return self.chooseScene(context);
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

    /// First: which scene the game starts in, kept as the project's default scene.
    fn chooseScene(self: *ExportWindow, context: *ui.Context) void {
        context.heading(3, "Which scene starts first?");
        if (self.scenes.len == 0) {
            context.muted("The project has no scenes. Make one in the Assets panel, then export.");
            if (context.buttonVariant("Close", .outline)) self.closing = true;
            return;
        }
        context.muted("The game opens in this scene on launch. It is kept as the project's default scene (File > Project Settings).");
        _ = context.select("Starts in", self.scenes, &self.scene);
        context.begin(.row);
        defer context.end();
        if (context.button("Continue")) {
            self.change = project_settings.setDefaultScene(self.gpa, self.project_dir, self.scenes[self.scene]) catch |err| blk: {
                std.log.err("cannot keep the default scene: {t}", .{err});
                break :blk null;
            };
            self.scene_chosen = true;
        }
        if (context.buttonVariant("Cancel", .outline)) self.closing = true;
    }

    /// Then: where it should run, and Export.
    fn choose(self: *ExportWindow, context: *ui.Context) void {
        context.muted("Builds the game as fast as it runs, with everything it needs, ready to hand out.");
        context.label("Starts in {s}", .{std.fs.path.basename(self.scenes[self.scene])});
        if (context.buttonVariant("Choose another scene", .link)) self.scene_chosen = false;
        var labels: [platforms.len][]const u8 = undefined;
        for (&labels, platforms) |*label, platform| label.* = platform.label;
        context.label("Runs on", .{});
        _ = context.select("Runs on", &labels, &self.platform);
        context.muted(platforms[self.platform].note);
        if (context.button("Export")) self.start();
    }

    fn start(self: *ExportWindow) void {
        const folders = job_zig.editorFolders(self.gpa) catch |err| return std.log.err("cannot export: {t}", .{err});
        defer self.gpa.free(folders.resources_dir);
        defer self.gpa.free(folders.engines_dir);
        self.job = Job.start(self.gpa, .{ .dir = self.project_dir, .resources_dir = folders.resources_dir, .engines_dir = folders.engines_dir, .action = .{ .export_game = .{ .target = platforms[self.platform].target, .scene = self.scenes[self.scene] } } }) catch |err| blk: {
            std.log.err("cannot export: {t}", .{err});
            break :blk null;
        };
    }

    /// The project's scenes to start in, its default scene picked.
    fn findScenes(self: *ExportWindow) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const arena = self.scenes_arena.allocator();
        var project = std.Io.Dir.cwd().openDir(io, self.project_dir, .{}) catch return;
        defer project.close(io);
        self.scenes = listing.scenes(arena, io, project, eggy.project.resources_dir) catch &.{};
        const config = eggy.project.load(arena, io, project) catch return;
        const default = config.default_scene orelse return;
        for (self.scenes, 0..) |scene, i| if (std.mem.eql(u8, scene, default)) {
            self.scene = i;
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
