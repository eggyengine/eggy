//! Getting a project's editor ready in the background, so the editor keeps drawing while it
//! happens. Creating a project unpacks Eggy's bundled package (once per version, shared by every
//! project) and writes the template as the new project; opening one reads its `eggy.zon`. Either
//! way the project's editor is then built, for `launchEditor`. `status` reports how far it is.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const template = @import("template.zig");
const log = std.log.scoped(.projects);

pub const Options = struct {
    /// The project's directory, absolute.
    dir: []const u8,
    /// Where the editor's `template.tar` and `eggy.tar` are, absolute.
    resources_dir: []const u8,
    /// Where unpacked engines live, one directory per version, absolute.
    engines_dir: []const u8,
    /// Make the project first, in `dir` (which must not exist yet, or be empty). Without it, the
    /// job opens the project already in `dir`.
    create: ?Create = null,
};

pub const Create = struct {
    /// What people see: any text.
    title: []const u8,
    /// The package name, checked with `template.validateName`.
    name: []const u8,
};

pub const Stage = enum {
    reading_project,
    unpacking_engine,
    writing_files,
    building,
    done,
    failed,

    pub fn label(stage: Stage) []const u8 {
        return switch (stage) {
            .reading_project => "Reading the project",
            .unpacking_engine => "Unpacking Eggy",
            .writing_files => "Writing the project",
            .building => "Building the editor",
            .done => "Done",
            .failed => "Failed",
        };
    }
};

/// A copy of the job's progress, for drawing.
pub const Status = struct {
    stage: Stage,
    /// The whole job's progress, 0 to 1.
    fraction: f32,
    /// What it is doing now: for the build, its step under way and how many steps are done.
    detail: []const u8,
    /// The end of the job's output so far: what it did, then the build's own output.
    log: []const u8,
};

