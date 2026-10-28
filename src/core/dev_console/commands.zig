//! Console commands: what the game and plugins declare, and how a typed line becomes a call to one.
const std = @import("std");
const App = @import("../app.zig").App;

/// A command the game or a plugin adds to the dev console (its `console_commands`). Typed as
/// its `name`, then its words, which `consoleCommand` reads from its `Call`.
pub const Command = struct {
    /// One word, typed to run it, such as "god".
    name: [:0]const u8,
    /// What it does, for `help`.
    help: [:0]const u8 = "",
    /// Its words after the name, for `help`, such as "<on|off>".
    usage: [:0]const u8 = "",
};

/// One run of a command: the words typed after its name, and where it writes its output.
pub const Call = struct {
    /// The line as typed; `args` are slices of it.
    line: []const u8,
    args: []const []const u8,
    out: *std.Io.Writer,
    /// Scratch memory for the run, freed after it.
    arena: std.mem.Allocator,

    /// Write a line of output. Output that can't be written is dropped.
    ///
    /// ```zig
    /// call.print("health is {d}", .{health});
    /// ```
    pub fn print(self: *Call, comptime fmt: []const u8, args: anytype) void {
        self.out.print(fmt ++ "\n", args) catch {};
    }

    /// Word `index` after the command's name, or null past the last.
    pub fn arg(self: *const Call, index: usize) ?[]const u8 {
        return if (index < self.args.len) self.args[index] else null;
    }

    /// The line as typed from word `index` on, spaces and quotes kept (ZON, say); "" past the last.
    ///
    /// ```zig
    /// const value = call.rest(2); // `set Player Transform.position .{ 1, 2, 3 }`
    /// ```
    pub fn rest(self: *const Call, index: usize) []const u8 {
        const word = self.arg(index) orelse return "";
        var start = @intFromPtr(word.ptr) - @intFromPtr(self.line.ptr);
        if (start > 0 and self.line[start - 1] == '"') start -= 1;
        return std.mem.trim(u8, self.line[start..], " \t");
    }
};

/// The commands the game and its plugins declare, and how to run one, as the host has them:
/// `Set` in the runtime, the game's library in the editor. `list` is valid until the next frame.
pub const Commands = struct {
    context: *anyopaque,
    list: []const Command,
    /// Run `list[command]` on `app`; false if its hook failed (and it said why in `call`).
    run: *const fn (context: *anyopaque, command: usize, app: *App, call: *Call) bool,

    /// No commands but Eggy's own, for a host without a game.
    pub const none: Commands = .{ .context = undefined, .list = &.{}, .run = runNone };

    fn runNone(_: *anyopaque, _: usize, _: *App, _: *Call) bool {
        return false;
    }
};

/// `line` split into words at spaces, keeping "quoted words" whole (without their quotes), in `arena`.
///
/// ```zig
/// const words = try commands.split(arena, "set Player \"Transform.position\" .{1,2,3}");
/// ```
pub fn split(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var rest = std.mem.trim(u8, line, " \t");
    while (rest.len != 0) {
        if (rest[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse rest.len;
            try words.append(arena, rest[1..close]);
            rest = std.mem.trimStart(u8, rest[@min(close + 1, rest.len)..], " \t");
        } else {
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            try words.append(arena, rest[0..end]);
            rest = std.mem.trimStart(u8, rest[end..], " \t");
        }
    }
    return words.toOwnedSlice(arena);
}

test "a line splits into words at spaces, keeping quoted words whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = try split(arena.allocator(), "  set \"Main Camera\" Camera.fov  70 ");
    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("set", words[0]);
    try std.testing.expectEqualStrings("Main Camera", words[1]);
    try std.testing.expectEqualStrings("Camera.fov", words[2]);
    try std.testing.expectEqualStrings("70", words[3]);
    try std.testing.expectEqual(@as(usize, 0), (try split(arena.allocator(), "   ")).len);
}

test "the rest of a call's line keeps its spaces and quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = "set Sign Label.text \"hello there\"";
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const call = Call{ .line = line, .args = (try split(arena.allocator(), line))[1..], .out = &discard.writer, .arena = arena.allocator() };
    try std.testing.expectEqualStrings("\"hello there\"", call.rest(2));
    try std.testing.expectEqualStrings("Label.text \"hello there\"", call.rest(1));
    try std.testing.expectEqualStrings("", call.rest(3));
}
