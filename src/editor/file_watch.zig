//! Which files under a folder changed, as the OS reports them (inotify on Linux,
//! `ReadDirectoryChangesW` on Windows, FSEvents on macOS), so the editor picks up edits made
//! outside it as they land, without walking the folder each frame.
const std = @import("std");
const builtin = @import("builtin");

pub const Watch = struct {
    gpa: std.mem.Allocator,
    /// The OS's watch, on the heap: Windows and macOS write into it from outside while it runs.
    impl: *Impl,

    const Impl = switch (builtin.os.tag) {
        .linux => Inotify,
        .windows => DirectoryChanges,
        .macos => FsEvents,
        else => void,
    };

    /// Watch `folder` (relative to `base`, a path of the caller's that outlives the watch) and
    /// every folder in it, now and later. Null where the OS has no watch for this editor or the
    /// folder can't be watched; pair with `deinit`.
    ///
    /// ```zig
    /// var watch = try Watch.init(gpa, io, project_dir, "resources");
    /// defer if (watch) |*found| found.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, io: std.Io, base: []const u8, folder: []const u8) !?Watch {
        if (Impl == void) return null;
        const impl = try gpa.create(Impl);
        errdefer gpa.destroy(impl);
        if (!try impl.start(gpa, io, base, folder)) {
            gpa.destroy(impl);
            return null;
        }
        return .{ .gpa = gpa, .impl = impl };
    }

    pub fn deinit(self: *Watch) void {
        if (Impl == void) return;
        self.impl.stop();
        self.gpa.destroy(self.impl);
    }

    /// Add to `changed` (paths relative to `base` with `/` between folders, in `arena`, each
    /// once) what changed since the last poll, without waiting.
    pub fn poll(self: *Watch, io: std.Io, arena: std.mem.Allocator, changed: *std.ArrayList([]const u8)) !void {
        if (Impl == void) return;
        try self.impl.poll(io, arena, changed);
    }
};

/// Add `path` to `changed` unless it is there already.
fn note(arena: std.mem.Allocator, changed: *std.ArrayList([]const u8), path: []const u8) !void {
    for (changed.items) |seen| if (std.mem.eql(u8, seen, path)) return;
    try changed.append(arena, path);
}

/// Linux: a watch on each folder, as inotify watches no deeper; folders made later are added
/// as they are seen.
const Inotify = struct {
    const linux = std.os.linux;
    /// What a watched folder reports: a file written and closed, moved in or out, deleted, and
    /// folders made, to watch them too.
    const events = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.DELETE | linux.IN.CREATE | linux.IN.ONLYDIR;

    gpa: std.mem.Allocator,
    fd: i32,
    /// Each watched folder, by its watch: its path from `base` ("resources/scene"), owned.
    folders: std.AutoHashMapUnmanaged(i32, []u8) = .empty,
    base: []const u8,

    fn start(self: *Inotify, gpa: std.mem.Allocator, io: std.Io, base: []const u8, folder: []const u8) !bool {
        const result = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(result) != .SUCCESS) return false;
        self.* = .{ .gpa = gpa, .fd = @intCast(result), .base = base };
        errdefer self.stop();
        try self.addTree(io, folder);
        if (self.folders.count() > 0) return true;
        self.stop();
        return false;
    }

    fn stop(self: *Inotify) void {
        var paths = self.folders.valueIterator();
        while (paths.next()) |path| self.gpa.free(path.*);
        self.folders.deinit(self.gpa);
        _ = linux.close(self.fd);
    }

    fn poll(self: *Inotify, io: std.Io, arena: std.mem.Allocator, changed: *std.ArrayList([]const u8)) !void {
        var buffer: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const result = linux.read(self.fd, &buffer, buffer.len);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .AGAIN => return,
                .INTR => continue,
                else => return error.WatchFailed,
            }
            if (result == 0) return;
            var at: usize = 0;
            while (at < result) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[at]));
                at += @sizeOf(linux.inotify_event) + event.len;
                const folder = self.folders.get(event.wd) orelse continue;
                const name = event.getName() orelse continue;
                const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, name });
                if (event.mask & linux.IN.ISDIR != 0) {
                    if (event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) try self.addTree(io, path);
                    continue;
                }
                try note(arena, changed, path);
            }
        }
    }

    /// Watch `folder` and the folders in it.
    fn addTree(self: *Inotify, io: std.Io, folder: []const u8) !void {
        try self.add(folder);
        var root = try std.Io.Dir.cwd().openDir(io, self.base, .{});
        defer root.close(io);
        var dir = root.openDir(io, folder, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = try dir.walk(self.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ folder, entry.path });
            defer self.gpa.free(path);
            try self.add(path);
        }
    }

    fn add(self: *Inotify, folder: []const u8) !void {
        const full = try std.fs.path.joinZ(self.gpa, &.{ self.base, folder });
        defer self.gpa.free(full);
        const result = linux.inotify_add_watch(self.fd, full, events);
        if (linux.errno(result) != .SUCCESS) return;
        const wd: i32 = @intCast(result);
        const entry = try self.folders.getOrPut(self.gpa, wd);
        if (entry.found_existing) return;
        entry.value_ptr.* = self.gpa.dupe(u8, folder) catch |err| {
            self.folders.removeByPtr(entry.key_ptr);
            return err;
        };
    }
};

