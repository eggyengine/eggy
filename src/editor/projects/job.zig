//! Getting a project's editor ready in the background, so the editor keeps drawing while it
//! happens. Creating a project unpacks Eggy's bundled package (once per version, shared by every
//! project) and writes the template as the new project; opening one reads its `eggy.zon`;
//! upgrading one points it at the newest Eggy unpacked. Every way, the project's editor is then
//! built, for `launchEditor`; or, to export it, the game is built to ship (`zig build export`).
//! `status` reports how far it is.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const template = @import("template.zig");
const engine = @import("engine.zig");
const log = std.log.scoped(.projects);
const build_output = @import("build_output.zig");
const export_process = @import("export_process.zig");
/// The progress window's raw-output limit; Console diagnostics stream independently.
const max_output = 1 << 20;

pub const Options = struct {
    /// The project's directory, absolute.
    dir: []const u8,
    /// Where the editor's `template.tar` and `eggy.tar` are, absolute.
    resources_dir: []const u8,
    /// Where unpacked engines live, one directory per version, absolute.
    engines_dir: []const u8,
    action: Action,
};

/// What the job does to the project before building it.
pub const Action = union(enum) {
    /// Open the project already in `dir`, also unpacking this editor's Eggy so it is known to be
    /// the newest (see `engine.latest`) if it is new.
    open,
    /// Build the project in `dir` again, as it is.
    rebuild,
    /// Make the project first, in `dir` (which must not exist yet, or be empty).
    create: Create,
    /// Point the project in `dir` at the newest Eggy unpacked.
    upgrade,
    /// Point the project in `dir` at this Eggy codebase (absolute) for good: see
    /// `engine.ProjectEngine.linked`.
    link: []const u8,
    /// Build the game to ship into its `zig-out/export/`, rather than its editor: `zig build
    /// export` with these arguments, such as `-Dtarget=x86_64-windows-gnu` and
    /// `-Dscene=resources/main.scene.zon` (see `src/build/export.zig`).
    export_game: []const []const u8,
};

/// The editor's resources (beside its `bin` folder) and the user's engines folder, for `Options`.
/// Caller-owned.
/// Editor GUI/CLI helper: uses SDL executable/user-data paths without starting a project job.
/// Free both absolute strings with `gpa`; path/allocation errors clean partial results and
/// propagate. Does not create either directory.
///
/// ```zig
/// const folders = try editorFolders(gpa); // Existing allocator.
/// defer gpa.free(folders.resources_dir);
/// defer gpa.free(folders.engines_dir);
/// ```
pub fn editorFolders(gpa: std.mem.Allocator) !struct { resources_dir: []u8, engines_dir: []u8 } {
    const sdl3 = eggy.sdl_adapter.sdl;
    const resources_dir = try std.fs.path.resolve(gpa, &.{ try sdl3.filesystem.getBasePath(), "..", "resources" });
    errdefer gpa.free(resources_dir);
    const pref = try sdl3.filesystem.getPrefPath("eggy", "eggy");
    defer sdl3.free(pref);
    return .{ .resources_dir = resources_dir, .engines_dir = try std.fs.path.join(gpa, &.{ pref, "engines" }) };
}

pub const Create = struct {
    /// What people see: any text.
    title: []const u8,
    /// The package name, checked with `template.validateName`.
    name: []const u8,
};

