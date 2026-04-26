const rendering = @import("vulkan.zig");
const pipeline = @import("pipeline.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const vk = @import("vulkan");
const colour = @import("../utils/colour.zig");
const std = @import("std");
const math = @import("../math.zig");


/// Image layout states.
pub const ImageLayout = enum {
    undefined,
    transfer_dst_optimal,
    shader_read_only_optimal,
    color_attachment_optimal,
    present_src,

    fn toVk(self: ImageLayout) vk.ImageLayout {
        return switch (self) {
            .undefined => .undefined,
            .transfer_dst_optimal => .transfer_dst_optimal,
            .shader_read_only_optimal => .shader_read_only_optimal,
            .color_attachment_optimal => .color_attachment_optimal,
            .present_src => .present_src_khr,
        };
    }
};

/// Index element types.
pub const IndexType = enum {
    uint16,
    uint32,

    fn toVk(self: IndexType) vk.IndexType {
        return switch (self) {
            .uint16 => .uint16,
            .uint32 => .uint32,
        };
    }
};

/// Load operation for attachments.
pub const LoadOp = enum {
    clear,
    load,
    dont_care,

    fn toVk(self: LoadOp) vk.AttachmentLoadOp {
        return switch (self) {
            .clear => .clear,
            .load => .load,
            .dont_care => .dont_care,
        };
    }
};

/// Store operation for attachments.
pub const StoreOp = enum {
    store,
    dont_care,

    fn toVk(self: StoreOp) vk.AttachmentStoreOp {
        return switch (self) {
            .store => .store,
            .dont_care => .dont_care,
        };
    }
};

/// Operations for an attachment (load + store behavior).
pub const Operations = struct {
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
};

/// Color attachment configuration for rendering.
pub const ColorAttachment = struct {
    view: ?*texture.TextureView = null,
    clear_color: colour.Colour = colour.Colour.black,
    ops: Operations = .{},
};

pub const DepthStencilAttachment = struct {
    view: *texture.TextureView,
    depth_clear_value: f32 = 1.0,
    depth_ops: Operations = .{ .load_op = .clear, .store_op = .dont_care },
    stencil_clear_value: u32 = 0,
    stencil_ops: ?Operations = null,
};

/// Configuration for beginRendering.
pub const RenderingInfo = struct {
    color_attachment: ColorAttachment = .{},
    depth_stencil_attachment: ?DepthStencilAttachment = null,
};

fn colourToVk(c: colour.Colour) vk.ClearValue {
    return .{ .color = .{ .float_32 = .{ c.r, c.g, c.b, c.a } } };
}

pub const CommandBuffer = struct {
    e_vulkan: *rendering.EggyVulkanInterface,
    cmd: vk.CommandBuffer,
    frame_index: usize,

    /// Create a CommandBuffer for the current frame.
    pub fn init(e_vulkan: *rendering.EggyVulkanInterface) CommandBuffer {
        return .{
            .e_vulkan = e_vulkan,
            .cmd = e_vulkan.command_buffers[e_vulkan.current_frame],
            .frame_index = e_vulkan.current_frame,
        };
    }

    /// Allocate and begin a one-shot command buffer (not tied to a frame).
    pub fn begin(e_vulkan: *rendering.EggyVulkanInterface) !CommandBuffer {
        const allocInfo = vk.CommandBufferAllocateInfo{
            .command_pool = e_vulkan.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };

        var command_buffer: vk.CommandBuffer = undefined;
        try e_vulkan.device.allocateCommandBuffers(&allocInfo, @ptrCast(&command_buffer));

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };
        try e_vulkan.device.beginCommandBuffer(command_buffer, &begin_info);

        return CommandBuffer{
            .e_vulkan = e_vulkan,
            .cmd = command_buffer,
            .frame_index = 0,
        };
    }

    /// End recording, submit, wait, and free the command buffer. 
    /// 
    /// Supports both oneshot command buffers and 
    pub fn end(self: *@This()) void {
        self.e_vulkan.device.endCommandBuffer(self.cmd) catch unreachable;

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.cmd),
        };
        self.e_vulkan.device.queueSubmit(self.e_vulkan.queue.inner, &.{submit_info}, .null_handle) catch unreachable;
        self.e_vulkan.device.queueWaitIdle(self.e_vulkan.queue.inner) catch unreachable;

        self.e_vulkan.device.freeCommandBuffers(self.e_vulkan.command_pool, &.{self.cmd});
    }

    /// Begin dynamic rendering with the swapchain image as the color attachment.
    pub fn beginRendering(self: *@This(), info: RenderingInfo) void {
        const frame = self;

        self.transitionSwapchainImageLayout(
            .undefined,
            .color_attachment_optimal,
            .{},
            .{ .color_attachment_write_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_output_bit = true },
        );

        if (info.depth_stencil_attachment) |depth| {
            const image = if (depth.view.texture) |tex| tex.texture else @panic("depth view must reference a texture");
            const depth_barrier = vk.ImageMemoryBarrier2{
                .src_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
                .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
                .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
                .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .depth_attachment_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{
                    .aspect_mask = .{ .depth_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            const dep_info = vk.DependencyInfo{
                .image_memory_barrier_count = 1,
                .p_image_memory_barriers = @ptrCast(&depth_barrier),
            };
            self.e_vulkan.device.cmdPipelineBarrier2(self.cmd, &dep_info);
        }

        const color_view = if (info.color_attachment.view) |v|
            v.image_view
        else
            frame.e_vulkan.swapchain.image_views.items[frame.e_vulkan.current_image_index].image_view;

        const color_attachment_info = vk.RenderingAttachmentInfo{
            .image_view = color_view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = info.color_attachment.ops.load_op.toVk(),
            .store_op = info.color_attachment.ops.store_op.toVk(),
            .clear_value = colourToVk(info.color_attachment.clear_color),
        };

        var depth_attachment_info: vk.RenderingAttachmentInfo = undefined;
        const p_depth: ?*const vk.RenderingAttachmentInfo = if (info.depth_stencil_attachment) |depth| blk: {
            depth_attachment_info = .{
                .image_view = depth.view.image_view,
                .image_layout = .depth_stencil_attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_view = .null_handle,
                .resolve_image_layout = .undefined,
                .load_op = depth.depth_ops.load_op.toVk(),
                .store_op = depth.depth_ops.store_op.toVk(),
                .clear_value = .{ .depth_stencil = .{ .depth = depth.depth_clear_value, .stencil = depth.stencil_clear_value } },
            };
            break :blk &depth_attachment_info;
        } else null;

        const rendering_info = vk.RenderingInfo{
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = frame.e_vulkan.swapchain.swapchain_extent,
            },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_info),
            .p_depth_attachment = p_depth,
        };

        frame.e_vulkan.device.cmdBeginRendering(frame.cmd, &rendering_info);
        self.setFullViewport();
        self.setFullScissor();
    }

    /// End the current dynamic rendering scope.
    pub fn endRendering(self: *@This()) void {
        self.e_vulkan.device.cmdEndRendering(self.cmd);
    }

    /// Bind a graphics pipeline.
    pub fn bindPipeline(self: *@This(), p: pipeline.Pipeline) void {
        self.e_vulkan.device.cmdBindPipeline(self.cmd, .graphics, p.handle);
    }

    /// Bind a descriptor set for the current frame.
    pub fn bindDescriptor(self: *@This(), resource: buffer.DescriptorSetResource, p: pipeline.Pipeline) void {
        const descriptor_set = resource.descriptor_sets[self.frame_index];
        self.e_vulkan.device.cmdBindDescriptorSets(
            self.cmd,
            .graphics,
            p.layout,
            0,
            @ptrCast(&descriptor_set),
            null,
        );
    }

    /// Bind a vertex buffer. Accepts `RawBuffer`, `Buffer(T)`, or `VertexBuffer(T)`.
    pub fn bindVertexBuffer(self: *@This(), buf: anytype) void {
        const offsets = [_]vk.DeviceSize{0};
        const vk_buffer = if (@hasField(@TypeOf(buf), "raw")) buf.raw.buffer else buf.buffer;
        self.e_vulkan.device.cmdBindVertexBuffers(self.cmd, 0, @ptrCast(&vk_buffer), &offsets);
    }

    /// Bind an index buffer. Accepts `IndexBuffer(T)` or `RawBuffer`, and `T` must be that of an `index_type`. 
    pub fn bindIndexBuffer(self: *@This(), buf: anytype, index_type: IndexType) void {
        const vk_buffer = if (@hasField(@TypeOf(buf), "raw")) buf.raw.buffer else buf.buffer;
        self.e_vulkan.device.cmdBindIndexBuffer(self.cmd, vk_buffer, 0, index_type.toVk());
    }

    /// Draw vertices directly.
    pub fn draw(self: *@This(), vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.e_vulkan.device.cmdDraw(self.cmd, vertex_count, instance_count, first_vertex, first_instance);
    }

    /// Draw indexed vertices.
    pub fn drawIndexed(self: *@This(), index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
        self.e_vulkan.device.cmdDrawIndexed(self.cmd, index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    /// Set viewport to cover the full swapchain extent.
    pub fn setFullViewport(self: *@This()) void {
        const ext = self.e_vulkan.swapchain.swapchain_extent;
        self.setViewport(0, 0, @floatFromInt(ext.width), @floatFromInt(ext.height));
    }

    /// Set scissor to cover the full swapchain extent.
    pub fn setFullScissor(self: *@This()) void {
        const ext = self.e_vulkan.swapchain.swapchain_extent;
        self.setScissor(0, 0, ext.width, ext.height);
    }

    /// Set a custom viewport.
    pub fn setViewport(self: *@This(), x: f32, y: f32, width: f32, height: f32) void {
        const viewport = vk.Viewport{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .min_depth = 0.0,
            .max_depth = 1.0,
        };
        const viewports = [_]vk.Viewport{viewport};
        self.e_vulkan.device.cmdSetViewport(self.cmd, 0, &viewports);
    }

    /// Set a custom scissor rectangle.
    pub fn setScissor(self: *@This(), x: i32, y: i32, width: u32, height: u32) void {
        const scissor = vk.Rect2D{
            .offset = .{ .x = x, .y = y },
            .extent = .{ .width = width, .height = height },
        };
        const scissors = [_]vk.Rect2D{scissor};
        self.e_vulkan.device.cmdSetScissor(self.cmd, 0, &scissors);
    }

    /// Copy data between two buffers.
    pub fn copyBuffer(self: *@This(), src: buffer.RawBuffer, dst: buffer.RawBuffer) void {
        const region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = src.size,
        };
        self.e_vulkan.device.cmdCopyBuffer(self.cmd, src.buffer, dst.buffer, 1, @ptrCast(&region));
    }

    pub fn transitionImageLayout(self: *@This(), tex: texture.Texture, old_layout: ImageLayout, new_layout: ImageLayout, subresource_range: texture.TextureViewOptions.SubresourceRange) void {
        var src_access_mask: vk.AccessFlags = .{};
        var dst_access_mask: vk.AccessFlags = .{};
        var src_stage_mask: vk.PipelineStageFlags = .{};
        var dst_stage_mask: vk.PipelineStageFlags = .{};

        const old_vk = old_layout.toVk();
        const new_vk = new_layout.toVk();

        if (old_vk == .undefined and new_vk == .transfer_dst_optimal) {
            src_access_mask = .{};
            dst_access_mask = .{ .transfer_write_bit = true };
            src_stage_mask = .{ .top_of_pipe_bit = true };
            dst_stage_mask = .{ .transfer_bit = true };
        } else if (old_vk == .transfer_dst_optimal and new_vk == .shader_read_only_optimal) {
            src_access_mask = .{ .transfer_write_bit = true };
            dst_access_mask = .{ .shader_read_bit = true };
            src_stage_mask = .{ .transfer_bit = true };
            dst_stage_mask = .{ .fragment_shader_bit = true };
        } else {
            @panic("unsupported layout transition");
        }

        const barrier = vk.ImageMemoryBarrier{
            .src_access_mask = src_access_mask,
            .dst_access_mask = dst_access_mask,
            .old_layout = old_vk,
            .new_layout = new_vk,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = tex.texture,
            .subresource_range = subresource_range.toVk()
        };

        self.e_vulkan.device.cmdPipelineBarrier(self.cmd, src_stage_mask, dst_stage_mask, .{}, null, null, &.{barrier});
    }

    /// Copy a buffer's contents into a texture image.
    /// The texture must already be in transfer_dst_optimal layout.
    pub fn copyBufferToImage(self: *@This(), buf: buffer.RawBuffer, tex: texture.Texture, width: u32, height: u32) void {
        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };

        self.e_vulkan.device.cmdCopyBufferToImage(self.cmd, buf.buffer, tex.texture, .transfer_dst_optimal, &.{region});
    }


    /// Transition the current swapchain image layout
    pub fn transitionSwapchainImageLayout(
        self: *@This(),
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        src_access_mask: vk.AccessFlags2,
        dst_access_mask: vk.AccessFlags2,
        src_stage_mask: vk.PipelineStageFlags2,
        dst_stage_mask: vk.PipelineStageFlags2,
    ) void {
        const barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = src_stage_mask,
            .src_access_mask = src_access_mask,
            .dst_stage_mask = dst_stage_mask,
            .dst_access_mask = dst_access_mask,
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.e_vulkan.swapchain.swapchain_images.items[self.e_vulkan.current_image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const dependency_info = vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        };

        self.e_vulkan.device.cmdPipelineBarrier2(self.cmd, &dependency_info);
    }

    /// Get the swapchain extent.
    pub fn extent(self: *@This()) math.Vec2u {
        const ext = self.e_vulkan.swapchain.swapchain_extent;
        return .{ .x = ext.width, .y = ext.height };
    }
};