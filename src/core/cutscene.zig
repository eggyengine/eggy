//! Cutscenes in play: while an `Animator` whose `takes_over` asks for it plays its clip, the
//! player's input is held back from the game (holding Escape skips to the end), the `UiScreen`s
//! the clip doesn't animate are hidden, and the view is letterboxed. `App.updateWorld` updates
//! the `Cutscene` after the animation step; hosts then route input through `event`, filter the
//! screens with `hideHud` and draw the bars and the skip ring with `draw`.
const std = @import("std");
const ecs = @import("clutch");
const ui = @import("weeoui");
const sdl = @import("vitellus_sdl3").sdl;
const animation = @import("animation.zig");
const Animator = animation.Animator;
const Takeover = animation.Takeover;
const ClipCache = @import("clip_cache.zig").ClipCache;
const ui_scenes = @import("ui_scenes/ui_scenes.zig");

/// How long Escape is held to skip, in seconds.
pub const skip_hold_s: f32 = 1;
/// The letterbox bars' height, as a share of the view's.
const bar_share: f32 = 0.1;
/// How fast the bars slide in and out: shares of the way per second.
const bar_rate: f32 = 4;
/// Over the game's screens, under the loading screen and the dev console.
const z_index = 200;

pub const Cutscene = struct {
    /// What the cutscenes playing now take, all together.
    takeover: Takeover = .nothing,
    escape_held: bool = false,
    /// How long Escape has been held while input is taken.
    skip_held_s: f32 = 0,
    /// How far the letterbox is in, from 0 (gone) to 1.
    bars: f32 = 0,

    /// Find what the playing cutscenes take, and skip them when Escape has been held long
    /// enough. Returns whether input was just taken, for the host to forget what is held.
    /// Host-only, once a gameplay frame after `animation.step`; `real_delta_s` is unscaled.
    pub fn update(self: *Cutscene, world: *ecs.World, clips: *ClipCache, real_delta_s: f32, effects: animation.Effects) bool {
        const before = self.takeover;
        self.takeover = taken(world, clips);
        if (!self.takeover.takesInput()) {
            self.skip_held_s = 0;
        } else if (self.escape_held) {
            self.skip_held_s += real_delta_s;
            if (self.skip_held_s >= skip_hold_s) {
                skipAll(world, clips, effects);
                self.skip_held_s = 0;
                self.escape_held = false;
                self.takeover = taken(world, clips);
            }
        }
        const goal: f32 = if (self.takeover.takesHud()) 1 else 0;
        const moved = bar_rate * @max(real_delta_s, 0);
        self.bars = if (self.bars < goal) @min(goal, self.bars + moved) else @max(goal, self.bars - moved);
        return self.takeover.takesInput() and !before.takesInput();
    }

    /// Whether `event` is held back from the game: player input while a cutscene takes it. It
    /// watches Escape for the skip. Host-only, after the game's UI has had its turn (so a
    /// dialogue's buttons still take presses) and before `Input.handle`.
    pub fn event(self: *Cutscene, value: sdl.events.Event) bool {
        if (!self.takeover.takesInput()) return false;
        switch (value) {
            .key_down => |key| if (key.scancode == .escape) {
                self.escape_held = true;
            },
            .key_up => |key| if (key.scancode == .escape) {
                self.escape_held = false;
                self.skip_held_s = 0;
            },
            else => {},
        }
        return isPlayerInput(value);
    }

    /// Take out of `state`'s gathered screens those a HUD-taking cutscene doesn't animate. Host-
    /// only, after the screens are gathered and before they are built.
    pub fn hideHud(self: *const Cutscene, world: *ecs.World, clips: *ClipCache, state: *ui_scenes.State) void {
        if (!self.takeover.takesHud()) return;
        var kept: usize = 0;
        for (state.screens[0..state.screen_count]) |screen| {
            if (!animatedByCutscene(world, clips, screen.entity())) continue;
            state.screens[kept] = screen;
            kept += 1;
        }
        state.screen_count = kept;
    }

    /// Whether `draw` has anything to show, so a host knows to build its UI layer this frame.
    pub fn shows(self: *const Cutscene) bool {
        return self.bars > 0 or self.skip_held_s > 0;
    }

    /// Letterbox the view, and while Escape is held, show how close the skip is. The bars take
    /// no presses. Host-only: call where the game UI is built.
    pub fn draw(self: *const Cutscene, context: *ui.Context) void {
        const viewport = context.viewport;
        const arena = context.builder().allocator;
        const bar_h = @round(viewport.h * bar_share * easeInOut(self.bars));
        if (bar_h >= 1) for ([_]f32{ viewport.y, viewport.y + viewport.h - bar_h }, 0..) |top, index| {
            const bar = context.builder().node(context.idFor(if (index == 0) "##cutscene bar top" else "##cutscene bar bottom"), .{ .width = viewport.w, .height = bar_h, .z_index = z_index }, .{ .custom = .{ .context = &black, .draw = drawBar } }, &.{}) catch return;
            bar.overlay = .{ .point = .init(viewport.x, top) };
            context.element(bar);
        };
        if (self.skip_held_s <= 0) return;
        const ring = arena.create(SkipRing) catch return;
        ring.* = .{ .fraction = std.math.clamp(self.skip_held_s / skip_hold_s, 0, 1) };
        const width: f32 = 150;
        const height: f32 = 28;
        const hint = context.builder().node(context.idFor("##cutscene skip"), .{ .width = width, .height = height, .z_index = z_index + 1 }, .{ .custom = .{ .context = ring, .draw = SkipRing.draw } }, &.{}) catch return;
        hint.overlay = .{ .point = .init(viewport.x + viewport.w - width - 24, viewport.y + 20) };
        hint.accessibility = .{ .role = .progress, .label = "Hold Esc to skip", .numeric_value = ring.fraction };
        context.element(hint);
    }
};

