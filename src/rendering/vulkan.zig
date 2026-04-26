pub const vk = @import("vulkan");
pub const pipeline = @import("pipeline.zig");
pub const cmd = @import("command.zig");
pub const swapchain = @import("swapchain.zig");
pub const buffer = @import("buffer.zig");
pub const texture = @import("texture.zig");
pub const vkSetName = @import("debug.zig").vkSetName;

const sdl = @import("sdl3");
const builtin = @import("builtin");
const std = @import("std");
const rendering = @import("../rendering.zig");
const eggy = @import("../eggy.zig");

const Allocator = std.mem.Allocator;
const SdlBackend = rendering.SdlBackend;

/// Options for a Vulkan renderer
pub const Options = struct {
    app_name: [*:0]const u8 = "eggyengine app",
    engine_name: [*:0]const u8 = "eggyengine",
    app_version: u32 = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
    engine_version: u32 = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
    api_version: u32 = @bitCast(vk.API_VERSION_1_4),
    enable_validation_layers: bool = @import("builtin").mode == .Debug,
    extra_layers: []const [*:0]const u8 = &.{},
    extra_extensions: []const [*:0]const u8 = &.{},
};

const SurfaceResult = struct {
    vk_surface: vk.SurfaceKHR,
    sdl_surface: sdl.vulkan.Surface,
};

const Queue = struct {
    family_index: u32,
    inner: vk.Queue,
};

