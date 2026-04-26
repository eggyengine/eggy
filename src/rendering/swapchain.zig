const vk = @import("vulkan");
const std = @import("std");
const vulkan = @import("vulkan.zig");
const eggy = @import("../eggy.zig");
const sdl = @import("sdl3");
const texture = @import("texture.zig");

const Allocator = std.mem.Allocator;

pub const Swapchain = struct {
    allocator: Allocator,
    device: vk.DeviceProxy,

    swapchain: vk.SwapchainKHR,
    swapchain_images: std.ArrayList(vk.Image),
    surface_format: vk.SurfaceFormatKHR,
    swapchain_extent: vk.Extent2D,
    image_views: std.ArrayList(texture.TextureView),

    /// Recreates the existing swapchain
    pub fn recreate(self: *@This(), e_vulkan: *vulkan.EggyVulkanInterface) !void {
        var size = e_vulkan.window.getSize() catch .{ 0, 0 };
        while (size[0] == 0 or size[1] == 0) {
            sdl.events.wait() catch {};
            size = e_vulkan.window.getSize() catch .{ 0, 0 };
        }
        
        try e_vulkan.await();
        self.cleanup();
        self.* = try Swapchain.init(e_vulkan);
    }

    pub fn cleanup(self: *@This()) void {
        for (self.image_views.items) |view| {
            self.device.destroyImageView(view.image_view, null);
        }
        self.image_views.clearAndFree(self.allocator);
        self.swapchain_images.clearAndFree(self.allocator);
        self.device.destroySwapchainKHR(self.swapchain, null);
    }

    pub fn init(e_vulkan: *vulkan.EggyVulkanInterface) !Swapchain {
        var self: Swapchain = undefined;
        self.allocator = e_vulkan.allocator;
        self.device = e_vulkan.device;

        const capabilities = try e_vulkan.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(e_vulkan.pdev, e_vulkan.surface);
        self.swapchain_extent = chooseSwapExtent(capabilities, e_vulkan.window);
        const min_image_count = chooseSwapMinImageCount(capabilities);

        const available_formats = try e_vulkan.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(e_vulkan.pdev, e_vulkan.surface, e_vulkan.allocator);
        defer e_vulkan.allocator.free(available_formats);
        self.surface_format = chooseSwapSurfaceFormat(available_formats);

        const available_present_modes = try e_vulkan.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(e_vulkan.pdev, e_vulkan.surface, e_vulkan.allocator);
        defer e_vulkan.allocator.free(available_present_modes);
        const present_mode = chooseSwapPresentMode(available_present_modes);

        const swapchain_create_info = vk.SwapchainCreateInfoKHR{
            .surface = e_vulkan.surface,
            .min_image_count = min_image_count,
            .image_format = self.surface_format.format,
            .image_color_space = self.surface_format.color_space,
            .image_extent = self.swapchain_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
        };

        self.swapchain = try e_vulkan.device.createSwapchainKHR(&swapchain_create_info, null);

        const swapchain_images = try e_vulkan.device.getSwapchainImagesAllocKHR(self.swapchain, e_vulkan.allocator);
        defer e_vulkan.allocator.free(swapchain_images);

        self.swapchain_images = .empty;
        try self.swapchain_images.appendSlice(e_vulkan.allocator, swapchain_images);

        self.image_views = .empty;
        for (swapchain_images) |image| {
            const view = try texture.TextureView.initFromVKImage(e_vulkan, image, .{
                .format = self.surface_format.format
            });
            try self.image_views.append(e_vulkan.allocator, view);
        }

        std.log.debug("Created swapchain with {d} images", .{swapchain_images.len});
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.cleanup();
    }
};

fn chooseSwapExtent(capabilities: vk.SurfaceCapabilitiesKHR, window: *sdl.video.Window) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) {
        return capabilities.current_extent;
    }

    const size = window.getSize() catch return capabilities.current_extent;
    return .{
        .width = std.math.clamp(@as(u32, @intCast(size[0])), capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(@as(u32, @intCast(size[1])), capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}

fn chooseSwapMinImageCount(capabilities: vk.SurfaceCapabilitiesKHR) u32 {
    var min_img_cnt = @max(3, capabilities.min_image_count);
    if ((0 < capabilities.max_image_count) and (capabilities.max_image_count < min_img_cnt)) {
        min_img_cnt = capabilities.max_image_count;
    }
    return min_img_cnt;
}

fn chooseSwapSurfaceFormat(available_formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    std.debug.assert(available_formats.len > 0);
    for (available_formats) |format| {
        if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
            return format;
        }
    }
    return available_formats[0];
}

fn chooseSwapPresentMode(available_present_modes: []const vk.PresentModeKHR) vk.PresentModeKHR {
    for (available_present_modes) |mode| {
        if (mode == .mailbox_khr) {
            return .mailbox_khr;
        }
    }
    return .fifo_khr;
}