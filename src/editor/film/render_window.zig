//! The Render window, as Blender's: the picture being rendered (or the last one) fills it, the
//! output settings and what was rendered run down its side, and how far the render has got sits
//! under the picture. The Render menu opens it and starts renders from it; `film.zig` renders.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const vit = eggy.vit;
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const page_style = @import("../page_style.zig");
const file_manager = @import("../file_manager.zig");
const film_zig = @import("film.zig");
const Film = film_zig.Film;
const restyle = page_style.restyle;
const smallText = page_style.smallText;

const sidebar_width: f32 = 250;
const gap: f32 = 14;
/// The line under the picture: the bar and how far it has got.
const status_height: f32 = 28;

/// What a render makes: a still at the playhead, the chosen cutscene, or every one in turn.
pub const What = enum { image, animation, all };

/// Where the Animation panel's playhead is, and on which entity's clips.
pub const Playhead = struct { entity: ?eggy.ecs.EntityId, time_s: f32 };

pub const RenderWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    closing: bool = false,
    /// Why the last render didn't start.
    problem: ?[]const u8 = null,
    sidebar_scroll: ui.Layout.ScrollState = .{},

    /// Open the window; `graphics` and `font` (the editor's) must outlive it. Pair with `close`.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*RenderWindow {
        const self = try gpa.create(RenderWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Render", .{ 980, 600 }, .{ .resizable = true }) };
        return self;
    }

    /// Close the window and free it; a render under way goes on.
    pub fn close(self: *RenderWindow, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *RenderWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) {
            self.closing = true;
            return true;
        }
        self.window.handle(curr_event);
        return true;
    }

    /// Find the open scene's cutscenes again, choosing the one the Animation panel shows.
    pub fn refresh(film: *Film, env: ?film_zig.Env, playhead: Playhead) void {
        if (env) |found| film.findSources(found, playhead.entity);
    }

    /// Start `what` with the chosen cutscene and output settings; a still is taken at the
    /// playhead when it is on that cutscene, else at its start. Why it can't start is shown.
    pub fn start(self: *RenderWindow, film: *Film, env: ?film_zig.Env, what: What, playhead: Playhead) void {
        self.problem = null;
        const found = env orelse {
            self.problem = "The game's code isn't running, so nothing can be posed. Fix it (see the Console), then render.";
            return;
        };
        const at_s: f32 = blk: {
            if (film.chosen >= film.sources.items.len) break :blk 0;
            const entity = playhead.entity orelse break :blk 0;
            break :blk if (entity.eql(film.sources.items[film.chosen].entity)) playhead.time_s else 0;
        };
        const started = switch (what) {
            .image => film.render(found, .{ .still_s = at_s }),
            .animation => film.render(found, .animation),
            .all => film.renderAll(found),
        };
        started catch |err| {
            self.problem = switch (err) {
                error.NoCutscene => "No entity in the open scene has an Animator with a .clip.zon.",
                error.FilmUnderWay => "A render is under way.",
                else => "The render couldn't start: see the Console.",
            };
            if (err == error.OutOfMemory) std.log.err("cannot start the render: {t}", .{err});
        };
    }

    /// Draw a frame. Returns whether the window stays open.
    pub fn update(self: *RenderWindow, graphics: *eggy.Graphics, style: *const ui.Context, film: *Film, env: ?film_zig.Env, playhead: Playhead) !bool {
        const Page = struct {
            window: *RenderWindow,
            film: *Film,
            env: ?film_zig.Env,
            playhead: Playhead,
            stage_id: u32 = 0,

            pub fn build(page: *@This(), context: *ui.Context) void {
                page.stage_id = page.window.build(context, page.film, page.env, page.playhead);
            }

            /// The picture over the stage, as large as fits at its own shape.
            pub fn drawOver(page: *@This(), context: *const ui.Context, cmd: vit.CommandBuffer, extent: vit.Extent2D) void {
                const picture = page.film.picture() orelse return;
                const stage = (context.last_bounds.get(page.stage_id) orelse return).rect;
                const fitted = fit(stage, picture.width_px, picture.height_px);
                const scale = context.pixel_scale;
                picture.scene.draw(cmd, .{ .x = fitted.x * scale[0], .y = fitted.y * scale[1], .w = fitted.w * scale[0], .h = fitted.h * scale[1] }, extent);
            }
        };
        var page = Page{ .window = self, .film = film, .env = env, .playhead = playhead };
        try self.window.present(graphics, style, &page);
        return !self.closing;
    }

    /// The stage and the line under it on the left, the sidebar on the right. Returns the
    /// stage's id, for the picture.
    fn build(self: *RenderWindow, context: *ui.Context, film: *Film, env: ?film_zig.Env, playhead: Playhead) u32 {
        const b = context.builder();
        const height = page_style.pageHeight(context);
        const stage_id = context.idFor("render stage");
        context.begin(.row);

        context.begin(.column);
        const stage_width = @max(1, context.contentWidth() - sidebar_width - gap);
        if (b.node(stage_id, .{ .width = stage_width, .height = @max(1, height - status_height - gap) }, .{ .custom = .{ .context = &stage_paint, .draw = drawStage } }, &.{})) |stage| context.element(stage) else |_| {}
        buildStatus(context, film);
        context.end();
        restyle(context, .{ .width = stage_width, .gap = gap });

        context.beginScroll(&self.sidebar_scroll, height);
        self.buildSidebar(context, film, env, playhead);
        context.end();
        restyle(context, .{ .width = sidebar_width, .gap = 10 });

        context.end();
        restyle(context, .{ .direction = .row, .gap = gap, .align_items = .start });
        return stage_id;
    }

    /// The output settings, the buttons that render, and what each render of the last run made.
    fn buildSidebar(self: *RenderWindow, context: *ui.Context, film: *Film, env: ?film_zig.Env, playhead: Playhead) void {
        const arena = context.builder().allocator;
        const look = &film.look;
        const busy = !film.finished();

        field(context, "Cutscene");
        if (film.sources.items.len == 0)
            context.muted("No entity in the open scene has an Animator with a .clip.zon")
        else
            _ = context.select("##render cutscene", film.sourceLabels(arena), &film.chosen);
        field(context, "Size");
        _ = context.select("##render size", &film_zig.size_labels, &look.size);
        field(context, "Frame rate");
        _ = context.select("##render rate", &film_zig.rate_labels, &look.rate);
        field(context, "Motion blur");
        _ = context.select("##render blur", &film_zig.blur_labels, &look.blur);
        field(context, "Format");
        var format: usize = @backingInt(look.format);
        if (context.select("##render format", &film_zig.Format.labels, &format)) look.format = @fromBackingInt(@intCast(format));
        if (look.format == .mp4) {
            context.muted("Needs ffmpeg; without it the frames are kept.");
            smallText(context, 12);
        }

        context.separator();
        if (busy) {
            if (context.buttonVariant("Stop", .outline)) film.stop(env);
        } else {
            if (context.button("Render Animation")) self.start(film, env, .animation, playhead);
            if (context.buttonVariant("Render Image", .outline)) self.start(film, env, .image, playhead);
            if (context.buttonVariant("Render All Cutscenes", .ghost)) self.start(film, env, .all, playhead);
        }
        if (self.problem) |why| context.alert("Couldn't render", why, true);

        for (film.queue.items, 0..) |queued, index| buildQueued(context, film, queued, index);
    }
};

