//! Optional developer-API fixture selected with `-Dapi-demo=weeoui` or `custom`.
const std = @import("std");
const eggy = @import("eggy");

pub const Game = if (@import("api_fixture_options").custom_ui) Custom else Hud;
const PlayerInput = eggy.input.Map(enum { jump, move }, .{
    .key = "player",
    .controls = &.{
        .{ .control = .jump, .bindings = &.{ .{ .key = .space }, .{ .controller = .{ .button = .south } } } },
        .{ .control = .move, .kind = .vector, .bindings = &.{ .{ .keys_2d = .{} }, .{ .controller_stick = .{} } } },
    },
});

const Hud = struct {
    pub const input_maps = .{PlayerInput};
    clicks: u32 = 0,
    gameplay_presses: u32 = 0,
    text: eggy.ui.TextEdit(128) = .{},
    player: eggy.EntityRef(eggy.Transform) = .{},

    /// Demo startup hook: install the bundled font, create a cube/camera and return HUD state.
    /// The App owns entities/UI; propagates font/GPU/entity allocation failures.
    /// The engine calls this after registering PlayerInput.
    ///
    /// ```zig
    /// // Fixture-host dispatch, normally performed by plugins.Set:
    /// var hud = try Hud.init(gpa, app);
    /// ```
    pub fn init(_: std.mem.Allocator, app: *eggy.App) !Hud {
        const layer = try app.gameUi();
        try layer.setFont(@embedFile("api_fixture_font"));
        const player = try app.world.spawn(.{ eggy.Name.init("API Cube"), eggy.Transform{}, eggy.Mesh{} });
        _ = try app.world.spawn(.{ eggy.Camera{}, eggy.Transform{ .position = .{ 0, 2, 7 }, .rotation_deg = .{ -15, 0, 0 } } });
        return .{ .player = .init(player) };
    }

    /// Demo gameplay hook: count mapped jumps and move the cube using gameplay seconds.
    /// Resolves the entity reference each call, skips deleted cubes and propagates input errors.
    ///
    /// ```zig
    /// try hud.update(app); // Once per running frame, before ECS Update systems.
    /// ```
    pub fn update(self: *Hud, app: *eggy.App) !void {
        const player = app.input.map(PlayerInput);
        if (try player.pressed(.jump)) self.gameplay_presses += 1;
        const transform = self.player.get(&app.world) orelse return;
        const direction = try player.vector(.move);
        transform.translate(.{ direction.x * app.time.delta_s, 0, direction.y * app.time.delta_s });
        app.world.markChanged(self.player.entity.?, eggy.Transform);
    }

    /// Build the demo's dark HUD into a borrowed, already-begun UI context.
    /// Updates local click/text state; the host renders it and isolates captured input.
    ///
    /// ```zig
    /// try hud.gameUi(app, ui); // During the host's game UI pass only.
    /// ```
    pub fn gameUi(self: *Hud, _: *eggy.App, ui: *eggy.ui.Context) !void {
        ui.theme = .dark;
        ui.heading(2, "Eggy developer API");
        ui.muted("Custom font, theme, widgets, and gameplay input isolation.");
        if (ui.button("Count UI click")) self.clicks += 1;
        _ = ui.textInput("UI text", &self.text, "Space here must not reach gameplay");
        ui.label("UI clicks: {d}", .{self.clicks});
        ui.label("Gameplay jump presses: {d}", .{self.gameplay_presses});
        ui.muted("Mapped keys or a controller move the cube outside UI keyboard focus.");
    }

    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "api-tools", .title = "API Tools" }};
    pub const editor_commands = [_]eggy.plugins.EditorCommand{.{ .key = "raise", .title = "Raise Selected Entity" }};

    /// Build panel index 0, providing an undoable raise-selection button.
    /// Borrows both contexts during the hook; selection/edit errors propagate to the Console.
    ///
    /// ```zig
    /// try hud.editorPanelUi(0, editor, ui); // Editor panel dispatch.
    /// ```
    pub fn editorPanelUi(self: *Hud, _: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        ui.heading(3, "Developer tools");
        if (ui.button("Raise selection")) try self.editorCommand(0, editor);
    }

    /// Raise the selected Transform by one metre through the host's undoable component edit.
    /// Fixture command index is 0. Missing selection/Transform is a no-op; edit errors propagate.
    ///
    /// ```zig
    /// try hud.editorCommand(0, editor); // The fixture's "Raise Selected Entity" command.
    /// ```
    pub fn editorCommand(_: *Hud, _: usize, editor: *eggy.editor.Context) !void {
        const entity = try editor.selection() orelse return;
        const transform = editor.app.world.get(entity, eggy.Transform) orelse return;
        var after = transform.*;
        after.position[1] += 1;
        try editor.changeComponent(entity, eggy.Action(eggy.Transform){ .before = transform.*, .after = after });
    }
};

const Custom = struct {
    pub const input_maps = .{PlayerInput};
    clicks: u32 = 0,
    gameplay_presses: u32 = 0,

    /// Count gameplay jump edges for the custom-renderer fixture; input errors propagate.
    /// The host invokes this only for running gameplay, after UI event consumption.
    ///
    /// ```zig
    /// try custom.update(app);
    /// ```
    pub fn update(self: *Custom, app: *eggy.App) !void {
        if (try app.input.map(PlayerInput).pressed(.jump)) self.gameplay_presses += 1;
    }

    /// A minimal custom renderer: clear the owned target without creating a Weeoui overlay.
    /// Requires no active render pass and `app.ui_layer == null`. Borrows `target` only for
    /// this frame; the host submits/presents it. Propagates render-pass setup errors.
    ///
    /// ```zig
    /// try custom.draw(app, draw_context); // After scene drawing, before frame submission.
    /// ```
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

    /// Consume mouse-button input and non-repeated Space presses for the custom UI.
    /// Returns true when gameplay must not see the event; increments/logs press counts.
    /// Borrows the event only during dispatch and may run while editor Play is paused.
    ///
    /// ```zig
    /// if (try custom.uiEvent(app, current)) return .run; // Host input routing.
    /// ```
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
