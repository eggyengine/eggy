//! The clutch: the last weeks of work drawn as a dot for each day, a column a week, Monday at
//! the top. A day's dot grows with the time worked on it, yolk coloured; a day without work is
//! a speck, and today is ringed.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const Day = @import("record.zig").Day;

/// The widest a day's cell is drawn, in points.
const max_cell = 18;
/// The fewest and most weeks shown; between them, as many as fit the width.
const min_weeks = 8;
const max_weeks = 26;

const Clutch = struct {
    /// Time worked in each cell, a week's seven after another, oldest week first; null for
    /// days still to come.
    cells: []const ?u64,
    today_cell: usize,
    weeks: usize,
    busiest_ms: u64,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Clutch = @ptrCast(@alignCast(context));
        const cell = @min(max_cell, r.w / @as(f32, @floatFromInt(self.weeks)));
        for (self.cells, 0..) |worked, i| {
            const ms = worked orelse continue;
            const centre_x = r.x + (@as(f32, @floatFromInt(i / 7)) + 0.5) * cell;
            const centre_y = r.y + (@as(f32, @floatFromInt(i % 7)) + 0.5) * cell;
            // By area, so a day twice as long looks twice as big.
            const share = if (self.busiest_ms == 0) 0 else @sqrt(@as(f32, @floatFromInt(ms)) / @as(f32, @floatFromInt(self.busiest_ms)));
            const radius = if (ms == 0) 1.5 else @max(2.5, cell * 0.42 * share);
            const dot = ui.Rect{ .x = centre_x - radius, .y = centre_y - radius, .w = radius * 2, .h = radius * 2 };
            try c.roundRect(dot, if (ms == 0) c.theme.border else c.theme.primary, radius);
            if (i == self.today_cell) {
                const ring_radius = cell * 0.48;
                try c.roundRectStroke(.{ .x = centre_x - ring_radius, .y = centre_y - ring_radius, .w = ring_radius * 2, .h = ring_radius * 2 }, c.theme.foreground, ring_radius, 1);
            }
        }
    }
};

/// How many weeks fit `width` points.
pub fn weeksIn(width: f32) usize {
    const fitting: usize = @intFromFloat(@max(0, width / max_cell));
    return std.math.clamp(fitting, min_weeks, max_weeks);
}

/// The clutch for `days` (oldest first) up to `today`, `width` points wide.
pub fn element(b: L.Builder, days: []const Day, today: i32, width: f32) !*L.Element {
    const weeks = weeksIn(width);
    const look = try b.allocator.create(Clutch);
    look.* = try layOut(b.allocator, days, today, weeks);
    const cell = @min(max_cell, width / @as(f32, @floatFromInt(weeks)));
    const drawn = try b.node(0, .{ .width = cell * @as(f32, @floatFromInt(weeks)), .height = cell * 7 }, .{ .custom = .{ .context = look, .draw = Clutch.draw } }, &.{});
    drawn.accessibility = .{ .role = .image, .label = "Days worked over the last weeks" };
    return drawn;
}

/// Monday 0 to Sunday 6; 1970-01-01 was a Thursday.
fn weekday(day: i32) usize {
    return @intCast(@mod(day + 3, 7));
}

fn layOut(arena: std.mem.Allocator, days: []const Day, today: i32, weeks: usize) !Clutch {
    const cells = try arena.alloc(?u64, weeks * 7);
    const first = today - @as(i32, @intCast(weekday(today) + (weeks - 1) * 7));
    for (cells, 0..) |*cell, i| cell.* = if (first + @as(i32, @intCast(i)) <= today) 0 else null;
    var busiest_ms: u64 = 0;
    for (days) |day| {
        if (day.day < first or day.day > today) continue;
        const i: usize = @intCast(day.day - first);
        cells[i] = cells[i].? + day.worked_ms;
        busiest_ms = @max(busiest_ms, cells[i].?);
    }
    return .{ .cells = cells, .today_cell = @intCast(today - first), .weeks = weeks, .busiest_ms = busiest_ms };
}
