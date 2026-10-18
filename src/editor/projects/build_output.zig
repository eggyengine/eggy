//! Compiler diagnostics grouped for the Console, without Zig's build-runner scaffolding.
const std = @import("std");
const build_log = std.log.scoped(.zig_build);
const diagnostic = @import("../diagnostic.zig");

pub const Message = struct {
    level: std.log.Level,
    start: usize,
    end: usize,
};

/// One build pipe's pending diagnostic. Stream independently of the progress window's cap,
/// and separately for stdout/stderr so interleaved output cannot split a source trace.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    project_dir: []const u8,
    pending: std.ArrayList(u8) = .empty,
    level: ?std.log.Level = null,
    failed_command: bool = false,
    truncated: bool = false,
    has_error: bool = false,
    emit: *const fn (std.mem.Allocator, []const u8, bool, []const u8) anyerror!void = log,
    /// Bound a single diagnostic, not the build; later errors are always read.
    const max_diagnostic = 1 << 20;

    pub fn deinit(self: *Stream) void {
        self.pending.deinit(self.gpa);
    }

    /// Start an output line, including its newline if present. Use `continueLine` when
    /// the pipe reader splits a long line across buffer-sized fragments.
    pub fn line(self: *Stream, text: []const u8) !void {
        const trimmed = std.mem.trimEnd(u8, text, "\r\n");
        if (trimmed.len == 0) return self.continueLine(text);
        if (isTreeLine(trimmed)) {
            // The preceding unclassified line is the tree's root, not a diagnostic.
            if (self.level == null) self.clear() else try self.finish();
            self.failed_command = false;
            return;
        }
        if (isNoise(trimmed)) {
            try self.finish();
            self.failed_command = std.mem.startsWith(u8, trimmed, "error: the following");
            return;
        }
        if (self.failed_command and isCommand(trimmed)) {
            self.failed_command = false;
            return;
        }
        self.failed_command = false;
        if (diagnosticLevel(trimmed) != null or !isContext(trimmed)) {
            try self.finish();
            self.level = diagnosticLevel(trimmed);
        }
        try self.append(text);
    }

    /// Continue the same logical line without interpreting fragments as new messages.
    pub fn continueLine(self: *Stream, text: []const u8) !void {
        if (self.pending.items.len != 0) try self.append(text);
    }

    /// Emit the last pending message at EOF, preserving whether this pipe reported an error.
    pub fn finish(self: *Stream) !void {
        if (self.pending.items.len == 0) return;
        if (self.truncated) try self.pending.appendSlice(self.gpa, "\n    [Further details omitted after 1 MiB]\n");
        try self.emit(self.gpa, self.pending.items, false, self.project_dir);
        self.has_error = self.has_error or self.level == .err;
        self.clear();
    }

    fn append(self: *Stream, text: []const u8) !void {
        const kept = @min(text.len, max_diagnostic - self.pending.items.len);
        try self.pending.appendSlice(self.gpa, text[0..kept]);
        self.truncated = self.truncated or kept != text.len;
    }

    fn clear(self: *Stream) void {
        self.pending.clearRetainingCapacity();
        self.level = null;
        self.truncated = false;
    }
};

/// Group source excerpts, notes and reference traces with their diagnostic. Ranges borrow
/// `output`; unknown output is kept, while known build summaries and failed commands are not.
pub fn parse(gpa: std.mem.Allocator, output: []const u8, messages: *std.ArrayList(Message)) !void {
    messages.clearRetainingCapacity();
    var current: ?usize = null;
    var failed_command = false;
    var start: usize = 0;
    while (start < output.len) {
        const end = std.mem.indexOfScalarPos(u8, output, start, '\n') orelse output.len;
        const line = std.mem.trimEnd(u8, output[start..end], "\r");
        defer start = end + 1;
        if (line.len == 0) continue;
        const next_end = if (end < output.len) std.mem.indexOfScalarPos(u8, output, end + 1, '\n') orelse output.len else output.len;
        const next_line = output[@min(end + 1, output.len)..next_end];

        // Runner scaffolding ends the diagnostic; never attach its command to the source trace.
        if (isNoise(line) or (current == null and diagnosticLevel(line) == null and !isContext(line) and isTreeLine(next_line))) {
            current = null;
            failed_command = std.mem.startsWith(u8, line, "error: the following");
            continue;
        }
        if (failed_command and isCommand(line)) {
            failed_command = false;
            continue;
        }
        failed_command = false;

        if (diagnosticLevel(line)) |level| {
            try messages.append(gpa, .{ .level = level, .start = start, .end = start + line.len });
            current = messages.items.len - 1;
        } else if (current != null and isContext(line)) {
            messages.items[current.?].end = start + line.len;
        } else {
            current = null;
            try messages.append(gpa, .{ .level = .info, .start = start, .end = start + line.len });
        }
    }
}

