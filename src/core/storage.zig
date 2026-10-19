//! Versioned game-save slots in project-specific writable user data, never resources or preferences.
const std = @import("std");
const builtin = @import("builtin");
const format = @import("storage_format.zig");
const browser = @import("storage_browser.zig");

pub const support: @import("support.zig").Support = .available;
pub const max_save_bytes = format.max_payload_bytes;
pub const max_slot_bytes = 64;
const file_name_bytes = 73;

pub const Error = error{
    StorageNotInitialized,
    UnsupportedPlatform,
    InvalidProjectId,
    InvalidSlot,
    FileNotFound,
    CorruptSave,
    UnsupportedSaveFormat,
    UnsupportedSaveSchema,
    SaveTooLarge,
    OutOfMemory,
    AccessDenied,
    StorageFull,
    StorageIo,
};

/// Stable C-boundary results; Zig error numbers differ between host and game compilations.
pub const Status = enum(u32) {
    ok = 0,
    not_found = 1,
    corrupt = 2,
    unsupported_format = 3,
    unsupported_schema = 4,
    too_large = 5,
    out_of_memory = 6,
    access_denied = 7,
    full = 8,
    io = 9,
    unsupported_platform = 10,
};
const Bytes = extern struct { ptr: [*]u8, len: usize };
const Provider = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, *const anyopaque, [*]const u8, usize, u32, *Bytes) callconv(.c) Status,
    write: *const fn (*anyopaque, [*]const u8, usize, u32, [*]const u8, usize) callconv(.c) Status,
    remove: *const fn (*anyopaque, [*]const u8, usize) callconv(.c) Status,
    destroy: *const fn (*anyopaque) callconv(.c) void,
};

/// A movable host-owned service. Copies borrow its heap-stable provider until host deinit.
/// Calls are synchronous; serialize access on the host/game thread and do not retain across App shutdown.
pub const Storage = struct {
    provider: ?Provider = null,

    /// Open this project's save namespace before plugin initialization. `project_id` must be
    /// nonempty and stable (normally the generated project name, identical in editor/runtime).
    /// Owns a heap context, not an App pointer; `gpa` and `io` must outlive `deinit`.
    /// Desktop/Android use SDL's writable user-data path; browsers use localStorage, not MEMFS.
    /// Unsupported/denied persistence and setup failures propagate, without a memory-only fallback.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, project_id: []const u8) Error!Storage {
        if (project_id.len == 0) return error.InvalidProjectId;
        const namespace = identityHash(project_id);
        if (comptime builtin.os.tag == .emscripten) {
            try browser.checkAvailable();
            const context = try gpa.create(Context);
            context.* = .{ .gpa = gpa, .io = io, .backend = .{ .browser = namespace } };
            return context.interface();
        } else {
            const sdl3 = @import("vitellus_sdl3").sdl;
            const pref = sdl3.filesystem.getPrefPath("eggy", "games") catch return error.StorageIo;
            defer sdl3.free(pref);
            const path = try std.fs.path.join(gpa, &.{ pref, &namespace, "saves" });
            defer gpa.free(path);
            const dir = std.Io.Dir.cwd().createDirPathOpen(io, path, .{}) catch |err| return mappedError(err);
            return fromDirectory(gpa, io, dir);
        }
    }

    /// Host-only: destroy once, after plugin/world shutdown and before SDL/Io shutdown.
    /// Clears this value; all previously copied views become invalid.
    pub fn deinit(self: *Storage) void {
        if (self.provider) |provider| provider.destroy(provider.context);
        self.* = .{};
    }

    /// Read schema 1 into caller-owned bytes; free with `gpa.free`, including empty saves.
    /// Missing slots, invalid names, unsupported versions, corruption and I/O failures are errors.
    pub fn read(self: Storage, gpa: std.mem.Allocator, slot: []const u8) Error![]u8 {
        return self.readVersion(gpa, slot, 1);
    }

    /// Atomically replace schema 1 data. Borrows `bytes` only for this call.
    /// A failed pre-commit write leaves the previous save intact; no silent fallback is used.
    pub fn write(self: Storage, slot: []const u8, bytes: []const u8) Error!void {
        return self.writeVersion(slot, 1, bytes);
    }

    /// Read only the requested game schema. Eggy's envelope version is checked separately.
    /// No automatic migrations/defaults: handle `UnsupportedSaveSchema` explicitly.
    pub fn readVersion(self: Storage, gpa: std.mem.Allocator, slot: []const u8, schema: u32) Error![]u8 {
        try validateSlot(slot);
        const provider = self.provider orelse return error.StorageNotInitialized;
        var bytes: Bytes = undefined;
        try check(provider.read(provider.context, &gpa, slot.ptr, slot.len, schema, &bytes));
        return bytes.ptr[0..bytes.len];
    }

    /// Atomically replace a slot with a versioned payload of at most `max_save_bytes`.
    /// Desktop flushes and syncs a sibling file before rename; browsers atomically set one
    /// localStorage key. Success does not guarantee survival of power loss or browser eviction.
    pub fn writeVersion(self: Storage, slot: []const u8, schema: u32, bytes: []const u8) Error!void {
        try validateSlot(slot);
        if (bytes.len > max_save_bytes) return error.SaveTooLarge;
        const provider = self.provider orelse return error.StorageNotInitialized;
        try check(provider.write(provider.context, slot.ptr, slot.len, schema, bytes.ptr, bytes.len));
    }

    /// Delete one slot; a missing slot returns `FileNotFound`, not a successful no-op.
    /// Never interprets a slot as a filesystem path or removes other project data.
    pub fn remove(self: Storage, slot: []const u8) Error!void {
        try validateSlot(slot);
        const provider = self.provider orelse return error.StorageNotInitialized;
        try check(provider.remove(provider.context, slot.ptr, slot.len));
    }
};

