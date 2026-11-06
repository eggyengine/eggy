//! The project's asset catalog (each packaged asset's path, id and kind), looked up at run time.
//!
//! A binary whose root declares `eggy_asset_ids` (the runtime, a game's library) starts with that
//! catalog compiled in. The editor compiles none, so asset changes don't rebuild it: it `set`s the
//! catalog its loaded game library carries.
const std = @import("std");

pub const Entry = struct { path: []const u8, id: u64, kind: u8, converted: bool };

/// The catalog the root module compiled in, empty without one.
pub const compiled: []const Entry = blk: {
    const root = @import("root");
    if (!@hasDecl(root, "eggy_asset_ids")) break :blk &.{};
    const source = root.eggy_asset_ids.entries;
    @setEvalBranchQuota(10 * source.len + 1000);
    var list: [source.len]Entry = undefined;
    for (&list, source) |*entry, from| entry.* = .{ .path = from.path, .id = from.id, .kind = from.kind, .converted = from.converted };
    const final = list;
    break :blk &final;
};

var entries: []const Entry = compiled;

/// Use `catalog` from now on. It is borrowed: keep it alive until the next `set`.
pub fn set(catalog: []const Entry) void {
    entries = catalog;
}

/// The entry for project path `path`, if the catalog has one.
pub fn find(path: []const u8) ?Entry {
    for (current()) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

/// The entry for asset id `id`, if the catalog has one.
pub fn findId(id: u64) ?Entry {
    for (current()) |entry| if (entry.id == id) return entry;
    return null;
}

/// The compiled catalog at compile time (`AssetRef.init`), which can't read the run time one.
fn current() []const Entry {
    return if (@inComptime()) compiled else entries;
}

test "a catalog set at run time answers lookups until replaced" {
    const before = entries;
    defer set(before);
    const catalog = [_]Entry{.{ .path = "resources/rat.glb", .id = 42, .kind = 3, .converted = true }};
    set(&catalog);
    try std.testing.expectEqual(@as(u64, 42), find("resources/rat.glb").?.id);
    try std.testing.expectEqualStrings("resources/rat.glb", findId(42).?.path);
    set(&.{});
    try std.testing.expect(findId(42) == null);
}
