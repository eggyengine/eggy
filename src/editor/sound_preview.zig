//! The Asset Preview panel's sound player: the sound selected in Assets drawn as its waveform,
//! the part played lit, to click or drag on to play from there, with the time, Play and Pause,
//! Stop and Loop under it.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const page_style = @import("page_style.zig");

/// How many stretches of the sound its waveform is read in; drawn bars take the loudest of theirs.
const peak_count = 256;
const waveform_height: f32 = 72;

/// What `build` reads from, borrowed for the call.
pub const Request = struct {
    /// The sound's asset key.
    key: []const u8,
    /// The Asset Preview's file `version`: a new one is another file (or the file changed).
    version: u64,
    app: *eggy.App,
};

/// What a sound file holds, as decoding it found.
pub const Info = struct {
    duration_s: f32,
    channels: u32,
    sample_rate_hz: u32,
};

pub const SoundPreview = struct {
    /// The file read, by `Request.version`, and what it held; null `info`: it couldn't be decoded.
    read_version: ?u64 = null,
    info: ?Info = null,
    peaks: [peak_count]f32 = @splat(0),
    /// The voice playing it; paused by Pause, ended by Stop or at its end.
    voice: ?eggy.audio.Voice = null,
    paused: bool = false,
    looping: bool = false,
    /// Where play starts from while nothing plays, in seconds.
    cursor_s: f32 = 0,

    /// The sound's length, channels and rate, read the first time it is asked for.
    pub fn infoOf(self: *SoundPreview, gpa: std.mem.Allocator, request: Request) ?Info {
        if (self.read_version != request.version) self.analyse(gpa, request);
        return self.info;
    }

    /// Draw the player. Stops what played when `request` names another file.
    pub fn build(self: *SoundPreview, gpa: std.mem.Allocator, context: *ui.Context, request: Request) void {
        if (self.read_version != request.version) {
            self.stop(request.app);
            self.analyse(gpa, request);
        }
        const info = self.info orelse {
            context.muted("This sound couldn't be decoded: export it again as WAV or Ogg Vorbis.");
            page_style.smallText(context, 13);
            if (context.last_added) |text| text.paint_kind.text.wrap = true;
            return;
        };
        const audio = request.app.audio();
        if (self.voice) |voice| if (!audio.isPlaying(voice)) self.stop(request.app);
        const at_s = if (self.voice) |voice| audio.position(voice) orelse self.cursor_s else self.cursor_s;

        // The waveform: pressing on it grabs it, and letting go plays from where it was let go.
        const id = context.idFor("##sound waveform");
        const bounds = context.last_bounds.get(id);
        const pointer_over = if (bounds) |target| target.rect.contains(context.pointer.x, context.pointer.y) else false;
        if (context.pressed_down and pointer_over) context.active = id;
        const dragged_s: ?f32 = if ((context.active == id or context.released == id) and bounds != null) blk: {
            const rect = bounds.?.rect;
            break :blk std.math.clamp((context.pointer.x - rect.x) / @max(1, rect.w), 0, 1) * info.duration_s;
        } else null;
        if (context.released == id) self.playFrom(request, dragged_s.?);
        const shown_s = dragged_s orelse at_s;
        const progress = if (info.duration_s > 0) std.math.clamp(shown_s / info.duration_s, 0, 1) else 0;
        self.waveform(context, id, progress, self.voice != null or shown_s > 0);

        // The time played and the whole length, at the waveform's two ends.
        const arena = context.builder().allocator;
        context.begin(.row);
        context.muted(clockText(arena, shown_s));
        page_style.smallText(context, 12);
        page_style.restyle(context, .{ .grow = 1 });
        context.muted(clockText(arena, info.duration_s));
        page_style.smallText(context, 12);
        page_style.endRow(context);

        context.begin(.row);
        const playing = self.voice != null and !self.paused;
        if (context.buttonVariant(if (playing) "Pause##sound play" else "Play##sound play", if (playing) .outline else .default)) {
            if (playing) {
                audio.pause(self.voice.?) catch {};
                self.paused = true;
            } else if (self.voice) |voice| {
                audio.unpause(voice) catch {};
                self.paused = false;
            } else self.playFrom(request, self.cursor_s);
        }
        if (context.buttonVariant("Stop##sound stop", .outline)) self.stop(request.app);
        if (context.toggle("Loop##sound loop", &self.looping)) if (self.voice) |voice| {
            audio.setRepeat(voice, if (self.looping) .loop else .once) catch {};
        };
        page_style.endRow(context);
    }

    /// End what plays and go back to the start.
    pub fn stop(self: *SoundPreview, app: *eggy.App) void {
        if (self.voice) |voice| app.audio().stop(voice) catch {};
        self.voice = null;
        self.paused = false;
        self.cursor_s = 0;
    }

    /// Play the sound from `start_s`, unplaced through the master bus, ending what played.
    fn playFrom(self: *SoundPreview, request: Request, start_s: f32) void {
        const audio = request.app.audio();
        if (self.voice) |voice| audio.stop(voice) catch {};
        self.voice = null;
        self.paused = false;
        self.cursor_s = start_s;
        const file = eggy.AssetRef(.audio).parse(request.key) catch return;
        const options: eggy.audio.PlayOptions = .{ .bus = .master, .repeat = if (self.looping) .loop else .once, .start_s = start_s };
        self.voice = audio.play(file, options) catch |err| return std.log.err("cannot play the sound: {t}", .{err});
    }

    /// Decode the file whole for its length and waveform.
    fn analyse(self: *SoundPreview, gpa: std.mem.Allocator, request: Request) void {
        self.read_version = request.version;
        self.info = null;
        const file = eggy.AssetRef(.audio).parse(request.key) catch return;
        const bytes = request.app.resources().read(gpa, file) catch |err| return std.log.err("cannot read the sound: {t}", .{err});
        defer gpa.free(bytes);
        const found = eggy.audio.analyse(bytes, &self.peaks) catch return;
        if (found.sample_rate == 0) return;
        self.info = .{
            .duration_s = @as(f32, @floatFromInt(found.frames)) / @as(f32, @floatFromInt(found.sample_rate)),
            .channels = found.channels,
            .sample_rate_hz = found.sample_rate,
        };
    }

    /// The waveform across the panel, lit up to `progress` (0 to 1), with a line there when `head`.
    fn waveform(self: *const SoundPreview, context: *ui.Context, id: u32, progress: f32, head: bool) void {
        const shown = context.builder().allocator.create(Waveform) catch return;
        shown.* = .{ .peaks = &self.peaks, .progress = progress, .head = head };
        const element = context.builder().node(id, .{ .width = context.contentWidth(), .height = waveform_height }, .{ .custom = .{ .context = shown, .draw = drawWaveform } }, &.{}) catch return;
        element.cursor = .pointer;
        element.accessibility = .{ .role = .slider, .label = "Position", .numeric_value = progress };
        context.element(element);
    }
};

