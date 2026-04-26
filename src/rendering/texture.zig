pub const zigimg = @import("zigimg");

const std = @import("std");
const rendering = @import("vulkan.zig");
const cmd = @import("command.zig");
const vk = @import("vulkan");
const Context = @import("../ctx.zig").Context;

pub const TextureOptions = struct {
    label: ?[*:0]const u8 = null,
    format: vk.Format = .r8g8b8a8_srgb,
    tiling: vk.ImageTiling = .optimal,
    usage: vk.ImageUsageFlags = .{ .transfer_dst_bit = true, .sampled_bit = true },
    memory_properties: vk.MemoryPropertyFlags = .{ .device_local_bit = true },
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: vk.SampleCountFlags = .{ .@"1_bit" = true },
    image_type: vk.ImageType = .@"2d",
    sharing_mode: vk.SharingMode = .exclusive,
    initial_layout: vk.ImageLayout = .undefined,
    subresource_range: TextureViewOptions.SubresourceRange = .{},
};

pub const Texture = struct {
    e_vulkan: *rendering.EggyVulkanInterface,

    texture: vk.Image = undefined,
    texture_mem: vk.DeviceMemory = undefined,
    options: TextureOptions,
    width: u32 = 0,
    height: u32 = 0,

    /// Create an empty texture with the given dimensions. No data is uploaded.
    pub fn init(e_vulkan: *rendering.EggyVulkanInterface, width: u32, height: u32, options: TextureOptions) !Texture {
        var self = Texture{
            .e_vulkan = e_vulkan,
            .options = options,
            .width = width,
            .height = height,
        };

        try self.createImage(
            options.format,
            .{ .width = width, .height = height, .depth = 1 },
            options.tiling,
            options.usage,
            options.memory_properties,
            options.label,
        );

        return self;
    }

    /// Create a texture from an image file and upload its contents.
    pub fn initFromFile(ctx: *Context, e_vulkan: *rendering.EggyVulkanInterface, file: std.Io.File, options: TextureOptions) !Texture {
        var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        var image = try zigimg.Image.fromFile(ctx.proc_init.gpa, ctx.proc_init.io, file, read_buffer[0..]);
        defer image.deinit(ctx.proc_init.gpa);
        return initFromImage(e_vulkan, &image, options);
    }

    /// Create a texture from embedded/in-memory image data and upload its contents.
    pub fn initFromMemory(ctx: *Context, e_vulkan: *rendering.EggyVulkanInterface, data: []const u8, options: TextureOptions) !Texture {
        var image = try zigimg.Image.fromMemory(ctx.proc_init.gpa, data);
        defer image.deinit(ctx.proc_init.gpa);
        return initFromImage(e_vulkan, &image, options);
    }

    /// Create a texture from a decoded zigimg Image and upload its contents.
    fn initFromImage(e_vulkan: *rendering.EggyVulkanInterface, image: *zigimg.Image, options: TextureOptions) !Texture {
        try image.convert(e_vulkan.allocator, .rgba32);
        var self = try init(e_vulkan, @intCast(image.width), @intCast(image.height), options);
        try self.write(image.rawBytes());
        return self;
    }

    /// Upload raw pixel data to the texture.
    /// Data must match the texture's format and dimensions.
    pub fn write(self: *Texture, pixels: []const u8) !void {
        var staging_buffer = try rendering.buffer.RawBuffer.init(
            self.e_vulkan,
            @intCast(pixels.len),
            .{ .TransferSrc = true },
            .{ .HostVisible = true, .HostCoherent = true },
            null,
        );
        defer staging_buffer.deinit();
        try staging_buffer.copyFromSlice(u8, pixels);

        var command_buffer = try cmd.CommandBuffer.begin(self.e_vulkan);
        command_buffer.transitionImageLayout(self.*, .undefined, .transfer_dst_optimal, self.options.subresource_range);
        command_buffer.copyBufferToImage(staging_buffer, self.*, self.width, self.height);
        command_buffer.transitionImageLayout(self.*, .transfer_dst_optimal, .shader_read_only_optimal, self.options.subresource_range);
        command_buffer.end();
    }

    fn createImage(self: *@This(), format: vk.Format, image_size: vk.Extent3D, tiling: vk.ImageTiling, usage: vk.ImageUsageFlags, properties: vk.MemoryPropertyFlags, label: ?[*:0]const u8) !void {
        const image_create_info = vk.ImageCreateInfo {
            .initial_layout = .undefined,
            .image_type = .@"2d",
            .format = format,
            .extent = image_size,
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = tiling,
            .usage = usage,
            .sharing_mode = .exclusive,
        };

        self.texture = try self.e_vulkan.device.createImage(&image_create_info, null);
        rendering.vkSetName(self.e_vulkan.device, vk.Image, self.texture, label);

        const mem_requirements = self.e_vulkan.device.getImageMemoryRequirements(self.texture);
        const mem_alloc_info = vk.MemoryAllocateInfo {
            .allocation_size = mem_requirements.size,
            .memory_type_index = rendering.buffer.findMemoryType(self.e_vulkan, mem_requirements.memory_type_bits, properties) orelse return error.NoSuitableMemoryType,
        };
        self.texture_mem = try self.e_vulkan.device.allocateMemory(&mem_alloc_info, null);
        try self.e_vulkan.device.bindImageMemory(self.texture, self.texture_mem, 0);
    }

    pub fn deinit(self: *@This()) void {
        self.e_vulkan.device.destroyImage(self.texture, null);
        self.e_vulkan.device.freeMemory(self.texture_mem, null);
    }
};

