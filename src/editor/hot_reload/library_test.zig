//! Hot reload for real, using a headless API fixture game.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("hot_reload.zig").HotGame;
const history_zig = @import("../history.zig");

const Source = struct {
    fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
        if (!std.mem.eql(u8, path, eggy.AssetRef(.input_map).fromId(43).key())) return error.FileNotFound;
        return gpa.dupeZ(u8,
            \\.{ .controls = .{
            \\    .{ .name = "move", .kind = .vector, .bindings = .{ .{ .keys_2d = .{} } } },
            \\    .{ .name = "jump", .bindings = .{ .{ .key = .space } } },
            \\} }
        );
    }
    fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !eggy.assets.Model {
        return error.NotPackaged;
    }
    fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !eggy.assets.Texture {
        return error.OutOfMemory;
    }
};

fn attachInput(app: *eggy.App, gpa: std.mem.Allocator) !*eggy.input_backend.Backend {
    const backend = try gpa.create(eggy.input_backend.Backend);
    backend.* = .{ .gpa = gpa, .state = .init(gpa) };
    app.input_backend = backend;
    app.input = .{ .backend = backend.state.interface() };
    return backend;
}

test "the game's library loads, runs, swaps for a fresh copy, and unloads cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const sdl = eggy.sdl_adapter.sdl;
    const use_dummy = (try sdl.getEnvironment()).getVariable("SDL_VIDEODRIVER") == null;
    if (use_dummy) try sdl.hints.set(.video_driver, "dummy");
    defer if (use_dummy) sdl.hints.reset(.video_driver) catch @panic("cannot reset dummy video driver");
    try sdl.init(.{ .video = true });
    defer sdl.quit(.{ .video = true });
    const window = try sdl.video.Window.init("SDL host", 320, 240, .{ .hidden = true });
    defer window.deinit();
    const path = try std.fs.path.resolve(gpa, &.{@import("test_library").path});
    defer gpa.free(path);
    var app: eggy.App = undefined;
    app.window = .init(window);
    app.world = .init(gpa);
    const backend = try attachInput(&app, gpa);
    defer backend.deinit();
    app.time = .{};
    app.resource_jobs = null;
    app.instances = null;
    app.ui_layer = null;
    app.scene_access = null;
    app.scene_transition = .{};
    app.storage = .{};
    app.debug_draw = .{};
    app.draw2d = .{ .gpa = gpa };
    app.ui_scenes = .{ .gpa = gpa };
    defer app.ui_scenes.deinit();
    defer app.draw2d.deinit();
    app.profiling = .{};
    var resource_context: u8 = 0;
    app.resource_provider = eggy.resources.Resources.from(&resource_context, Source.read, Source.model, Source.image);
    defer app.world.deinit();
    app.preference_values = .init(gpa);
    defer app.preference_values.deinit();

    var game = try HotGame.load(gpa, path);
    var game_loaded = true;
    defer if (game_loaded) game.deinit(&app);
    game.start(&app, &.{}, .keep);
    game.update(&app);
    var editor = eggy.editor.Context{ .app = &app, .host = undefined };
    game.editorCommand(3, &editor);
    try std.testing.expectEqualStrings("SDL shared across reload", window.getTitle().?);
    try std.testing.expect(game.state != null);
    try std.testing.expectEqual(@as(usize, 2), backend.state.owners.count());
    try std.testing.expectEqualStrings("game/fixture", game.file_types[0].key);
    try std.testing.expectEqualStrings("ab\x00cd", game.file_types[0].contents);
    try std.testing.expect(@intFromPtr(game.file_types[0].title.ptr) != @intFromPtr(game.game.file_types[0].title));
    const first_copy = try gpa.dupe(u8, game.copy_path);
    defer gpa.free(first_copy);

    // A swap loads a copy of its own and deletes the old one.
    try game.reload(&app);
    try window.setTitle("SDL host after reload");
    game.start(&app, &.{}, .keep);
    game.update(&app);
    game.editorCommand(3, &editor);
    try std.testing.expectEqualStrings("SDL shared across reload", window.getTitle().?);
    try std.testing.expect(game.state != null);
    try std.testing.expectEqualStrings("game/fixture", game.file_types[0].key);
    try std.testing.expectEqualStrings("ab\x00cd", game.file_types[0].contents);
    try std.testing.expect(!std.mem.eql(u8, first_copy, game.copy_path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, first_copy, .{}));

    const last_copy = try gpa.dupe(u8, game.copy_path);
    defer gpa.free(last_copy);
    game.deinit(&app);
    game_loaded = false;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, last_copy, .{}));
}

