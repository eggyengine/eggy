//! What a distributable plugin says about itself, in the `.plugin` section of the `eggy.zon` in its
//! folder, and how a project records a plugin it installed, in its own `eggy.zon`'s `.plugins`
//! (which `addGame` builds the game with). Kept free of the engine so `build.zig` can read it.
//!
//! A plugin's `eggy.zon`, beside its `README.md`:
//!
//!     .{ .plugin = .{
//!         .title = "Frame Stats",
//!         .module = "eggy_frame_stats", // the module its package publishes with `addPlugin`
//!         .version = "0.1.0", // semver
//!         .description = "Frames per second in a corner of the game.",
//!         .repository = "https://github.com/eggyengine/eggy", // where it is hosted
//!         .fingerprint = 0x634131700cbdf8dd, // its package's build.zig.zon fingerprint
//!     } }
//!
//! The editor installs a plugin only from its own repository, and only once the package fetched
//! from it has the fingerprint its manifest names: a copy of the manifest elsewhere, or a package
//! swapped for another under it, is refused. Zig then pins the package's content hash in the
//! game's `build.zig.zon`.
const std = @import("std");

/// A plugin as its `eggy.zon` describes it.
pub const Manifest = struct {
    /// Its name as people see it.
    title: []const u8,
    /// The module its package publishes it as (`addPlugin`'s `name`), which games build with.
    module: []const u8,
    /// Its version, semver ("1.4.0").
    version: []const u8,
    /// A line on what it does.
    description: []const u8 = "",
    /// Where it is hosted ("https://github.com/me/plugins"). Its package must come from there.
    repository: []const u8,
    /// Its package's `build.zig.zon` `.fingerprint`, which the fetched package must have.
    fingerprint: u64,
    /// A dev plugin helps whoever makes the game: the editor and `zig build run-runtime` run it,
    /// but `zig build export` leaves it out of the game it ships.
    dev: bool = false,
    /// Its read-me, relative to this `eggy.zon`.
    readme: []const u8 = "README.md",
    /// Where its Zig package is, as `zig fetch` takes it ("git+https://github.com/me/plugins#v1.0.0"),
    /// inside `repository`; `package_in_eggy` for plugins that ship inside Eggy. Without one, it
    /// is `repository` at the commit this `eggy.zon` was read from (a raw.githubusercontent.com
    /// address), else at tag `v<version>`; or, read from a folder, that folder's package.
    package: ?[]const u8 = null,
    /// The oldest Eggy it works with, semver.
    minimum_eggy_version: ?[]const u8 = null,

    /// `package` for a plugin that ships inside Eggy: games get its module from Eggy itself.
    pub const package_in_eggy = "eggy";

    /// Whether games get it from Eggy itself rather than fetching a package.
    pub fn inEggy(self: Manifest) bool {
        return if (self.package) |package| std.mem.eql(u8, package, package_in_eggy) else false;
    }
};

/// A plugin a project installed, as its `eggy.zon` lists it under `.plugins`.
pub const Installed = struct {
    /// The module its package publishes, which the game is built with.
    module: []const u8,
    /// The dependency (in `build.zig.zon`) that publishes it; null for a plugin inside Eggy.
    dependency: ?[]const u8 = null,
    /// The version installed, semver.
    version: []const u8 = "",
    /// Left out of exported games (see `Manifest.dev`).
    dev: bool = false,
    /// Where its `eggy.zon` was read from (an address or a path), to look for a newer version.
    source: []const u8 = "",
    /// Its `Manifest.repository`, which an update must name too.
    repository: []const u8 = "",
    /// Its package's fingerprint, which an update's package must have too.
    fingerprint: ?u64 = null,
};

/// The `eggy.zon` of a plugin's folder: its manifest, among whatever else it holds (a plugin's
/// package can be a game project too).
const File = struct { plugin: Manifest };

/// The manifest in `source` (a plugin's `eggy.zon`), its strings in `arena`. Fails with
/// `error.NotAPlugin` when `source` has no `.plugin` section, `error.ParseZon` when it isn't ZON,
/// and `error.InvalidVersion` or `error.InvalidModule` when those fields can't be used.
///
/// ```zig
/// const manifest = try plugin_manifest.parse(arena, source);
/// std.debug.print("{s} {s}\n", .{ manifest.title, manifest.version });
/// ```
pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) !Manifest {
    if (!mentionsPluginField(source)) return error.NotAPlugin;
    // Build scripts read this file too, so it can't use `eggy.assets.zon`.
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const file = try std.zon.parse.fromSlice(File, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    const manifest = file.plugin;
    _ = std.SemanticVersion.parse(manifest.version) catch return error.InvalidVersion;
    _ = repositoryPath(manifest.repository) orelse return error.InvalidRepository;
    if (manifest.package) |package| if (!manifest.inEggy() and !packageInRepository(package, manifest.repository)) return error.PackageOutsideRepository;
    if (manifest.minimum_eggy_version) |minimum| _ = std.SemanticVersion.parse(minimum) catch return error.InvalidVersion;
    if (!isIdentifier(manifest.module)) return error.InvalidModule;
    return manifest;
}

/// Whether `source` sets a `.plugin` field (not `.plugins`, a project's installed list).
fn mentionsPluginField(source: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, ".plugin")) |found| {
        at = found + ".plugin".len;
        const rest = std.mem.trimStart(u8, source[at..], " \t\r\n");
        if (rest.len > 0 and rest[0] == '=') return true;
    }
    return false;
}

