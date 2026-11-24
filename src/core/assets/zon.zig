//! Reading ZON text into Zig values, as Eggy's files are read.
const std = @import("std");

pub const Options = struct {
    /// Skip fields `T` doesn't have, for files later versions add to.
    ignore_unknown_fields: bool = false,
};

/// `source` as a `T`, with everything it points at allocated in `arena`. Fails with
/// `error.ParseZon` for text that isn't a `T` (its diagnostics, also in `arena`, are dropped) or
/// `error.OutOfMemory`. Use an arena: nothing frees what this allocates one by one.
///
/// ```zig
/// const config = try zon.parse(Config, arena, source, .{ .ignore_unknown_fields = true });
/// ```
pub fn parse(comptime T: type, arena: std.mem.Allocator, source: [:0]const u8, options: Options) !T {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = options.ignore_unknown_fields,
    });
}