/// A setting's name over its control.
fn field(context: *ui.Context, name: []const u8) void {
    context.muted(name);
    smallText(context, 12);
}

/// The render under way: a bar and how far it has got; nothing otherwise.
fn buildStatus(context: *ui.Context, film: *const Film) void {
    const arena = context.builder().allocator;
    context.begin(.row);
    if (film.running) |index| if (film.progress(index)) |shown| {
        const fraction: f32 = if (shown.stage == .rendering) @as(f32, @floatFromInt(shown.frame)) / @as(f32, @floatFromInt(@max(1, shown.frames))) else 1;
        context.progress(fraction);
        restyle(context, .{ .grow = 1 });
        const text = switch (shown.stage) {
            .encoding => "Encoding",
            else => if (shown.left_s) |left|
                std.fmt.allocPrint(arena, "Frame {d} of {d}, about {d} s left", .{ @min(shown.frame + 1, shown.frames), shown.frames, left }) catch ""
            else
                std.fmt.allocPrint(arena, "Frame {d} of {d}", .{ @min(shown.frame + 1, shown.frames), shown.frames }) catch "",
        };
        context.muted(text);
    };
    context.end();
    restyle(context, .{ .direction = .row, .height = status_height, .gap = 10, .align_items = .center });
}

/// One render of the last run: its cutscene, how it went, and its file once made.
fn buildQueued(context: *ui.Context, film: *const Film, queued: film_zig.Queued, index: usize) void {
    const arena = context.builder().allocator;
    context.begin(.column);
    context.label("{s}", .{queued.source.label});
    switch (queued.state) {
        .waiting => context.muted("Waiting"),
        .filming => context.muted(if (film.progress(index)) |shown| if (shown.stage == .encoding) "Encoding" else "Rendering" else "Rendering"),
        .failed => context.alert("The render stopped", queued.message, true),
        .done => {
            context.muted(queued.message);
            smallText(context, 12);
            context.begin(.row);
            if (queued.openable) {
                const open_label = std.fmt.allocPrint(arena, "{s}##render open {d}", .{ if (queued.span == .still_s) "Open" else "Play", index }) catch "Open";
                if (context.buttonVariant(open_label, .outline)) file_manager.openFile(film.gpa, queued.saved) catch |err| std.log.err("cannot open {s}: {t}", .{ queued.saved, err });
            }
            const show = std.fmt.allocPrint(arena, "Show in folder##render show {d}", .{index}) catch "Show in folder";
            const folder = if (queued.openable) std.fs.path.dirname(queued.saved) orelse queued.saved else queued.saved;
            if (context.buttonVariant(show, .ghost)) file_manager.showFolder(film.gpa, folder) catch |err| std.log.err("cannot show {s}: {t}", .{ folder, err });
            page_style.endRow(context);
        },
    }
    context.end();
    restyle(context, .{ .gap = 4 });
}

