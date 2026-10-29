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
            try scene.render(&graphics, frame.cmd, .{ .width = 63 + @as(u32, @intCast(frame_index)), .height = 35 }, &drawables, camera.View.default, &.{}, true);
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

fn triangle(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) !assets.Model {
    const vertices = try gpa.dupe(assets.model.Vertex, &.{
        .{ .position = .{ -1, -1, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 0, 1 } },
        .{ .position = .{ 1, -1, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 1, 1 } },
        .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 0.5, 0 } },
    });
    errdefer gpa.free(vertices);
    const indices = try gpa.dupe(u32, &.{ 0, 1, 2 });
    errdefer gpa.free(indices);
    const parts = try gpa.dupe(assets.model.Part, &.{.{ .first_index = 0, .index_count = 3 }});
    return .{ .vertices = vertices, .indices = indices, .parts = parts, .textures = &.{} };
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

test "GPU directional shadows darken receivers and world sprites and text reach the scene" {
    if (comptime builtin.os.tag == .emscripten) return error.SkipZigTest;
    if ((try sdl.getEnvironment()).getVariable("EGGY_GPU_TEST") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const flags = sdl.InitFlags{ .video = true };
    try sdl.init(flags);
    defer sdl.quit(flags);
    const window = adapter.Sdl3Window.init(try sdl.video.Window.init("Eggy shadow and world drawing", 320, 240, .{ .vulkan = true }));
    defer window.window.deinit();
    var graphics = try Graphics.initWithSettings(gpa, window, .{ .backend = .vulkan, .anti_aliasing = .off, .shadow_quality = .low, .shadow_distance_m = 20, .width = 320, .height = 240 });
    defer graphics.deinit();
    var scene = try SceneTexture.init(&graphics);
    defer scene.deinit();
    defer graphics.queue.waitIdle() catch @panic("shadow GPU work did not finish");
    var context: u8 = 0;
    graphics.textures.loader = .{ .context = &context, .load = checker };
    var drawables = [_]mesh.Drawable{
        .{ .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0.5, 0, 1 } }, .color = .{ 0.8, 0.8, 0.8, 1 }, .shape = .cube, .entity_id = 0, .entity_generation = 0 },
        .{ .model = .{ .{ 12, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 12, 0 }, .{ 0, 0, 0, 1 } }, .color = .{ 0.8, 0.8, 0.8, 1 }, .shape = .plane, .entity_id = 1, .entity_generation = 0 },
    };
    graphics.lights.count = 1;
    const direction = camera.normalize(.{ 0.6, -1, -0.5 });
    graphics.lights.lights[0] = .{
        .direction_range = .{ direction[0], direction[1], direction[2], 0 },
        .color_intensity = .{ 1, 1, 1, 7000 },
    };
    graphics.lights.options = .{ 1, 0, -1, 0 };
    const view = camera.View.lookingAt(.{ 4, 4, 7 }, .{ 0, 0.5, 0 }, .{});
    const without = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(without);
    graphics.lights.options[2] = 0;
    const shadowed = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(shadowed);
    var darkened: usize = 0;
    for (0..without.len / 4) |pixel| {
        if (@as(u16, shadowed[pixel * 4]) + 5 < without[pixel * 4]) darkened += 1;
    }
    try std.testing.expect(darkened > 20);

    var world_draw = @import("draw2d.zig").Draw2d{ .gpa = gpa };
    defer world_draw.deinit();
    try world_draw.sprite(.{ .image = .init("generated-checker.png"), .position = .{ 0, 2 }, .size = .{ 2, 1 }, .billboard = true, .tint = .{ 1, 0.1, 0.1, 1 } });
    try world_draw.worldText("world", .{ -1, 2.5, 0 }, 0.35);
    graphics.world_draw = &world_draw;
    const decorated = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(decorated);
    try std.testing.expect(!std.mem.eql(u8, shadowed, decorated));
    world_draw.clear();
    try world_draw.worldText("world", .{ -1, 2.5, 0 }, 0.35);
    const text_only = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(text_only);
    try std.testing.expect(!std.mem.eql(u8, shadowed, text_only));
    try std.testing.expect(!std.mem.eql(u8, decorated, text_only));
    world_draw.clear();
    try world_draw.sprite(.{ .image = .init("generated-checker.png"), .position = .{ 0, 0.5 }, .size = .{ 0.1, 0.1 }, .billboard = true });
    const occluded = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(occluded);
    try std.testing.expectEqualSlices(u8, shadowed, occluded);
    world_draw.clear();
    graphics.lights.options[2] = -1;
    graphics.lights.count = 0;
    const ambient = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(ambient);
    graphics.lights.count = 1;
    graphics.lights.lights[0] = .{
        .position_kind = .{ 0, 3, 0, 1 },
        .direction_range = .{ 0, -1, 0, 10 },
        .color_intensity = .{ 1, 1, 1, 3000 },
        .cone_shadow = .{ @cos(15 * std.math.rad_per_deg), @cos(30 * std.math.rad_per_deg), 0, 0 },
    };
    const point_lit = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(point_lit);
    try std.testing.expect(rgbSum(point_lit) > rgbSum(ambient));
    graphics.lights.lights[0].position_kind[3] = 2;
    const spot_lit = try scenePixels(gpa, &graphics, &scene, &drawables, view);
    defer gpa.free(spot_lit);
    try std.testing.expect(rgbSum(spot_lit) > rgbSum(ambient));
    try std.testing.expect(rgbSum(point_lit) > rgbSum(spot_lit));
    const many = try gpa.alloc(mesh.Drawable, @import("mesh_renderer.zig").max_drawables + 1);
    defer gpa.free(many);
    for (many) |*drawable| {
        drawable.* = drawables[0];
        drawable.model[3][0] = 1000;
    }
    many[many.len - 1] = drawables[0];
    const culled = try scenePixels(gpa, &graphics, &scene, many, view);
    defer gpa.free(culled);
    graphics.models.loader = .{ .context = &context, .load = triangle };
    for (many) |*drawable| drawable.model[3][0] = 1000;
    const empty_scene = try scenePixels(gpa, &graphics, &scene, many, view);
    defer gpa.free(empty_scene);
    many[many.len - 1] = drawables[0];
    many[many.len - 1].model_file = "late.glb";
    many[many.len - 1].model_file_len = "late.glb".len;
    const late_model = try scenePixels(gpa, &graphics, &scene, many, view);
    defer gpa.free(late_model);
    try std.testing.expect(!std.mem.eql(u8, culled, late_model));
    try std.testing.expect(!std.mem.eql(u8, empty_scene, late_model));
    for (many) |*drawable| drawable.* = drawables[0];
    const overflow_frame = try graphics.beginFrame();
    try std.testing.expectError(error.TooManyVisibleMeshes, scene.render(&graphics, overflow_frame.cmd, .{ .width = 128, .height = 128 }, many, view, &.{}, false));
    try graphics.endFrame(overflow_frame);
}

