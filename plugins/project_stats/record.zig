//! How long and how the project has been worked on: time counts while someone uses the editor,
//! and stops a few idle minutes after the last input or once its windows lose focus. Each
//! person's record (their time, the days it fell on, their sessions, saves, plays and builds) is
//! kept in `.eggy/work_time/<user>.zon`, a file each so collaborators' commits never clash. The
//! session's stopwatch is this sitting's, resettable like a speedpaint's timer.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;

pub const folder = ".eggy/work_time";
/// After this long without input, the time since doesn't count; a record written less than
/// this long ago (a hot reload, or the editor opened again straight away) goes on with its sitting.
const idle_limit_ms = 5 * std.time.ms_per_min;
/// How often the record is written while it changes, so a crash loses little.
const save_interval_ms = std.time.ms_per_min;

/// Time worked on one day: `day` counts days since 1970-01-01 in the worker's local time.
pub const Day = struct { day: i32, worked_ms: u64 };

/// The sitting under way when the record was written, so a hot reload carries on with it.
pub const Sitting = struct {
    worked_ms: u64 = 0,
    stopwatch_ms: u64 = 0,
    /// When the record was written, in milliseconds since 1970-01-01 UTC.
    written_at_ms: i64 = 0,
};

/// One person's work on the project, as their file keeps it.
pub const Record = struct {
    worked_ms: u64 = 0,
    /// Editor sittings with any time worked, and the longest of them.
    sessions: u32 = 0,
    longest_session_ms: u64 = 0,
    saves: u32 = 0,
    plays: u32 = 0,
    builds: u32 = 0,
    /// Oldest first, one for each day worked.
    days: []const Day = &.{},
    sitting: Sitting = .{},
};

pub const Person = struct { name: []const u8, record: Record, is_me: bool };

