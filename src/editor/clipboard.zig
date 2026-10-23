//! A page's text fields and the system clipboard: what a field copied or cut goes on it, and a
//! paste a field asked for is typed in from it.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;

/// Put what `page_ui`'s field cut or copied this frame on the system clipboard, and answer its
/// paste. Call once per frame after the page renders, for every window's page.
///
/// ```zig
/// vertices = try page_ui.render();
/// clipboard.sync(page_ui);
/// ```
pub fn sync(page_ui: *ui.Context) void {
    if (page_ui.copied) |text| {
        var buffer: [4096]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&buffer, "{s}", .{text}, 0)) |copy| sdl3.clipboard.setText(copy) catch {} else |_| {}
    }
    if (page_ui.paste_requested) {
        page_ui.paste_requested = false;
        if (!sdl3.clipboard.hasText()) return;
        const text = sdl3.clipboard.getText() catch return;
        defer sdl3.free(text);
        page_ui.handle(.{ .text = text });
    }
}
