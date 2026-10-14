//! The sandbox game: the smallest game Eggy runs, and the example to copy for your own.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

/// An example component: how far an entity has turned, advanced by the `spin` system.
const Spin = struct { turns: u64 = 0 };

fn spin(spinners: ecs.Query(.{*Spin})) !void {
    var iter = spinners;
    while (iter.next()) |view| view.get(*Spin).turns += 1;
}

pub const Game = struct {
    frames: u64 = 0,
    entities: usize = 0,
    /// The first spinner's turns, read back from the world each frame.
    turns: u64 = 0,
    first: ecs.EntityId,

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Game {
        _ = gpa;
        // Register systems in `init`; eggy runs the world's stages from then on.
        app.world.addSchedule(ecs.Schedule(.Update, .{spin}));
        const first = try app.world.spawn(.{Spin{}});
        for (0..2) |_| _ = try app.world.spawn(.{Spin{}});
        return .{ .first = first };
    }

    pub fn update(self: *Game, app: *eggy.App) !void {
        self.frames += 1;
        self.entities = app.world.entityCount();
        self.turns = app.world.get(self.first, Spin).?.turns;
    }

    pub fn editorUi(self: *Game, ui: *eggy.ui.Context) void {
        ui.label("Frames: {d}", .{self.frames});
        ui.label("Entities: {d} (first has turned {d} times)", .{ self.entities, self.turns });
    }
};