/// Windows: one read of the folder's changes, all the way down, kept pending; a poll takes it
/// if it finished and starts the next.
const DirectoryChanges = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, event: ?HANDLE = null };
    /// Where a `FILE_NOTIFY_INFORMATION`'s fields are: the next one's offset, the name's length
    /// in bytes, and the UTF-16 name. Read byte by byte: Wine doesn't keep them aligned.
    const next_offset_at = 0;
    const name_bytes_at = 8;
    const name_at = 12;

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadDirectoryChangesW(dir: HANDLE, buffer: *anyopaque, length: u32, subtree: c_int, filter: u32, returned: ?*u32, overlapped: *Overlapped, routine: ?*const anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn GetOverlappedResult(file: HANDLE, overlapped: *Overlapped, transferred: *u32, wait: c_int) callconv(.winapi) c_int;
    extern "kernel32" fn CancelIoEx(file: HANDLE, overlapped: ?*Overlapped) callconv(.winapi) c_int;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(object: HANDLE) callconv(.winapi) c_int;

    const file_list_directory = 0x1;
    const share_all = 0x1 | 0x2 | 0x4;
    const open_existing = 3;
    const backup_semantics = 0x02000000;
    const overlapped_io = 0x40000000;
    /// Files made, renamed or deleted, and written.
    const filter = 0x1 | 0x10;
    const io_incomplete = 996;

    gpa: std.mem.Allocator,
    handle: HANDLE,
    folder: []u8,
    overlapped: Overlapped = .{},
    buffer: [64 * 1024]u8 align(@alignOf(u32)) = undefined,

    fn start(self: *DirectoryChanges, gpa: std.mem.Allocator, io: std.Io, base: []const u8, folder: []const u8) !bool {
        _ = io;
        const full = try std.fs.path.join(gpa, &.{ base, folder });
        defer gpa.free(full);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, full);
        defer gpa.free(wide);
        const handle = CreateFileW(wide, file_list_directory, share_all, null, open_existing, backup_semantics | overlapped_io, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return false;
        self.* = .{ .gpa = gpa, .handle = handle, .folder = gpa.dupe(u8, folder) catch |err| {
            _ = CloseHandle(handle);
            return err;
        } };
        if (self.read()) return true;
        _ = CloseHandle(handle);
        gpa.free(self.folder);
        return false;
    }

    fn read(self: *DirectoryChanges) bool {
        self.overlapped = .{};
        return ReadDirectoryChangesW(self.handle, &self.buffer, self.buffer.len, 1, filter, null, &self.overlapped, null) != 0;
    }

    fn stop(self: *DirectoryChanges) void {
        // The read writes into `buffer` until it is cancelled and done.
        _ = CancelIoEx(self.handle, &self.overlapped);
        var transferred: u32 = 0;
        _ = GetOverlappedResult(self.handle, &self.overlapped, &transferred, 1);
        _ = CloseHandle(self.handle);
        self.gpa.free(self.folder);
    }

    fn poll(self: *DirectoryChanges, io: std.Io, arena: std.mem.Allocator, changed: *std.ArrayList([]const u8)) !void {
        _ = io;
        var transferred: u32 = 0;
        if (GetOverlappedResult(self.handle, &self.overlapped, &transferred, 0) == 0) {
            if (GetLastError() == io_incomplete) return;
            return error.WatchFailed;
        }
        // ponytail: none reported means more changed than `buffer` holds, and those are missed until the next refocus; read a bigger buffer if that happens in practice.
        var at: usize = 0;
        while (transferred > 0) {
            const record = self.buffer[at..transferred];
            const next_offset = std.mem.readInt(u32, record[next_offset_at..][0..4], .little);
            const name_bytes = std.mem.readInt(u32, record[name_bytes_at..][0..4], .little);
            const units = try arena.alloc(u16, name_bytes / 2);
            for (units, 0..) |*unit, i| unit.* = std.mem.readInt(u16, record[name_at + 2 * i ..][0..2], .little);
            const name = try std.unicode.utf16LeToUtf8Alloc(arena, units);
            std.mem.replaceScalar(u8, name, '\\', '/');
            try note(arena, changed, try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.folder, name }));
            if (next_offset == 0) break;
            at += next_offset;
        }
        if (!self.read()) return error.WatchFailed;
    }
};