fn rgbSum(pixels: []const u8) u64 {
    var total: u64 = 0;
    for (0..pixels.len / 4) |index| for (pixels[index * 4 ..][0..3]) |channel| {
        total += channel;
    };
    return total;
}

test "GPU sprite quads face the front and show only their texture region" {
    if (comptime builtin.os.tag == .emscripten) return error.SkipZigTest;
    if ((try sdl.getEnvironment()).getVariable("EGGY_GPU_TEST") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const flags = sdl.InitFlags{ .video = true };
    try sdl.init(flags);
    defer sdl.quit(flags);
    const window = adapter.Sdl3Window.init(try sdl.video.Window.init("Eggy sprite regions", 320, 240, .{ .vulkan = true }));
    defer window.window.deinit();
    var graphics = try Graphics.initWithSettings(gpa, window, .{ .backend = .vulkan, .anti_aliasing = .off, .width = 320, .height = 240 });
    defer graphics.deinit();
    var scene = try SceneTexture.init(&graphics);
    defer scene.deinit();
    defer graphics.queue.waitIdle() catch @panic("sprite GPU work did not finish");
    var context: u8 = 0;
    graphics.textures.loader = .{ .context = &context, .load = checker };
    // Seen flat from the front, as the 2D Scene panel sees it.
    const view = camera.View{ .eye = .{ 0, 0, 10 }, .forward = .{ 0, 0, -1 }, .up = .{ 0, 1, 0 }, .near = 0.1, .far = 100, .projection = .orthographic, .orthographic_height_m = 2 };
    var quad = [_]mesh.Drawable{.{ .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } }, .color = @splat(1), .shape = .quad, .entity_id = 0, .entity_generation = 0, .texture_file = "checker.png", .texture_file_len = "checker.png".len, .material_params = .{ 0, 1, 1, 1 } }};
    // The checker's top-left 2x2 cell is white, the one right of it black.
    quad[0].uv_rect = .{ 0.2 / 63.0, 0.2 / 35.0, 1.8 / 63.0, 1.8 / 35.0 };
    const white = try scenePixels(gpa, &graphics, &scene, &quad, view);
    defer gpa.free(white);
    quad[0].uv_rect = .{ 2.2 / 63.0, 0.2 / 35.0, 3.8 / 63.0, 1.8 / 35.0 };
    const black = try scenePixels(gpa, &graphics, &scene, &quad, view);
    defer gpa.free(black);
    const middle = (64 * 128 + 64) * 4;
    try std.testing.expect(white[middle] > 200);
    try std.testing.expect(black[middle] < 40);
}

