//! A scene loaded over several frames, so a loading screen can show while it comes in: its file
//! read in the background, then the models and images it uses put on the GPU one a frame, then
//! its entities placed in the world, beside what is there or in its place.
const std = @import("std");
const ecs = @import("clutch");
const assets = @import("eggy_assets");
const refs = @import("../refs.zig");
const scene = @import("../scene.zig");
const SceneInstances = @import("../scene_instances.zig").SceneInstances;
const resources_zig = @import("../resources/resources.zig");
const Resources = resources_zig.Resources;
const Transition = @import("transition.zig").Transition;
const ModelCache = @import("../model_cache.zig").ModelCache;
const TextureCache = @import("../texture_cache.zig").TextureCache;
const log = std.log.scoped(.scenes);

/// Names one `Scenes.stream` call, to ask how it ended.
pub const Ticket = enum(u64) { _ };

pub const Options = struct {
    /// Where the scene goes when added beside the world; must be alive when it is placed.
    parent: ?ecs.EntityId = null,
    /// Take the place of every entity in the world once loaded, as `Scenes.replace` does,
    /// rather than adding the scene as an instance beside them.
    replace: bool = false,
    /// Cover the game with Eggy's loading screen until it is placed.
    loading_screen: bool = true,
};

/// How far a load has come, for a loading screen.
pub const Loading = struct {
    /// The scene being loaded: its project path where the build knows it, else its key.
    scene: []const u8,
    stage: Stage,
    /// The models and images put on the GPU so far, out of `total`.
    done: usize,
    total: usize,
    /// What is being loaded now: a model's or an image's path (or key), or the scene's.
    item: []const u8,
    loading_screen: bool,

    pub const Stage = enum { reading, models_and_images, placing };

    /// How much is done, from 0 to 1: reading counts as nothing, placing as all.
    pub fn fraction(self: Loading) f32 {
        return switch (self.stage) {
            .reading => 0,
            .placing => 1,
            .models_and_images => if (self.total == 0) 1 else @as(f32, @floatFromInt(self.done)) / @as(f32, @floatFromInt(self.total)),
        };
    }
};

/// How a stream ended: the instance's root when added, null when it replaced the world.
pub const Placed = struct { root: ?ecs.EntityId };

/// A model or image a scene uses, warmed on the GPU before it is placed.
const Asset = struct {
    key: [assets.id.key_len]u8,
    kind: enum { model, image },
    /// Its project path, borrowed from the build's catalog; else its key.
    name: []const u8,
};

