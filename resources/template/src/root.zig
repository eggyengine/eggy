//! eggy_template_name's plugin: code any eggy game can run. A game adds it with
//! `b.dependency("eggy_template_name", .{}).module("eggy_template_name")` in `addGame`'s `plugins`.
//! Every hook is optional; see eggy's `plugins.zig` for the full list.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

/// A component: an entity with one turns a little every frame (see `spin`). The plugin lists it
/// in `components`, so the editor's Hierarchy and Inspector show it, and can add and edit it.
pub const Spin = struct {
    /// Turns per frame.
    speed: f32 = 0.001,
    turns: f32 = 0,
};

/// A system: turns every entity with a `Spin` by its speed, once a frame.
fn spin(spinners: ecs.Query(.{*Spin})) !void {
    var iter = spinners;
    while (iter.next()) |view| {
        const turning = view.get(*Spin);
        turning.turns += turning.speed;
    }
}

pub const Plugin = struct {
    clicks: u32 = 0,
    /// What people can set for this plugin in the editor's Edit > Preferences: its manifest.
    /// Values are kept in the project's `.eggy/plugins/eggy_template_name.zon` and baked into
    /// the game. Read them with `app.preferences`.
    pub const Preferences = struct {
        clicks_per_press: u32 = 1,

        pub const descriptions = .{ .clicks_per_press = "How many clicks each press of the panel's button counts." };
    };

    /// The components this plugin brings (see `Spin`).
    pub const components = .{Spin};

    /// Runs once at start-up: registers the `spin` system and spawns an entity to turn.
    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        _ = gpa;
        app.world.addSchedule(ecs.Schedule(.Update, .{spin}));
        _ = try app.world.spawn(.{Spin{}});
        return .{};
    }

    /// Panels this plugin adds to the editor's dock. Each gets a tab you can drag anywhere, float
    /// or pop out; `editorPanelUi` fills it.
    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "main", .title = "eggy_template_name" }};
    pub const editor_commands = [_]eggy.plugins.EditorCommand{.{ .key = "reset-clicks", .title = "Reset Plugin Clicks" }};

    /// Commands appear in View and dispatch to this plugin, without stored callbacks.
    pub fn editorCommand(self: *Plugin, command: usize, editor: *eggy.editor.Context) !void {
        _ = editor;
        switch (command) {
            0 => self.clicks = 0,
            else => unreachable,
        }
    }

    /// Draws panel `panel` (an index into `editor_panels`) every frame. Never called in the runtime.
    pub fn editorPanelUi(self: *Plugin, panel: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        _ = panel;
        ui.heading(3, "eggy_template_name");
        ui.muted("A panel from your plugin. Drag its tab to dock it anywhere.");
        if (ui.button("Click me")) self.clicks += editor.app.preferences(Preferences).clicks_per_press;
        ui.label("Clicked {d} times", .{self.clicks});
    }

    /// Adds to the editor's Inspector. Never called in the runtime.
    pub fn editorUi(self: *Plugin, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        _ = editor;
        _ = self;
        ui.muted("eggy_template_name plugin");
    }
};

test "the plugin compiles" {
    std.testing.refAllDecls(Plugin);
}