pub const TextureViewOptions = struct {
    pub const SubresourceRange = struct {
        aspect_mask: vk.ImageAspectFlags = .{ .color_bit = true },
        base_mip_level: u32 = 0,
        level_count: u32 = 1,
        base_array_layer: u32 = 0,
        layer_count: u32 = 1,

        pub fn toVk(self: @This()) vk.ImageSubresourceRange {
            return .{
                .aspect_mask = self.aspect_mask,
                .base_mip_level = self.base_mip_level,
                .level_count = self.level_count,
                .base_array_layer = self.base_array_layer,
                .layer_count = self.layer_count,
            };
        }
    };

    label: ?[*:0]const u8 = null,
    /// If this is not set, it will inherit from the Texture provided, or use a fallback. 
    format: ?vk.Format = null,
    view_type: vk.ImageViewType = .@"2d",
    components: vk.ComponentMapping = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    subresource_range: SubresourceRange = .{},

    pub fn toVk(self: TextureViewOptions, image: vk.Image, fallback_format: vk.Format) vk.ImageViewCreateInfo {
        return .{
            .image = image,
            .view_type = self.view_type,
            .format = self.format orelse fallback_format,
            .components = self.components,
            .subresource_range = self.subresource_range.toVk(),
        };
    }
};

pub const TextureView = struct {
    e_vulkan: *rendering.EggyVulkanInterface,
    /// The original texture the view is binded to. 
    /// 
    /// If set to `null`, likely means the value was binded to a lower-level Texture such as Swapchain. 
    texture: ?*Texture = null,

    image_view: vk.ImageView,

    pub fn init(e_vulkan: *rendering.EggyVulkanInterface, texture: *Texture, options: TextureViewOptions) !@This() {
        const view_info = options.toVk(texture.texture, texture.options.format);
        const view = try e_vulkan.device.createImageView(&view_info, null);
        rendering.vkSetName(e_vulkan.device, vk.ImageView, view, options.label);
        return .{
            .e_vulkan = e_vulkan,
            .texture = texture,
            .image_view = view,
        };
    }

    pub fn initFromVKImage(e_vulkan: *rendering.EggyVulkanInterface, image: vk.Image, options: TextureViewOptions) !@This() {
        const view_info = options.toVk(image, .r8g8b8a8_srgb);
        const view = try e_vulkan.device.createImageView(&view_info, null);
        rendering.vkSetName(e_vulkan.device, vk.ImageView, view, options.label);
        return .{
            .e_vulkan = e_vulkan,
            .image_view = view,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.e_vulkan.device.destroyImageView(self.image_view, null);
    }
};

pub const SamplerOptions = struct {
    label: ?[*:0]const u8 = null,
    mag_filter: vk.Filter = .linear,
    min_filter: vk.Filter = .linear,
    mipmap_mode: vk.SamplerMipmapMode = .linear,
    address_mode_u: vk.SamplerAddressMode = .repeat,
    address_mode_v: vk.SamplerAddressMode = .repeat,
    address_mode_w: vk.SamplerAddressMode = .repeat,
    mip_lod_bias: f32 = 0.0,
    anisotropy_enable: bool = true,
    /// If `max_anisotropy` is null, default is set to the maximum physical device limit. 
    max_anisotropy: ?f32 = null,
    compare_enable: bool = false,
    compare_op: vk.CompareOp = .always,
    min_lod: f32 = 0.0,
    max_lod: f32 = 0.0,
    border_color: vk.BorderColor = .int_opaque_black,
    unnormalized_coordinates: bool = false,

    pub fn toVk(self: SamplerOptions, v: *rendering.EggyVulkanInterface) vk.SamplerCreateInfo {
        const properties = v.instance.getPhysicalDeviceProperties(v.pdev);
        return .{
            .mag_filter = self.mag_filter,
            .min_filter = self.min_filter,
            .mipmap_mode = self.mipmap_mode,
            .address_mode_u = self.address_mode_u,
            .address_mode_v = self.address_mode_v,
            .address_mode_w = self.address_mode_w,
            .mip_lod_bias = self.mip_lod_bias,
            .anisotropy_enable = if (self.anisotropy_enable) .true else .false,
            .max_anisotropy = self.max_anisotropy orelse properties.limits.max_sampler_anisotropy,
            .compare_enable = if (self.compare_enable) .true else .false,
            .compare_op = self.compare_op,
            .min_lod = self.min_lod,
            .max_lod = self.max_lod,
            .border_color = self.border_color,
            .unnormalized_coordinates = if (self.unnormalized_coordinates) .true else .false,
        };
    }
};

pub const Sampler = struct {
    e_vulkan: *rendering.EggyVulkanInterface,
    sampler: vk.Sampler,

    pub fn init(e_vulkan: *rendering.EggyVulkanInterface, options: SamplerOptions) !@This() {
        const sampler_info = options.toVk(e_vulkan);
        const sampler = try e_vulkan.device.createSampler(&sampler_info, null);
        rendering.vkSetName(e_vulkan.device, vk.Sampler, sampler, options.label);
        return .{
            .e_vulkan = e_vulkan,
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.e_vulkan.device.destroySampler(self.sampler, null);
    }
};

const SupportedFormat = error {
    NoSuitableCandidate
};

pub fn findSupportedFormat(e_vulkan: *rendering.EggyVulkanInterface, candidates: []const vk.Format, tiling: vk.ImageTiling, features: vk.FormatFeatureFlags) !vk.Format {
    for (candidates) |format| {
        const props = e_vulkan.instance.getPhysicalDeviceFormatProperties(e_vulkan.pdev, format);
        if (tiling == .linear and props.linear_tiling_features.contains(features)) {
            return format;
        }
        if (tiling == .optimal and props.optimal_tiling_features.contains(features)) {
            return format;
        }
    }

    return SupportedFormat.NoSuitableCandidate;
}

fn hasStencilComponent(format: vk.Format) vk.Format {
    return format == .d32_sfloat_s8_uint or format == .d24_unorm_s8_uint;
}

pub const Extension = struct {
    pub const DepthTexture = struct {
        depth_texture: rendering.texture.Texture,
        depth_view: rendering.texture.TextureView,

        e_vulkan: *rendering.EggyVulkanInterface,

        pub fn init(self: *@This(), e_vulkan: *rendering.EggyVulkanInterface) !void {
            self.e_vulkan = e_vulkan;

            const options: rendering.texture.TextureOptions = .{
                .format = try rendering.texture.findSupportedFormat(
                    e_vulkan, 
                    &.{ .d32_sfloat, .d32_sfloat_s8_uint, .d24_unorm_s8_uint }, 
                    .optimal, 
                    .{ .depth_stencil_attachment_bit = true },
                ),
                .usage = .{ .depth_stencil_attachment_bit = true },
            };
            self.depth_texture = try rendering.texture.Texture.init(e_vulkan, e_vulkan.swapchain.swapchain_extent.width, e_vulkan.swapchain.swapchain_extent.height, options);
            self.depth_view = try rendering.texture.TextureView.init(e_vulkan, &self.depth_texture, .{ .subresource_range = .{ .aspect_mask = .{ .depth_bit = true } } });
        }

        pub fn recreate(self: *@This()) !void {
            try self.e_vulkan.await();
            self.depth_view.deinit();
            self.depth_texture.deinit();
            self.depth_texture = try rendering.texture.Texture.init(self.e_vulkan, self.e_vulkan.swapchain.swapchain_extent.width, self.e_vulkan.swapchain.swapchain_extent.height, self.depth_texture.options);
            self.depth_view = try rendering.texture.TextureView.init(self.e_vulkan, &self.depth_texture, .{ .subresource_range = .{ .aspect_mask = .{ .depth_bit = true } } });
        }

        pub fn format(self: *@This()) vk.Format {
            return self.depth_texture.options.format;
        } 

        pub fn deinit(self: *@This()) void {
            self.e_vulkan.await() catch {};

            self.depth_texture.deinit();
            self.depth_view.deinit();
        } 
    };
};