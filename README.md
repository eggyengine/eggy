# eggyengine

a data-driven modular game engine built in zig, vulkan (with slang shaders), sdl3, with a feel familiar to that of Bevy and its ECS systems. 

# dependencies

currently, the current available zig version is `0.16.0`. 

for vulkan, you need the sdk (and subsequently the validation headers if enabled, which would be yes by default). 

# add to project
to use this with the zig build system, import as so:
```bash
zig fetch --save git+https://github.com/eggyengine/eggy
```

and then in `build.zig`:
```zig
const eggy = b.dependency("eggy", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("eggy", eggy.module("eggy"));
```

# basic usage
```zig
const std = @import("std");
const eggy = @import("eggy");

pub fn main(init: std.process.Init) !void {
    // your app is defined here
    var app = eggy.EggyApp(&.{
        // modules here
    })
    .init(init, .{
        // any eggy-based options
    });

    // make sure to clean it up
    defer app.deinit();

    // let it rip
    app.run();
}
```

a module is defined as a struct of some sort. this is an extremely basic one:
```zig
struct {
    pub const schedules = .{ .update = &.{print_hello} };

    // pub const sub_modules = &.{};
}

// a pointer to an eggy.Context is required for any function that is a schedule
fn print_hello(ctx: *eggy.Context) !void {
    std.debug.print("Hello eggy!", .{});
}
```

which can be directly embedded into your app or kept as a constant:
```zig
var app = eggy.EggyApp(&.{
    struct {
        pub const schedules = .{ .update = &.{print_hello} };
    },
});
```

or
```zig
const MyModule = struct {
    pub const schedules = .{ .update = &.{print_hello} };
};

var app = eggy.EggyApp(&.{MyModule});
```