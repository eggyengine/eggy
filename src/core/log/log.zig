//! Eggy's log on the desktop: `std.log` messages at or above a level chosen while running
//! (`--log-level`, else the editor's preference, else `info`), printed as usual and kept in a file
//! per run under `<data folder>/logs/`, of which the newest few are kept. `crash_report.zig`
//! writes what a fatal error leaves behind beside them.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("vitellus_sdl3").sdl;

pub const crash_report = @import("crash_report.zig");

/// Log files kept per program: starting a run deletes the oldest past this many.
const kept_runs = 10;
const command_line_flag = "--log-level=";

/// The quietest level shown; messages below it are dropped.
var shown_level: std.log.Level = .info;
/// Whether `--log-level` set `shown_level`, which then wins over the editor's preference.
var level_from_command_line = false;

/// The run's log file, once `start` opened it. Writes from any thread go through `mutex`.
var mutex: std.Io.Mutex = .init;
var file: ?std.Io.File = null;
var file_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
var file_path_len: usize = 0;

/// Which of Eggy's data folders a program logs into: the editor's, or the games'.
pub const Program = enum { editor, game };

/// Begin the run's log: take `--log-level=<err|warn|info|debug>` from `args` and open
/// `<data folder>/logs/<name>-<date>-<time>.log`, deleting the oldest of `name`'s past
/// `kept_runs`. Call once, early in `init`. Desktop only (a no-op elsewhere); a log file that
/// can't be made is reported and the run goes on without one.
pub fn start(io: std.Io, program: Program, name: []const u8, args: []const [*:0]const u8) void {
    takeLevelFlag(args);
    if (builtin.os.tag == .emscripten or builtin.abi.isAndroid()) return;
    openFile(io, program, name) catch |err| std.log.warn("no log file this run: {t}", .{err});
}

/// Show the level `--log-level=` names in `args`, whatever the preference says.
fn takeLevelFlag(args: []const [*:0]const u8) void {
    for (args) |arg| {
        const text = std.mem.span(arg);
        if (!std.mem.startsWith(u8, text, command_line_flag)) continue;
        const value = text[command_line_flag.len..];
        shown_level = std.meta.stringToEnum(std.log.Level, value) orelse {
            std.log.warn("unknown log level {s}: expected err, warn, info or debug", .{value});
            continue;
        };
        level_from_command_line = true;
    }
}

/// Show messages at `level` and above, unless `--log-level` chose otherwise. Thread-safe enough
/// for a setting: the level is read without a lock.
pub fn setLevel(level: std.log.Level) void {
    if (!level_from_command_line) shown_level = level;
}

/// Whether a message at `level` is shown.
pub fn shows(level: std.log.Level) bool {
    return @backingInt(level) <= @backingInt(shown_level);
}

/// The run's log file, absolute, or null without one.
pub fn filePath() ?[]const u8 {
    return if (file_path_len == 0) null else file_path_buffer[0..file_path_len];
}

/// The last `buffer.len` bytes of the run's log file, from the start of a line, in `buffer`;
/// empty without a log file or if it can't be read.
pub fn readTail(io: std.Io, buffer: []u8) []const u8 {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const log_file = file orelse return "";
    const len = log_file.length(io) catch return "";
    const from = len -| buffer.len;
    const read = log_file.readPositionalAll(io, buffer, from) catch return "";
    const tail = buffer[0..read];
    if (from == 0) return tail;
    const line_start = std.mem.indexOfScalar(u8, tail, '\n') orelse return tail;
    return tail[line_start + 1 ..];
}

/// `std.Options.logFn` for Eggy's programs: messages at the shown level and above are printed as
/// `std.log` does and appended to the log file. Thread-safe.
///
/// ```zig
/// pub const std_options: std.Options = .{ .log_level = .debug, .logFn = eggy.log.logFn };
/// ```
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (!shows(level)) return;
    // The test runner fails a test that logs a warning, so tests keep quiet.
    if (!builtin.is_test) std.log.defaultLog(level, scope, format, args);
    appendToFile(level, scope, format, args);
}

