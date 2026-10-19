//! The player's graphics menu: a dialog drawn over the game with the graphics options, opened
//! with F10 (rebindable or off) or by the game, which owns `app.graphics_settings_ui`. While it is
//! open it takes all input, so the game neither sees nor reacts to it.
const std = @import("std");
const ui = @import("weeoui");
const sdl = @import("vitellus_sdl3").sdl;
const App = @import("../app.zig").App;
const Key = @import("../input/input.zig").Key;
const game_ui = @import("game_ui.zig");
const graphics_form = @import("graphics_form.zig");
const render_settings = @import("../render_settings.zig");

pub const Form = graphics_form.Form;

const dialog_title = "Graphics##graphics menu";

/// The menu's state. It is a field of `App`; the runtime feeds it events and draws it.
pub const GraphicsSettingsUi = struct {
    showing: bool = false,
    /// What the last `sync` saw, so gameplay input is dropped once per opening and closing.
    synced: bool = false,
    /// The key that opens and closes the menu: null for none (the game opens it itself).
    toggle_key: ?Key = .func10,
    form: Form = .{},
    scroll: ui.Layout.ScrollState = .{},

    /// Show the menu: the draft starts from the player's current choices, and gameplay input is
    /// dropped. Takes effect at the next event or frame.
    ///
    /// ```zig
    /// if (app.input.pressed(.g)) app.graphics_settings_ui.open();
    /// ```
    pub fn open(self: *GraphicsSettingsUi) void {
        self.showing = true;
    }

    /// Hide the menu, discarding an unapplied draft.
    ///
    /// ```zig
    /// app.graphics_settings_ui.close();
    /// ```
    pub fn close(self: *GraphicsSettingsUi) void {
        self.showing = false;
    }

    /// Open the menu if it is closed, or close it.
    ///
    /// ```zig
    /// if (app.input.pressed(.escape)) app.graphics_settings_ui.toggle();
    /// ```
    pub fn toggle(self: *GraphicsSettingsUi) void {
        self.showing = !self.showing;
    }

    /// Whether the menu is open.
    pub fn isOpen(self: *const GraphicsSettingsUi) bool {
        return self.showing;
    }

    /// Route one SDL event: the toggle key opens and closes the menu, and while it is open
    /// the menu takes every input event (the game gets none). Returns whether the event was
    /// used: the host then skips gameplay and plugin input for it.
    /// Host-only, on the main thread, before gameplay input.
    ///
    /// ```zig
    /// if (app.graphics_settings_ui.event(app, current)) return .run;
    /// ```
    pub fn event(self: *GraphicsSettingsUi, app: *App, curr_event: sdl.events.Event) bool {
        self.sync(app);
        switch (curr_event) {
            .key_down, .key_up => |key| if (self.toggle_key != null and key.scancode == self.toggle_key) {
                if (curr_event == .key_down and !key.repeat) self.toggle();
                self.sync(app);
                app.input.suppress(curr_event);
                return true;
            },
            else => {},
        }
        if (!self.showing or !game_ui.isInput(curr_event)) return false;

        // Escape closes a dropdown first, then the menu.
        if (curr_event == .key_down and curr_event.key_down.scancode == .escape and !curr_event.key_down.repeat) {
            const dropdown_open = if (app.ui_layer) |layer| layer.context.open_popup != 0 else false;
            if (dropdown_open) app.ui_layer.?.context.open_popup = 0 else self.close();
            self.sync(app);
        } else if (app.ui_layer) |layer| _ = layer.handle(curr_event, false);
        app.input.suppress(curr_event);
        return true;
    }

    /// Declare the menu in this frame's game UI, if it is open: the options, then Apply, Restore
    /// defaults and Cancel. Apply saves the player's choice and applies it at the next frame
    /// boundary; failures are shown in the menu.
    /// Host-only, between the overlay's `begin` and `render`.
    ///
    /// ```zig
    /// layer.begin(draw, time_ms);
    /// app.graphics_settings_ui.draw(app, &layer.context);
    /// ```
    pub fn draw(self: *GraphicsSettingsUi, app: *App, context: *ui.Context) void {
        self.sync(app);
        if (!self.showing) return;
        if (!context.beginDialog(dialog_title, &self.showing)) return;
        defer context.endDialog();

        if (self.toggle_key) |key| {
            const arena = context.builder().allocator;
            const name = sdl.keyboard.getScancodeName(key) orelse @tagName(key);
            context.muted(std.fmt.allocPrint(arena, "Press Escape or {s} to close.", .{name}) catch "Press Escape to close.");
        } else context.muted("Press Escape to close.");
        context.beginScroll(&self.scroll, @max(160, @min(context.viewport.h - 220, 520)));
        buildOptions(&self.form, context, app);
        context.end();
        if (buildButtons(&self.form, context, app, "Cancel")) self.close();
    }

    /// Once per opening or closing: drop gameplay input and the overlay's focus, and start an
    /// opened menu from the player's current choices.
    fn sync(self: *GraphicsSettingsUi, app: *App) void {
        if (self.showing == self.synced) return;
        self.synced = self.showing;
        app.input.cancel();
        if (app.ui_layer) |layer| layer.cancel();
        if (self.showing) self.form.load(app.graphics_options.requested);
    }
};

/// The graphics options for `app`, with a note when saved settings were not used or a restart
/// is pending: what the player's menu and the editor's Graphics preferences both show.
/// The form's draft is edited, never applied.
///
/// ```zig
/// graphics_settings.buildOptions(&form, context, app);
/// ```
pub fn buildOptions(form: *Form, context: *ui.Context, app: *App) void {
    if (app.graphics_options.warning) context.alert("Saved settings not used", "The graphics settings saved earlier could not be applied, so the defaults are in use.", true);
    if (app.graphics_options.requested.requiresRestart(app.graphics.render_settings)) context.muted("A new graphics API, card or vertical sync setting is waiting for the next start.");
    const caps = app.graphics.capabilities();
    _ = form.build(context, .{ .caps = &caps });
}

/// Apply, Restore defaults and `cancel_label` for `form`. Apply saves the draft as the user's
/// choice and queues it for the next frame boundary, showing failures in the form; Restore
/// defaults loads the game's defaults into the draft. Returns true when the cancel button was
/// pressed: the caller decides what that closes or discards.
///
/// ```zig
/// if (graphics_settings.buildButtons(&form, context, app, "Revert")) form.load(app.graphics_options.requested);
/// ```
pub fn buildButtons(form: *Form, context: *ui.Context, app: *App, cancel_label: []const u8) bool {
    const action = form.buttons(context, cancel_label) orelse return false;
    switch (action) {
        .apply => {
            const result: anyerror!render_settings.ApplyResult = if (form.read()) |draft| app.saveGraphicsSettings(draft) else |err| err;
            form.report(result);
        },
        .restore_defaults => form.load(app.graphics_options.defaults),
        .cancel => return true,
    }
    return false;
}

test "the menu opens, closes and toggles" {
    var menu = GraphicsSettingsUi{};
    try std.testing.expect(!menu.isOpen());
    menu.open();
    try std.testing.expect(menu.isOpen());
    menu.toggle();
    try std.testing.expect(!menu.isOpen());
    menu.toggle();
    menu.close();
    try std.testing.expect(!menu.isOpen());
}

test "F10 is the default key, and a game may turn it off" {
    var menu = GraphicsSettingsUi{};
    try std.testing.expectEqual(@as(?Key, .func10), menu.toggle_key);
    menu.toggle_key = null;
    try std.testing.expectEqual(@as(?Key, null), menu.toggle_key);
}
