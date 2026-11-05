//! Asking whether to replace a file something else changed since the editor last read or wrote it.
const std = @import("std");
const sdl3 = @import("eggy").sdl_adapter.sdl;

/// Ask over `window` whether to overwrite `file_name`, which changed on disk; true to overwrite.
/// A dialog that can't open counts as no, so nothing is lost.
// ponytail: blocks the editor's loop while the dialog is up; fine for a one-off question.
pub fn confirm(window: sdl3.video.Window, file_name: []const u8) bool {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&buffer,
        \\{s} changed on disk since the editor opened it.
        \\
        \\Overwriting it loses those changes. Cancel keeps the editor's changes unsaved.
    , .{file_name}, 0) catch return false;
    const overwrite_button = 1;
    const answer = sdl3.message_box.show(.{
        .flags = .{ .warning_dialog = true },
        .parent_window = window,
        .title = "Overwrite the scene?",
        .message = message,
        .buttons = &.{
            .{ .value = 0, .text = "Cancel", .flags = .{ .mark_default_with_escape_key = true, .mark_default_with_return_key = true } },
            .{ .value = overwrite_button, .text = "Overwrite", .flags = .{} },
        },
        .color_scheme = null,
    }) catch |err| {
        std.log.err("cannot ask whether to overwrite {s}: {t}", .{ file_name, err });
        return false;
    };
    return answer == overwrite_button;
}
