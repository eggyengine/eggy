//! The editor's end of its splash screen: starts it, tells it each startup step, and has it show
//! a fatal error in place of the message box until the editor's first frame is up.
const std = @import("std");
const eggy = @import("eggy");
const message = @import("message.zig");
const log = std.log.scoped(.splash);

/// The flag that starts this executable as the splash screen, followed by the project's name and
/// Eggy's version.
pub const flag = "--splash";

/// The splash screen under way, and the pipe to it.
const Running = struct {
    io: std.Io,
    child: std.process.Child,
    /// Null once closed: the splash screen goes when it reads to the end.
    stdin: ?std.Io.File,
    /// Guards `stdin`: asset loaders tell the splash what they load from their own threads.
    lock: std.atomic.Mutex = .unlocked,
};

// ponytail: one splash per process, as one editor process shows one project; the fatal dialog's
// presenter is a plain function, so the splash it reaches is process-wide too.
var running: ?Running = null;

/// Show the splash screen for `project_name`: this executable again, with `flag`, given
/// `environ` (its display is found there). A splash that can't start is logged and left out.
/// Main thread, once, as the editor starts.
///
/// ```zig
/// splash.open(process_init.io, process_init.environ_map, project.name);
/// splash.step(.graphics);
/// ```
pub fn open(io: std.Io, environ: *const std.process.Environ.Map, project_name: []const u8) void {
    start(io, environ, project_name) catch |err| log.warn("no splash screen: {t}", .{err});
}

fn start(io: std.Io, environ: *const std.process.Environ.Map, project_name: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try std.process.executablePath(io, &path_buffer)];
    const child = try std.process.spawn(io, .{
        .argv = &.{ path, flag, project_name, @import("build_options").version },
        .stdin = .pipe,
        // SDL's Io passes no environment on by itself.
        .environ_map = environ,
    });
    running = .{ .io = io, .child = child, .stdin = child.stdin };
    eggy.fatal_dialog.presenter = present;
}

/// Tell the splash screen `step` has begun.
pub fn step(begun: message.Step) void {
    send(.{ .step = begun });
}

/// Tell the splash screen what the current step is working on, such as a file's path. Any thread.
pub fn detail(text: []const u8) void {
    send(.{ .detail = text });
}

/// The editor's first frame is on screen: the splash screen says so and goes, and fatal errors
/// show in the message box again.
pub fn finish() void {
    send(.done);
    closeInput();
    if (eggy.fatal_dialog.presenter == present) eggy.fatal_dialog.presenter = null;
}

/// Wait for the splash screen to have gone, after `finish`: before the editor exits.
pub fn wait() void {
    var splash = &(running orelse return);
    closeInput();
    _ = splash.child.wait(splash.io) catch |err| log.debug("splash screen: {t}", .{err});
    running = null;
}

/// Show a fatal error on the splash screen, and wait for it to be closed.
fn present(stage: []const u8, text: []const u8) bool {
    _ = stage;
    const splash = &(running orelse return false);
    if (splash.stdin == null) return false;
    send(.{ .fail = text });
    if (splash.stdin == null) return false;
    wait();
    return true;
}

fn send(sent: message.Message) void {
    const splash = &(running orelse return);
    while (!splash.lock.tryLock()) std.atomic.spinLoopHint();
    defer splash.lock.unlock();
    const pipe = splash.stdin orelse return;
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    // A message too long for the line is cut; the splash shows what fits anyway.
    message.write(&writer, sent) catch {
        writer.end = buffer.len - 1;
        writer.buffer[writer.end] = '\n';
        writer.end += 1;
    };
    pipe.writeStreamingAll(splash.io, writer.buffered()) catch |err| {
        // The splash screen is gone: the editor starts without it.
        log.debug("splash screen: {t}", .{err});
        pipe.close(splash.io);
        splash.stdin = null;
    };
}

fn closeInput() void {
    const splash = &(running orelse return);
    while (!splash.lock.tryLock()) std.atomic.spinLoopHint();
    defer splash.lock.unlock();
    if (splash.stdin) |pipe| pipe.close(splash.io);
    splash.stdin = null;
    splash.child.stdin = null;
}
