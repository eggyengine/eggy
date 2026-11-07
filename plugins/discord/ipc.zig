//! Talking to the Discord app over its local IPC, the protocol Rich Presence uses: a worker that
//! connects, says hello as the application, and sends the latest status whenever it changes,
//! trying again every few seconds while Discord is closed.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Activity = @import("activity.zig").Activity;
const log = std.log.scoped(.discord);

/// How long to wait before looking for Discord again.
const retry_s = 5;
/// How often the worker looks for a new status to send.
const poll_ms = 250;
/// The most a message to or from Discord may be; longer replies are cut, as only their opcode
/// matters.
const max_payload = 8 * 1024;
/// The picture beside the status: the Eggy icon among the application's Rich Presence art assets.
const large_image = "eggy_icon_1_";
/// The status's one button, to Eggy's repository. Discord shows it to others, not to you.
const repository_button = .{ .label = "Eggy source code", .url = "https://git.tirbo.fish/eggy/eggy" };

/// What a frame is: the kind of message it carries.
pub const Opcode = enum(u32) { handshake = 0, frame = 1, close = 2, ping = 3, pong = 4, _ };

pub const Frame = struct { opcode: Opcode, payload: []const u8 };

/// Send `payload` as one frame: opcode and length, little-endian, then the JSON.
pub fn writeFrame(writer: *Io.Writer, opcode: Opcode, payload: []const u8) Io.Writer.Error!void {
    try writer.writeInt(u32, @backingInt(opcode), .little);
    try writer.writeInt(u32, @intCast(payload.len), .little);
    try writer.writeAll(payload);
    try writer.flush();
}

/// The next frame, its payload in `buffer` (cut to fit, the rest skipped).
pub fn readFrame(reader: *Io.Reader, buffer: []u8) Io.Reader.Error!Frame {
    const opcode: Opcode = @fromBackingInt(@intCast(try reader.takeInt(u32, .little)));
    const len = try reader.takeInt(u32, .little);
    const kept = @min(len, buffer.len);
    try reader.readSliceAll(buffer[0..kept]);
    try reader.discardAll(len - kept);
    return .{ .opcode = opcode, .payload = buffer[0..kept] };
}

/// The command that sets the status of process `pid` to `status`, counting from `start_s` (Unix
/// seconds); `nonce` tells its reply apart.
pub fn writeSetActivity(writer: *Io.Writer, pid: u32, nonce: u64, status: *const Activity, start_s: i64) Io.Writer.Error!void {
    var nonce_buffer: [24]u8 = undefined;
    const command = .{
        .cmd = "SET_ACTIVITY",
        .nonce = std.fmt.bufPrint(&nonce_buffer, "{d}", .{nonce}) catch unreachable,
        .args = .{ .pid = pid, .activity = .{
            .details = status.details(),
            .state = @as(?[]const u8, if (status.state().len > 0) status.state() else null),
            .timestamps = .{ .start = start_s },
            .assets = .{ .large_image = large_image, .large_text = "Eggy" },
            .buttons = .{repository_button},
        } },
    };
    try writer.print("{f}", .{std.json.fmt(command, .{ .emit_null_optional_fields = false })});
}

/// Where the Discord app listens, in the order to try, in `arena`: its pipes on Windows; elsewhere
/// its sockets in the runtime and temporary folders `environ_map` names, including those of the
/// Flatpak and Snap builds.
pub fn socketPaths(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    if (builtin.os.tag == .windows) {
        for (0..10) |i| try paths.append(arena, try std.fmt.allocPrint(arena, "\\\\.\\pipe\\discord-ipc-{d}", .{i}));
        return paths.items;
    }
    var folders: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP" }) |name| if (environ_map.get(name)) |folder| try folders.append(arena, folder);
    try folders.append(arena, "/tmp");
    for (folders.items) |folder| for ([_][]const u8{ "", "app/com.discordapp.Discord", "snap.discord", ".flatpak/com.discordapp.Discord/xdg-run" }) |inside| {
        for (0..10) |i| try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/discord-ipc-{d}", .{ try std.fs.path.join(arena, &.{ folder, inside }), i }));
    };
    return paths.items;
}

