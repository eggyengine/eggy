//! The new-project template (`resources/template.tar`) made into a project of its own: a package
//! name, a fresh package fingerprint, and the template's placeholders filled in.
//!
//! | placeholder                           | replaced with                                  |
//! |---------------------------------------|------------------------------------------------|
//! | `eggy_template_name`                  | the package name                               |
//! | `eggy_template_title`                 | the project's title (in `eggy.zon`)            |
//! | `template_fingerprint`'s hex value    | a fingerprint valid for the package name       |
//! | `.{ .path = "eggy_template_engine" }` | the path to Eggy, relative to the project      |
const std = @import("std");

pub const Project = struct {
    /// A Zig identifier: the package, executable and module name. Check it with `validateName`.
    name: []const u8,
    /// What people see: any text.
    title: []const u8,
    /// The random half of the package fingerprint, never 0 or 0xffffffff. Pick it once per
    /// project and never change it.
    fingerprint_id: u32,
    /// Eggy's package, relative to the project: Zig rejects absolute dependency paths.
    engine_path: []const u8,
};

pub const NameError = error{ EmptyName, NameTooLong, NameNotIdentifier };
pub const max_name_len = 32;

/// Whether `name` can name a Zig package: a plain identifier, as `build.zig.zon` requires.
/// Editor project-creation helper: rejects empty names, names over 32 bytes, keywords and `_`.
/// Returns no storage and does not normalize the supplied name.
///
/// ```zig
/// try validateName("space_game");
/// ```
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > max_name_len) return error.NameTooLong;
    if (!std.zig.isValidId(name) or std.mem.eql(u8, name, "_")) return error.NameNotIdentifier;
}

/// A package name for `title` in `buffer`: lower case, words joined by `_`, and a `game_` prefix
/// when it would start with a digit. Empty when the title has no letters or digits.
/// Editor helper: ASCII-only derivation truncates to 32 bytes; result borrows `buffer` until
/// it is reused. Validate the proposed name before creating a project.
///
/// ```zig
/// var buffer: [max_name_len]u8 = undefined;
/// const name = packageName(&buffer, "Space Game!");
/// try validateName(name);
/// ```
pub fn packageName(buffer: *[max_name_len]u8, title: []const u8) []const u8 {
    var len: usize = 0;
    var gap = false;
    for (title) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (len == 0 and std.ascii.isDigit(char)) {
                @memcpy(buffer[0.."game_".len], "game_");
                len = "game_".len;
            } else if (gap and len > 0 and len < buffer.len) {
                buffer[len] = '_';
                len += 1;
            }
            gap = false;
            if (len == buffer.len) break;
            buffer[len] = std.ascii.toLower(char);
            len += 1;
        } else gap = true;
    }
    const name = buffer[0..len];
    // A keyword (say "const") is no identifier, so it gets the prefix too.
    if (len > 0 and !std.zig.isValidId(name) and len + "game_".len <= buffer.len) {
        std.mem.copyBackwards(u8, buffer["game_".len..][0..len], name);
        @memcpy(buffer[0.."game_".len], "game_");
        return buffer[0 .. len + "game_".len];
    }
    return name;
}

/// The fingerprint Zig expects for package `name`: CRC32 of the name over the random `id`.
/// Editor helper: pass a validated package name and stable non-reserved id from `fingerprintId`.
/// Returns a numeric value without allocating or modifying either input.
///
/// ```zig
/// const value = fingerprint("space_game", fingerprintId(42));
/// ```
pub fn fingerprint(name: []const u8, id: u32) u64 {
    return @as(u64, std.hash.Crc32.hash(name)) << 32 | id;
}

/// A fingerprint id from `random_bits`, skipping the two values Zig reserves.
/// Editor helper: maps reserved zero/all-ones inputs to 1; the caller supplies randomness
/// and must retain the chosen id for the lifetime of the generated package.
///
/// ```zig
/// const id = fingerprintId(42); // 42
/// ```
pub fn fingerprintId(random_bits: u32) u32 {
    return switch (random_bits) {
        0, 0xffffffff => 1,
        else => random_bits,
    };
}

