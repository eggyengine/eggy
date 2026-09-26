const std = @import("std");
const nvd = @cImport({
    @cDefine("NVD_STATIC_LINKAGE", "1");
    @cInclude("nvdialog.h");
});

pub fn report(stage: []const u8, err: anyerror, detail: ?[]const u8) void {
    var buffer: [2048]u8 = undefined;
    const message = if (detail) |text|
        std.fmt.bufPrint(&buffer, "{s}: {s}", .{ @errorName(err), text[0..@min(text.len, 1024)] }) catch unreachable
    else
        @errorName(err);
    std.log.err("Fatal error during {s}: {s}", .{ stage, message });
    show(stage, message);
}

pub fn show(stage: []const u8, message: []const u8) void {
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
