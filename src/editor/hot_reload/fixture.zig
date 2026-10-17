//! A headless game for testing typed editor actions across the actual shared-library boundary.
const std = @import("std");
const eggy = @import("eggy");

pub const Counter = struct { value: u32 = 1 };
pub const Game = struct {
    entity: eggy.ecs.EntityId,
    pub const components = .{Counter};
    pub const editor_commands = [_]eggy.plugins.EditorCommand{
        .{ .key = "increment", .title = "Increment" },
        .{ .key = "read-resource", .title = "Check resource errors" },
    };
    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "counter", .title = "Counter" }};

    pub fn init(_: std.mem.Allocator, app: *eggy.App) !Game {
        return .{ .entity = eggy.findNamed(&app.world, "API Entity") orelse try app.world.spawn(.{ eggy.Name.init("API Entity"), Counter{} }) };
    }
    pub fn editorCommand(self: *Game, command: usize, editor: *eggy.editor.Context) !void {
        if (command == 1) {
            if (editor.app.resources().read(editor.app.world.allocator, eggy.AssetRef(.text).init("missing.txt"))) |bytes| {
                editor.app.world.allocator.free(bytes);
                return error.ExpectedMissingResource;
            } else |err| if (err != error.FileNotFound) return err;
        }
        const before = editor.app.world.get(self.entity, Counter) orelse return error.NoCounter;
        try editor.changeComponent(self.entity, eggy.Action(Counter){ .before = before.*, .after = .{ .value = before.value + 1 } });
    }
    pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
        const counter = app.world.get(self.entity, Counter) orelse return error.NoCounter;
        ui.label("Counter: {d}", .{counter.value});
    }
    pub fn editorPanelUi(self: *Game, _: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        try self.gameUi(editor.app, ui);
    }
    pub fn uiEvent(_: *Game, _: *eggy.App, event: eggy.Event) !bool {
        return event == .key_down;
    }
};
