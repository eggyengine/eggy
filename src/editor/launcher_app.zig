//! Eggy's own editor, the one Eggy ships: the launcher (`projects/launcher.zig`) and New/Open
//! Project (`projects/flow.zig`), without a project's workspace, game library or engine world,
//! so the executable stays small. Opening a project hands over to that project's editor.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const Style = @import("editor_style.zig").Style;
const Launcher = @import("projects/launcher.zig").Launcher;
const ProjectFlow = @import("projects/flow.zig").ProjectFlow;
const preferences = @import("preferences/preferences.zig");

pub const LauncherApp = struct {
    gpa: std.mem.Allocator,
    /// A hidden window that owns the GPU device; the launcher and the flow have windows of their own.
    window: eggy.sdl_adapter.Sdl3Window,
    graphics: eggy.Graphics,
    style: Style,
    /// Eggy's data folder, where the recent projects are kept.
    data_folder: []u8,
    /// Exactly one shows: the launcher, or the New/Open Project flow it started.
    launcher: ?*Launcher = null,
    flow: ?*ProjectFlow = null,

    /// Start SDL, the GPU and the UI, and open the launcher. Fills `self`, which must stay put
    /// while SDL calls back. Errors propagate with everything started so far undone.
    ///
    /// ```zig
    /// const host = try gpa.create(LauncherApp);
    /// try host.init(process, args);
    /// defer host.deinit();
    /// ```
    pub fn init(self: *LauncherApp, process: *const std.process.Init, args: []const [*:0]const u8) !void {
        const gpa = process.gpa;
        eggy.log.start(process.io, .editor, "eggy_editor", args);
        try sdl3.init(.{ .video = true });
        errdefer sdl3.quit(.{ .video = true });
        eggy.compiled_shader_cache.open(process.io, .editor);
        errdefer eggy.compiled_shader_cache.close();
        var window: eggy.sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init("Eggy", 880, 560, .{ .vulkan = true, .hidden = true, .high_pixel_density = true }));
        errdefer window.deinit();
        var graphics = try eggy.Graphics.init(gpa, window);
        errdefer graphics.deinit();
        var style = try Style.init(gpa, process.io, graphics.color_format);
        errdefer style.deinit(gpa);
        const folders = try preferences.Folders.init(gpa, null);
        self.* = .{ .gpa = gpa, .window = window, .graphics = graphics, .style = style, .data_folder = folders.global };
        errdefer gpa.free(self.data_folder);
        self.launcher = try Launcher.open(gpa, &self.graphics, self.style.context.font, self.style.mono, self.data_folder);
    }

    /// Close whichever window is open and shut everything down, once, after SDL stops calling.
    pub fn deinit(self: *LauncherApp) void {
        if (self.launcher) |launcher| launcher.close(&self.graphics);
        if (self.flow) |flow| flow.close(&self.graphics);
        self.gpa.free(self.data_folder);
        self.style.deinit(self.gpa);
        self.graphics.deinit();
        eggy.compiled_shader_cache.close();
        self.window.deinit();
        sdl3.quit(.{ .video = true });
    }

    /// Draw a frame of whichever window is open and act on it. `.success` once a project's
    /// editor has taken over; rendering and job errors propagate.
    pub fn iterate(self: *LauncherApp) !sdl3.AppResult {
        if (self.flow) |flow| {
            switch (try flow.update(&self.graphics, &self.style.context)) {
                .running => {},
                .closed => try self.backToLauncher(),
                .launched => return .success,
            }
            return .run;
        }
        const launcher = self.launcher orelse return .success;
        const flow = switch (try launcher.update(&self.graphics, &self.style.context)) {
            .none => return .run,
            .new_project => try ProjectFlow.create(self.gpa, &self.graphics, self.style.context.font, self.style.mono),
            .open => |dir| try ProjectFlow.open(self.gpa, &self.graphics, self.style.context.font, self.style.mono, dir, .open),
        };
        // A failed build goes back to the list, and opens its error in the code editor chosen.
        flow.close_label = "Back to projects";
        flow.code_editor = self.codeEditor();
        launcher.close(&self.graphics);
        self.launcher = null;
        self.flow = flow;
        return .run;
    }

    /// Route `curr_event` to the open window. Closing the launcher, or quitting, ends Eggy;
    /// closing the flow's window (or Escape in it) goes back to the launcher.
    pub fn event(self: *LauncherApp, curr_event: sdl3.events.Event) !sdl3.AppResult {
        if (curr_event == .quit) return .success;
        if (self.flow) |flow| {
            if (flow.closeRequested(curr_event)) try self.backToLauncher() else _ = flow.handle(curr_event);
            return .run;
        }
        if (self.launcher) |launcher| {
            if (launcher.closeRequested(curr_event)) return .success;
            _ = launcher.handle(curr_event);
        }
        return .run;
    }

    /// The code editor chosen in Settings, for every project (the global layer).
    fn codeEditor(self: *LauncherApp) @import("code_editor.zig").Choice {
        var store = eggy.preferences.Store.init(self.gpa);
        defer store.deinit();
        preferences.load(self.gpa, &store, .{ .global = self.data_folder, .project = null });
        return preferences.editor(&store).code_editor;
    }

    /// Drop the New/Open Project flow and show the launcher again, its list read afresh.
    fn backToLauncher(self: *LauncherApp) !void {
        if (self.flow) |flow| flow.close(&self.graphics);
        self.flow = null;
        self.launcher = try Launcher.open(self.gpa, &self.graphics, self.style.context.font, self.style.mono, self.data_folder);
    }
};
