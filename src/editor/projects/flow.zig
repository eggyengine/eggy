//! File > New Project and File > Open Project, start to finish. New Project shows the wizard in a
//! window of its own; then either way a loading screen (`build_progress.zig`) shows while the
//! project is made (if new) and its editor built in the background, and finally the project's own
//! editor opens. A failed build can be tried again from there.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const Wizard = @import("wizard.zig").Wizard;
const build_progress = @import("../build_progress.zig");
const BuildProgress = build_progress.BuildProgress;
const code_editor = @import("../code_editor.zig");
const project_tile = @import("project_tile.zig");
const job_zig = @import("job.zig");
const Job = job_zig.Job;
const log = std.log.scoped(.projects);

/// Where the flow is after a frame.
pub const Outcome = enum {
    running,
    /// Cancelled, or closed after failing: drop it.
    closed,
    /// The project's editor is open: this editor can quit.
    launched,
};

pub const ProjectFlow = struct {
    gpa: std.mem.Allocator,
    font: *ui.Font,
    /// The monospace face for the loading screen's output.
    mono: *const ui.Font,
    window: ToolWindow,
    phase: union(enum) { wizard: Wizard, working: Working },
    /// What leaves a failed build: the launcher's "Back to projects", or "Close".
    close_label: []const u8 = "Close",
    /// What opens a failed build's first error.
    code_editor: code_editor.Choice = .vscode,

    /// A job under way and the screen showing it, with what it was asked to do, to try again.
    const Working = struct {
        job: *Job,
        progress: BuildProgress,
        /// The project's title and package name, owned, when the job creates it.
        created: ?job_zig.Create = null,

        fn deinit(self: *Working, gpa: std.mem.Allocator) void {
            self.job.deinit();
            self.progress.deinit();
            if (self.created) |made| freeCreate(gpa, made);
        }
    };

    /// File > New Project: open the wizard. The result is on the heap, since the wizard's folder
    /// picker keeps a pointer to it.
    /// Desktop editor only: borrows live graphics/font/mono resources through `close`; returns
    /// a caller-managed flow pointer. Allocation/window errors propagate with partial setup freed.
    ///
    /// ```zig
    /// const flow = try ProjectFlow.create(gpa, graphics, font, mono);
    /// defer flow.close(graphics); // Existing desktop editor resources.
    /// ```
    pub fn create(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font) !*ProjectFlow {
        const self = try gpa.create(ProjectFlow);
        errdefer gpa.destroy(self);
        var default_location: std.ArrayList(u8) = .empty;
        defer default_location.deinit(gpa);
        const documents = sdl3.filesystem.getUserFolder(.documents) catch sdl3.filesystem.getUserFolder(.home) catch "";
        try default_location.print(gpa, "{s}{s}EggyProjects", .{ documents, if (std.mem.endsWith(u8, documents, std.fs.path.sep_str)) "" else std.fs.path.sep_str });
        self.* = .{
            .gpa = gpa,
            .font = font,
            .mono = mono,
            .window = try ToolWindow.open(gpa, graphics, font, "New Project", .{ 560, 440 }, .{ .resizable = true }),
            .phase = .{ .wizard = .init(default_location.items) },
        };
        return self;
    }

    /// File > Open Project: build and open the project in `dir` (absolute). `action` is `.open`,
    /// or `.link` to link it to an Eggy codebase first (Open Project with Developer Eggy).
    /// Desktop editor only: copies the job's paths/options before returning and opens a loading
    /// window. Borrows graphics/font/mono until `close`; allocation/job-start/window errors
    /// propagate. Worker failures arrive later as status shown by `update`.
    ///
    /// ```zig
    /// const flow = try ProjectFlow.open(gpa, graphics, font, mono, project_dir, .open);
    /// defer flow.close(graphics); // Existing resources and absolute project path.
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font, dir: []const u8, action: job_zig.Action) !*ProjectFlow {
        const self = try gpa.create(ProjectFlow);
        errdefer gpa.destroy(self);
        log.info("opening {s}", .{dir});
        var working = try startJob(gpa, font, mono, dir, action, null);
        errdefer working.deinit(gpa);
        self.* = .{
            .gpa = gpa,
            .font = font,
            .mono = mono,
            .window = try loadingWindow(gpa, graphics, font),
            .phase = .{ .working = working },
        };
        return self;
    }

    /// Close its window, stopping the build if one is under way.
    /// Desktop editor only: cancels/joins a job, frees loading UI/images or wizard state, then
    /// destroys this heap pointer. Ensure wizard picker callbacks no longer reference it.
    /// Files already written by a cancelled job are not rolled back.
    ///
    /// ```zig
    /// flow.close(graphics); // Existing ProjectFlow pointer and owning Graphics, once.
    /// ```
    pub fn close(self: *ProjectFlow, graphics: *eggy.Graphics) void {
        switch (self.phase) {
            .wizard => |*wizard| wizard.deinit(),
            .working => |*working| working.deinit(self.gpa),
        }
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Whether the loading screen is up: the project is being made or built.
    /// Desktop editor only: reports phase, including a completed/failed job still on screen,
    /// rather than whether its worker is currently executing.
    ///
    /// ```zig
    /// const loading_screen = flow.isWorking(); // Existing ProjectFlow.
    /// ```
    pub fn isWorking(self: *const ProjectFlow) bool {
        return self.phase == .working;
    }

    /// Handle `curr_event` if it is for this flow's window; returns whether it was. The loading
    /// screen's output view sees input first, so it can select and copy.
    /// Desktop editor only: accepts raw SDL events, returns false for another window, and
    /// does not cancel or close the flow for a close event.
    ///
    /// ```zig
    /// const used = flow.handle(event); // Existing ProjectFlow and raw SDL event.
    /// ```
    pub fn handle(self: *ProjectFlow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (self.phase == .working) if (@import("weeoui_sdl3").translate(curr_event)) |input| {
            if (self.phase.working.progress.handle(input)) return true;
        };
        self.window.handle(curr_event);
        return true;
    }

    /// Whether `curr_event` asks to close this flow's window: its close button, or Escape in it.
    /// Desktop editor only: ignores other windows and reports intent without destruction.
    ///
    /// ```zig
    /// if (flow.closeRequested(event)) flow.close(graphics); // Host SDL event/graphics.
    /// ```
    pub fn closeRequested(self: *const ProjectFlow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) return true;
        const input = @import("weeoui_sdl3").translate(curr_event) orelse return false;
        return input == .key_down and input.key_down.key == .escape;
    }

    /// Draw a frame and move the flow on.
    /// Desktop editor only: borrows main UI style; can start a creation job, replace the wizard
    /// window or launch a finished project's editor. Returns running/closed/launched; caller
    /// closes this flow for either terminal outcome and quits the old editor after launched.
    /// Presentation/status/job-start/spawn failures propagate; worker failures show on the loading screen.
    ///
    /// ```zig
    /// const outcome = try flow.update(graphics, style); // Existing flow and editor resources.
    /// if (outcome != .running) flow.close(graphics);
    /// ```
    pub fn update(self: *ProjectFlow, graphics: *eggy.Graphics, style: *const ui.Context) !Outcome {
        switch (self.phase) {
            .wizard => |*wizard| {
                const Page = struct {
                    wizard: *Wizard,
                    window: sdl3.video.Window,
                    action: @import("wizard.zig").Action = .none,
                    /// ToolWindow callback for the editor wizard frame, storing its action.
                    /// Borrows wizard/window/context; create-action strings remain wizard-owned.
                    ///
                    /// ```zig
                    /// // Inside ProjectFlow.update's wizard branch, with local Page:
                    /// page.build(context);
                    /// ```
                    pub fn build(page: *@This(), context: *ui.Context) void {
                        page.action = page.wizard.build(context, page.window);
                    }
                };
                var page = Page{ .wizard = wizard, .window = self.window.popout.window.window };
                try self.window.present(graphics, style, &page);
                switch (page.action) {
                    .none => {},
                    .cancel => return .closed,
                    .create => |request| try self.startCreating(graphics, request.title, request.name, request.dir),
                }
            },
            .working => |*working| {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                const status = try working.job.status(arena.allocator());
                const Page = struct {
                    progress: *BuildProgress,
                    status: job_zig.Status,
                    options: build_progress.Options,
                    action: build_progress.Action = .none,
                    /// ToolWindow callback for the editor loading frame, storing what its buttons
                    /// asked for. Status text must survive synchronous UI building/rendering.
                    ///
                    /// ```zig
                    /// // Inside ProjectFlow.update's working branch, with local Page:
                    /// page.build(context);
                    /// ```
                    pub fn build(page: *@This(), context: *ui.Context) void {
                        page.action = page.progress.add(context, page.status, page.options);
                    }
                };
                var page = Page{ .progress = &working.progress, .status = status, .options = .{
                    .close_label = self.close_label,
                    .code_editor = self.code_editor,
                } };
                try self.window.present(graphics, style, &page);
                switch (page.action) {
                    .none, .reload => {},
                    .cancel, .close => return .closed,
                    .retry => try self.retry(),
                }
                if (status.stage == .done) {
                    try working.job.launchEditor(&.{});
                    return .launched;
                }
            },
        }
        return .running;
    }

    /// Swap the wizard for the loading screen and start making the project.
    fn startCreating(self: *ProjectFlow, graphics: *eggy.Graphics, title: []const u8, name: []const u8, dir: []const u8) !void {
        const gpa = self.gpa;
        log.info("creating {s} ({s}) in {s}", .{ title, name, dir });
        var working = try startJob(gpa, self.font, self.mono, dir, .{ .create = .{ .title = title, .name = name } }, .{ .title = title, .name = name });
        errdefer working.deinit(gpa);
        const window = try loadingWindow(gpa, graphics, self.font);

        // The job copied the wizard's text, so the wizard can go now.
        self.phase.wizard.deinit();
        self.window.close(graphics);
        self.window = window;
        self.phase = .{ .working = working };
    }

    /// Try the failed job again: creating the project if it never got written, else opening it.
    fn retry(self: *ProjectFlow) !void {
        const working = &self.phase.working;
        const folders = try job_zig.editorFolders(self.gpa);
        defer self.gpa.free(folders.resources_dir);
        defer self.gpa.free(folders.engines_dir);
        const dir = working.progress.project.dir;
        const action: job_zig.Action = if (working.created != null and !hasProject(dir)) .{ .create = working.created.? } else .open;
        const job = try Job.start(self.gpa, .{ .dir = dir, .resources_dir = folders.resources_dir, .engines_dir = folders.engines_dir, .action = action });
        working.job.deinit();
        working.job = job;
        working.progress.restart();
    }

    /// Start `action`'s job for the project in `dir`, and its loading screen. `created` is the
    /// title and name of a project the job creates (copied), else null.
    fn startJob(gpa: std.mem.Allocator, font: *ui.Font, mono: *const ui.Font, dir: []const u8, action: job_zig.Action, created: ?job_zig.Create) !Working {
        const folders = try job_zig.editorFolders(gpa);
        defer gpa.free(folders.resources_dir);
        defer gpa.free(folders.engines_dir);

        // The project as the screen shows it: a new one by the wizard's title, an existing one
        // by its eggy.zon's, with its logo.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const title = if (created) |made| made.title else projectTitle(arena.allocator(), dir);
        var progress = try BuildProgress.init(gpa, mono, .{
            .verb = if (created != null) .create else .open,
            .title = title,
            .dir = dir,
            .logo = if (created != null) null else project_tile.projectLogo(gpa, font, dir),
        });
        errdefer progress.deinit();
        var owned: ?job_zig.Create = null;
        if (created) |made| {
            const owned_title = try gpa.dupe(u8, made.title);
            errdefer gpa.free(owned_title);
            owned = .{ .title = owned_title, .name = try gpa.dupe(u8, made.name) };
        }
        errdefer if (owned) |made| freeCreate(gpa, made);
        const job = try Job.start(gpa, .{ .dir = dir, .resources_dir = folders.resources_dir, .engines_dir = folders.engines_dir, .action = action });
        return .{ .job = job, .progress = progress, .created = owned };
    }

    fn loadingWindow(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !ToolWindow {
        return ToolWindow.open(gpa, graphics, font, "Loading project", .{ 560, 520 }, .{ .borderless = true });
    }
};

fn freeCreate(gpa: std.mem.Allocator, created: job_zig.Create) void {
    gpa.free(created.title);
    gpa.free(created.name);
}

/// The title in `dir`'s `eggy.zon`, in `arena`; the folder's name when it can't be read.
fn projectTitle(arena: std.mem.Allocator, dir: []const u8) []const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var project = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return std.fs.path.basename(dir);
    defer project.close(io);
    const config = eggy.project.load(arena, io, project) catch return std.fs.path.basename(dir);
    return config.title;
}

/// Whether `dir` holds a project already: an `eggy.zon`.
fn hasProject(dir: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var project = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer project.close(io);
    project.access(io, eggy.project.file_name, .{}) catch return false;
    return true;
}
