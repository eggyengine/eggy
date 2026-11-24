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

    /// Free this editor build pipe's buffered diagnostic once using its configured allocator.
    /// Does not emit pending output; call `finish` first when EOF is reached normally.
    ///
    /// ```zig
    /// var stream = Stream{ .gpa = gpa, .project_dir = project_dir };
    /// defer stream.deinit(); // Existing allocator and project path.
    /// ```
    pub fn deinit(self: *Stream) void {
        self.pending.deinit(self.gpa);
    }

    /// Start an output line, including its newline if present. Use `continueLine` when
    /// the pipe reader splits a long line across buffer-sized fragments.
    /// Editor-only: copies retained bytes, filters runner noise, and may emit the previous
    /// diagnostic synchronously through `emit`. Allocation/emitter failures propagate;
    /// keep separate Streams for stdout/stderr to avoid joining unrelated traces.
    ///
    /// ```zig
    /// try stream.line("src/main.zig:1:1: error: invalid value\n"); // Existing Stream.
    /// ```
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
    /// Editor-only: call only after `line` for that logical line; ignored when nothing is
    /// pending. Copies bytes up to the 1 MiB diagnostic cap; allocation failures propagate.
    ///
    /// ```zig
    /// try stream.line("error: a long diagnostic "); // Existing Stream.
    /// try stream.continueLine("continued here\n");
    /// ```
    pub fn continueLine(self: *Stream, text: []const u8) !void {
        if (self.pending.items.len != 0) try self.append(text);
    }

    /// Emit the last pending message at EOF, preserving whether this pipe reported an error.
    /// Editor-only: no-op when empty; calls the emitter with borrowed buffered text, then
    /// clears it only after success. Emitter/allocation errors propagate for caller handling.
    ///
    /// ```zig
    /// try stream.finish(); // Existing Stream after its build pipe reaches EOF.
    /// ```
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
/// Editor-only: clears/reuses `messages`, allocating its range records through `gpa`; callers
/// retain the original output for slicing and deinit the list with that allocator.
/// Allocation failures propagate with a possibly partial list.
///
/// ```zig
/// var messages: std.ArrayList(Message) = .empty;
/// defer messages.deinit(gpa); // Existing allocator and captured build output.
/// try parse(gpa, output, &messages);
/// for (messages.items) |message| std.debug.print("{s}\n", .{output[message.start..message.end]});
/// ```
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

/// The build's errors and warnings with their notes and traces, one blank line between each,
/// for pasting elsewhere; every message `parse` keeps when there is none. Owned by `gpa`.
///
/// ```zig
/// const text = try problems(gpa, output);
/// defer gpa.free(text);
/// ```
pub fn problems(gpa: std.mem.Allocator, output: []const u8) ![]u8 {
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(gpa);
    try parse(gpa, output, &messages);
    var any_problem = false;
    for (messages.items) |message| any_problem = any_problem or message.level == .err or message.level == .warn;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (messages.items) |message| {
        if (any_problem and message.level != .err and message.level != .warn) continue;
        if (text.items.len != 0) try text.appendSlice(gpa, if (any_problem) "\n\n" else "\n");
        try text.appendSlice(gpa, std.mem.trimEnd(u8, output[message.start..message.end], "\r\n"));
    }
    return text.toOwnedSlice(gpa);
}

/// Log a completed build. If it failed without a recognised error, retain its full output
/// under one error instead of filtering away the only explanation.
/// Editor-only: borrows output/project path, emits Console log entries and adds hook-signature
/// hints where recognized. Temporary allocations use `gpa` and are freed; allocation failures
/// propagate and earlier messages may already have been logged.
///
/// ```zig
/// try log(gpa, output, true, project_dir); // Failed editor build's captured output.
/// ```
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

test "problems keep errors and their context, not the runner's steps or failed command" {
    const output =
        \\$ zig build editor --summary none
        \\editor
        \\+- compile exe game debug native 2 errors
        \\src/a.zig:1:2: error: first
        \\    broken();
        \\referenced by:
        \\    init: src/main.zig:3:4
        \\src/b.zig:5:6: error: second
        \\error: the following command failed with 2 compilation errors:
        \\/opt/zig/zig build-exe -ODebug -Mroot=src/main.zig --cache-dir .zig-cache
    ;
    const text = try problems(std.testing.allocator, output);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\src/a.zig:1:2: error: first
        \\    broken();
        \\referenced by:
        \\    init: src/main.zig:3:4
        \\
        \\src/b.zig:5:6: error: second
    , text);
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
