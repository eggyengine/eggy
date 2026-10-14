//! The `eggy_editor` module: a game's scene with Weeoui tooling drawn over it. Desktop only.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const weeoui_vitellus = @import("weeoui_vitellus");

/// The editor for `project` (see `eggy_runtime.Runtime`). The game and its plugins run as they
/// do in the runtime, and each can add panels through `editorUi`.
pub fn Editor(comptime project: type) type {
    const Plugins = eggy.plugins.Set(project.plugins);
    return struct {
        app: eggy.App,
        plugins: Plugins,
        ui: ui.Context,
        /// Draws `ui`'s vertices into the frame `Graphics` already started.
        overlay: weeoui_vitellus.Renderer,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) !Self {
            var app = try eggy.App.init(gpa, project.name ++ " - eggy editor");
            errdefer app.deinit();
            var context = try ui.Context.init(gpa);
            errdefer context.deinit();
            context.srgb_target = weeoui_vitellus.isSrgb(app.graphics.color_format);
            var overlay = try weeoui_vitellus.Renderer.init(app.graphics.device, app.graphics.color_format, &context.font);
            errdefer overlay.deinit();
            return .{ .plugins = try Plugins.init(gpa, &app), .app = app, .ui = context, .overlay = overlay };
        }

        pub fn deinit(self: *Self) void {
            self.plugins.deinit();
            // The overlay's GPU buffers must outlive any frame still in flight.
            self.app.graphics.queue.waitIdle() catch {};
            self.overlay.deinit();
            self.ui.deinit();
            self.app.deinit();
        }

        pub fn iterate(self: *Self) !sdl3.AppResult {
            try self.app.graphics.syncSize(self.app.window);
            const viewport = try self.uiViewport() orelse return .run; // minimized
            try self.plugins.update(&self.app);

            // Build this frame's UI.
            self.ui.newFrame(viewport);
            self.ui.time_ms = sdl3.timer.getMillisecondsSinceInit();
            self.buildUi();
            const vertices = try self.ui.render();

            // Draw the scene, then the UI over it.
            const frame = try self.app.graphics.beginFrame();
            try self.overlay.upload(frame.cmd, &self.ui.font, vertices, viewport);
            try frame.cmd.beginRenderPass(.{ .label = "editor ui", .color_attachments = &.{.{ .view = frame.target, .load_op = .load, .store_op = .store }} });
            self.overlay.draw(frame.cmd, frame.extent, 0, vertices.len);
            frame.cmd.endRenderPass();
            try self.app.graphics.endFrame(frame);
            return .run;
        }

        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            weeoui_sdl3.handleEvent(&self.ui, curr_event);
            try self.plugins.event(&self.app, curr_event);
            return self.app.event(curr_event);
        }

        /// The editor's panel: its own heading, then whatever the game and plugins add.
        fn buildUi(self: *Self) void {
            self.ui.begin(.card);
            self.ui.heading(2, project.name);
            self.plugins.editorUi(&self.ui);
            self.ui.end();
        }

        /// The window in points, which is where SDL reports the pointer; null while minimized.
        /// Also points `ui` at the window's pixel density so text stays crisp.
        // ponytail: ignores the display's content scale (Windows 125%+); copy weeoui_sdl3.run's scaling if UI looks small there.
        fn uiViewport(self: *Self) !?ui.Rect {
            const width, const height = try self.app.window.window.getSize();
            if (width == 0 or height == 0) return null;
            const pixel_width, const pixel_height = try self.app.window.window.getSizeInPixels();
            const viewport = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) };
            self.ui.pixel_scale = .{ @as(f32, @floatFromInt(pixel_width)) / viewport.w, @as(f32, @floatFromInt(pixel_height)) / viewport.h };
            self.ui.font.dpi_scale = self.ui.pixel_scale[0];
            return viewport;
        }
    };
}

test "the editor compiles for a project" {
    const project = struct {
        pub const name = "test";
        pub const plugins = .{struct {}};
    };
    std.testing.refAllDecls(Editor(project));
}
