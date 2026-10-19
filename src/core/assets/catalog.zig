//! The project's asset catalog: one hidden, editor-only file, `.eggy/assets.zon`, that gives every
//! file and folder of `resources/` a stable opaque id, its kind and how a model is imported.
//! Paths are only how the editor shows and finds things; everything else refers to the id, so
//! renames and moves keep references. The catalog replaces the `<name>.eggy` descriptor beside
//! each file (`descriptor.zig` is now only read, to carry those ids and settings over).
//!
//! `Snapshot` is an immutable, owned copy to read from (any thread, no I/O); `Catalog` is the
//! editor's mutable copy. Every change builds a whole new snapshot, writes it to disk atomically
//! and only then swaps it in, so a failed write leaves memory and disk as they were.
//!
//! The trash (`.eggy/trash/`) is catalogued too: deleting an asset is a move there, and undoing
//! it a move back, so the id survives.
//!
//!     .{
//!         .version = 1,
//!         .assets = .{
//!             .{ .id = 8410273145522034177, .path = "resources/ship.glb", .kind = .model, .model_import = .{ .scale = 0.01 } },
//!         },
//!     }
const std = @import("std");
const asset_id = @import("id.zig");
const Kind = @import("kind.zig").Kind;
const descriptor = @import("descriptor.zig");

pub const Id = asset_id.Id;
pub const ModelImport = descriptor.ModelImport;

/// Where the catalog lives, relative to the project.
pub const file_path = ".eggy/assets.zon";
/// The layout this build reads and writes; a file of another version is refused.
pub const format_version: u32 = 1;
pub const resources_prefix = "resources/";
pub const trash_prefix = ".eggy/trash/";

pub const Error = error{
    /// The file is not a catalog: it doesn't parse, or holds a zero id, a bad or repeated path.
    InvalidCatalog,
    UnsupportedVersion,
    /// Two assets share an id, or a model's own child id (`id.model`) is another asset's.
    AssetIdCollision,
    AssetIdsExhausted,
    /// The path to move, copy or remove isn't in the catalog.
    NotCatalogued,
    PathAlreadyExists,
    InvalidPath,
};

/// One catalogued file or folder.
pub const Entry = struct {
    id: Id,
    /// Relative to the project, `/` separated: under `resources/` or `.eggy/trash/`.
    path: []const u8,
    kind: Kind,
    /// How a model is imported; ignored for other kinds.
    model_import: ModelImport = .{},
};

const Disk = struct { version: u32, assets: []const Entry };

/// What a `sync` found and did.
pub const Changes = struct {
    /// Files and folders given an entry.
    made: usize = 0,
    /// Of those, how many took the id of a legacy `.eggy` descriptor.
    migrated: usize = 0,
    /// Entries dropped because their file has gone.
    removed: usize = 0,
    /// Legacy descriptor files deleted after the catalog was safely written.
    sidecars_removed: usize = 0,

    pub fn any(self: Changes) bool {
        return self.made + self.removed + self.sidecars_removed > 0;
    }
};