const stage_paint: u8 = 0;

/// The stage behind the picture: darker than the page, as a viewer's backdrop is.
fn drawStage(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.roundRectAlpha(r, .{ 0, 0, 0 }, c.theme.radiusSm(), 0.3);
}

/// The largest rect of `width_px` by `height_px`'s shape that fits in `stage`, centred.
fn fit(stage: ui.Rect, width_px: u32, height_px: u32) ui.Rect {
    const aspect = @as(f32, @floatFromInt(width_px)) / @as(f32, @floatFromInt(@max(1, height_px)));
    const w = @min(stage.w, stage.h * aspect);
    const h = w / aspect;
    return .{ .x = stage.x + (stage.w - w) / 2, .y = stage.y + (stage.h - h) / 2, .w = w, .h = h };
}

test "a picture fits its stage at its own shape, centred" {
    const wide = fit(.{ .x = 0, .y = 0, .w = 400, .h = 400 }, 1920, 1080);
    try std.testing.expectEqual(@as(f32, 400), wide.w);
    try std.testing.expectApproxEqAbs(@as(f32, 225), wide.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 87.5), wide.y, 0.01);
    const tall = fit(.{ .x = 10, .y = 0, .w = 800, .h = 225 }, 1920, 1080);
    try std.testing.expectApproxEqAbs(@as(f32, 400), tall.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 210), tall.x, 0.01);
}
