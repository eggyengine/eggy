//! Text put on the system clipboard, kept by Eggy until the next copy so other apps always paste
//! what was copied.
const std = @import("std");
const sdl = @import("vitellus_sdl3").sdl;

/// The text last copied, served to whoever pastes it. Main thread only, as SDL's clipboard is.
var held: std.ArrayList(u8) = .empty;

/// What SDL offers the text as: the types `SDL_SetClipboardText` offers.
var text_types = [_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain", "TEXT", "UTF8_STRING", "STRING" };

/// Put `text` (borrowed) on the system clipboard; empty text clears it. Main thread only.
/// Fails when the copy can't be held or SDL refuses the clipboard.
///
/// ```zig
/// try eggy.clipboard.setText(selected);
/// ```
pub fn setText(text: []const u8) !void {
    if (text.len == 0) return sdl.clipboard.clearData();
    // SDL on Wayland can free the text `SDL_SetClipboardText` copies while the editor still
    // offers it, so pastes read freed memory. Eggy holds the text itself, and SDL's cleanup
    // leaves it alone; the next copy replaces it.
    // ponytail: works around SDL 3.4.18's Wayland clipboard, drop it once SDL keeps the text alive.
    held.clearRetainingCapacity();
    try held.appendSlice(std.heap.c_allocator, text);
    if (!sdl.c.SDL_SetClipboardData(serve, keep, null, @ptrCast(&text_types), text_types.len)) return error.SdlError;
}

/// The held text, for every text type SDL asks for.
fn serve(_: ?*anyopaque, _: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
    size.* = held.items.len;
    return held.items.ptr;
}

/// SDL is done offering the text: it stays held for the next copy to replace.
fn keep(_: ?*anyopaque) callconv(.c) void {}