/// macOS: an FSEvents stream over the folder, all the way down, calling back on a queue of its
/// own; a poll takes what it collected.
const FsEvents = struct {
    const Callback = *const fn (stream: ?*anyopaque, info: ?*anyopaque, count: usize, paths: ?*anyopaque, flags: [*]const u32, ids: [*]const u64) callconv(.c) void;
    const Context = extern struct { version: isize = 0, info: ?*anyopaque, retain: ?*const anyopaque = null, release: ?*const anyopaque = null, describe: ?*const anyopaque = null };

    extern "c" fn CFStringCreateWithCString(allocator: ?*anyopaque, text: [*:0]const u8, encoding: u32) ?*anyopaque;
    extern "c" fn CFArrayCreate(allocator: ?*anyopaque, values: [*]const ?*anyopaque, count: isize, callbacks: ?*const anyopaque) ?*anyopaque;
    extern "c" fn CFRelease(object: ?*anyopaque) void;
    extern "c" const kCFTypeArrayCallBacks: anyopaque;
    extern "c" fn FSEventStreamCreate(allocator: ?*anyopaque, callback: Callback, context: *const Context, paths: ?*anyopaque, since: u64, latency_s: f64, flags: u32) ?*anyopaque;
    extern "c" fn FSEventStreamSetDispatchQueue(stream: *anyopaque, queue: ?*anyopaque) void;
    extern "c" fn FSEventStreamStart(stream: *anyopaque) u8;
    extern "c" fn FSEventStreamStop(stream: *anyopaque) void;
    extern "c" fn FSEventStreamInvalidate(stream: *anyopaque) void;
    extern "c" fn FSEventStreamRelease(stream: *anyopaque) void;
    extern "c" fn dispatch_queue_create(label: [*:0]const u8, attributes: ?*anyopaque) ?*anyopaque;
    extern "c" fn dispatch_release(object: *anyopaque) void;

    const utf8 = 0x08000100;
    const since_now = 0xFFFFFFFFFFFFFFFF;
    const no_defer = 0x2;
    const file_events = 0x10;
    const item_is_dir = 0x20000;

    gpa: std.mem.Allocator,
    stream: *anyopaque,
    queue: *anyopaque,
    /// `base` as FSEvents names it: absolute, links resolved.
    root: []u8,
    /// What the stream reported since the last poll (owned), under `mutex`.
    mutex: std.atomic.Mutex = .unlocked,
    paths: std.ArrayList([]u8) = .empty,

    fn start(self: *FsEvents, gpa: std.mem.Allocator, io: std.Io, base: []const u8, folder: []const u8) !bool {
        const root = std.Io.Dir.cwd().realPathFileAlloc(io, base, gpa) catch return false;
        errdefer gpa.free(root);
        const watched = try std.fs.path.joinZ(gpa, &.{ root, folder });
        defer gpa.free(watched);
        const path = CFStringCreateWithCString(null, watched, utf8) orelse return false;
        defer CFRelease(path);
        const list = CFArrayCreate(null, &.{path}, 1, &kCFTypeArrayCallBacks) orelse return false;
        defer CFRelease(list);
        self.* = .{ .gpa = gpa, .stream = undefined, .queue = undefined, .root = root };
        const context: Context = .{ .info = self };
        self.stream = FSEventStreamCreate(null, report, &context, list, since_now, 0.05, no_defer | file_events) orelse return false;
        self.queue = dispatch_queue_create("eggy.file_watch", null) orelse {
            FSEventStreamRelease(self.stream);
            return false;
        };
        FSEventStreamSetDispatchQueue(self.stream, self.queue);
        if (FSEventStreamStart(self.stream) != 0) return true;
        FSEventStreamInvalidate(self.stream);
        FSEventStreamRelease(self.stream);
        dispatch_release(self.queue);
        gpa.free(root);
        return false;
    }

    fn stop(self: *FsEvents) void {
        FSEventStreamStop(self.stream);
        // After this the stream calls back no more.
        FSEventStreamInvalidate(self.stream);
        FSEventStreamRelease(self.stream);
        dispatch_release(self.queue);
        for (self.paths.items) |path| self.gpa.free(path);
        self.paths.deinit(self.gpa);
        self.gpa.free(self.root);
    }

    fn report(stream: ?*anyopaque, info: ?*anyopaque, count: usize, paths: ?*anyopaque, flags: [*]const u32, ids: [*]const u64) callconv(.c) void {
        _ = stream;
        _ = ids;
        const self: *FsEvents = @ptrCast(@alignCast(info.?));
        const names: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths.?));
        self.lock();
        defer self.mutex.unlock();
        for (names[0..count], flags[0..count]) |name, flag| {
            if (flag & item_is_dir != 0) continue;
            const path = std.mem.span(name);
            if (path.len <= self.root.len + 1 or !std.mem.startsWith(u8, path, self.root) or path[self.root.len] != '/') continue;
            // Out of memory on the queue: this change is missed until the next refocus.
            const relative = self.gpa.dupe(u8, path[self.root.len + 1 ..]) catch continue;
            self.paths.append(self.gpa, relative) catch self.gpa.free(relative);
        }
    }

    fn lock(self: *FsEvents) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn poll(self: *FsEvents, io: std.Io, arena: std.mem.Allocator, changed: *std.ArrayList([]const u8)) !void {
        _ = io;
        self.lock();
        defer self.mutex.unlock();
        defer {
            for (self.paths.items) |path| self.gpa.free(path);
            self.paths.clearRetainingCapacity();
        }
        for (self.paths.items) |path| try note(arena, changed, try arena.dupe(u8, path));
    }
};

