//! What the editor tells its splash screen while it starts: one line per message, down a pipe.
const std = @import("std");

/// The editor's startup, in order; the splash screen shows each as it begins.
pub const Step = enum {
    graphics,
    project,
    game,
    scene,
    plugins,
    assets,

    /// What the splash screen calls `step`.
    pub fn label(step: Step) []const u8 {
        return switch (step) {
            .graphics => "Starting graphics",
            .project => "Reading the project",
            .game => "Loading the game",
            .scene => "Opening the scene",
            .plugins => "Starting plugins",
            .assets => "Loading assets",
        };
    }
};

/// How many steps the startup has.
pub const step_count = @typeInfo(Step).@"enum".field_names.len;

pub const Message = union(enum) {
    /// `Step` has begun.
    step: Step,
    /// What the step is working on now, such as a file's path.
    detail: []const u8,
    /// The editor is on screen: the splash screen can go.
    done,
    /// The editor couldn't start, and why, for the splash screen to show until it is closed.
    fail: []const u8,
};

/// Stands in for a newline inside a message's text, which would end its line.
const newline_mark = 0x1e;

/// Write `message` to `writer` as its line.
///
/// ```zig
/// try message.write(&writer, .{ .detail = "resources/models/bee.gltf" });
/// ```
pub fn write(writer: *std.Io.Writer, message: Message) std.Io.Writer.Error!void {
    switch (message) {
        .step => |step| try writer.print("step {t}", .{step}),
        .detail => |text| try writeText(writer, "detail", text),
        .done => try writer.writeAll("done"),
        .fail => |text| try writeText(writer, "fail", text),
    }
    try writer.writeByte('\n');
}

fn writeText(writer: *std.Io.Writer, kind: []const u8, text: []const u8) !void {
    try writer.print("{s} ", .{kind});
    for (text) |byte| switch (byte) {
        '\n' => try writer.writeByte(newline_mark),
        '\r' => {},
        else => try writer.writeByte(byte),
    };
}

/// The message `line` (without its newline) holds, its text borrowed from `line`, which gets its
/// newlines back in place; null for a line this version doesn't know.
///
/// ```zig
/// if (message.parse(line)) |got| apply(got);
/// ```
pub fn parse(line: []u8) ?Message {
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const kind = line[0..space];
    const rest = if (space < line.len) line[space + 1 ..] else line[line.len..];
    std.mem.replaceScalar(u8, rest, newline_mark, '\n');
    if (std.mem.eql(u8, kind, "step")) return .{ .step = std.meta.stringToEnum(Step, rest) orelse return null };
    if (std.mem.eql(u8, kind, "detail")) return .{ .detail = rest };
    if (std.mem.eql(u8, kind, "done")) return .done;
    if (std.mem.eql(u8, kind, "fail")) return .{ .fail = rest };
    return null;
}

test "messages come back as written, newlines in their text included" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, .{ .step = .scene });
    try write(&writer, .{ .fail = "NoDevice\n\nA crash report was saved" });
    try write(&writer, .done);
    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    try std.testing.expectEqual(Step.scene, parse(@constCast(lines.next().?)).?.step);
    try std.testing.expectEqualStrings("NoDevice\n\nA crash report was saved", parse(@constCast(lines.next().?)).?.fail);
    try std.testing.expect(parse(@constCast(lines.next().?)).? == .done);
}

test "a line from a newer editor is skipped" {
    var line = "step compiling_shaders".*;
    try std.testing.expectEqual(null, parse(&line));
    var other = "hatch now".*;
    try std.testing.expectEqual(null, parse(&other));
}
