//! `SpriteAnimator`: plays a run of frames from a sprite sheet on its entity's `Sprite`, a
//! built-in component. The sheet is the sprite's image cut into a grid of `columns` by `rows`
//! equal frames, numbered from 0 left to right, top to bottom; `step` sets the sprite's
//! `region` to the frame due. Time is the game's, so a paused game holds its frame.
const std = @import("std");
const ecs = @import("clutch");
const Sprite = @import("sprite.zig").Sprite;

pub const SpriteAnimator = struct {
    /// Marks it in the editor (nf-md-filmstrip).
    pub const icon = "\u{f0231}";
    pub const category = "2D";
    /// It sets its `Sprite`'s region.
    pub const dependencies = .{Sprite};

    /// How the sheet is cut: frames across, and down.
    columns: u16 = 1,
    rows: u16 = 1,
    /// The run of frames played: where it starts, and how many.
    first_frame: u16 = 0,
    frame_count: u16 = 1,
    frames_per_second: f32 = 12,
    repeat: Repeat = .loop,
    playing: bool = true,
    /// How long it has played, in seconds.
    time_s: f32 = 0,

    pub const Repeat = enum { once, loop, ping_pong };

    /// The sheet's frame showing at `time_s`: within the run, as `repeat` says.
    pub fn frame(self: SpriteAnimator) u32 {
        const count: u32 = @max(1, self.frame_count);
        const ticks: f32 = self.time_s * self.frames_per_second;
        const tick: u32 = if (std.math.isFinite(ticks) and ticks > 0) @intFromFloat(@min(ticks, 1e9)) else 0;
        var along: u32 = 0;
        switch (self.repeat) {
            .once => along = @min(tick, count - 1),
            .loop => along = tick % count,
            // There and back without showing either end twice.
            .ping_pong => if (count > 1) {
                const bounce = tick % (2 * count - 2);
                along = if (bounce < count) bounce else 2 * count - 2 - bounce;
            },
        }
        return self.first_frame + along;
    }

    /// Frame `index`'s part of the sheet: left, top, right, bottom, as fractions of the image.
    pub fn region(self: SpriteAnimator, index: u32) [4]f32 {
        const columns: u32 = @max(1, self.columns);
        const rows: u32 = @max(1, self.rows);
        const column: f32 = @floatFromInt(index % columns);
        const row: f32 = @floatFromInt(@min(index / columns, rows - 1));
        const width = 1 / @as(f32, @floatFromInt(columns));
        const height = 1 / @as(f32, @floatFromInt(rows));
        return .{ column * width, row * height, (column + 1) * width, (row + 1) * height };
    }

    /// Whether a `once` run has shown its last frame.
    pub fn finished(self: SpriteAnimator) bool {
        return self.repeat == .once and self.time_s * self.frames_per_second >= @as(f32, @floatFromInt(@max(1, self.frame_count)));
    }
};

/// Advance every playing `SpriteAnimator` by `delta_s` and show its frame on its `Sprite`.
/// Host and game library alike, once per gameplay frame after the game's systems.
///
/// ```zig
/// sprite_animator.step(&app.world, app.time.delta_s);
/// ```
pub fn step(world: *ecs.World, delta_s: f32) void {
    var animators = world.query(.{ *SpriteAnimator, *Sprite });
    while (animators.next()) |view| {
        const animator = view.get(*SpriteAnimator);
        if (animator.playing and std.math.isFinite(delta_s)) animator.time_s += delta_s;
        view.get(*Sprite).region = animator.region(animator.frame());
    }
}