/// What the editor says of its use, as `EditorStatus` has it.
pub const Use = struct {
    idle_ms: u64,
    unfocused_ms: ?u64,
    saves: u32,
    plays: u32,
    builds: u32,
};

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    /// Holds the others' records and names.
    arena: std.heap.ArenaAllocator,
    /// This person's file, relative to the project; owned.
    path: []u8,
    /// Everyone else, as their files said when the project opened.
    others: []const Person,
    /// This person's record; its `days` are `my_days`.
    mine: Record,
    my_days: std.ArrayList(Day),
    /// Today, in days since 1970-01-01 local time; kept current by the plugin.
    today: i32 = 0,
    /// Up to when time has been counted, on the editor's clock; null before the first count.
    counted_ms: ?u64 = null,
    /// The editor's tallies when last seen, to count what it did since; null before then.
    seen: ?Use = null,
    changed: bool = false,
    saved_at_ms: u64 = 0,

    /// Read every person's file in `project`, telling `user`'s own from the others'. A file
    /// that can't be read counts as no work. Its sitting goes on if it was written within the
    /// idle limit of `now_real_ms` (milliseconds since 1970-01-01 UTC).
    // ponytail: two editors open on one project as one user each write their own record, so one's work is lost; merge on save if that happens.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, user: []const u8, now_real_ms: i64) !Tracker {
        const path = try fileOf(gpa, user);
        errdefer gpa.free(path);
        var self = Tracker{ .gpa = gpa, .arena = .init(gpa), .path = path, .others = &.{}, .mine = .{}, .my_days = .empty };
        errdefer self.arena.deinit();
        errdefer self.my_days.deinit(gpa);
        var dir = project.openDir(io, folder, .{ .iterate = true }) catch return self;
        defer dir.close(io);
        const arena = self.arena.allocator();
        var others: std.ArrayList(Person) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
            const record = readFile(arena, io, dir, entry.name) orelse continue;
            if (std.mem.eql(u8, entry.name, std.fs.path.basename(path))) {
                self.mine = record;
                try self.my_days.appendSlice(gpa, record.days);
            } else try others.append(arena, .{ .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".zon".len]), .record = record, .is_me = false });
        }
        self.others = others.items;
        self.mine.days = self.my_days.items;
        if (now_real_ms - self.mine.sitting.written_at_ms >= idle_limit_ms) self.mine.sitting = .{};
        return self;
    }

    pub fn deinit(self: *Tracker) void {
        self.my_days.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.free(self.path);
    }

    /// Follow the editor's `use` as of `now_ms` on its clock: add the time worked since last
    /// counted (up to the idle limit after the last input, and not after focus left) to today,
    /// and what it did since.
    pub fn follow(self: *Tracker, use: Use, now_ms: u64) void {
        self.countTallies(use);
        const counted_ms = self.counted_ms orelse now_ms;
        self.counted_ms = @max(counted_ms, now_ms);
        const last_input_ms = now_ms -| use.idle_ms;
        // After a gap too long to have been watched (a minimized window draws no frames), only
        // the time since the last input is known to be work.
        const from_ms = if (now_ms - counted_ms > idle_limit_ms) @max(counted_ms, last_input_ms) else counted_ms;
        var until_ms = @min(now_ms, last_input_ms + idle_limit_ms);
        if (use.unfocused_ms) |away_ms| until_ms = @min(until_ms, now_ms -| away_ms);
        if (until_ms <= from_ms) return;
        const worked_ms = until_ms - from_ms;
        self.addToToday(worked_ms) catch |err| return std.log.warn("cannot count the time worked: {t}", .{err});
        // The first time worked makes this sitting a session.
        if (self.mine.sitting.worked_ms == 0) self.mine.sessions += 1;
        self.mine.sitting.worked_ms += worked_ms;
        self.mine.sitting.stopwatch_ms += worked_ms;
        self.mine.worked_ms += worked_ms;
        self.mine.longest_session_ms = @max(self.mine.longest_session_ms, self.mine.sitting.worked_ms);
        self.changed = true;
    }

    /// Saves, plays and builds since the editor's tallies were last seen. The first sight only
    /// sets where counting starts, so a hot reload doesn't count them again.
    fn countTallies(self: *Tracker, use: Use) void {
        defer self.seen = use;
        const seen = self.seen orelse return;
        inline for (.{ "saves", "plays", "builds" }) |name| {
            const done = @field(use, name) -| @field(seen, name);
            if (done > 0) {
                @field(self.mine, name) += done;
                self.changed = true;
            }
        }
    }

    fn addToToday(self: *Tracker, worked_ms: u64) !void {
        // A clock set back adds to the latest day rather than unsorting them.
        if (self.my_days.items.len > 0 and self.my_days.items[self.my_days.items.len - 1].day >= self.today) {
            self.my_days.items[self.my_days.items.len - 1].worked_ms += worked_ms;
        } else try self.my_days.append(self.gpa, .{ .day = self.today, .worked_ms = worked_ms });
        self.mine.days = self.my_days.items;
    }

    pub fn resetStopwatch(self: *Tracker) void {
        self.mine.sitting.stopwatch_ms = 0;
        self.changed = true;
    }

    /// Everyone who has worked on the project, this person first. Allocated from `arena`.
    pub fn people(self: *const Tracker, arena: std.mem.Allocator) ![]Person {
        const all = try arena.alloc(Person, self.others.len + 1);
        all[0] = .{ .name = std.fs.path.stem(self.path), .record = self.mine, .is_me = true };
        @memcpy(all[1..], self.others);
        return all;
    }

    /// Write this person's record if it changed and the last write is a minute old, at
    /// `now_ms` on the editor's clock. Failures are logged: the record is not part of editing.
    pub fn keep(self: *Tracker, io: std.Io, project: std.Io.Dir, now_ms: u64, now_real_ms: i64) void {
        if (!self.changed or now_ms -| self.saved_at_ms < save_interval_ms) return;
        self.save(io, project, now_real_ms);
        self.saved_at_ms = now_ms;
    }

    /// Write this person's record now, if it changed: on a hot reload or when the editor closes.
    pub fn save(self: *Tracker, io: std.Io, project: std.Io.Dir, now_real_ms: i64) void {
        if (!self.changed) return;
        self.mine.sitting.written_at_ms = now_real_ms;
        var text: std.Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        std.zon.stringify.serialize(self.mine, .{}, &text.writer) catch |err| return std.log.warn("cannot keep the time worked: {t}", .{err});
        project.createDirPath(io, folder) catch {};
        project.writeFile(io, .{ .sub_path = self.path, .data = text.written() }) catch |err| return std.log.warn("cannot keep the time worked in {s}: {t}", .{ self.path, err });
        self.changed = false;
    }
};

/// Who is working: the system's user name, or "someone" without one.
pub fn userName() []const u8 {
    const name = std.c.getenv("USER") orelse std.c.getenv("USERNAME") orelse return "someone";
    return std.mem.span(name);
}

/// `user`'s file, with anything a file name can't hold made `_`. Caller-owned.
fn fileOf(gpa: std.mem.Allocator, user: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, folder ++ "/{s}.zon", .{if (user.len == 0) "someone" else user});
    for (path[folder.len + 1 .. path.len - ".zon".len]) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '_' and c.* != '.') c.* = '_';
    }
    return path;
}

/// The record in `name`, allocated from `arena`; null for one that can't be read.
fn readFile(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ?Record {
    const text = dir.readFileAllocOptions(io, name, arena, .limited(4 << 20), .of(u8), 0) catch return null;
    return zon_file.parse(Record, arena, text, .{ .ignore_unknown_fields = true }) catch null;
}

/// `ms` as hours and minutes, "3h 05m", or minutes alone under an hour, "12m".
pub fn formatTotal(buffer: []u8, ms: u64) []const u8 {
    const minutes = ms / std.time.ms_per_min;
    if (minutes < 60) return std.fmt.bufPrint(buffer, "{d}m", .{minutes}) catch "";
    return std.fmt.bufPrint(buffer, "{d}h {d:0>2}m", .{ minutes / 60, minutes % 60 }) catch "";
}

/// `ms` as a stopwatch reads, "1:02:03".
pub fn formatClock(buffer: []u8, ms: u64) []const u8 {
    const seconds = ms / std.time.ms_per_s;
    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{ seconds / 3600, seconds / 60 % 60, seconds % 60 }) catch "";
}