/// What the cutscenes under way in `world` take, all together (one paused at a choice still
/// takes them).
pub fn taken(world: *ecs.World, clips: *ClipCache) Takeover {
    var input = false;
    var hud = false;
    var animators = world.query(.{*const Animator});
    while (animators.next()) |view| {
        const animator = view.get(*const Animator).*;
        if (animator.takes_over == .nothing or !animation.inProgress(animator, clips)) continue;
        input = input or animator.takes_over.takesInput();
        hud = hud or animator.takes_over.takesHud();
    }
    if (input and hud) return .input_and_hud;
    if (input) return .input;
    if (hud) return .hud;
    return .nothing;
}

/// Jump every input-taking cutscene to its end, firing the keys it skips over so the game hears
/// every event (a quest still starts).
fn skipAll(world: *ecs.World, clips: *ClipCache, effects: animation.Effects) void {
    var animators = world.query(.{*Animator});
    while (animators.next()) |view| {
        const animator = view.get(*Animator);
        if (!animator.takes_over.takesInput() or !animation.inProgress(animator.*, clips)) continue;
        animation.skipToEnd(world, view.entity, clips, effects);
    }
}

/// Whether a HUD-taking cutscene playing now acts on `entity` (or is it).
fn animatedByCutscene(world: *ecs.World, clips: *ClipCache, entity: ecs.EntityId) bool {
    var animators = world.query(.{*const Animator});
    while (animators.next()) |view| {
        const animator = view.get(*const Animator).*;
        if (!animator.takes_over.takesHud() or !animation.inProgress(animator, clips)) continue;
        if (view.entity.eql(entity)) return true;
        const clip = clips.authored(animator.clip.key()) orelse continue;
        for (clip.tracks) |track| {
            const target = animation.trackTarget(world, view.entity, track) orelse continue;
            if (target.eql(entity)) return true;
        }
    }
    return false;
}

/// Player input the game would see: keys, pointers, touches and controllers.
fn isPlayerInput(event: sdl.events.Event) bool {
    return switch (event) {
        .key_down, .key_up, .text_input, .text_editing, .mouse_motion, .mouse_button_down, .mouse_button_up, .mouse_wheel => true,
        .gamepad_axis_motion, .gamepad_button_down, .gamepad_button_up, .finger_down, .finger_up, .finger_motion, .finger_canceled => true,
        else => false,
    };
}

const black: [3]f32 = .{ 0, 0, 0 };

fn drawBar(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const color: *const [3]f32 = @ptrCast(@alignCast(context));
    try c.rect(r, color.*);
}

fn easeInOut(t: f32) f32 {
    const c = std.math.clamp(t, 0, 1);
    return c * c * (3 - 2 * c);
}