/// A status sender, its worker running until `destroy`.
pub const Client = struct {
    gpa: std.mem.Allocator,
    threaded: Io.Threaded,
    paths_arena: std.heap.ArenaAllocator,
    paths: []const []const u8,
    application_id: u64,
    pid: u32,
    worker: Io.Future(void) = undefined,

    // Shared with the worker, under `mutex`.
    mutex: Io.Mutex = .init,
    wanted: Activity = .{},
    wanted_start_s: i64 = 0,
    /// Counts the statuses asked for; 0 before the first.
    generation: u64 = 0,

    /// Start looking for Discord to show statuses as `application_id`, at `paths` (see
    /// `socketPaths`, which are copied). Fails only on allocation or threads.
    pub fn start(gpa: std.mem.Allocator, paths: []const []const u8, application_id: u64) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{}), .paths_arena = .init(gpa), .paths = &.{}, .application_id = application_id, .pid = processId() };
        errdefer self.threaded.deinit();
        errdefer self.paths_arena.deinit();
        const kept = try self.paths_arena.allocator().alloc([]const u8, paths.len);
        for (kept, paths) |*to, from| to.* = try self.paths_arena.allocator().dupe(u8, from);
        self.paths = kept;
        self.worker = try self.threaded.io().concurrent(run, .{self});
        return self;
    }

    /// Show `status`, counting from `start_s` (Unix seconds), once connected; it replaces any
    /// status not yet sent.
    pub fn show(self: *Client, status: Activity, start_s: i64) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.wanted = status;
        self.wanted_start_s = start_s;
        self.generation += 1;
    }

    /// Stop the worker, closing the connection (Discord then clears the status), and free it.
    pub fn destroy(self: *Client) void {
        const gpa = self.gpa;
        self.worker.cancel(self.threaded.io());
        self.threaded.deinit();
        self.paths_arena.deinit();
        gpa.destroy(self);
    }

    fn run(self: *Client) void {
        const io = self.threaded.io();
        var refusal_logged = false;
        while (true) {
            self.session(io) catch |err| switch (err) {
                error.Canceled => return,
                error.Refused => if (!refusal_logged) {
                    refusal_logged = true;
                    log.warn("Discord refused Application ID {d}: check it in Settings", .{self.application_id});
                },
                // Discord isn't open, or closed: look again later.
                else => {},
            };
            io.sleep(.fromSeconds(retry_s), .awake) catch return;
        }
    }

    /// One connection: hello, then each new status, until Discord or the worker ends it.
    fn session(self: *Client, io: Io) !void {
        const pipe = try self.connect(io);
        defer pipe.close(io);
        var read_buffer: [1024]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var pipe_reader = if (builtin.os.tag == .windows) pipe.readerStreaming(io, &read_buffer) else pipe.reader(io, &read_buffer);
        var pipe_writer = if (builtin.os.tag == .windows) pipe.writerStreaming(io, &write_buffer) else pipe.writer(io, &write_buffer);
        // The pipe's reader and writer keep why they failed (being cancelled, say) to themselves.
        self.talk(io, &pipe_reader.interface, &pipe_writer.interface) catch |err| return switch (err) {
            error.ReadFailed => pipe_reader.err orelse err,
            error.WriteFailed => pipe_writer.err orelse err,
            else => err,
        };
    }

    fn talk(self: *Client, io: Io, reader: *Io.Reader, writer: *Io.Writer) !void {
        var payload_buffer: [max_payload]u8 = undefined;

        var hello: Io.Writer = .fixed(&payload_buffer);
        try hello.print("{{\"v\":1,\"client_id\":\"{d}\"}}", .{self.application_id});
        try writeFrame(writer, .handshake, hello.buffered());
        if ((try readFrame(reader, &payload_buffer)).opcode != .frame) return error.Refused;

        // A new connection sends the latest status again, so start from nothing sent.
        var sent: u64 = 0;
        while (true) {
            const status, const start_s = self.unsent(io, &sent) orelse {
                try io.sleep(.fromMilliseconds(poll_ms), .awake);
                continue;
            };
            var command: Io.Writer = .fixed(&payload_buffer);
            try writeSetActivity(&command, self.pid, sent, &status, start_s);
            try writeFrame(writer, .frame, command.buffered());
            // Read its reply, so what Discord sends never piles up unread.
            while (true) {
                const reply = try readFrame(reader, &payload_buffer);
                switch (reply.opcode) {
                    .ping => try writeFrame(writer, .pong, reply.payload),
                    .close => return error.ConnectionClosed,
                    else => break,
                }
            }
        }
    }

    /// The status asked for since `sent`, marking it sent; null when there is none.
    fn unsent(self: *Client, io: Io, sent: *u64) ?struct { Activity, i64 } {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.generation == sent.*) return null;
        sent.* = self.generation;
        return .{ self.wanted, self.wanted_start_s };
    }

    /// The first of `paths` Discord answers at.
    fn connect(self: *Client, io: Io) !Pipe {
        for (self.paths) |path| {
            if (openPipe(io, path)) |pipe| return pipe else |err| if (err == error.Canceled) return err;
        }
        return error.DiscordNotRunning;
    }
};

