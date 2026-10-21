//! Where a plugin comes from: the `eggy.zon` someone typed, pasted or dropped (an address or a
//! path), the files beside it (its read-me), and the Zig package a game is built with.
const std = @import("std");
const eggy = @import("eggy");
const Manifest = eggy.plugin_manifest.Manifest;

/// Where a plugin's `eggy.zon` is.
pub const Origin = union(enum) {
    /// An https address.
    url: []const u8,
    /// An absolute path to the file.
    path: []const u8,

    pub fn text(origin: Origin) []const u8 {
        return switch (origin) {
            inline else => |value| value,
        };
    }
};

/// `typed` (an address, a GitHub page of the file or its folder, or a path to either; `~` is the
/// home folder) as the `eggy.zon` to read, in `arena`. Relative paths resolve from `cwd`.
/// Fails with `error.EmptyLocation` for blank input.
///
/// ```zig
/// const origin = try source.locate(arena, "https://github.com/me/plugins/tree/main/stats", "/");
/// // .url = "https://raw.githubusercontent.com/me/plugins/main/stats/eggy.zon"
/// ```
pub fn locate(arena: std.mem.Allocator, typed: []const u8, cwd: []const u8) !Origin {
    const trimmed = std.mem.trim(u8, typed, " \t\r\n\"'");
    if (trimmed.len == 0) return error.EmptyLocation;
    if (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://")) {
        var url = trimmed;
        // A GitHub page of the file (`blob`) or its folder (`tree`) as the raw file.
        if (githubPage(url)) |page| url = try std.fmt.allocPrint(arena, "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}", .{ page.owner, page.repo, page.ref, page.path });
        if (!std.mem.endsWith(u8, url, ".zon")) url = try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, url, "/"), "/", eggy.project.file_name });
        return .{ .url = url };
    }
    var path = trimmed;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        if (std.c.getenv("HOME")) |home| path = try std.mem.concat(arena, u8, &.{ std.mem.span(home), path[1..] });
    }
    path = try std.fs.path.resolve(arena, &.{ cwd, path });
    if (!std.mem.endsWith(u8, path, ".zon")) path = try std.fs.path.join(arena, &.{ path, eggy.project.file_name });
    return .{ .path = path };
}

/// The file `relative` (such as its `README.md`) beside `origin`'s `eggy.zon`, in `arena`.
pub fn sibling(arena: std.mem.Allocator, origin: Origin, relative: []const u8) !Origin {
    return switch (origin) {
        .url => |url| .{ .url = try std.mem.concat(arena, u8, &.{ url[0 .. (std.mem.lastIndexOfScalar(u8, url, '/') orelse url.len) + 1], relative }) },
        .path => |path| .{ .path = try std.fs.path.resolve(arena, &.{ std.fs.path.dirname(path) orelse "/", relative }) },
    };
}

/// The package a game builds a plugin from.
pub const Package = union(enum) {
    /// Eggy itself: the game takes the module of the Eggy it is built with.
    eggy,
    /// A package to fetch (as `zig fetch` takes it) into dependency `dependency`.
    fetch: struct { url: []const u8, dependency: []const u8 },
};

/// The package `manifest`, read from `origin`, is built from, in `arena`: Eggy, its own
/// `.package`, the commit of its repository a raw.githubusercontent.com `origin` names, the
/// package around a local `origin` (`package_root`, found by `packageRoot`), or its repository at
/// tag `v<version>`. Fails with `error.NotFromRepository` when a raw.githubusercontent.com
/// `origin` lies outside the repository the manifest names.
pub fn packageFor(arena: std.mem.Allocator, manifest: Manifest, origin: Origin, package_root: ?[]const u8) !Package {
    if (manifest.inEggy()) return .eggy;
    const dependency = try dependencyName(arena, manifest.repository);
    if (manifest.package) |package| return .{ .fetch = .{ .url = package, .dependency = dependency } };
    switch (origin) {
        .url => |url| if (rawGitHub(url)) |raw| {
            const at = try std.fmt.allocPrint(arena, "https://github.com/{s}/{s}", .{ raw.owner, raw.repo });
            if (!eggy.plugin_manifest.packageInRepository(at, manifest.repository)) return error.NotFromRepository;
            return .{ .fetch = .{ .url = try std.fmt.allocPrint(arena, "git+{s}#{s}", .{ at, raw.ref }), .dependency = dependency } };
        },
        .path => if (package_root) |root| return .{ .fetch = .{ .url = root, .dependency = dependency } },
    }
    return .{ .fetch = .{ .url = try std.fmt.allocPrint(arena, "git+{s}#v{s}", .{ std.mem.trimEnd(u8, manifest.repository, "/"), manifest.version }), .dependency = dependency } };
}

/// The nearest folder holding `path` with a `build.zig.zon`: the package of a local plugin, in
/// `arena`; null when there is none.
pub fn packageRoot(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    var folder = std.fs.path.dirname(path);
    while (folder) |at| : (folder = std.fs.path.dirname(at)) {
        const zon = std.fs.path.join(arena, &.{ at, "build.zig.zon" }) catch return null;
        if (std.Io.Dir.cwd().access(io, zon, .{})) return at else |_| {}
    }
    return null;
}

