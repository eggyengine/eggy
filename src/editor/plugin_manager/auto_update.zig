//! Keeping a project's installed plugins up to date: in the background, read each one's
//! `eggy.zon` again from where it was installed and offer a newer version, which is installed as
//! the Plugins window's Update would once the person agrees (a bad actor may have pushed it), one
//! plugin at a time. Plugins inside Eggy update with Eggy instead, and
//! those whose package is a folder (a checkout being developed) are left to whoever develops them.
const std = @import("std");
const eggy = @import("eggy");
const fetch_zig = @import("fetch.zig");
const install_zig = @import("install.zig");
const package_removal = @import("package_removal.zig");
const project_plugins = @import("project_plugins.zig");
const Installed = eggy.plugin_manifest.Installed;
const log = std.log.scoped(.plugins);

/// What a poll found.
pub const Progress = union(enum) {
    /// Still checking.
    working,
    /// Every plugin is checked; destroy it.
    done,
    /// A newer version is waiting for `answer`, borrowed until then. Reported once.
    offer: Offer,
    /// A plugin was updated: the change to record (the caller owns its texts), and what it
    /// became, borrowed until the next poll.
    updated: struct { change: project_plugins.Change, title: []const u8, version: []const u8 },
};

/// A newer version of an installed plugin, for the person to agree to.
pub const Offer = struct {
    module: []const u8,
    title: []const u8,
    installed_version: []const u8,
    version: []const u8,
    repository: []const u8,
    /// Where its `eggy.zon` was read from.
    source: []const u8,
};

