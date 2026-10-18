//! The editor's window icon: the egg from `resources/icon.svg`.
const std = @import("std");
const sdl3 = @import("eggy").sdl_adapter.sdl;

/// Give `window` the editor's icon. A desktop that ignores icons is not an error worth stopping for.
/// Requires a live SDL window; decodes embedded PNG bytes, sets the icon, and frees the
/// intermediate surface. Failures are logged, with no ownership transferred to the caller.
///
/// ```zig
/// icon.apply(app.window.window); // Editor host, after creating its SDL window.
/// ```
pub fn apply(window: sdl3.video.Window) void {
    set(window) catch |err| std.log.warn("cannot set the window icon: {t}", .{err});
}

fn set(window: sdl3.video.Window) !void {
    const stream = try sdl3.io_stream.Stream.initFromConstMem(@embedFile("editor_icon"));
    const icon = try sdl3.surface.Surface.initFromPngIo(stream, true);
    defer icon.deinit();
    try window.setIcon(icon);
}
