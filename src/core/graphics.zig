const std = @import("std");
const vit = @import("vitellus");
const sdl_adapter = @import("vitellus_sdl3");
const ui = @import("weeoui");
const viewport3d = @import("viewport3d.zig");
const mesh = @import("mesh.zig");
const camera = @import("camera.zig");
const weeoui_vitellus = @import("weeoui_vitellus");
const ModelCache = @import("model_cache.zig").ModelCache;
const TextureCache = @import("texture_cache.zig").TextureCache;
const Sources = @import("mesh_renderer.zig").Sources;

/// The GPU device, the main window's `Surface`, and the 3D scene that draws into it.
pub const Graphics = struct {
    instance: vit.Instance,
    adapter: vit.Adapter,
    device: vit.Device,
    queue: vit.Queue,
    /// The format every surface renders in, so pipelines work in any window.
    color_format: vit.Format,
    /// The main window's swapchain.
    surface: Surface,
    preview: viewport3d.Preview,
    /// The model files meshes are drawn as, shared by every scene drawn; set its `loader`.
    models: ModelCache,
    /// The images meshes are painted with, likewise; set its `loader`.
    textures: TextureCache,

    pub fn init(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window) !Graphics {
        // Eggy's shaders are SPIR-V and WGSL; each platform only tries the backends it has.
        const instance = try vit.Instance.init(allocator, .{ .backend = .{ .vulkan = true, .webgpu = true }, .validation = .core });
        errdefer instance.deinit();
        const adapter = try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
        errdefer adapter.deinit();
        const device = try vit.Device.init(adapter, .{ .label = "vitellus device" });
        errdefer device.deinit();
        const queue = try vit.Queue.init(device, .{ .label = "graphics queue", .kind = .graphics });
        errdefer queue.deinit();

        // The main window picks the color format; other windows must offer the same one.
        var surface = try Surface.initFor(instance, adapter, device, queue, window, null);
        errdefer surface.deinit();
        const color_format = weeoui_vitellus.colorFormat(surface.swapchain.info().format);
        var textures = try TextureCache.init(allocator, device);
        errdefer textures.deinit();
        const preview = try viewport3d.Preview.init(device, color_format, surface.extent, textures.layout);
        std.log.info("Graphics ready: {d}x{d} px, {s}", .{ surface.extent.width, surface.extent.height, @tagName(color_format) });
        return .{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .color_format = color_format,
            .surface = surface,
            .preview = preview,
            .models = .init(allocator, device),
            .textures = textures,
        };
    }

    /// Where the scene's model files and textures come from, for drawing it.
    pub fn sources(self: *Graphics) Sources {
        return .{ .models = &self.models, .textures = &self.textures };
    }

    /// Forget every model file and image, so each loads again when next drawn: their files may
    /// have changed. Waits for the GPU to finish with them.
    pub fn forgetAssets(self: *Graphics) void {
        self.queue.waitIdle() catch {};
        self.models.forgetAll(&self.textures);
        self.textures.forgetAll();
    }

    /// Match the main window's swapchain to its pixel size.
    pub fn syncSize(self: *Graphics, window: sdl_adapter.Sdl3Window) !void {
        const before = self.surface.extent;
        try self.surface.syncSize(self.queue, window);
        if (std.meta.eql(before, self.surface.extent)) return;
        try self.preview.resize(self.device, self.surface.extent);
    }

    pub fn deinit(self: *Graphics) void {
        self.queue.waitIdle() catch {};
        self.models.deinit(&self.textures);
        self.preview.deinit();
        self.textures.deinit();
        self.surface.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    /// A `Surface` for another window, rendering in `color_format`. Deinit it before `self`.
    pub fn addSurface(self: *const Graphics, window: sdl_adapter.Sdl3Window) !Surface {
        return Surface.initFor(self.instance, self.adapter, self.device, self.queue, window, self.color_format);
    }

    /// Start a frame in the main window (see `Surface.beginFrame`).
    pub fn beginFrame(self: *Graphics) !Frame {
        return self.surface.beginFrame();
    }

    /// Finish and present a frame from `beginFrame`.
    pub fn endFrame(self: *Graphics, frame: Frame) !void {
        return self.surface.endFrame(self.queue, frame);
    }

    /// Draw the 3D scene, with `drawables` (from `eggy.mesh.gather`; sorted in place) seen from
    /// `view`, over the whole of `frame`. Call outside a render pass.
    pub fn drawScene(self: *Graphics, frame: Frame, drawables: []mesh.Drawable, view: camera.View) !void {
        const window = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(frame.extent.width), .h = @floatFromInt(frame.extent.height) };
        try self.preview.draw(frame.cmd, frame.target, window, window, window, frame.extent, weeoui_vitellus.isSrgb(self.color_format), drawables, self.sources(), view, null);
    }
};

