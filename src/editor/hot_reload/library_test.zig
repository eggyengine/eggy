//! Hot reload for real, using a headless API fixture game.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("hot_reload.zig").HotGame;
const history_zig = @import("../history.zig");

const Source = struct {
    fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
        if (!std.mem.eql(u8, path, "resources/player.inmap.zon")) return error.FileNotFound;
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
    const path = try std.fs.path.resolve(gpa, &.{@import("test_library").path});
    defer gpa.free(path);
    var app: eggy.App = undefined;
    app.world = .init(gpa);
    const backend = try attachInput(&app, gpa);
    defer backend.deinit();
    app.time = .{};
    app.instances = null;
    app.ui_layer = null;
    app.scene_access = null;
    var resource_context: u8 = 0;
    app.resource_provider = eggy.resources.Resources.from(&resource_context, Source.read, Source.model, Source.image);
    defer app.world.deinit();
    app.preference_values = .init(gpa);
    defer app.preference_values.deinit();

    var game = try HotGame.load(gpa, path);
    game.start(&app, &.{}, .keep);
    game.update(&app);
    try std.testing.expect(game.state != null);
    try std.testing.expectEqual(@as(usize, 2), backend.state.owners.count());
    try std.testing.expectEqualStrings("game/fixture", game.file_types[0].key);
    try std.testing.expectEqualStrings("ab\x00cd", game.file_types[0].contents);
    try std.testing.expect(@intFromPtr(game.file_types[0].title.ptr) != @intFromPtr(game.game.file_types[0].title));
    const first_copy = try gpa.dupe(u8, game.copy_path);
    defer gpa.free(first_copy);

    // A swap loads a copy of its own and deletes the old one.
    try game.reload(&app);
    game.start(&app, &.{}, .keep);
    game.update(&app);
    try std.testing.expect(game.state != null);
    try std.testing.expectEqualStrings("game/fixture", game.file_types[0].key);
    try std.testing.expectEqualStrings("ab\x00cd", game.file_types[0].contents);
    try std.testing.expect(!std.mem.eql(u8, first_copy, game.copy_path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, first_copy, .{}));

    const last_copy = try gpa.dupe(u8, game.copy_path);
    defer gpa.free(last_copy);
    game.deinit(&app);
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
    var resource_context: u8 = 0;
    app.resource_provider = eggy.resources.Resources.from(&resource_context, Source.read, Source.model, Source.image);
    const backend = try attachInput(&app, gpa);
    defer backend.deinit();
    try backend.state.readOverrides(".{ .controls = .{ .{ .owner = \"game/player\", .name = \"jump\", .bindings = .{ .{ .key = .j } } }, .{ .owner = \"game/asset-player\", .name = \"jump\", .bindings = .{ .{ .key = .j } } } } }");
    app.time = .{};
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