/// Log a completed build. If it failed without a recognised error, retain its full output
/// under one error instead of filtering away the only explanation.
pub fn log(gpa: std.mem.Allocator, output: []const u8, failed: bool, project_dir: []const u8) !void {
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(gpa);
    try parse(gpa, output, &messages);
    const has_error = for (messages.items) |message| {
        if (message.level == .err) break true;
    } else false;
    if (failed and !has_error) {
        const details = std.mem.trimEnd(u8, output, "\r\n");
        if (details.len > 0) build_log.err("Build failed\n{s}", .{details}) else build_log.err("Build failed without compiler output", .{});
        return;
    }
    for (messages.items) |message| {
        const text = output[message.start..message.end];
        if (message.level == .err) if (try explainHook(gpa, text, project_dir)) |explained| {
            defer gpa.free(explained);
            build_log.err("{s}", .{explained});
            continue;
        };
        switch (message.level) {
            .err => build_log.err("{s}", .{text}),
            .warn => build_log.warn("{s}", .{text}),
            .info => build_log.info("{s}", .{text}),
            .debug => unreachable,
        }
    }
}

fn explainHook(gpa: std.mem.Allocator, text: []const u8, project_dir: []const u8) !?[]u8 {
    const hint = diagnostic.hookHint(text) orelse return null;
    const source = diagnostic.projectSource(text, project_dir) orelse return null;
    return try std.fmt.allocPrint(gpa, "{s}:{d}:{d}: error: {s}\nExpected: {s}\nAdd the editor parameter before ui (use _: *eggy.editor.Context if unused) and return !void.\n\nCompiler details:\n{s}", .{
        source.path, source.line, source.column, hint.summary, hint.signature, text,
    });
}

fn diagnosticLevel(line: []const u8) ?std.log.Level {
    if (std.ascii.isWhitespace(line[0])) return null;
    if (std.mem.startsWith(u8, line, "error:") or std.mem.indexOf(u8, line, ": error:") != null) return .err;
    if (std.mem.startsWith(u8, line, "warning:") or std.mem.indexOf(u8, line, ": warning:") != null) return .warn;
    return null;
}

fn isContext(line: []const u8) bool {
    return std.ascii.isWhitespace(line[0]) or
        std.mem.indexOf(u8, line, ": note:") != null or
        std.mem.startsWith(u8, line, "note:") or
        std.mem.eql(u8, line, "referenced by:");
}

fn isCommand(line: []const u8) bool {
    return std.mem.indexOf(u8, line, " build-") != null or
        std.mem.indexOf(u8, line, ".zig-cache/") != null or
        std.mem.indexOf(u8, line, ".zig-cache\\") != null;
}

fn isNoise(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "Build Summary:") or
        isTreeLine(trimmed) or
        std.mem.endsWith(u8, trimmed, " transitive failure") or
        std.mem.startsWith(u8, trimmed, "failed command:") or
        std.mem.startsWith(u8, trimmed, "error: process exited with error code") or
        std.mem.startsWith(u8, trimmed, "error: the following command failed") or
        std.mem.startsWith(u8, trimmed, "error: the following build command failed")) return true;
    const counted = if (std.mem.startsWith(u8, trimmed, "error: ")) trimmed["error: ".len..] else trimmed;
    const count = std.mem.trimStart(u8, counted, "0123456789");
    return count.len != counted.len and
        (std.mem.eql(u8, count, " errors") or std.mem.eql(u8, count, " error") or
            std.mem.eql(u8, count, " compilation errors") or std.mem.eql(u8, count, " compilation error"));
}