/// The load in progress, if any, and the last one to finish until it is asked about.
pub const SceneStream = struct {
    current: ?Load = null,
    finished: ?struct { ticket: Ticket, result: anyerror!Placed } = null,
    next_ticket: u64 = 1,

    const Load = struct {
        ticket: Ticket,
        file: refs.AssetRef(.scene),
        options: Options,
        /// The background read of the scene's file; null once read, or where reads are synchronous.
        reading: ?resources_zig.Request,
        assets: std.ArrayList(Asset) = .empty,
        /// How many of `assets` are on the GPU.
        warmed: usize = 0,
        read: bool = false,
    };

    /// Forget the load in progress and how the last one ended. Pending reads are the resource
    /// queue's to cancel (`App.resetWorld` clears it).
    pub fn deinit(self: *SceneStream, gpa: std.mem.Allocator) void {
        if (self.current) |*load| load.assets.deinit(gpa);
        self.* = .{ .next_ticket = self.next_ticket };
    }

    /// Begin loading `file`. One scene streams at a time: a second call while one loads fails
    /// with `SceneStreamBusy`. Starting a load forgets how the previous one ended.
    pub fn start(self: *SceneStream, gpa: std.mem.Allocator, resources: Resources, file: refs.AssetRef(.scene), options: Options) !Ticket {
        if (file.len == 0) return error.UnsetAsset;
        if (self.current != null) return error.SceneStreamBusy;
        // Read in the background where the host can; otherwise the first step reads it.
        const reading: ?resources_zig.Request = resources.readAsync(gpa, file) catch |err| switch (err) {
            error.NoAsyncResourceProvider => null,
            else => return err,
        };
        const ticket: Ticket = @fromBackingInt(@intCast(self.next_ticket));
        self.next_ticket += 1;
        self.current = .{ .ticket = ticket, .file = file, .options = options, .reading = reading };
        self.finished = null;
        return ticket;
    }

    /// How `ticket`'s load ended: null while it loads, its placement once placed, or the error it
    /// failed with. The outcome is kept until another stream starts.
    pub fn outcome(self: *const SceneStream, ticket: Ticket) !?Placed {
        if (self.current) |load| if (load.ticket == ticket) return null;
        const ended = self.finished orelse return error.UnknownSceneStream;
        if (ended.ticket != ticket) return error.UnknownSceneStream;
        return try ended.result;
    }

    /// How far the load in progress has come; null with none. Borrows names until the next step.
    pub fn loading(self: *const SceneStream) ?Loading {
        const load = &(self.current orelse return null);
        const scene_name = nameOf(&load.file);
        const stage: Loading.Stage = if (!load.read) .reading else if (load.warmed < load.assets.items.len) .models_and_images else .placing;
        const item = if (stage == .models_and_images) load.assets.items[load.warmed].name else scene_name;
        return .{ .scene = scene_name, .stage = stage, .done = load.warmed, .total = load.assets.items.len, .item = item, .loading_screen = load.options.loading_screen };
    }

    /// Carry the load on by one step, once a frame after the game's systems: take the file once
    /// read, else put one more model or image on the GPU, else place the scene. A failure ends
    /// the load, logged and kept for `outcome`, leaving the world as it was.
    pub fn step(self: *SceneStream, gpa: std.mem.Allocator, world: *ecs.World, access: scene.Access, instances: *SceneInstances, transition: *Transition, resources: Resources, models: *ModelCache, textures: *TextureCache) void {
        const load = &(self.current orelse return);
        const placed = self.advance(gpa, load, world, access, instances, transition, resources, models, textures) catch |err| {
            log.err("cannot stream scene {s}: {t}", .{ nameOf(&load.file), err });
            return self.finish(gpa, err);
        };
        if (placed) |done| self.finish(gpa, done);
    }

    fn advance(self: *SceneStream, gpa: std.mem.Allocator, load: *Load, world: *ecs.World, access: scene.Access, instances: *SceneInstances, transition: *Transition, resources: Resources, models: *ModelCache, textures: *TextureCache) !?Placed {
        _ = self;
        // The file first: its text names the models and images to warm.
        if (!load.read) {
            var bytes = if (load.reading) |request| (try resources.poll(request)) orelse return null else blk: {
                const text = try resources.read(gpa, load.file);
                break :blk resources_zig.Result{ .gpa = gpa, .value = .{ .bytes = text } };
            };
            defer bytes.deinit();
            load.reading = null;
            load.read = true;
            try findAssets(gpa, bytes.value.bytes, &load.assets);
            return null;
        }
        // One model or image a frame, so the loading screen moves between them.
        // ponytail: each decodes on the main thread inside the cache; decode on the resource queue and upload here if one stalls the screen.
        if (load.warmed < load.assets.items.len) {
            const asset = &load.assets.items[load.warmed];
            switch (asset.kind) {
                .model => _ = models.get(&asset.key, textures),
                .image => _ = textures.get(&asset.key),
            }
            load.warmed += 1;
            return null;
        }
        // Then its entities, in place of the world's or beside them.
        if (load.options.replace) {
            if (transition.pending != null) return null;
            try transition.request(gpa, resources, load.file);
            if (!try transition.apply(world, access, instances)) return error.SceneTransitionPending;
            return .{ .root = null };
        }
        if (load.options.parent) |parent| if (!world.isAlive(parent)) return error.InvalidEntity;
        var reader = resources;
        return .{ .root = try instances.create(reader.sceneFiles(), world, access, load.file, load.options.parent) };
    }

    fn finish(self: *SceneStream, gpa: std.mem.Allocator, result: anyerror!Placed) void {
        var load = self.current.?;
        load.assets.deinit(gpa);
        self.current = null;
        self.finished = .{ .ticket = load.ticket, .result = result };
    }
};