/// An immutable, owned view of the catalog, sorted by path.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    by_id: std.AutoHashMapUnmanaged(Id, u32),

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }

    /// The entry for `path`, if the catalog has one. Borrowed from the snapshot.
    pub fn findPath(self: *const Snapshot, path: []const u8) ?*const Entry {
        const at = std.sort.binarySearch(Entry, self.entries, path, comparePath) orelse return null;
        return &self.entries[at];
    }

    /// The entry with `id`, if the catalog has one. Borrowed from the snapshot.
    pub fn findId(self: *const Snapshot, id: Id) ?*const Entry {
        return &self.entries[self.by_id.get(id) orelse return null];
    }

    /// A copy owning its own memory, for another thread to read.
    pub fn clone(self: *const Snapshot, gpa: std.mem.Allocator) !Snapshot {
        return build(gpa, self.entries);
    }

    /// Read the catalog of `project` without changing anything. `error.FileNotFound` when it has
    /// none yet (`Catalog.sync` makes it); `error.InvalidCatalog`, `error.UnsupportedVersion` and
    /// `error.AssetIdCollision` for a file that can't be trusted.
    ///
    /// ```zig
    /// var snapshot = try Snapshot.read(gpa, io, project);
    /// defer snapshot.deinit();
    /// const entry = snapshot.findPath("resources/ship.glb");
    /// ```
    pub fn read(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir) !Snapshot {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const text = try project.readFileAllocOptions(io, file_path, scratch.allocator(), .limited(64 << 20), .of(u8), 0);
        return parse(gpa, scratch.allocator(), text);
    }

    /// A snapshot of `entries` (copied), checked: ids are nonzero and unique, paths valid and unique.
    pub fn build(gpa: std.mem.Allocator, entries: []const Entry) !Snapshot {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const sorted = try a.alloc(Entry, entries.len);
        for (sorted, entries) |*to, from| {
            if (from.id == 0 or !validPath(from.path)) return error.InvalidCatalog;
            to.* = from;
            to.path = try a.dupe(u8, from.path);
        }
        std.mem.sort(Entry, sorted, {}, lessThan);

        var by_id: std.AutoHashMapUnmanaged(Id, u32) = .empty;
        try by_id.ensureTotalCapacity(a, @intCast(sorted.len));
        for (sorted, 0..) |entry, at| {
            if (at > 0 and std.mem.eql(u8, sorted[at - 1].path, entry.path)) return error.InvalidCatalog;
            const slot = by_id.getOrPutAssumeCapacity(entry.id);
            if (slot.found_existing) return error.AssetIdCollision;
            slot.value_ptr.* = @intCast(at);
        }
        for (sorted) |entry| {
            if (entry.kind == .model and by_id.contains(asset_id.model(entry.id))) return error.AssetIdCollision;
        }
        return .{ .arena = arena, .entries = sorted, .by_id = by_id };
    }

    fn parse(gpa: std.mem.Allocator, scratch: std.mem.Allocator, text: [:0]const u8) !Snapshot {
        const disk = std.zon.parse.fromSliceAlloc(Disk, scratch, text, null, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => return error.InvalidCatalog,
        };
        if (disk.version != format_version) return error.UnsupportedVersion;
        return build(gpa, disk.assets);
    }
};

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn comparePath(path: []const u8, entry: Entry) std.math.Order {
    return std.mem.order(u8, path, entry.path);
}

/// Whether `path` can be catalogued: under `resources/` or the trash, `/` separated, no empty,
/// `.` or `..` parts, no backslash, colon or NUL.
pub fn validPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, resources_prefix) and !std.mem.startsWith(u8, path, trash_prefix)) return false;
    if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Whether `path` is `folder` or inside it.
pub fn isUnder(path: []const u8, folder: []const u8) bool {
    return std.mem.eql(u8, path, folder) or (path.len > folder.len and path[folder.len] == '/' and std.mem.startsWith(u8, path, folder));
}