const ActionHost = struct {
    app: *eggy.App,
    game: *HotGame,
    history: history_zig.History,
    before: ?[]u8 = null,

    fn snapshot(self: *ActionHost) ![]u8 {
        var scene = try eggy.scene.Scene.capture(self.history.gpa, &self.app.world, self.game.sceneAccess(), null);
        defer scene.deinit();
        var text: std.Io.Writer.Allocating = .init(self.history.gpa);
        defer text.deinit();
        try scene.write(&text.writer);
        return text.toOwnedSlice();
    }

    fn request(raw: *anyopaque, input: *const eggy.editor.Request, _: *eggy.editor.Response) callconv(.c) eggy.editor.Status {
        const self: *ActionHost = @ptrCast(@alignCast(raw));
        self.perform(input.operation) catch |err| return if (err == error.OutOfMemory) .out_of_memory else .failed;
        return .ok;
    }

    fn perform(self: *ActionHost, operation: eggy.editor.Operation) !void {
        switch (operation) {
            .begin_edit => {
                try self.history.reserve();
                self.before = try self.snapshot();
            },
            .commit_edit => {
                const after = try self.snapshot();
                self.history.record(.{ .scene = .{ .before = self.before.?, .after = after } });
                self.before = null;
            },
            .cancel_edit => {
                if (self.before) |before| self.history.gpa.free(before);
                self.before = null;
            },
            else => return error.UnexpectedRequest,
        }
    }

    fn apply(self: *ActionHost, step: *history_zig.Step, direction: eggy.Direction) !void {
        const source = try self.history.gpa.dupeZ(u8, step.scene.value(direction));
        defer self.history.gpa.free(source);
        var scene = try eggy.scene.Scene.parse(self.history.gpa, source);
        defer scene.deinit();
        self.game.restart(self.app, &scene, &.{}, .keep);
    }

    fn expectCounter(self: *ActionHost, expected: []const u8) !void {
        const component = for (self.game.component_types, 0..) |info, index| {
            if (std.mem.eql(u8, info.name, "Counter")) break index;
        } else return error.NoCounter;
        const entity = for (self.app.world.slots.items, 0..) |slot, index| {
            if (slot.alive) break eggy.ecs.EntityId.init(@intCast(index), slot.generation);
        } else return error.NoEntity;
        var buffer: [128]u8 = undefined;
        try std.testing.expectEqualStrings(expected, self.game.readField(self.app, entity, component, 0, &buffer).?);
        const text = try self.game.sceneAccess().readFieldAlloc(self.history.gpa, &self.app.world, entity, component, 0);
        defer self.history.gpa.free(text);
        try std.testing.expectEqualStrings(expected, text);
        try std.testing.expectError(error.NoSuchComponent, self.game.sceneAccess().readFieldAlloc(self.history.gpa, &self.app.world, entity, component, 1));
    }
};