test "GPU imported skeletal morph and vertex clips pose each instance independently" {
    if (comptime builtin.os.tag == .emscripten) return error.SkipZigTest;
    if ((try sdl.getEnvironment()).getVariable("EGGY_GPU_TEST") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const flags = sdl.InitFlags{ .video = true };
    try sdl.init(flags);
    defer sdl.quit(flags);
    const window = adapter.Sdl3Window.init(try sdl.video.Window.init("Eggy imported animation", 320, 240, .{ .vulkan = true }));
    defer window.window.deinit();
    var graphics = try Graphics.initWithSettings(gpa, window, .{ .backend = .vulkan, .anti_aliasing = .off, .width = 320, .height = 240 });
    defer graphics.deinit();
    var scene = try SceneTexture.init(&graphics);
    defer scene.deinit();
    defer graphics.queue.waitIdle() catch @panic("animation GPU work did not finish");
    var context: u8 = 0;
    graphics.models.loader = .{ .context = &context, .load = animatedTriangle };
    graphics.clips.resources = @import("resources/resources.zig").Resources.from(&context, importedAnimation, animatedTriangle, checker);
    var animators = [_]@import("animation.zig").Animator{
        .{ .playing = false }, .{ .playing = false },
    };
    const model_key = "000000000000002a";
    var drawables = [_]mesh.Drawable{
        .{ .model = .{ .{ 0.5, 0, 0, 0 }, .{ 0, 0.5, 0, 0 }, .{ 0, 0, 0.5, 0 }, .{ -1.25, 0, 0, 1 } }, .color = .{ 1, 0.1, 0.1, 1 }, .shape = .cube, .entity_id = 0, .entity_generation = 0, .model_file = model_key, .model_file_len = model_key.len, .animator = &animators[0] },
        .{ .model = .{ .{ 0.5, 0, 0, 0 }, .{ 0, 0.5, 0, 0 }, .{ 0, 0, 0.5, 0 }, .{ 1.25, 0, 0, 1 } }, .color = .{ 1, 0.1, 0.1, 1 }, .shape = .cube, .entity_id = 1, .entity_generation = 0, .model_file = model_key, .model_file_len = model_key.len, .animator = &animators[1] },
    };
    const view = camera.View.lookingAt(.{ 0, 0, 4 }, .{ 0, 0, 0 }, .{});
    for ([_]u64{ 43, 44, 45 }) |clip_id| {
        animators[0].model_clip = .fromId(clip_id);
        animators[0].time_s = 0;
        animators[1] = animators[0];
        drawables[0].model[3][0] = -1.25;
        const rest = try scenePixels(gpa, &graphics, &scene, &drawables, view);
        defer gpa.free(rest);
        animators[0].time_s = 0.5;
        const posed = try scenePixels(gpa, &graphics, &scene, &drawables, view);
        defer gpa.free(posed);
        try std.testing.expect(!std.mem.eql(u8, rest, posed));
        for (0..128) |row| {
            const right = row * 128 * 4 + 64 * 4;
            try std.testing.expectEqualSlices(u8, rest[right..][0 .. 64 * 4], posed[right..][0 .. 64 * 4]);
        }

        // Moving the joint, morph, or baked vertices must match the same rigid world-space move.
        animators[0].model_clip = .{};
        drawables[0].model[3][0] += 0.5;
        const translated = try scenePixels(gpa, &graphics, &scene, &drawables, view);
        defer gpa.free(translated);
        try std.testing.expectEqualSlices(u8, translated, posed);
    }
}

fn animatedTriangle(raw: *anyopaque, gpa: std.mem.Allocator, key: []const u8) !assets.Model {
    var model = try triangle(raw, gpa, key);
    errdefer model.deinit(gpa);
    model.parts[0].vertex_count = 3;
    model.parts[0].node = 0;
    model.parts[0].skin = 0;
    model.parts[0].morph_count = 1;
    model.rig.nodes = try gpa.dupe(assets.model.Node, &.{.{ .name = &.{} }});
    model.rig.nodes[0].name = try gpa.dupe(u8, "root");
    model.rig.influences = try gpa.dupe(assets.model.Influence, &@as([3]assets.model.Influence, @splat(.{ .weights = .{ 1, 0, 0, 0 } })));
    model.rig.skins = try gpa.dupe(assets.model.Skin, &.{.{ .joints = &.{}, .inverse_bind = &.{} }});
    model.rig.skins[0].joints = try gpa.dupe(u32, &.{0});
    model.rig.skins[0].inverse_bind = try gpa.dupe([4][4]f32, &.{.{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } }});
    model.rig.morph_targets = try gpa.dupe(assets.model.MorphTarget, &.{.{ .name = &.{}, .deltas = &.{} }});
    model.rig.morph_targets[0].name = try gpa.dupe(u8, "slide");
    model.rig.morph_targets[0].deltas = try gpa.dupe(assets.model.MorphDelta, &.{
        .{ .vertex = 0, .position = .{ 2, 0, 0 } },
        .{ .vertex = 1, .position = .{ 2, 0, 0 } },
        .{ .vertex = 2, .position = .{ 2, 0, 0 } },
    });
    if (!model.isWhole()) return error.InvalidAnimationFixture;
    return model;
}

