//! File > New Project and File > Open Project, start to finish. New Project shows the wizard in a
//! window of its own; then either way a loading screen shows while the project is made (if new)
//! and its editor built in the background, and finally the project's own editor opens.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const Wizard = @import("wizard.zig").Wizard;
const Splash = @import("splash.zig").Splash;
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
    window: ToolWindow,
    phase: union(enum) { wizard: Wizard, working: struct { job: *Job, splash: Splash } },

    /// File > New Project: open the wizard. The result is on the heap, since the wizard's folder
    /// picker keeps a pointer to it.
    pub fn create(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*ProjectFlow {
        const self = try gpa.create(ProjectFlow);
        errdefer gpa.destroy(self);
        var default_location: std.ArrayList(u8) = .empty;
        defer default_location.deinit(gpa);
        const documents = sdl3.filesystem.getUserFolder(.documents) catch sdl3.filesystem.getUserFolder(.home) catch "";
        try default_location.print(gpa, "{s}{s}EggyProjects", .{ documents, if (std.mem.endsWith(u8, documents, std.fs.path.sep_str)) "" else std.fs.path.sep_str });
        self.* = .{
            .gpa = gpa,
            .font = font,
            .window = try ToolWindow.open(gpa, graphics, font, "New Project", .{ 560, 440 }, .{ .resizable = true }),
            .phase = .{ .wizard = .init(default_location.items) },
        };
        return self;
    }

    /// File > Open Project: build and open the project in `dir` (absolute).
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, dir: []const u8) !*ProjectFlow {
        const self = try gpa.create(ProjectFlow);
        errdefer gpa.destroy(self);
        log.info("opening {s}", .{dir});
        var heading: [96]u8 = undefined;
        const working = try startJob(gpa, font, dir, null, std.fmt.bufPrint(&heading, "Opening {s}", .{std.fs.path.basename(dir)}) catch "Opening project");
        errdefer working.job.deinit();
        self.* = .{
            .gpa = gpa,
            .font = font,
            .window = try loadingWindow(gpa, graphics, font),
            .phase = .{ .working = working },
        };
        return self;
    }

    /// Close its window, stopping the build if one is under way.
    pub fn close(self: *ProjectFlow, graphics: *eggy.Graphics) void {
        switch (self.phase) {
            .wizard => |*wizard| wizard.deinit(),
            .working => |*working| {
                working.job.deinit();
                if (working.splash.egg) |*egg| egg.deinit(self.gpa);
            },
        }
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Whether the loading screen is up: the project is being made or built.
    pub fn isWorking(self: *const ProjectFlow) bool {
        return self.phase == .working;
    }

    /// Handle `curr_event` if it is for this flow's window; returns whether it was.
    pub fn handle(self: *ProjectFlow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// Whether `curr_event` asks to close this flow's window.
    pub fn closeRequested(self: *const ProjectFlow, curr_event: sdl3.events.Event) bool {
        return curr_event == .window_close_requested and self.window.owns(curr_event);
    }

    /// Draw a frame and move the flow on.
    pub fn update(self: *ProjectFlow, graphics: *eggy.Graphics, style: *const ui.Context) !Outcome {
        switch (self.phase) {
            .wizard => |*wizard| {
                const Page = struct {
                    wizard: *Wizard,
                    window: sdl3.video.Window,
                    action: @import("wizard.zig").Action = .none,
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
                    splash: *Splash,
                    status: job_zig.Status,
                    action: @import("splash.zig").Action = .none,
                    pub fn build(page: *@This(), context: *ui.Context) void {
                        page.action = page.splash.build(context, page.status);
                    }
                };
                var page = Page{ .splash = &working.splash, .status = status };
                try self.window.present(graphics, style, &page);
                if (page.action != .none) return .closed;
                if (status.stage == .done) {
                    try working.job.launchEditor();
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
        var heading: [96]u8 = undefined;
        const working = try startJob(gpa, self.font, dir, .{ .title = title, .name = name }, std.fmt.bufPrint(&heading, "Creating {s}", .{title}) catch "Creating project");
        errdefer working.job.deinit();
        const window = try loadingWindow(gpa, graphics, self.font);

        // The job copied the wizard's text, so the wizard can go now.
        self.phase.wizard.deinit();
        self.window.close(graphics);
        self.window = window;
        self.phase = .{ .working = working };
    }

    /// Start the job for the project in `dir` (made first, with `new_project`), and its loading screen.
    fn startJob(gpa: std.mem.Allocator, font: *ui.Font, dir: []const u8, new_project: ?job_zig.Create, heading: []const u8) !@FieldType(@FieldType(ProjectFlow, "phase"), "working") {
        // The editor's resources sit beside its bin folder; engines go in the user's data folder.
        const base = try sdl3.filesystem.getBasePath();
        const resources_dir = try std.fs.path.resolve(gpa, &.{ base, "..", "resources" });
        defer gpa.free(resources_dir);
        const pref = try sdl3.filesystem.getPrefPath("eggy", "eggy");
        defer sdl3.free(pref);
        const engines_dir = try std.fs.path.join(gpa, &.{ pref, "engines" });
        defer gpa.free(engines_dir);

        const job = try Job.start(gpa, .{ .dir = dir, .resources_dir = resources_dir, .engines_dir = engines_dir, .create = new_project });
        const egg = ui.Image.load(gpa, font, @embedFile("editor_icon")) catch null;
        return .{ .job = job, .splash = .init(heading, egg) };
    }

    fn loadingWindow(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !ToolWindow {
        return ToolWindow.open(gpa, graphics, font, "Loading project", .{ 560, 520 }, .{ .borderless = true });
    }
};
