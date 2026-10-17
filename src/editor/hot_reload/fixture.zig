//! A headless game for testing typed editor actions across the actual shared-library boundary.
const std = @import("std");
const eggy = @import("eggy");

pub const Counter = struct { value: u32 = 1 };
const Player = eggy.input.Map(enum { jump, move }, .{
    .key = "player",
    .controls = &.{
        .{ .control = .jump, .bindings = &.{.{ .key = .space }} },
        .{ .control = .move, .kind = .vector, .bindings = &.{.{ .keys_2d = .{} }} },
    },
});
pub const Game = struct {
    entity: eggy.ecs.EntityId,
    pub const components = .{Counter};
    pub const input_maps = .{Player};
    pub const editor_commands = [_]eggy.plugins.EditorCommand{
        .{ .key = "increment", .title = "Increment" },
        .{ .key = "read-resource", .title = "Check resource errors" },
        .{ .key = "read-input", .title = "Check mapped input" },
    };
    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "counter", .title = "Counter" }};

    pub fn init(_: std.mem.Allocator, app: *eggy.App) !Game {
        return .{ .entity = eggy.findNamed(&app.world, "API Entity") orelse try app.world.spawn(.{ eggy.Name.init("API Entity"), Counter{} }) };
    }
    pub fn editorCommand(self: *Game, command: usize, editor: *eggy.editor.Context) !void {
        if (command == 2) {
            const player = editor.app.input.map(Player);
            if (!try player.pressed(.jump)) return error.ExpectedMappedPress;
            var bindings: [1]eggy.input.Binding = undefined;
            if ((try player.getBindings(.jump, &bindings))[0].key != .j) return error.ExpectedProjectBinding;
            if (player.axis(.jump)) |_| return error.ExpectedWrongKind else |err| if (err != error.WrongControlKind) return err;
            try player.rebind(.jump, .{ .key = .j });
            try player.setTrigger(.jump, .immediate);
        }
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
