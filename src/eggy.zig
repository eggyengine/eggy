// const sdl = @import("sdl3");
// const vk = @import("vulkan");

const std = @import("std");
const signal = @import("signal.zig");

pub const ecs = @import("ecs.zig");
pub const Context = @import("ctx.zig").Context;
pub const module = @import("mod.zig");
pub const math = @import("math.zig");
pub const mem = @import("mem.zig");
pub const colour = @import("utils/colour.zig");

/// The fixed timestep for `fixed_update` schedules.
const FIXED_TIMESTEP: f32 = 1.0 / 60.0;

var previous_time = 0;

fn flattenModules(comptime input: []const type) []const type {
    const count = countModules(input);

    const result = blk: {
        var r: [count]type = undefined;
        var idx: usize = 0;

        for (input) |M| {
            idx = addModule(&r, idx, M);
        }

        break :blk r; // "return" the value from the block
    };

    return &result; // now it's a const, so this works
}

fn addModule(result: anytype, idx: usize, comptime M: type) usize {
    var i = idx;

    if (@hasDecl(M, "sub_modules")) {
        for (M.sub_modules) |SubM| {
            i = addModule(result, i, SubM);
        }
    }

    result[i] = M;
    i += 1;

    return i;
}

fn countModules(comptime input: []const type) usize {
    var count: usize = 0;
    for (input) |M| {
        count += 1; // the current module counts as a module.

        if (@hasDecl(M, "sub_modules")) {
            count += countModules(M.sub_modules); // recursively count sub_modules
        }
    }

    return count;
}

const EggyAppOptions = struct {
    /// Panic on any error for a function that returns `!void`.
    ///
    /// By default, if it is built in debug, it is set as true.
    panic_on_err: bool = @import("builtin").mode == .Debug,
};

