---
sidebar_position: 5
title: Game UI
---

# Game UI

Declare `gameUi` to describe a game's interface with Weeoui. Eggy supplies the context,
font atlas, input routing, and renderer; you choose the layout, widgets, and style.

```zig
pub const Game = struct {
    clicks: u32 = 0,

    pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
        _ = app;
        ui.theme = eggy.ui.Theme.dark;
        ui.theme.text_size = 18;
        ui.heading(2, "My game");
        if (ui.button("Count")) self.clicks += 1;
        ui.label("Clicked {d} times", .{self.clicks});
    }
};
```

![A custom-font game HUD over a 3D scene](/img/developer-api/hud.png)

Use Weeoui's existing containers, custom widgets, and layout builder for your own designs;
there is no second Eggy widget vocabulary. UI hooks run in plugin order. The interface is
drawn after the scene and custom draw hooks, before Eggy presents the frame.

The same hook runs in the editor's **Play** Scene viewport, including while paused.
It uses viewport-local logical coordinates and the target window's pixel scale. It does
not draw over editor chrome or run while the editor's Build window freezes the game.
Stop/reload discards the old UI contexts before unloading the game library.

## Fonts and lifetime

Select a font once during initialization:

```zig
pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Game {
    const bytes = try app.resources().read(
        gpa,
        eggy.AssetRef(.any).init("resources/fonts/my-font.ttf"),
    );
    defer gpa.free(bytes);
    try (try app.gameUi()).setFont(bytes);
    return .{};
}
```

`setFont` copies the TTF/OTF, so the resource bytes can be freed immediately. It replaces GPU
resources safely; do not call it every frame. Customize `ui.theme` in the hook rather than
replacing `ui.font` or changing the context's ownership fields.

Contexts, widget trees, vertices, and draw targets are borrowed. Do not retain them beyond
the hook/frame. Keep durable UI state in plugin fields, without pointers to the plugin itself.
Clipboard and text-input ownership follow UI focus. Standalone UI uses the existing SDL
accessibility adapter; embedded game widgets are not yet merged into the editor's
accessibility tree.

## Use your own renderer

Omit `gameUi` and declare `draw`. A custom-renderer-only game creates no default Weeoui
overlay. For example, this minimal custom draw hook clears the target:

```zig
pub fn draw(self: *Game, app: *eggy.App, target: eggy.DrawContext) !void {
    _ = self;
    _ = app;
    try target.cmd.beginRenderPass(.{
        .color_attachments = &.{.{
            .view = target.target,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.1, .g = 0.2, .b = 0.4, .a = 1 },
        }},
    });
    target.cmd.endRenderPass();
}
```

For a real custom interface, own your pipelines and buffers and record its commands here.
`target.beginPass()`/`endPass()` are convenient when preserving the scene instead of clearing
it. Enter and leave the hook outside a render pass, with the target in color-attachment
state. Pair a started pass with `defer target.endPass()` if later work can fail.

`viewport` is logical size, `extent_px` is physical size, and `color_format` matches the
target. `frame_owner` and `frame_slot` identify the already-waited reusable slot: keep
per-surface/per-slot upload buffers when rendering into more than one surface. Do not
submit, present, retain the command buffer, or destroy resources still used by the GPU.

To handle your renderer's input, declare:

```zig
pub fn uiEvent(self: *Game, app: *eggy.App, event: eggy.Event) !bool {
    _ = self;
    _ = app;
    return switch (event) {
        .mouse_button_down, .mouse_button_up => true,
        else => false,
    };
}
```

Default UI gets first refusal, then custom `uiEvent` hooks run in reverse plugin order.
Return true for every event your custom UI owns, including releases. Unconsumed input
reaches gameplay's `event` hook and `app.input`; consumed input reaches neither. Default UI
capture clears gameplay holds without inventing release actions. A custom modal interface
can call `app.input.cancel()` when it takes focus. OS lifecycle events are never swallowed.
Editor shortcuts and modal tools retain precedence.

## Exercise the examples

From an Eggy checkout, `zig build run-runtime -Dapi-demo=weeoui` runs the themed HUD with a
copied custom font and a text field. Space in the focused field must not increase the
gameplay counter. `-Dapi-demo=custom` runs the custom-renderer-only example, which asserts
that no default overlay was created. Use `zig build run -Dapi-demo=weeoui` to open its editor
and inspect the API Tools panel and commands.