fn importedAnimation(_: *anyopaque, gpa: std.mem.Allocator, key: []const u8) ![:0]u8 {
    var times = [_]f32{ 0, 1 };
    var translation = [_]f32{ 0, 0, 0, 2, 0, 0 };
    var weights = [_]f32{ 0, 1 };
    var vertices = [_]f32{ -1, -1, 0, 1, -1, 0, 0, 1, 0, 1, -1, 0, 3, -1, 0, 2, 1, 0 };
    var tracks = [_]assets.model.Track{switch (try assets.id.parse(key)) {
        43 => .{ .channel = .translation, .target = 0, .stride = 3, .times = &times, .values = &translation },
        44 => .{ .channel = .morph_weights, .target = 0, .stride = 1, .times = &times, .values = &weights },
        45 => .{ .channel = .vertex_cache, .target = 0, .stride = 9, .times = &times, .values = &vertices },
        else => return error.FileNotFound,
    }};
    var bytes = std.Io.Writer.Allocating.init(gpa);
    defer bytes.deinit();
    try assets.imported_clip.write(&bytes.writer, .{
        .source_model = 42,
        .clip = .{ .name = "slide", .duration_s = 1, .tracks = &tracks },
    });
    return gpa.dupeSentinel(u8, bytes.written(), 0);
}

fn scenePixels(gpa: std.mem.Allocator, graphics: *Graphics, scene: *SceneTexture, drawables: []mesh.Drawable, view: camera.View) ![]u8 {
    const size = 128;
    const length = size * size * 4;
    const destination = try vit.Buffer.init(graphics.device, .{ .size = length, .usage = .{ .transfer_dst = true }, .memory = .readback });
    defer destination.deinit();
    const frame = try graphics.beginFrame();
    try scene.render(graphics, frame.cmd, .{ .width = size, .height = size }, drawables, view, &.{}, false);
    const target = scene.target.?.texture;
    try frame.cmd.barrier(&.{.{ .texture = .{ .texture = target, .before = .sampled, .after = .copy_source } }});
    try frame.cmd.copyTextureToBuffer(.{ .buffer = destination, .bytes_per_row = size * 4, .texture = .{ .texture = target }, .extent = .{ .width = size, .height = size } });
    try frame.cmd.barrier(&.{.{ .texture = .{ .texture = target, .before = .copy_source, .after = .sampled } }});
    try graphics.endFrame(frame);
    try graphics.queue.waitIdle();
    const mapped = try destination.map(.read, .{ .size = length });
    defer destination.unmap(null);
    return gpa.dupe(u8, mapped[0..length]);
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