pub fn EggyApp(comptime user_modules: []const type) type {
    const modules = flattenModules(user_modules);

    comptime {
        for (modules) |M| {
            validateModule(M);
        }
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        proc_init: std.process.Init,
        world: ecs.World,
        modules: std.meta.Tuple(modules),
        running: bool,
        delta_time: f32,
        fixed_accumulator: f32 = 0,

        options: EggyAppOptions,

        pub fn init(proc_init: std.process.Init, opt: EggyAppOptions) !Self {
            var self = Self{
                .allocator = proc_init.gpa,
                .world = ecs.World.init(proc_init.gpa),
                .modules = undefined,
                .running = true,
                .delta_time = 0,
                .options = opt,
                .proc_init = proc_init,
            };

            // default init all modules
            inline for (&self.modules, 0..) |*m, i| {
                const M = modules[i];
                const fields = @typeInfo(M).@"struct".fields;
                inline for (fields) |field| {
                    if (field.default_value_ptr == null) {
                        @compileError("Module '" ++ @typeName(M) ++ "' cannot be default-initialised: " ++
                            "field '" ++ field.name ++ "' has no default value. " ++
                            "Either provide a default value or implement a custom init.");
                    }
                }
                m.* = M{};
            }

            self.runSchedule(.pre_init);
            self.runSchedule(.init);
            self.runSchedule(.post_init);

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.runSchedule(.pre_deinit);
            self.runSchedule(.deinit);
            self.runSchedule(.post_deinit);
            self.world.deinit();
        }

        pub fn run(self: *Self) void {
            signal.setupDefaults();
            var last_time = std.Io.Clock.now(.awake, self.proc_init.io).nanoseconds;
            var frame_count: u32 = 0;
            var fps_timer: i128 = 0;

            while (self.running and !signal.wasInterrupted()) {
                const now = std.Io.Clock.now(.awake, self.proc_init.io).nanoseconds;
                const delta_ns = now - last_time;
                last_time = now;

                self.delta_time = @as(f32, @floatFromInt(delta_ns)) / 1_000_000_000.0;

                frame_count += 1;
                fps_timer += delta_ns;
                if (fps_timer >= 1_000_000_000) {
                    frame_count = 0;
                    fps_timer = 0;
                }

                self.runSchedule(.pre_update);
                self.runSchedule(.update);
                self.runSchedule(.post_update);

                self.fixed_accumulator += self.delta_time;
                while (self.fixed_accumulator >= FIXED_TIMESTEP) {
                    self.runSchedule(.pre_fixed_update);
                    self.runSchedule(.fixed_update);
                    self.runSchedule(.post_fixed_update);
                    self.fixed_accumulator -= FIXED_TIMESTEP;
                }

                self.runSchedule(.pre_render);
                self.runSchedule(.render);
                self.runSchedule(.post_render);
            }
        }

        pub fn runSchedule(self: *Self, comptime schedule: ecs.Schedule) void {
            const dt = switch (schedule) {
                .pre_fixed_update, .fixed_update, .post_fixed_update => FIXED_TIMESTEP,
                else => self.delta_time,
            };

            var ctx = Context{
                .world = &self.world,
                .allocator = self.allocator,
                .delta_time = dt,
                .running = &self.running,
                .proc_init = &self.proc_init,
            };

            const is_deinit = schedule == .pre_deinit or schedule == .deinit or schedule == .post_deinit;

            const indices = comptime blk: {
                var idx: [modules.len]usize = undefined;
                for (0..modules.len) |i| {
                    idx[i] = if (is_deinit) modules.len - 1 - i else i;
                }
                break :blk idx;
            };

            inline for (indices) |i| {
                const m = &self.modules[i];
                const M = modules[i];
                if (@hasDecl(M, "schedules")) {
                    const scheds = M.schedules;
                    const schedule_name = @tagName(schedule);

                    if (@hasField(@TypeOf(scheds), schedule_name)) {
                        const funcs = @field(scheds, schedule_name);
                        inline for (funcs) |func| {
                            const FnInfo = @typeInfo(@TypeOf(func)).@"fn";
                            const returns_error = FnInfo.return_type != null and
                                @typeInfo(FnInfo.return_type.?) == .error_union;

                            // zero sized modules cannot have 2 params (specifically it cannot have `@This`)
                            if (FnInfo.params.len == 2 and @sizeOf(M) == 0) {
                                @compileError("Module '" ++ @typeName(M) ++ "' has no runtime fields (size=0) " ++
                                    "but schedule function '" ++ @typeName(@TypeOf(func)) ++ "' takes *Self. " ++
                                    "Either add a field to the module, or change the function to only take *Context.");
                            }

                            const result = switch (FnInfo.params.len) {
                                0 => func(),
                                1 => func(&ctx),
                                2 => func(m, &ctx),
                                else => @compileError("Schedule function must take 0, 1 (*Context), or 2 (*Self, *Context) arguments"),
                            };

                            // todo: potentially just do a log or make it so debug crashes (like that of validation layers)...
                            if (returns_error) {
                                _ = result catch |err| {
                                    if (self.options.panic_on_err) {
                                        std.debug.panic("[{s}] System '{s}' failed: {}", .{
                                            schedule_name,
                                            @typeName(M),
                                            err,
                                        });
                                    }
                                    
                                    std.log.err("[{s}] System '{s}' failed: {}", .{
                                        schedule_name,
                                        @typeName(M),
                                        err,
                                    });
                                };
                            }
                        }
                    }
                }
            }
        }

        pub fn getModule(self: *Self, comptime M: type) *M {
            inline for (&self.modules, 0..) |*m, i| {
                if (modules[i] == M) return m;
            }
            @compileError("Module " ++ @typeName(M) ++ " not registered");
        }
    };
}

fn validateModule(comptime M: type) void {
    if (@typeInfo(M) != .@"struct") {
        @compileError(@typeName(M) ++ " must be a struct");
    }

    // zero sized modules cannot have 2 params (specifically it cannot have `@This`)
    if (@hasDecl(M, "schedules")) {
        const scheds = M.schedules;
        const is_zero_sized = @sizeOf(M) == 0;

        inline for (@typeInfo(@TypeOf(scheds)).@"struct".fields) |field| {
            const funcs = @field(scheds, field.name);
            inline for (funcs) |func| {
                const FnInfo = @typeInfo(@TypeOf(func)).@"fn";
                if (FnInfo.params.len == 2 and is_zero_sized) {
                    @compileError("Module '" ++ @typeName(M) ++ "' is zero-sized (has no runtime fields) " ++
                        "but its '" ++ field.name ++ "' schedule has a function that takes *Self.\n" ++
                        "Fix: Either add a field to the module, or change the function signature from " ++
                        "'fn(self: *@This(), ctx: *Context)' to 'fn(ctx: *Context)'.");
                }
            }
        }
    }
}
