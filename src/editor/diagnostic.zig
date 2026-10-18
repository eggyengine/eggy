//! Source links and actionable explanations extracted from compiler diagnostics.
const std = @import("std");

/// A compiler's one-based source position; the path borrows the diagnostic text.
pub const Location = struct {
    path: []const u8,
    line: u32,
    column: u32,
};

/// Read `path:line:column` at the start of a diagnostic or reference-trace line.
/// Log prefixes and Windows drive letters are allowed.
pub fn location(text: []const u8) ?Location {
    const line = std.mem.trim(u8, text, " \t\r");
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, at, ':')) |colon| {
        at = colon + 1;
        const row_end = std.mem.indexOfNonePos(u8, line, at, "0123456789") orelse continue;
        if (row_end == at or line[row_end] != ':') continue;
        const column_start = row_end + 1;
        const column_end = std.mem.indexOfNonePos(u8, line, column_start, "0123456789") orelse line.len;
        if (column_end == column_start or (column_end < line.len and line[column_end] != ':')) continue;
        const path_start = if (std.mem.lastIndexOf(u8, line[0..colon], ": ")) |prefix| prefix + 2 else 0;
        const path = line[path_start..colon];
        if (path.len == 0) continue;
        const row = std.fmt.parseInt(u32, line[at..row_end], 10) catch continue;
        const column = std.fmt.parseInt(u32, line[column_start..column_end], 10) catch continue;
        if (row == 0 or column == 0) continue;
        return .{ .path = path, .line = row, .column = column };
    }
    return null;
}

/// Prefer the project's declaration note over an engine call site, then its primary error.
/// Generated cache files and references outside this project are not offered as its source.
pub fn projectSource(message: []const u8, project_dir: []const u8) ?Location {
    var best: ?Location = null;
    var best_rank: u8 = 0;
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |line| {
        const source = location(line) orelse continue;
        const path = if (std.fs.path.isAbsolute(source.path)) blk: {
            if (!std.mem.startsWith(u8, source.path, project_dir)) continue;
            const rest = source.path[project_dir.len..];
            if (rest.len == 0 or !std.fs.path.isSep(rest[0])) continue;
            break :blk rest[1..];
        } else source.path;
        if (std.mem.startsWith(u8, path, "../") or std.mem.startsWith(u8, path, "..\\") or
            std.mem.indexOf(u8, path, ".zig-cache/") != null or std.mem.indexOf(u8, path, ".zig-cache\\") != null) continue;
        const rank: u8 = if (std.mem.indexOf(u8, line, "note: function declared here") != null)
            3
        else if (std.mem.indexOf(u8, line, ": error:") != null or std.mem.indexOf(u8, line, ": warning:") != null)
            2
        else
            1;
        if (rank <= best_rank) continue;
        best = source;
        best_rank = rank;
    }
    return best;
}

pub const Hint = struct { summary: []const u8, signature: []const u8 };

/// Recognise the old editor UI hooks without guessing about unrelated argument errors.
pub fn hookHint(message: []const u8) ?Hint {
    if (std.mem.indexOf(u8, message, "member function expected 1 argument(s), found 2") != null and
        std.mem.indexOf(u8, message, ".editorUi(editor, context)") != null)
        return .{
            .summary = "editorUi is missing its editor context parameter",
            .signature = "pub fn editorUi(self: *@This(), editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void",
        };
    if (std.mem.indexOf(u8, message, "member function expected 2 argument(s), found 3") != null and
        std.mem.indexOf(u8, message, ".editorPanelUi(panel - first, editor, context)") != null)
        return .{
            .summary = "editorPanelUi is missing its editor context parameter",
            .signature = "pub fn editorPanelUi(self: *@This(), panel: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void",
        };
    return null;
}

test "source positions support log prefixes, reference traces, spaces and drive letters" {
    const unix = location("error(zig_build): /home/me/my game/src/main.zig:12:5: error: broken").?;
    try std.testing.expectEqualStrings("/home/me/my game/src/main.zig", unix.path);
    try std.testing.expectEqual(@as(u32, 12), unix.line);
    try std.testing.expectEqual(@as(u32, 5), unix.column);
    const windows = location("    editorUi: C:\\game\\src\\root.zig:69:9").?;
    try std.testing.expectEqualStrings("C:\\game\\src\\root.zig", windows.path);
    try std.testing.expectEqualStrings("/game (copy)/src/root.zig", location("/game (copy)/src/root.zig:69:9: note: function declared here").?.path);
    try std.testing.expect(location("src/root.zig:0:9: error: invalid") == null);
    try std.testing.expect(location("src/root.zig:99999999999999:9: error: invalid") == null);
    try std.testing.expect(location("referenced by:") == null);
}

test "project declaration notes outrank the engine and generated references" {
    const message =
        \\/home/me/eggy/src/core/plugins.zig:252:113: error: member function expected 1 argument(s), found 2
        \\    try self.instances[i].editorUi(editor, context);
        \\src/root.zig:69:9: note: function declared here
        \\    pub fn editorUi(self: *Plugin, ui: *eggy.ui.Context) void {
        \\referenced by:
        \\    game: /home/me/game/.zig-cache/o/library.zig:2:3
    ;
    const source = projectSource(message, "/home/me/game").?;
    try std.testing.expectEqualStrings("src/root.zig", source.path);
    try std.testing.expectEqual(@as(u32, 69), source.line);
    const hint = hookHint(message).?;
    try std.testing.expectEqualStrings("editorUi is missing its editor context parameter", hint.summary);
    try std.testing.expect(std.mem.indexOf(u8, hint.signature, "editor: *eggy.editor.Context") != null);
    try std.testing.expect(projectSource("/home/me/game-other/src/main.zig:1:1: error: broken", "/home/me/game") == null);
    try std.testing.expect(projectSource("../other/src/main.zig:1:1: error: broken", "/home/me/game") == null);
    try std.testing.expect(hookHint("src/main.zig:1:1: error: member function expected 1 argument(s), found 2\n    other.call(a, b);") == null);
}