fn validateSlot(slot: []const u8) error{InvalidSlot}!void {
    if (slot.len == 0 or slot.len > max_slot_bytes) return error.InvalidSlot;
    for (slot) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidSlot;
    }
}

fn identityHash(identity: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identity, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// Transfers directory ownership even when context allocation fails.
fn fromDirectory(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) Error!Storage {
    errdefer dir.close(io);
    const context = try gpa.create(Context);
    context.* = .{ .gpa = gpa, .io = io, .backend = .{ .directory = dir } };
    return context.interface();
}

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: union(enum) { directory: std.Io.Dir, browser: [64]u8 },

    fn interface(self: *Context) Storage {
        return .{ .provider = .{
            .context = self,
            .read = readBridge,
            .write = writeBridge,
            .remove = removeBridge,
            .destroy = destroyBridge,
        } };
    }

    fn read(self: *Context, gpa: std.mem.Allocator, slot: []const u8, schema: u32) ![]u8 {
        var name_buffer: [file_name_bytes]u8 = undefined;
        const encoded = switch (self.backend) {
            .directory => |dir| try dir.readFileAlloc(self.io, slotFileName(&name_buffer, slot), gpa, .limited(format.header_bytes + max_save_bytes)),
            .browser => |namespace| try browser.read(gpa, &namespace, slot),
        };
        defer gpa.free(encoded);
        return gpa.dupe(u8, try format.payload(encoded, schema));
    }

    fn write(self: *Context, slot: []const u8, schema: u32, bytes: []const u8) !void {
        const header = format.header(bytes, schema);
        switch (self.backend) {
            .directory => |dir| {
                var name_buffer: [file_name_bytes]u8 = undefined;
                var atomic = try dir.createFileAtomic(self.io, slotFileName(&name_buffer, slot), .{ .replace = true });
                defer atomic.deinit(self.io);
                var buffer: [4096]u8 = undefined;
                var writer = atomic.file.writer(self.io, &buffer);
                writer.interface.writeAll(&header) catch return writer.err.?;
                writer.interface.writeAll(bytes) catch return writer.err.?;
                writer.interface.flush() catch return writer.err.?;
                try atomic.file.sync(self.io);
                try atomic.replace(self.io);
            },
            .browser => |namespace| {
                const encoded = try self.gpa.alloc(u8, header.len + bytes.len);
                defer self.gpa.free(encoded);
                @memcpy(encoded[0..header.len], &header);
                @memcpy(encoded[header.len..], bytes);
                try browser.write(&namespace, slot, encoded);
            },
        }
    }

    fn readBridge(raw: *anyopaque, allocator: *const anyopaque, slot: [*]const u8, len: usize, schema: u32, out: *Bytes) callconv(.c) Status {
        const self: *Context = @ptrCast(@alignCast(raw));
        const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(allocator));
        const bytes = self.read(gpa.*, slot[0..len], schema) catch |err| return status(err);
        out.* = .{ .ptr = bytes.ptr, .len = bytes.len };
        return .ok;
    }

    fn writeBridge(raw: *anyopaque, slot: [*]const u8, len: usize, schema: u32, bytes: [*]const u8, bytes_len: usize) callconv(.c) Status {
        const self: *Context = @ptrCast(@alignCast(raw));
        self.write(slot[0..len], schema, bytes[0..bytes_len]) catch |err| return status(err);
        return .ok;
    }

    fn removeBridge(raw: *anyopaque, slot: [*]const u8, len: usize) callconv(.c) Status {
        const self: *Context = @ptrCast(@alignCast(raw));
        switch (self.backend) {
            .directory => |dir| {
                var name_buffer: [file_name_bytes]u8 = undefined;
                dir.deleteFile(self.io, slotFileName(&name_buffer, slot[0..len])) catch |err| return status(err);
            },
            .browser => |namespace| browser.remove(&namespace, slot[0..len]) catch |err| return status(err),
        }
        return .ok;
    }

    fn destroyBridge(raw: *anyopaque) callconv(.c) void {
        const self: *Context = @ptrCast(@alignCast(raw));
        switch (self.backend) {
            .directory => |dir| dir.close(self.io),
            .browser => {},
        }
        self.gpa.destroy(self);
    }
};

