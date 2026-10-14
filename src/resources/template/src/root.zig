//! eggy_template_name's plugin: code any eggy game can run. A game adds it with
//! `b.dependency("eggy_template_name", .{}).module("eggy_template_name")` in `addGame`'s `plugins`.
//! Every hook is optional; see eggy's `plugins.zig` for the full list.
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    /// Adds to the editor's panel. Never called in the runtime.
    pub fn editorUi(self: *Plugin, ui: *eggy.ui.Context) void {
        _ = self;
        ui.muted("eggy_template_name plugin");
    }
};

test "the plugin compiles" {
    std.testing.refAllDecls(Plugin);
}
