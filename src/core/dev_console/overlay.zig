//! The dev console over the game: a command bar along the bottom of the view, with the last few
//! lines of output and the candidates over it, shown and hidden with its toggle key. While it
//! shows it takes all input.
const std = @import("std");
const ui = @import("weeoui");
const sdl = @import("vitellus_sdl3").sdl;
const App = @import("../app.zig").App;
const game_ui = @import("../game_ui/game_ui.zig");
const DevConsole = @import("console.zig").DevConsole;
const Line = @import("console.zig").Line;
const Commands = @import("commands.zig").Commands;
const prompt = @import("prompt.zig");
const palette = @import("palette.zig").console;
const scripting = @import("buzz_session.zig").available;

const z_index = 400;
const padding: f32 = 14;
const text_size: f32 = 13;
const line_height: f32 = 19;
/// The bar the prompt types on, along the bottom, and the yolk edge along its top.
const band_height: f32 = 44;
const lip_height: f32 = 2;
/// Room over the bar for the candidates.
const candidates_height: f32 = 22 + 8;
/// The most lines of output shown over the bar; Page Up goes further back.
const max_lines: usize = 6;
/// The tallest the console gets: the bar, the candidates and the lines.
const max_height: f32 = band_height + candidates_height + @as(f32, @floatFromInt(max_lines)) * line_height + padding;
/// Where the text of a line starts, after the chevron.
const chevron_width: f32 = 18;
const status_width: f32 = 120;

/// Route one SDL event: the toggle key shows and hides the console, and while it shows it takes
/// every input event (the game gets none). Returns whether the event was used: the host then
/// skips gameplay and plugin input for it. `embedded` as for `game_ui.Overlay.handle`: true when
/// the game is drawn in a panel (the editor's), with `curr_event` in its coordinates.
/// Host-only, on the main thread, before gameplay input.
///
/// ```zig
/// if (eggy.dev_console.overlay.event(&app.dev_console, app, current, false)) return .run;
/// ```
pub fn event(console: *DevConsole, app: *App, curr_event: sdl.events.Event, embedded: bool) bool {
    sync(console, app);
    switch (curr_event) {
        .key_down, .key_up => |key| if (console.enabled and console.toggle_key != null and key.scancode == console.toggle_key) {
            if (curr_event == .key_down and !key.repeat) {
                console.toggle();
                // The key's character, typed as it closes, isn't for the prompt.
                swallow_toggle_text = true;
            }
            sync(console, app);
            app.input.suppress(curr_event);
            return true;
        },
        .text_input => if (swallow_toggle_text) {
            swallow_toggle_text = false;
            return true;
        },
        else => {},
    }
    if (!console.showing or !game_ui.isInput(curr_event)) return false;
    swallow_toggle_text = false;

    switch (curr_event) {
        // Escape hides it; Page Up and Down and the wheel scroll the output.
        .key_down => |key| if (key.scancode == .escape) {
            console.close();
            sync(console, app);
        } else if (key.scancode == .pageup) {
            console.scrolled_back += 10;
        } else if (key.scancode == .pagedown) {
            console.scrolled_back -|= 10;
        } else if (!console.prompt.takeTab(key.scancode == .tab, key.mod.left_shift or key.mod.right_shift)) forward(app, curr_event, embedded),
        .mouse_wheel => |wheel| {
            if (wheel.y > 0) console.scrolled_back += 3 else console.scrolled_back -|= 3;
        },
        else => forward(app, curr_event, embedded),
    }
    app.input.suppress(curr_event);
    return true;
}

/// Whether the toggle key's character is still to come as text, to drop it.
var swallow_toggle_text = false;

fn forward(app: *App, curr_event: sdl.events.Event, embedded: bool) void {
    if (app.ui_layer) |layer| _ = layer.handle(curr_event, embedded);
}

/// Declare the console in this frame's game UI, if it shows: its output, newest at the bottom,
/// over its prompt, which completes from and runs `game`'s commands too.
/// Host-only, between the overlay's `begin` and `render`.
///
/// ```zig
/// layer.begin(draw, time_ms);
/// eggy.dev_console.overlay.draw(&app.dev_console, app, commands, &layer.context);
/// ```
pub fn draw(console: *DevConsole, app: *App, game: Commands, context: *ui.Context) void {
    sync(console, app);
    if (!console.showing) return;
    const viewport = context.viewport;
    const height = @min(viewport.h, max_height);
    const top = viewport.y + viewport.h - height;

    // Its whole reach, painted only as far as it shows, and keeping clicks off the game under it.
    const paint = context.builder().allocator.create(Panel) catch return;
    paint.* = .{ .console = console };
    const panel = context.builder().node(context.idFor("##dev console"), .{ .width = viewport.w, .height = height, .z_index = z_index }, .{ .custom = .{ .context = paint, .draw = Panel.draw } }, &.{}) catch return;
    panel.overlay = .{ .point = .init(viewport.x, top) };
    panel.accessibility = .{ .role = .group, .label = "Dev console" };
    context.element(panel);

    // The field sits on the bar, after the chevron and clear of the status at its end. It keeps
    // the keyboard while the console shows, even after a click elsewhere took it away.
    const field_x = viewport.x + padding + chevron_width - prompt.field_text_inset;
    console.buildPrompt(app, game, context, .{
        .place = .{ .x = field_x, .y = top, .w = @max(0, viewport.x + viewport.w - padding - status_width - field_x), .h = height - 2 },
        .z_index = z_index,
        .palette = palette,
        .take_focus = true,
    });
}

