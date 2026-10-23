//! Fatal errors, logged and then shown in SDL's message box (a native dialog on the desktop and
//! Android, an alert in the browser).
const std = @import("std");
const sdl3 = @import("vitellus_sdl3").sdl;

/// Log a fatal `stage` failure, appending optional borrowed backend diagnostics, then show it,
/// naming `crash_report` (the report's path) when one was written. May block until the dialog
/// is dismissed. Truncates long detail for bounded stack storage.
/// Reporting/dialog failures are logged, not returned; does not exit.
///
/// ```zig
/// // Host error boundary, before returning the original error:
/// fatal_dialog.report("init", @errorName(err), report_path);
/// return err;
/// ```
pub fn report(stage: []const u8, message: []const u8, crash_report: ?[]const u8) void {
    std.log.err("Fatal error during {s}: {s}", .{ stage, message });
    var buffer: [2048]u8 = undefined;
    const shown = if (crash_report) |path|
        std.fmt.bufPrint(&buffer, "{s}\n\nA crash report was saved to:\n{s}", .{ message[0..@min(message.len, 1024)], path[0..@min(path.len, 900)] }) catch message
    else
        message;
    if (crash_report) |path| std.log.err("crash report: {s}", .{path});
    show(stage, shown);
}

/// Show a bounded fatal message in SDL's message box, borrowing both slices during the call.
/// Works before `SDL_Init`. May block until dismissed; logs failures and does not exit.
///
/// ```zig
/// fatal_dialog.show("panic", "A required renderer resource is missing.");
/// ```
pub fn show(stage: []const u8, message: []const u8) void {
    var buffer: [2048]u8 = undefined;
    const description = formatMessage(&buffer, stage, message);
    sdl3.message_box.showSimple(.{ .error_dialog = true }, "Eggy - Fatal Error", description, null) catch |err|
        std.log.err("Cannot show fatal dialog: {t}", .{err});
}

fn formatMessage(buffer: []u8, stage: []const u8, message: []const u8) [:0]u8 {
    const prefix = std.fmt.bufPrint(buffer, "Fatal error during {s}:\n", .{stage[0..@min(stage.len, 64)]}) catch unreachable;
    const available = buffer.len - prefix.len - 1;
    const length = @min(available, message.len);
    @memcpy(buffer[prefix.len..][0..length], message[0..length]);
    buffer[prefix.len + length] = 0;
    return buffer[0 .. prefix.len + length :0];
}

test "fatal dialog preserves error context and bounds long messages" {
    var buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings("Fatal error during init:\nNoAdapter", formatMessage(&buffer, "init", "NoAdapter"));
    const long: [100]u8 = @splat('A');
    const bounded = formatMessage(&buffer, "frame", &long);
    try std.testing.expectEqual(@as(usize, buffer.len - 1), bounded.len);
    try std.testing.expectEqual(@as(u8, 'A'), bounded[bounded.len - 1]);
}