/// "Hold Esc to skip" beside a ring filling as Escape is held.
const SkipRing = struct {
    fraction: f32,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const SkipRing = @ptrCast(@alignCast(context));
        const radius: f32 = 9;
        const center = [2]f32{ r.x + radius + 2, r.y + r.h / 2 };
        const muted = [4]f32{ 1, 1, 1, 0.25 };
        const full = [4]f32{ 1, 1, 1, 0.95 };
        // The ring as short segments: the filled part bright, the rest faint.
        const segments = 32;
        for (0..segments) |index| {
            const a0 = (@as(f32, @floatFromInt(index)) / segments) * std.math.tau - std.math.pi / 2.0;
            const a1 = (@as(f32, @floatFromInt(index + 1)) / segments) * std.math.tau - std.math.pi / 2.0;
            const color = if (@as(f32, @floatFromInt(index)) / segments < self.fraction) full else muted;
            const inner = radius - 2.5;
            const p0 = [2]f32{ center[0] + @cos(a0) * radius, center[1] + @sin(a0) * radius };
            const p1 = [2]f32{ center[0] + @cos(a1) * radius, center[1] + @sin(a1) * radius };
            const q0 = [2]f32{ center[0] + @cos(a0) * inner, center[1] + @sin(a0) * inner };
            const q1 = [2]f32{ center[0] + @cos(a1) * inner, center[1] + @sin(a1) * inner };
            try c.triangle(.{ p0, p1, q1 }, .{ color, color, color });
            try c.triangle(.{ p0, q1, q0 }, .{ color, color, color });
        }
        try c.textIn(.{ .x = r.x + 2 * radius + 10, .y = r.y, .w = r.w - 2 * radius - 10, .h = r.h }, "Hold Esc to skip", 13, full[0..3].*, .start);
    }
};

test "a cutscene takes input and the HUD while it plays, Escape held skips it, and its events still fire" {
    const gpa = std.testing.allocator;
    const assets = @import("eggy_assets");
    const Name = @import("name.zig").Name;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    const key = @import("refs.zig").AssetRef(.animation).fromId(0x51).key();
    try cache.replace(key, .{ .duration_s = 10, .tracks = &[_]assets.clip.Track{
        .{ .target = "/dialogue", .property = .visible, .interpolation = .step, .keys = &.{.{ .time_s = 0, .value = .{ 1, 0, 0 } }} },
        .{ .target = "", .property = .event, .interpolation = .step, .keys = &.{.{ .time_s = 9, .text = "start_quest" }} },
    } });
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var events: std.ArrayList(animation.Event) = .empty;
    defer events.deinit(gpa);
    const effects = animation.Effects{ .events = &events, .gpa = gpa };
    const hud = try world.spawn(.{ Name.init("hud"), ui_scenes.UiScreen{ .scene = .fromId(0x61) } });
    const dialogue = try world.spawn(.{ Name.init("dialogue"), ui_scenes.UiScreen{ .scene = .fromId(0x62) } });
    const intro = try world.spawn(.{ Name.init("intro"), Animator{ .clip = .fromId(0x51), .playing = false, .takes_over = .input_and_hud } });

    // Nothing plays: nothing is taken.
    var cutscene = Cutscene{};
    try std.testing.expect(!cutscene.update(&world, &cache, 0.1, effects));

    // Started, it takes input (just now) and the HUD; only the dialogue screen stays.
    try (animation.Animation{ .world = &world }).start(intro);
    animation.step(&world, &cache, 1, effects);
    try std.testing.expect(cutscene.update(&world, &cache, 0.1, effects));
    try std.testing.expectEqual(Takeover.input_and_hud, cutscene.takeover);
    var state = ui_scenes.State{ .gpa = gpa };
    defer state.deinit();
    state.screen_count, state.billboard_count = ui_scenes.gather(&world, &state.screens, &state.billboards);
    try std.testing.expectEqual(@as(usize, 2), state.screen_count);
    cutscene.hideHud(&world, &cache, &state);
    try std.testing.expectEqual(@as(usize, 1), state.screen_count);
    try std.testing.expect(state.screens[0].entity().eql(dialogue));
    _ = hud;

    // Paused partway (waiting on a choice) it still holds them.
    try (animation.Animation{ .world = &world }).pause(intro);
    _ = cutscene.update(&world, &cache, 0.1, effects);
    try std.testing.expectEqual(Takeover.input_and_hud, cutscene.takeover);
    try (animation.Animation{ .world = &world }).unpause(intro);

    // Escape held for a second skips to the end, and the quest still starts.
    cutscene.escape_held = true;
    _ = cutscene.update(&world, &cache, 0.6, effects);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    _ = cutscene.update(&world, &cache, 0.6, effects);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("start_quest", events.items[0].name);
    try std.testing.expectEqual(Takeover.nothing, cutscene.takeover);
}