/// The dependency a repository's package is saved as in a game's `build.zig.zon`: its name, as
/// an identifier ("https://github.com/me/eggy-plugins" is `eggy_plugins`), shared by every plugin
/// of a repository that holds several.
pub fn dependencyName(arena: std.mem.Allocator, repository: []const u8) ![]const u8 {
    const home = eggy.plugin_manifest.repositoryPath(repository) orelse return error.InvalidRepository;
    const name = home[(std.mem.lastIndexOfScalar(u8, home, '/') orelse return error.InvalidRepository) + 1 ..];
    const identifier = try arena.alloc(u8, name.len + @intFromBool(std.ascii.isDigit(name[0])));
    var at: usize = 0;
    if (std.ascii.isDigit(name[0])) {
        identifier[0] = '_';
        at = 1;
    }
    for (name) |c| {
        identifier[at] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_';
        at += 1;
    }
    return identifier;
}

const Raw = struct { owner: []const u8, repo: []const u8, ref: []const u8 };

/// `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/...` taken apart.
fn rawGitHub(url: []const u8) ?Raw {
    const prefix = "https://raw.githubusercontent.com/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    var parts = std.mem.splitScalar(u8, url[prefix.len..], '/');
    const owner = parts.next() orelse return null;
    const repo = parts.next() orelse return null;
    var ref = parts.next() orelse return null;
    // `refs/heads/<branch>` names a branch the long way.
    if (std.mem.eql(u8, ref, "refs")) {
        _ = parts.next();
        ref = parts.next() orelse return null;
    }
    if (owner.len == 0 or repo.len == 0 or ref.len == 0) return null;
    return .{ .owner = owner, .repo = repo, .ref = ref };
}

const Page = struct { owner: []const u8, repo: []const u8, ref: []const u8, path: []const u8 };

/// `https://github.com/<owner>/<repo>/(blob|tree)/<ref>/<path>` taken apart.
fn githubPage(url: []const u8) ?Page {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    var parts = std.mem.splitScalar(u8, url[prefix.len..], '/');
    const owner = parts.next() orelse return null;
    const repo = parts.next() orelse return null;
    const kind = parts.next() orelse return null;
    if (!std.mem.eql(u8, kind, "blob") and !std.mem.eql(u8, kind, "tree")) return null;
    const ref = parts.next() orelse return null;
    return .{ .owner = owner, .repo = repo, .ref = ref, .path = std.mem.trimEnd(u8, parts.rest(), "/") };
}

test "a GitHub page of a plugin's folder or file reads its raw eggy.zon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://raw.githubusercontent.com/me/pack/main/stats/eggy.zon", (try locate(a, "https://github.com/me/pack/tree/main/stats/", "/")).url);
    try std.testing.expectEqualStrings("https://raw.githubusercontent.com/me/pack/v1/stats/eggy.zon", (try locate(a, "https://github.com/me/pack/blob/v1/stats/eggy.zon", "/")).url);
    try std.testing.expectEqualStrings("/work/stats/eggy.zon", (try locate(a, " stats ", "/work")).path);
    try std.testing.expectEqualStrings("/work/stats/README.md", (try sibling(a, .{ .path = "/work/stats/eggy.zon" }, "README.md")).path);
    try std.testing.expectEqualStrings("https://example.com/p/README.md", (try sibling(a, .{ .url = "https://example.com/p/eggy.zon" }, "README.md")).url);
    try std.testing.expectError(error.EmptyLocation, locate(a, "  ", "/"));
}

test "a plugin's package is its repository at the commit its eggy.zon came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manifest = Manifest{ .title = "Stats", .module = "stats", .version = "1.2.0", .repository = "https://github.com/Me/eggy-pack", .fingerprint = 1 };
    // From a raw file: the repository at that commit, saved under the repository's name.
    const raw = (try packageFor(a, manifest, .{ .url = "https://raw.githubusercontent.com/me/eggy-pack/abc123/stats/eggy.zon" }, null)).fetch;
    try std.testing.expectEqualStrings("git+https://github.com/me/eggy-pack#abc123", raw.url);
    try std.testing.expectEqualStrings("eggy_pack", raw.dependency);
    // A copy of the manifest hosted in someone else's repository is refused.
    try std.testing.expectError(error.NotFromRepository, packageFor(a, manifest, .{ .url = "https://raw.githubusercontent.com/mallory/pack/main/stats/eggy.zon" }, null));
    // Elsewhere: the tag of its version; from a folder: that folder's package.
    try std.testing.expectEqualStrings("git+https://github.com/Me/eggy-pack#v1.2.0", (try packageFor(a, manifest, .{ .url = "https://example.com/eggy.zon" }, null)).fetch.url);
    try std.testing.expectEqualStrings("/work/pack", (try packageFor(a, manifest, .{ .path = "/work/pack/stats/eggy.zon" }, "/work/pack")).fetch.url);
    var in_eggy = manifest;
    in_eggy.package = "eggy";
    try std.testing.expect(try packageFor(a, in_eggy, .{ .path = "/x/eggy.zon" }, null) == .eggy);
}
