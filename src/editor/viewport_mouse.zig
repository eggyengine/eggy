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