fn appendToFile(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const io = std.Options.debug_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const log_file = file orelse return;
    var buffer: [512]u8 = undefined;
    var writer = log_file.writerStreaming(io, &buffer);
    const prefix = comptime level.asText() ++ (if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ");
    const seconds = @as(f64, @floatFromInt(sdl3.timer.getMillisecondsSinceInit())) / 1000;
    writer.interface.print("[{d:>9.3}] " ++ prefix ++ format ++ "\n", .{seconds} ++ args) catch return;
    writer.interface.flush() catch {};
}

fn openFile(io: std.Io, program: Program, name: []const u8) !void {
    const pref = try sdl3.filesystem.getPrefPath("eggy", switch (program) {
        .editor => "eggy",
        .game => "games",
    });
    defer sdl3.free(pref);
    var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const folder_path = try std.fmt.bufPrint(&folder_buffer, "{s}logs", .{pref});
    var folder = try std.Io.Dir.cwd().createDirPathOpen(io, folder_path, .{ .open_options = .{ .iterate = true } });
    defer folder.close(io);

    // Named so they sort oldest first: `name-YYYYMMDD-HHMMSS.log`, in UTC.
    const now: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toSeconds()));
    const day = (std.time.epoch.EpochSeconds{ .secs = now }).getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const day_seconds = (std.time.epoch.EpochSeconds{ .secs = now }).getDaySeconds();
    var file_name_buffer: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buffer, "{s}-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.log", .{
        name,                          day.year,                         month_day.month.numeric(),          month_day.day_index + 1,
        day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(),
    });
    try deleteOldest(io, folder, name);

    // Readable too, so a crash report can quote its end.
    const opened = try folder.createFile(io, file_name, .{ .read = true });
    const path = try std.fmt.bufPrint(&file_path_buffer, "{s}/{s}", .{ folder_path, file_name });
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    file = opened;
    file_path_len = path.len;
}

/// Delete `name`'s oldest log files, leaving room for one more within `kept_runs`.
fn deleteOldest(io: std.Io, folder: std.Io.Dir, name: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runs: std.ArrayList([]const u8) = .empty;
    var it = folder.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isRunOf(entry.name, name)) continue;
        try runs.append(arena, try arena.dupe(u8, entry.name));
    }
    if (runs.items.len < kept_runs) return;
    std.mem.sortUnstable([]const u8, runs.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (runs.items[0 .. runs.items.len - kept_runs + 1]) |old| folder.deleteFile(io, old) catch {};
}

/// Whether `file_name` is one of `name`'s run logs (`name-YYYYMMDD-HHMMSS.log`), not another
/// program's whose name starts the same.
fn isRunOf(file_name: []const u8, name: []const u8) bool {
    const stamp_len = "-YYYYMMDD-HHMMSS.log".len;
    if (file_name.len != name.len + stamp_len or !std.mem.startsWith(u8, file_name, name)) return false;
    const stamp = file_name[name.len..];
    return stamp[0] == '-' and stamp[9] == '-' and std.mem.endsWith(u8, stamp, ".log");
}

test "a run's log is told apart from a program whose name starts the same" {
    try std.testing.expect(isRunOf("space-20261021-230405.log", "space"));
    try std.testing.expect(!isRunOf("space_editor-20261021-230405.log", "space"));
    try std.testing.expect(!isRunOf("space-20261021-230405-crash.txt", "space"));
}

test "the command line's level wins over a preference" {
    defer {
        shown_level = .info;
        level_from_command_line = false;
    }
    takeLevelFlag(&.{"--log-level=debug"});
    try std.testing.expect(shows(.debug));
    setLevel(.err);
    try std.testing.expect(shows(.debug));
}