pub const AutoUpdate = struct {
    gpa: std.mem.Allocator,
    /// The project's folder, and its installed plugins as read when the check started.
    arena: std.heap.ArenaAllocator,
    project_dir: []const u8,
    queue: []const Installed,
    next: usize = 0,
    /// The plugin being read again, then the newer one being installed (owned).
    fetching: ?*fetch_zig.Fetch = null,
    /// A newer version waiting for `answer` (owned), and whether `poll` has reported it.
    offered: ?*fetch_zig.Fetched = null,
    offer_reported: bool = false,
    newer: ?*fetch_zig.Fetched = null,
    installing: ?*install_zig.Install = null,
    /// `build.zig.zon` before `installing` saved the package, owned, for undo.
    package_before: ?[]u8 = null,
    /// The last update's name and version, for `Progress.updated`.
    reported: std.heap.ArenaAllocator,

    /// Start checking the plugins the project in `project_dir` installed from an address or a
    /// path. Fails only to allocate, or to read its `eggy.zon`.
    pub fn start(gpa: std.mem.Allocator, project_dir: []const u8) !*AutoUpdate {
        const self = try gpa.create(AutoUpdate);
        errdefer gpa.destroy(self);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
        defer dir.close(io);
        const config = try eggy.project.load(a, io, dir);
        const package = dir.readFileAllocOptions(io, "build.zig.zon", a, .limited(1 << 20), .of(u8), 0) catch "";
        // Only those fetched from somewhere can come from there again, and not over a local checkout.
        var queue: std.ArrayList(Installed) = .empty;
        for (config.plugins) |installed| {
            const dependency = installed.dependency orelse continue;
            if (installed.source.len == 0) continue;
            if (package_removal.isFolderDependency(a, package, dependency) catch false) continue;
            try queue.append(a, installed);
        }
        self.* = .{ .gpa = gpa, .arena = arena, .project_dir = try a.dupe(u8, project_dir), .queue = queue.items, .reported = .init(gpa) };
        return self;
    }

    /// Stop whatever is under way (an unfinished install leaves the project as it was) and free it.
    pub fn destroy(self: *AutoUpdate) void {
        const gpa = self.gpa;
        if (self.fetching) |fetch| fetch.destroy();
        if (self.installing) |running| running.destroy();
        if (self.offered) |fetched| fetched.destroy();
        if (self.newer) |fetched| fetched.destroy();
        if (self.package_before) |text| gpa.free(text);
        self.reported.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Move the check on, once a frame. Failures are logged and skip that plugin.
    pub fn poll(self: *AutoUpdate) Progress {
        if (self.installing) |running| return self.pollInstall(running);
        if (self.offered) |fetched| {
            if (self.offer_reported) return .working;
            self.offer_reported = true;
            const installed = self.queue[self.next - 1];
            return .{ .offer = .{
                .module = installed.module,
                .title = fetched.manifest.title,
                .installed_version = installed.version,
                .version = fetched.manifest.version,
                .repository = fetched.manifest.repository,
                .source = installed.source,
            } };
        }
        if (self.fetching) |fetch| {
            const outcome = fetch.take() orelse return .working;
            fetch.destroy();
            self.fetching = null;
            switch (outcome) {
                .fetched => |fetched| self.consider(fetched),
                .failed => |why| log.warn("cannot check {s} for an update: {s}", .{ self.queue[self.next - 1].module, why }),
            }
            return .working;
        }
        if (self.next == self.queue.len) return .done;
        const installed = self.queue[self.next];
        self.next += 1;
        self.fetching = fetch_zig.Fetch.start(self.gpa, installed.source, self.project_dir) catch |err| {
            log.warn("cannot check {s} for an update: {t}", .{ installed.module, err });
            return .working;
        };
        return .working;
    }

    /// Install `fetched` (owned) if it is a newer version of the plugin just checked.
    fn consider(self: *AutoUpdate, fetched: *fetch_zig.Fetched) void {
        const installed = self.queue[self.next - 1];
        const manifest = fetched.manifest;
        const skip: ?[]const u8 = if (!std.mem.eql(u8, manifest.module, installed.module))
            "its eggy.zon now names another module"
        else if (eggy.plugin_manifest.compareVersions(manifest.version, installed.version) != .gt)
            null
        else if (project_plugins.replacementProblem(installed, manifest)) |why|
            why
        else if (project_plugins.needsNewerEggy(manifest))
            "it needs a newer Eggy: use File > Upgrade Editor"
        else if (fetched.package != .fetch)
            "it now says it ships inside Eggy"
        else {
            self.offered = fetched;
            self.offer_reported = false;
            return;
        };
        if (skip) |why| log.warn("not updating {s} to {s}: {s}", .{ installed.module, manifest.version, why });
        fetched.destroy();
    }

    /// The person's answer to the offer `poll` reported: install it, or leave the plugin as it is
    /// and check the next one. Without an offer waiting, nothing.
    pub fn answer(self: *AutoUpdate, install: bool) void {
        const fetched = self.offered orelse return;
        self.offered = null;
        if (install) self.startInstall(fetched) else fetched.destroy();
    }

    fn startInstall(self: *AutoUpdate, fetched: *fetch_zig.Fetched) void {
        const package = fetched.package.fetch;
        log.info("updating {s} from {s} to {s}", .{ fetched.manifest.module, self.queue[self.next - 1].version, fetched.manifest.version });
        self.package_before = project_plugins.readPackageFile(self.gpa, self.project_dir) catch null;
        self.installing = install_zig.Install.start(self.gpa, .{ .project_dir = self.project_dir, .url = package.url, .dependency = package.dependency, .fingerprint = fetched.manifest.fingerprint }) catch |err| {
            log.warn("cannot update {s}: {t}", .{ fetched.manifest.module, err });
            fetched.destroy();
            if (self.package_before) |text| self.gpa.free(text);
            self.package_before = null;
            return;
        };
        self.newer = fetched;
    }

    fn pollInstall(self: *AutoUpdate, running: *install_zig.Install) Progress {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const status = running.status(scratch.allocator()) catch return .working;
        const outcome = status.outcome orelse return .working;
        running.destroy();
        self.installing = null;
        const fetched = self.newer.?;
        self.newer = null;
        defer fetched.destroy();
        const package_before = self.package_before;
        self.package_before = null;
        if (outcome == .failed) {
            log.warn("cannot update {s}: {s}", .{ fetched.manifest.module, outcome.failed });
            if (package_before) |text| self.gpa.free(text);
            return .working;
        }

        // Listed at its new version, with what `zig fetch --save` did to build.zig.zon: one step.
        var change = project_plugins.Change{ .project = project_plugins.rewrite(self.gpa, self.project_dir, fetched.manifest.module, project_plugins.entryFor(fetched, false)) catch |err| {
            log.err("{s} {s} is fetched, but eggy.zon couldn't list it: {t}", .{ fetched.manifest.module, fetched.manifest.version, err });
            if (package_before) |text| self.gpa.free(text);
            return .working;
        } };
        if (package_before) |before| change.package = project_plugins.packageChange(self.gpa, self.project_dir, before) catch null;
        _ = self.reported.reset(.retain_capacity);
        const a = self.reported.allocator();
        return .{ .updated = .{
            .change = change,
            .title = a.dupe(u8, fetched.manifest.title) catch "",
            .version = a.dupe(u8, fetched.manifest.version) catch "",
        } };
    }
};

test "only plugins fetched from somewhere, and not from a folder, are checked again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = eggy.project.file_name, .data =
        \\.{ .name = "game", .title = "Game", .plugins = .{
        \\    .{ .module = "eggy_git", .version = "0.1.0" },
        \\    .{ .module = "stats", .dependency = "stats", .version = "1.0.0" },
        \\    .{ .module = "mcp", .dependency = "eggy_mcp", .version = "0.1.0", .source = "https://raw.githubusercontent.com/me/mcp/main/eggy.zon" },
        \\    .{ .module = "wip", .dependency = "wip", .version = "0.1.0", .source = "https://raw.githubusercontent.com/me/wip/main/eggy.zon" },
        \\} }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data =
        \\.{ .name = .game, .dependencies = .{ .wip = .{ .path = "../wip" } } }
    });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(folder);
    const updates = try AutoUpdate.start(std.testing.allocator, folder);
    defer updates.destroy();
    try std.testing.expectEqual(@as(usize, 1), updates.queue.len);
    try std.testing.expectEqualStrings("mcp", updates.queue[0].module);
}
