const std = @import("std");
const vit = @import("vitellus");

pub const Graphics = struct {
    instance: vit.Instance,
    adapter: vit.Adapter,
    device: vit.Device,
    queue: vit.Queue,
    swapchain: vit.Swapchain,
    commands: vit.CommandPool,

    pub fn init(i: std.process.Init, window: vit.windowing.sdl3.Sdl3Window) !@This() {
        const instance = try vit.Instance.init(i.gpa, .{
            .backend = .{ .vulkan = true }, // todo: get other graphics APIs to work maybe
            .validation = .core,
        });
        errdefer instance.deinit();

        const adapter = try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
        errdefer adapter.deinit();

        const device = try vit.Device.init(adapter, .{ .label = "vitellus device" });
        errdefer device.deinit();

        const queue = try vit.Queue.init(device, .{ .label = "vitellus graphics queue", .kind = .graphics });
        errdefer queue.deinit();

        const commands = try vit.CommandPool.init(device, .{ .kind = .graphics });
        errdefer commands.deinit();

        const caps = try adapter.surfaceCapabilities(instance.allocator, try window.asWindow());
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0)
            return error.NoSurfaceCapabilities;

        const size = try window.window.getSizeInPixels();
        const swapchain = try vit.Swapchain.init(adapter, .{
            .label = "swapchain",
            .window = try window.asWindow(),
            .queue = queue,
            .extent = .{ .width = @intCast(size.@"0"), .height = @intCast(size.@"1") },
            .format = caps.formats[0],
            .present_mode = pickPresentMode(caps.present_modes),
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });

        return .{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .swapchain = swapchain,
            .commands = commands,
        };
    }

    pub fn onResize(self: *@This(), window: vit.windowing.sdl3.Sdl3Window) !void {
        const size = try window.window.getSizeInPixels();
        if (size.@"0" == 0 or size.@"1" == 0) return;
        try self.queue.waitIdle();
        try self.swapchain.resize(.{
            .width = @intCast(size.@"0"),
            .height = @intCast(size.@"1"),
        });
    }

    pub fn deinit(self: *@This()) void {
        self.queue.waitIdle() catch {};
        self.swapchain.deinit();
        self.commands.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    pub fn frame(self: *@This()) !void {
        try self.commands.reset();
        const acquired = try self.swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(self.commands, .{});
        defer cmd.deinit();

        try cmd.barrier(&.{.{
            .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment },
        }});
        try cmd.beginRenderPass(.{
            .color_attachments = &.{.{
                .view = acquired.view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            }},
        });
        cmd.endRenderPass();
        try cmd.barrier(&.{.{
            .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present },
        }});
        try cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{cmd} });
        _ = try self.swapchain.present(&.{});
    }
};

fn pickPresentMode(modes: []const vit.PresentMode) vit.PresentMode {
    for (modes) |mode| if (mode == .mailbox) return mode;
    for (modes) |mode| if (mode == .immediate) return mode;
    return modes[0];
}
