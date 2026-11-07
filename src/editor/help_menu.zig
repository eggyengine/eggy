//! The Help menu's ways out of the editor: Eggy's documentation, its issue tracker, and the
//! folder holding each run's log and crash report (what an issue needs).
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const file_manager = @import("file_manager.zig");

pub const documentation_url = "https://eggyengine.github.io/eggy";
pub const issues_url = "https://github.com/eggyengine/eggy/issues/new";

/// Open `url` in the browser; a failure is logged.
pub fn openUrl(url: [:0]const u8) void {
    sdl3.openURL(url) catch |err| std.log.err("cannot open {s}: {t}", .{ url, err });
}

/// Show the folder of the editor's log files in the file manager, using `gpa` for its address.
/// Returns false when this run has no log file to show the folder of; other failures are logged.
pub fn showLogs(gpa: std.mem.Allocator) bool {
    const path = eggy.log.filePath() orelse return false;
    file_manager.showFolder(gpa, std.fs.path.dirname(path) orelse path) catch |err| std.log.err("cannot show the log files: {t}", .{err});
    return true;
}
