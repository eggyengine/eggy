const vk = @import("vulkan");
const rendering = @import("vulkan.zig");
const pipeline = @import("pipeline.zig");
const std = @import("std");

pub const BufferUsageFlags = struct {
    TransferSrc: bool = false,
    TransferDst: bool = false,
    UniformTexelBuffer: bool = false,
    StorageTexelBuffer: bool = false,
    UniformBuffer: bool = false,
    StorageBuffer: bool = false,
    IndexBuffer: bool = false,
    VertexBuffer: bool = false,
    IndirectBuffer: bool = false,
    ConditionalRendering: bool = false,
    ShaderBindingTable: bool = false,
    TransformFeedbackBuffer: bool = false,
    TransformFeedbackCounterBuffer: bool = false,
    VideoDecodeSrc: bool = false,
    VideoDecodeDst: bool = false,
    VideoEncodeDst: bool = false,
    VideoEncodeSrc: bool = false,
    ShaderDeviceAddress: bool = false,
    AccelerationStructureBuildInputReadOnly: bool = false,
    AccelerationStructureStorage: bool = false,
    SamplerDescriptorBuffer: bool = false,
    ResourceDescriptorBuffer: bool = false,
    MicromapBuildInputReadOnly: bool = false,
    MicromapStorage: bool = false,
    ExecutionGraphScratch: bool = false,
    PushDescriptorsDescriptorBuffer: bool = false,
    TileMemory: bool = false,
    DescriptorHeap: bool = false,

    pub fn toVk(self: BufferUsageFlags) vk.BufferUsageFlags {
        return .{
            .transfer_src_bit = self.TransferSrc,
            .transfer_dst_bit = self.TransferDst,
            .uniform_texel_buffer_bit = self.UniformTexelBuffer,
            .storage_texel_buffer_bit = self.StorageTexelBuffer,
            .uniform_buffer_bit = self.UniformBuffer,
            .storage_buffer_bit = self.StorageBuffer,
            .index_buffer_bit = self.IndexBuffer,
            .vertex_buffer_bit = self.VertexBuffer,
            .indirect_buffer_bit = self.IndirectBuffer,
            .conditional_rendering_bit_ext = self.ConditionalRendering,
            .shader_binding_table_bit_khr = self.ShaderBindingTable,
            .transform_feedback_buffer_bit_ext = self.TransformFeedbackBuffer,
            .transform_feedback_counter_buffer_bit_ext = self.TransformFeedbackCounterBuffer,
            .video_decode_src_bit_khr = self.VideoDecodeSrc,
            .video_decode_dst_bit_khr = self.VideoDecodeDst,
            .video_encode_dst_bit_khr = self.VideoEncodeDst,
            .video_encode_src_bit_khr = self.VideoEncodeSrc,
            .shader_device_address_bit = self.ShaderDeviceAddress,
            .acceleration_structure_build_input_read_only_bit_khr = self.AccelerationStructureBuildInputReadOnly,
            .acceleration_structure_storage_bit_khr = self.AccelerationStructureStorage,
            .sampler_descriptor_buffer_bit_ext = self.SamplerDescriptorBuffer,
            .resource_descriptor_buffer_bit_ext = self.ResourceDescriptorBuffer,
            .micromap_build_input_read_only_bit_ext = self.MicromapBuildInputReadOnly,
            .micromap_storage_bit_ext = self.MicromapStorage,
            .execution_graph_scratch_bit_amdx = self.ExecutionGraphScratch,
            .push_descriptors_descriptor_buffer_bit_ext = self.PushDescriptorsDescriptorBuffer,
            .tile_memory_bit_qcom = self.TileMemory,
            .descriptor_heap_bit_ext = self.DescriptorHeap,
        };
    }
};

pub const MemoryPropertyFlags = struct {
    DeviceLocal: bool = false,
    HostVisible: bool = false,
    HostCoherent: bool = false,
    HostCached: bool = false,
    LazilyAllocated: bool = false,
    Protected: bool = false,
    DeviceCoherent: bool = false,
    DeviceUncached: bool = false,

    pub fn toVk(self: MemoryPropertyFlags) vk.MemoryPropertyFlags {
        return .{
            .device_local_bit = self.DeviceLocal,
            .host_visible_bit = self.HostVisible,
            .host_coherent_bit = self.HostCoherent,
            .host_cached_bit = self.HostCached,
            .lazily_allocated_bit = self.LazilyAllocated,
            .protected_bit = self.Protected,
            .device_coherent_bit_amd = self.DeviceCoherent,
            .device_uncached_bit_amd = self.DeviceUncached,
        };
    }
};