/// Once per showing or hiding: drop gameplay input and the overlay's focus.
fn sync(console: *DevConsole, app: *App) void {
    if (console.showing == console.synced) return;
    console.synced = console.showing;
    app.input.cancel();
    if (app.ui_layer) |layer| layer.cancel();
}

/// The console's paint, from the bottom up: the bar with its chevron and what runs there, then,
/// only as tall as they need, the candidates and the newest lines of output over it.
const Panel = struct {
    console: *DevConsole,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Panel = @ptrCast(@alignCast(context));
        const bar = ui.Rect{ .x = r.x, .y = r.y + r.h - band_height, .w = r.w, .h = band_height };
        try c.rectAlpha(bar, palette.band, 0.97);
        try c.rect(.{ .x = r.x, .y = bar.y, .w = r.w, .h = lip_height }, palette.yolk);
        try c.textIn(.{ .x = r.x + padding, .y = bar.y, .w = chevron_width, .h = bar.h }, "\u{203A}", 18, palette.yolk, .start);
        const status = if (!scripting) "Commands only" else if (self.console.session_failed) "Buzz didn't start" else "Commands and Buzz";
        try c.textIn(.{ .x = r.x + r.w - padding - status_width, .y = bar.y, .w = status_width, .h = bar.h }, status, 12, palette.dim, .end);

        // Scrolled back no further than the oldest line allows, keeping a row to say so.
        const lines = self.console.lines.items;
        const back = @min(self.console.scrolled_back, lines.len -| max_lines);
        self.console.scrolled_back = back;
        const end = lines.len - back;
        const start = end -| if (back != 0) max_lines - 1 else max_lines;
        const rows = end - start + @intFromBool(back != 0);
        const candidates: f32 = if (self.console.prompt.candidates_shown != 0) candidates_height else 0;
        const output_height: f32 = if (rows != 0) @as(f32, @floatFromInt(rows)) * line_height + padding / 2 else 0;
        if (candidates + output_height == 0) return;
        try c.rectAlpha(.{ .x = r.x, .y = bar.y - candidates - output_height, .w = r.w, .h = candidates + output_height }, palette.shell, palette.shell_alpha);

        var y = bar.y - candidates - output_height + padding / 2;
        const text_x = r.x + padding + chevron_width;
        const text_w = r.w - padding * 2 - chevron_width;
        for (lines[start..end]) |line| {
            const row = ui.Rect{ .x = text_x, .y = y, .w = text_w, .h = line_height };
            switch (line.kind) {
                .input => {
                    try c.textIn(.{ .x = r.x + padding, .y = y, .w = chevron_width, .h = line_height }, "\u{203A}", text_size, palette.dim, .start);
                    try c.textIn(row, line.text, text_size, palette.dim, .start);
                },
                .output => try c.textIn(row, line.text, text_size, palette.text, .start),
                .failure => {
                    try c.rect(.{ .x = r.x + padding + 3, .y = y + 3, .w = 2, .h = line_height - 6 }, palette.failure);
                    try c.textIn(row, line.text, text_size, palette.failure, .start);
                },
            }
            y += line_height;
        }
        if (back != 0) {
            var buffer: [64]u8 = undefined;
            const notice = std.fmt.bufPrint(&buffer, "{d} newer below. Page Down to return.", .{back}) catch "Page Down to return.";
            try c.textIn(.{ .x = text_x, .y = y, .w = text_w, .h = line_height }, notice, 12, palette.yolk, .start);
        }
    }
};

test "the toggle key shows and hides the console, and takes the key from the game" {
    var app: App = undefined;
    app.input = .{};
    app.ui_layer = null;
    var console = DevConsole{};
    const down = sdl.events.Event{ .key_down = .{ .common = undefined, .id = null, .scancode = .grave, .key = .grave, .mod = .{}, .raw = 0, .down = true, .repeat = false } };
    try std.testing.expect(event(&console, &app, down, false));
    try std.testing.expect(console.isOpen());
    try std.testing.expect(event(&console, &app, down, false));
    try std.testing.expect(!console.isOpen());
}
