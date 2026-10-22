//! What the App keeps for UI scenes between frames: the parsed scenes, the game UI's images,
//! what code changed about entities' nodes, the buttons pressed in the last UI frame, and the
//! painter for plugins' widgets.
const std = @import("std");
const ecs = @import("clutch");
const ui = @import("weeoui");
const assets = @import("eggy_assets");
const ui_scene = assets.ui_scene;
const Resources = @import("../resources/resources.zig").Resources;
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const cache = @import("cache.zig");
const Override = layout.Override;

/// A button of a UI scene was pressed on the frame before this one: `node` is its name (owned
/// by the App until the next UI frame).
pub const Clicked = struct {
    entity: ecs.EntityId,
    node: []const u8,
};

/// A screen to build this frame, as `ui_scenes.gather` found it.
pub const Screen = extern struct {
    entity_id: u32,
    entity_generation: u32,
    scene: [assets.id.key_len]u8,
    scene_len: u8,
    layer: i16,
    interactive: bool,

    pub fn entity(self: Screen) ecs.EntityId {
        return .{ .id = self.entity_id, .generation = self.entity_generation };
    }
    pub fn key(self: *const Screen) []const u8 {
        return self.scene[0..self.scene_len];
    }
};

/// A billboard to paint this frame, as `ui_scenes.gather` found it.
pub const Billboard = extern struct {
    entity_id: u32,
    entity_generation: u32,
    scene: [assets.id.key_len]u8,
    scene_len: u8,
    face_camera: bool,
    width_m: f32,
    resolution: f32,
    /// The entity's place in the world, as columns.
    model: [4][4]f32,

    pub fn entity(self: Billboard) ecs.EntityId {
        return .{ .id = self.entity_id, .generation = self.entity_generation };
    }
    pub fn key(self: *const Billboard) []const u8 {
        return self.scene[0..self.scene_len];
    }
};

/// A button a billboard painted last frame, for presses on it: `rect` is where on the billboard,
/// 0 to 1 from its top left, and `node` its name (borrowed from the scene cache).
pub const BillboardButton = struct {
    entity: ecs.EntityId,
    node: []const u8,
    rect: ui.Rect,
};

/// How many screens and billboards are shown in one frame at most.
pub const max_screens = 64;
pub const max_billboards = 256;

pub const State = struct {
    gpa: std.mem.Allocator = std.heap.c_allocator,
    scenes: ?cache.Scenes = null,
    /// The game UI's images, in its font's atlas.
    screen_images: ?cache.Images = null,
    /// Bumped when files change, so images other atlases hold (billboards') load again.
    files_revision: u32 = 0,
    /// By entity, then node name: what code changed. Names and strings are owned.
    overrides: std.AutoHashMapUnmanaged(u64, std.StringHashMapUnmanaged(Override)) = .empty,
    /// The buttons pressed in the last UI frame, for `clicked` and `Clicked` events.
    clicks: std.ArrayList(Clicked) = .empty,
    clicks_arena: ?std.heap.ArenaAllocator = null,
    /// This frame's visible screens, lowest layer first, and billboards (`ui_scenes.gather`).
    screens: [max_screens]Screen = undefined,
    screen_count: usize = 0,
    billboards: [max_billboards]Billboard = undefined,
    billboard_count: usize = 0,
    /// The buttons billboards painted since `gatherInto` (`billboards.Renderer.prepare`).
    billboard_buttons: std.ArrayList(BillboardButton) = .empty,
    /// Draws plugins' widgets; set by the plugin set each frame, cleared with the world.
    widgets: paint.WidgetPainter = .none,
    /// The asset key of the font the game UI draws with, when a screen's theme chose one.
    font_key: [assets.id.key_len]u8 = undefined,
    font_key_len: usize = 0,

    pub fn deinit(self: *State) void {
        self.clearEntities();
        self.overrides.deinit(self.gpa);
        self.clicks.deinit(self.gpa);
        self.billboard_buttons.deinit(self.gpa);
        if (self.clicks_arena) |*arena| arena.deinit();
        if (self.scenes) |*scenes| scenes.deinit();
        if (self.screen_images) |*images| images.deinit();
        self.* = .{ .gpa = self.gpa };
    }

    /// Forget what code changed, the presses and the widget painter: the world and the plugins
    /// they were about are gone. Caches stay.
    pub fn clearEntities(self: *State) void {
        var it = self.overrides.iterator();
        while (it.next()) |entry| freeNodes(self.gpa, entry.value_ptr);
        self.overrides.clearRetainingCapacity();
        self.forgetClicks();
        self.widgets = .none;
        self.screen_count = 0;
        self.billboard_count = 0;
        self.billboard_buttons.clearRetainingCapacity();
    }

    pub fn shownScreens(self: *const State) []const Screen {
        return self.screens[0..self.screen_count];
    }
    pub fn shownBillboards(self: *const State) []const Billboard {
        return self.billboards[0..self.billboard_count];
    }

    /// Start a UI frame: last frame's presses are no longer news.
    pub fn forgetClicks(self: *State) void {
        self.clicks.clearRetainingCapacity();
        if (self.clicks_arena) |*arena| _ = arena.reset(.retain_capacity);
    }

    /// The game UI's font is going away: its images must load again into the next one.
    pub fn fontGone(self: *State) void {
        if (self.screen_images) |*images| images.forgetAll();
        self.font_key_len = 0;
    }

    /// The parsed scenes, made the first time.
    pub fn sceneCache(self: *State) *cache.Scenes {
        if (self.scenes == null) self.scenes = .{ .gpa = self.gpa };
        return &self.scenes.?;
    }

    /// The game UI's images, made the first time.
    pub fn screenImages(self: *State) *cache.Images {
        if (self.screen_images == null) self.screen_images = .{ .gpa = self.gpa };
        return &self.screen_images.?;
    }

    /// A file changed: scenes and images with `key` load again when next drawn.
    pub fn forget(self: *State, key: []const u8) void {
        // Buttons borrow their names from the scenes.
        self.billboard_buttons.clearRetainingCapacity();
        if (self.scenes) |*scenes| scenes.forget(key);
        if (self.screen_images) |*images| images.forget(key);
        self.files_revision +%= 1;
    }

    /// Files changed: every scene and image loads again when next drawn.
    pub fn forgetAll(self: *State) void {
        // Buttons borrow their names from the scenes.
        self.billboard_buttons.clearRetainingCapacity();
        if (self.scenes) |*scenes| scenes.forgetAll();
        if (self.screen_images) |*images| images.forgetAll();
        self.files_revision +%= 1;
    }

    /// What code changed about `entity`'s nodes named `name`, if anything.
    pub fn overrideOf(self: *const State, entity: ecs.EntityId, name: []const u8) ?*const Override {
        const nodes = self.overrides.getPtr(entityKey(entity)) orelse return null;
        return nodes.getPtr(name);
    }

    /// The change for `entity`'s nodes named `name`, made empty the first time.
    pub fn overrideFor(self: *State, entity: ecs.EntityId, name: []const u8) !*Override {
        const nodes = try self.overrides.getOrPut(self.gpa, entityKey(entity));
        if (!nodes.found_existing) nodes.value_ptr.* = .empty;
        const node = try nodes.value_ptr.getOrPut(self.gpa, name);
        if (!node.found_existing) {
            node.key_ptr.* = self.gpa.dupe(u8, name) catch |err| {
                nodes.value_ptr.removeByPtr(node.key_ptr);
                return err;
            };
            node.value_ptr.* = .{};
        }
        return node.value_ptr;
    }

    /// Go back to what the file says for `entity`'s nodes named `name`.
    pub fn removeOverride(self: *State, entity: ecs.EntityId, name: []const u8) void {
        const nodes = self.overrides.getPtr(entityKey(entity)) orelse return;
        const removed = nodes.fetchRemove(name) orelse return;
        self.gpa.free(removed.key);
        freeOverride(self.gpa, removed.value);
    }

    /// Note that `entity`'s button `name` was pressed this UI frame. Copies the name.
    pub fn recordClick(self: *State, entity: ecs.EntityId, name: []const u8) !void {
        if (self.clicks_arena == null) self.clicks_arena = .init(self.gpa);
        const owned = try self.clicks_arena.?.allocator().dupe(u8, name);
        try self.clicks.append(self.gpa, .{ .entity = entity, .node = owned });
    }
};

