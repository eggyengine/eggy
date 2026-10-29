//! UI scenes on entities: `UiScreen` shows a `.ui.zon` over the game's view (a HUD, a menu) and
//! `UiBillboard` shows one in the world on the entity. `app.uiScenes()` lets code change what
//! the nodes show and ask which buttons were pressed, and each press is also sent as a `Clicked`
//! event for systems. The host gathers the entities (`gather`), builds the screens into the game
//! UI (`buildScreens`) and paints billboards for the scene pass (`billboards.zig`).
//!
//! ```zig
//! // In a system or update hook, given the HUD's entity:
//! try app.uiScenes().setText(hud, "score", "Score: 12");
//! if (app.uiScenes().clicked(hud, "pause")) paused = true;
//! ```
const std = @import("std");
const ecs = @import("clutch");
const ui = @import("weeoui");
const assets = @import("eggy_assets");
const ui_scene = assets.ui_scene;
const AssetRef = @import("../refs.zig").AssetRef;
const Transform = @import("../transform.zig").Transform;
const transform = @import("../transform.zig");
const Resources = @import("../resources/resources.zig").Resources;
const Overlay = @import("../game_ui/game_ui.zig").Overlay;
pub const layout = @import("layout.zig");
pub const paint = @import("paint.zig");
pub const cache = @import("cache.zig");
pub const scene_ui = @import("scene_ui.zig");
pub const billboards = @import("billboards.zig");
const state_zig = @import("state.zig");
pub const State = state_zig.State;
pub const max_screens = state_zig.max_screens;
pub const max_billboards = state_zig.max_billboards;
pub const Clicked = state_zig.Clicked;
pub const Screen = state_zig.Screen;
pub const Billboard = state_zig.Billboard;
pub const Override = layout.Override;
pub const WidgetPainter = paint.WidgetPainter;
pub const WidgetRequest = paint.WidgetRequest;

pub const support: @import("../support.zig").Support = .available;

/// Shows a UI scene over the game's view, scaled from its design size as the scene says.
pub const UiScreen = struct {
    /// Marks it in the editor (nf-md-view_dashboard).
    pub const icon = "\u{f056e}";
    pub const category = "UI";
    scene: AssetRef(.ui) = .{},
    /// Screens with higher layers draw over those with lower ones.
    layer: i16 = 0,
    visible: bool = true,
    /// Whether its buttons take presses (and so keep them from the game).
    interactive: bool = true,
};

/// Shows a UI scene in the world, where the entity is: depth-tested, and hidden by what is in
/// front of it. Its buttons take mouse presses (`billboards.press`).
pub const UiBillboard = struct {
    /// Marks it in the editor (nf-md-billboard).
    pub const icon = "\u{f1010}";
    pub const category = "UI";
    pub const dependencies = .{Transform};
    scene: AssetRef(.ui) = .{},
    /// How wide its face is, in metres, whatever the entity's scale; its height follows what the
    /// scene lays out within its design size (all of it, for a root that fills it).
    width_m: f32 = 1,
    /// Turn to face the camera; otherwise its face is the entity's XY plane, facing +Z.
    face_camera: bool = true,
    /// Texels per design pixel: higher is sharper, and takes more of the glyph atlas.
    resolution: f32 = 2,
    visible: bool = true,
};

