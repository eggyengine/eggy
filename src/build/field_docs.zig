//! The `///` comments on struct fields in some modules' source folders, as a module of
//! `pub const @"Type.field"` strings: Zig can't reflect doc comments, so the Inspector's tooltips
//! read them from here.
const std = @import("std");
const package_root = @import("package_root.zig");

/// The most a source file may be.
const max_source_bytes = 4 << 20;

/// A module with the field docs of every `.zig` file under each of `modules`' root folders (a
/// module built from a generated file has none). A name two types share takes the first's.
///
/// ```zig
/// library.addImport("eggy_field_docs", field_docs.module(b, &.{ eggy, game }));
/// ```
pub fn module(b: *std.Build, modules: []const *std.Build.Module) *std.Build.Module {
    var docs: Docs = .{ .gpa = b.allocator };
    for (modules) |source_module| {
        const root = source_module.root_source_file orelse continue;
        const path = switch (root) {
            .src_path => |path| path,
            else => continue,
        };
        const folder = std.fs.path.dirname(path.sub_path) orelse ".";
        var dir = package_root.open(path.owner).openDir(b.graph.io, folder, .{ .iterate = true }) catch continue;
        defer dir.close(b.graph.io);
        docs.addFolder(b.graph.io, dir) catch |err| std.debug.panic("cannot read field docs in {s}: {t}", .{ folder, err });
    }
    return b.createModule(.{ .root_source_file = b.addWriteFiles().add("eggy_field_docs.zig", docs.source.items) });
}

const Docs = struct {
    gpa: std.mem.Allocator,
    source: std.ArrayList(u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn addFolder(self: *Docs, io: std.Io, dir: std.Io.Dir) !void {
        var walker = try dir.walk(self.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.indexOf(u8, entry.path, "zig-cache") != null or std.mem.startsWith(u8, entry.path, "zig-out")) continue;
            const text = dir.readFileAllocOptions(io, entry.path, self.gpa, .limited(max_source_bytes), .of(u8), 0) catch continue;
            defer self.gpa.free(text);
            try self.addSource(text);
        }
    }

    /// The field docs of one file's named structs (`const Name = struct { ... }`, at any depth).
    fn addSource(self: *Docs, text: [:0]const u8) !void {
        var tree = try std.zig.Ast.parse(self.gpa, text, .{});
        defer tree.deinit(self.gpa);
        try self.addMembers(&tree, tree.rootDecls(), "");
    }

    fn addMembers(self: *Docs, tree: *const std.zig.Ast, members: []const std.zig.Ast.Node.Index, type_name: []const u8) std.mem.Allocator.Error!void {
        for (members) |member| {
            if (tree.fullContainerField(member)) |field| {
                if (type_name.len == 0) continue;
                const doc = try docBefore(self.gpa, tree, field.firstToken());
                defer self.gpa.free(doc);
                if (doc.len > 0) try self.put(type_name, tree.tokenSlice(field.ast.main_token), doc);
                continue;
            }
            const decl = tree.fullVarDecl(member) orelse continue;
            const init = decl.ast.init_node.unwrap() orelse continue;
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&buffer, init) orelse continue;
            try self.addMembers(tree, container.ast.members, tree.tokenSlice(decl.ast.mut_token + 1));
        }
    }

    fn put(self: *Docs, type_name: []const u8, field: []const u8, doc: []const u8) !void {
        const key = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ type_name, std.mem.trim(u8, field, "@\"") });
        const seen = try self.seen.getOrPut(self.gpa, key);
        if (seen.found_existing) return self.gpa.free(key);
        try self.source.print(self.gpa, "pub const @\"{f}\": [:0]const u8 = \"{f}\";\n", .{ std.zig.fmtString(key), std.zig.fmtString(doc) });
    }
};

/// The `///` lines right above `token`, joined by spaces; empty without any.
fn docBefore(gpa: std.mem.Allocator, tree: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) ![]u8 {
    var first = token;
    while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    for (first..token) |line_token| {
        const line = std.mem.trim(u8, tree.tokenSlice(@intCast(line_token))[3..], " \t\r");
        if (line.len == 0) continue;
        if (doc.items.len > 0) try doc.append(gpa, ' ');
        try doc.appendSlice(gpa, line);
    }
    return doc.toOwnedSlice(gpa);
}

test "a named struct's field docs are kept by type and field, joined into one line" {
    var docs: Docs = .{ .gpa = std.testing.allocator };
    defer {
        var keys = docs.seen.keyIterator();
        while (keys.next()) |key| std.testing.allocator.free(key.*);
        docs.seen.deinit(std.testing.allocator);
        docs.source.deinit(std.testing.allocator);
    }
    try docs.addSource(
        \\pub const Mesh = struct {
        \\    /// Where it sits,
        \\    /// within its entity.
        \\    local: u8 = 0,
        \\    plain: u8 = 0,
        \\    pub const Inner = struct {
        \\        /// Deeper.
        \\        @"type": u8,
        \\    };
        \\};
    );
    try std.testing.expectEqualStrings(
        \\pub const @"Mesh.local": [:0]const u8 = "Where it sits, within its entity.";
        \\pub const @"Inner.type": [:0]const u8 = "Deeper.";
        \\
    , docs.source.items);
}
