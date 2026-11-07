//! Where packaged projects get newer Eggy from: a Git repository and ref (the `eggy_source`
//! preference), whose commit is read in the background from the server's ref list (Git's smart
//! HTTP `info/refs`, which GitHub, Gitea, GitLab and plain Git servers all answer), and fetched
//! with `zig fetch` into the engines folder for File > Upgrade Editor.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const process_environ = @import("../process_environ.zig");
const engine = @import("engine.zig");

/// The source a fresh install checks.
pub const default = "https://github.com/eggyengine/eggy#main";

/// The most a server's ref list may be.
const max_refs = 4 << 20;

/// A repository and the ref in it to follow. Borrows the text it was parsed from.
pub const Source = struct {
    /// An http(s) address, without `git+` or a trailing `/`.
    url: []const u8,
    /// A branch, a tag, or a full commit; `HEAD` (the default branch) when none was given.
    ref: []const u8,

    /// `text` (`[git+]https://host/repo[#ref]`) taken apart. Fails with `error.InvalidSource`
    /// when it isn't an http(s) address.
    ///
    /// ```zig
    /// const source = try Source.parse("https://github.com/eggyengine/eggy#main");
    /// ```
    pub fn parse(text: []const u8) !Source {
        var rest = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.startsWith(u8, rest, "git+")) rest = rest["git+".len..];
        const hash = std.mem.indexOfScalar(u8, rest, '#');
        const url = std.mem.trimEnd(u8, if (hash) |at| rest[0..at] else rest, "/");
        const ref = if (hash) |at| rest[at + 1 ..] else "";
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidSource;
        if (std.mem.indexOfScalar(u8, url[std.mem.indexOf(u8, url, "://").? + 3 ..], '/') == null) return error.InvalidSource;
        return .{ .url = url, .ref = if (ref.len == 0) "HEAD" else ref };
    }
};

/// The commit `ref` names in `refs`, a smart HTTP ref list (`info/refs?service=git-upload-pack`):
/// the branch, else the commit a tag points at, else `HEAD` for `HEAD`. A full commit is its own
/// answer. Borrows `refs` or `ref`; null when the list doesn't have it.
fn findCommit(refs: []const u8, ref: []const u8) ?[]const u8 {
    if (isCommit(ref)) return ref;
    var branch: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var peeled: ?[]const u8 = null;
    var at: usize = 0;
    // Each pkt-line is four hex digits of length (counting themselves), then the line; `0000`
    // ends a section. A ref's line is `<commit> <name>`, the first one followed by NUL and
    // capabilities.
    while (at + 4 <= refs.len) {
        const len = std.fmt.parseInt(usize, refs[at .. at + 4], 16) catch return null;
        if (len == 0) {
            at += 4;
            continue;
        }
        if (len < 4 or at + len > refs.len) return null;
        const line = std.mem.trimEnd(u8, refs[at + 4 .. at + len], "\n");
        at += len;
        const fields = line[0 .. std.mem.indexOfScalar(u8, line, 0) orelse line.len];
        const space = std.mem.indexOfScalar(u8, fields, ' ') orelse continue;
        const commit = fields[0..space];
        const name = fields[space + 1 ..];
        if (!isCommit(commit)) continue;
        if (std.mem.eql(u8, ref, "HEAD") and std.mem.eql(u8, name, "HEAD")) return commit;
        if (nameIs(name, "refs/heads/", ref, "")) branch = commit;
        if (nameIs(name, "refs/tags/", ref, "")) tag = commit;
        if (nameIs(name, "refs/tags/", ref, "^{}")) peeled = commit;
    }
    return branch orelse peeled orelse tag;
}

fn nameIs(name: []const u8, prefix: []const u8, ref: []const u8, suffix: []const u8) bool {
    return name.len == prefix.len + ref.len + suffix.len and std.mem.startsWith(u8, name, prefix) and
        std.mem.eql(u8, name[prefix.len..][0..ref.len], ref) and std.mem.endsWith(u8, name, suffix);
}

