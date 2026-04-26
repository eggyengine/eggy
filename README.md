# eggyengine

a data-driven modular game engine built in zig, vulkan (with slang shaders), sdl3, with a feel familiar to that of Bevy and its ECS systems. 

# dependencies

currently, the current available zig version is `0.16.0`. 

for vulkan, you need the sdk (and subsequently the validation headers if enabled, which would be yes by default). 

# example
```zig
pub fn main() !void {
    // your app is defined here
    var app = eggy.EggyApp(&.{
        // modules here
    })
    .init(std.heap.page_allocator, .{
        // any eggy-based options
    });

    // make sure to clean it up
    defer app.deinit();

    // let it rip
    app.run();
}
```