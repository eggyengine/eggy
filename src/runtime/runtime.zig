//! The `eggy_runtime` module: the game as players run it, with its plugins and nothing else.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;

const web = builtin.os.tag == .emscripten;
const fps = 340000;

/// The runtime for `project`, which declares `name` (the window title) and `plugins` (a tuple of
/// plugin types, the game first). `addGame` generates it from the game's build.
pub fn Runtime(comptime project: type) type {
    const Plugins = eggy.plugins.Set(project.plugins);
    return struct {
        app: eggy.App,
        plugins: Plugins,
        fps_capper: sdl3.extras.FramerateCapper(f32),

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) !Self {
            var app = try eggy.App.init(gpa, project.name);
            errdefer app.deinit();
            var plugins = try Plugins.init(gpa, &app);
            errdefer plugins.deinit();
            try app.startWorld();
            return .{
                .plugins = plugins,
                .app = app,
                .fps_capper = .{ .mode = .{ .limited = fps } },
            };
        }

        pub fn deinit(self: *Self) void {
            self.plugins.deinit();
            self.app.deinit();
        }

        pub fn iterate(self: *Self) !sdl3.AppResult {
            try self.app.graphics.syncSize(self.app.window);
            // The browser already paces frames to the display.
            if (!web) _ = self.fps_capper.delay();
            try self.plugins.update(&self.app);
            try self.app.updateWorld();
            const frame = try self.app.graphics.beginFrame();
            try self.app.graphics.drawScene(frame);
            try self.app.graphics.endFrame(frame);
            return .run;
        }

        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            try self.plugins.event(&self.app, curr_event);
            return self.app.event(curr_event);
        }
    };
}

test "the runtime compiles for a project" {
    const project = struct {
        pub const name = "test";
        pub const plugins = .{struct {}};
    };
    std.testing.refAllDecls(Runtime(project));
}