fn useAfter(idle_ms: u64, unfocused_ms: ?u64) Use {
    return .{ .idle_ms = idle_ms, .unfocused_ms = unfocused_ms, .saves = 0, .plays = 0, .builds = 0 };
}

test "time counts while in use, and stops when idle or unfocused" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    try tmp.dir.createDirPath(io, folder);
    try tmp.dir.writeFile(io, .{ .sub_path = folder ++ "/alex.zon", .data = ".{ .worked_ms = 60000 }" });

    var tracker = try Tracker.load(gpa, io, tmp.dir, "sam", 0);
    defer tracker.deinit();
    tracker.today = 100;
    // The first sight only starts the count; a minute of use, then an hour idle: five minutes of that count.
    tracker.follow(useAfter(0, null), 1000);
    tracker.follow(useAfter(0, null), 61_000);
    tracker.follow(useAfter(std.time.ms_per_hour, null), 61_000 + std.time.ms_per_hour);
    try std.testing.expectEqual(60_000 + idle_limit_ms, tracker.mine.worked_ms);
    // Back after a long unwatched gap, then focus left 50 seconds into a minute of use: only
    // those 50 count.
    tracker.follow(useAfter(0, null), 10_000_000);
    tracker.follow(useAfter(0, 10_000), 10_060_000);
    try std.testing.expectEqual(110_000 + idle_limit_ms, tracker.mine.worked_ms);
    try std.testing.expectEqual(1, tracker.others.len);
    try std.testing.expectEqual(60_000, tracker.others[0].record.worked_ms);
}

test "the record keeps its days, sessions and tallies, and a reload goes on with its sitting" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    var first = try Tracker.load(gpa, io, tmp.dir, "sam", 0);
    defer first.deinit();
    first.today = 100;
    first.follow(.{ .idle_ms = 0, .unfocused_ms = null, .saves = 4, .plays = 0, .builds = 0 }, 0);
    first.follow(.{ .idle_ms = 0, .unfocused_ms = null, .saves = 5, .plays = 0, .builds = 0 }, 60_000);
    // Past midnight, the same sitting goes on into the next day.
    first.today = 101;
    first.follow(.{ .idle_ms = 0, .unfocused_ms = null, .saves = 5, .plays = 0, .builds = 0 }, 120_000);
    first.save(io, tmp.dir, 1_000_000);

    // Reloaded a few seconds later: the same sitting, and the editor's tallies not counted again.
    var second = try Tracker.load(gpa, io, tmp.dir, "sam", 1_003_000);
    defer second.deinit();
    try std.testing.expectEqualSlices(Day, &.{ .{ .day = 100, .worked_ms = 60_000 }, .{ .day = 101, .worked_ms = 60_000 } }, second.mine.days);
    try std.testing.expectEqual(1, second.mine.saves);
    second.today = 101;
    second.follow(.{ .idle_ms = 0, .unfocused_ms = null, .saves = 5, .plays = 0, .builds = 0 }, 200_000);
    second.follow(.{ .idle_ms = 0, .unfocused_ms = null, .saves = 5, .plays = 0, .builds = 0 }, 230_000);
    try std.testing.expectEqual(1, second.mine.sessions);
    try std.testing.expectEqual(1, second.mine.saves);
    try std.testing.expectEqual(150_000, second.mine.sitting.stopwatch_ms);
    try std.testing.expectEqual(150_000, second.mine.longest_session_ms);

    // Opened again an hour later: a new sitting.
    second.save(io, tmp.dir, 1_100_000);
    var third = try Tracker.load(gpa, io, tmp.dir, "sam", 1_100_000 + std.time.ms_per_hour);
    defer third.deinit();
    try std.testing.expectEqual(0, third.mine.sitting.worked_ms);
    third.today = 102;
    third.follow(useAfter(0, null), 0);
    third.follow(useAfter(0, null), 10_000);
    try std.testing.expectEqual(2, third.mine.sessions);
}

test "a user's file name holds only safe characters" {
    const path = try fileOf(std.testing.allocator, "DOMAIN\\Jo Smith");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(folder ++ "/DOMAIN_Jo_Smith.zon", path);
}

test "times read as totals and as a stopwatch" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12m", formatTotal(&buffer, 12 * std.time.ms_per_min + 59_000));
    try std.testing.expectEqualStrings("3h 05m", formatTotal(&buffer, 185 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("1:02:03", formatClock(&buffer, 3_723_000));
}
