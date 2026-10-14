//! eggy_template_name's plugin: code any eggy game can run. A game adds it with
//! `b.dependency("eggy_template_name", .{}).module("eggy_template_name")` in `addGame`'s `plugins`.
//! Every hook is optional; see eggy's `plugins.zig` for the full list.
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    clicks: u32 = 0,

    /// Panels this plugin adds to the editor's dock. Each gets a tab you can drag anywhere, float
    /// or pop out; `editorPanelUi` fills it.
    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .title = "eggy_template_name" }};

    /// Draws panel `panel` (an index into `editor_panels`) every frame. Never called in the runtime.
    pub fn editorPanelUi(self: *Plugin, panel: usize, ui: *eggy.ui.Context) void {
        _ = panel;
        ui.heading(3, "eggy_template_name");
        ui.muted("A panel from your plugin. Drag its tab to dock it anywhere.");
        if (ui.button("Click me")) self.clicks += 1;
        ui.label("Clicked {d} times", .{self.clicks});
    }

    /// Adds to the editor's Inspector. Never called in the runtime.
    pub fn editorUi(self: *Plugin, ui: *eggy.ui.Context) void {
        _ = self;
        ui.muted("eggy_template_name plugin");
    }
};

test "the plugin compiles" {
    std.testing.refAllDecls(Plugin);
}