pub const Job = struct {
    gpa: std.mem.Allocator,
    /// The job's own I/O: a thread pool for the worker, with the editor's environment so the
    /// build finds `zig` on PATH. The editor locks `mutex` through it too.
    threaded: std.Io.Threaded,
    /// `Options.dir`, `resources_dir` and `engines_dir`, owned.
    dir: []u8,
    resources_dir: []u8 = &.{},
    engines_dir: []u8 = &.{},
    /// `Options.create`, its text owned.
    create: ?Create,
    /// The project's package name: from `create`, or read from its `eggy.zon` before the build.
    name: []u8 = &.{},
    worker: std.Io.Future(void),

    // Shared with the worker, under `mutex`.
    mutex: std.Io.Mutex = .init,
    stage: Stage = .reading_project,
    /// The build's own progress, 0 to 1.
    build_fraction: f32 = 0,
    detail: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,

    /// Start the job described by `options` (copied).
    pub fn start(gpa: std.mem.Allocator, options: Options) !*Job {
        const self = try gpa.create(Job);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = processEnviron() }), .dir = try gpa.dupe(u8, options.dir), .create = null, .worker = undefined };
        errdefer self.freeText();
        errdefer self.threaded.deinit();
        self.resources_dir = try gpa.dupe(u8, options.resources_dir);
        self.engines_dir = try gpa.dupe(u8, options.engines_dir);
        if (options.create) |create| {
            self.create = .{ .title = "", .name = "" };
            inline for (.{ "title", "name" }) |field| @field(self.create.?, field) = try gpa.dupe(u8, @field(create, field));
            self.name = try gpa.dupe(u8, create.name);
        }
        self.worker = try self.io().concurrent(run, .{self});
        return self;
    }

    /// Stop the job if it is still running (the build is killed), and free it.
    pub fn deinit(self: *Job) void {
        const gpa = self.gpa;
        self.worker.cancel(self.io());
        self.threaded.deinit();
        self.freeText();
        self.detail.deinit(gpa);
        self.output.deinit(gpa);
        gpa.destroy(self);
    }

    fn freeText(self: *Job) void {
        const gpa = self.gpa;
        gpa.free(self.dir);
        gpa.free(self.resources_dir);
        gpa.free(self.engines_dir);
        gpa.free(self.name);
        if (self.create) |create| inline for (.{ "title", "name" }) |field| gpa.free(@field(create, field));
    }

    pub fn io(self: *Job) std.Io {
        return self.threaded.io();
    }

    /// The job's progress, with its text copied into `arena`.
    pub fn status(self: *Job, arena: std.mem.Allocator) !Status {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        const fraction: f32 = switch (self.stage) {
            .reading_project => 0.01,
            .unpacking_engine => 0.02,
            .writing_files => 0.08,
            .building => 0.1 + 0.88 * self.build_fraction,
            .done => 1,
            .failed => 0,
        };
        return .{
            .stage = self.stage,
            .fraction = fraction,
            .detail = try arena.dupe(u8, self.detail.items),
            .log = try arena.dupe(u8, self.output.items[self.output.items.len -| 4096..]),
        };
    }

    /// Open the project's editor with `--project`; call once the job is `done`. The editor
    /// runs on its own, so this one can quit.
    pub fn launchEditor(self: *Job) !void {
        const exe = try std.fmt.allocPrint(self.gpa, "{s}{c}zig-out{c}bin{c}{s}_editor{s}", .{ self.dir, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, self.name, builtin.target.exeFileExt() });
        defer self.gpa.free(exe);
        log.info("opening {s}", .{exe});
        _ = try std.process.spawn(self.io(), .{
            .argv = &.{ exe, "--project", self.dir },
            .cwd = .{ .path = self.dir },
            .stdin = .ignore,
        });
    }

    fn setStage(self: *Job, stage: Stage, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        self.stage = stage;
        self.detail.clearRetainingCapacity();
        self.detail.appendSlice(self.gpa, detail) catch {};
    }

    /// Add a line to the job's output, beside the build's own.
    fn say(self: *Job, comptime fmt: []const u8, args: anytype) void {
        log.info(fmt, args);
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        self.output.print(self.gpa, fmt ++ "\n", args) catch {};
    }

    fn run(self: *Job) void {
        self.prepare() catch |err| {
            if (err == error.Canceled) return;
            log.err("cannot prepare {s}: {t}", .{ self.dir, err });
            self.mutex.lockUncancelable(self.io());
            defer self.mutex.unlock(self.io());
            self.stage = .failed;
            self.detail.clearRetainingCapacity();
            self.detail.print(self.gpa, "{s}", .{describe(err)}) catch {};
        };
    }

    fn prepare(self: *Job) !void {
        if (self.create) |create| {
            const io_ = self.io();
            const gpa = self.gpa;

            // Eggy's package, unpacked once per version where every project can share it.
            self.setStage(.unpacking_engine, "");
            var resources = try std.Io.Dir.cwd().openDir(io_, self.resources_dir, .{});
            defer resources.close(io_);
            const engine_dir = try self.unpackEngine(resources);
            defer gpa.free(engine_dir);

            // The template, as the new project.
            self.setStage(.writing_files, self.dir);
            try self.writeProject(resources, create, engine_dir);
        } else try self.readProject();

        // Its editor, which `launchEditor` opens.
        self.setStage(.building, "Starting zig build");
        try self.build();
        self.setStage(.done, "");
    }

    /// Read the project's name from its `eggy.zon`, checking `dir` holds an Eggy project.
    fn readProject(self: *Job) !void {
        self.setStage(.reading_project, self.dir);
        const io_ = self.io();
        var project = std.Io.Dir.cwd().openDir(io_, self.dir, .{}) catch return error.NotAProject;
        defer project.close(io_);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const config = eggy.project.load(arena.allocator(), io_, project) catch |err| return switch (err) {
            error.FileNotFound => error.NotAProject,
            error.ParseZon => error.UnreadableConfig,
            else => err,
        };
        template.validateName(config.name) catch return error.UnreadableConfig;
        self.name = try self.gpa.dupe(u8, config.name);
        self.say("Opening {s} ({s})", .{ config.title, self.dir });
        try self.checkEngine(project, arena.allocator());
    }

    /// If the project's Eggy (a path dependency) is missing, say an engine folder that was
    /// cleaned up or a project copied from another machine, point it at this editor's bundled
    /// Eggy instead, unpacking that first.
    fn checkEngine(self: *Job, project: std.Io.Dir, arena: std.mem.Allocator) !void {
        const io_ = self.io();
        const manifest = project.readFileAllocOptions(io_, "build.zig.zon", arena, .limited(1 << 20), .of(u8), 0) catch return error.NotAProject;
        const Manifest = struct { dependencies: struct { eggy: struct { path: ?[]const u8 = null } = .{} } = .{} };
        const parsed = std.zon.parse.fromSliceAlloc(Manifest, arena, manifest, null, .{ .ignore_unknown_fields = true }) catch return error.UnreadableManifest;
        const old_path = parsed.dependencies.eggy.path orelse return; // fetched by URL: Zig's business
        if (project.access(io_, old_path, .{})) |_| return else |_| {}

        var resources = try std.Io.Dir.cwd().openDir(io_, self.resources_dir, .{});
        defer resources.close(io_);
        const engine_dir = try self.unpackEngine(resources);
        defer self.gpa.free(engine_dir);
        const new_path = try std.fs.path.relative(arena, "/", null, self.dir, engine_dir);
        const old_literal = try std.fmt.allocPrint(arena, "\"{f}\"", .{std.zig.fmtString(old_path)});
        const new_literal = try std.fmt.allocPrint(arena, "\"{f}\"", .{std.zig.fmtString(new_path)});
        const updated = try std.mem.replaceOwned(u8, arena, manifest, old_literal, new_literal);
        try project.writeFile(io_, .{ .sub_path = "build.zig.zon", .data = updated });
        self.say("Its Eggy ({s}) wasn't found, so it now uses this editor's: {s}", .{ old_path, engine_dir });
    }

    /// The directory holding `eggy.tar`'s package, unpacking it first if this version is new.
    fn unpackEngine(self: *Job, resources: std.Io.Dir) ![]u8 {
        const io_ = self.io();
        const gpa = self.gpa;
        const tarball = try resources.readFileAlloc(io_, "eggy.tar", gpa, .limited(256 << 20));
        defer gpa.free(tarball);

        // Name the version by its contents, so a new editor never reuses an old engine.
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
        const version = std.fmt.bytesToHex(digest[0..8], .lower);
        const dir = try std.fs.path.join(gpa, &.{ self.engines_dir, &version });
        errdefer gpa.free(dir);
        const cwd = std.Io.Dir.cwd();
        const manifest = try std.fs.path.join(gpa, &.{ dir, "build.zig.zon" });
        defer gpa.free(manifest);
        if (cwd.access(io_, manifest, .{})) |_| {
            self.say("Using Eggy from {s}", .{dir});
            return dir;
        } else |_| {}

        // Unpack beside it, then rename, so a half-unpacked engine is never mistaken for one.
        const partial = try std.mem.concat(gpa, u8, &.{ dir, ".partial" });
        defer gpa.free(partial);
        cwd.deleteTree(io_, partial) catch {};
        try cwd.createDirPath(io_, partial);
        var target = try cwd.openDir(io_, partial, .{});
        defer target.close(io_);
        var reader: std.Io.Reader = .fixed(tarball);
        try std.tar.extract(io_, target, &reader, .{});
        try cwd.rename(partial, cwd, dir, io_);
        self.say("Unpacked Eggy into {s}", .{dir});
        return dir;
    }

    /// Write `template.tar` into the project's (new, or empty) directory with its placeholders
    /// filled, pointing it at `engine_dir`.
    fn writeProject(self: *Job, resources: std.Io.Dir, create: Create, engine_dir: []const u8) !void {
        const io_ = self.io();
        const gpa = self.gpa;
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io_, self.dir);
        var project_dir = try cwd.openDir(io_, self.dir, .{ .iterate = true });
        defer project_dir.close(io_);
        var entries = project_dir.iterate();
        if (try entries.next(io_) != null) return error.ProjectDirNotEmpty;

        var random: [4]u8 = undefined;
        io_.random(&random);
        const engine_path = try std.fs.path.relative(gpa, "/", null, self.dir, engine_dir);
        defer gpa.free(engine_path);
        const project = template.Project{
            .name = create.name,
            .title = create.title,
            .fingerprint_id = template.fingerprintId(std.mem.readInt(u32, &random, .little)),
            .engine_path = engine_path,
        };

        const tarball = try resources.readFileAlloc(io_, "template.tar", gpa, .limited(16 << 20));
        defer gpa.free(tarball);
        var reader: std.Io.Reader = .fixed(tarball);
        var file_name: [std.fs.max_path_bytes]u8 = undefined;
        var link_name: [std.fs.max_path_bytes]u8 = undefined;
        var files = std.tar.Iterator.init(&reader, .{ .file_name_buffer = &file_name, .link_name_buffer = &link_name });
        while (try files.next()) |file| {
            if (file.kind != .file) continue;
            var contents: std.Io.Writer.Allocating = .init(gpa);
            defer contents.deinit();
            try files.streamRemaining(file, &contents.writer);
            const rendered = try template.render(gpa, contents.written(), project);
            defer gpa.free(rendered);
            if (std.fs.path.dirname(file.name)) |parent| try project_dir.createDirPath(io_, parent);
            try project_dir.writeFile(io_, .{ .sub_path = file.name, .data = rendered });
        }
        self.say("Wrote {s} into {s}", .{ create.name, self.dir });
    }

    /// `zig build editor` in the project, following its progress (on POSIX, through the
    /// `ZIG_PROGRESS` pipe Zig reports to) and keeping its output for `status`.
    fn build(self: *Job) !void {
        const io_ = self.io();
        const gpa = self.gpa;

        // Zig writes its progress tree to the file descriptor named in ZIG_PROGRESS. Spawning
        // removes that variable unless the progress goes into this process's own std.Progress
        // tree, which can't be read back, so a shell sets it and execs zig with the pipe.
        var progress_fds: ?[2]std.c.fd_t = null;
        var fd_text: [16]u8 = undefined;
        const plain_argv: []const []const u8 = &.{ "zig", "build", "editor", "--color", "off" };
        var argv = plain_argv;
        if (builtin.os.tag != .windows) {
            var fds: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&fds) == 0) {
                progress_fds = fds;
                argv = &.{ "/bin/sh", "-c", "ZIG_PROGRESS=\"$1\" exec zig build editor --color off", "sh", try std.fmt.bufPrint(&fd_text, "{d}", .{fds[1]}) };
            }
        }
        self.say("$ zig build editor   (in {s})", .{self.dir});
        var child = std.process.spawn(io_, .{
            .argv = argv,
            .cwd = .{ .path = self.dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch |err| {
            if (progress_fds) |fds| {
                for (fds) |fd| _ = std.c.close(fd);
            }
            return if (err == error.FileNotFound) error.ZigNotFound else err;
        };
        // Stop the build if the job is cancelled, or fails, before it ends.
        defer child.kill(io_);

        // The child has the write end now; ours would keep the pipe open past the build.
        var progress = if (progress_fds) |fds| blk: {
            _ = std.c.close(fds[1]);
            break :blk try io_.concurrent(followProgress, .{ self, std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } } });
        } else null;
        defer if (progress) |*task| task.cancel(io_);

        // Keep the build's error output, for when it fails.
        var buffer: [4096]u8 = undefined;
        var stderr = child.stderr.?.readerStreaming(io_, &buffer);
        while (true) {
            const chunk = stderr.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return stderr.err orelse err,
            };
            self.mutex.lockUncancelable(io_);
            self.output.appendSlice(gpa, chunk) catch {};
            self.mutex.unlock(io_);
            stderr.interface.toss(chunk.len);
        }

        const term = try child.wait(io_);
        if (term != .exited or term.exited != 0) return error.BuildFailed;
    }

    /// Read Zig's progress snapshots from `file` until the build closes it, keeping the overall
    /// fraction done and the step under way.
    fn followProgress(self: *Job, file: std.Io.File) void {
        const io_ = self.io();
        defer file.close(io_);
        var buffer: [8192]u8 = undefined;
        var reader = file.readerStreaming(io_, &buffer);
        var nodes: [255]ProgressNode = undefined;
        var parents: [255]u8 = undefined;
        while (true) {
            // A snapshot: its node count, every node, then each node's parent.
            const count = reader.interface.takeByte() catch return;
            reader.interface.readSliceAll(std.mem.sliceAsBytes(nodes[0..count])) catch return;
            reader.interface.readSliceAll(parents[0..count]) catch return;
            const summary = summarize(nodes[0..count], parents[0..count]) orelse continue;
            self.mutex.lockUncancelable(io_);
            defer self.mutex.unlock(io_);
            self.build_fraction = summary.fraction;
            self.detail.clearRetainingCapacity();
            self.detail.print(self.gpa, "{s} ({d}/{d})", .{ summary.step, summary.done, summary.total }) catch {};
        }
    }
};