test "typed actions and game UI cross the real ABI and undo after library replacement" {
    const gpa = std.testing.allocator;
    const path = try std.fs.path.resolve(gpa, &.{@import("test_library").path});
    defer gpa.free(path);
    var app: eggy.App = undefined;
    app.world = .init(gpa);
    defer app.world.deinit();
    app.preference_values = .init(gpa);
    defer app.preference_values.deinit();
    app.instances = null;
    app.ui_layer = null;
    app.scene_access = null;
    app.scene_transition = .{};
    app.storage = .{};
    app.debug_draw = .{};
    app.draw2d = .{ .gpa = gpa };
    app.ui_scenes = .{ .gpa = gpa };
    defer app.ui_scenes.deinit();
    defer app.draw2d.deinit();
    app.profiling = .{};
    var resource_context: u8 = 0;
    app.resource_provider = eggy.resources.Resources.from(&resource_context, Source.read, Source.model, Source.image);
    const backend = try attachInput(&app, gpa);
    defer backend.deinit();
    try backend.state.readOverrides(".{ .controls = .{ .{ .owner = \"game/player\", .name = \"jump\", .bindings = .{ .{ .key = .j } } }, .{ .owner = \"game/asset-player\", .name = \"jump\", .bindings = .{ .{ .key = .j } } } } }");
    app.time = .{};
    app.resource_jobs = null;
    var game = try HotGame.load(gpa, path);
    defer game.deinit(&app);
    game.start(&app, &.{}, .keep);
    var host = ActionHost{ .app = &app, .game = &game, .history = .{ .gpa = gpa } };
    defer host.history.deinit();
    defer if (host.before) |before| gpa.free(before);
    var editor = eggy.editor.Context{ .app = &app, .host = .{ .context = &host, .request = ActionHost.request } };
    game.editorCommand(1, &editor);
    try host.expectCounter("2");
    try std.testing.expectEqual(@as(usize, 1), host.history.undo_steps.items.len);
    const press = eggy.Event{ .key_down = .{ .common = undefined, .id = null, .scancode = .j, .key = null, .mod = .{}, .raw = 0, .down = true, .repeat = false } };
    try app.input.handle(press);
    game.editorCommand(2, &editor);
    try host.expectCounter("3");
    // The plugin bars cross the boundary as data, and their entries run through it.
    try std.testing.expectEqual(@as(usize, 2), game.menus.len);
    try std.testing.expectEqualStrings("game/counter", game.menus[0].key);
    try std.testing.expectEqualStrings("game/counter/odd", game.menus[0].items[1].key);
    try std.testing.expectEqualStrings("Ctrl+1", game.menus[0].items[0].shortcut);
    try std.testing.expectEqual(eggy.plugins.BuiltinMenu.view, game.menus[1].extends.?);
    try std.testing.expectEqual(@as(?eggy.plugins.BuiltinMenu, null), game.menus[0].extends);
    try std.testing.expectEqual(eggy.plugins.StatusSide.right, game.status_items[0].side);
    try std.testing.expectEqualStrings("game/mode/reset", game.status_items[1].items[0].key);
    try std.testing.expect(@intFromPtr(game.menus[0].title.ptr) != @intFromPtr(game.game.menus[0].title));
    try std.testing.expectEqualStrings("3", game.barState(.{ .status = 0 }, &editor).text());
    try std.testing.expect(game.barState(.{ .menu_item = .{ .menu = 0, .item = 1 } }, &editor).checked);
    game.barAction(.{ .menu_item = .{ .menu = 0, .item = 0 } }, &editor);
    try host.expectCounter("4");
    game.barAction(.{ .status_item = .{ .status = 1, .item = 0 } }, &editor);
    try host.expectCounter("5");
    // Rows the library doesn't have are ignored.
    game.barAction(.{ .menu_item = .{ .menu = 9, .item = 0 } }, &editor);
    game.barAction(.{ .menu_item = .{ .menu = 0, .item = 7 } }, &editor);
    try host.expectCounter("5");
    try std.testing.expect(!game.barState(.{ .status_item = .{ .status = 4, .item = 0 } }, &editor).enabled);
    try std.testing.expect(try host.history.apply(.undo, &host, ActionHost.apply));
    try std.testing.expect(try host.history.apply(.undo, &host, ActionHost.apply));
    try host.expectCounter("3");
    {
        var ui = try eggy.ui.Context.init(gpa);
        defer ui.deinit();
        ui.newFrame(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
        game.gameUi(&app, &ui);
        try std.testing.expect((try ui.render()).len > 0);
        ui.newFrame(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
        game.editorPanelUi(0, &editor, &ui);
        try std.testing.expect((try ui.render()).len > 0);
    }
    // Animation preview crosses the boundary: assign, pose, and end without leaving a trace.
    {
        const authored = eggy.AssetRef(.animation).fromId(44).key();
        const imported = eggy.AssetRef(.animation).fromId(45).key();
        app.graphics.clips = .{ .gpa = gpa };
        defer app.graphics.clips.deinit();
        try app.graphics.clips.replace(authored, .{ .duration_s = 1, .tracks = &.{} });
        const actor = try app.world.spawn(.{});
        try std.testing.expect(game.assignAnimation(&app, actor, authored, false));
        try std.testing.expect(game.assignAnimation(&app, actor, imported, true));
        try std.testing.expect(!game.assignAnimation(&app, actor, "not an asset", false));
        try std.testing.expect(!game.showAnimationPreview(&app, authored, imported, 1));
        try std.testing.expect(game.beginAnimationPreview(&app, actor));
        try std.testing.expect(game.showAnimationPreview(&app, authored, imported, 1));
        game.endAnimationPreview(&app);
        try std.testing.expect(!game.showAnimationPreview(&app, authored, imported, 1));
        const targets = try game.animationTargets(gpa, &app, actor);
        defer gpa.free(targets);
        try std.testing.expectEqual(@as(usize, 0), targets.len);
        try std.testing.expectEqual(@as(?[9]f32, null), game.animationTransform(&app, actor, ""));
        var model: [64]u8 = undefined;
        try std.testing.expectEqual(@as(?[]const u8, null), game.animationModel(&app, actor, &model));
    }
    var kept = try eggy.scene.Scene.capture(gpa, &app.world, game.sceneAccess(), null);
    defer kept.deinit();
    try game.reload(&app);
    const restored = try kept.instantiate(gpa, &app.world, game.sceneAccess(), null);
    gpa.free(restored.entities);
    game.start(&app, &.{}, .keep);
    try host.expectCounter("3");
    try std.testing.expect(try host.history.apply(.undo, &host, ActionHost.apply));
    try host.expectCounter("2");
    try std.testing.expect(try host.history.apply(.redo, &host, ActionHost.apply));
    try host.expectCounter("3");
    try app.input.handle(press);
    game.editorCommand(2, &editor);
    try host.expectCounter("4");
}