fn slotFileName(buffer: *[file_name_bytes]u8, slot: []const u8) []const u8 {
    // Lowercase hashes preserve case-sensitive slot identity on every filesystem.
    return std.fmt.bufPrint(buffer, "slot-{s}.sav", .{identityHash(slot)}) catch unreachable;
}

fn status(err: anyerror) Status {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.CorruptSave => .corrupt,
        error.UnsupportedSaveFormat => .unsupported_format,
        error.UnsupportedSaveSchema => .unsupported_schema,
        error.SaveTooLarge, error.StreamTooLong, error.FileTooBig => .too_large,
        error.OutOfMemory => .out_of_memory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => .access_denied,
        error.StorageFull, error.NoSpaceLeft, error.DiskQuota => .full,
        error.UnsupportedPlatform => .unsupported_platform,
        else => .io,
    };
}

fn check(result: Status) Error!void {
    return switch (result) {
        .ok => {},
        .not_found => error.FileNotFound,
        .corrupt => error.CorruptSave,
        .unsupported_format => error.UnsupportedSaveFormat,
        .unsupported_schema => error.UnsupportedSaveSchema,
        .too_large => error.SaveTooLarge,
        .out_of_memory => error.OutOfMemory,
        .access_denied => error.AccessDenied,
        .full => error.StorageFull,
        .io => error.StorageIo,
        .unsupported_platform => error.UnsupportedPlatform,
    };
}

fn mappedError(err: anyerror) Error {
    check(status(err)) catch |mapped| return mapped;
    unreachable;
}

fn testStorage(gpa: std.mem.Allocator, dir: std.Io.Dir) !Storage {
    return fromDirectory(gpa, std.testing.io, try dir.openDir(std.testing.io, ".", .{}));
}

