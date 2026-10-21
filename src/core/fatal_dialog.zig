//! Fatal errors through desktop dialogs, or the platform logger where there is none: the
//! browser, Android, and Linux games built on another system (whose GTK the dialog can't link).
const std = @import("std");
const no_dialog = !@import("fatal_dialog_options").native_dialog;
const nvd = if (no_dialog) struct {} else @cImport({
    @cDefine("NVD_STATIC_LINKAGE", "1");
    @cInclude("nvdialog.h");
});

/// Log a fatal `stage` failure, appending optional borrowed backend diagnostics, then show it,
/// naming `crash_report` (the report's path) when one was written. Desktop may block for a native
/// dialog; Web/Android log only. Truncates long detail for bounded stack storage.
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

/// Show a bounded fatal message in a native desktop dialog, borrowing both slices during
/// the call. May block until dismissed; logs native-dialog failures and does not exit.
/// Without a dialog (Web, Android, cross-built Linux) this does nothing: use `report` to log.
///
/// ```zig
/// fatal_dialog.show("panic", "A required renderer resource is missing.");
/// ```
pub fn show(stage: []const u8, message: []const u8) void {
    if (no_dialog) return; // `report` already logged it to the platform console.
    var buffer: [2048]u8 = undefined;
    const description = formatMessage(&buffer, stage, message);
    const init_result = nvd.nvd_init();
    if (init_result != 0 and init_result != -nvd.NVD_ALREADY_INITIALIZED) {
        std.log.err("Cannot show fatal dialog: nvdialog init returned {d}", .{init_result});
        return;
    }
    const dialog = nvd.nvd_dialog_box_new("Eggy - Fatal Error", description, nvd.NVD_DIALOG_ERROR) orelse {
        std.log.err("Cannot create fatal dialog: nvdialog error {d}", .{nvd.nvd_get_error()});
        return;
    };
    defer nvd.nvd_free_object(dialog);
    nvd.nvd_show_dialog(dialog);
    const dialog_error = nvd.nvd_get_error();
    if (dialog_error != nvd.NVD_NO_ERROR) std.log.err("Cannot show fatal dialog: nvdialog error {d}", .{dialog_error});
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
    const long = "A" ** 100;
    const bounded = formatMessage(&buffer, "frame", long);
    try std.testing.expectEqual(@as(usize, buffer.len - 1), bounded.len);
    try std.testing.expectEqual(@as(u8, 'A'), bounded[bounded.len - 1]);
}