fn entityKey(entity: ecs.EntityId) u64 {
    return @as(u64, entity.generation) << 32 | entity.id;
}

fn freeNodes(gpa: std.mem.Allocator, nodes: *std.StringHashMapUnmanaged(Override)) void {
    var it = nodes.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        freeOverride(gpa, entry.value_ptr.*);
    }
    nodes.deinit(gpa);
}

/// Free the strings `override` owns.
pub fn freeOverride(gpa: std.mem.Allocator, override: Override) void {
    if (override.text) |text| gpa.free(text);
    if (override.image) |image| gpa.free(image);
}

/// What laying out and painting one entity's scene reads: nested scenes and images through the
/// caches, and what code changed about that entity's nodes.
pub const Sources = struct {
    state: *State,
    resources: Resources,
    images: *cache.Images,
    font: *ui.Font,
    entity: ecs.EntityId,

    pub fn layoutSources(self: *Sources) layout.Sources {
        return .{ .font = self.font, .context = self, .scene = scene, .image_size = imageSize, .override = override };
    }
    pub fn imageSource(self: *Sources) paint.ImageSource {
        return .{ .context = self, .get = image };
    }
    fn scene(context: *anyopaque, key: []const u8) ?*const ui_scene.UiScene {
        const self: *Sources = @ptrCast(@alignCast(context));
        return self.state.sceneCache().get(self.resources, key);
    }
    fn imageSize(context: *anyopaque, key: []const u8) ?[2]f32 {
        const self: *Sources = @ptrCast(@alignCast(context));
        return self.images.size(self.resources, self.font, key);
    }
    fn image(context: *anyopaque, key: []const u8) ?*const ui.Image {
        const self: *Sources = @ptrCast(@alignCast(context));
        return self.images.get(self.resources, self.font, key);
    }
    fn override(context: *anyopaque, name: []const u8) ?*const Override {
        const self: *Sources = @ptrCast(@alignCast(context));
        return self.state.overrideOf(self.entity, name);
    }
};

test "code's changes are kept by entity and name until cleared" {
    var state = State{ .gpa = std.testing.allocator };
    defer state.deinit();
    const hud = ecs.EntityId{ .id = 3, .generation = 1 };
    (try state.overrideFor(hud, "health")).value = 0.5;
    (try state.overrideFor(hud, "menu")).visible = false;
    try std.testing.expectEqual(@as(f32, 0.5), state.overrideOf(hud, "health").?.value.?);
    try std.testing.expect(state.overrideOf(.{ .id = 4, .generation = 1 }, "health") == null);
    state.removeOverride(hud, "health");
    try std.testing.expect(state.overrideOf(hud, "health") == null);
    try state.recordClick(hud, "pause");
    try std.testing.expectEqualStrings("pause", state.clicks.items[0].node);
    state.clearEntities();
    try std.testing.expect(state.overrideOf(hud, "menu") == null);
    try std.testing.expectEqual(@as(usize, 0), state.clicks.items.len);
}
