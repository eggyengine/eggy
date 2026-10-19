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
const vit = @import("vitellus");
const mipmaps = @import("mipmaps.zig");

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

test "GPU texture transfers preserve padded rows in every mip level" {
    if (comptime builtin.os.tag == .emscripten) return error.SkipZigTest;
    if ((try sdl.getEnvironment()).getVariable("EGGY_GPU_TEST") == null) return error.SkipZigTest;
    const instance = try vit.Instance.init(std.testing.allocator, .{ .backend = .{ .vulkan = true }, .validation = .core });
    defer instance.deinit();
    const gpu = try vit.Adapter.init(instance, .{});
    defer gpu.deinit();
    const device = try vit.Device.init(gpu, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{});
    defer queue.deinit();
    for ([_][2]u32{ .{ 32, 32 }, .{ 63, 35 }, .{ 1, 5 } }) |extent|
        try checkTextureRows(device, queue, extent[0], extent[1]);
}

fn checkTextureRows(device: vit.Device, queue: vit.Queue, width: u32, height: u32) !void {
    const gpa = std.testing.allocator;
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(pixels);
    for (0..height) |y| for (0..width) |x| {
        pixels[(y * width + x) * 4 ..][0..4].* = .{ @truncate(x * 7), @truncate(y * 11), @truncate((x + y) * 3), 255 };
    };
    var chain = try mipmaps.Chain.init(gpa, width, height, pixels, true);
    defer chain.deinit(gpa);
    const source = try vit.Buffer.init(device, .{ .size = chain.bytes.len, .usage = .{ .transfer_src = true }, .memory = .upload, .initial_data = chain.bytes });
    defer source.deinit();
    const padded_offset = std.mem.alignForward(usize, chain.bytes.len, 512);
    const destination = try vit.Buffer.init(device, .{ .size = padded_offset + chain.bytes.len, .usage = .{ .transfer_dst = true }, .memory = .readback });
    defer destination.deinit();
    const texture = try vit.Texture.init(device, .{ .width = width, .height = height, .mip_levels = chain.count, .format = .rgba8_unorm, .usage = .{ .transfer_src = true, .transfer_dst = true } });
    defer texture.deinit();
    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = .common, .after = .copy_destination } }});
    for (chain.levels[0..chain.count], 0..) |level, index| {
        try cmd.copyBufferToTexture(.{
            .buffer = source,
            .buffer_offset = level.offset,
            .bytes_per_row = level.row_bytes,
            .texture = .{ .texture = texture, .mip_level = @intCast(index) },
            .extent = .{ .width = level.width, .height = level.height },
        });
    }
    try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = .copy_destination, .after = .copy_source } }});
    for (chain.levels[0..chain.count], 0..) |level, index| {
        for ([_]bool{ false, true }) |padded| {
            try cmd.copyTextureToBuffer(.{
                .buffer = destination,
                .buffer_offset = level.offset + if (padded) padded_offset else @as(usize, 0),
                .bytes_per_row = if (padded) level.row_bytes else 0,
                .texture = .{ .texture = texture, .mip_level = @intCast(index) },
                .extent = .{ .width = level.width, .height = level.height },
            });
        }
    }
    try cmd.finish();
    try queue.submit(.{ .command_buffers = &.{cmd} });
    try queue.waitIdle();
    const read = try destination.map(.read, .{ .size = padded_offset + chain.bytes.len });
    defer destination.unmap(null);
    for (chain.levels[0..chain.count]) |level| for (0..level.height) |row| {
        const expected = chain.bytes[level.offset + row * level.row_bytes ..][0 .. level.width * 4];
        const tight = read[level.offset + row * level.width * 4 ..][0 .. level.width * 4];
        const padded = read[padded_offset + level.offset + row * level.row_bytes ..][0 .. level.width * 4];
        try std.testing.expectEqualSlices(u8, expected, tight);
        try std.testing.expectEqualSlices(u8, expected, padded);
    };
}