/// `contents` (a file of the template) with every placeholder filled in. Caller owns the result.
/// Editor-only: validates package name/id and requires a relative engine path; title/path
/// substitutions are Zig-string escaped. No filesystem writes occur. Free bytes with `gpa`;
/// validation and allocation errors propagate with intermediate buffers cleaned up.
///
/// ```zig
/// // Given allocator and the contents of one bundled template file:
/// const rendered = try render(gpa, contents, .{
///     .name = "space_game", .title = "Space Game",
///     .fingerprint_id = fingerprintId(42), .engine_path = "../engines/abc",
/// });
/// defer gpa.free(rendered);
/// ```
pub fn render(gpa: std.mem.Allocator, contents: []const u8, project: Project) ![]u8 {
    try validateName(project.name);
    if (project.fingerprint_id == 0 or project.fingerprint_id == 0xffffffff) return error.InvalidFingerprintId;
    if (std.fs.path.isAbsolute(project.engine_path)) return error.EnginePathNotRelative;

    // The engine and title first: their text could contain the name placeholder.
    const engine = try std.fmt.allocPrint(gpa, ".{{ .path = \"{f}\" }}", .{std.zig.fmtString(project.engine_path)});
    defer gpa.free(engine);
    const with_engine = try std.mem.replaceOwned(u8, gpa, contents, engine_placeholder, engine);
    defer gpa.free(with_engine);

    var fingerprint_buffer: [18]u8 = undefined;
    const new_fingerprint = std.fmt.bufPrint(&fingerprint_buffer, "0x{x:0>16}", .{fingerprint(project.name, project.fingerprint_id)}) catch unreachable;
    const with_fingerprint = try std.mem.replaceOwned(u8, gpa, with_engine, template_fingerprint, new_fingerprint);
    defer gpa.free(with_fingerprint);

    const with_name = try std.mem.replaceOwned(u8, gpa, with_fingerprint, name_placeholder, project.name);
    defer gpa.free(with_name);
    // The title sits in a ZON string: escape it as one.
    const title = try std.fmt.allocPrint(gpa, "{f}", .{std.zig.fmtString(project.title)});
    defer gpa.free(title);
    return std.mem.replaceOwned(u8, gpa, with_name, title_placeholder, title);
}

const name_placeholder = "eggy_template_name";
const title_placeholder = "eggy_template_title";
const engine_placeholder = ".{ .path = \"eggy_template_engine\" }";
/// The template's fingerprint: valid for `eggy_template_name`, so the template builds as is.
const template_fingerprint = "0x76cd980c5eed1e55";

test "the template's own fingerprint is valid for its placeholder name" {
    var buffer: [18]u8 = undefined;
    try std.testing.expectEqualStrings(template_fingerprint, try std.fmt.bufPrint(&buffer, "0x{x:0>16}", .{fingerprint(name_placeholder, 0x5eed1e55)}));
}

test "rendering fills every placeholder with a fingerprint valid for the new name" {
    const project = Project{ .name = "space_game", .title = "Space \"Game\"", .fingerprint_id = 0x1234abcd, .engine_path = "../engines/abc" };
    const zon = try render(std.testing.allocator,
        \\.{ .name = .eggy_template_name, .fingerprint = 0x76cd980c5eed1e55,
        \\   .dependencies = .{ .eggy = .{ .path = "eggy_template_engine" } } }
        \\.{ .title = "eggy_template_title" }
    , project);
    defer std.testing.allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, "eggy_template") == null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .space_game,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, "0x485d4b061234abcd") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".eggy = .{ .path = \"../engines/abc\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".title = \"Space \\\"Game\\\"\"") != null);
}

test "an absolute engine path is rejected, since Zig would reject the dependency" {
    try std.testing.expectError(error.EnginePathNotRelative, render(std.testing.allocator, "", .{ .name = "space_game", .title = "", .fingerprint_id = 1, .engine_path = "/home/me/eggy" }));
}

test "titles become package names" {
    var buffer: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("space_game", packageName(&buffer, "Space Game!"));
    try std.testing.expectEqualStrings("game_2d_shooter", packageName(&buffer, "2D  Shooter"));
    try std.testing.expectEqualStrings("game_const", packageName(&buffer, "const"));
    try std.testing.expectEqualStrings("", packageName(&buffer, "!!!"));
    try validateName(packageName(&buffer, "A very long title that goes on and on and on"));
}

test "project names must be plain identifiers" {
    try validateName("space_game");
    try std.testing.expectError(error.EmptyName, validateName(""));
    try std.testing.expectError(error.NameNotIdentifier, validateName("space game"));
    try std.testing.expectError(error.NameNotIdentifier, validateName("2d_game"));
    try std.testing.expectError(error.NameNotIdentifier, validateName("const"));
    try std.testing.expectError(error.NameTooLong, validateName(&@as([33]u8, @splat('a'))));
}

test "fingerprint ids skip the values Zig reserves" {
    try std.testing.expectEqual(@as(u32, 1), fingerprintId(0));
    try std.testing.expectEqual(@as(u32, 1), fingerprintId(0xffffffff));
    try std.testing.expectEqual(@as(u32, 42), fingerprintId(42));
}
