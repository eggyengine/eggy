//! Which Eggy a project builds against: the engines unpacked into the user's data folder (one
//! directory per version, named by the hash of its `eggy.tar`) and which of them is the newest,
//! the Eggy codebase being developed on this machine, and pointing a project's `build.zig.zon`
//! at one of those.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;

/// Files in the engines folder: the newest engine unpacked (see `markLatest`), and the Eggy
/// codebase being developed on this machine (see `markDeveloper`).
const latest_file = "latest";
const developer_file = "developer";

/// Which Eggy a project builds against. Text lives in the caller's arena.
pub const ProjectEngine = union(enum) {
    /// One of the unpacked engines: its version, the directory's name.
    packaged: []const u8,
    /// A codebase of Eggy, absolute: one being developed, linked in with `repoint`. A linked
    /// project never goes back to a packaged engine.
    linked: []const u8,
    /// Fetched by URL: its `build.zig.zon` picks the version.
    fetched,

    /// Whether the project could move to `latest` (see `latest`): only packaged engines upgrade.
    /// Editor-only: compares recorded directory ids, not semantic versions or source contents.
    /// Null newest, linked/fetched engines and identical ids all return false.
    ///
    /// ```zig
    /// const available = (ProjectEngine{ .packaged = "aaaa" }).canUpgrade("bbbb");
    /// ```
    pub fn canUpgrade(self: ProjectEngine, newest: ?[]const u8) bool {
        const version = switch (self) {
            .packaged => |version| version,
            .linked, .fetched => return false,
        };
        return if (newest) |other| !std.mem.eql(u8, version, other) else false;
    }

    /// Whether the project could be linked to the Eggy codebase `developer` (see `developer`).
    /// Editor-only: compares recorded paths exactly without disk checks; fetched engines cannot
    /// link, and null/already-linked developer paths return false.
    ///
    /// ```zig
    /// const available = (ProjectEngine{ .packaged = "aaaa" }).canLink("/src/eggy");
    /// ```
    pub fn canLink(self: ProjectEngine, developer_dir: ?[]const u8) bool {
        const codebase = developer_dir orelse return false;
        return switch (self) {
            .packaged => true,
            .linked => |dir| !std.mem.eql(u8, dir, codebase),
            .fetched => false,
        };
    }
};

/// Which Eggy the project in `project_dir` (absolute) builds against; `engines_dir` (absolute)
/// tells packaged engines apart.
/// Editor-only: paths in the returned union live in `arena`. Resolves the manifest's relative
/// dependency path without requiring the engine to exist; missing path dependencies classify
/// as fetched. Directory/manifest/parse/allocation errors propagate.
///
/// ```zig
/// const current = try projectEngine(arena, io, project_dir, engines_dir);
/// // Existing arena allocator/I/O and absolute project/engine-store paths.
/// ```
pub fn projectEngine(arena: std.mem.Allocator, io: std.Io, project_dir: []const u8, engines_dir: []const u8) !ProjectEngine {
    var project = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
    defer project.close(io);
    const path = try dependencyPath(arena, io, project) orelse return .fetched;
    const engine_dir = try std.fs.path.resolve(arena, &.{ project_dir, path });
    const engines = try std.fs.path.resolve(arena, &.{engines_dir});
    const parent = std.fs.path.dirname(engine_dir) orelse "";
    return if (std.mem.eql(u8, parent, engines)) .{ .packaged = std.fs.path.basename(engine_dir) } else .{ .linked = engine_dir };
}

/// Whether a project's eggy dependency `path` names a packaged engine, on this machine or the
/// one the project came from: its directory sits in an `engines` folder.
/// Editor-only: lexical parent-name check, not a filesystem/provenance validation.
///
/// ```zig
/// const packaged = isPackagedPath("../engines/0123456789abcdef"); // true
/// ```
pub fn isPackagedPath(path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(parent), "engines");
}

