//! Opt-in native GPU coverage for live quality changes, mip uploads and offscreen scene rebuilds.
//! Run with `EGGY_GPU_TEST=1 zig build test-core` on a desktop with Vulkan.
const std = @import("std");
const builtin = @import("builtin");
const adapter = @import("vitellus_sdl3");
const sdl = adapter.sdl;
const Graphics = @import("graphics.zig").Graphics;
const SceneTexture = @import("scene_texture.zig").SceneTexture;
const render = @import("render_settings.zig");
const mesh = @import("mesh.zig");
const camera = @import("camera.zig");
const assets = @import("eggy_assets");
const control = @import("graphics_control.zig");
const identityHash = @import("storage.zig").identityHash;

test "GPU renders every supported AA mode through live texture and scene changes" {
    if (comptime builtin.os.tag == .emscripten) return error.SkipZigTest;
    if ((try sdl.getEnvironment()).getVariable("EGGY_GPU_TEST") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const flags = sdl.InitFlags{ .video = true };
    try sdl.init(flags);
    defer sdl.quit(flags);
    const window = adapter.Sdl3Window.init(try sdl.video.Window.init("Eggy graphics smoke", 320, 240, .{ .vulkan = true }));
    defer window.window.deinit();
    var graphics = try Graphics.initWithSettings(gpa, window, .{ .backend = .vulkan, .adapter_index = 0, .anti_aliasing = .off, .width = 320, .height = 240 });
    defer graphics.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = control.State{
        .defaults = graphics.render_settings,
        .requested = graphics.render_settings,
        .store = .{ .gpa = gpa, .io = std.testing.io, .scope = .runtime, .namespace = identityHash("GPU smoke"), .directory = try tmp.dir.openDir(std.testing.io, ".", .{}) },
    };
    defer state.deinit();
    state.warning = true;
    _ = try state.setDefaults(graphics.render_settings, &graphics);
    try state.apply(&graphics, window);
    try std.testing.expect(state.warning);
    var context: u8 = 0;
    graphics.textures.loader = .{ .context = &context, .load = checker };
    var scene = try SceneTexture.init(&graphics);
    defer scene.deinit();
    defer graphics.queue.waitIdle() catch @panic("GPU smoke queue did not finish");
    const path = "generated-checker";
    var drawables = [_]mesh.Drawable{.{
        .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } },
        .color = .{ 1, 1, 1, 1 },
        .shape = .cube,
        .entity_id = 0,
        .entity_generation = 0,
        .texture_file = path.ptr,
        .texture_file_len = path.len,
    }};
    for (std.meta.tags(render.AntiAliasing), 0..) |mode, index| {
        if (!graphics.capabilities().anti_aliasing.contains(mode)) continue;
        var settings = graphics.render_settings;
        settings.anti_aliasing = mode;
        settings.render_scale = if (index % 2 == 0) 0.5 else 1.5;
        settings.mipmaps = index % 2 == 0;
        settings.texture_filter = if (index % 2 == 0) .linear else .nearest;
        settings.anisotropy = if (settings.texture_filter == .linear and graphics.capabilities().max_anisotropy >= 8) 8 else 1;
        try std.testing.expectEqual(render.ApplyResult.queued, try state.request(settings, &graphics, true));
        try std.testing.expect(!state.warning);
        try state.apply(&graphics, window);
        try std.testing.expectEqualDeep(settings, graphics.render_settings);
        for (0..3) |frame_index| {
            const frame = try graphics.beginFrame();
            try scene.render(&graphics, frame.cmd, .{ .width = 63 + @as(u32, @intCast(frame_index)), .height = 35 }, &drawables, camera.View.default, null, true);
            try graphics.drawScene(frame, &drawables, camera.View.default);
            try graphics.endFrame(frame);
        }
    }
    try std.testing.expect(graphics.textures.entries.contains(path));
    var restart = graphics.render_settings;
    restart.backend = .auto;
    restart.adapter_index = null;
    if (graphics.capabilities().present_modes.contains(.fifo)) restart.present_mode = .fifo;
    try std.testing.expectEqual(render.ApplyResult.restart_required, try state.request(restart, &graphics, true));
    try state.apply(&graphics, window);
    try std.testing.expectEqual(render.Backend.vulkan, graphics.render_settings.backend);
    try std.testing.expectEqual(@as(?u16, 0), graphics.render_settings.adapter_index);
    try std.testing.expectEqual(render.PresentMode.auto, graphics.render_settings.present_mode);
    try std.testing.expectEqualDeep(restart, (try state.store.?.load()).?);
}

fn checker(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) !assets.Texture {
    const width = 63;
    const height = 35;
    const pixels = try gpa.alloc(u8, width * height * 4);
    for (0..height) |y| for (0..width) |x| {
        const offset = (y * width + x) * 4;
        const value: u8 = if ((x / 2 + y / 2) % 2 == 0) 255 else 0;
        @memcpy(pixels[offset..][0..4], &[_]u8{ value, value, value, 255 });
    };
    return .{ .width = width, .height = height, .pixels = pixels };
}
