//! Legacy `<name>.eggy` sidecars, read when migrating identities and import settings into
//! `.eggy/assets.zon`. New editor/build operations use the catalog, not resource sidecars.
//!
//!     .{ .id = 8410273145522034177, .kind = .model, .model = .{ .scale = 0.01 } }
const std = @import("std");
const zon_file = @import("zon.zig");
const Kind = @import("kind.zig").Kind;

/// What a descriptor's file name adds to its file's.
pub const extension = ".eggy";

pub const Descriptor = struct {
    /// Made at random when the file first gets a descriptor; it stays with the file.
    id: u64,
    kind: Kind,
    /// How a model is imported; ignored for other kinds.
    model: ModelImport = .{},
};

/// How a model file is imported, in the editor and when packaging.
pub const ModelImport = struct {
    /// How much bigger to make it: 0.01 for a model made in centimetres.
    scale: f32 = 1,
};

/// Whether `path` is a descriptor rather than a file of the project.
/// Checks only the name; `.eggy` by itself is not a descriptor.
///
/// ```zig
/// const descriptor_file = isDescriptor("resources/ship.glb.eggy");
/// ```
pub fn isDescriptor(path: []const u8) bool {
    return path.len > extension.len and std.mem.endsWith(u8, path, extension);
}

/// The descriptor of the file at `path`, in `buffer`.
/// Returns a borrowed slice; fails with `error.NoSpaceLeft` if the suffix does not fit.
///
/// ```zig
/// var buffer: [512]u8 = undefined;
/// const descriptor_path = try pathOf(&buffer, "resources/ship.glb");
/// ```
pub fn pathOf(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}" ++ extension, .{path});
}

/// Allocate the descriptor's path; free the result with `gpa.free`.
/// Propagates allocation failure; does not access the filesystem.
///
/// ```zig
/// const descriptor_path = try pathOfAlloc(gpa, "resources/ship.glb");
/// defer gpa.free(descriptor_path);
/// ```
pub fn pathOfAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}" ++ extension, .{path});
}

/// A new descriptor for the file at `path`, with a random id from `io`.
/// Infers the kind from the filename; folders need their kind set separately.
/// Returns a value without writing a file.
///
/// ```zig
/// const descriptor = new(io, "resources/ship.glb");
/// ```
pub fn new(io: std.Io, path: []const u8) Descriptor {
    var id: u64 = 0;
    io.random(std.mem.asBytes(&id));
    return .{ .id = id, .kind = Kind.of(path) };
}

/// `text` (a descriptor file's ZON) as a descriptor, allocating in `arena`.
/// Requires sentinel-terminated input, ignores unknown fields, and propagates parse errors.
/// Release parse allocations with the arena.
///
/// ```zig
/// var arena = std.heap.ArenaAllocator.init(gpa);
/// defer arena.deinit();
/// const descriptor = try parse(arena.allocator(), ".{ .id = 42, .kind = .model }");
/// ```
pub fn parse(arena: std.mem.Allocator, text: [:0]const u8) !Descriptor {
    return zon_file.parse(Descriptor, arena, text, .{ .ignore_unknown_fields = true });
}

/// The descriptor of the file at `path` in `dir`, read in `arena`; null when it has none.
/// Fails with `error.ParseZon` when it doesn't parse.
/// `path` names the asset, not its `.eggy` sidecar; other I/O and allocation errors propagate.
/// The arena owns the loaded text and parse allocations.
///
/// ```zig
/// var arena = std.heap.ArenaAllocator.init(gpa);
/// defer arena.deinit();
/// const descriptor = try read(arena.allocator(), io, project_dir, "resources/ship.glb");
/// ```
pub fn read(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?Descriptor {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const text = dir.readFileAllocOptions(io, try pathOf(&buffer, path), arena, .limited(64 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try parse(arena, text);
}

/// Write `descriptor` as the descriptor of the file at `path` in `dir`.
/// Creates or truncates the sidecar, not the asset; propagates formatting and I/O errors.
///
/// ```zig
/// try write(io, project_dir, "resources/ship.glb", .{ .id = 42, .kind = .model });
/// ```
pub fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, descriptor: Descriptor) !void {
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var text_buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text_buffer);
    try std.zon.stringify.serialize(descriptor, .{}, &writer);
    try writer.writeByte('\n');
    try dir.writeFile(io, .{ .sub_path = try pathOf(&name_buffer, path), .data = writer.buffered() });
}

test "a descriptor reads back as written, and unknown fields are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const descriptor = try parse(arena.allocator(), ".{ .id = 42, .kind = .model, .model = .{ .scale = 0.01 }, .later = true }");
    try std.testing.expectEqual(@as(u64, 42), descriptor.id);
    try std.testing.expectEqual(Kind.model, descriptor.kind);
    try std.testing.expectEqual(@as(f32, 0.01), descriptor.model.scale);
    try std.testing.expect(isDescriptor("ships/fighter.glb.eggy"));
    try std.testing.expect(!isDescriptor("ships/fighter.glb"));
    try std.testing.expect(!isDescriptor(".eggy")); // the project's own folder
}

test "allocated descriptor paths match buffer paths" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const path = try pathOfAlloc(gpa, "ships/fighter.glb");
            defer gpa.free(path);
            var buffer: [64]u8 = undefined;
            try std.testing.expectEqualStrings(try pathOf(&buffer, "ships/fighter.glb"), path);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