/// The visible screens and billboards with a scene set, at most as many as `screens` and
/// `billboards` hold; returns how many of each. Screens come lowest layer first.
pub fn gather(world: *ecs.World, screens: []Screen, billboards_out: []Billboard) [2]usize {
    var counts = [2]usize{ 0, 0 };
    var screen_query = world.query(.{*const UiScreen});
    while (screen_query.next()) |view| {
        const screen = view.get(*const UiScreen);
        if (!screen.visible or screen.scene.len == 0 or counts[0] == screens.len) continue;
        var found = Screen{ .entity_id = view.entity.id, .entity_generation = view.entity.generation, .scene = undefined, .scene_len = screen.scene.len, .layer = screen.layer, .interactive = screen.interactive };
        @memcpy(found.scene[0..screen.scene.len], screen.scene.key());
        screens[counts[0]] = found;
        counts[0] += 1;
    }
    std.mem.sort(Screen, screens[0..counts[0]], {}, struct {
        fn lower(_: void, a: Screen, b: Screen) bool {
            return a.layer < b.layer;
        }
    }.lower);
    var billboard_query = world.query(.{ *const UiBillboard, *const Transform });
    while (billboard_query.next()) |view| {
        const billboard = view.get(*const UiBillboard);
        if (!billboard.visible or billboard.scene.len == 0 or counts[1] == billboards_out.len) continue;
        if (!std.math.isFinite(billboard.width_m) or billboard.width_m <= 0) continue;
        var found = Billboard{ .entity_id = view.entity.id, .entity_generation = view.entity.generation, .scene = undefined, .scene_len = billboard.scene.len, .face_camera = billboard.face_camera, .width_m = billboard.width_m, .resolution = std.math.clamp(billboard.resolution, 0.25, 8), .model = undefined };
        @memcpy(found.scene[0..billboard.scene.len], billboard.scene.key());
        for (&found.model, transform.worldMatrix(world, view.entity).data) |*column, data| column.* = data;
        billboards_out[counts[1]] = found;
        counts[1] += 1;
    }
    return counts;
}

/// Find this frame's screens and billboards in `world` for `state`, and use `widgets` to draw
/// plugins' widgets. Last frame's presses are no longer news, and its billboards' buttons are
/// painted again. Host-only, once per frame after the update hooks and before drawing; in the
/// editor it runs in the game's library, where the component types are.
pub fn gatherInto(world: *ecs.World, state: *State, widgets: WidgetPainter) void {
    state.forgetClicks();
    state.billboard_buttons.clearRetainingCapacity();
    state.billboard_bounds.clearRetainingCapacity();
    state.screen_count, state.billboard_count = gather(world, &state.screens, &state.billboards);
    state.widgets = widgets;
}

/// Send last UI frame's presses as `Clicked` events, for this frame's systems.
/// Host-only, once per gameplay frame before the Update stages (`App.updateWorld` does it).
pub fn publish(world: *ecs.World, state: *const State) !void {
    for (state.clicks.items) |click| try world.sendEvent(click);
}

/// Changing what an entity's UI scene shows, and asking what was pressed, by node name. Changes
/// last until cleared or the world is reset; a name nothing has does nothing.
pub const UiScenes = struct {
    state: *State,

    /// Show `text` in the text or button nodes named `name` of `entity`'s scene. Copies it.
    pub fn setText(self: UiScenes, entity: ecs.EntityId, name: []const u8, text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        const override = try self.state.overrideFor(entity, name);
        const owned = try self.state.gpa.dupe(u8, text);
        if (override.text) |old| self.state.gpa.free(old);
        override.text = owned;
    }

    /// Fill the progress bars named `name` to `value` (0 to 1).
    pub fn setValue(self: UiScenes, entity: ecs.EntityId, name: []const u8, value: f32) !void {
        if (!std.math.isFinite(value)) return error.InvalidValue;
        (try self.state.overrideFor(entity, name)).value = std.math.clamp(value, 0, 1);
    }

    /// Show or hide the nodes named `name`, and their children.
    pub fn setVisible(self: UiScenes, entity: ecs.EntityId, name: []const u8, visible: bool) !void {
        (try self.state.overrideFor(entity, name)).visible = visible;
    }

    /// Show `image` in the image nodes named `name` (or as their look's image).
    pub fn setImage(self: UiScenes, entity: ecs.EntityId, name: []const u8, image: AssetRef(.image)) !void {
        const override = try self.state.overrideFor(entity, name);
        const owned = try self.state.gpa.dupe(u8, image.key());
        if (override.image) |old| self.state.gpa.free(old);
        override.image = owned;
    }

    /// Go back to what the file says for the nodes named `name`.
    pub fn reset(self: UiScenes, entity: ecs.EntityId, name: []const u8) void {
        self.state.removeOverride(entity, name);
    }

    /// Whether a button named `name` of `entity`'s screen was pressed in the last UI frame.
    pub fn clicked(self: UiScenes, entity: ecs.EntityId, name: []const u8) bool {
        for (self.state.clicks.items) |click| {
            if (click.entity.eql(entity) and std.mem.eql(u8, click.node, name)) return true;
        }
        return false;
    }
};

