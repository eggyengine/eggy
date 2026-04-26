const std = @import("std");
const eggy = @import("eggy.zig");

pub const windowing = @import("windowing.zig");
pub const rendering = @import("rendering.zig");
pub const input = @import("input.zig");

pub const DefaultModuleOptions = struct {
    windowing_options: windowing.WindowingModuleOptions = .{},
};

/// This module allows for you to run a simple window and a renderer, as well as input and more.
///
/// # Backends
/// ## Windowing
/// - SDL3
/// ## Graphics
/// - Vulkan - Options can be provided through `EggyVulkanInterface.Options`
///
/// # Example
/// ```zig
/// eggy.mod.DefaultModule(.{}, eggy.mod.rendering.vulkan.EggyVulkanInterface)
/// ```
pub fn DefaultModule(comptime options: DefaultModuleOptions, comptime BackendImpl: type) type {
    return struct {
        pub const sub_modules = &.{
            // order matters, dont change its existing order.
            input.InputModule(),
            windowing.WindowingModule(options.windowing_options, BackendImpl.sdl_backend),
            rendering.RenderingModule(BackendImpl),
        };

        pub const schedules = .{};
    };
}
