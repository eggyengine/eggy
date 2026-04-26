const std = @import("std");
const vk = @import("vulkan");

pub inline fn vkSetName(
    device: vk.DeviceProxy,
    comptime T: type,
    handle: T,
    name: ?[*:0]const u8,
) void {
    if (comptime !std.debug.runtime_safety) return; // strips in release

    const object_type = comptime switch (T) {
        vk.CommandBuffer       => vk.ObjectType.command_buffer,
        vk.CommandPool         => vk.ObjectType.command_pool,
        vk.Image               => vk.ObjectType.image,
        vk.ImageView           => vk.ObjectType.image_view,
        vk.Buffer              => vk.ObjectType.buffer,
        vk.BufferView          => vk.ObjectType.buffer_view,
        vk.Pipeline            => vk.ObjectType.pipeline,
        vk.PipelineLayout      => vk.ObjectType.pipeline_layout,
        vk.PipelineCache       => vk.ObjectType.pipeline_cache,
        vk.RenderPass          => vk.ObjectType.render_pass,
        vk.Framebuffer         => vk.ObjectType.framebuffer,
        vk.ShaderModule        => vk.ObjectType.shader_module,
        vk.DescriptorSet       => vk.ObjectType.descriptor_set,
        vk.DescriptorSetLayout => vk.ObjectType.descriptor_set_layout,
        vk.DescriptorPool      => vk.ObjectType.descriptor_pool,
        vk.Sampler             => vk.ObjectType.sampler,
        vk.Queue               => vk.ObjectType.queue,
        vk.Semaphore           => vk.ObjectType.semaphore,
        vk.Fence               => vk.ObjectType.fence,
        vk.Device              => vk.ObjectType.device,
        vk.DeviceMemory        => vk.ObjectType.device_memory,
        vk.SwapchainKHR        => vk.ObjectType.swapchain_khr,
        vk.SurfaceKHR          => vk.ObjectType.surface_khr,
        vk.Instance            => vk.ObjectType.instance,
        vk.PhysicalDevice      => vk.ObjectType.physical_device,
        vk.QueryPool           => vk.ObjectType.query_pool,
        vk.Event               => vk.ObjectType.event,
        else => @compileError("Unsupported Vulkan object type: " ++ @typeName(T)),
    };

    const name_info = vk.DebugUtilsObjectNameInfoEXT{
        .object_type   = object_type,
        .object_handle = @intFromEnum(handle),
        .p_object_name = name,
    };

    device.setDebugUtilsObjectNameEXT(&name_info) catch {};
}