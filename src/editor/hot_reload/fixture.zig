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
const AssetPlayer = eggy.input.FileMap(enum { jump, move }, .{ .key = "asset-player", .file = "resources/player.inmap.zon" });
pub const Game = struct {
    entity: eggy.ecs.EntityId,
    pub const components = .{Counter};
    pub const input_maps = .{ Player, AssetPlayer };
    pub const editor_file_types = [_]eggy.plugins.EditorFileType{.{
        .key = "fixture",
        .title = "Fixture",
        .extension = ".fixture",
        .contents = "ab\x00cd",
    }};
    pub const editor_commands = [_]eggy.plugins.EditorCommand{
        .{ .key = "increment", .title = "Increment" },
        .{ .key = "read-resource", .title = "Check resource errors" },
        .{ .key = "read-input", .title = "Check mapped input" },
        .{ .key = "sdl-window", .title = "Check shared SDL window" },
    };
    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "counter", .title = "Counter" }};
    pub const editor_menus = [_]eggy.plugins.EditorMenu{
        .{ .key = "counter", .title = "Counter", .items = &.{ .{ .key = "add", .title = "Add One", .shortcut = "Ctrl+1" }, .{ .key = "odd", .title = "Odd", .checkable = true } } },
        .{ .key = "view-extra", .title = "Extra", .extends = .view, .items = &.{.{ .key = "noop", .title = "Nothing" }} },
    };
    pub const editor_status_items = [_]eggy.plugins.EditorStatusItem{
        .{ .key = "value", .title = "Counter", .side = .right },
        .{ .key = "mode", .title = "Mode", .items = &.{.{ .key = "reset", .title = "Reset" }} },
    };

    /// Add one to the Counter for "Add One" (menu 0, row 0) and the Mode > Reset row's status
    /// entry (which also adds, so the test sees a status menu row dispatch); other entries do nothing.
    /// Fixture-only: the Counter must exist; history/service errors propagate.
    ///
    /// ```zig
    /// try fixture.editorBarAction(.{ .menu_item = .{ .menu = 0, .item = 0 } }, &editor_context);
    /// ```
    pub fn editorBarAction(self: *Game, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) !void {
        const pressed = switch (target) {
            .menu_item => |t| t.menu == 0 and t.item == 0,
            .status_item => |t| t.status == 1 and t.item == 0,
            .status => false,
        };
        if (pressed) try self.editorCommand(0, editor);
    }

    /// Check "Odd" while the Counter is odd, and show the Counter's value as the first status
    /// item's text. Fixture-only: the Counter must exist.
    ///
    /// ```zig
    /// try fixture.editorBarState(.{ .status = 0 }, &editor_context, &state);
    /// ```
    pub fn editorBarState(self: *Game, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context, state: *eggy.plugins.EditorBarState) !void {
        const counter = editor.app.world.get(self.entity, Counter) orelse return error.NoCounter;
        switch (target) {
            .menu_item => |t| state.checked = t.menu == 0 and t.item == 1 and counter.value % 2 == 1,
            .status => |s| if (s == 0) {
                var buffer: [16]u8 = undefined;
                state.setText(try std.fmt.bufPrint(&buffer, "{d}", .{counter.value}));
            },
            .status_item => {},
        }
    }

    /// Initialize the shared-library test game, reusing "API Entity" or spawning its Counter.
    /// Fixture-only: ignores the allocator argument; the App world owns the entity and spawn
    /// errors propagate. Reusing a named entity does not add a missing Counter.
    ///
    /// ```zig
    /// // Fixture context: existing test App pointer and allocator.
    /// var fixture = try Game.init(gpa, app);
    /// ```
    pub fn init(_: std.mem.Allocator, app: *eggy.App) !Game {
        return .{ .entity = eggy.findNamed(&app.world, "API Entity") orelse try app.world.spawn(.{ eggy.Name.init("API Entity"), Counter{} }) };
    }
    /// Exercise host services in the shared-library fixture: 0 increments with undo, 1 checks
    /// missing resources then increments, 2 checks input/rebinding then increments, and 3
    /// checks shared SDL state and changes the title without incrementing.
    /// Fixture-only: requires initialized Counter, hook-local host services and each command's
    /// prepared test environment; assertion/service/SDL errors propagate with prior side effects.
    ///
    /// ```zig
    /// // Fixture context: initialized Game and editor service context for its App.
    /// try fixture.editorCommand(0, &editor_context);
    /// ```
    pub fn editorCommand(self: *Game, command: usize, editor: *eggy.editor.Context) !void {
        if (command == 3) {
            const sdl = eggy.sdl_adapter.sdl;
            if (!sdl.wasInit(.{ .video = true }).video) return error.SdlVideoNotShared;
            const window = editor.app.window.window;
            try sdl.mouse.hide();
            if (sdl.mouse.visible()) return error.CursorNotHidden;
            try sdl.mouse.show();
            if (!sdl.mouse.visible()) return error.CursorNotShown;
            try sdl.mouse.setWindowRelativeMode(window, true);
            if (!sdl.mouse.getWindowRelativeMode(window)) return error.MouseNotRelative;
            // The game's releaseMouse hook must use the host's SDL instance too.
            if (sdl.mouse.getWindowRelativeMode(window)) try sdl.mouse.setWindowRelativeMode(window, false);
            if (sdl.mouse.getWindowRelativeMode(window)) return error.MouseStillRelative;
            try sdl.mouse.setWindowRelativeMode(window, false);
            try sdl.mouse.setWindowGrab(window, false);
            try window.setKeyboardGrab(false);
            // SDL's dummy driver deliberately has no OS capture or confinement.
            if (!std.mem.eql(u8, sdl.video.getCurrentDriverName().?, "dummy")) {
                // Wayland's implicit grab is released by the compositor, not SDL_CaptureMouse.
                if (!std.mem.eql(u8, sdl.video.getCurrentDriverName().?, "wayland")) try sdl.mouse.capture(false);
                try sdl.mouse.setWindowRect(window, null);
            }
            try window.setTitle("SDL shared across reload");
            return;
        }
        if (command == 2) {
            const player = editor.app.input.map(Player);
            if (!try player.pressed(.jump)) return error.ExpectedMappedPress;
            const gpa = editor.app.world.allocator;
            const bindings = try player.getBindingsAlloc(gpa, .jump);
            defer gpa.free(bindings);
            if (bindings[0].key != .j) return error.ExpectedProjectBinding;
            if (player.axis(.jump)) |_| return error.ExpectedWrongKind else |err| if (err != error.WrongControlKind) return err;
            const asset_player = editor.app.input.map(AssetPlayer);
            if (!try asset_player.pressed(.jump)) return error.ExpectedAssetMappedPress;
            const asset_bindings = try asset_player.getBindingsAlloc(gpa, .jump);
            defer gpa.free(asset_bindings);
            if (asset_bindings[0].key != .j) return error.ExpectedProjectAssetBinding;
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
    /// Draw the fixture Counter label into an active UI frame; return NoCounter if absent.
    /// Fixture-only: the entity must belong to `app`; label storage belongs to the UI frame.
    ///
    /// ```zig
    /// try fixture.gameUi(app, context); // Fixture Game, matching App, building UI context.
    /// ```
    pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
        const counter = app.world.get(self.entity, Counter) orelse return error.NoCounter;
        ui.label("Counter: {d}", .{counter.value});
    }
    /// Draw the fixture's Counter panel through `gameUi`, ignoring the panel index.
    /// Fixture-only: contexts are borrowed during the hook; a missing Counter error propagates.
    ///
    /// ```zig
    /// try fixture.editorPanelUi(0, &editor_context, context); // Live fixture UI/host contexts.
    /// ```
    pub fn editorPanelUi(self: *Game, _: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        try self.gameUi(editor.app, ui);
    }
    /// Consume exactly key-down events to test priority routing; never fails or mutates state.
    /// Fixture-only: no event pointer is retained.
    ///
    /// ```zig
    /// const consumed = try fixture.uiEvent(app, event); // Fixture Game/App and Eggy event.
    /// ```
    pub fn uiEvent(_: *Game, _: *eggy.App, event: eggy.Event) !bool {
        return event == .key_down;
    }
};