/// Whether `text` is a full SHA-1 commit id.
fn isCommit(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// What a check ended with.
pub const Outcome = union(enum) {
    /// The commit the source's ref is at.
    commit: [40]u8,
    /// Why it failed, for the log: static text.
    failed: []const u8,
};

/// One source's ref being read on a worker.
pub const Check = struct {
    gpa: std.mem.Allocator,
    /// The worker's I/O, with the editor's environment (for proxies and certificates).
    threaded: std.Io.Threaded,
    /// The source as typed, owned; `source` borrows it.
    text: []u8,
    source: Source,
    worker: std.Io.Future(void) = undefined,

    // Shared with the worker, under `mutex`.
    mutex: std.Io.Mutex = .init,
    outcome: ?Outcome = null,

    /// Start reading which commit `text` (see `Source.parse`) names. Fails at once only for a
    /// source that isn't an address, or allocation; reading failures come from `take`.
    /// Pair with `destroy`.
    ///
    /// ```zig
    /// const check = try Check.start(gpa, "https://github.com/eggyengine/eggy#main");
    /// defer check.destroy();
    /// ```
    pub fn start(gpa: std.mem.Allocator, text: []const u8) !*Check {
        const self = try gpa.create(Check);
        errdefer gpa.destroy(self);
        const owned = try gpa.dupe(u8, text);
        errdefer gpa.free(owned);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = process_environ.current() }), .text = owned, .source = try Source.parse(owned) };
        errdefer self.threaded.deinit();
        self.worker = try self.threaded.io().concurrent(work, .{self});
        return self;
    }

    /// Its outcome once it has one, which never changes after: borrowed until `destroy`.
    pub fn take(self: *Check) ?*const Outcome {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return if (self.outcome) |*outcome| outcome else null;
    }

    /// Stop reading if it still is, and free it.
    pub fn destroy(self: *Check) void {
        const gpa = self.gpa;
        self.worker.cancel(self.threaded.io());
        self.threaded.deinit();
        gpa.free(self.text);
        gpa.destroy(self);
    }

    fn work(self: *Check) void {
        var commit: [40]u8 = undefined;
        const outcome: Outcome = if (self.read(&commit)) .{ .commit = commit } else |err| .{ .failed = describe(err) };
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.outcome = outcome;
    }

    fn read(self: *Check, commit: *[40]u8) !void {
        if (isCommit(self.source.ref)) {
            @memcpy(commit, self.source.ref);
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.threaded.io() };
        defer client.deinit();
        const url = try std.fmt.allocPrint(arena, "{s}/info/refs?service=git-upload-pack", .{self.source.url});
        var body: std.Io.Writer.Allocating = .init(arena);
        const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
        if (result.status == .not_found) return error.RepositoryNotFound;
        if (result.status.class() != .success) return error.HttpError;
        if (body.written().len > max_refs) return error.FileTooBig;
        @memcpy(commit, findCommit(body.written(), self.source.ref) orelse return error.RefNotFound);
    }
};

/// What to tell someone when `err` stops a check or a download.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidSource => "the Eggy source isn't an https address of a Git repository",
        error.RepositoryNotFound => "there is no Git repository at the Eggy source",
        error.RefNotFound => "the Eggy source's repository has no such branch or tag",
        error.HttpError => "the Eggy source's server didn't send its branches",
        error.FileTooBig => "the Eggy source's server sent too much",
        error.ZigNotFound => "Zig isn't on your PATH",
        error.FetchFailed => "zig fetch couldn't get that commit of Eggy",
        error.NotAnEggy => "the Eggy source's repository isn't Eggy: it has no build.zig.zon",
        error.UnknownHostName, error.ConnectionRefused, error.NetworkUnreachable, error.TlsInitializationFailed => "couldn't reach the Eggy source's server",
        else => @errorName(err),
    };
}

/// The engine directory `commit` of `source` unpacks into: its first 16 characters, as long as
/// the names of engines unpacked from an editor's `eggy.tar`.
pub fn engineName(commit: []const u8) []const u8 {
    return commit[0..16];
}