/// Windows reaches Discord through a named pipe, opened as a file; elsewhere, a Unix socket.
const Pipe = if (builtin.os.tag == .windows) Io.File else Io.net.Stream;

fn openPipe(io: Io, path: []const u8) !Pipe {
    if (builtin.os.tag == .windows) return Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
    const address = try Io.net.UnixAddress.init(path);
    return address.connect(io);
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

test "a frame is its opcode and length, then the JSON, and reads back the same" {
    var bytes: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&bytes);
    try writeFrame(&writer, .handshake, "{}");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 2, 0, 0, 0, '{', '}' }, writer.buffered());
    var reader: Io.Reader = .fixed(writer.buffered());
    var payload: [1]u8 = undefined;
    const frame = try readFrame(&reader, &payload);
    try std.testing.expectEqual(Opcode.handshake, frame.opcode);
    try std.testing.expectEqualStrings("{", frame.payload);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}

test "a status without a second line leaves state out" {
    const describe = @import("activity.zig").describe;
    var bytes: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&bytes);
    try writeSetActivity(&writer, 42, 7, &describe("bees", "", .editing), 1700000000);
    try std.testing.expectEqualStrings(
        \\{"cmd":"SET_ACTIVITY","nonce":"7","args":{"pid":42,"activity":{"details":"Editing bees","timestamps":{"start":1700000000},"assets":{"large_image":"eggy_icon_1_","large_text":"Eggy"},"buttons":[{"label":"Eggy source code","url":"https://git.tirbo.fish/eggy/eggy"}]}}}
    , writer.buffered());
}

test "Discord's sockets are looked for in the runtime folder first, then the temporary ones" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map: std.process.Environ.Map = .init(arena.allocator());
    try environ_map.put("XDG_RUNTIME_DIR", "/run/user/1000");
    const paths = try socketPaths(arena.allocator(), &environ_map);
    try std.testing.expectEqualStrings("/run/user/1000/discord-ipc-0", paths[0]);
    try std.testing.expectEqualStrings("/run/user/1000/app/com.discordapp.Discord/discord-ipc-0", paths[10]);
    try std.testing.expectEqualStrings("/tmp/discord-ipc-9", paths[paths.len - 31]);
}

test "the client says hello, then sends the status, to a pretend Discord" {
    if (!Io.net.has_unix_sockets or builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(folder);
    const path = try std.fs.path.join(std.testing.allocator, &.{ folder, "discord-ipc-0" });
    defer std.testing.allocator.free(path);
    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const client = try Client.start(std.testing.allocator, &.{path}, 1234);
    defer client.destroy();
    client.show(@import("activity.zig").describe("bees", "garden.scene.zon", .playing), 5);

    const stream = try server.accept(io);
    defer stream.close(io);
    var read_buffer: [256]u8 = undefined;
    var write_buffer: [256]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);
    var payload: [512]u8 = undefined;

    const hello = try readFrame(&stream_reader.interface, &payload);
    try std.testing.expectEqual(Opcode.handshake, hello.opcode);
    try std.testing.expectEqualStrings("{\"v\":1,\"client_id\":\"1234\"}", hello.payload);
    try writeFrame(&stream_writer.interface, .frame, "{\"evt\":\"READY\"}");

    const command = try readFrame(&stream_reader.interface, &payload);
    try std.testing.expectEqual(Opcode.frame, command.opcode);
    try std.testing.expect(std.mem.indexOf(u8, command.payload, "\"details\":\"Playtesting bees\",\"state\":\"Scene: garden\"") != null);
    try writeFrame(&stream_writer.interface, .frame, "{\"cmd\":\"SET_ACTIVITY\"}");
}