pub const Stage = enum {
    reading_project,
    unpacking_engine,
    upgrading,
    linking,
    writing_files,
    building,
    exporting,
    done,
    failed,

    /// Return a static human-readable editor/CLI progress label for this job stage.
    ///
    /// ```zig
    /// const caption = Stage.building.label(); // "Building the editor"
    /// ```
    pub fn label(stage: Stage) []const u8 {
        return switch (stage) {
            .reading_project => "Reading the project",
            .unpacking_engine => "Unpacking Eggy",
            .upgrading => "Upgrading Eggy",
            .linking => "Linking Eggy",
            .writing_files => "Writing the project",
            .building => "Building the editor",
            .exporting => "Exporting the game",
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
    /// The job's output so far: what it did, then the build's own output. The job's own, valid
    /// until the next `status` or `deinit`.
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
    /// `Options.action`, its text owned.
    action: Action,
    /// The project's package name: from `.create`, or read from its `eggy.zon` before the build.
    name: []u8 = &.{},
    worker: std.Io.Future(void),

    // Shared with the worker, under `mutex`.
    mutex: std.Io.Mutex = .init,
    stage: Stage = .reading_project,
    /// The build's own progress, 0 to 1.
    build_fraction: f32 = 0,
    detail: std.ArrayList(u8) = .empty,
    /// Only grows (up to `max_output`), so `shown` catches up by copying what is new.
    output: std.ArrayList(u8) = .empty,

    /// `output` as `status` last handed it out; only the thread calling `status` touches it.
    shown: std.ArrayList(u8) = .empty,

    /// Start the job described by `options` (copied).
    /// Editor GUI/CLI only: paths must be absolute, and creation requires a missing/empty
    /// project directory. Owns copied options, threaded I/O and worker until `deinit`.
    /// Returns after spawning the worker; preparation/build failures are reported by `status`,
    /// while allocation/worker-start failures propagate. Worker actions can unpack engines,
    /// rewrite dependencies/project files and launch Zig; cancellation does not roll them back.
    ///
    /// ```zig
    /// // Given allocator and absolute project/resources/engine-store paths:
    /// const job = try Job.start(gpa, .{
    ///     .dir = project_dir, .resources_dir = resources_dir,
    ///     .engines_dir = engines_dir, .action = .rebuild,
    /// });
    /// defer job.deinit();
    /// ```
    pub fn start(gpa: std.mem.Allocator, options: Options) !*Job {
        const self = try gpa.create(Job);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = processEnviron() }), .dir = try gpa.dupe(u8, options.dir), .action = .open, .worker = undefined };
        errdefer self.freeText();
        errdefer self.threaded.deinit();
        self.resources_dir = try gpa.dupe(u8, options.resources_dir);
        self.engines_dir = try gpa.dupe(u8, options.engines_dir);
        switch (options.action) {
            .create => |create| {
                self.action = .{ .create = .{ .title = "", .name = "" } };
                inline for (.{ "title", "name" }) |field| @field(self.action.create, field) = try gpa.dupe(u8, @field(create, field));
                self.name = try gpa.dupe(u8, create.name);
            },
            .link => |dir| self.action = .{ .link = try gpa.dupe(u8, dir) },
            .export_game => |args| {
                const copies = try gpa.alloc([]const u8, args.len);
                var copied: usize = 0;
                errdefer {
                    for (copies[0..copied]) |arg| gpa.free(arg);
                    gpa.free(copies);
                }
                for (copies, args) |*copy, arg| {
                    copy.* = try gpa.dupe(u8, arg);
                    copied += 1;
                }
                self.action = .{ .export_game = copies };
            },
            else => self.action = options.action,
        }
        self.worker = try self.io().concurrent(run, .{self});
        return self;
    }

    /// Stop the job if it is still running (the build is killed), and free it.
    /// Editor GUI/CLI only: cancels/joins worker activity before releasing I/O and owned
    /// options/output. Call once with no concurrent status/io consumers; returned job/log
    /// pointers become invalid. Completed filesystem changes remain on disk.
    ///
    /// ```zig
    /// defer job.deinit(); // Existing Job pointer, retained until polling/launching is done.
    /// ```
    pub fn deinit(self: *Job) void {
        const gpa = self.gpa;
        self.worker.cancel(self.io());
        self.threaded.deinit();
        self.freeText();
        self.detail.deinit(gpa);
        self.output.deinit(gpa);
        self.shown.deinit(gpa);
        gpa.destroy(self);
    }

    fn freeText(self: *Job) void {
        const gpa = self.gpa;
        gpa.free(self.dir);
        gpa.free(self.resources_dir);
        gpa.free(self.engines_dir);
        gpa.free(self.name);
        if (self.action == .link) gpa.free(self.action.link);
        if (self.action == .export_game) {
            for (self.action.export_game) |arg| gpa.free(arg);
            gpa.free(self.action.export_game);
        }
        if (self.action == .create) inline for (.{ "title", "name" }) |field| gpa.free(@field(self.action.create, field));
    }

    /// Borrow this editor project's threaded I/O implementation and inherited process environment.
    /// The value is valid only until job teardown; do not use it concurrently with `deinit`.
    ///
    /// ```zig
    /// const job_io = job.io(); // Existing live Job pointer.
    /// ```
    pub fn io(self: *Job) std.Io {
        return self.threaded.io();
    }

    /// The job's progress, its detail copied into `arena` and its log the job's own (see
    /// `Status.log`). Call it from one thread only.
    /// Editor GUI/CLI only: locks shared progress while collecting a snapshot; fraction is
    /// normalized [0, 1]. Detail lives in `arena`, log borrows job storage until the next call
    /// or teardown. Allocation failures propagate and never transfer output ownership.
    ///
    /// ```zig
    /// const progress = try job.status(arena); // Live Job and per-frame arena allocator.
    /// std.log.info("{s}", .{progress.stage.label()});
    /// ```
    pub fn status(self: *Job, arena: std.mem.Allocator) !Status {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        const fraction: f32 = switch (self.stage) {
            .reading_project => 0.01,
            .unpacking_engine, .upgrading, .linking => 0.02,
            .writing_files => 0.08,
            .building, .exporting => 0.1 + 0.88 * self.build_fraction,
            .done => 1,
            .failed => 0,
        };
        // Copy only the output added since the last call, not all of it every frame.
        try self.shown.appendSlice(self.gpa, self.output.items[self.shown.items.len..]);
        return .{
            .stage = self.stage,
            .fraction = fraction,
            .detail = try arena.dupe(u8, self.detail.items),
            .log = self.shown.items,
        };
    }

    /// Open the project's editor with `--project`, and `extra_args` after it; call once the job
    /// is `done`. The editor runs on its own, so this one can quit.
    /// Editor GUI/CLI only: use after a successful editor-building action, not export_game.
    /// Does not verify stage/executable existence before spawning; allocation/spawn errors
    /// propagate. Extra argument strings are borrowed during spawn and the child owns its
    /// process lifetime independently of this job.
    ///
    /// ```zig
    /// // Given a Job whose latest status is .done after an editor build:
    /// try job.launchEditor(&.{});
    /// ```
    pub fn launchEditor(self: *Job, extra_args: []const []const u8) !void {
        const exe = try std.fmt.allocPrint(self.gpa, "{s}{c}zig-out{c}bin{c}{s}_editor{s}", .{ self.dir, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, self.name, builtin.target.exeFileExt() });
        defer self.gpa.free(exe);
        log.info("opening {s}", .{exe});
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ exe, "--project", self.dir });
        try argv.appendSlice(self.gpa, extra_args);
        _ = try std.process.spawn(self.io(), .{
            .argv = argv.items,
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
        switch (self.action) {
            .create => |create| {
                // Eggy's package, unpacked once per version where every project can share it.
                self.setStage(.unpacking_engine, "");
                const engine_dir = try self.unpackEngine();
                defer self.gpa.free(engine_dir);

                // The template, as the new project.
                self.setStage(.writing_files, self.dir);
                try self.writeProject(create, engine_dir);
            },
            .open => {
                // This editor's Eggy, so a newer editor makes its Eggy the one to upgrade to.
                self.setStage(.unpacking_engine, "");
                self.gpa.free(try self.unpackEngine());
                try self.readProject();
            },
            .rebuild, .upgrade, .link, .export_game => try self.readProject(),
        }

        // The game to ship; or its editor, which `launchEditor` opens.
        if (self.action == .export_game) {
            self.setStage(.exporting, "Starting zig build");
            const steps = try self.gpa.alloc([]const u8, self.action.export_game.len + 1);
            defer self.gpa.free(steps);
            steps[0] = "export";
            @memcpy(steps[1..], self.action.export_game);
            try self.build(steps);
        } else {
            self.setStage(.building, "Starting zig build");
            try self.build(&.{"editor"});
        }
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
        switch (self.action) {
            .upgrade => try self.upgrade(project, arena.allocator()),
            .link => |codebase| try self.link(project, arena.allocator(), codebase),
            else => try self.checkEngine(project, arena.allocator()),
        }
    }

    /// Point the project at the newest Eggy unpacked, which its next build uses.
    fn upgrade(self: *Job, project: std.Io.Dir, arena: std.mem.Allocator) !void {
        self.setStage(.upgrading, "");
        const io_ = self.io();
        // A linked project stays on its codebase.
        const path = try engine.dependencyPath(arena, io_, project) orelse return error.EngineNotAPath;
        if (!engine.isPackagedPath(path)) return error.ProjectIsLinked;
        const version = try engine.latest(arena, io_, self.engines_dir) orelse return error.NoEngineToUpgradeTo;
        const engine_dir = try std.fs.path.join(arena, &.{ self.engines_dir, version });
        try engine.repoint(arena, io_, project, self.dir, engine_dir);
        self.say("Upgraded to Eggy {s}: {s}", .{ version, engine_dir });
    }

    /// Point the project at the Eggy codebase `codebase`, which its builds use from now on.
    fn link(self: *Job, project: std.Io.Dir, arena: std.mem.Allocator, codebase: []const u8) !void {
        self.setStage(.linking, codebase);
        try engine.repoint(arena, self.io(), project, self.dir, codebase);
        self.say("Linked to the Eggy codebase at {s}", .{codebase});
    }

    /// If the project's Eggy (a path dependency) is missing, say an engine folder that was
    /// cleaned up or a project copied from another machine, point it at this editor's bundled
    /// Eggy instead, unpacking that first.
    fn checkEngine(self: *Job, project: std.Io.Dir, arena: std.mem.Allocator) !void {
        const io_ = self.io();
        const dependency_path = engine.dependencyPath(arena, io_, project) catch |err| return switch (err) {
            error.FileNotFound => error.NotAProject,
            else => err,
        };
        const old_path = dependency_path orelse return; // fetched by URL: Zig's business
        if (project.access(io_, old_path, .{})) |_| return else |_| {}
        // A linked codebase that went missing is not swapped for a packaged Eggy: that would
        // undo the link.
        if (!engine.isPackagedPath(old_path)) {
            self.say("The Eggy codebase this project is linked to ({s}) wasn't found", .{old_path});
            return error.LinkedEngineMissing;
        }

        const engine_dir = try self.unpackEngine();
        defer self.gpa.free(engine_dir);
        try engine.repoint(arena, io_, project, self.dir, engine_dir);
        self.say("Its Eggy ({s}) wasn't found, so it now uses this editor's: {s}", .{ old_path, engine_dir });
    }

    /// The directory holding `eggy.tar`'s package, unpacking it first if this version is new, and
    /// then recording it as the newest. Caller-owned.
    fn unpackEngine(self: *Job) ![]u8 {
        const io_ = self.io();
        const gpa = self.gpa;
        var resources = try std.Io.Dir.cwd().openDir(io_, self.resources_dir, .{});
        defer resources.close(io_);
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
            // Engines unpacked before `latest` was kept still need one to be the newest.
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            if (try engine.latest(arena.allocator(), io_, self.engines_dir) == null) try engine.markLatest(io_, self.engines_dir, &version);
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
        // ponytail: "newest" means most recently unpacked, so an older editor unpacking its Eggy after a cleanup takes over; compare versions if that bites.
        try engine.markLatest(io_, self.engines_dir, &version);
        self.say("Unpacked Eggy into {s}", .{dir});
        return dir;
    }

    /// Write `template.tar` into the project's (new, or empty) directory with its placeholders
    /// filled, pointing it at `engine_dir`.
    fn writeProject(self: *Job, create: Create, engine_dir: []const u8) !void {
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

        var resources = try cwd.openDir(io_, self.resources_dir, .{});
        defer resources.close(io_);
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

    /// `zig build <steps>` in the project, following its progress (on POSIX, through the
    /// `ZIG_PROGRESS` pipe Zig reports to) and keeping its output for `status`.
    fn build(self: *Job, steps: []const []const u8) !void {
        const io_ = self.io();
        const gpa = self.gpa;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Zig writes its progress tree to the file descriptor named in ZIG_PROGRESS. `zig build`
        // doesn't pass it on to the build runner it starts, so the runner is started directly
        // (see Eggy's `src/build/runner.zig`), by a shell that sets the variable for it. A project
        // on an Eggy that can't say how runs `zig build`, without the steps' progress.
        var progress_fds: ?[2]std.c.fd_t = null;
        var fd_text: [16]u8 = undefined;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        if (builtin.os.tag != .windows) if (self.runnerArgv(arena)) |runner| {
            var fds: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&fds) == 0) {
                progress_fds = fds;
                try argv.appendSlice(gpa, &.{ "/bin/sh", "-c", "export ZIG_PROGRESS=\"$1\"; shift; exec \"$@\"", "sh", try std.fmt.bufPrint(&fd_text, "{d}", .{fds[1]}) });
                try argv.appendSlice(gpa, runner);
            }
        };
        if (progress_fds == null) try argv.appendSlice(gpa, &.{ "zig", "build" });
        try argv.appendSlice(gpa, steps);
        try argv.appendSlice(gpa, &.{ "--color", "off", "--summary", "none" });
        const shown = try std.mem.join(gpa, " ", steps);
        defer gpa.free(shown);
        self.say("$ zig build {s} --summary none   (in {s})", .{ shown, self.dir });
        var process = export_process.Process.spawn(io_, .{
            .argv = argv.items,
            .cwd = .{ .path = self.dir },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }, self.action == .export_game) catch |err| {
            if (progress_fds) |fds| {
                for (fds) |fd| _ = std.c.close(fd);
            }
            return if (err == error.FileNotFound) error.ZigNotFound else err;
        };
        // Stop the build if the job is cancelled, or fails, before it ends.
        defer process.stop(io_);
        const child = &process.child;

        // The child has the write end now; ours would keep the pipe open past the build.
        var progress = if (progress_fds) |fds| blk: {
            _ = std.c.close(fds[1]);
            break :blk try io_.concurrent(followProgress, .{ self, std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } } });
        } else null;
        defer if (progress) |*task| task.cancel(io_);

        // Keep raw output for progress, with each pipe grouping its own Console diagnostics.
        const output_start = self.output.items.len;
        var stdout = try io_.concurrent(followOutput, .{ self, child.stdout.? });
        defer _ = stdout.cancel(io_) catch false;
        const stderr_errors = try self.followOutput(child.stderr.?);
        const stdout_errors = try stdout.await(io_);

        const term = try child.wait(io_);
        const failed = term != .exited or term.exited != 0;
        if (failed and !stderr_errors and !stdout_errors) try build_output.log(gpa, self.output.items[output_start..], true, self.dir);
        if (failed) return error.BuildFailed;
    }

    /// The command line starting the project's build runner, as its build records it through
    /// `EGGY_RUNNER_FILE` while `zig build --help` compiles and runs it, in `arena`; null when the
    /// project's Eggy doesn't record it, or its build doesn't compile (`zig build` then says why).
    fn runnerArgv(self: *Job, arena: std.mem.Allocator) ?[]const []const u8 {
        const io_ = self.io();
        self.setStage(self.stage, "Compiling build.zig");
        const file = std.fs.path.join(arena, &.{ self.dir, ".zig-cache", "eggy_runner.txt" }) catch return null;
        std.Io.Dir.cwd().createDirPath(io_, std.fs.path.dirname(file).?) catch return null;
        std.Io.Dir.cwd().deleteFile(io_, file) catch {};
        var process = export_process.Process.spawn(io_, .{
            .argv = &.{ "/bin/sh", "-c", "EGGY_RUNNER_FILE=\"$1\" exec zig build --help", "sh", file },
            .cwd = .{ .path = self.dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }, self.action == .export_game) catch return null;
        defer process.stop(io_);
        const term = process.child.wait(io_) catch return null;
        if (term != .exited or term.exited != 0) return null;
        const text = std.Io.Dir.cwd().readFileAlloc(io_, file, arena, .limited(64 * 1024)) catch return null;
        var args: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| args.append(arena, line) catch return null;
        return if (args.items.len > 0) args.items else null;
    }

    /// Read a pipe through EOF, keeping progress output and streaming grouped diagnostics.
    /// Return whether this pipe reported an error.
    fn followOutput(self: *Job, file: std.Io.File) !bool {
        const io_ = self.io();
        var diagnostics = build_output.Stream{ .gpa = self.gpa, .project_dir = self.dir };
        defer diagnostics.deinit();
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io_, &buffer);
        var continuation = false;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                // A last line without a newline, else the end.
                error.EndOfStream => if (reader.interface.bufferedLen() > 0) try reader.interface.take(reader.interface.bufferedLen()) else break,
                error.StreamTooLong => try reader.interface.take(reader.interface.bufferedLen()),
                else => return reader.err orelse err,
            };
            if (self.action == .export_game and std.mem.startsWith(u8, line, "[Export SDK] "))
                self.setStage(.exporting, std.mem.trimEnd(u8, line["[Export SDK] ".len..], "\r\n"));
            {
                self.mutex.lockUncancelable(io_);
                defer self.mutex.unlock(io_);
                const kept = @min(line.len, max_output -| self.output.items.len);
                try self.output.appendSlice(self.gpa, line[0..kept]);
            }
            if (continuation) try diagnostics.continueLine(line) else try diagnostics.line(line);
            continuation = !std.mem.endsWith(u8, line, "\n");
        }
        try diagnostics.finish();
        return diagnostics.has_error;
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
            // Never back: steps after a nested build are counted as less than it was.
            self.build_fraction = @max(self.build_fraction, summary.fraction);
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