fn isTreeLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t\r");
    return std.mem.startsWith(u8, trimmed, "+-") or
        std.mem.eql(u8, trimmed, "|") or std.mem.startsWith(u8, trimmed, "| ") or
        std.mem.startsWith(u8, trimmed, "\u{251c}\u{2500}") or
        std.mem.startsWith(u8, trimmed, "\u{2514}\u{2500}") or
        std.mem.startsWith(u8, trimmed, "\u{2502}");
}

test "compiler context belongs to one error without build commands or summaries" {
    const output =
        \\editor
        \\+- compile lib game 1 errors
        \\/home/me/eggy/src/core/plugins.zig:252:113: error: member function expected 1 argument(s), found 2
        \\    inline for (list, 0..) |T, i| try self.instances[i].editorUi(editor, context);
        \\                                 ~~~~~~~~~~~~~~~~~~~~~~~~~~^~~~~~~~~~~~~~~~~
        \\src/root.zig:69:9: note: function declared here
        \\    pub fn editorUi(self: *Plugin, ui: *eggy.ui.Context) void {
        \\    ~~~~^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        \\referenced by:
        \\    editorUi: /home/me/eggy/src/editor/hot_reload/library.zig:243:40
        \\    6 reference(s) hidden; use '-freference-trace=8' to see all references
        \\
        \\error: the following command failed with 1 compilation errors:
        \\/opt/zig/zig build-lib -ODebug -Mroot=src/main.zig --cache-dir .zig-cache
        \\
        \\Build Summary: 2/5 steps succeeded; 1 failed
        \\+- transitive failure
        \\error: the following build command failed with exit code 1:
        \\.zig-cache/o/abc/build /opt/zig/zig . .zig-cache editor
    ;
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try parse(std.testing.allocator, output, &messages);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    const error_message = messages.items[0];
    try std.testing.expectEqual(std.log.Level.err, error_message.level);
    const text = output[error_message.start..error_message.end];
    try std.testing.expect(std.mem.startsWith(u8, text, "/home/me/eggy/src/core/plugins.zig:252:113: error:"));
    try std.testing.expect(std.mem.endsWith(u8, text, "to see all references"));
    try std.testing.expect(std.mem.indexOf(u8, text, "note: function declared here") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Build Summary:") == null);
}

test "multiple errors, warnings and unknown output remain separate" {
    const output = "src/a.zig:1:2: error: first\r\n    broken();\r\nsrc/b.zig:3:4: warning: second\r\n    warning context\r\nlinker stopped unexpectedly\r\nerror: unable to find library 'missing'";
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try parse(std.testing.allocator, output, &messages);
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqual(std.log.Level.err, messages.items[0].level);
    try std.testing.expectEqual(std.log.Level.warn, messages.items[1].level);
    try std.testing.expectEqualStrings("linker stopped unexpectedly", output[messages.items[2].start..messages.items[2].end]);
    try std.testing.expectEqual(std.log.Level.err, messages.items[3].level);
}

test "source text containing error is context, and a new diagnostic is not a failed command" {
    const output = "error: first\n    const text = \"error: example\";\nerror: the following command failed with exit code 1:\nerror: unable to spawn compiler";
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try parse(std.testing.allocator, output, &messages);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("error: first\n    const text = \"error: example\";", output[messages.items[0].start..messages.items[0].end]);
    try std.testing.expectEqualStrings("error: unable to spawn compiler", output[messages.items[1].start..messages.items[1].end]);
}

test "unicode build trees and duplicate error counts are not messages" {
    const output = "run\n" ++
        "\u{2514}\u{2500} run /game/zig-out/bin/game_editor\n" ++
        "   \u{2514}\u{2500} compile lib game 1 errors\n" ++
        "src/main.zig:1:1: error: broken\n    source();\n" ++
        "error: 1 compilation errors\n" ++
        "failed command: /opt/zig/zig build-lib many arguments\n" ++
        "run transitive failure\n";
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try parse(std.testing.allocator, output, &messages);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualStrings("src/main.zig:1:1: error: broken\n    source();", output[messages.items[0].start..messages.items[0].end]);
}

test "old editor hook diagnostics lead with the project source and explain the new signature" {
    const errors = [_][]const u8{
        "/eggy/src/core/plugins.zig:252:113: error: member function expected 1 argument(s), found 2\n" ++
            "    try self.instances[i].editorUi(editor, context);\n" ++
            "src/root.zig:69:9: note: function declared here",
        "/eggy/src/core/plugins.zig:262:76: error: member function expected 2 argument(s), found 3\n" ++
            "    try self.instances[i].editorPanelUi(panel - first, editor, context);\n" ++
            "src/root.zig:60:9: note: function declared here",
    };
    for (errors, [_][]const u8{
        "src/root.zig:69:9: error: editorUi is missing its editor context parameter",
        "src/root.zig:60:9: error: editorPanelUi is missing its editor context parameter",
    }) |original, headline| {
        const explained = (try explainHook(std.testing.allocator, original, "/game")).?;
        defer std.testing.allocator.free(explained);
        try std.testing.expect(std.mem.startsWith(u8, explained, headline));
        try std.testing.expect(std.mem.indexOf(u8, explained, "editor: *eggy.editor.Context") != null);
        try std.testing.expect(std.mem.indexOf(u8, explained, "return !void") != null);
        try std.testing.expect(std.mem.endsWith(u8, explained, original));
    }
}

test "streamed diagnostics survive more than the progress window's output limit" {
    const console_log = @import("../console_log.zig");
    defer console_log.clear();
    var stream = Stream{ .gpa = std.testing.allocator, .project_dir = "/game", .emit = captureStream };
    defer stream.deinit();
    const progress = [_]u8{'x'} ** 4095 ++ "\n";
    for (0..300) |_| try stream.line(progress);
    try stream.line("src/main.zig:8:2: error: late streamed diagnostic\n");
    try stream.line("    broken();\n");
    try stream.line("src/main.zig:2:1: note: declared here\n");
    try stream.line("failed command: /zig build-exe ");
    try stream.continueLine("unhelpful command arguments\n");
    try stream.finish();
    try std.testing.expect(stream.has_error);
    var out = console_log.Messages{};
    defer out.deinit(std.testing.allocator);
    _ = try console_log.snapshot(std.testing.allocator, &out, .{ .levels = .{ true, false, false, false } });
    try std.testing.expectEqual(@as(usize, 1), out.entries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items, "late streamed diagnostic") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items, "broken();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items, "note: declared here") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items, "unhelpful command") == null);
}

test "streaming suppresses build roots and bounds one diagnostic without dropping later errors" {
    const console_log = @import("../console_log.zig");
    defer console_log.clear();
    var stream = Stream{ .gpa = std.testing.allocator, .project_dir = "/game", .emit = captureStream };
    defer stream.deinit();
    try stream.line("run\n");
    try stream.line("+- compile lib game 2 errors\n");
    try stream.line("src/main.zig:1:1: error: first streamed error\n");
    try stream.line("    ");
    const huge_source = try std.testing.allocator.alloc(u8, Stream.max_diagnostic + 4096);
    defer std.testing.allocator.free(huge_source);
    @memset(huge_source, 'x');
    try stream.continueLine(huge_source);
    try stream.continueLine("\n");
    try std.testing.expect(stream.pending.items.len <= Stream.max_diagnostic);
    try stream.line("src/main.zig:2:1: error: second streamed error");
    try stream.finish();
    var out = console_log.Messages{};
    defer out.deinit(std.testing.allocator);
    _ = try console_log.snapshot(std.testing.allocator, &out, .{});
    try std.testing.expectEqual(@as(usize, 2), out.entries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items, "Further details omitted after 1 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items, "second streamed error") != null);
}

fn captureStream(gpa: std.mem.Allocator, output: []const u8, _: bool, _: []const u8) !void {
    const console_log = @import("../console_log.zig");
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(gpa);
    try parse(gpa, output, &messages);
    for (messages.items) |message| switch (message.level) {
        inline else => |level| console_log.logFn(level, .zig_build, "{s}", .{output[message.start..message.end]}),
    };
}
