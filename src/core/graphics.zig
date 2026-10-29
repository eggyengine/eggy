const builtin = @import("builtin");
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
const MaterialCache = @import("material_cache.zig").MaterialCache;
const ShaderCache = @import("shader_cache.zig").ShaderCache;
const render = @import("render_settings.zig");
const backend_config = @import("graphics_backend.zig");

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
    /// Android destroys the window's native surface while the application is backgrounded.
    surface_active: bool = true,
    preview: viewport3d.Preview,
    /// The model files meshes are drawn as, shared by every scene drawn; set its `loader`.
    models: ModelCache,
    /// The images meshes are painted with, likewise; set its `loader`.
    textures: TextureCache,
    materials: MaterialCache,
    /// Project shaders, for materials' surfaces and post passes; set its `loader`.
    shaders: ShaderCache,
    /// Seconds the game has run, which shaders are given; the host sets it each frame.
    time_s: f32 = 0,
    /// The authored animation clips entities play, shared by every scene drawn; set its `resources`.
    clips: @import("clip_cache.zig").ClipCache,
    lights: @import("lighting.zig").Frame = .{},
    stats: @import("mesh_renderer.zig").Stats = .{},
    world_draw: ?*const @import("draw2d.zig").Draw2d = null,
    /// This frame's billboards' UI scenes, set by the host before drawing; null for none.
    ui_billboards: ?*const @import("ui_scenes/billboards.zig").Frame = null,
    render_settings: render.Settings = .{},
    settings_revision: u64 = 0,
    cached_caps: render.Capabilities = .{},

    /// Graphics for `window`, on the platform's backends in Vitellus's order: on Windows
    /// DirectX 12, then Vulkan; on macOS Metal (not there yet), then Vulkan through MoltenVK; on
    /// Linux Vulkan; on the web WebGPU. `VITELLUS_BACKEND` puts one first. One that fails part way
    /// (no adapter, no surface for the window) gives way to the next. Validation only in debug
    /// builds: a release asks for none.
    /// Host-only initialization: SDL must already own a live `window`, which must outlive
    /// the returned graphics. Retains `allocator` for caches and backend state; propagates
    /// backend/device/swapchain creation errors. Pair with `deinit` after other surfaces.
    ///
    /// ```zig
    /// var graphics = try Graphics.init(gpa, sdl_window_adapter);
    /// defer graphics.deinit();
    /// ```
    pub fn init(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window) !Graphics {
        return initWithDefaults(allocator, window, .{});
    }

    /// Initialize a requested backend/GPU and validate quality against its actual capabilities.
    pub fn initWithSettings(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window, settings: render.Settings) !Graphics {
        return initConfigured(allocator, window, settings, .strict);
    }

    /// Adapt shipped defaults to this device; saved user overrides must use `initWithSettings`.
    pub fn initWithDefaults(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window, defaults: render.Settings) !Graphics {
        try defaults.validateValues();
        return initConfigured(allocator, window, defaults.forPlatform(), .project_defaults);
    }

    const Policy = enum { strict, project_defaults };

    fn initConfigured(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window, settings: render.Settings, policy: Policy) !Graphics {
        try settings.validateValues();
        // Null: Vitellus's own choice; once one fails, every other.
        var allowed = backend_config.mask(settings.backend);
        var last_error: ?anyerror = null;
        while (true) {
            const validation: vit.ValidationLevel = if (builtin.mode == .debug) .core else .none;
            // With every backend tried, the last one's own error says why, not `NoSupportedBackend`.
            const instance = vit.Instance.init(allocator, .{ .backend = allowed, .validation = validation }) catch |err| return if (err == error.NoSupportedBackend) last_error orelse err else err;
            const backend = instance.selected_backend;
            return initOn(allocator, window, instance, settings, policy) catch |err| {
                if (settings.backend != .auto) return err;
                std.log.warn("cannot render with {t} ({t}): trying the next backend", .{ backend, err });
                var rest = allowed orelse vit.BackendType{ .dx12 = true, .vulkan = true, .metal = true, .webgpu = true };
                switch (backend) {
                    inline else => |tag| @field(rest, @tagName(tag)) = false,
                }
                last_error = err;
                allowed = rest;
                continue;
            };
        }
    }

    /// `init` on `instance`, which it owns from now on (freed if this fails).
    fn initOn(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window, instance: vit.Instance, requested: render.Settings, policy: Policy) !Graphics {
        var settings = requested;
        std.log.info("rendering with {t}", .{instance.selected_backend});
        errdefer instance.deinit();
        const adapter = if (settings.adapter_index) |index| backend_config.selectAdapter(instance, index) catch |err| switch (err) {
            error.InvalidGraphicsAdapter, error.EnumerationUnsupported => blk: {
                if (policy == .strict) return err;
                settings.adapter_index = null;
                std.log.warn("project's default GPU is unavailable ({t}); selecting automatically", .{err});
                break :blk try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
            },
            else => return err,
        } else try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
        errdefer adapter.deinit();
        const device = try vit.Device.init(adapter, .{ .label = "vitellus device", .required_features = .{ .anisotropic_filtering = adapter.capabilities().features.anisotropic_filtering } });
        errdefer device.deinit();
        const queue = try vit.Queue.init(device, .{ .label = "graphics queue", .kind = .graphics });
        errdefer queue.deinit();

        // The main window picks the color format; other windows must offer the same one.
        var surface = Surface.initFor(instance, adapter, device, queue, window, null, settings.present_mode) catch |err| switch (err) {
            error.UnsupportedPresentMode => blk: {
                if (policy == .strict) return err;
                settings.present_mode = .auto;
                std.log.warn("project's default presentation mode is unavailable; selecting automatically", .{});
                break :blk try Surface.initFor(instance, adapter, device, queue, window, null, .auto);
            },
            else => return err,
        };
        errdefer surface.deinit();
        const color_format = weeoui_vitellus.colorFormat(surface.swapchain.info().format);
        const caps = try backend_config.capabilities(adapter, instance, surface.present_modes, color_format);
        if (policy == .project_defaults) {
            settings = settings.supportedDefaults(caps);
            if (!std.meta.eql(settings, requested))
                std.log.warn("project graphics defaults adjusted to this device's supported options", .{});
        }
        try settings.validate(caps);
        var textures = try TextureCache.init(allocator, device, queue, settings);
        errdefer textures.deinit();
        const preview = try viewport3d.Preview.init(device, color_format, surface.extent, textures.layout, settings);
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
            .materials = .{ .gpa = allocator },
            .shaders = .{ .gpa = allocator, .device = device, .shaderSource = viewport3d.shaderSource },
            .clips = .{ .gpa = allocator },
            .render_settings = settings,
            .cached_caps = caps,
        };
    }

    /// Borrow-free snapshot of usable settings and adapter names, queried once at startup.
    pub fn capabilities(self: *const Graphics) render.Capabilities {
        return self.cached_caps;
    }

    /// Apply live rendering choices before recording any frame. Restart-only changes are rejected.
    pub fn setRenderSettings(self: *Graphics, settings: render.Settings) !void {
        try settings.validate(self.cached_caps);
        if (self.render_settings.requiresRestart(settings)) return error.RestartRequired;
        if (std.meta.eql(self.render_settings, settings)) return;
        const replace_textures = self.render_settings.mipmaps != settings.mipmaps or
            self.render_settings.texture_filter != settings.texture_filter or self.render_settings.anisotropy != settings.anisotropy;
        const replace_preview = replace_textures or self.render_settings.anti_aliasing != settings.anti_aliasing or self.render_settings.render_scale != settings.render_scale or
            self.render_settings.shadow_quality != settings.shadow_quality or self.render_settings.shadow_distance_m != settings.shadow_distance_m or self.render_settings.shadow_bias != settings.shadow_bias;
        try self.queue.waitIdle();
        var textures: ?TextureCache = null;
        errdefer if (textures) |*made| made.deinit();
        if (replace_textures) {
            textures = try TextureCache.init(self.textures.gpa, self.device, self.queue, settings);
            textures.?.loader = self.textures.loader;
        }
        var preview: ?viewport3d.Preview = null;
        errdefer if (preview) |*made| made.deinit();
        if (replace_preview)
            preview = try viewport3d.Preview.init(self.device, self.color_format, self.surface.extent, if (textures) |made| made.layout else self.textures.layout, settings);
        if (preview) |made| {
            self.preview.deinit();
            self.preview = made;
        }
        if (textures) |made| {
            self.models.forgetAll(&self.textures);
            self.textures.deinit();
            self.textures = made;
        }
        self.render_settings = settings;
        if (replace_preview) self.settings_revision +%= 1;
    }

    /// Where the scene's model files and textures come from, for drawing it.
    /// Host renderer helper: the returned pointers borrow `self`; do not retain them after
    /// graphics moves or is destroyed. Loader configuration remains on the caches.
    ///
    /// ```zig
    /// const asset_sources = graphics.sources();
    /// ```
    pub fn sources(self: *Graphics) Sources {
        return .{ .models = &self.models, .textures = &self.textures, .materials = &self.materials, .clips = &self.clips, .shaders = &self.shaders, .time_s = self.time_s, .lights = &self.lights, .stats = &self.stats, .world_draw = self.world_draw, .ui_billboards = self.ui_billboards };
    }

    /// Forget every model file, image and shader, so each loads again when next drawn: their files may
    /// have changed. Waits for the GPU to finish with them.
    /// Host-only cache invalidation: invalidates all cached GPU handles and model bounds.
    /// Queue-idle errors are ignored; do not call while recording draws using those assets.
    ///
    /// ```zig
    /// graphics.forgetAssets();
    /// ```
    pub fn forgetAssets(self: *Graphics) void {
        self.queue.waitIdle() catch {};
        self.models.forgetAll(&self.textures);
        self.materials.forgetAll();
        self.shaders.forgetAll();
        self.clips.forgetAll();
        self.textures.forgetAll();
    }

    /// Match the main window's swapchain to its pixel size.
    /// Host resize step before beginning a frame; waits for the queue when size changes and
    /// resizes scene depth resources. Minimized windows keep the previous size.
    /// Window, queue and GPU allocation errors propagate.
    ///
    /// ```zig
    /// try graphics.syncSize(main_window_adapter);
    /// ```
    pub fn syncSize(self: *Graphics, window: sdl_adapter.Sdl3Window) !void {
        if (!self.surface_active) return;
        const before = self.surface.extent;
        try self.surface.syncSize(self.queue, window);
        if (std.meta.eql(before, self.surface.extent)) return;
        try self.preview.resize(self.device, self.surface.extent);
    }

    /// Release the native surface before Android backgrounds the window, retaining GPU assets.
    pub fn suspendSurface(self: *Graphics) !void {
        if (!self.surface_active) return;
        try self.queue.waitIdle();
        self.surface.deinit();
        self.surface_active = false;
    }

    /// Recreate the main surface after Android restores the window; failures leave it suspended.
    pub fn resumeSurface(self: *Graphics, window: sdl_adapter.Sdl3Window) !void {
        if (self.surface_active) return;
        var surface = try self.addSurface(window);
        errdefer surface.deinit();
        try self.preview.resize(self.device, surface.extent);
        self.surface = surface;
        self.surface_active = true;
    }

    /// Tear down host graphics and all cached assets once, waiting for queued work first.
    /// Destroy extra surfaces and dependent renderers before this; keep SDL/window alive
    /// until afterward. Invalidates every borrowed device/cache/frame handle.
    ///
    /// ```zig
    /// var graphics = try Graphics.init(gpa, main_window_adapter);
    /// defer graphics.deinit();
    /// ```
    pub fn deinit(self: *Graphics) void {
        self.queue.waitIdle() catch {};
        self.models.deinit(&self.textures);
        self.materials.deinit();
        self.clips.deinit();
        self.preview.deinit();
        self.shaders.deinit();
        self.textures.deinit();
        if (self.surface_active) self.surface.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    /// A `Surface` for another window, rendering in `color_format`. Deinit it before `self`.
    /// Host-only: the second SDL window must remain alive through surface destruction.
    /// Returns independently owned swapchain resources; unsupported formats and GPU errors
    /// propagate. Wait for the queue before deinitializing the surface.
    ///
    /// ```zig
    /// var surface = try graphics.addSurface(popout_window_adapter);
    /// // After the pop-out's final frame:
    /// try graphics.queue.waitIdle();
    /// surface.deinit();
    /// ```
    pub fn addSurface(self: *const Graphics, window: sdl_adapter.Sdl3Window) !Surface {
        return Surface.initFor(self.instance, self.adapter, self.device, self.queue, window, self.color_format, self.render_settings.present_mode);
    }

    /// Start a frame in the main window (see `Surface.beginFrame`).
    /// Host loop only: returns borrowed recording/target handles, not caller-owned GPU
    /// objects. Finish this frame with `endFrame` before starting another on this surface.
    /// Acquisition/recording errors propagate.
    ///
    /// ```zig
    /// const frame = try graphics.beginFrame();
    /// try graphics.endFrame(frame);
    /// ```
    pub fn beginFrame(self: *Graphics) !Frame {
        const before = self.surface.extent;
        try self.surface.matchWindowShape(self.queue);
        const frame = try self.surface.beginFrame();
        // The swapchain can come back another size than asked for (Android rebuilds it when the
        // screen turns), so the scene's targets follow the image it draws into.
        if (!std.meta.eql(before, frame.extent)) {
            try self.queue.waitIdle();
            try self.preview.resize(self.device, frame.extent);
        }
        return frame;
    }

    /// Finish and present a frame from `beginFrame`.
    /// Host loop only: all render passes must be ended and the target left in
    /// color-attachment state. Submits once, advances the slot, and propagates GPU errors;
    /// do not reuse `frame` afterward.
    ///
    /// ```zig
    /// const frame = try graphics.beginFrame();
    /// try graphics.endFrame(frame);
    /// ```
    pub fn endFrame(self: *Graphics, frame: Frame) !void {
        return self.surface.endFrame(self.queue, frame);
    }

    /// Draw the 3D scene, with `drawables` (from `eggy.mesh.gather`; sorted in place) seen from
    /// `view`, over the whole of `frame`. Call outside a render pass.
    /// Host runtime rendering step: may load/upload assets and records passes into this
    /// graphics' active frame. Paths in `drawables` must still be valid; GPU errors
    /// propagate. Games normally let the runtime own this frame lifecycle.
    ///
    /// ```zig
    /// const frame = try graphics.beginFrame();
    /// try graphics.drawScene(frame, gathered_drawables, camera_view);
    /// try graphics.endFrame(frame);
    /// ```
    pub fn drawScene(self: *Graphics, frame: Frame, drawables: []mesh.Drawable, view: camera.View) !void {
        const window = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(frame.extent.width), .h = @floatFromInt(frame.extent.height) };
        try self.preview.draw(frame.cmd, frame.target, window, window, window, frame.extent, weeoui_vitellus.isSrgb(self.color_format), drawables, self.sources(), view, &.{}, false);
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
    /// The swapchain's images' size, which the platform can choose over `requested` (Android
    /// sizes it from the display), and the window pixel size it was last asked to match.
    extent: vit.Extent2D,
    requested: vit.Extent2D,
    present_modes: std.enums.EnumSet(render.PresentMode),

    /// A swapchain for `window`; with `color_format`, one whose format renders as it.
    fn initFor(instance: vit.Instance, adapter: vit.Adapter, device: vit.Device, queue: vit.Queue, window: sdl_adapter.Sdl3Window, color_format: ?vit.Format, requested_mode: render.PresentMode) !Surface {
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
        var present_modes = std.enums.EnumSet(render.PresentMode).initOne(.auto);
        for (caps.present_modes) |mode| present_modes.insert(switch (mode) {
            inline else => |tag| @field(render.PresentMode, @tagName(tag)),
        });
        if (!present_modes.contains(requested_mode)) return error.UnsupportedPresentMode;
        const swapchain = try vit.Swapchain.init(adapter, .{
            .label = "swapchain",
            .window = try window.asWindow(),
            .queue = queue,
            .extent = extent,
            .format = format,
            .present_mode = if (requested_mode == .auto) pickPresentMode(caps.present_modes) else switch (requested_mode) {
                .auto => unreachable,
                inline else => |tag| @field(vit.PresentMode, @tagName(tag)),
            },
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });
        return .{ .swapchain = swapchain, .slots = slots, .gpu_done = gpu_done, .render_done = render_done, .extent = imageExtent(swapchain, extent), .requested = extent, .present_modes = present_modes };
    }

    /// Free the swapchain. The GPU must be done with it (`queue.waitIdle`).
    /// Host-only teardown: call once before destroying its window or owning `Graphics`.
    /// Invalidates frame slots, semaphores and any borrowed swapchain target.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// extra_surface.deinit();
    /// ```
    pub fn deinit(self: *Surface) void {
        self.swapchain.deinit();
        for (&self.slots) |*slot| slot.deinit();
        for (self.render_done) |semaphore| semaphore.deinit();
        self.gpu_done.deinit();
    }

    /// Match the swapchain to `window`'s pixel size.
    /// Host-only resize, outside an active frame. Uses the surface's graphics queue and
    /// original window; zero-sized/minimized windows keep the old swapchain.
    /// Waits for idle on a change and propagates window/queue/resize errors.
    ///
    /// ```zig
    /// try extra_surface.syncSize(graphics.queue, popout_window_adapter);
    /// ```
    pub fn syncSize(self: *Surface, queue: vit.Queue, window: sdl_adapter.Sdl3Window) !void {
        // A minimized window has no pixels; keep the old swapchain until it comes back.
        const requested = try pixelExtent(window) orelse return;
        if (std.meta.eql(requested, self.requested)) return;
        try queue.waitIdle();
        try self.swapchain.resize(requested);
        self.requested = requested;
        self.extent = imageExtent(self.swapchain, requested);
    }

    /// Ask for the window's size again while the swapchain is the other way round from it.
    /// While an Android screen turns, the surface briefly reports its old orientation, and a
    /// swapchain the backend rebuilt then keeps it; once the surface settles, this corrects it.
    /// Host-only, outside an active frame; waits for idle when it resizes.
    /// ponytail: retries every frame until the surface settles; back off if a device never does.
    pub fn matchWindowShape(self: *Surface, queue: vit.Queue) !void {
        const wanted = self.requested;
        if (wanted.width == wanted.height) return;
        if ((wanted.width > wanted.height) == (self.extent.width > self.extent.height)) return;
        try queue.waitIdle();
        try self.swapchain.resize(wanted);
        self.extent = imageExtent(self.swapchain, wanted);
    }

    /// Start a frame: wait for its slot, acquire a swapchain image, and clear it to black. Record
    /// into the returned `Frame`, then pass it to `endFrame`.
    /// Host-only; only one active frame per surface. The surface retains all returned GPU
    /// handles; do not deinitialize them. GPU/acquisition errors propagate, including
    /// `TooManySwapchainImages` for an unsupported image index.
    ///
    /// ```zig
    /// const frame = try extra_surface.beginFrame();
    /// try extra_surface.endFrame(graphics.queue, frame);
    /// ```
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
        self.extent = imageExtent(self.swapchain, self.extent);
        return .{ .cmd = cmd, .target = acquired.view, .extent = self.extent, .render_done = self.render_done[acquired.index] };
    }

    /// Finish `frame`: submit its commands to `queue` and present the image once they have run.
    /// Host-only: use the matching frame and graphics queue, with no active render pass and
    /// the target in color-attachment state. Advances the in-flight slot; propagates submit
    /// and present errors. Do not record into or submit this frame again.
    ///
    /// ```zig
    /// const frame = try extra_surface.beginFrame();
    /// try extra_surface.endFrame(graphics.queue, frame);
    /// ```
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
/// The size of `swapchain`'s images, or `fallback` from a backend that doesn't say.
fn imageExtent(swapchain: vit.Swapchain, fallback: vit.Extent2D) vit.Extent2D {
    const extent = swapchain.info().extent;
    return if (extent.width == 0 or extent.height == 0) fallback else extent;
}

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