test "save slots roundtrip binary and empty bytes, overwrite atomically, and delete" {
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    var storage = try testStorage(std.testing.allocator, folder.dir);
    defer storage.deinit();
    try std.testing.expectError(error.FileNotFound, storage.read(std.testing.allocator, "missing"));
    try std.testing.expectError(error.FileNotFound, storage.remove("missing"));
    try storage.write("slot-1", "\x00first\xff");
    const first = try storage.read(std.testing.allocator, "slot-1");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("\x00first\xff", first);
    try storage.write("slot-1", "replacement");
    const replaced = try storage.read(std.testing.allocator, "slot-1");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("replacement", replaced);
    try std.testing.expectEqualStrings("\x00first\xff", first);

    var iterator = folder.dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        var name_buffer: [file_name_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(slotFileName(&name_buffer, "slot-1"), entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try storage.write("empty", "");
    const empty = try storage.read(std.testing.allocator, "empty");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try storage.remove("slot-1");
    try std.testing.expectError(error.FileNotFound, storage.read(std.testing.allocator, "slot-1"));
}

test "invalid slots fail before provider access or allocation" {
    const storage: Storage = .{};
    for ([_][]const u8{ "", ".", "..", "../save", "/save", "a/b", "a\\b", "C:save", "name.ext", "a b", "bad\x00name", "sävé", &("a".* ** 65) }) |slot| {
        try std.testing.expectError(error.InvalidSlot, storage.read(std.testing.failing_allocator, slot));
        try std.testing.expectError(error.InvalidSlot, storage.write(slot, "bytes"));
        try std.testing.expectError(error.InvalidSlot, storage.remove(slot));
    }
    try std.testing.expectError(error.StorageNotInitialized, storage.read(std.testing.allocator, "slot"));
    try std.testing.expectError(error.StorageNotInitialized, storage.write("slot", "bytes"));
    try std.testing.expectError(error.StorageNotInitialized, storage.remove("slot"));
    try std.testing.expectError(error.InvalidProjectId, Storage.init(std.testing.failing_allocator, std.testing.io, ""));
}

test "save reads distinguish unsupported schema, format, corruption and IO errors" {
    var folder = std.testing.tmpDir(.{});
    defer folder.cleanup();
    var storage = try testStorage(std.testing.allocator, folder.dir);
    defer storage.deinit();
    try storage.writeVersion("slot", 7, "progress");
    try std.testing.expectError(error.UnsupportedSaveSchema, storage.read(std.testing.allocator, "slot"));
    const bytes = try storage.readVersion(std.testing.allocator, "slot", 7);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("progress", bytes);

    var name_buffer: [file_name_bytes]u8 = undefined;
    const name = slotFileName(&name_buffer, "slot");
    var encoded = try folder.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(encoded);
    encoded[8] = 2;
    try folder.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = encoded });
    try std.testing.expectError(error.UnsupportedSaveFormat, storage.read(std.testing.allocator, "slot"));
    encoded[8] = 1;
    encoded[encoded.len - 1] ^= 1;
    try folder.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = encoded });
    try std.testing.expectError(error.CorruptSave, storage.readVersion(std.testing.allocator, "slot", 7));
    try folder.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "broken" });
    try std.testing.expectError(error.CorruptSave, storage.read(std.testing.allocator, "slot"));
    try folder.dir.createDir(std.testing.io, slotFileName(&name_buffer, "directory"), .default_dir);
    try std.testing.expectError(error.StorageIo, storage.read(std.testing.allocator, "directory"));
    try std.testing.expectError(error.StorageIo, storage.remove("directory"));
}

test "failed atomic replacement preserves destination and cleans scratch files" {
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    var storage = try testStorage(std.testing.allocator, folder.dir);
    defer storage.deinit();
    var name_buffer: [file_name_bytes]u8 = undefined;
    const name = slotFileName(&name_buffer, "blocked");
    try folder.dir.createDir(std.testing.io, name, .default_dir);
    var path_buffer: [file_name_bytes + 10]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/untouched", .{name});
    try folder.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "previous" });
    try std.testing.expectError(error.StorageIo, storage.write("blocked", "replacement"));
    const untouched = try folder.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(untouched);
    try std.testing.expectEqualStrings("previous", untouched);
    var iterator = folder.dir.iterate();
    const entry = (try iterator.next(std.testing.io)).?;
    try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expectEqual(null, try iterator.next(std.testing.io));
}

