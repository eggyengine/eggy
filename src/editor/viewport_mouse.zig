//! Mouse capture within the rendered Scene viewport.
const std = @import("std");
const eggy = @import("eggy");
const sdl = eggy.sdl_adapter.sdl;

pub const State = struct {
    confined: ?struct { window: sdl.video.Window, previous: ?sdl.rect.IRect } = null,
    mirrored_relative: ?sdl.video.Window = null,
    relative: bool = false,

    /// Follow the viewport's current window-space bounds while the game owns the mouse.
    /// `host` is the window exposed to game hooks; relative mode follows a popped-out Scene.
    /// Pass null when the viewport is hidden or unfocused. SDL failures propagate.
    pub fn sync(self: *State, host: sdl.video.Window, target: ?sdl.video.Window, viewport: ?eggy.ui.Rect, owns_pointer: bool) !void {
        const window = target orelse return self.release(host);
        const rect = bounds(viewport orelse return self.release(host)) orelse return self.release(host);
        const host_relative = sdl.mouse.getWindowRelativeMode(host);
        if (self.mirrored_relative) |mirrored| {
            if (!host_relative or mirrored.value != window.value) {
                try sdl.mouse.setWindowRelativeMode(mirrored, false);
                self.mirrored_relative = null;
            }
        }
        const relative = host_relative or sdl.mouse.getWindowRelativeMode(window);
        const grabbed = sdl.mouse.getWindowGrab(host) or sdl.mouse.getWindowGrab(window);
        // Wayland's flag is a compositor-owned implicit grab, not SDL_CaptureMouse.
        const captured = supportsExplicitCapture() and (owns_pointer or sdl.mouse.getState()[0].toSdl() == 0) and (host.getFlags().mouse_capture or window.getFlags().mouse_capture);
        if (!relative and !grabbed and !captured) {
            try self.restoreBounds();
            self.relative = false;
            return;
        }

        if (self.confined) |confined| if (confined.window.value != window.value) try self.restoreBounds();
        const previous = sdl.mouse.getWindowRect(window);
        if (!std.meta.eql(sdl.mouse.getWindowRect(window), @as(?sdl.rect.IRect, rect))) try sdl.mouse.setWindowRect(window, rect);
        if (self.confined == null) self.confined = .{ .window = window, .previous = previous };
        if (host_relative and window.value != host.value and !sdl.mouse.getWindowRelativeMode(window)) {
            try sdl.mouse.setWindowRelativeMode(window, true);
            self.mirrored_relative = window;
        }
        self.relative = relative;
    }

    /// Release game mouse modes before focus loss, Stop, reload, or closing a viewport.
    /// Clears confinement on both windows; SDL failures propagate.
    pub fn release(self: *State, host: sdl.video.Window) !void {
        if (self.mirrored_relative) |window| {
            try sdl.mouse.setWindowRelativeMode(window, false);
            self.mirrored_relative = null;
        }
        if (self.confined) |confined| if (confined.window.value != host.value) try releaseWindow(confined.window, true);
        try releaseWindow(host, self.confined != null);
        if (self.confined) |confined| {
            try sdl.mouse.setWindowRect(confined.window, null);
            self.confined = null;
        }
        if (sdl.mouse.getWindowRect(host) != null) try sdl.mouse.setWindowRect(host, null);
        self.relative = false;
    }

    fn restoreBounds(self: *State) !void {
        const confined = self.confined orelse return;
        try sdl.mouse.setWindowRect(confined.window, confined.previous);
        self.confined = null;
    }
};

fn releaseWindow(window: sdl.video.Window, captured: bool) !void {
    if (sdl.mouse.getWindowRelativeMode(window)) try sdl.mouse.setWindowRelativeMode(window, false);
    if (sdl.mouse.getWindowGrab(window)) try sdl.mouse.setWindowGrab(window, false);
    if (captured and supportsExplicitCapture() and window.getFlags().mouse_capture) try sdl.mouse.capture(false);
}

fn supportsExplicitCapture() bool {
    return !std.mem.eql(u8, sdl.video.getCurrentDriverName() orelse "", "wayland");
}

