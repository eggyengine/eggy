//! The splash screen's window, in a process of its own so it keeps moving while the editor
//! works: the project and Eggy's version over each step the editor says it has begun, until the
//! editor is on screen, or the failure it shows is closed.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const c = eggy.sdl_adapter.sdl.c;
const icon = @import("../icon.zig");
const page_style = @import("../page_style.zig");
const message = @import("message.zig");
const motion = @import("motion.zig");
const canvas_zig = @import("canvas.zig");
const Canvas = canvas_zig.Canvas;
const Image = canvas_zig.Image;
const Rect = canvas_zig.Rect;
const Color = canvas_zig.Color;
const hex = canvas_zig.hex;
const fade = canvas_zig.fade;
const log = std.log.scoped(.splash);

/// The window's size, and the room around what it shows, in logical pixels.
const width = 480;
const height = 280;
const padding = 28;

/// Where things go: the egg's tile at the top left with the project beside it, and the step
/// over the bar and what the step is working on at the bottom.
const layout = struct {
    const tile: Rect = .{ .x = padding, .y = padding, .w = 72, .h = 72 };
    const egg: Rect = .{ .x = padding + 8, .y = padding + 8, .w = 56, .h = 56 };
    const title_x = padding + 72 + 18;
    const right = width - padding;
    const detail_y = height - padding - 15;
    const bar_y = detail_y - 10 - 4;
    const label_y = bar_y - 10 - 18;
    const row = 18;
    const segment_gap = 4;
    const button_h = 28;
};

const palette = struct {
    const ground = hex(0x15120F);
    const edge = hex(0x2E2823);
    const tile = hex(0x1E1A16);
    const text = hex(0xF3EEE6);
    const muted = hex(0xA69C8F);
    const faint = hex(0x8E8478);
    const track = hex(0x3A332C);
    const accent = hex(0xF5BE4A);
    const sparkle = hex(0xF5C969);
    const ready = hex(0xFFD98A);
    const alarm = hex(0xB5523C);
    const failure = hex(0xF2937A);
    const error_text = hex(0xCFC6BA);
    const on_accent = hex(0x1A140C);
    const shimmer: Color = .{ 1, 0.957, 0.839, 0.85 };
};

/// The sparkles around the egg: where in its tile, how big, and how late each starts.
const sparkles = [_]struct { x: f32, y: f32, size: f32, delay_s: f32 }{
    .{ .x = 8, .y = 10, .size = 4, .delay_s = 0 },
    .{ .x = 61, .y = 18, .size = 4, .delay_s = 0.6 },
    .{ .x = 57, .y = 60, .size = 3, .delay_s = 1.2 },
};

/// How long "Ready" shows before the splash goes.
const ready_s = 0.4;

/// The crack across the failed egg, as points in the 32-pixel icon.
const crack_points = [_][2]f32{ .{ 10, 9 }, .{ 13, 12 }, .{ 11, 14 }, .{ 15, 16 }, .{ 13, 19 } };