/// The build's progress in a snapshot: its "steps" counter (a build nested in one of its steps,
/// as `zig build export` runs, has its own, inside), and the first named step under the innermost
/// one, which is what is being worked on. Without one, the counter nearest the root (rather than
/// the compiler's work inside a step) stands in.
fn summarize(nodes: []const ProgressNode, parents: []const u8) ?Summary {
    // The step counters, outermost first, by depth.
    var counters: [8]usize = undefined;
    var depths: [8]usize = undefined;
    var count: usize = 0;
    for (nodes, 0..) |node, i| {
        if (!std.mem.eql(u8, node.nameText(), "steps") or count == counters.len) continue;
        const total = std.mem.littleToNative(u32, node.estimated_total_count);
        if (total == 0 or total == std.math.maxInt(u32)) continue;
        const depth = depthOf(parents, i);
        var at = count;
        while (at > 0 and depths[at - 1] > depth) : (at -= 1) {
            counters[at] = counters[at - 1];
            depths[at] = depths[at - 1];
        }
        counters[at] = i;
        depths[at] = depth;
        count += 1;
    }
    if (count == 0) {
        counters[0] = nearestCounter(nodes, parents) orelse return null;
        count = 1;
    }

    // From the innermost out: a nested build does the bulk of the work, so it stands for every
    // step of the build around it still to come.
    var fraction: f32 = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        const node = nodes[counters[i]];
        const done: f32 = @floatFromInt(std.mem.littleToNative(u32, node.completed_count));
        const total: f32 = @floatFromInt(std.mem.littleToNative(u32, node.estimated_total_count));
        fraction = std.math.clamp((done + fraction * (total - done)) / total, 0, 1);
    }
    const innermost = counters[count - 1];
    var step = nodes[innermost].nameText();
    for (parents, 0..) |parent, child| if (parent == innermost and nodes[child].nameText().len > 0) {
        step = nodes[child].nameText();
        break;
    };
    return .{ .fraction = fraction, .step = step, .done = std.mem.littleToNative(u32, nodes[innermost].completed_count), .total = std.mem.littleToNative(u32, nodes[innermost].estimated_total_count) };
}