/// Inherits `BackendImpl`
pub const EggyVulkanInterface = struct {
    pub const sdl_backend: SdlBackend = .vulkan;
    pub const backend_name = "Vulkan";
    pub const MAX_FRAMES_IN_FLIGHT = 2;

    pub fn ensure_available() !void {
        try sdl.vulkan.loadLibrary(null);
        std.log.debug("Vulkan library is loaded", .{});
    }

    allocator: Allocator,
    options: Options,

    window: *sdl.video.Window,
    // required to be able to drop safely
    sdl_surface: sdl.vulkan.Surface,

    vkb: vk.BaseWrapper, // vk::raii::Context?
    instance: vk.InstanceProxy,
    debug_utils_messenger: ?vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    swapchain: swapchain.Swapchain,

    device: vk.DeviceProxy,
    queue: Queue,

    command_pool: vk.CommandPool,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,

    present_completed_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
    draw_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence,
    current_frame: usize,
    current_image_index: u32,

    render_finished_semaphores: std.ArrayList(vk.Semaphore),

    pub fn init(allocator: Allocator, window: *sdl.video.Window, options: Options) !@This() {
        var self: @This() = undefined;
        self.allocator = allocator;
        self.options = options;
        self.window = window;
        self.debug_utils_messenger = null;

        // setup vulkan
        const get_proc_addr = try sdl.vulkan.getVkGetInstanceProcAddr();
        self.vkb = vk.BaseWrapper.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(get_proc_addr)));

        var extensions: std.ArrayList([*:0]const u8) = .empty;
        defer extensions.deinit(self.allocator);

        var layers: std.ArrayList([*:0]const u8) = .empty;
        defer layers.deinit(self.allocator);

        try ensureExtensions(&self, &layers, &extensions);

        try createInstance(&self, &layers, &extensions);

        if (self.options.enable_validation_layers) {
            try setupDebugMessenger(&self);
        }

        // create surface
        const surface_result = try createSurface(&self);
        self.surface = surface_result.vk_surface;
        self.sdl_surface = surface_result.sdl_surface;

        try pickPhysicalDevice(&self);
        try createLogicalDevice(&self);
        self.swapchain = try swapchain.Swapchain.init(&self);

        try createCommandPool(&self);
        try createCommandBuffers(&self);

        try createSyncObjects(&self);

        std.log.debug("Initialised vulkan for eggy", .{});
        return self;
    }

    /// A common function that waits for the device to finish operations before doing anything.
    // Other backends must implement this.
    pub fn await(self: @This()) !void {
        try self.device.deviceWaitIdle();
    }
    /// Initialise with default options.
    pub fn initDefault(allocator: Allocator, window: *sdl.video.Window) !@This() {
        return init(allocator, window, .{});
    }

    pub fn deinit(self: *@This()) void {
        self.await() catch {};

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.device.destroyFence(self.draw_fences[i], null);
            self.device.destroySemaphore(self.present_completed_semaphores[i], null);
        }

        self.device.destroyCommandPool(self.command_pool, null);

        for (self.render_finished_semaphores.items) |sem| {
            self.device.destroySemaphore(sem, null);
        }
        self.render_finished_semaphores.deinit(self.allocator);

        self.swapchain.deinit();

        self.device.destroyDevice(null);
        self.allocator.destroy(self.device.wrapper);

        self.sdl_surface.deinit();

        if (self.debug_utils_messenger) |messenger| {
            self.instance.destroyDebugUtilsMessengerEXT(messenger, null);
        }
        self.instance.destroyInstance(null);
        self.allocator.destroy(self.instance.wrapper);
    }

    fn ensureExtensions(
        self: *@This(),
        layers: *std.ArrayList([*:0]const u8),
        extensions: *std.ArrayList([*:0]const u8),
    ) !void {
        const validation_layer_name: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";

        if (self.options.enable_validation_layers) {
            if (try checkLayerSupport(&self.vkb, self.allocator, &.{validation_layer_name}) == false) {
                std.log.warn("Missing Vulkan validation layers, therefore disabled. Try installing the Vulkan SDK or disable in eggy.", .{});
                self.options.enable_validation_layers = false; // since its an error
                // return error.MissingValidationLayer; // or potentially skip without validation?
            }
        }

        const sdl_extensions = try sdl.vulkan.getInstanceExtensions();

        try extensions.appendSlice(self.allocator, sdl_extensions);

        if (self.options.enable_validation_layers) {
            try extensions.append(self.allocator, vk.extensions.ext_debug_utils.name);
            try layers.append(self.allocator, validation_layer_name);
        }

        for (self.options.extra_extensions) |ext| {
            try extensions.append(self.allocator, ext);
        }

        for (self.options.extra_layers) |layer| {
            try layers.append(self.allocator, layer);
        }
    }

    fn setupDebugMessenger(self: *@This()) !void {
        const severityFlags = vk.DebugUtilsMessageSeverityFlagsEXT{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        };

        const messageTypeFlags = vk.DebugUtilsMessageTypeFlagsEXT{
            .general_bit_ext = true,
            .performance_bit_ext = true,
            .validation_bit_ext = true,
        };

        const createInfo = vk.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = severityFlags,
            .message_type = messageTypeFlags,
            .pfn_user_callback = debugCallback,
        };

        self.debug_utils_messenger = try self.instance.createDebugUtilsMessengerEXT(&createInfo, null);
    }

    fn createInstance(
        self: *@This(),
        layers: *std.ArrayList([*:0]const u8),
        extensions: *std.ArrayList([*:0]const u8),
    ) !void {
        const instance_handle = try self.vkb.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = self.options.app_name,
                .application_version = @bitCast(self.options.app_version),
                .p_engine_name = self.options.engine_name,
                .engine_version = @bitCast(self.options.engine_version),
                .api_version = @bitCast(self.options.api_version),
            },
            .enabled_layer_count = @intCast(layers.items.len),
            .pp_enabled_layer_names = @ptrCast(layers.items.ptr),
            .enabled_extension_count = @intCast(extensions.items.len),
            .pp_enabled_extension_names = @ptrCast(extensions.items.ptr),
        }, null);

        const vki = try self.allocator.create(vk.InstanceWrapper);
        errdefer self.allocator.destroy(vki);
        vki.* = vk.InstanceWrapper.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = vk.InstanceProxy.init(instance_handle, vki);
        errdefer self.instance.destroyInstance(null);
    }

    fn createSurface(self: *@This()) !SurfaceResult {
        const sdl_instance: sdl.vulkan.Instance = @ptrFromInt(@intFromEnum(self.instance.handle));
        const sdl_surface = try sdl.vulkan.Surface.init(self.window.*, sdl_instance, null);
        return .{
            .vk_surface = @enumFromInt(@intFromPtr(sdl_surface.surface)),
            .sdl_surface = sdl_surface,
        };
    }

    fn pickPhysicalDevice(self: *@This()) !void {
        const pdevs = try self.instance.enumeratePhysicalDevicesAlloc(self.allocator);
        defer self.allocator.free(pdevs);

        if (pdevs.len == 0) {
            return error.NoVulkanDevices;
        }

        const PhysicalDeviceScore = struct { device: vk.PhysicalDevice, score: u128 };

        var pq = std.PriorityQueue(PhysicalDeviceScore, void, struct {
            fn compare(_: void, a: PhysicalDeviceScore, b: PhysicalDeviceScore) std.math.Order {
                return std.math.order(b.score, a.score);
            }
        }.compare).empty;
        defer pq.deinit(self.allocator);

        for (pdevs) |device| {
            if (try isDeviceSuitable(self, device)) {
                try pq.push(self.allocator, .{ .device = device, .score = try scoreDevice(self, device) });
            }
        }

        if (pq.peek()) |scored| {
            self.pdev = scored.device;
            self.props = self.instance.getPhysicalDeviceProperties(scored.device);
            self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(scored.device);

            const props = self.instance.getPhysicalDeviceProperties(scored.device);
            std.log.info("Selected GPU: {s}", .{std.mem.sliceTo(&props.device_name, 0)});
            std.log.debug("GPU selected was ranked {d}/{d} with a score of {d} points", .{ 1, pq.count(), scored.score });

            return;
        }

        return error.NoSuitableDevice;
    }

    fn scoreDevice(self: *@This(), device: vk.PhysicalDevice) !u128 {
        var score: u128 = 0;

        const props = self.instance.getPhysicalDeviceProperties(device);

        // discrete gpu takes priority
        score += switch (props.device_type) {
            .discrete_gpu => 1000,
            .integrated_gpu => 100,
            else => 10,
        };

        score += props.limits.max_image_dimension_2d;
        score += props.limits.max_uniform_buffer_range;
        score += props.limits.max_push_constants_size;
        score += props.limits.max_framebuffer_width + props.limits.max_framebuffer_height;
        score += props.limits.max_viewports;
        score += props.limits.max_bound_descriptor_sets;

        return score;
    }

    fn isDeviceSuitable(self: *@This(), device: vk.PhysicalDevice) !bool {
        // Check if the device supports Vulkan 1.3+
        const props = self.instance.getPhysicalDeviceProperties(device);
        if (props.api_version < vk.API_VERSION_1_3.toU32()) {
            return false;
        }

        // Check if any queue family supports graphics + present
        const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, self.allocator);
        defer self.allocator.free(queue_families);

        var has_suitable_queue = false;
        for (queue_families, 0..) |family, i| {
            if (family.queue_flags.graphics_bit) {
                const present_support = self.instance.getPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), self.surface) catch .false;
                if (present_support == .true) {
                    has_suitable_queue = true;
                    break;
                }
            }
        }
        if (!has_suitable_queue) return false;

        // Check required device extensions
        const required_extensions = [_][*:0]const u8{
            vk.extensions.khr_swapchain.name,
        };

        const available_extensions = try self.instance.enumerateDeviceExtensionPropertiesAlloc(device, null, self.allocator);
        defer self.allocator.free(available_extensions);

        for (required_extensions) |required| {
            var found = false;
            for (available_extensions) |available| {
                if (std.mem.eql(u8, std.mem.span(required), std.mem.sliceTo(&available.extension_name, 0))) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        // Check required device features
        var extended_dynamic_state_features = vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{};
        var vulkan13_features = vk.PhysicalDeviceVulkan13Features{
            .p_next = @ptrCast(&extended_dynamic_state_features),
        };
        var features2 = vk.PhysicalDeviceFeatures2{
            .p_next = @ptrCast(&vulkan13_features),
            .features = .{}
        };
        self.instance.getPhysicalDeviceFeatures2(device, &features2);

        if (features2.features.sampler_anisotropy != .true) return false;
        if (vulkan13_features.dynamic_rendering != .true) return false;
        if (extended_dynamic_state_features.extended_dynamic_state != .true) return false;

        return true;
    }

    fn createLogicalDevice(self: *@This()) !void {
        const qfp = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
            self.pdev,
            self.allocator,
        );
        defer self.allocator.free(qfp);

        // Find a queue family that supports both graphics and present
        var queue_family_index: ?u32 = null;
        for (qfp, 0..) |prop, i| {
            const idx: u32 = @intCast(i);
            const supports_graphics = prop.queue_flags.graphics_bit;
            const supports_present = self.instance.getPhysicalDeviceSurfaceSupportKHR(self.pdev, idx, self.surface) catch .false;

            if (supports_graphics and supports_present == .true) {
                queue_family_index = idx;
                break;
            }
        }

        const qfi = queue_family_index orelse return error.NoSuitableQueueFamily;

        std.log.debug("Using queue family index {d}", .{qfi});

        const device_extensions = [_][*:0]const u8{
            vk.extensions.khr_swapchain.name,
        };

        var extended_dynamic_state_features = vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{
            .extended_dynamic_state = .true,
        };

        var vulkan11_features = vk.PhysicalDeviceVulkan11Features{
            .p_next = @ptrCast(&extended_dynamic_state_features),
            .shader_draw_parameters = .true,
        };

        var vulkan13_features = vk.PhysicalDeviceVulkan13Features{
            .p_next = @ptrCast(&vulkan11_features),
            .dynamic_rendering = .true,
            .synchronization_2 = .true,
        };

        var features2 = vk.PhysicalDeviceFeatures2{
            .p_next = @ptrCast(&vulkan13_features),
            .features = .{
                .sampler_anisotropy = .true,
            },
        };

        self.instance.getPhysicalDeviceFeatures2(self.pdev, &features2);

        const queue_priority: f32 = 0.5;
        const queue_create_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = qfi,
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&queue_priority),
        };

        const device_create_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&features2),
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_create_info),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = undefined,
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
        };

        const device_handle = try self.instance.createDevice(self.pdev, &device_create_info, null);

        const get_device_proc_addr = self.instance.wrapper.dispatch.vkGetDeviceProcAddr orelse return error.MissingDeviceProcAddr;
        const device_wrapper = try self.allocator.create(vk.DeviceWrapper);

        device_wrapper.* = vk.DeviceWrapper.load(device_handle, get_device_proc_addr);

        self.device = vk.DeviceProxy.init(device_handle, device_wrapper);

        self.queue = Queue{ .family_index = qfi, .inner = self.device.getDeviceQueue(qfi, 0) };

        std.log.debug("Created logical device and queue", .{});
    }

    fn createCommandPool(self: *@This()) !void {
        const poolInfo = vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.queue.family_index,
        };
        self.command_pool = try self.device.createCommandPool(&poolInfo, null);
    }

    fn createCommandBuffers(self: *@This()) !void {
        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = MAX_FRAMES_IN_FLIGHT,
        };
        try self.device.allocateCommandBuffers(&alloc_info, &self.command_buffers);
    }

    fn createSyncObjects(self: *@This()) !void {
        const semaphore_info: vk.SemaphoreCreateInfo = .{};
        const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.present_completed_semaphores[i] = try self.device.createSemaphore(&semaphore_info, null);
            self.draw_fences[i] = try self.device.createFence(&fence_info, null);
        }
        self.current_frame = 0;
        self.current_image_index = 0;

        self.render_finished_semaphores = .empty;
        for (0..self.swapchain.swapchain_images.items.len) |_| {
            const sem = try self.device.createSemaphore(&semaphore_info, null);
            try self.render_finished_semaphores.append(self.allocator, sem);
        }
    }

    pub const AcquireError = error{
        FenceWaitFailed,
        SurfaceLost,
        SwapchainOutOfDate,
        AcquireFailed,
        CommandBufferResetFailed,
        CommandBufferBeginFailed,
    };

    pub const SubmitResult = enum {
        success,
        swapchain_out_of_date,
        swapchain_suboptimal,
    };

    pub fn beginFrame(self: *@This(), label: [*:0]const u8) AcquireError!void {
        const frame_index = self.current_frame;

        const fence_result = self.device.waitForFences(@ptrCast(&self.draw_fences[frame_index]), .true, std.math.maxInt(u64)) catch {
            return error.FenceWaitFailed;
        };
        if (fence_result != .success) {
            return error.FenceWaitFailed;
        }

        const acquire_result = self.device.acquireNextImageKHR(
            self.swapchain.swapchain,
            std.math.maxInt(u64),
            self.present_completed_semaphores[frame_index],
            .null_handle,
        ) catch |err| {
            return switch (err) {
                error.SurfaceLostKHR => error.SurfaceLost,
                error.OutOfDateKHR => error.SwapchainOutOfDate,
                else => error.AcquireFailed,
            };
        };

        if (acquire_result.result == .error_out_of_date_khr) {
            return error.SwapchainOutOfDate;
        }

        const fences = [_]vk.Fence {
            self.draw_fences[frame_index]
        };
        self.device.resetFences(&fences) catch {
            return error.FenceWaitFailed;
        };

        const cmd_buf = self.command_buffers[frame_index];
        self.device.resetCommandBuffer(cmd_buf, .{}) catch {
            return error.CommandBufferResetFailed;
        };

        @import("debug.zig").vkSetName(self.device, vk.CommandBuffer, cmd_buf, label);

        self.device.beginCommandBuffer(cmd_buf, &.{
            .flags = .{ .one_time_submit_bit = true },
        }) catch {
            return error.CommandBufferBeginFailed;
        };

        self.current_image_index = acquire_result.image_index;
    }

    /// Submit the recorded command buffer and present the frame.
    pub fn endFrame(self: *@This(), command_buffer: *cmd.CommandBuffer) !SubmitResult {
        command_buffer.transitionSwapchainImageLayout(
            .color_attachment_optimal,
            .present_src_khr,
            .{ .color_attachment_write_bit = true },
            .{},
            .{ .color_attachment_output_bit = true },
            .{ .bottom_of_pipe_bit = true },
        );

        try self.device.endCommandBuffer(command_buffer.cmd);

        const frame_index = self.current_frame;
        const image_index = self.current_image_index;

        const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.present_completed_semaphores[frame_index]),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer.cmd),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.render_finished_semaphores.items[image_index]),
        };
        try self.device.queueSubmit(self.queue.inner, @ptrCast(&submit_info), self.draw_fences[frame_index]);

        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_finished_semaphores.items[image_index]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain.swapchain),
            .p_image_indices = @ptrCast(&self.current_image_index),
        };

        const present_result = self.device.queuePresentKHR(self.queue.inner, &present_info) catch |err| {
            return switch (err) {
                error.OutOfDateKHR => .swapchain_out_of_date,
                else => err,
            };
        };

        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;

        if (present_result == .suboptimal_khr) {
            return .swapchain_suboptimal;
        }

        return .success;
    }
};

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_type: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_type;
    _ = p_user_data;

    // NOTE: enabling this code will cause a segfault. it is best to use std.debug.print
    if (p_callback_data) |data| {
        if (message_severity.error_bit_ext) {
            std.log.err("[vulkan] {s}\n", .{ data.p_message orelse "(no message)" });
        }
        else if (message_severity.warning_bit_ext)
            {std.log.warn("[vulkan] {s}\n", .{ data.p_message orelse "(no message)" });}
        else
            {std.log.info("[vulkan] {s}\n", .{ data.p_message orelse "(no message)" });}
    }

    const severity_str = if (message_severity.error_bit_ext)
        "ERROR"
    else if (message_severity.warning_bit_ext)
        "WARNING"
    else
        "INFO";

    if (p_callback_data) |data| {
        std.debug.print("[vulkan] [{s}] {s}\n", .{ severity_str, data.p_message orelse "(no message)" });
    }

    return .false;
}

fn checkLayerSupport(vkb: *const vk.BaseWrapper, alloc: Allocator, required_layers: []const [*:0]const u8) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(alloc);
    defer alloc.free(available_layers);
    for (required_layers) |required_layer| {
        for (available_layers) |layer| {
            if (std.mem.eql(u8, std.mem.span(required_layer), std.mem.sliceTo(&layer.layer_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}