/// Find a suitable memory type index for the given requirements.
pub fn findMemoryType(e_vulkan: *rendering.EggyVulkanInterface, typeFilter: u32, properties: vk.MemoryPropertyFlags) ?u32 {
    const memProps = e_vulkan.instance.getPhysicalDeviceMemoryProperties(e_vulkan.pdev);
    for (0..memProps.memory_type_count) |i| {
        if ((typeFilter & (@as(u32, 1) << @intCast(i))) != 0 and
            memProps.memory_types[i].property_flags.contains(properties))
        {
            return @intCast(i);
        }
    }
    return null;
}

/// A raw GPU buffer without type information
pub const RawBuffer = struct {
    e_vulkan: *rendering.EggyVulkanInterface,
    buffer: vk.Buffer,
    mem: vk.DeviceMemory,
    size: vk.DeviceSize,

    /// Create a raw buffer with the specified size, usage, and memory properties.
    pub fn init(
        e_vulkan: *rendering.EggyVulkanInterface,
        size: vk.DeviceSize,
        usage: BufferUsageFlags,
        mem_properties: MemoryPropertyFlags,
        label: ?[*:0]const u8,
    ) !RawBuffer {
        const buffer_info = vk.BufferCreateInfo{
            .size = size,
            .usage = usage.toVk(),
            .sharing_mode = .exclusive,
        };

        const buffer = try e_vulkan.device.createBuffer(&buffer_info, null);
        rendering.vkSetName(e_vulkan.device, vk.Buffer, buffer, label);
        errdefer e_vulkan.device.destroyBuffer(buffer, null);

        const memRequirements = e_vulkan.device.getBufferMemoryRequirements(buffer);

        const memAllocInfo = vk.MemoryAllocateInfo{
            .allocation_size = memRequirements.size,
            .memory_type_index = findMemoryType(e_vulkan, memRequirements.memory_type_bits, mem_properties.toVk()) orelse return error.NoSuitableMemoryType,
        };

        const mem = try e_vulkan.device.allocateMemory(&memAllocInfo, null);
        errdefer e_vulkan.device.freeMemory(mem, null);

        try e_vulkan.device.bindBufferMemory(buffer, mem, 0);
        std.log.debug("Initialised new buffer '{any}' [flags={any}]", .{label, usage});
        return RawBuffer{
            .e_vulkan = e_vulkan,
            .buffer = buffer,
            .mem = mem,
            .size = size,
        };
    }

    /// Map the buffer memory and return a pointer to it.
    pub fn map(self: *RawBuffer) !?*anyopaque {
        return try self.e_vulkan.device.mapMemory(self.mem, 0, self.size, .{});
    }

    /// Unmap the buffer memory.
    pub fn unmap(self: *RawBuffer) void {
        self.e_vulkan.device.unmapMemory(self.mem);
    }

    /// Copy data to the buffer. The buffer must be host-visible.
    /// 
    /// This already maps and unmaps the data for you, however you can map yourself with `RawBuffer.map/unmap`. 
    pub fn copyFromSlice(self: *RawBuffer, comptime T: type, data: []const T) !void {
        const mapped = try self.map();
        if (mapped) |ptr| {
            const dest: [*]T = @ptrCast(@alignCast(ptr));
            @memcpy(dest[0..data.len], data);
        }
        self.unmap();
    }

    pub fn deinit(self: RawBuffer) void {
        self.e_vulkan.device.freeMemory(self.mem, null);
        self.e_vulkan.device.destroyBuffer(self.buffer, null);
    }
};


pub fn copyBuffer(e_vulkan: *rendering.EggyVulkanInterface, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
    var cmd_buf: vk.CommandBuffer = undefined;
    try e_vulkan.device.allocateCommandBuffers(&.{
        .command_pool = e_vulkan.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmd_buf));
    defer e_vulkan.device.freeCommandBuffers(e_vulkan.command_pool, &.{cmd_buf});

    try e_vulkan.device.beginCommandBuffer(cmd_buf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const copy_region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    e_vulkan.device.cmdCopyBuffer(cmd_buf, src, dst, &.{copy_region});

    try e_vulkan.device.endCommandBuffer(cmd_buf);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd_buf),
    };
    try e_vulkan.device.queueSubmit(e_vulkan.queue.inner, &.{submit_info}, .null_handle);
    try e_vulkan.device.queueWaitIdle(e_vulkan.queue.inner);
}