test "a file written in a watched folder, or in a folder made in it later, is reported once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (Watch.Impl == void) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "resources/scene");
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);

    var watch = (try Watch.init(gpa, io, base, "resources")).?;
    defer watch.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var changed: std.ArrayList([]const u8) = .empty;

    try tmp.dir.writeFile(io, .{ .sub_path = "resources/scene/main.scene.zon", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "resources/scene/main.scene.zon", .data = ".{ }" });
    try waitFor(&watch, io, arena.allocator(), &changed, "resources/scene/main.scene.zon");
    var reports: usize = 0;
    for (changed.items) |path| reports += @intFromBool(std.mem.eql(u8, path, "resources/scene/main.scene.zon"));
    try std.testing.expectEqual(@as(usize, 1), reports);

    // A folder made after the watch started is watched once it is seen.
    try tmp.dir.createDirPath(io, "resources/levels");
    try watch.poll(io, arena.allocator(), &changed);
    try tmp.dir.writeFile(io, .{ .sub_path = "resources/levels/one.scene.zon", .data = ".{}" });
    try waitFor(&watch, io, arena.allocator(), &changed, "resources/levels/one.scene.zon");
}

/// Poll `watch` until `path` is among `changed`, for up to two seconds: Windows and macOS report
/// a moment after the write.
fn waitFor(watch: *Watch, io: std.Io, arena: std.mem.Allocator, changed: *std.ArrayList([]const u8), path: []const u8) !void {
    for (0..100) |_| {
        try watch.poll(io, arena, changed);
        for (changed.items) |seen| if (std.mem.eql(u8, seen, path)) return;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.NotReported;
}

test "every OS's watch compiles" {
    _ = &Watch.init;
    _ = &Watch.poll;
    _ = &Watch.deinit;
}