/// Build this frame's screens (`gatherInto`) into the game UI `context`, across its viewport.
/// When `overlay` is the context's, a scene's theme font
/// (the last one asked for) becomes its font. Scenes that can't be read are logged once and
/// skipped.
pub fn buildScreens(state: *State, resources: Resources, context: *ui.Context, overlay: ?*Overlay, time_ms: u64) !void {
    const viewport = context.viewport;
    for (state.shownScreens()) |screen| {
        const scene = state.sceneCache().get(resources, screen.key()) orelse continue;
        if (overlay) |layer| if (&layer.context == context) try useFont(state, resources, layer, scene.theme.font);
        const scale = scene.scaling.scale(scene.design_size, .{ viewport.w, viewport.h });
        _ = try scene_ui.build(context, state, resources, state.screenImages(), scene, screen.entity(), .{ .viewport = viewport, .scale = scale, .z_index = screen.layer, .interactive = screen.interactive }, time_ms);
    }
}

/// Make the font with asset `key` the game UI's, unless it already is. A font that can't be
/// read is logged and the current one kept.
fn useFont(state: *State, resources: Resources, overlay: *Overlay, key: []const u8) !void {
    if (key.len == 0 or std.mem.eql(u8, key, state.font_key[0..state.font_key_len])) return;
    @memcpy(state.font_key[0..key.len], key);
    state.font_key_len = key.len;
    const reference = AssetRef(.any).parse(key) catch |err| return std.log.err("cannot use font {s} for UI: {t}", .{ key, err });
    const bytes = resources.read(state.gpa, reference) catch |err| return std.log.err("cannot read font {s} for UI: {t}", .{ key, err });
    defer state.gpa.free(bytes);
    overlay.setFont(bytes) catch |err| return std.log.err("cannot use font {s} for UI: {t}", .{ key, err });
    // Images were packed into the old font's atlas.
    if (state.screen_images) |*images| images.forgetAll();
}

test "code's changes are kept by entity and name, and presses are found" {
    var state = State{ .gpa = std.testing.allocator };
    defer state.deinit();
    const service = UiScenes{ .state = &state };
    const hud = ecs.EntityId{ .id = 3, .generation = 1 };
    try service.setText(hud, "score", "Score: 1");
    try service.setText(hud, "score", "Score: 2");
    try service.setValue(hud, "health", 2);
    try service.setVisible(hud, "menu", false);
    try std.testing.expectEqualStrings("Score: 2", state.overrideOf(hud, "score").?.text.?);
    try std.testing.expectEqual(@as(f32, 1), state.overrideOf(hud, "health").?.value.?);
    try std.testing.expect(state.overrideOf(.{ .id = 4, .generation = 1 }, "score") == null);
    service.reset(hud, "score");
    try std.testing.expect(state.overrideOf(hud, "score") == null);
    try state.recordClick(hud, "pause");
    try std.testing.expect(service.clicked(hud, "pause"));
    try std.testing.expect(!service.clicked(hud, "play"));
    state.clearEntities();
    try std.testing.expect(!service.clicked(hud, "pause"));
    try std.testing.expect(state.overrideOf(hud, "menu") == null);
}

test "screens are gathered lowest layer first and billboards with their place" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const top = try world.spawn(.{UiScreen{ .scene = .init("hud.ui.zon"), .layer = 5 }});
    const bottom = try world.spawn(.{UiScreen{ .scene = .init("back.ui.zon"), .layer = -1 }});
    _ = try world.spawn(.{UiScreen{ .scene = .init("hidden.ui.zon"), .visible = false }});
    _ = try world.spawn(.{UiScreen{}});
    _ = try world.spawn(.{ UiBillboard{ .scene = .init("sign.ui.zon") }, Transform{ .position = .{ 1, 2, 3 } } });
    var screens: [8]Screen = undefined;
    var signs: [8]Billboard = undefined;
    const counts = gather(&world, &screens, &signs);
    try std.testing.expectEqual([2]usize{ 2, 1 }, counts);
    try std.testing.expect(screens[0].entity().eql(bottom));
    try std.testing.expect(screens[1].entity().eql(top));
    try std.testing.expectEqual(@as(f32, 2), signs[0].model[3][1]);
}

test {
    _ = layout;
    _ = paint;
    _ = cache;
    _ = scene_ui;
    _ = billboards;
    _ = state_zig;
}
