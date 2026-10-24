//! A plugin package's entry in a project's `build.zig.zon`: taken back out once the last plugin
//! installed from it is uninstalled (the reverse of `install.zig`'s `zig fetch --save`), or
//! before `zig fetch --save` replaces a folder entry, which it would otherwise keep as `.path`.
const std = @import("std");
const Ast = std.zig.Ast;

/// `manifest` (a `build.zig.zon`'s text) without dependency `name`, in `arena`, the rest kept as
/// written; null when it has no such dependency. Fails with `error.ParseZon` when it isn't ZON.
///
/// ```zig
/// if (try withoutDependency(arena, text, "stat_pack")) |after| try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = after });
/// ```
pub fn withoutDependency(arena: std.mem.Allocator, manifest: [:0]const u8, name: []const u8) !?[]const u8 {
    const tree = try parse(arena, manifest);
    const dependency = try dependencyNamed(tree, name) orelse return null;

    // From its `.name` through its comma.
    var start: usize = tree.tokenStart(tree.firstToken(dependency) - 3);
    var last = tree.lastToken(dependency);
    if (tree.tokenTag(last + 1) == .comma) last += 1;
    var end: usize = tree.tokenStart(last) + tree.tokenSlice(last).len;

    // Its whole line(s), when nothing else shares them.
    const line_start = if (std.mem.lastIndexOfScalar(u8, manifest[0..start], '\n')) |newline| newline + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, manifest, end, '\n') orelse manifest.len;
    if (isBlank(manifest[line_start..start]) and isBlank(manifest[end..line_end])) {
        start = line_start;
        end = @min(line_end + 1, manifest.len);
    }
    return try std.mem.concat(arena, u8, &.{ manifest[0..start], manifest[end..] });
}

/// Whether `manifest` (a `build.zig.zon`'s text) points dependency `name` at a folder (`.path`),
/// such as a plugin checkout being developed; false when it has no such dependency. Fails with
/// `error.ParseZon` when it isn't ZON.
pub fn isFolderDependency(arena: std.mem.Allocator, manifest: [:0]const u8, name: []const u8) !bool {
    const tree = try parse(arena, manifest);
    const dependency = try dependencyNamed(tree, name) orelse return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const fields = tree.fullStructInit(&buffer, dependency) orelse return false;
    return fieldNamed(tree, fields, "path") != null;
}

fn parse(arena: std.mem.Allocator, manifest: [:0]const u8) !Ast {
    const tree = try Ast.parse(arena, manifest, .{ .mode = .zon });
    if (tree.errors.len > 0) return error.ParseZon;
    return tree;
}

/// The value of `.dependencies.<name>`, if there is one.
fn dependencyNamed(tree: Ast, name: []const u8) !?Ast.Node.Index {
    var root_buffer: [2]Ast.Node.Index = undefined;
    const root = tree.fullStructInit(&root_buffer, tree.rootDecls()[0]) orelse return error.ParseZon;
    const dependencies_node = fieldNamed(tree, root, "dependencies") orelse return null;
    var dependencies_buffer: [2]Ast.Node.Index = undefined;
    const dependencies = tree.fullStructInit(&dependencies_buffer, dependencies_node) orelse return null;
    return fieldNamed(tree, dependencies, name);
}

/// The value of `init`'s field `name` (written `.name` or `.@"name"`).
fn fieldNamed(tree: Ast, init: Ast.full.StructInit, name: []const u8) ?Ast.Node.Index {
    for (init.ast.fields) |field| {
        const written = tree.tokenSlice(tree.firstToken(field) - 2);
        const unquoted = if (std.mem.startsWith(u8, written, "@\"")) written[2 .. written.len - 1] else written;
        if (std.mem.eql(u8, unquoted, name)) return field;
    }
    return null;
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r").len == 0;
}

test "a dependency is taken out of build.zig.zon, the others kept as written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest =
        \\.{
        \\    .name = .rats,
        \\    .dependencies = .{
        \\        .eggy = .{ .path = "../eggy" },
        \\        .stat_pack = .{
        \\            .url = "git+https://github.com/rat/stat_pack#1234",
        \\            .hash = "stat_pack-1.0.0-AAAA",
        \\        },
        \\        // Physics.
        \\        .@"wobble" = .{ .path = "wobble" },
        \\    },
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(
        \\.{
        \\    .name = .rats,
        \\    .dependencies = .{
        \\        .eggy = .{ .path = "../eggy" },
        \\        // Physics.
        \\        .@"wobble" = .{ .path = "wobble" },
        \\    },
        \\}
        \\
    , (try withoutDependency(arena.allocator(), manifest, "stat_pack")).?);
    try std.testing.expect(std.mem.indexOf(u8, (try withoutDependency(arena.allocator(), manifest, "wobble")).?, "wobble") == null);
    try std.testing.expect(try withoutDependency(arena.allocator(), manifest, "missing") == null);
}

test "a folder dependency is told from a fetched one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest =
        \\.{ .name = .rats, .dependencies = .{
        \\    .wobble = .{ .path = "../wobble" },
        \\    .stat_pack = .{ .url = "git+https://github.com/rat/stat_pack#1234", .hash = "stat_pack-1.0.0-AAAA" },
        \\} }
    ;
    try std.testing.expect(try isFolderDependency(arena.allocator(), manifest, "wobble"));
    try std.testing.expect(!try isFolderDependency(arena.allocator(), manifest, "stat_pack"));
    try std.testing.expect(!try isFolderDependency(arena.allocator(), manifest, "missing"));
}