fn bounds(viewport: eggy.ui.Rect) ?sdl.rect.IRect {
    const x = @ceil(viewport.x);
    const y = @ceil(viewport.y);
    const w = @floor(viewport.x + viewport.w) - x;
    const h = @floor(viewport.y + viewport.h) - y;
    if (w <= 0 or h <= 0) return null;
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(w), .h = @intFromFloat(h) };
}

test "capture bounds stay within the rendered image in logical window points" {
    try std.testing.expectEqual(sdl.rect.IRect{ .x = 101, .y = 51, .w = 299, .h = 199 }, bounds(.{ .x = 100.25, .y = 50.75, .w = 300.5, .h = 200 }).?);
    try std.testing.expectEqual(sdl.rect.IRect{ .x = 20, .y = 30, .w = 640, .h = 360 }, bounds(.{ .x = 20, .y = 30, .w = 640, .h = 360 }).?);
    try std.testing.expect(bounds(.{ .x = 0, .y = 0, .w = 0, .h = 300 }) == null);
    try std.testing.expect(bounds(.{ .x = 0.5, .y = 0, .w = 0.25, .h = 300 }) == null);
}

test "relative capture tracks viewport resizing and pop-outs then releases both windows" {
    const use_dummy = (try sdl.getEnvironment()).getVariable("SDL_VIDEODRIVER") == null;
    if (use_dummy) try sdl.hints.set(.video_driver, "dummy");
    defer if (use_dummy) sdl.hints.reset(.video_driver) catch @panic("cannot reset test video driver");
    try sdl.init(.{ .video = true });
    defer sdl.quit(.{ .video = true });
    const host = try sdl.video.Window.init("Capture host", 900, 675, .{ .hidden = true });
    defer host.deinit();
    var state = State{};
    defer state.release(host) catch @panic("cannot release test mouse");
    try sdl.mouse.setWindowRelativeMode(host, true);
    const viewport = eggy.ui.Rect{ .x = 100, .y = 50, .w = 400, .h = 300 };
    if (std.mem.eql(u8, sdl.video.getCurrentDriverName().?, "dummy")) {
        try std.testing.expectError(error.SdlError, state.sync(host, host, viewport, true));
        try std.testing.expect(state.confined == null);
        return;
    }
    if (std.mem.eql(u8, sdl.video.getCurrentDriverName().?, "wayland")) {
        try std.testing.expect(!supportsExplicitCapture());
    }
    try state.sync(host, host, viewport, true);
    try std.testing.expectEqual(bounds(viewport), sdl.mouse.getWindowRect(host));
    const resized = eggy.ui.Rect{ .x = 140, .y = 80, .w = 500, .h = 360 };
    try state.sync(host, host, resized, true);
    try std.testing.expectEqual(bounds(resized), sdl.mouse.getWindowRect(host));

    const popout = try sdl.video.Window.init("Capture pop-out", 700, 500, .{ .hidden = true });
    defer {
        state.release(host) catch @panic("cannot release test pop-out mouse");
        popout.deinit();
    }
    try state.sync(host, popout, viewport, true);
    try std.testing.expect(sdl.mouse.getWindowRect(host) == null);
    try std.testing.expectEqual(bounds(viewport), sdl.mouse.getWindowRect(popout));
    try std.testing.expect(sdl.mouse.getWindowRelativeMode(popout));
    try sdl.mouse.setWindowRelativeMode(host, false);
    try state.sync(host, popout, viewport, true);
    try std.testing.expect(state.confined == null);
    try std.testing.expect(!sdl.mouse.getWindowRelativeMode(popout));
    try std.testing.expect(sdl.mouse.getWindowRect(popout) == null);

    try sdl.mouse.setWindowRect(host, .{ .x = 0, .y = 0, .w = 900, .h = 675 });
    try sdl.mouse.setWindowRelativeMode(host, true);
    try state.sync(host, host, viewport, true);
    try state.sync(host, null, null, false);
    try std.testing.expect(!sdl.mouse.getWindowRelativeMode(host));
    try std.testing.expect(sdl.mouse.getWindowRect(host) == null);
    try state.release(host);
    try std.testing.expect(state.confined == null);
}