/// One node of a `std.Progress` snapshot as Zig sends it (little endian; see `std.Progress`).
const ProgressNode = extern struct {
    completed_count: u32,
    /// 0 when unknown; maxInt marks a node standing in for a child process.
    estimated_total_count: u32,
    name: [120]u8 align(@alignOf(usize)),

    fn nameText(node: *const ProgressNode) []const u8 {
        return std.mem.sliceTo(&node.name, 0);
    }
};

const Summary = struct { fraction: f32, step: []const u8, done: u32, total: u32 };

/// The build's progress in a snapshot: the counter nearest the root (the build's steps, rather
/// than the compiler's work inside one), and the first named step under it, which is what is
/// being worked on.
fn summarize(nodes: []const ProgressNode, parents: []const u8) ?Summary {
    var best: ?usize = null;
    var best_depth: usize = std.math.maxInt(usize);
    for (nodes, 0..) |node, i| {
        const total = std.mem.littleToNative(u32, node.estimated_total_count);
        if (total == 0 or total == std.math.maxInt(u32)) continue;
        const depth = depthOf(parents, i);
        if (depth < best_depth) {
            best = i;
            best_depth = depth;
        }
    }
    const counter = best orelse return null;
    const done = std.mem.littleToNative(u32, nodes[counter].completed_count);
    const total = std.mem.littleToNative(u32, nodes[counter].estimated_total_count);
    var step = nodes[counter].nameText();
    for (parents, 0..) |parent, i| if (parent == counter and nodes[i].nameText().len > 0) {
        step = nodes[i].nameText();
        break;
    };
    return .{ .fraction = std.math.clamp(@as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total)), 0, 1), .step = step, .done = done, .total = total };
}

