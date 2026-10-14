//! The `eggy_template` module: the new-project template the editor copies, with its
//! placeholders filled in. The template lives in `template/` and is valid Zig as written; the
//! placeholders are:
//!
//! | placeholder                         | replaced with                          |
//! |-------------------------------------|----------------------------------------|
//! | `eggy_template_name`                | the project's name                     |
//! | `template_fingerprint`'s hex value  | a fingerprint valid for that name      |
//! | `.{ .path = "eggy_template_engine" }` | the eggy dependency (path or URL)    |
const std = @import("std");

pub const File = struct {
    /// Relative to the new project's root, with `/` separators.
    path: []const u8,
    contents: []const u8,
};

/// Every file of the template. Write each one, after `render`, to the new project's directory.
pub const files = [_]File{
    .{ .path = ".gitignore", .contents = @embedFile("template/.gitignore") },
    .{ .path = "build.zig", .contents = @embedFile("template/build.zig") },
    .{ .path = "build.zig.zon", .contents = @embedFile("template/build.zig.zon") },
    .{ .path = "src/main.zig", .contents = @embedFile("template/src/main.zig") },
    .{ .path = "src/root.zig", .contents = @embedFile("template/src/root.zig") },
};

/// Where the new project gets eggy from.
pub const Engine = union(enum) {
    /// A local checkout, relative to the new project: Zig rejects absolute dependency paths.
    path: []const u8,
    /// A published version, as `zig fetch` would save it.
    url: struct { url: []const u8, hash: []const u8 },
};

pub const Project = struct {
    /// A Zig identifier: the package, executable and window name. Check it with `validateName`.
    name: []const u8,
    /// The random half of the package fingerprint, never 0 or 0xffffffff. Pick it once per
    /// project and never change it.
    fingerprint_id: u32,
    engine: Engine,
};

pub const NameError = error{ EmptyName, NameTooLong, NameNotIdentifier };

/// Whether `name` can name a Zig package: a plain identifier, as `build.zig.zon` requires.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > 32) return error.NameTooLong;
    if (!std.zig.isValidId(name) or std.mem.eql(u8, name, "_")) return error.NameNotIdentifier;
}

/// The fingerprint Zig expects for package `name`: CRC32 of the name over the random `id`.
pub fn fingerprint(name: []const u8, id: u32) u64 {
    return @as(u64, std.hash.Crc32.hash(name)) << 32 | id;
}

/// `contents` (one of `files`) with every placeholder filled in for `project`. Caller owns the result.
pub fn render(gpa: std.mem.Allocator, contents: []const u8, project: Project) ![]u8 {
    try validateName(project.name);
    if (project.fingerprint_id == 0 or project.fingerprint_id == 0xffffffff) return error.InvalidFingerprintId;
    if (project.engine == .path and std.fs.path.isAbsolute(project.engine.path)) return error.EnginePathNotRelative;

    // The engine first: its replacement may contain any text, but not the other placeholders.
    const engine = switch (project.engine) {
        .path => |path| try std.fmt.allocPrint(gpa, ".{{ .path = \"{f}\" }}", .{std.zig.fmtString(path)}),
        .url => |remote| try std.fmt.allocPrint(gpa, ".{{\n            .url = \"{f}\",\n            .hash = \"{f}\",\n        }}", .{ std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash) }),
    };
    defer gpa.free(engine);
    const with_engine = try std.mem.replaceOwned(u8, gpa, contents, engine_placeholder, engine);
    defer gpa.free(with_engine);

    var fingerprint_buffer: [18]u8 = undefined;
    const new_fingerprint = std.fmt.bufPrint(&fingerprint_buffer, "0x{x:0>16}", .{fingerprint(project.name, project.fingerprint_id)}) catch unreachable;
    const with_fingerprint = try std.mem.replaceOwned(u8, gpa, with_engine, template_fingerprint, new_fingerprint);
    defer gpa.free(with_fingerprint);

    return std.mem.replaceOwned(u8, gpa, with_fingerprint, name_placeholder, project.name);
}

const name_placeholder = "eggy_template_name";
const engine_placeholder = ".{ .path = \"eggy_template_engine\" }";
/// `template/build.zig.zon`'s fingerprint: valid for `eggy_template_name`, so the template builds as is.
const template_fingerprint = "0x76cd980c5eed1e55";

test "rendering fills every placeholder and gives a fingerprint valid for the new name" {
    const project = Project{ .name = "space_game", .fingerprint_id = 0x1234abcd, .engine = .{ .path = "../eggy" } };
    for (files) |file| {
        const rendered = try render(std.testing.allocator, file.contents, project);
        defer std.testing.allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "eggy_template") == null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, template_fingerprint) == null);
    }

    const zon = try render(std.testing.allocator, @embedFile("template/build.zig.zon"), project);
    defer std.testing.allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .space_game,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".eggy = .{ .path = \"../eggy\" },") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, "0x485d4b061234abcd") != null);
}

test "the template's own fingerprint is valid for its placeholder name" {
    var buffer: [18]u8 = undefined;
    try std.testing.expectEqualStrings(template_fingerprint, try std.fmt.bufPrint(&buffer, "0x{x:0>16}", .{fingerprint(name_placeholder, 0x5eed1e55)}));
}

test "a published engine replaces the path dependency with url and hash" {
    const zon = try render(std.testing.allocator, @embedFile("template/build.zig.zon"), .{
        .name = "space_game",
        .fingerprint_id = 1,
        .engine = .{ .url = .{ .url = "git+https://github.com/eggyengine/eggy#abc", .hash = "eggy-0.1.0-xyz" } },
    });
    defer std.testing.allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".url = \"git+https://github.com/eggyengine/eggy#abc\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".hash = \"eggy-0.1.0-xyz\",") != null);
}

test "an absolute engine path is rejected, since Zig would reject the dependency" {
    try std.testing.expectError(error.EnginePathNotRelative, render(std.testing.allocator, "", .{ .name = "space_game", .fingerprint_id = 1, .engine = .{ .path = "/home/me/eggy" } }));
}

test "project names must be plain identifiers" {
    try validateName("space_game");
    try std.testing.expectError(error.EmptyName, validateName(""));
    try std.testing.expectError(error.NameNotIdentifier, validateName("space game"));
    try std.testing.expectError(error.NameNotIdentifier, validateName("2d_game"));
    try std.testing.expectError(error.NameNotIdentifier, validateName("const"));
    try std.testing.expectError(error.NameTooLong, validateName("a" ** 33));
}