/// The editor's mutable catalog of one project.
pub const Catalog = struct {
    gpa: std.mem.Allocator,
    current: Snapshot,

    /// Load `project`'s catalog; one that doesn't exist yet is empty (run `sync` to fill it).
    /// An unreadable or untrustworthy file is an error, never silently replaced.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir) !Catalog {
        const current = Snapshot.read(gpa, io, project) catch |err| switch (err) {
            error.FileNotFound => try Snapshot.build(gpa, &.{}),
            else => return err,
        };
        return .{ .gpa = gpa, .current = current };
    }

    pub fn deinit(self: *Catalog) void {
        self.current.deinit();
    }

    /// The catalog as it is now, borrowed until the next change.
    pub fn view(self: *const Catalog) *const Snapshot {
        return &self.current;
    }

    /// Make the catalog match the files of `resources/`: give new files and folders an entry
    /// (carrying the id and import settings of a legacy `<name>.eggy` descriptor, else a fresh
    /// random id), drop entries whose file has gone, then delete the legacy descriptors, only
    /// after the catalog is on disk. Hidden files are not catalogued.
    /// A legacy id already taken gets a fresh one (the file was copied) and a warning.
    /// Nothing changes if writing fails.
    ///
    /// ```zig
    /// const changes = try catalog.sync(io, project);
    /// ```
    pub fn sync(self: *Catalog, io: std.Io, project: std.Io.Dir) !Changes {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        // Every file and folder of `resources/`, and the legacy descriptors among them.
        var found: std.StringArrayHashMapUnmanaged(bool) = .empty;
        var sidecars: std.ArrayList([]const u8) = .empty;
        try listResources(a, io, project, &found, &sidecars);
        std.mem.sort([]const u8, found.keys(), {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        found.reIndex(a) catch return error.OutOfMemory;

        var changes: Changes = .{};
        var next: std.ArrayList(Entry) = .empty;
        var used: std.AutoHashMapUnmanaged(Id, void) = .empty;
        var altered = false;

        // What the catalog already knows stays, with its kind brought up to date.
        for (self.current.entries) |entry| {
            if (std.mem.startsWith(u8, entry.path, trash_prefix)) {
                project.access(io, entry.path, .{}) catch {
                    changes.removed += 1;
                    continue;
                };
                try next.append(a, entry);
            } else if (found.get(entry.path)) |directory| {
                var kept = entry;
                kept.kind = if (directory) .folder else Kind.of(entry.path);
                altered = altered or kept.kind != entry.kind;
                try next.append(a, kept);
            } else {
                changes.removed += 1;
                continue;
            }
            try used.put(a, entry.id, {});
        }

        // What it doesn't: legacy ids and settings where there are any, else new ids.
        var paths = found.iterator();
        while (paths.next()) |item| {
            if (self.current.findPath(item.key_ptr.*) != null) continue;
            const legacy = readLegacy(a, io, project, item.key_ptr.*);
            var made: Entry = .{ .id = 0, .path = item.key_ptr.*, .kind = if (item.value_ptr.*) .folder else Kind.of(item.key_ptr.*) };
            if (legacy) |old| {
                made.model_import = old.model;
                if (old.id != 0 and !used.contains(old.id)) {
                    made.id = old.id;
                    changes.migrated += 1;
                } else std.log.warn("{s}: its legacy asset id {d} is taken; it gets a new one", .{ item.key_ptr.*, old.id });
            }
            if (made.id == 0) made.id = try freshId(io, &used);
            try used.put(a, made.id, {});
            try next.append(a, made);
            changes.made += 1;
        }

        if (changes.made + changes.removed > 0 or altered) {
            var built = try Snapshot.build(self.gpa, next.items);
            errdefer built.deinit();
            try self.commit(io, project, &built);
        }

        // The legacy descriptors have done their job: the catalog is durable.
        for (sidecars.items) |path| {
            project.deleteFile(io, path) catch |err| {
                std.log.warn("cannot remove the legacy descriptor {s}: {t}", .{ path, err });
                continue;
            };
            changes.sidecars_removed += 1;
        }
        return changes;
    }

    /// Record that `from` (a file or a folder with everything in it) now lives at `to`: the ids
    /// stay. Call it after the files moved. `error.NotCatalogued` without `from`,
    /// `error.PathAlreadyExists` if `to` is taken, `error.InvalidPath` for a `to` inside `from`.
    pub fn move(self: *Catalog, io: std.Io, project: std.Io.Dir, from: []const u8, to: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const next = try self.rewritten(scratch.allocator(), from, to, .keep);
        var built = try Snapshot.build(self.gpa, next);
        errdefer built.deinit();
        try self.commit(io, project, &built);
    }

    /// Record that `from` was copied to `to`: every copy gets a new id (a copy is a different
    /// asset). Same errors as `move`.
    pub fn copy(self: *Catalog, io: std.Io, project: std.Io.Dir, from: []const u8, to: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var used: std.AutoHashMapUnmanaged(Id, void) = .empty;
        for (self.current.entries) |entry| try used.put(a, entry.id, {});
        const next = try self.rewritten(a, from, to, .{ .fresh = .{ .io = io, .used = &used } });
        var built = try Snapshot.build(self.gpa, next);
        errdefer built.deinit();
        try self.commit(io, project, &built);
    }

    /// Forget `path` and everything inside it, after its files were erased (a deletion the
    /// editor can undo is a `move` into the trash instead). `error.NotCatalogued` without it.
    pub fn remove(self: *Catalog, io: std.Io, project: std.Io.Dir, path: []const u8) !void {
        if (self.current.findPath(path) == null) return error.NotCatalogued;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        var next: std.ArrayList(Entry) = .empty;
        for (self.current.entries) |entry| if (!isUnder(entry.path, path)) try next.append(scratch.allocator(), entry);
        var built = try Snapshot.build(self.gpa, next.items);
        errdefer built.deinit();
        try self.commit(io, project, &built);
    }

    /// Change how the model at `path` is imported. `error.NotCatalogued` if it isn't a model.
    pub fn setModelImport(self: *Catalog, io: std.Io, project: std.Io.Dir, path: []const u8, settings: ModelImport) !void {
        const at = self.current.findPath(path) orelse return error.NotCatalogued;
        if (at.kind != .model) return error.NotCatalogued;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const next = try scratch.allocator().dupe(Entry, self.current.entries);
        for (next) |*entry| if (std.mem.eql(u8, entry.path, path)) {
            entry.model_import = settings;
        };
        var built = try Snapshot.build(self.gpa, next);
        errdefer built.deinit();
        try self.commit(io, project, &built);
    }

    const Ids = union(enum) {
        keep,
        fresh: struct { io: std.Io, used: *std.AutoHashMapUnmanaged(Id, void) },
    };

    /// The entries with `from` and what is inside it at `to` instead, copied when `ids` is
    /// `fresh` (the originals stay, the copies get new ids).
    fn rewritten(self: *const Catalog, a: std.mem.Allocator, from: []const u8, to: []const u8, ids: Ids) ![]const Entry {
        if (!validPath(to)) return error.InvalidPath;
        if (self.current.findPath(from) == null) return error.NotCatalogued;
        if (isUnder(to, from)) return error.InvalidPath;
        for (self.current.entries) |entry| if (isUnder(entry.path, to)) return error.PathAlreadyExists;

        var next: std.ArrayList(Entry) = .empty;
        for (self.current.entries) |entry| {
            if (!isUnder(entry.path, from)) {
                try next.append(a, entry);
                continue;
            }
            var moved = entry;
            moved.path = try std.mem.concat(a, u8, &.{ to, entry.path[from.len..] });
            switch (ids) {
                .keep => {},
                .fresh => |fresh| {
                    moved.id = try freshId(fresh.io, fresh.used);
                    try fresh.used.put(a, moved.id, {});
                    try next.append(a, entry);
                },
            }
            try next.append(a, moved);
        }
        return next.items;
    }

    /// Write `built` to disk, then make it the catalog (it is taken over; the old one freed).
    fn commit(self: *Catalog, io: std.Io, project: std.Io.Dir, built: *Snapshot) !void {
        try write(self.gpa, io, project, built.entries);
        self.current.deinit();
        self.current = built.*;
    }
};

/// A random id unused so far, not zero and not a model child of another asset.
fn freshId(io: std.Io, used: *const std.AutoHashMapUnmanaged(Id, void)) !Id {
    for (0..64) |_| {
        var id: Id = 0;
        io.random(std.mem.asBytes(&id));
        if (id == 0 or used.contains(id) or used.contains(asset_id.model(id))) continue;
        return id;
    }
    return error.AssetIdsExhausted;
}

fn readLegacy(a: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8) ?descriptor.Descriptor {
    return descriptor.read(a, io, project, path) catch |err| {
        std.log.warn("{s}: its legacy descriptor doesn't read ({t}); it gets a new id", .{ path, err });
        return null;
    };
}

/// The files and folders of `resources/` (project-relative, with whether each is a folder) and
/// the legacy descriptors among them, in `a`. Hidden entries are left out.
fn listResources(a: std.mem.Allocator, io: std.Io, project: std.Io.Dir, found: *std.StringArrayHashMapUnmanaged(bool), sidecars: *std.ArrayList([]const u8)) !void {
    var resources = project.openDir(io, "resources", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer resources.close(io);
    var walker = try resources.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (hidden(entry.path)) continue;
        const path = try std.mem.concat(a, u8, &.{ resources_prefix, entry.path });
        if (entry.kind == .file and descriptor.isDescriptor(path)) {
            try sidecars.append(a, path);
        } else try found.put(a, path, entry.kind == .directory);
    }
}

fn hidden(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len > 0 and part[0] == '.') return true;
    return false;
}

