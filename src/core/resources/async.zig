//! Bounded host-owned CPU resource jobs, joined before provider or game-library teardown.
const std = @import("std");
const builtin = @import("builtin");
const api = @import("resources.zig");
const assets = @import("eggy_assets");
const refs = @import("../refs.zig");
const threaded = !builtin.single_threaded and builtin.os.tag != .emscripten;
pub const max_requests = 8;

const Job = struct {
    source: api.Resources,
    caller: std.mem.Allocator,
    path: []u8,
    kind: api.LoadKind,
    arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    value: ?api.Result = null,
    failure: ?anyerror = null,

    fn run(self: *Job) void {
        self.started.store(true, .release);
        self.load() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn load(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return error.ResourceCancelled;
        const gpa = self.arena.allocator();
        self.value = .{ .gpa = gpa, .value = switch (self.kind) {
            .bytes => .{ .bytes = try self.source.read(gpa, try refs.AssetRef(.text).parse(self.path)) },
            .model => .{ .model = try self.source.loadModel(gpa, try refs.AssetRef(.model).parse(self.path)) },
            .image => .{ .image = try self.source.loadImage(gpa, try refs.AssetRef(.image).parse(self.path)) },
        } };
    }

    fn destroy(self: *Job, gpa: std.mem.Allocator) void {
        if (comptime threaded) if (self.thread) |thread| thread.join();
        self.arena.deinit();
        self.caller.free(self.path);
        gpa.destroy(self);
    }
};

/// Main-thread owner. Provider callbacks must be host-owned, immutable and thread-safe.
/// Worker allocations use private arenas, never the caller's possibly non-thread-safe allocator.
pub const Queue = struct {
    gpa: std.mem.Allocator,
    source: api.Resources = .{},
    jobs: std.AutoHashMapUnmanaged(u64, *Job) = .empty,
    next_id: u64 = 1,

    pub fn create(gpa: std.mem.Allocator) !*Queue {
        const self = try gpa.create(Queue);
        self.* = .{ .gpa = gpa };
        return self;
    }

    /// Cancel and join before closing provider state, destroying caller allocators or unloading
    /// the game library. IDs never reset, so old handles cannot address a new world's jobs.
    pub fn clear(self: *Queue) void {
        var values = self.jobs.valueIterator();
        while (values.next()) |job| job.*.cancelled.store(true, .release);
        values = self.jobs.valueIterator();
        while (values.next()) |job| job.*.destroy(self.gpa);
        self.jobs.clearRetainingCapacity();
    }

    pub fn destroy(self: *Queue) void {
        self.clear();
        self.jobs.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Attach host callbacks to a synchronous provider without retaining a pointer into App.
    pub fn attach(self: *Queue, source: api.Resources) api.Resources {
        self.source = source;
        var result = source;
        result.async_provider = .{ .context = self, .submit = submit, .poll = poll, .cancel = cancel, .progress = progress };
        return result;
    }

    fn submit(raw: *anyopaque, allocator: *const anyopaque, kind: api.LoadKind, path: [*]const u8, len: usize, output: *u64) callconv(.c) api.Status {
        const self: *Queue = @ptrCast(@alignCast(raw));
        const caller: *const std.mem.Allocator = @ptrCast(@alignCast(allocator));
        output.* = self.add(caller.*, kind, path[0..len]) catch |err| return api.status(err, path[0..len]);
        return .ok;
    }

    fn add(self: *Queue, caller: std.mem.Allocator, kind: api.LoadKind, path: []const u8) !u64 {
        if (self.jobs.count() >= max_requests) return error.TooManyResourceRequests;
        if (self.next_id == std.math.maxInt(u64)) return error.TooManyResourceRequests;
        const owned = try caller.dupe(u8, path);
        errdefer caller.free(owned);
        const job = try self.gpa.create(Job);
        errdefer self.gpa.destroy(job);
        job.* = .{ .source = self.source, .caller = caller, .kind = kind, .path = owned };
        errdefer job.arena.deinit();
        const id = self.next_id;
        try self.jobs.put(self.gpa, id, job);
        errdefer _ = self.jobs.remove(id);
        if (comptime threaded) job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.next_id += 1;
        return id;
    }

    fn poll(raw: *anyopaque, id: u64, output: *anyopaque) callconv(.c) api.Status {
        const self: *Queue = @ptrCast(@alignCast(raw));
        const value = self.take(id) catch |err| return api.status(err, "async completion");
        const out: *api.Result = @ptrCast(@alignCast(output));
        out.* = value orelse return .pending;
        return .ok;
    }

    fn take(self: *Queue, id: u64) !?api.Result {
        const job = self.jobs.get(id) orelse return error.InvalidResourceRequest;
        if (comptime !threaded) if (!job.done.load(.acquire)) job.run();
        if (!job.done.load(.acquire)) return null;
        defer {
            _ = self.jobs.remove(id);
            job.destroy(self.gpa);
        }
        if (job.cancelled.load(.acquire)) return error.ResourceCancelled;
        if (job.failure) |err| return err;
        const loaded = job.value.?;
        return .{ .gpa = job.caller, .value = switch (loaded.value) {
            .bytes => |bytes| .{ .bytes = try job.caller.dupeZ(u8, bytes) },
            .model => |model| block: {
                var encoded: std.Io.Writer.Allocating = .init(job.arena.allocator());
                try assets.model.write(&encoded.writer, model);
                var reader: std.Io.Reader = .fixed(encoded.written());
                break :block .{ .model = try assets.model.read(job.caller, &reader) };
            },
            .image => |image| .{ .image = .{ .width = image.width, .height = image.height, .pixels = try job.caller.dupe(u8, image.pixels) } },
        } };
    }

    fn cancel(raw: *anyopaque, id: u64) callconv(.c) api.Status {
        const self: *Queue = @ptrCast(@alignCast(raw));
        const job = self.jobs.get(id) orelse return .invalid_request;
        job.cancelled.store(true, .release);
        return .ok;
    }

    fn progress(raw: *anyopaque, id: u64, output: *api.Progress) callconv(.c) api.Status {
        const self: *Queue = @ptrCast(@alignCast(raw));
        const job = self.jobs.get(id) orelse return .invalid_request;
        output.* = if (job.done.load(.acquire)) .complete else if (job.cancelled.load(.acquire)) .cancelling else if (job.started.load(.acquire)) .loading else .queued;
        return .ok;
    }
};

test "asynchronous bytes, models and images transfer ownership and reject consumed handles" {
    const Source = struct {
        fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
            if (std.mem.eql(u8, path, "missing.txt")) return error.FileNotFound;
            return gpa.dupeZ(u8, "loaded");
        }
        fn model(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) !assets.Model {
            return .{ .vertices = try gpa.alloc(assets.model.Vertex, 0), .indices = try gpa.alloc(u32, 0), .parts = try gpa.alloc(assets.model.Part, 0), .textures = try gpa.alloc(assets.Texture, 0) };
        }
        fn image(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) !assets.Texture {
            return .{ .width = 1, .height = 1, .pixels = try gpa.dupe(u8, &.{ 1, 2, 3, 255 }) };
        }
    };
    const gpa = std.testing.allocator;
    const queue = try Queue.create(gpa);
    defer queue.destroy();
    var context: u8 = 0;
    const resources = queue.attach(api.Resources.from(&context, Source.read, Source.model, Source.image));
    const requests = [_]api.Request{
        try resources.readAsync(gpa, refs.AssetRef(.text).init("notes.txt")),
        try resources.loadModelAsync(gpa, .init("ship.glb")),
        try resources.loadImageAsync(gpa, .init("ship.png")),
    };
    for (requests, 0..) |request, index| {
        var loaded: ?api.Result = null;
        while (loaded == null) loaded = try resources.poll(request);
        var result = loaded.?;
        defer result.deinit();
        try std.testing.expectEqual(@as(api.LoadKind, @enumFromInt(index)), std.meta.activeTag(result.value));
        if (index == 0) try std.testing.expectEqualStrings("loaded", result.value.bytes);
        try std.testing.expectError(error.InvalidResourceRequest, resources.poll(request));
    }
    const cancelled = try resources.readAsync(gpa, refs.AssetRef(.text).init("notes.txt"));
    try resources.cancel(cancelled);
    while (resources.poll(cancelled)) |pending| {
        try std.testing.expect(pending == null);
    } else |err| try std.testing.expectEqual(error.ResourceCancelled, err);
    const stale = try resources.readAsync(gpa, refs.AssetRef(.text).init("notes.txt"));
    queue.clear();
    try std.testing.expectError(error.InvalidResourceRequest, resources.progress(stale));
    const missing = try resources.readAsync(gpa, refs.AssetRef(.text).init("missing.txt"));
    while (resources.poll(missing)) |pending| {
        try std.testing.expect(pending == null);
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
    for (0..max_requests) |_| _ = try resources.readAsync(gpa, refs.AssetRef(.text).init("notes.txt"));
    try std.testing.expectError(error.TooManyResourceRequests, resources.readAsync(gpa, refs.AssetRef(.text).init("notes.txt")));
}

test "native imports run off-thread and cancellation does not wait for the importer" {
    if (comptime !threaded) return error.SkipZigTest;
    const Source = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        worker_id: std.atomic.Value(usize) = .init(0),

        fn read(raw: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![:0]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.worker_id.store(@intCast(std.Thread.getCurrentId()), .release);
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
            return gpa.dupeZ(u8, "discard me");
        }
        fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Model {
            return error.NotPackaged;
        }
        fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Texture {
            return error.NotPackaged;
        }
    };
    var source = Source{};
    const queue = try Queue.create(std.testing.allocator);
    defer queue.destroy();
    defer source.release.store(true, .release);
    const resources = queue.attach(api.Resources.from(&source, Source.read, Source.model, Source.image));
    const request = try resources.readAsync(std.testing.allocator, refs.AssetRef(.text).init("notes.txt"));
    while (!source.entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(source.worker_id.load(.acquire) != @as(usize, @intCast(std.Thread.getCurrentId())));
    try std.testing.expect(try resources.poll(request) == null);
    try resources.cancel(request);
    try std.testing.expectEqual(api.Progress.cancelling, try resources.progress(request));
    source.release.store(true, .release);
    while (resources.poll(request)) |pending| {
        try std.testing.expect(pending == null);
    } else |err| try std.testing.expectEqual(error.ResourceCancelled, err);
}