/// Fetch `commit` of the repository at `url` into `engines_dir` (absolute), unless it is there
/// already, recording the commit in it (`engine.markCommit`). Returns the engine directory,
/// caller-owned. Runs `zig fetch`, which puts it in Zig's global cache, then unpacks it from there
/// beside its final name and renames it, so a half-unpacked engine is never taken for one.
/// Blocking: call from a worker.
///
/// ```zig
/// const dir = try download(gpa, io, engines_dir, "https://git.tirbo.fish/eggy/eggy", commit);
/// defer gpa.free(dir);
/// ```
pub fn download(gpa: std.mem.Allocator, io: std.Io, engines_dir: []const u8, url: []const u8, commit: []const u8) ![]u8 {
    const dir = try std.fs.path.join(gpa, &.{ engines_dir, engineName(commit) });
    errdefer gpa.free(dir);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, try std.fs.path.join(arena, &.{ dir, "build.zig.zon" }), .{})) |_| return dir else |_| {}

    const location = try std.fmt.allocPrint(arena, "git+{s}#{s}", .{ url, commit });
    const hash = std.mem.trim(u8, try zig(arena, io, &.{ "zig", "fetch", location }), " \r\n");
    const Env = struct { global_cache_dir: []const u8 };
    const env_text = try zig(arena, io, &.{ "zig", "env" });
    const env = zon_file.parse(Env, arena, try arena.dupeSentinel(u8, env_text, 0), .{ .ignore_unknown_fields = true }) catch return error.FetchFailed;
    const tarball_path = try std.fs.path.join(arena, &.{ env.global_cache_dir, "p", try std.fmt.allocPrint(arena, "{s}.tar.gz", .{hash}) });

    var tarball = cwd.openFile(io, tarball_path, .{}) catch return error.FetchFailed;
    defer tarball.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_reader = tarball.reader(io, &file_buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &window);

    const partial = try std.mem.concat(arena, u8, &.{ dir, ".partial" });
    cwd.deleteTree(io, partial) catch {};
    try cwd.createDirPath(io, partial);
    errdefer cwd.deleteTree(io, partial) catch {};
    {
        var target = try cwd.openDir(io, partial, .{});
        defer target.close(io);
        // Zig keeps a package under a folder named for its hash.
        try std.tar.extract(io, target, &gzip.reader, .{ .strip_components = 1 });
        target.access(io, "build.zig.zon", .{}) catch return error.NotAnEggy;
    }
    try engine.markCommit(io, partial, commit);
    try cwd.rename(partial, cwd, dir, io);
    return dir;
}

/// Run Zig with `argv`, returning its output in `arena`.
fn zig(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| return if (err == error.FileNotFound) error.ZigNotFound else err;
    if (!result.term.success()) {
        std.log.err("{s} {s} failed: {s}", .{ argv[0], argv[1], result.stderr });
        return error.FetchFailed;
    }
    return result.stdout;
}

test "a source is an address and a ref, HEAD when none is given" {
    const source = try Source.parse(" git+https://git.tirbo.fish/eggy/eggy/#main ");
    try std.testing.expectEqualStrings("https://git.tirbo.fish/eggy/eggy", source.url);
    try std.testing.expectEqualStrings("main", source.ref);
    try std.testing.expectEqualStrings("HEAD", (try Source.parse("https://github.com/me/eggy")).ref);
    try std.testing.expectError(error.InvalidSource, Source.parse("git.tirbo.fish/eggy/eggy"));
    try std.testing.expectError(error.InvalidSource, Source.parse("https://example.com"));
}

test "a ref's commit is read from the server's ref list" {
    const main = "c2e4dc9e78c1222331c8b062d3a77169906145d4";
    const tag = "1111111111111111111111111111111111111111";
    const tagged = "2222222222222222222222222222222222222222";
    const refs = "001e# service=git-upload-pack\n0000" ++
        "0058" ++ main ++ " HEAD\x00multi_ack symref=HEAD:refs/heads/main\n" ++
        "003d" ++ main ++ " refs/heads/main\n" ++
        "003e" ++ tag ++ " refs/heads/mainx\n" ++
        "003e" ++ tag ++ " refs/tags/v0.2.0\n" ++
        "0041" ++ tagged ++ " refs/tags/v0.2.0^{}\n" ++ "0000";
    try std.testing.expectEqualStrings(main, findCommit(refs, "main").?);
    try std.testing.expectEqualStrings(main, findCommit(refs, "HEAD").?);
    try std.testing.expectEqualStrings(tagged, findCommit(refs, "v0.2.0").?);
    try std.testing.expect(findCommit(refs, "dev") == null);
    try std.testing.expectEqualStrings(tag, findCommit("", tag).?);
}