/// One window's swapchain and the frames in flight that draw into it.
pub const Surface = struct {
    swapchain: vit.Swapchain,
    /// The CPU records into one slot while the GPU may still be drawing the other.
    slots: [frames_in_flight]FrameSlot,
    slot: usize = 0,
    /// Advances to a frame's number when the GPU finishes it.
    gpu_done: vit.Fence,
    submitted: u64 = 0,
    /// Signalled when drawing into swapchain image i finishes; its present waits on it.
    render_done: [max_swapchain_images]vit.Semaphore,
    extent: vit.Extent2D,

    /// A swapchain for `window`; with `color_format`, one whose format renders as it.
    fn initFor(instance: vit.Instance, adapter: vit.Adapter, device: vit.Device, queue: vit.Queue, window: sdl_adapter.Sdl3Window, color_format: ?vit.Format) !Surface {
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

        // Pick the window's format (the wanted one when given), then make the swapchain.
        const caps = try adapter.surfaceCapabilities(instance.allocator, try window.asWindow());
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0) return error.NoSurfaceCapabilities;
        const format = if (color_format) |wanted| for (caps.formats) |candidate| {
            if (weeoui_vitellus.colorFormat(candidate) == wanted) break candidate;
        } else return error.NoMatchingSurfaceFormat else caps.formats[0];
        const extent = try pixelExtent(window) orelse vit.Extent2D{ .width = 1, .height = 1 };
        const swapchain = try vit.Swapchain.init(adapter, .{
            .label = "swapchain",
            .window = try window.asWindow(),
            .queue = queue,
            .extent = extent,
            .format = format,
            .present_mode = pickPresentMode(caps.present_modes),
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });
        return .{ .swapchain = swapchain, .slots = slots, .gpu_done = gpu_done, .render_done = render_done, .extent = extent };
    }

    /// Free the swapchain. The GPU must be done with it (`queue.waitIdle`).
    pub fn deinit(self: *Surface) void {
        self.swapchain.deinit();
        for (&self.slots) |*slot| slot.deinit();
        for (self.render_done) |semaphore| semaphore.deinit();
        self.gpu_done.deinit();
    }

    /// Match the swapchain to `window`'s pixel size.
    pub fn syncSize(self: *Surface, queue: vit.Queue, window: sdl_adapter.Sdl3Window) !void {
        // A minimized window has no pixels; keep the old swapchain until it comes back.
        const requested = try pixelExtent(window) orelse return;
        if (requested.width == self.extent.width and requested.height == self.extent.height) return;
        try queue.waitIdle();
        try self.swapchain.resize(requested);
        self.extent = requested;
    }

    /// Start a frame: wait for its slot, acquire a swapchain image, and clear it to black. Record
    /// into the returned `Frame`, then pass it to `endFrame`.
    pub fn beginFrame(self: *Surface) !Frame {
        // Wait for the frame that last used this slot, `frames_in_flight` frames ago.
        const slot = &self.slots[self.slot];
        _ = try self.gpu_done.wait(slot.frame, null);
        if (slot.cmd) |old| old.deinit();
        slot.cmd = null;
        try slot.commands.reset();

        // Acquire the next swapchain image and make it a render target.
        const acquired = try self.swapchain.acquireNextImage(slot.acquired);
        if (acquired.index >= max_swapchain_images) return error.TooManySwapchainImages;
        const cmd = try vit.CommandBuffer.init(slot.commands, .{});
        slot.cmd = cmd;
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{ .view = acquired.view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }} });
        cmd.endRenderPass();
        return .{ .cmd = cmd, .target = acquired.view, .extent = self.swapchain.info().extent, .render_done = self.render_done[acquired.index] };
    }

    /// Finish `frame`: submit its commands to `queue` and present the image once they have run.
    pub fn endFrame(self: *Surface, queue: vit.Queue, frame: Frame) !void {
        try frame.cmd.barrier(&.{.{ .texture_view = .{ .view = frame.target, .before = .color_attachment, .after = .present } }});
        try frame.cmd.finish();

        // Submit, then hand the slot on; the next use of this slot waits for `submitted`.
        self.submitted += 1;
        const slot = &self.slots[self.slot];
        try queue.submit(.{
            .command_buffers = &.{frame.cmd},
            .wait_semaphores = &.{slot.acquired},
            .signal_semaphores = &.{frame.render_done},
            .signal_fences = &.{.{ .fence = self.gpu_done, .value = self.submitted }},
        });
        slot.frame = self.submitted;
        self.slot = (self.slot + 1) % frames_in_flight;
        _ = try self.swapchain.present(&.{frame.render_done});
    }
};

/// A frame between `Surface.beginFrame` and `Surface.endFrame`.
pub const Frame = struct {
    cmd: vit.CommandBuffer,
    /// The acquired swapchain image, in the color-attachment state.
    target: vit.TextureView,
    extent: vit.Extent2D,
    /// Signalled when this frame's commands finish; its present waits on it.
    render_done: vit.Semaphore,
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

/// The window's drawable size in pixels, or null while it has none.
fn pixelExtent(window: sdl_adapter.Sdl3Window) !?vit.Extent2D {
    const width, const height = try window.window.getSizeInPixels();
    if (width == 0 or height == 0) return null;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

fn pickPresentMode(modes: []const vit.PresentMode) vit.PresentMode {
    for (modes) |mode| if (mode == .mailbox) return mode;
    for (modes) |mode| if (mode == .immediate) return mode;
    return modes[0];
}
