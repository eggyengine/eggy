//! Line-based editor CLI questions, with explicit answers for unattended runs.
const std = @import("std");

pub const Prompt = struct {
    arena: std.mem.Allocator,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    non_interactive: bool = false,

    /// Use a supplied answer, otherwise ask, or use the default in unattended mode.
    /// EOF never accepts a default on the user's behalf.
    /// Editor CLI only: `label` is displayed and `flag` names the missing CLI option.
    /// Supplied/default answers are borrowed; typed answers live in `self.arena`.
    /// Empty supplied values, missing unattended answers, EOF and reader/writer errors propagate.
    ///
    /// ```zig
    /// // Given a Prompt backed by live reader/writer and arena:
    /// const title = try prompt.text("Space Game", "Project title", "title", null);
    /// ```
    pub fn text(self: *Prompt, answer: ?[]const u8, label: []const u8, flag: []const u8, default: ?[]const u8) ![]const u8 {
        if (answer) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
            try self.output.print("--{s} cannot be empty.\n", .{flag});
            return error.EmptyArgument;
        }
        if (self.non_interactive) {
            if (default) |value| return value;
            try self.output.print("Pass --{s} in non-interactive mode.\n", .{flag});
            return error.MissingArgument;
        }
        while (true) {
            try self.output.print("{s}", .{label});
            if (default) |value| try self.output.print(" [{s}]", .{value});
            try self.output.writeAll(": ");
            try self.output.flush();
            const line = (try self.input.takeDelimiter('\n')) orelse {
                try self.output.print("\nInput ended; pass --{s} to answer without a prompt.\n", .{flag});
                return error.EndOfInput;
            };
            const value = std.mem.trim(u8, line, " \t\r\n");
            if (value.len > 0) return self.arena.dupe(u8, value);
            if (default) |value_default| return value_default;
            try self.output.writeAll("An answer is required.\n");
        }
    }

    /// Ask permission for a repair; unattended runs decline unless explicitly enabled.
    /// Editor CLI only: an explicit `answer` bypasses input; otherwise retry until yes/no.
    /// Interactive EOF and reader/writer errors propagate rather than granting permission.
    ///
    /// ```zig
    /// // Given a Prompt:
    /// const approved = try prompt.confirm(false, "Select a different Zig version?");
    /// std.debug.assert(!approved);
    /// ```
    pub fn confirm(self: *Prompt, answer: ?bool, label: []const u8) !bool {
        if (answer) |value| return value;
        if (self.non_interactive) return false;
        while (true) {
            const value = try self.text(null, label, "fix=true/false", "no");
            if (std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "y")) return true;
            if (std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "n")) return false;
            try self.output.writeAll("Answer yes or no.\n");
        }
    }
};
