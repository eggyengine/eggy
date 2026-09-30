const std = @import("std");
const vit = @import("vitellus");
const sdl_adapter = @import("vitellus_sdl3");
const ui = @import("weeoui");
const viewport3d = @import("viewport3d.zig");
const weeoui_vitellus = @import("weeoui_vitellus");

pub const Graphics = struct {
    instance: vit.Instance,
    adapter: vit.Adapter,
    device: vit.Device,
    queue: vit.Queue,
    swapchain: vit.Swapchain,
    /// The CPU records into one slot while the GPU may still be drawing the other.
    slots: [frames_in_flight]FrameSlot,
    slot: usize = 0,
    /// Advances to a frame's number when the GPU finishes it.
    gpu_done: vit.Fence,
    submitted: u64 = 0,
    /// Signalled when drawing into swapchain image i finishes; its present waits on it.
    render_done: [max_swapchain_images]vit.Semaphore,
    color_format: vit.Format,
    window_extent: vit.Extent2D,
    preview: viewport3d.Preview,

    pub fn init(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window) !@This() {
        const instance = try vit.Instance.init(allocator, .{ .backend = .{ .vulkan = true }, .validation = .core });
        errdefer instance.deinit();
        const adapter = try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
        errdefer adapter.deinit();
        const device = try vit.Device.init(adapter, .{ .label = "vitellus device" });
        errdefer device.deinit();
        const queue = try vit.Queue.init(device, .{ .label = "graphics queue", .kind = .graphics });
        errdefer queue.deinit();
        var slots: [frames_in_flight]FrameSlot = undefined;
        for (&slots, 0..) |*slot, i| {
            errdefer for (slots[0..i]) |*made| made.deinit();
            slot.* = try .init(device);
        }
        errdefer for (&slots) |*slot| slot.deinit();
        const gpu_done = try vit.Fence.init(device, .{ .label = "frames done" });
        errdefer gpu_done.deinit();
        var render_done: [max_swapchain_images]vit.Semaphore = undefined;
        for (&render_done, 0..) |*semaphore, i| {
            errdefer for (render_done[0..i]) |made| made.deinit();
            semaphore.* = try vit.Semaphore.init(device, .{ .label = "render done" });
        }
        errdefer for (render_done) |semaphore| semaphore.deinit();
        const caps = try adapter.surfaceCapabilities(instance.allocator, try window.asWindow());
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0) return error.NoSurfaceCapabilities;
        const size = try window.window.getSizeInPixels();
        const extent = vit.Extent2D{ .width = @intCast(@max(1, size.@"0")), .height = @intCast(@max(1, size.@"1")) };
        const swapchain = try vit.Swapchain.init(adapter, .{
            .label = "swapchain",
            .window = try window.asWindow(),
            .queue = queue,
            .extent = extent,
            .format = caps.formats[0],
            .present_mode = pickPresentMode(caps.present_modes),
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });
        errdefer swapchain.deinit();
        const color_format = weeoui_vitellus.colorFormat(caps.formats[0]);
        const preview = try viewport3d.Preview.init(device, color_format, extent);
        std.log.info("Graphics ready: {d}x{d} px, {s}", .{ extent.width, extent.height, @tagName(color_format) });
        return .{ .instance = instance, .adapter = adapter, .device = device, .queue = queue, .swapchain = swapchain, .slots = slots, .gpu_done = gpu_done, .render_done = render_done, .color_format = color_format, .window_extent = extent, .preview = preview };
    }

    /// Match the swapchain to the window's pixel size.
    pub fn syncSize(self: *@This(), window: sdl_adapter.Sdl3Window) !void {
        const pixels = try window.window.getSizeInPixels();
        if (pixels.@"0" == 0 or pixels.@"1" == 0) return;
        const requested = vit.Extent2D{ .width = @intCast(pixels.@"0"), .height = @intCast(pixels.@"1") };
        if (requested.width == self.window_extent.width and requested.height == self.window_extent.height) return;
        try self.queue.waitIdle();
        try self.preview.resize(self.device, requested);
        try self.swapchain.resize(requested);
        self.window_extent = requested;
    }

    pub fn deinit(self: *@This()) void {
        self.queue.waitIdle() catch {};
        self.preview.deinit();
        self.swapchain.deinit();
        for (&self.slots) |*slot| slot.deinit();
        for (self.render_done) |semaphore| semaphore.deinit();
        self.gpu_done.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    /// Draw the 3D scene over the whole window.
    pub fn frame(self: *@This()) !void {
        const extent = self.swapchain.info().extent;
        const slot = &self.slots[self.slot];
        // Wait for the frame that last used this slot, `frames_in_flight` frames ago.
        _ = try self.gpu_done.wait(slot.frame, null);
        if (slot.cmd) |old| old.deinit();
        slot.cmd = null;
        try slot.commands.reset();
        const acquired = try self.swapchain.acquireNextImage(slot.acquired);
        if (acquired.index >= max_swapchain_images) return error.TooManySwapchainImages;
        const render_done = self.render_done[acquired.index];
        const cmd = try vit.CommandBuffer.init(slot.commands, .{});
        slot.cmd = cmd;
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        // The scene paints its own backdrop; the clear only covers the first frame's undefined image.
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{ .view = acquired.view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }} });
        cmd.endRenderPass();
        const window = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(extent.width), .h = @floatFromInt(extent.height) };
        try self.preview.draw(cmd, acquired.view, window, window, window, extent, weeoui_vitellus.isSrgb(self.color_format));
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present } }});
        try cmd.finish();
        self.submitted += 1;
        try self.queue.submit(.{
            .command_buffers = &.{cmd},
            .wait_semaphores = &.{slot.acquired},
            .signal_semaphores = &.{render_done},
            .signal_fences = &.{.{ .fence = self.gpu_done, .value = self.submitted }},
        });
        slot.frame = self.submitted;
        self.slot = (self.slot + 1) % frames_in_flight;
        _ = try self.swapchain.present(&.{render_done});
    }
};

const frames_in_flight = weeoui_vitellus.frames_in_flight;
const max_swapchain_images = 8;

/// What one frame in flight owns until the GPU finishes it.
const FrameSlot = struct {
    commands: vit.CommandPool,
    /// Signalled by the swapchain when the acquired image is ready to draw into.
    acquired: vit.Semaphore,
    /// Freed once the GPU is done with it, not right after submitting.
    cmd: ?vit.CommandBuffer = null,
    /// Frame number (`gpu_done` value) that last used this slot.
    frame: u64 = 0,

    fn init(device: vit.Device) !FrameSlot {
        const commands = try vit.CommandPool.init(device, .{ .kind = .graphics });
        errdefer commands.deinit();
        return .{ .commands = commands, .acquired = try vit.Semaphore.init(device, .{ .label = "image acquired" }) };
    }

    fn deinit(self: *FrameSlot) void {
        if (self.cmd) |cmd| cmd.deinit();
        self.acquired.deinit();
        self.commands.deinit();
    }
};

fn pickPresentMode(modes: []const vit.PresentMode) vit.PresentMode {
    for (modes) |mode| if (mode == .mailbox) return mode;
    for (modes) |mode| if (mode == .immediate) return mode;
    return modes[0];
}
