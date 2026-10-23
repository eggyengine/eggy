//! Build-time generation of the compiled authoring-path lookup; no runtime index is installed.
const std = @import("std");
const Kind = @import("kind.zig").Kind;

pub const Entry = struct {
    path: []const u8,
    id: u64,
    kind: Kind,
    converted: bool,
};

/// Collect unique identities and unambiguous authoring aliases before emitting Zig source.
/// Paths are copied; source files and derived children must each be claimed.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    identities: std.AutoHashMapUnmanaged(u64, void) = .empty,
    paths: std.StringHashMapUnmanaged(usize) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Builder) void {
        self.identities.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        for (self.entries.items) |entry| self.gpa.free(entry.path);
        self.entries.deinit(self.gpa);
    }

    /// Reserve a source or child identity, refusing zero and collisions instead of aliasing.
    pub fn claim(self: *Builder, value: u64) !void {
        if (value == 0) return error.InvalidAssetId;
        const slot = try self.identities.getOrPut(self.gpa, value);
        if (slot.found_existing) return error.AssetIdCollision;
    }

    /// Add an authoring alias for an already claimed identity.
    pub fn add(self: *Builder, entry: Entry) !void {
        if (!self.identities.contains(entry.id)) return error.UnclaimedAssetId;
        if (self.paths.get(entry.path)) |index| {
            const old = self.entries.items[index];
            if (old.id != entry.id or old.kind != entry.kind or old.converted != entry.converted) return error.AmbiguousAssetPath;
            return;
        }
        for (self.entries.items) |old| if (old.id == entry.id and
            (old.kind != entry.kind or old.converted != entry.converted)) return error.InconsistentAssetKind;
        var owned = entry;
        owned.path = try self.gpa.dupe(u8, entry.path);
        errdefer self.gpa.free(owned.path);
        try self.entries.append(self.gpa, owned);
        errdefer _ = self.entries.pop();
        try self.paths.put(self.gpa, owned.path, self.entries.items.len - 1);
    }

    test "compiled aliases own paths after temporary import metadata is released" {
        var registry = Builder{ .gpa = std.testing.allocator };
        defer registry.deinit();
        try registry.claim(42);
        var temporary = "resources/rat.glb/Skeletal".*;
        try registry.add(.{ .path = &temporary, .id = 42, .kind = .model, .converted = true });
        @memset(&temporary, '?');
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try registry.write(&output.writer);
        try std.testing.expect(std.mem.indexOf(u8, output.written(), "resources/rat.glb/Skeletal") != null);
    }

    /// Emit a self-contained Zig module, used by executable and game-library roots.
    pub fn write(self: *const Builder, writer: *std.Io.Writer) !void {
        try writer.writeAll(
            \\pub const Entry = struct { path: []const u8, id: u64, kind: u8, converted: bool };
            \\pub const entries = [_]Entry{
            \\
        );
        for (self.entries.items) |entry| {
            try writer.print("    .{{ .path = \"{f}\", .id = 0x{x}, .kind = {d}, .converted = {} }},\n", .{
                std.zig.fmtString(entry.path), entry.id, @intFromEnum(entry.kind), entry.converted,
            });
        }
        try writer.writeAll(
            \\};
            \\pub fn find(path: []const u8) ?Entry {
            \\    for (entries) |entry| if (@import("std").mem.eql(u8, entry.path, path)) return entry;
            \\    return null;
            \\}
            \\pub fn findId(id: u64) ?Entry {
            \\    for (entries) |entry| if (entry.id == id) return entry;
            \\    return null;
            \\}
            \\
        );
    }
};

test "compiled aliases reject collisions and inconsistent kinds" {
    var registry = Builder{ .gpa = std.testing.allocator };
    defer registry.deinit();
    try registry.claim(42);
    try std.testing.expectError(error.AssetIdCollision, registry.claim(42));
    try std.testing.expectError(error.InvalidAssetId, registry.claim(0));
    const source = Entry{ .path = "resources/rat.glb", .id = 42, .kind = .model, .converted = true };
    try registry.add(source);
    try registry.add(source);
    try registry.add(.{ .path = "resources/rat.glb/Skeletal", .id = 42, .kind = .model, .converted = true });
    try std.testing.expectError(error.InconsistentAssetKind, registry.add(.{ .path = "other", .id = 42, .kind = .animation, .converted = false }));
    try registry.claim(7);
    try std.testing.expectError(error.AmbiguousAssetPath, registry.add(.{ .path = source.path, .id = 7, .kind = .model, .converted = true }));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try registry.write(&output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), ".id = 0x2a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "manifest") == null);
}
