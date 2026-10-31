//! Direct-call checks that missing capabilities never report successful work.
const std = @import("std");
const expect = std.testing.expectError;

test "every missing backend operation returns NotImplemented" {
    const entity = @import("clutch").EntityId.init(0, 0);

    const network = @import("network.zig").Network{};
    const address = @import("network.zig").Address{ .host = "localhost", .port = 3000 };
    try expect(error.NotImplemented, network.connect(address));
    try expect(error.NotImplemented, network.listen(address));
    try expect(error.NotImplemented, network.send(@fromBackingInt(@intCast(0)), "hello"));
    var buffer: [32]u8 = undefined;
    try expect(error.NotImplemented, network.poll(&buffer));
    try expect(error.NotImplemented, network.disconnect(@fromBackingInt(@intCast(0))));
    const navigation = @import("navigation.zig").Navigation{};
    try expect(error.NotImplemented, navigation.findPath(std.testing.allocator, .zero, .one));
    try expect(error.NotImplemented, navigation.setDestination(entity, .one));
    try expect(error.NotImplemented, navigation.cancel(entity));
    const storage = @import("storage.zig").Storage{};
    try expect(error.StorageNotInitialized, storage.read(std.testing.allocator, "slot"));
    try expect(error.StorageNotInitialized, storage.write("slot", "bytes"));
    try expect(error.StorageNotInitialized, storage.remove("slot"));

    const resources = @import("resources/resources.zig").Resources{};
    try expect(error.NoAsyncResourceProvider, resources.readAsync(std.testing.allocator, @import("refs.zig").AssetRef(.text).init("notes.txt")));
    try expect(error.NoAsyncResourceProvider, resources.cancel(@fromBackingInt(@intCast(0))));
    var world = @import("clutch").World.init(std.testing.allocator);
    defer world.deinit();
    var instances = @import("scene_instances.zig").SceneInstances.init(std.testing.allocator);
    defer instances.deinit();
    const scenes = @import("scenes/scenes.zig").Scenes{ .world = &world, .instances = &instances, .resources = .{}, .access = null };
    try expect(error.NoSceneRegistry, scenes.stream(.init("level.scene.zon"), .{}));
    try expect(error.NoSceneRegistry, scenes.replace(.init("level.scene.zon")));
}

test {
    _ = @import("debug_draw.zig");
    _ = @import("profiling.zig");
}