/// The newest engine unpacked into `engines_dir`, as `markLatest` recorded it; null if none was.
/// Editor-only: verifies the recorded directory has `build.zig.zon`; missing/unreadable
/// directories yield null, while record-read/allocation failures can propagate.
/// The returned version string lives in `arena`; "newest" means most recently recorded.
///
/// ```zig
/// const version = try latest(arena, io, engines_dir); // Existing arena/I/O/store path.
/// ```
pub fn latest(arena: std.mem.Allocator, io: std.Io, engines_dir: []const u8) !?[]const u8 {
    const version = try readRecord(arena, io, engines_dir, latest_file) orelse return null;
    // Only a directory that is there and finished unpacking counts.
    try checkPackage(arena, io, try std.fs.path.join(arena, &.{ engines_dir, version })) orelse return null;
    return version;
}

/// Record `version` (a directory in `engines_dir`) as the newest engine.
/// Editor-only: caller must finish unpacking and create `engines_dir` first. Overwrites the
/// record directly; borrows input strings and propagates filesystem errors.
///
/// ```zig
/// try markLatest(io, engines_dir, version); // After unpacking this complete engine version.
/// ```
pub fn markLatest(io: std.Io, engines_dir: []const u8, version: []const u8) !void {
    try writeRecord(io, engines_dir, latest_file, version);
}

/// The Eggy codebase `markDeveloper` last recorded, absolute, if it is still there.
/// Editor-only: checks for `build.zig.zon`; returned path lives in `arena`. Missing record or
/// package yields null; record-read/allocation failures can propagate.
///
/// ```zig
/// const source_dir = try developer(arena, io, engines_dir); // Existing arena/I/O/store path.
/// ```
pub fn developer(arena: std.mem.Allocator, io: std.Io, engines_dir: []const u8) !?[]const u8 {
    const dir = try readRecord(arena, io, engines_dir, developer_file) orelse return null;
    try checkPackage(arena, io, dir) orelse return null;
    return dir;
}

/// Record `source_dir` (absolute), the Eggy an editor was built from, as the codebase being
/// developed if it is a Git checkout rather than a packaged engine.
/// Editor-only: missing/unreadable source or `.git` silently no-ops. Creates the engines
/// folder before overwriting its developer record; those filesystem errors propagate.
///
/// ```zig
/// try markDeveloper(io, engines_dir, "/src/eggy"); // Existing I/O and engine-store path.
/// ```
pub fn markDeveloper(io: std.Io, engines_dir: []const u8, source_dir: []const u8) !void {
    var source = std.Io.Dir.cwd().openDir(io, source_dir, .{}) catch return;
    defer source.close(io);
    source.access(io, ".git", .{}) catch return;
    try std.Io.Dir.cwd().createDirPath(io, engines_dir);
    try writeRecord(io, engines_dir, developer_file, source_dir);
}

/// Whether `dir` holds a package (a `build.zig.zon`): null when it doesn't.
fn checkPackage(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !?void {
    std.Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ dir, "build.zig.zon" }), .{}) catch return null;
}

fn readRecord(arena: std.mem.Allocator, io: std.Io, engines_dir: []const u8, name: []const u8) !?[]const u8 {
    var engines = std.Io.Dir.cwd().openDir(io, engines_dir, .{}) catch return null;
    defer engines.close(io);
    const text = engines.readFileAlloc(io, name, arena, .limited(std.fs.max_path_bytes)) catch |err| return switch (err) {
        error.FileNotFound => null,
        else => err,
    };
    const value = std.mem.trim(u8, text, " \r\n");
    return if (value.len == 0) null else value;
}

fn writeRecord(io: std.Io, engines_dir: []const u8, name: []const u8, value: []const u8) !void {
    var engines = try std.Io.Dir.cwd().openDir(io, engines_dir, .{});
    defer engines.close(io);
    try engines.writeFile(io, .{ .sub_path = name, .data = value });
}

/// The path of `build.zig.zon`'s eggy dependency, relative to `project`; null when it is
/// fetched by URL. Fails with `error.FileNotFound` without a `build.zig.zon`.
/// Editor-only: reads at most 1 MiB and returns parsed text living in `arena`; malformed ZON
/// returns UnreadableManifest. A missing dependency/path also returns null.
///
/// ```zig
/// const path = try dependencyPath(arena, io, project); // Arena/I/O and open project directory.
/// ```
pub fn dependencyPath(arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir) !?[]const u8 {
    return parseDependencyPath(arena, try readManifest(arena, io, project));
}