/// `repository` ("https://github.com/owner/repo", any host) as "github.com/owner/repo", lower
/// case and without a trailing `/` or `.git`; null unless it is an https address with a path.
pub fn repositoryPath(repository: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, repository, "https://")) repository["https://".len..] else return null;
    const trimmed = std.mem.trimEnd(u8, std.mem.trimEnd(u8, rest, "/"), ".git");
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return null;
    if (slash == 0 or slash + 1 == trimmed.len) return null;
    return trimmed;
}

/// Whether `package` (as `zig fetch` takes it) comes from `repository`: a git or https address
/// of the same repository (ignoring case, `.git`, and any `#ref` or `?query`), or an archive in it.
pub fn packageInRepository(package: []const u8, repository: []const u8) bool {
    const home = repositoryPath(repository) orelse return false;
    var address = package;
    if (std.mem.startsWith(u8, address, "git+")) address = address["git+".len..];
    if (!std.mem.startsWith(u8, address, "https://")) return false;
    address = address["https://".len..];
    const end = std.mem.indexOfAny(u8, address, "#?") orelse address.len;
    address = address[0..end];
    if (address.len < home.len or !std.ascii.eqlIgnoreCase(address[0..home.len], home)) return false;
    const after = address[home.len..];
    return after.len == 0 or after[0] == '/' or std.mem.eql(u8, after, ".git");
}

/// Whether `name` can name a module or a dependency: letters, digits and `_`, not starting with
/// a digit.
pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// How semver `a` compares with `b`; an unreadable version is older than any other.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const left = std.SemanticVersion.parse(a) catch return if (std.SemanticVersion.parse(b)) |_| .lt else |_| .eq;
    const right = std.SemanticVersion.parse(b) catch return .gt;
    return left.order(right);
}

test "a plugin's eggy.zon gives its manifest, around whatever else it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try parse(arena.allocator(),
        \\.{
        \\    .name = "stats_game",
        \\    .title = "Stats Game",
        \\    .plugin = .{ .title = "Stats", .module = "stats", .version = "1.2.0", .dev = true, .repository = "https://github.com/rat/stats", .fingerprint = 0x1234 },
        \\}
    );
    try std.testing.expectEqualStrings("stats", manifest.module);
    try std.testing.expect(manifest.dev and !manifest.inEggy());
    try std.testing.expectEqualStrings("README.md", manifest.readme);

    try std.testing.expectError(error.NotAPlugin, parse(arena.allocator(), ".{ .name = \"game\", .title = \"Game\", .plugins = .{} }"));
    try std.testing.expectError(error.ParseZon, parse(arena.allocator(), ".{ .plugin = .{ .title = \"No module\" } }"));
    const home = ".repository = \"https://github.com/rat/stats\", .fingerprint = 1";
    try std.testing.expectError(error.InvalidVersion, parse(arena.allocator(), ".{ .plugin = .{ .title = \"T\", .module = \"m\", .version = \"one\", " ++ home ++ " } }"));
    try std.testing.expectError(error.InvalidModule, parse(arena.allocator(), ".{ .plugin = .{ .title = \"T\", .module = \"my-plugin\", .version = \"1.0.0\", " ++ home ++ " } }"));
    // A package from somewhere else than the repository it names is refused.
    try std.testing.expectError(error.PackageOutsideRepository, parse(arena.allocator(), ".{ .plugin = .{ .title = \"T\", .module = \"m\", .version = \"1.0.0\", .package = \"git+https://github.com/mallory/stats#v1\", " ++ home ++ " } }"));
}

test "a package comes from its repository only by the same address" {
    const repository = "https://github.com/Rat/stats/";
    try std.testing.expectEqualStrings("github.com/Rat/stats", repositoryPath(repository).?);
    try std.testing.expect(packageInRepository("git+https://github.com/rat/stats.git#v1.0.0", repository));
    try std.testing.expect(packageInRepository("https://github.com/rat/stats/archive/v1.0.0.tar.gz", repository));
    try std.testing.expect(!packageInRepository("git+https://github.com/rat/stats-evil#v1", repository));
    try std.testing.expect(!packageInRepository("git+http://github.com/rat/stats#v1", repository));
    try std.testing.expect(repositoryPath("github.com/rat/stats") == null);
}

test "versions compare as semver" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.9.0", "0.10.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0.0", "1.0.0-beta"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("2.1.3", "2.1.3"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("", "0.0.1"));
}
