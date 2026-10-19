//! Backend/GPU selection and the user-configurable capabilities they actually provide.
const std = @import("std");
const builtin = @import("builtin");
const vit = @import("vitellus");
const render = @import("render_settings.zig");

pub fn mask(backend: render.Backend) ?vit.BackendType {
    return if (backend == .auto) null else .{
        .vulkan = backend == .vulkan,
        .dx12 = backend == .dx12,
        .webgpu = backend == .webgpu,
    };
}

pub fn selectAdapter(instance: vit.Instance, index: u16) !vit.Adapter {
    const choices = try instance.enumerateAdapters();
    defer instance.allocator.free(choices);
    if (index >= choices.len) {
        for (choices) |choice| choice.deinit();
        return error.InvalidGraphicsAdapter;
    }
    for (choices, 0..) |choice, i| if (i != index) choice.deinit();
    return choices[index];
}

/// Query once at startup; returned adapter names and option sets own no heap allocations.
pub fn capabilities(adapter: vit.Adapter, instance: vit.Instance, present_modes: std.enums.EnumSet(render.PresentMode), format: vit.Format) !render.Capabilities {
    const native = adapter.capabilities();
    var caps = render.Capabilities{
        .present_modes = present_modes,
        .window_settings = builtin.os.tag != .emscripten and !builtin.abi.isAndroid(),
        .frame_limit = builtin.os.tag != .emscripten,
        .max_anisotropy = if (native.features.anisotropic_filtering) @min(16, @max(1, native.limits.max_sampler_anisotropy)) else 1,
        .max_shadow_resolution = @min(4096, native.limits.max_texture_dimension_2d),
    };
    switch (builtin.os.tag) {
        .windows => {
            caps.backends.insert(.dx12);
            caps.backends.insert(.vulkan);
        },
        .emscripten => caps.backends.insert(.webgpu),
        else => caps.backends.insert(.vulkan),
    }
    const color = adapter.formatCapabilities(format).sample_counts;
    const depth = adapter.formatCapabilities(.d32_float).sample_counts;
    if (color.two and depth.two) caps.anti_aliasing.insert(.msaa_2x);
    if (color.four and depth.four) caps.anti_aliasing.insert(.msaa_4x);
    if (color.eight and depth.eight) caps.anti_aliasing.insert(.msaa_8x);
    if (comptime builtin.os.tag != .emscripten) {
        const choices = instance.enumerateAdapters() catch |err| {
            std.log.warn("manual GPU selection unavailable: {t}", .{err});
            return caps;
        };
        defer {
            for (choices) |choice| choice.deinit();
            instance.allocator.free(choices);
        }
        if (choices.len > caps.adapters.len) return error.TooManyGraphicsAdapters;
        for (choices, 0..) |choice, i| {
            const info = choice.info();
            caps.adapters[i] = .{ .name = info.name, .name_len = info.name_len };
        }
        caps.adapter_count = choices.len;
    }
    return caps;
}