/// Point `project`'s (in `project_dir`, absolute) eggy dependency at `engine_dir` (absolute),
/// rewriting only that path in its `build.zig.zon`.
/// Editor-only: requires an existing path dependency (otherwise EngineNotAPath). Computes a
/// relative path, escapes it and replaces matching quoted old-path literals in the manifest;
/// no engine-existence check or atomic write. Scratch storage lives in `arena`; read/parse/
/// allocation/write errors propagate, and write failure may leave partial file contents.
///
/// ```zig
/// // Given arena/I/O, open project directory and both absolute paths:
/// try repoint(arena, io, project, project_dir, engine_dir);
/// ```
pub fn repoint(arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir, project_dir: []const u8, engine_dir: []const u8) !void {
    const manifest = try readManifest(arena, io, project);
    const old_path = try parseDependencyPath(arena, manifest) orelse return error.EngineNotAPath;
    // Zig rejects absolute dependency paths.
    const new_path = try std.fs.path.relative(arena, "/", null, project_dir, engine_dir);
    const old_literal = try std.fmt.allocPrint(arena, "\"{f}\"", .{std.zig.fmtString(old_path)});
    const new_literal = try std.fmt.allocPrint(arena, "\"{f}\"", .{std.zig.fmtString(new_path)});
    const updated = try std.mem.replaceOwned(u8, arena, manifest, old_literal, new_literal);
    try project.writeFile(io, .{ .sub_path = "build.zig.zon", .data = updated });
}

fn readManifest(arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir) ![:0]u8 {
    return project.readFileAllocOptions(io, "build.zig.zon", arena, .limited(1 << 20), .of(u8), 0);
}

fn parseDependencyPath(arena: std.mem.Allocator, manifest: [:0]const u8) !?[]const u8 {
    const Manifest = struct { dependencies: struct { eggy: struct { path: ?[]const u8 = null } = .{} } = .{} };
    const parsed = zon_file.parse(Manifest, arena, manifest, .{ .ignore_unknown_fields = true }) catch return error.UnreadableManifest;
    return parsed.dependencies.eggy.path;
}

test "a manifest's eggy path is found, and none when eggy is fetched by URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("../engines/abc", (try parseDependencyPath(arena.allocator(),
        \\.{ .name = .game, .dependencies = .{ .eggy = .{ .path = "../engines/abc" } } }
    )).?);
    try std.testing.expect(try parseDependencyPath(arena.allocator(),
        \\.{ .name = .game, .dependencies = .{ .eggy = .{ .url = "git+https://example.com/eggy", .hash = "x" } } }
    ) == null);
}

test "only a packaged engine upgrades, and only to a different one" {
    try std.testing.expect((ProjectEngine{ .packaged = "aaaa" }).canUpgrade("bbbb"));
    try std.testing.expect(!(ProjectEngine{ .packaged = "aaaa" }).canUpgrade("aaaa"));
    try std.testing.expect(!(ProjectEngine{ .packaged = "aaaa" }).canUpgrade(null));
    try std.testing.expect(!(ProjectEngine{ .linked = "/src/eggy" }).canUpgrade("bbbb"));
    try std.testing.expect(!(ProjectEngine{ .fetched = {} }).canUpgrade("bbbb"));
}

test "a project links to a developer codebase it isn't linked to yet" {
    try std.testing.expect((ProjectEngine{ .packaged = "aaaa" }).canLink("/src/eggy"));
    try std.testing.expect((ProjectEngine{ .linked = "/old/eggy" }).canLink("/src/eggy"));
    try std.testing.expect(!(ProjectEngine{ .linked = "/src/eggy" }).canLink("/src/eggy"));
    try std.testing.expect(!(ProjectEngine{ .packaged = "aaaa" }).canLink(null));
    try std.testing.expect(!(ProjectEngine{ .fetched = {} }).canLink("/src/eggy"));
}

test "packaged engine paths sit in an engines folder" {
    try std.testing.expect(isPackagedPath("../../.local/share/eggy/eggy/engines/0fd1c93de26789bd"));
    try std.testing.expect(!isPackagedPath("../../src/eggy"));
}