/// What `drawWaveform` draws, for one frame.
const Waveform = struct {
    peaks: *const [peak_count]f32,
    progress: f32,
    head: bool,
};

/// Bars mirrored about the middle, one every 3 points, each as loud as the loudest stretch under
/// it: played ones in the theme's primary colour, the rest muted.
fn drawWaveform(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const shown: *const Waveform = @ptrCast(@alignCast(context));
    try c.roundRect(r, c.theme.muted, 6);
    const inner = ui.Rect{ .x = r.x + 8, .y = r.y + 8, .w = @max(0, r.w - 16), .h = @max(0, r.h - 16) };
    const bar_count: usize = std.math.clamp(@as(usize, @intFromFloat(inner.w / 3)), 16, peak_count);
    const step = inner.w / @as(f32, @floatFromInt(bar_count));
    for (0..bar_count) |bar| {
        var loudest: f32 = 0;
        for (bar * peak_count / bar_count..@max(bar * peak_count / bar_count + 1, (bar + 1) * peak_count / bar_count)) |peak| loudest = @max(loudest, shown.peaks[peak]);
        const x = inner.x + @as(f32, @floatFromInt(bar)) * step;
        const height = @max(2, loudest * inner.h);
        const played = x + step / 2 <= inner.x + shown.progress * inner.w;
        try c.roundRect(.{ .x = x, .y = inner.y + (inner.h - height) / 2, .w = @max(1, step - 1), .h = height }, if (played) c.theme.primary else c.theme.muted_foreground, 1);
    }
    if (shown.head) try c.rect(.{ .x = inner.x + shown.progress * inner.w - 1, .y = r.y + 4, .w = 2, .h = r.h - 8 }, c.theme.foreground);
}

/// `seconds` as a clock to the tenth: "1:05.3".
fn clockText(arena: std.mem.Allocator, seconds: f32) []const u8 {
    const tenths: u64 = @intFromFloat(@round(@max(0, seconds) * 10));
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}.{d}", .{ tenths / 600, tenths / 10 % 60, tenths % 10 }) catch "";
}

test "the clock shows minutes, seconds and tenths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("0:00.0", clockText(arena.allocator(), 0));
    try std.testing.expectEqualStrings("1:05.3", clockText(arena.allocator(), 65.27));
    try std.testing.expectEqualStrings("0:01.8", clockText(arena.allocator(), 1.8));
}