/// How many parents node `index` has; a broken chain counts as deep.
fn depthOf(parents: []const u8, index: usize) usize {
    var depth: usize = 0;
    var at = index;
    while (parents[at] < parents.len) : (depth += 1) {
        if (depth == parents.len) return depth;
        at = parents[at];
    }
    return depth;
}

/// The editor's own environment, for the job's I/O and the build it runs.
fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } },
    };
}

/// What to tell someone when `err` stops the job.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ZigNotFound => "Zig 0.16 isn't on your PATH. Install it, then try again.",
        error.BuildFailed => "The project was created, but its first build failed. The build's output is below.",
        error.ProjectDirNotEmpty => "The project's folder isn't empty.",
        error.NotAProject => "That folder isn't an Eggy project: it has no eggy.zon.",
        error.UnreadableConfig => "The project's eggy.zon couldn't be read. It needs a .name (the package name) and a .title.",
        error.UnreadableManifest => "The project's build.zig.zon couldn't be read.",
        error.AccessDenied, error.PermissionDenied => "Eggy isn't allowed to write there.",
        else => @errorName(err),
    };
}

test "a progress snapshot gives the build's step count and its current step" {
    var nodes: [4]ProgressNode = undefined;
    for (&nodes, [_][]const u8{ "", "steps", "compile exe game_editor", "Linking" }, [_][2]u32{ .{ 0, 0 }, .{ 3, 12 }, .{ 0, 0 }, .{ 900, 1000 } }) |*node, name, counts| {
        node.* = .{ .completed_count = counts[0], .estimated_total_count = counts[1], .name = @splat(0) };
        @memcpy(node.name[0..name.len], name);
    }
    const summary = summarize(&nodes, &.{ 255, 0, 1, 2 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), summary.fraction, 0.001);
    try std.testing.expectEqualStrings("compile exe game_editor", summary.step);
    try std.testing.expectEqual(@as(u32, 12), summary.total);
    try std.testing.expect(summarize(nodes[0..1], &.{255}) == null);
}

test "the job compiles" {
    std.testing.refAllDecls(Job);
}