/// Write the catalog file atomically: a sibling is written, flushed and synced, then renamed over.
fn write(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, entries: []const Entry) !void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try std.zon.stringify.serialize(Disk{ .version = format_version, .assets = entries }, .{}, &text.writer);
    try text.writer.writeByte('\n');
    try project.createDirPath(io, ".eggy");
    var atomic = try project.createFileAtomic(io, file_path, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(text.written()) catch return writer.err.?;
    writer.interface.flush() catch return writer.err.?;
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn expectFile(project: std.Io.Dir, io: std.Io, path: []const u8, exists: bool) !void {
    project.access(io, path, .{}) catch return try std.testing.expect(!exists);
    try std.testing.expect(exists);
}

test "sync catalogues files and folders once, with stable ids, and drops what is gone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, "resources/models");
    try project.writeFile(io, .{ .sub_path = "resources/models/ship.glb", .data = "x" });
    try project.writeFile(io, .{ .sub_path = "resources/.hidden", .data = "x" });

    var catalog = try Catalog.open(gpa, io, project);
    defer catalog.deinit();
    const first = try catalog.sync(io, project);
    try std.testing.expectEqual(@as(usize, 2), first.made);
    const ship = catalog.view().findPath("resources/models/ship.glb").?.*;
    try std.testing.expectEqual(Kind.model, ship.kind);
    try std.testing.expectEqual(Kind.folder, catalog.view().findPath("resources/models").?.kind);
    try std.testing.expect(catalog.view().findPath("resources/.hidden") == null);
    try std.testing.expectEqual(ship.path, catalog.view().findId(ship.id).?.path);

    // Nothing to do the second time, and a reopened catalog reads what was written.
    try std.testing.expect(!(try catalog.sync(io, project)).any());
    var again = try Catalog.open(gpa, io, project);
    defer again.deinit();
    try std.testing.expectEqual(ship.id, again.view().findPath("resources/models/ship.glb").?.id);

    try project.deleteFile(io, "resources/models/ship.glb");
    try std.testing.expectEqual(@as(usize, 1), (try catalog.sync(io, project)).removed);
    try std.testing.expect(catalog.view().findId(ship.id) == null);
}