pub fn createBuffer(
    e_vulkan: *rendering.EggyVulkanInterface,
    size: vk.DeviceSize,
    usage: BufferUsageFlags,
    mem_properties: MemoryPropertyFlags,
) !struct { buffer: vk.Buffer, mem: vk.DeviceMemory } {
    const raw = try RawBuffer.init(e_vulkan, size, usage, mem_properties);
    return .{ .buffer = raw.buffer, .mem = raw.mem };
}

/// Ensures that the alignment of the struct is suited to multiples of 16 bytes. 
/// 
/// If failure to check, it will result in a compile-time error. 
pub fn checkAlignment(comptime T: type) void {
    if (@sizeOf(T) % 16 != 0) {
        @compileError(std.fmt.comptimePrint("The type '{s}' must be aligned by 16 byte multiples (currently {d}). Use `eggy.math.Padding` to pad and ensure alignment", .{ @typeName(T), @sizeOf(T) }));
    }
}

/// A typed block of memory allocated to the GPU, with support for dirty-state checking. 
pub fn Buffer(comptime T: type) type {
    return struct {
        comptime {
            checkAlignment(T);
        }

        raw: RawBuffer,
        data: []const T,
        dirty: bool,

        /// Initialises a new `Buffer` with the data of a specific type. 
        /// 
        /// Make sure to flush it straight after with `Buffer.flush()`, otherwise you will not see anything.
        pub fn init(e_vulkan: *rendering.EggyVulkanInterface, data: []const T, usage: BufferUsageFlags) !@This() {
            const size: vk.DeviceSize = @sizeOf(T) * data.len;

            const raw = try RawBuffer.init(e_vulkan, size, usage, .{
                .HostVisible = true,
                .HostCoherent = true,
            });

            return @This(){
                .raw = raw,
                .data = data,
                .dirty = true,
            };
        }

        /// Initialises a new `Buffer` with custom memory properties.
        pub fn initWithMemoryProperties(
            e_vulkan: *rendering.EggyVulkanInterface,
            data: []const T,
            usage: BufferUsageFlags,
            mem_properties: MemoryPropertyFlags,
        ) !@This() {
            const size: vk.DeviceSize = @sizeOf(T) * data.len;

            const raw = try RawBuffer.init(e_vulkan, size, usage, mem_properties);

            return @This(){
                .raw = raw,
                .data = data,
                .dirty = true,
            };
        }

        /// Marks the buffer as dirty, so the next flush() will write data to GPU memory.
        pub fn markDirty(self: *@This()) void {
            self.dirty = true;
        }

        /// Returns whether the buffer has pending changes to write.
        pub fn isDirty(self: *@This()) bool {
            return self.dirty;
        }

        /// Writes data to GPU memory only if the buffer is dirty.
        /// 
        /// This function can be placed in your update function without any consequences. 
        pub fn flush(self: *@This()) !void {
            if (!self.dirty) return;

            const mapped = try self.raw.map();
            if (mapped) |ptr| {
                const dest: [*]T = @ptrCast(@alignCast(ptr));
                @memcpy(dest[0..self.data.len], self.data);
            }
            self.raw.unmap();
            self.dirty = false;
        }

        /// Updates the buffer data and marks it as dirty.
        pub fn write(self: *@This(), data: []const T) void {
            self.data = data;
            self.dirty = true;
        }

        pub fn deinit(self: *@This()) void {
            self.raw.e_vulkan.await() catch {};
            self.raw.deinit();
        }
    };
}