/// What the editor has said, left by the thread that reads its pipe for the window to show.
const Inbox = struct {
    gpa: std.mem.Allocator,
    lock: std.atomic.Mutex = .unlocked,
    step: message.Step = .graphics,
    detail: [256]u8 = undefined,
    detail_len: usize = 0,
    /// Bumped with each detail, so the window knows to draw it again.
    detail_count: u32 = 0,
    done: bool = false,
    /// Owned; the first failure the editor sent.
    failure: ?[]u8 = null,
    /// The editor closed the pipe.
    ended: bool = false,

    /// Read the editor's lines until it closes the pipe. Runs on its own thread.
    fn read(self: *Inbox, io: std.Io) void {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
        while (reader.interface.takeDelimiter('\n') catch null) |line| {
            const got = message.parse(line) orelse continue;
            self.acquire();
            defer self.lock.unlock();
            switch (got) {
                .step => |step| self.step = step,
                .detail => |text| {
                    self.detail_len = @min(text.len, self.detail.len);
                    @memcpy(self.detail[0..self.detail_len], text[0..self.detail_len]);
                    self.detail_count +%= 1;
                },
                .done => self.done = true,
                .fail => |text| if (self.failure == null) {
                    self.failure = self.gpa.dupe(u8, text) catch null;
                },
            }
        }
        self.acquire();
        defer self.lock.unlock();
        self.ended = true;
    }

    fn acquire(self: *Inbox) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

/// What the window draws from, copied out of the inbox each frame.
const Heard = struct {
    step: message.Step,
    detail: [256]u8,
    detail_len: usize,
    detail_count: u32,
    done: bool,
    failure: ?[]const u8,
    ended: bool,
};

// The inbox outlives `run`: its reading thread can't be stopped while it waits on the pipe.
var inbox: Inbox = undefined;

/// Show the splash screen for `project_name`, made with Eggy `version`, until the editor is done
/// with it. SDL and window failures propagate.
///
/// ```zig
/// try screen.run(gpa, io, "garden", "0.1.0");
/// ```
pub fn run(gpa: std.mem.Allocator, io: std.Io, project_name: []const u8, version: []const u8) !void {
    inbox = .{ .gpa = gpa };
    const reader = try std.Thread.spawn(.{}, Inbox.read, .{ &inbox, io });
    reader.detach();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlError;
    defer c.SDL_Quit();
    const flags = c.SDL_WINDOW_BORDERLESS | c.SDL_WINDOW_TRANSPARENT | c.SDL_WINDOW_ALWAYS_ON_TOP | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = c.SDL_CreateWindow("Eggy", width, height, flags) orelse return error.SdlError;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlError;
    defer c.SDL_DestroyRenderer(renderer);
    // Without vsync, a frame every 16 ms instead.
    const vsync = c.SDL_SetRenderVSync(renderer, 1);
    const density = @max(1, c.SDL_GetWindowPixelDensity(window));
    _ = c.SDL_SetRenderScale(renderer, density, density);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    var screen = try Screen.init(gpa, .{ .gpa = gpa, .renderer = renderer, .density = density }, project_name, version);
    defer screen.deinit();
    const started = c.SDL_GetTicksNS();
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) if (screen.handle(&event) == .close) return;
        const heard = hear();
        const now_s: f32 = @floatCast(@as(f64, @floatFromInt(c.SDL_GetTicksNS() - started)) / std.time.ns_per_s);
        if (screen.follow(heard, now_s) == .close) return;
        _ = c.SDL_SetRenderDrawColorFloat(renderer, 0, 0, 0, 0);
        _ = c.SDL_RenderClear(renderer);
        screen.draw(now_s);
        _ = c.SDL_RenderPresent(renderer);
        if (!vsync) c.SDL_Delay(16);
    }
}

fn hear() Heard {
    inbox.acquire();
    defer inbox.lock.unlock();
    return .{
        .step = inbox.step,
        .detail = inbox.detail,
        .detail_len = inbox.detail_len,
        .detail_count = inbox.detail_count,
        .done = inbox.done,
        .failure = inbox.failure,
        .ended = inbox.ended,
    };
}

const Button = enum { copy, close };

