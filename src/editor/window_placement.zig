//! Where the editor's main window is (position, size, maximized), carried to the new editor that
//! Reload opens as `--window x,y,w,h,maximized`, so reloading keeps the window where it was. Any
//! other start maximizes the window.
const std = @import("std");
const sdl3 = @import("eggy").sdl_adapter.sdl;

pub const flag = "--window";

pub const Placement = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    maximized: bool,

    /// Where `window` is now; null if SDL can't say.
    pub fn of(window: sdl3.video.Window) ?Placement {
        const x, const y = window.getPosition() catch return null;
        const width, const height = window.getSize() catch return null;
        return .{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(width), .height = @intCast(height), .maximized = window.getFlags().maximized };
    }

    /// Put `window` here: maximized, or at this size and position.
    // ponytail: Wayland ignores a window's own position, so there only the size and maximized state carry over.
    pub fn apply(placement: Placement, window: sdl3.video.Window) void {
        if (placement.maximized) {
            window.maximize() catch {};
            return;
        }
        window.setSize(placement.width, placement.height) catch {};
        window.setPosition(.{ .absolute = placement.x }, .{ .absolute = placement.y }) catch {};
    }

    /// The value for `flag`, in `buffer`.
    pub fn format(placement: Placement, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{d},{d},{d},{d},{d}", .{ placement.x, placement.y, placement.width, placement.height, @intFromBool(placement.maximized) });
    }

    /// `flag`'s value parsed; null if it isn't five comma-separated numbers.
    pub fn parse(text: []const u8) ?Placement {
        var parts = std.mem.splitScalar(u8, text, ',');
        var numbers: [5]i64 = undefined;
        for (&numbers) |*number| number.* = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
        if (parts.next() != null or numbers[2] <= 0 or numbers[3] <= 0) return null;
        return .{
            .x = std.math.cast(i32, numbers[0]) orelse return null,
            .y = std.math.cast(i32, numbers[1]) orelse return null,
            .width = std.math.cast(u32, numbers[2]) orelse return null,
            .height = std.math.cast(u32, numbers[3]) orelse return null,
            .maximized = numbers[4] != 0,
        };
    }
};

/// The placement `flag` gives in `args`, if any.
pub fn fromArgs(args: []const [*:0]const u8) ?Placement {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, std.mem.span(arg), flag) and i + 1 < args.len) return Placement.parse(std.mem.span(args[i + 1]));
    }
    return null;
}

test "a placement survives the command line, and bad values are refused" {
    const placement = Placement{ .x = -1280, .y = 40, .width = 1280, .height = 1400, .maximized = false };
    var buffer: [64]u8 = undefined;
    const text = try placement.format(&buffer);
    try std.testing.expectEqualStrings("-1280,40,1280,1400,0", text);
    try std.testing.expectEqual(placement, Placement.parse(text).?);
    try std.testing.expect(Placement.parse("1,2,3") == null);
    try std.testing.expect(Placement.parse("1,2,0,4,0") == null);
    try std.testing.expect(Placement.parse("1,2,3,4,0,5") == null);
}