pub fn VertexBuffer(comptime T: type) type {
    return struct {
        raw: RawBuffer,
        len: usize,

        pub fn init(e_vulkan: *rendering.EggyVulkanInterface, data: []const T, label: ?[*:0]const u8) !@This() {
            const size: vk.DeviceSize = @sizeOf(T) * data.len;

            var staging = try RawBuffer.init(
                e_vulkan, 
                size, 
                .{ .TransferSrc = true }, 
                .{
                    .HostVisible = true,
                    .HostCoherent = true,
                },
                label
            );
            defer staging.deinit();

            try staging.copyFromSlice(T, data);

            var raw = try RawBuffer.init(e_vulkan, size, .{
                .VertexBuffer = true,
                .TransferDst = true,
            }, .{
                .DeviceLocal = true,
            }, label);
            errdefer raw.deinit();

            try copyBuffer(e_vulkan, staging.buffer, raw.buffer, size);

            return @This(){
                .raw = raw,
                .len = data.len,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.raw.e_vulkan.await() catch {};
            self.raw.deinit();
        }
    };
}

pub fn IndexBuffer(comptime T: type) type {
    return struct {
        raw: RawBuffer,
        len: usize,

        /// T should be u16 or u32.
        pub fn init(e_vulkan: *rendering.EggyVulkanInterface, data: []const T, label: ?[*:0]const u8) !@This() {
            const size: vk.DeviceSize = @sizeOf(T) * data.len;

            var staging = try RawBuffer.init(e_vulkan, size, .{ .TransferSrc = true }, .{
                .HostVisible = true,
                .HostCoherent = true,
            },
            label);
            defer staging.deinit();

            try staging.copyFromSlice(T, data);

            const raw = try RawBuffer.init(e_vulkan, size, .{
                .IndexBuffer = true,
                .TransferDst = true,
            }, .{
                .DeviceLocal = true,
            }, label);
            errdefer raw.deinit();

            try copyBuffer(e_vulkan, staging.buffer, raw.buffer, size);

            return @This(){
                .raw = raw,
                .len = data.len,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.raw.e_vulkan.await() catch {};
            self.raw.deinit();
        }
    };
}

/// In the shader-slang, this would be a `ConstantBuffer<T> foo;`
pub fn UniformBuffer(comptime T: type) type {
    return struct {
        comptime { checkAlignment(T); }
        raw: RawBuffer,
        mapped: [*]T,

        pub fn init(e_vulkan: *rendering.EggyVulkanInterface, label: ?[*:0]const u8) !@This() {
            const size: vk.DeviceSize = @sizeOf(T);
            const raw = try RawBuffer.init(e_vulkan, size, .{ .UniformBuffer = true }, .{
                .HostVisible = true,
                .HostCoherent = true,
            }, label);
            const mapped_ptr = try e_vulkan.device.mapMemory(raw.mem, 0, size, .{});
            return .{ .raw = raw, .mapped = @ptrCast(@alignCast(mapped_ptr)) };
        }

        pub fn write(self: *@This(), data: T) void { self.mapped[0] = data; }
        pub fn getData(self: *@This()) *T { return &self.mapped[0]; }

        pub fn deinit(self: *@This()) void {
            self.raw.e_vulkan.device.unmapMemory(self.raw.mem);
            self.raw.e_vulkan.await() catch {};
            self.raw.deinit();
        }
    };
}

pub const DescriptorSetResource = struct {
    e_vulkan: *rendering.EggyVulkanInterface,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [rendering.EggyVulkanInterface.MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,

    pub const Binding = union(enum) {
        buffer: struct {
            binding: u32,
            buffer: vk.Buffer,
            size: vk.DeviceSize,
            descriptor_type: vk.DescriptorType = .uniform_buffer,
        },
        image: struct {
            binding: u32,
            sampler: vk.Sampler,
            image_view: vk.ImageView,
            layout: vk.ImageLayout = .shader_read_only_optimal,
            descriptor_type: vk.DescriptorType = .combined_image_sampler,
        },
    };

    pub fn init(
        e_vulkan: *rendering.EggyVulkanInterface,
        p: pipeline.Pipeline,
        bindings: []const Binding,
    ) !@This() {
        // Count how many of each descriptor type we need for pool sizes
        var uniform_buffer_count: u32 = 0;
        var storage_buffer_count: u32 = 0;
        var combined_image_sampler_count: u32 = 0;
        var sampled_image_count: u32 = 0;
        var storage_image_count: u32 = 0;

        for (bindings) |b| {
            switch (b) {
                .buffer => |buf| switch (buf.descriptor_type) {
                    .uniform_buffer, .uniform_buffer_dynamic => uniform_buffer_count += 1,
                    .storage_buffer, .storage_buffer_dynamic => storage_buffer_count += 1,
                    else => {},
                },
                .image => |img| switch (img.descriptor_type) {
                    .combined_image_sampler => combined_image_sampler_count += 1,
                    .sampled_image => sampled_image_count += 1,
                    .storage_image => storage_image_count += 1,
                    else => {},
                },
            }
        }

        var pool_sizes_buf: [5]vk.DescriptorPoolSize = undefined;
        var pool_size_count: u32 = 0;
        const frames = rendering.EggyVulkanInterface.MAX_FRAMES_IN_FLIGHT;

        if (uniform_buffer_count > 0) {
            pool_sizes_buf[pool_size_count] = .{ .type = .uniform_buffer, .descriptor_count = uniform_buffer_count * frames };
            pool_size_count += 1;
        }
        if (storage_buffer_count > 0) {
            pool_sizes_buf[pool_size_count] = .{ .type = .storage_buffer, .descriptor_count = storage_buffer_count * frames };
            pool_size_count += 1;
        }
        if (combined_image_sampler_count > 0) {
            pool_sizes_buf[pool_size_count] = .{ .type = .combined_image_sampler, .descriptor_count = combined_image_sampler_count * frames };
            pool_size_count += 1;
        }
        if (sampled_image_count > 0) {
            pool_sizes_buf[pool_size_count] = .{ .type = .sampled_image, .descriptor_count = sampled_image_count * frames };
            pool_size_count += 1;
        }
        if (storage_image_count > 0) {
            pool_sizes_buf[pool_size_count] = .{ .type = .storage_image, .descriptor_count = storage_image_count * frames };
            pool_size_count += 1;
        }

        const descriptor_pool = try e_vulkan.device.createDescriptorPool(&.{
            .flags = .{},
            .max_sets = frames,
            .pool_size_count = pool_size_count,
            .p_pool_sizes = &pool_sizes_buf,
        }, null);
        errdefer e_vulkan.device.destroyDescriptorPool(descriptor_pool, null);

        var layouts: [frames]vk.DescriptorSetLayout = undefined;
        for (&layouts) |*l| l.* = p.descriptor_set_layout;

        var descriptor_sets: [frames]vk.DescriptorSet = undefined;
        try e_vulkan.device.allocateDescriptorSets(&.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = frames,
            .p_set_layouts = &layouts,
        }, &descriptor_sets);

        // Write descriptors for each frame
        for (0..frames) |i| {
            var writes_buf: [16]vk.WriteDescriptorSet = undefined;
            var buffer_infos: [16]vk.DescriptorBufferInfo = undefined;
            var image_infos: [16]vk.DescriptorImageInfo = undefined;

            for (bindings, 0..) |b, j| {
                switch (b) {
                    .buffer => |buf| {
                        buffer_infos[j] = .{
                            .buffer = buf.buffer,
                            .offset = 0,
                            .range = buf.size,
                        };
                        writes_buf[j] = .{
                            .dst_set = descriptor_sets[i],
                            .dst_binding = buf.binding,
                            .dst_array_element = 0,
                            .descriptor_count = 1,
                            .descriptor_type = buf.descriptor_type,
                            .p_buffer_info = @ptrCast(&buffer_infos[j]),
                            .p_image_info = undefined,
                            .p_texel_buffer_view = undefined,
                        };
                    },
                    .image => |img| {
                        image_infos[j] = .{
                            .sampler = img.sampler,
                            .image_view = img.image_view,
                            .image_layout = img.layout,
                        };
                        writes_buf[j] = .{
                            .dst_set = descriptor_sets[i],
                            .dst_binding = img.binding,
                            .dst_array_element = 0,
                            .descriptor_count = 1,
                            .descriptor_type = img.descriptor_type,
                            .p_buffer_info = undefined,
                            .p_image_info = @ptrCast(&image_infos[j]),
                            .p_texel_buffer_view = undefined,
                        };
                    },
                }
            }
            e_vulkan.device.updateDescriptorSets(writes_buf[0..bindings.len], null);
        }

        return .{
            .e_vulkan = e_vulkan,
            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.e_vulkan.await() catch {};
        self.e_vulkan.device.destroyDescriptorPool(self.descriptor_pool, null);
    }
};