const Screen = struct {
    gpa: std.mem.Allocator,
    canvas: Canvas,
    font: *ui.Font,
    mono: *ui.Font,
    card_fill: Image,
    card_ring: Image,
    tile_fill: Image,
    tile_ring: Image,
    glow: Image,
    egg: Image,
    name: Image,
    version: Image,
    /// Each step's label, then "Ready".
    labels: [message.step_count + 1]Image,
    /// "1 of 6" and on.
    counters: [message.step_count]Image,
    detail: ?Image = null,
    detail_count: u32 = 0,

    /// The step being shown, and when it began.
    step: message.Step = .graphics,
    step_began_s: f32 = 0,
    /// Where the label had rolled to when the step began, as a label index.
    rolled_from: f32 = 0,
    done_at_s: ?f32 = null,
    failure: ?Failure = null,
    hover: ?Button = null,
    pressed: ?Button = null,
    pointer: ?*c.SDL_Cursor,
    arrow: ?*c.SDL_Cursor,

    fn init(gpa: std.mem.Allocator, canvas: Canvas, project_name: []const u8, version: []const u8) !Screen {
        // Fonts that rasterize as they draw: baking every size first would hold the window back.
        const font = try gpa.create(ui.Font);
        errdefer gpa.destroy(font);
        font.* = try ui.Font.initBaking(gpa, ui.default_font, .on_draw);
        errdefer font.deinit();
        const mono = try gpa.create(ui.Font);
        errdefer gpa.destroy(mono);
        mono.* = try ui.Font.initBaking(gpa, @embedFile("mono_font"), .on_draw);
        errdefer mono.deinit();
        font.dpi_scale = canvas.density;
        mono.dpi_scale = canvas.density;

        const egg_pixels = try icon.pixels();
        var labels: [message.step_count + 1]Image = undefined;
        var counters: [message.step_count]Image = undefined;
        for (std.enums.values(message.Step), 0..) |each, i| {
            labels[i] = try canvas.text(font, each.label(), 13);
            var buffer: [16]u8 = undefined;
            counters[i] = try canvas.text(font, try std.fmt.bufPrint(&buffer, "{d} of {d}", .{ i + 1, message.step_count }), 12);
        }
        labels[message.step_count] = try canvas.text(font, "Ready", 13);
        var version_buffer: [64]u8 = undefined;
        return .{
            .gpa = gpa,
            .canvas = canvas,
            .font = font,
            .mono = mono,
            .card_fill = try canvas.rounded(width, height, 10, .fill),
            .card_ring = try canvas.rounded(width, height, 10, .{ .ring = 1 }),
            .tile_fill = try canvas.rounded(72, 72, 14, .fill),
            .tile_ring = try canvas.rounded(72, 72, 14, .{ .ring = 1 }),
            .glow = try canvas.rounded(72 + 4, 72 + 4, 16, .{ .glow = 22 }),
            .egg = try canvas.image(std.mem.asBytes(&egg_pixels), icon.size, icon.size, .nearest),
            .name = try canvas.text(font, project_name, 20),
            .version = try canvas.text(font, std.fmt.bufPrint(&version_buffer, "Eggy {s}", .{version}) catch "Eggy", 12),
            .labels = labels,
            .counters = counters,
            .pointer = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
            .arrow = c.SDL_GetDefaultCursor(),
        };
    }

    fn deinit(self: *Screen) void {
        for ([_]Image{ self.card_fill, self.card_ring, self.tile_fill, self.tile_ring, self.glow, self.egg, self.name, self.version }) |made| made.deinit();
        for (self.labels) |made| made.deinit();
        for (self.counters) |made| made.deinit();
        if (self.detail) |made| made.deinit();
        if (self.failure) |*failure| failure.deinit();
        if (self.pointer) |cursor| c.SDL_DestroyCursor(cursor);
        self.mono.deinit();
        self.gpa.destroy(self.mono);
        self.font.deinit();
        self.gpa.destroy(self.font);
    }

    /// Take in what the editor has said since the last frame.
    fn follow(self: *Screen, heard: Heard, now_s: f32) enum { show, close } {
        if (heard.failure) |text| if (self.failure == null) {
            self.failure = Failure.init(self, text, now_s) catch |err| {
                log.err("cannot show the failure: {t}", .{err});
                return .close;
            };
        };
        if (self.failure != null) return .show;
        if (heard.done and self.done_at_s == null) {
            self.rolled_from = self.labelAt(now_s);
            self.done_at_s = now_s;
            self.setDetail("Opening the editor");
        }
        if (self.done_at_s) |done_at| return if (now_s - done_at > ready_s) .close else .show;
        // The editor went without saying it was done or why: nothing is left to show.
        if (heard.ended) return .close;
        if (heard.step != self.step) {
            self.rolled_from = self.labelAt(now_s);
            self.step = heard.step;
            self.step_began_s = now_s;
        }
        if (heard.detail_count != self.detail_count) {
            self.detail_count = heard.detail_count;
            self.setDetail(heard.detail[0..heard.detail_len]);
        }
        return .show;
    }

    fn setDetail(self: *Screen, text: []const u8) void {
        if (self.detail) |made| made.deinit();
        self.detail = null;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const shown = page_style.fitText(arena.allocator(), self.mono, text, 11, layout.right - padding);
        self.detail = self.canvas.text(self.mono, shown, 11) catch |err| blk: {
            log.debug("cannot draw {s}: {t}", .{ text, err });
            break :blk null;
        };
    }

    /// Which label shows at `now_s`, as an index: between two while rolling.
    fn labelAt(self: *const Screen, now_s: f32) f32 {
        const target: f32 = if (self.done_at_s != null) message.step_count else @floatFromInt(@backingInt(self.step));
        const began = self.done_at_s orelse self.step_began_s;
        return std.math.lerp(self.rolled_from, target, motion.roll(now_s - began));
    }

    fn handle(self: *Screen, event: *const c.SDL_Event) enum { keep, close } {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return .close,
            c.SDL_EVENT_KEY_DOWN => if (self.failure != null and switch (event.key.key) {
                c.SDLK_ESCAPE, c.SDLK_RETURN, c.SDLK_KP_ENTER => true,
                else => false,
            }) return .close,
            c.SDL_EVENT_MOUSE_MOTION => {
                const failure = &(self.failure orelse return .keep);
                const over = failure.buttonAt(event.motion.x, event.motion.y);
                if (over != self.hover) _ = c.SDL_SetCursor(if (over != null) self.pointer else self.arrow);
                self.hover = over;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (event.button.button == c.SDL_BUTTON_LEFT) {
                const failure = &(self.failure orelse return .keep);
                self.pressed = failure.buttonAt(event.button.x, event.button.y);
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => if (event.button.button == c.SDL_BUTTON_LEFT) {
                const failure = &(self.failure orelse return .keep);
                const pressed = self.pressed;
                self.pressed = null;
                if (pressed == null or pressed != failure.buttonAt(event.button.x, event.button.y)) return .keep;
                switch (pressed.?) {
                    .copy => failure.copy(),
                    .close => return .close,
                }
            },
            else => {},
        }
        return .keep;
    }

    fn draw(self: *Screen, now_s: f32) void {
        const canvas = self.canvas;
        canvas.draw(self.card_fill, 0, 0, palette.ground, null);
        canvas.draw(self.card_ring, 0, 0, palette.edge, null);
        self.drawEgg(now_s);
        canvas.draw(self.name, layout.title_x, layout.tile.y + 13, palette.text, null);
        canvas.draw(self.version, layout.title_x, layout.tile.y + 13 + 30, palette.muted, null);
        if (self.failure) |*failure| failure.draw(self) else self.drawProgress(now_s);
    }

    /// The egg in its tile: glowing with sparkles while the editor starts, cracked when it
    /// couldn't start.
    fn drawEgg(self: *Screen, now_s: f32) void {
        const canvas = self.canvas;
        const tile = layout.tile;
        const failed_at = if (self.failure) |failure| failure.shown_s else null;
        if (failed_at == null) canvas.draw(self.glow, tile.x - 2, tile.y - 2, fade(palette.accent, 0.22 * motion.glow(now_s)), null);
        canvas.draw(self.tile_fill, tile.x, tile.y, palette.tile, null);
        const border = if (failed_at) |at| canvas_zig.mix(palette.edge, palette.alarm, motion.alarm(now_s - at)) else palette.edge;
        canvas.draw(self.tile_ring, tile.x, tile.y, border, null);
        const egg = layout.egg;
        canvas.drawStretched(self.egg, egg, fade(.{ 1, 1, 1, 1 }, if (failed_at != null) 0.6 else 1));
        if (failed_at) |at| return drawCrack(canvas, egg, motion.crack(now_s - at));
        for (sparkles) |sparkle| {
            const strength = motion.twinkle(now_s, sparkle.delay_s);
            const size = sparkle.size * (0.4 + 0.6 * strength);
            const centre_x = tile.x + sparkle.x + sparkle.size / 2;
            const centre_y = tile.y + sparkle.y + sparkle.size / 2;
            canvas.fill(.{ .x = centre_x - size / 2, .y = centre_y - size / 2, .w = size, .h = size }, fade(palette.sparkle, strength));
        }
    }

    /// The step's label rolling in beside how many of how many, the bar with a segment per step,
    /// and what the step is working on.
    fn drawProgress(self: *Screen, now_s: f32) void {
        const canvas = self.canvas;
        const done = self.done_at_s != null;
        const index = @backingInt(self.step);
        const counter = self.counters[if (done) message.step_count - 1 else index];
        canvas.draw(counter, layout.right - counter.width, layout.label_y + (layout.row - counter.height) / 2, palette.muted, null);

        const row: Rect = .{ .x = padding, .y = layout.label_y, .w = layout.right - padding - counter.width - 12, .h = layout.row };
        const at = self.labelAt(now_s);
        // Labels a little apart, so none shows at the edge of the row while another is in it.
        const pitch = @max(layout.row, @ceil(self.labels[0].height)) + 2;
        for (self.labels, 0..) |label, i| {
            const y = layout.label_y + (@as(f32, @floatFromInt(i)) - at) * pitch + (layout.row - label.height) / 2;
            canvas.draw(label, padding, y, palette.text, row);
        }

        const count: f32 = message.step_count;
        const segment_w = (layout.right - padding - layout.segment_gap * (count - 1)) / count;
        for (0..message.step_count) |i| {
            const x = padding + @as(f32, @floatFromInt(i)) * (segment_w + layout.segment_gap);
            const track: Rect = .{ .x = x, .y = layout.bar_y, .w = segment_w, .h = 4 };
            canvas.fill(track, palette.track);
            const full: f32 = if (done or i < index) 1 else if (i == index) motion.fill(now_s - self.step_began_s) else 0;
            if (full == 0) continue;
            const filled: Rect = .{ .x = x, .y = layout.bar_y, .w = segment_w * full, .h = 4 };
            canvas.fill(filled, if (done) palette.ready else palette.accent);
            if (!done and i == index) canvas.band(filled, x + motion.sweep(now_s, segment_w), motion.sweep_width, palette.shimmer);
        }
        if (self.detail) |detail| canvas.draw(detail, padding, layout.detail_y, palette.faint, null);
    }
};

/// The crack across the egg drawn `amount` (0 to 1) of the way along.
fn drawCrack(canvas: Canvas, egg: Rect, amount: f32) void {
    if (amount <= 0) return;
    const scale = egg.w / icon.size;
    var points: [crack_points.len][2]f32 = undefined;
    var total: f32 = 0;
    for (&points, crack_points, 0..) |*point, art, i| {
        point.* = .{ egg.x + art[0] * scale, egg.y + art[1] * scale };
        if (i > 0) total += distance(points[i - 1], point.*);
    }
    var left = total * amount;
    for (points[1..], 1..) |to, i| {
        const from = points[i - 1];
        const length = distance(from, to);
        const t = @min(1, left / length);
        canvas.line(from, .{ std.math.lerp(from[0], to[0], t), std.math.lerp(from[1], to[1], t) }, 1.3 * scale, palette.on_accent);
        left -= length;
        if (left <= 0) return;
    }
}

fn distance(a: [2]f32, b: [2]f32) f32 {
    return @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
}

/// Why the editor couldn't start, with buttons to copy it and to close.
const Failure = struct {
    gpa: std.mem.Allocator,
    /// The whole message, for the clipboard.
    text: [:0]u8,
    title: Image,
    /// The message as it wraps in its box, cut short after `max_lines`.
    lines: [max_lines]?Image = @splat(null),
    copy_label: Image,
    close_label: Image,
    /// The box the message sits in, and the buttons' shapes.
    box_fill: Image,
    box_ring: Image,
    copy_ring: Image,
    close_fill: Image,
    shown_s: f32,

    const max_lines = 3;
    const line_h = 16.5;
    const box_padding = 8;

    fn init(screen: *Screen, text: []const u8, now_s: f32) !Failure {
        const gpa = screen.gpa;
        const canvas = screen.canvas;
        var failure: Failure = .{
            .gpa = gpa,
            .text = try gpa.dupeSentinel(u8, text, 0),
            .title = undefined,
            .copy_label = undefined,
            .close_label = undefined,
            .box_fill = undefined,
            .box_ring = undefined,
            .copy_ring = undefined,
            .close_fill = undefined,
            .shown_s = now_s,
        };
        errdefer gpa.free(failure.text);
        failure.title = try canvas.text(screen.font, "Couldn't start the editor", 13);
        errdefer failure.title.deinit();
        failure.copy_label = try canvas.text(screen.font, "Copy error", 12);
        errdefer failure.copy_label.deinit();
        failure.close_label = try canvas.text(screen.font, "Close", 12);
        errdefer failure.close_label.deinit();

        // The message as it wraps, its last line ending in "..." when there is more.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const room = layout.right - padding - 2 * 10;
        var lines: ui.Font.Lines = .{ .font = screen.mono, .value = text, .size = 11, .width = room };
        var count: usize = 0;
        while (lines.next()) |line| : (count += 1) {
            if (count == max_lines) break;
            const last = count == max_lines - 1;
            const rest = if (last) std.mem.replaceOwned(u8, arena.allocator(), text[@intFromPtr(line.ptr) - @intFromPtr(text.ptr) ..], "\n", " ") catch line else line;
            const shown = page_style.fitText(arena.allocator(), screen.mono, std.mem.trim(u8, rest, " "), 11, room);
            failure.lines[count] = canvas.text(screen.mono, shown, 11) catch null;
        }
        const box = failure.boxRect();
        failure.box_fill = try canvas.rounded(box.w, box.h, 6, .fill);
        failure.box_ring = try canvas.rounded(box.w, box.h, 6, .{ .ring = 1 });
        const copy_area = failure.buttonRect(.copy);
        failure.copy_ring = try canvas.rounded(copy_area.w, copy_area.h, 6, .{ .ring = 1 });
        const close_area = failure.buttonRect(.close);
        failure.close_fill = try canvas.rounded(close_area.w, close_area.h, 6, .fill);
        return failure;
    }

    fn deinit(self: *Failure) void {
        self.title.deinit();
        for (self.lines) |line| if (line) |made| made.deinit();
        self.copy_label.deinit();
        self.close_label.deinit();
        for ([_]Image{ self.box_fill, self.box_ring, self.copy_ring, self.close_fill }) |made| made.deinit();
        self.gpa.free(self.text);
    }

    fn lineCount(self: *const Failure) f32 {
        var count: f32 = 0;
        for (self.lines) |line| count += if (line != null) 1 else 0;
        return @max(1, count);
    }

    /// The message's box, as tall as its lines, above the buttons.
    fn boxRect(self: *const Failure) Rect {
        const box_h = self.lineCount() * line_h + 2 * box_padding;
        return .{ .x = padding, .y = height - padding - layout.button_h - 4 - 10 - box_h, .w = layout.right - padding, .h = box_h };
    }

    /// The buttons at the bottom right: Close at the edge, Copy error before it.
    fn buttonRect(self: *const Failure, button: Button) Rect {
        const y = height - padding - layout.button_h;
        const close_w = self.close_label.width + 28;
        const copy_w = self.copy_label.width + 24;
        return switch (button) {
            .close => .{ .x = layout.right - close_w, .y = y, .w = close_w, .h = layout.button_h },
            .copy => .{ .x = layout.right - close_w - 8 - copy_w, .y = y, .w = copy_w, .h = layout.button_h },
        };
    }

    fn buttonAt(self: *const Failure, x: f32, y: f32) ?Button {
        for ([_]Button{ .copy, .close }) |button| {
            const area = self.buttonRect(button);
            if (x >= area.x and x < area.x + area.w and y >= area.y and y < area.y + area.h) return button;
        }
        return null;
    }

    fn copy(self: *const Failure) void {
        // ponytail: on Wayland the copy lasts only while the splash is open, as SDL serves it from here.
        if (!c.SDL_SetClipboardText(self.text.ptr)) log.warn("cannot copy the error: {s}", .{c.SDL_GetError()});
    }

    /// The title, the message in its box, and the buttons, from the bottom up.
    fn draw(self: *const Failure, screen: *Screen) void {
        const canvas = screen.canvas;
        const box = self.boxRect();
        const title_y = box.y - 10 - layout.row;
        canvas.draw(self.title, padding, title_y + (layout.row - self.title.height) / 2, palette.failure, null);

        canvas.draw(self.box_fill, box.x, box.y, palette.tile, null);
        canvas.draw(self.box_ring, box.x, box.y, palette.edge, null);
        for (self.lines, 0..) |line, i| if (line) |made| {
            canvas.draw(made, box.x + 10, box.y + box_padding + @as(f32, @floatFromInt(i)) * line_h + (line_h - made.height) / 2, palette.error_text, null);
        };

        for ([_]Button{ .copy, .close }) |button| {
            var area = self.buttonRect(button);
            // Pressed buttons sink a little; hovered ones brighten.
            if (screen.pressed == button and screen.hover == button) {
                const inset_x = area.w * 0.025;
                const inset_y = area.h * 0.025;
                area = .{ .x = area.x + inset_x, .y = area.y + inset_y, .w = area.w - 2 * inset_x, .h = area.h - 2 * inset_y };
            }
            const lit: f32 = if (screen.hover == button) 1.12 else 1;
            const shape, const shape_color, const label, const label_color = switch (button) {
                .copy => .{ self.copy_ring, palette.track, self.copy_label, palette.text },
                .close => .{ self.close_fill, palette.accent, self.close_label, palette.on_accent },
            };
            canvas.drawStretched(shape, area, brighten(shape_color, lit));
            canvas.draw(label, area.x + (area.w - label.width) / 2, area.y + (area.h - label.height) / 2, label_color, null);
        }
    }
};

fn brighten(color: Color, by: f32) Color {
    return .{ @min(1, color[0] * by), @min(1, color[1] * by), @min(1, color[2] * by), color[3] };
}
