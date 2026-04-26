const sdl = @import("sdl3");
const std = @import("std");
const eggy = @import("eggy.zig");

pub const vulkan = @import("rendering/vulkan.zig");

pub const SdlBackend = enum {
    vulkan,
    opengl,
};

pub fn RenderingModule(comptime BackendImpl: type) type {
    return struct {
        backend: ?*BackendImpl = null,
        allocator: ?std.mem.Allocator = null,

        pub const sdl_backend: SdlBackend = if (@hasDecl(BackendImpl, "sdl_backend"))
            BackendImpl.sdl_backend
        else
            @compileError("Backend '" ++ @typeName(BackendImpl) ++ "' must declare 'pub const sdl_backend: rendering.SdlBackend'");

        pub const schedules = .{
            .init = &.{init},
            .deinit = &.{deinit},
        };

        fn init(self: *@This(), ctx: *eggy.Context) !void {
            if (@hasDecl(BackendImpl, "ensure_available")) {
                try BackendImpl.ensure_available();
            }

            const backend_name = if (@hasDecl(BackendImpl, "backend_name")) BackendImpl.backend_name else @typeName(BackendImpl);
            std.log.info("Using backend [{s}]", .{backend_name});

            const window = ctx.world.getResource(sdl.video.Window) orelse return error.WindowNotFound;
            const impl = try ctx.allocator.create(BackendImpl);
            // Use initDefault if available (e.g., EggyVulkanInterface), otherwise regular init
            impl.* = if (@hasDecl(BackendImpl, "initDefault"))
                try BackendImpl.initDefault(ctx.allocator, &window.*)
            else
                try BackendImpl.init(ctx.allocator, &window.*);
            self.backend = impl;
            self.allocator = ctx.allocator;

            try ctx.world.insertResource(self.*);
            try ctx.world.insertResource(impl.*);
        }

        fn deinit(self: *@This(), _: *eggy.Context) void {
            if (self.backend) |b| {
                // b.deinit(); // this will crash on exit after resize
                self.allocator.?.destroy(b);
            }
        }

        /// Get a pointer to the underlying backend.
        pub fn getBackend(self: *@This()) ?*BackendImpl {
            return self.backend;
        }
    };
}

pub const Renderer = struct {
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    deinitFn: *const fn (*anyopaque) void,
    destroyFn: *const fn (std.mem.Allocator, *anyopaque) void,

    pub fn init(ptr: anytype, allocator: std.mem.Allocator) Renderer {
        const Ptr = @TypeOf(ptr);
        return .{
            .ptr = @ptrCast(ptr),
            .allocator = allocator,
            .deinitFn = struct {
                fn thunk(p: *anyopaque) void {
                    const self: Ptr = @ptrCast(@alignCast(p));
                    self.deinit();
                }
            }.thunk,
            .destroyFn = struct {
                fn destroy(alloc: std.mem.Allocator, p: *anyopaque) void {
                    alloc.destroy(@as(Ptr, @ptrCast(@alignCast(p))));
                }
            }.destroy,
        };
    }

    pub fn deinit(self: Renderer) void {
        self.deinitFn(self.ptr);
        self.destroyFn(self.allocator, self.ptr);
    }
};