test "legacy descriptors lend their ids and settings, and go only once the catalog is written" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, "resources");
    try project.writeFile(io, .{ .sub_path = "resources/ship.glb", .data = "x" });
    try project.writeFile(io, .{ .sub_path = "resources/ship.glb.eggy", .data = ".{ .id = 77, .kind = .model, .model = .{ .scale = 0.01 } }" });
    // A copy made outside the editor, descriptor and all: its id is taken.
    try project.writeFile(io, .{ .sub_path = "resources/ship2.glb", .data = "x" });
    try project.writeFile(io, .{ .sub_path = "resources/ship2.glb.eggy", .data = ".{ .id = 77, .kind = .model }" });
    try project.writeFile(io, .{ .sub_path = "resources/orphan.png.eggy", .data = ".{ .id = 5, .kind = .image }" });

    var catalog = try Catalog.open(gpa, io, project);
    defer catalog.deinit();
    const changes = try catalog.sync(io, project);
    try std.testing.expectEqual(Changes{ .made = 2, .migrated = 1, .removed = 0, .sidecars_removed = 3 }, changes);
    const ship = catalog.view().findPath("resources/ship.glb").?;
    try std.testing.expectEqual(@as(Id, 77), ship.id);
    try std.testing.expectEqual(@as(f32, 0.01), ship.model_import.scale);
    try std.testing.expect(catalog.view().findPath("resources/ship2.glb").?.id != 77);
    try expectFile(project, io, "resources/ship.glb.eggy", false);
    try expectFile(project, io, ".eggy/assets.zon", true);
}