/// The counter nearest the root, if any.
fn nearestCounter(nodes: []const ProgressNode, parents: []const u8) ?usize {
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
    return best;
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
        error.BuildFailed => "The project's build failed. Its output is below.",
        error.ExportProcessGroupFailed => "The system could not isolate the export's processes for safe cancellation.",
        error.ProjectDirNotEmpty => "The project's folder isn't empty.",
        error.NotAProject => "That folder isn't an Eggy project: it has no eggy.zon.",
        error.UnreadableConfig => "The project's eggy.zon couldn't be read. It needs a .name (the package name) and a .title.",
        error.UnreadableManifest => "The project's build.zig.zon couldn't be read.",
        error.NoEngineToUpgradeTo => "There is no newer Eggy to upgrade to. Open the project from a newer editor first.",
        error.ProjectIsLinked => "The project is linked to an Eggy codebase, so it builds against that and doesn't upgrade.",
        error.LinkedEngineMissing => "The Eggy codebase the project is linked to is missing. Put it back, or change the eggy path in its build.zig.zon.",
        error.EngineNotAPath => "The project gets Eggy by URL, so its build.zig.zon picks the version.",
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

test "a build nested in a step counts as that step's progress" {
    // The outer build at 1 of 4 steps, running a nested build at 3 of 6.
    var nodes: [6]ProgressNode = undefined;
    for (&nodes, [_][]const u8{ "", "steps", "zig build runtime", "steps", "compile exe game", "steps-not" }, [_][2]u32{ .{ 0, 0 }, .{ 1, 4 }, .{ 0, std.math.maxInt(u32) }, .{ 3, 6 }, .{ 0, 0 }, .{ 0, 0 } }) |*node, name, counts| {
        node.* = .{ .completed_count = counts[0], .estimated_total_count = counts[1], .name = @splat(0) };
        @memcpy(node.name[0..name.len], name);
    }
    const summary = summarize(&nodes, &.{ 255, 0, 1, 2, 3, 0 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.5 / 4.0), summary.fraction, 0.001);
    try std.testing.expectEqualStrings("compile exe game", summary.step);
    try std.testing.expectEqual(@as(u32, 6), summary.total);
}

test "the job compiles" {
    std.testing.refAllDecls(Job);
}