test "project namespaces and portable slot filenames cannot traverse" {
    const a = identityHash("my game");
    const b = identityHash("other game");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expectEqualStrings(&a, &identityHash("my game"));
    try std.testing.expectEqual(@as(usize, 64), identityHash("../../escape").len);
    var name_buffer: [file_name_bytes]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, slotFileName(&name_buffer, "CON"), "slot-"));
    try validateSlot(&("a".* ** 64));
}

test "all storage allocations release on failure and reads remain caller owned" {
    var folder = std.testing.tmpDir(.{});
    defer folder.cleanup();
    var storage = try testStorage(std.testing.allocator, folder.dir);
    defer storage.deinit();
    try storage.write("slot", "owned data");
    const ReadCase = struct {
        fn run(gpa: std.mem.Allocator, view: Storage) !void {
            const bytes = try view.read(gpa, "slot");
            defer gpa.free(bytes);
            try std.testing.expectEqualStrings("owned data", bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ReadCase.run, .{storage});
    const InitCase = struct {
        fn run(gpa: std.mem.Allocator, dir: std.Io.Dir) !void {
            var owner = try testStorage(gpa, dir);
            defer owner.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, InitCase.run, .{folder.dir});
}

test "slots persist across service shutdown and case-distinct names do not alias" {
    var folder = std.testing.tmpDir(.{});
    defer folder.cleanup();
    {
        var storage = try testStorage(std.testing.allocator, folder.dir);
        defer storage.deinit();
        try storage.write("slot", "lowercase");
        try storage.write("SLOT", "uppercase");
    }
    var reopened = try testStorage(std.testing.allocator, folder.dir);
    defer reopened.deinit();
    const lower = try reopened.read(std.testing.allocator, "slot");
    defer std.testing.allocator.free(lower);
    const upper = try reopened.read(std.testing.allocator, "SLOT");
    defer std.testing.allocator.free(upper);
    try std.testing.expectEqualStrings("lowercase", lower);
    try std.testing.expectEqualStrings("uppercase", upper);
}

test "failed writes, syncs and renames preserve the previous valid save" {
    const Fail = struct {
        fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
            return error.NoSpaceLeft;
        }
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
        fn rename(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
            return error.AccessDenied;
        }
    };
    var folder = std.testing.tmpDir(.{ .iterate = true });
    defer folder.cleanup();
    var storage = try testStorage(std.testing.allocator, folder.dir);
    defer storage.deinit();
    try storage.write("slot", "last good save");
    const context: *Context = @ptrCast(@alignCast(storage.provider.?.context));
    defer context.io = std.testing.io;
    for ([_]enum { write, sync, rename }{ .write, .sync, .rename }) |phase| {
        var vtable = std.testing.io.vtable.*;
        const expected = switch (phase) {
            .write => blk: {
                vtable.fileWritePositional = Fail.write;
                break :blk error.StorageFull;
            },
            .sync => blk: {
                vtable.fileSync = Fail.sync;
                break :blk error.StorageIo;
            },
            .rename => blk: {
                vtable.dirRename = Fail.rename;
                break :blk error.AccessDenied;
            },
        };
        context.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        try std.testing.expectError(expected, storage.write("slot", "replacement"));
        context.io = std.testing.io;
        const bytes = try storage.read(std.testing.allocator, "slot");
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("last good save", bytes);
        var iterator = folder.dir.iterate();
        _ = (try iterator.next(std.testing.io)).?;
        try std.testing.expectEqual(null, try iterator.next(std.testing.io));
    }
}

test "stable storage statuses reconstruct errors without Zig error numbers" {
    inline for (std.meta.fields(Status)) |field| {
        const code: Status = @enumFromInt(field.value);
        if (code == .ok) continue;
        check(code) catch |err| try std.testing.expectEqual(code, status(err));
    }
    try std.testing.expectEqual(Status.access_denied, status(error.PermissionDenied));
    try std.testing.expectEqual(Status.full, status(error.NoSpaceLeft));
    try std.testing.expectEqual(Status.io, status(error.InputOutput));
}

test {
    _ = format;
}
