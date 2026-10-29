//! The Project Stats panel: how long the project has been worked on and by whom, the days it
//! was worked on as a clutch of dots, what it is made of, and how often it was saved, played
//! and built.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const Kind = eggy.assets.Kind;
const record = @import("record.zig");
const scan_zig = @import("scan.zig");
const summary_zig = @import("summary.zig");
const clutch = @import("clutch.zig");

pub const Panel = struct {
    scan: ?scan_zig.Scan = null,
    /// When the files were last counted, on the editor's clock; null before then.
    scanned_ms: ?u64 = null,

    pub const Input = struct {
        gpa: std.mem.Allocator,
        title: []const u8,
        project_dir: []const u8,
        work: *const record.Tracker,
        /// Entities in the open scene.
        entities: usize,
        /// Now, on the editor's clock.
        now_ms: u64,
    };

    /// How often the files are counted again while the panel shows.
    const rescan_ms = 10 * std.time.ms_per_s;

    /// The panel, for the project in `input`; logs what it can't show.
    pub fn build(self: *Panel, context: *ui.Context, input: Input) void {
        if (self.scanned_ms == null or input.now_ms -| self.scanned_ms.? >= rescan_ms) {
            self.scanned_ms = input.now_ms;
            self.rescan(input.gpa, input.project_dir);
        }
        self.buildPage(context, input) catch |err| std.log.err("cannot show the project's stats: {t}", .{err});
    }

    fn rescan(self: *Panel, gpa: std.mem.Allocator, project_dir: []const u8) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, project_dir, .{ .iterate = true }) catch |err| return std.log.warn("cannot count the project's files: {t}", .{err});
        defer dir.close(io);
        self.scan = scan_zig.scan(gpa, io, dir) catch |err| blk: {
            std.log.warn("cannot count the project's files: {t}", .{err});
            break :blk null;
        };
    }

    fn buildPage(self: *const Panel, context: *ui.Context, input: Input) !void {
        const b = context.builder();
        const arena = b.allocator;
        const width = context.contentWidth();
        const work = input.work;
        const people = try work.people(arena);
        const summary = try summary_zig.summarize(arena, people, work.today);

        // The project's time, large, then its days.
        context.element(try b.node(0, .{}, .{ .text = .{ .value = try total(arena, summary.worked_ms), .size = 34 } }, &.{}));
        const worked_on = if (people.len > 1)
            try std.fmt.allocPrint(arena, "worked on {s} by {d} people", .{ input.title, people.len })
        else
            try std.fmt.allocPrint(arena, "worked on {s}", .{input.title});
        context.muted(worked_on);
        context.element(try clutch.element(b, summary.days, work.today, width));
        context.muted(try std.fmt.allocPrint(arena, "The last {d} weeks, a dot for each day: the bigger the dot, the longer the day.", .{clutch.weeksIn(width)}));

        try space(context);
        try row(context, "You", try total(arena, work.mine.worked_ms));
        try row(context, "This session", try clock(arena, work.mine.sitting.stopwatch_ms));
        try row(context, "Days worked", try grouped(arena, summary.days.len));
        try row(context, "Current streak", try daysText(arena, summary.streak));
        try row(context, "Best streak", try daysText(arena, summary.best_streak));
        if (summary.busiest) |day| try row(context, "Busiest day", try std.fmt.allocPrint(arena, "{s} on {s}", .{ try total(arena, day.worked_ms), try date(arena, day.day) }));
        try row(context, "Sessions", try grouped(arena, summary.sessions));
        try row(context, "Longest session", try total(arena, summary.longest_session_ms));
        if (summary.sessions > 0) try row(context, "Average session", try total(arena, summary.worked_ms / summary.sessions));
        if (summary.days.len > 0) try row(context, "First worked on", try date(arena, summary.days[0].day));

        if (people.len > 1) {
            try space(context);
            std.mem.sort(record.Person, people, {}, struct {
                fn longer(_: void, a: record.Person, z: record.Person) bool {
                    return a.record.worked_ms > z.record.worked_ms;
                }
            }.longer);
            for (people) |person| {
                const name = if (person.is_me) try std.fmt.allocPrint(arena, "{s} (you)", .{person.name}) else person.name;
                const percent = if (summary.worked_ms == 0) 0 else (person.record.worked_ms * 100 + summary.worked_ms / 2) / summary.worked_ms;
                try row(context, name, try std.fmt.allocPrint(arena, "{s}, {d}%", .{ try total(arena, person.record.worked_ms), percent }));
            }
        }

        try space(context);
        if (self.scan) |found| {
            const code = found.kinds.get(.code);
            try row(context, "Zig code", try std.fmt.allocPrint(arena, "{s} lines in {s} files", .{ try grouped(arena, found.code_lines), try grouped(arena, code.files) }));
            for (shown_kinds) |shown| {
                const count = found.kinds.get(shown.kind);
                if (count.files == 0) continue;
                try row(context, shown.label, try std.fmt.allocPrint(arena, "{s} {s}, {s}", .{ try grouped(arena, count.files), if (count.files == 1) "file" else "files", try size(arena, count.bytes) }));
            }
            try row(context, "Project size", try size(arena, found.totalBytes()));
        } else context.muted("The project's files couldn't be counted: see the Console.");
        try row(context, "Entities in this scene", try grouped(arena, input.entities));

        try space(context);
        try row(context, "Scene saves", try grouped(arena, summary.saves));
        try row(context, "Plays", try grouped(arena, summary.plays));
        try row(context, "Builds", try grouped(arena, summary.builds));
    }
};