test "moves keep ids, copies get new ones, and the trash round trip returns the same id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, "resources/art");
    try project.writeFile(io, .{ .sub_path = "resources/art/a.png", .data = "x" });
    var catalog = try Catalog.open(gpa, io, project);
    defer catalog.deinit();
    _ = try catalog.sync(io, project);
    const id = catalog.view().findPath("resources/art/a.png").?.id;
    const folder = catalog.view().findPath("resources/art").?.id;

    try project.rename("resources/art", project, "resources/pictures", io);
    try catalog.move(io, project, "resources/art", "resources/pictures");
    try std.testing.expectEqual(id, catalog.view().findPath("resources/pictures/a.png").?.id);
    try std.testing.expectEqual(folder, catalog.view().findPath("resources/pictures").?.id);
    try std.testing.expect(catalog.view().findPath("resources/art/a.png") == null);

    try project.createDirPath(io, "resources/more");
    try project.writeFile(io, .{ .sub_path = "resources/more/a.png", .data = "x" });
    try catalog.copy(io, project, "resources/pictures", "resources/more");
    try std.testing.expect(catalog.view().findPath("resources/more/a.png").?.id != id);
    try std.testing.expectEqual(id, catalog.view().findPath("resources/pictures/a.png").?.id);
    try std.testing.expectError(error.PathAlreadyExists, catalog.copy(io, project, "resources/pictures", "resources/more"));
    try std.testing.expectError(error.InvalidPath, catalog.move(io, project, "resources/pictures", "resources/pictures/inner"));
    try std.testing.expectError(error.NotCatalogued, catalog.move(io, project, "resources/none", "resources/x"));

    // Deleting is a move into the trash; undoing it is a move back.
    try project.createDirPath(io, ".eggy/trash/1");
    try project.rename("resources/pictures/a.png", project, ".eggy/trash/1/a.png", io);
    try catalog.move(io, project, "resources/pictures/a.png", ".eggy/trash/1/a.png");
    try std.testing.expectEqual(id, catalog.view().findPath(".eggy/trash/1/a.png").?.id);
    _ = try catalog.sync(io, project);
    try std.testing.expect(catalog.view().findPath(".eggy/trash/1/a.png") != null);
    try project.rename(".eggy/trash/1/a.png", project, "resources/pictures/a.png", io);
    try catalog.move(io, project, ".eggy/trash/1/a.png", "resources/pictures/a.png");
    try std.testing.expectEqual(id, catalog.view().findPath("resources/pictures/a.png").?.id);

    try catalog.remove(io, project, "resources/more");
    try std.testing.expect(catalog.view().findPath("resources/more/a.png") == null);
    try std.testing.expectError(error.NotCatalogued, catalog.setModelImport(io, project, "resources/pictures/a.png", .{ .scale = 2 }));
}

test "an untrustworthy catalog file is refused, not replaced" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, ".eggy");
    const bad = [_]struct { []const u8, anyerror }{
        .{ "garbage", error.InvalidCatalog },
        .{ ".{ .version = 2, .assets = .{} }", error.UnsupportedVersion },
        .{ ".{ .version = 1, .assets = .{ .{ .id = 0, .path = \"resources/a\", .kind = .any } } }", error.InvalidCatalog },
        .{ ".{ .version = 1, .assets = .{ .{ .id = 3, .path = \"../a\", .kind = .any } } }", error.InvalidCatalog },
        .{ ".{ .version = 1, .assets = .{ .{ .id = 3, .path = \"resources/a\", .kind = .any }, .{ .id = 3, .path = \"resources/b\", .kind = .any } } }", error.AssetIdCollision },
    };
    for (bad) |case| {
        try project.writeFile(io, .{ .sub_path = file_path, .data = case[0] });
        try std.testing.expectError(case[1], Catalog.open(gpa, io, project));
    }
    // A model whose child id is another asset's is a collision too.
    const clash = try std.fmt.allocPrint(gpa, ".{{ .version = 1, .assets = .{{ .{{ .id = 3, .path = \"resources/a.glb\", .kind = .model }}, .{{ .id = {d}, .path = \"resources/b\", .kind = .any }} }} }}", .{asset_id.model(3)});
    defer gpa.free(clash);
    try project.writeFile(io, .{ .sub_path = file_path, .data = clash });
    try std.testing.expectError(error.AssetIdCollision, Catalog.open(gpa, io, project));
}