/// The models and images (tilemaps draw as models) `text`, a scene file, refers to by key, each
/// once. Keys the build's catalog doesn't know are left to load when drawn.
fn findAssets(gpa: std.mem.Allocator, text: []const u8, found: *std.ArrayList(Asset)) !void {
    const root = @import("root");
    if (comptime !@hasDecl(root, "eggy_asset_ids")) return;
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
        rest = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse return;
        const quoted = rest[0..close];
        rest = rest[close + 1 ..];
        if (quoted.len != assets.id.key_len) continue;
        const id = assets.id.parse(quoted) catch continue;
        const entry = root.eggy_asset_ids.findId(id) orelse continue;
        const kind: @FieldType(Asset, "kind") = switch (@as(assets.Kind, @fromBackingInt(@intCast(entry.kind)))) {
            .model, .tilemap => .model,
            .image => .image,
            else => continue,
        };
        const seen = for (found.items) |known| {
            if (std.mem.eql(u8, &known.key, quoted)) break true;
        } else false;
        if (seen) continue;
        try found.append(gpa, .{ .key = quoted[0..assets.id.key_len].*, .kind = kind, .name = entry.path });
    }
}

/// `file`'s project path where the build's catalog knows it, else its key.
fn nameOf(file: *const refs.AssetRef(.scene)) []const u8 {
    const root = @import("root");
    if (comptime @hasDecl(root, "eggy_asset_ids")) {
        if (root.eggy_asset_ids.findId(file.id())) |entry| return entry.path;
    }
    return file.key();
}

test "a stream reads its file, then places the scene beside the world, and says how it ended" {
    const Registry = @import("../components.zig").Registry(&.{}, &.{});
    const Source = struct {
        fn read(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![:0]u8 {
            return gpa.dupeSentinel(u8, ".{ .entities = .{ .{ .name = \"Ship\" } } }", 0);
        }
        fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Model {
            return error.NotPackaged;
        }
        fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Texture {
            return error.NotPackaged;
        }
    };
    var context: u8 = 0;
    const resources = Resources.from(&context, Source.read, Source.model, Source.image);
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var instances = SceneInstances.init(std.testing.allocator);
    defer instances.deinit();
    var transition = Transition{};
    defer transition.deinit();
    var models: ModelCache = undefined;
    var textures: TextureCache = undefined;
    var stream = SceneStream{};
    defer stream.deinit(std.testing.allocator);

    const ticket = try stream.start(std.testing.allocator, resources, .init("level.scene.zon"), .{});
    try std.testing.expectError(error.SceneStreamBusy, stream.start(std.testing.allocator, resources, .init("level.scene.zon"), .{}));
    try std.testing.expectEqual(Loading.Stage.reading, stream.loading().?.stage);
    try std.testing.expect(try stream.outcome(ticket) == null);

    // Read (synchronously here: no background queue), then placed on the next step.
    stream.step(std.testing.allocator, &world, scene.registryAccess(Registry), &instances, &transition, resources, &models, &textures);
    try std.testing.expectEqual(Loading.Stage.placing, stream.loading().?.stage);
    stream.step(std.testing.allocator, &world, scene.registryAccess(Registry), &instances, &transition, resources, &models, &textures);
    try std.testing.expect(stream.loading() == null);
    const placed = (try stream.outcome(ticket)).?;
    try std.testing.expect(world.isAlive(placed.root.?));
}