/// The kinds of file Contents lists, in its order, each when the project has any.
const shown_kinds = [_]struct { kind: Kind, label: []const u8 }{
    .{ .kind = .scene, .label = "Scenes" },
    .{ .kind = .ui, .label = "UI scenes" },
    .{ .kind = .model, .label = "Models" },
    .{ .kind = .image, .label = "Images" },
    .{ .kind = .audio, .label = "Sounds" },
    .{ .kind = .shader, .label = "Shaders" },
    .{ .kind = .material, .label = "Materials" },
    .{ .kind = .animation, .label = "Animation clips" },
    .{ .kind = .tilemap, .label = "Tilemaps" },
    .{ .kind = .font, .label = "Fonts" },
    .{ .kind = .input_map, .label = "Input maps" },
    .{ .kind = .text, .label = "Text files" },
    .{ .kind = .any, .label = "Other files" },
};

/// Room between the ledger's groups.
fn space(context: *ui.Context) !void {
    context.element(try context.builder().node(0, .{ .height = 10 }, .none, &.{}));
}

/// A line of the ledger: `label` at the left, muted, and `value` at the right.
fn row(context: *ui.Context, label: []const u8, value: []const u8) !void {
    const b = context.builder();
    const children = try b.allocator.dupe(*L.Element, &.{
        try b.node(0, .{}, .{ .text = .{ .value = label, .size = 12, .tone = .muted } }, &.{}),
        try b.node(0, .{ .grow = 1 }, .none, &.{}),
        try b.node(0, .{}, .{ .text = .{ .value = value, .size = 12 } }, &.{}),
    });
    context.element(try b.node(0, .{ .width = context.contentWidth(), .direction = .row, .align_items = .center, .gap = 12 }, .none, children));
}

fn total(arena: std.mem.Allocator, ms: u64) ![]const u8 {
    var buffer: [32]u8 = undefined;
    return arena.dupe(u8, record.formatTotal(&buffer, ms));
}

fn clock(arena: std.mem.Allocator, ms: u64) ![]const u8 {
    var buffer: [32]u8 = undefined;
    return arena.dupe(u8, record.formatClock(&buffer, ms));
}

fn daysText(arena: std.mem.Allocator, days: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d} {s}", .{ days, if (days == 1) "day" else "days" });
}

/// `n` with commas between its thousands, "4,210".
fn grouped(arena: std.mem.Allocator, n: u64) ![]const u8 {
    var digits: [24]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
    var out: std.ArrayList(u8) = .empty;
    for (plain, 0..) |digit, i| {
        if (i > 0 and (plain.len - i) % 3 == 0) try out.append(arena, ',');
        try out.append(arena, digit);
    }
    return out.items;
}

/// `bytes` in the largest unit under a thousand of it, "84.2 MB".
fn size(arena: std.mem.Allocator, bytes: u64) ![]const u8 {
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    if (bytes < 1000) return std.fmt.allocPrint(arena, "{d} B", .{bytes});
    var value = @as(f64, @floatFromInt(bytes)) / 1000;
    var unit: usize = 0;
    while (value >= 1000 and unit + 1 < units.len) : (unit += 1) value /= 1000;
    return std.fmt.allocPrint(arena, "{d:.1} {s}", .{ value, units[unit] });
}

/// Day `day` (since 1970-01-01) as "14 Oct 2026".
fn date(arena: std.mem.Allocator, day: i32) ![]const u8 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@max(0, day)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d} {s} {d}", .{ month_day.day_index + 1, months[@backingInt(month_day.month) - 1], year_day.year });
}

test "numbers, sizes and dates read as people write them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("4,210", try grouped(arena, 4210));
    try std.testing.expectEqualStrings("1,000,000", try grouped(arena, 1_000_000));
    try std.testing.expectEqualStrings("999", try grouped(arena, 999));
    try std.testing.expectEqualStrings("512 B", try size(arena, 512));
    try std.testing.expectEqualStrings("84.2 MB", try size(arena, 84_200_000));
    try std.testing.expectEqualStrings("1 Jan 1970", try date(arena, 0));
    try std.testing.expectEqualStrings("29 Oct 2026", try date(arena, 20755));
}

test {
    _ = scan_zig;
    _ = summary_zig;
    _ = clutch;
}
