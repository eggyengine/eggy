//! Optional developer-API fixture selected with `-Dapi-demo=weeoui` or `custom`.
const std = @import("std");
const eggy = @import("eggy");

pub const Game = if (@import("api_fixture_options").custom_ui) Custom else Hud;

const Hud = struct {
    clicks: u32 = 0,
    gameplay_presses: u32 = 0,
    text: eggy.ui.TextEdit(128) = .{},
    player: eggy.EntityRef(eggy.Transform) = .{},

    pub fn init(_: std.mem.Allocator, app: *eggy.App) !Hud {
        const layer = try app.gameUi();
        try layer.setFont(@embedFile("api_fixture_font"));
        const player = try app.world.spawn(.{ eggy.Name.init("API Cube"), eggy.Transform{}, eggy.Mesh{} });
        _ = try app.world.spawn(.{ eggy.Camera{}, eggy.Transform{ .position = .{ 0, 2, 7 }, .rotation_deg = .{ -15, 0, 0 } } });
        return .{ .player = .init(player) };
    }

    pub fn update(self: *Hud, app: *eggy.App) !void {
        if (app.input.pressed(.space)) self.gameplay_presses += 1;
        const transform = self.player.get(&app.world) orelse return;
        const direction = app.input.direction(.{});
        transform.translate(.{ direction[0] * app.time.delta_s, 0, -direction[1] * app.time.delta_s });
        app.world.markChanged(self.player.entity.?, eggy.Transform);
    }

    pub fn gameUi(self: *Hud, _: *eggy.App, ui: *eggy.ui.Context) !void {
        ui.theme = .dark;
        ui.heading(2, "Eggy developer API");
        ui.muted("Custom font, theme, widgets, and gameplay input isolation.");
        if (ui.button("Count UI click")) self.clicks += 1;
        _ = ui.textInput("UI text", &self.text, "Space here must not reach gameplay");
        ui.label("UI clicks: {d}", .{self.clicks});
        ui.label("Gameplay space presses: {d}", .{self.gameplay_presses});
        ui.muted("WASD moves the cube when the UI does not hold keyboard focus.");
    }

    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "api-tools", .title = "API Tools" }};
    pub const editor_commands = [_]eggy.plugins.EditorCommand{.{ .key = "raise", .title = "Raise Selected Entity" }};

    pub fn editorPanelUi(self: *Hud, _: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        ui.heading(3, "Developer tools");
        if (ui.button("Raise selection")) try self.editorCommand(0, editor);
    }

    pub fn editorCommand(_: *Hud, _: usize, editor: *eggy.editor.Context) !void {
        const entity = try editor.selection() orelse return;
        const transform = editor.app.world.get(entity, eggy.Transform) orelse return;
        var after = transform.*;
        after.position[1] += 1;
        try editor.changeComponent(entity, eggy.Action(eggy.Transform){ .before = transform.*, .after = after });
    }
};

const Custom = struct {
    clicks: u32 = 0,
    gameplay_presses: u32 = 0,

    pub fn update(self: *Custom, app: *eggy.App) !void {
        if (app.input.pressed(.space)) self.gameplay_presses += 1;
    }

    /// A minimal custom renderer: clear the owned target without creating a Weeoui overlay.
    pub fn draw(self: *Custom, app: *eggy.App, target: eggy.DrawContext) !void {
        std.debug.assert(app.ui_layer == null);
        try target.cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = target.target,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = if (self.clicks % 2 == 0) 0.12 else 0.5, .g = 0.2, .b = 0.4, .a = 1 },
        }} });
        target.cmd.endRenderPass();
    }

    pub fn uiEvent(self: *Custom, _: *eggy.App, event: eggy.Event) !bool {
        const pressed = switch (event) {
            .mouse_button_down => true,
            .key_down => |key| key.scancode == .space and !key.repeat,
            else => false,
        };
        if (pressed) {
            self.clicks += 1;
            std.log.info("custom UI interactions: {d}; gameplay presses: {d}", .{ self.clicks, self.gameplay_presses });
            return true;
        }
        return switch (event) {
            .mouse_button_up => true,
            .key_up => |key| key.scancode == .space,
            else => false,
        };
    }
};
