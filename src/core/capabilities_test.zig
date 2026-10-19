//! Direct-call checks that missing capabilities never report successful work.
const std = @import("std");
const expect = std.testing.expectError;

test "every missing backend operation returns NotImplemented" {
    const audio = @import("audio.zig").Audio{};
    try expect(error.NotImplemented, audio.play(.init("jump.ogg"), .{}));
    try expect(error.NotImplemented, audio.pause(@enumFromInt(0)));
    try expect(error.NotImplemented, audio.unpause(@enumFromInt(0)));
    try expect(error.NotImplemented, audio.stop(@enumFromInt(0)));
    try expect(error.NotImplemented, audio.setGain(@enumFromInt(0), 0.5));
    try expect(error.NotImplemented, audio.setBusGain(.master, 1));
    try expect(error.NotImplemented, audio.setListener(@splat(0), .{ 0, 0, -1 }, .{ 0, 1, 0 }));

    const animation = @import("animation.zig").Animation{};
    const entity = @import("clutch").EntityId.init(0, 0);
    const clip = @import("animation.zig").Clip{ .model = .init("rat.glb"), .name = "run" };
    try expect(error.NotImplemented, animation.play(entity, clip, .{}));
    try expect(error.NotImplemented, animation.blendTo(entity, clip, 0.2, .{}));
    try expect(error.NotImplemented, animation.pause(entity));
    try expect(error.NotImplemented, animation.stop(entity));
    try expect(error.NotImplemented, animation.seek(entity, 1));

    const draw = @import("draw2d.zig").Draw2d{};
    try expect(error.NotImplemented, draw.sprite(.{ .image = .init("rat.png") }));
    try expect(error.NotImplemented, draw.worldText("hello", @splat(0), 1));
    const materials = @import("materials.zig").Materials{};
    try expect(error.NotImplemented, materials.assign(entity, .{}));
    try expect(error.NotImplemented, materials.applyEffect(.bloom, 1));
    const lights = @import("lighting.zig").Lighting{};
    try expect(error.NotImplemented, lights.setLight(entity, .{ .point = .{} }));
    try expect(error.NotImplemented, lights.removeLight(entity));
    const particles = @import("particles.zig").Particles{};
    try expect(error.NotImplemented, particles.emit(.{ .position_m = @splat(0) }));
    try expect(error.NotImplemented, particles.stop(@enumFromInt(0)));

    const network = @import("network.zig").Network{};
    const address = @import("network.zig").Address{ .host = "localhost", .port = 3000 };
    try expect(error.NotImplemented, network.connect(address));
    try expect(error.NotImplemented, network.listen(address));
    try expect(error.NotImplemented, network.send(@enumFromInt(0), "hello"));
    var buffer: [32]u8 = undefined;
    try expect(error.NotImplemented, network.poll(&buffer));
    try expect(error.NotImplemented, network.disconnect(@enumFromInt(0)));
    const navigation = @import("navigation.zig").Navigation{};
    try expect(error.NotImplemented, navigation.findPath(std.testing.allocator, @splat(0), @splat(1)));
    try expect(error.NotImplemented, navigation.setDestination(entity, @splat(1)));
    try expect(error.NotImplemented, navigation.cancel(entity));
    const storage = @import("storage.zig").Storage{};
    try expect(error.StorageNotInitialized, storage.read(std.testing.allocator, "slot"));
    try expect(error.StorageNotInitialized, storage.write("slot", "bytes"));
    try expect(error.StorageNotInitialized, storage.remove("slot"));
    const localization = @import("localization.zig").Localization{};
    try expect(error.NotImplemented, localization.setLocale("en"));
    try expect(error.NotImplemented, localization.text(std.testing.allocator, "hello"));
    const debug = @import("debug_draw.zig").DebugDraw{};
    try expect(error.NotImplemented, debug.line(@splat(0), @splat(1), @splat(1)));
    try expect(error.NotImplemented, debug.box(@splat(0), @splat(1), @splat(1)));
    try expect(error.NotImplemented, debug.text(@splat(0), "hello"));
    const profiling = @import("profiling.zig").Profiling{};
    try expect(error.NotImplemented, profiling.begin("frame"));
    try expect(error.NotImplemented, profiling.end(@enumFromInt(0)));
    try expect(error.NotImplemented, profiling.counter("entities", 1));

    const resources = @import("resources/resources.zig").Resources{};
    try expect(error.NotImplemented, resources.readAsync(std.testing.allocator, @import("refs.zig").AssetRef(.text).init("notes.txt")));
    try expect(error.NotImplemented, resources.cancel(@enumFromInt(0)));
    var world = @import("clutch").World.init(std.testing.allocator);
    defer world.deinit();
    var instances = @import("scene_instances.zig").SceneInstances.init(std.testing.allocator);
    defer instances.deinit();
    const scenes = @import("scenes/scenes.zig").Scenes{ .world = &world, .instances = &instances, .resources = .{}, .access = null };
    try expect(error.NotImplemented, scenes.stream(.init("level.scene.zon"), .{}));
    try expect(error.NoSceneRegistry, scenes.replace(.init("level.scene.zon")));
}
