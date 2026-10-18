---
sidebar_position: 5
title: Control the mouse and window
slug: /guides/sdl3
---

Use SDL3 to lock the mouse for camera movement, capture a drag, confine or hide the
pointer, or change the window title. Eggy exposes the Zig SDL3 binding through
`eggy.sdl_adapter.sdl`. The editor and hot-loaded game share the same SDL instance.

## Borrow the host window

```zig
const std = @import("std");
const eggy = @import("eggy");
const sdl = eggy.sdl_adapter.sdl;
```

Call these controls from a game hook on the main thread, while `app` and its window
are alive. `app.window.window` is the main SDL window. Borrow it: do not destroy it
or initialize/shut down Eggy's SDL subsystems.

Use [`app.input`](../how-to/read-input.md) or [named input maps](../how-to/map-input.md) to read
gameplay input. Those respect editor Play/pause and UI capture. Calling SDL directly
to poll device state bypasses that routing; do not poll SDL's event queue yourself.

## Choose the right mouse mode

| Operation | Purpose | Release |
| --- | --- | --- |
| `mouse.setWindowRelativeMode(window, true)` | Continuous, unbounded movement for an FPS camera; hides the cursor while active | Pass `false` |
| `mouse.capture(true)` | Keep receiving mouse events outside the focused window, such as during a drag | Pass `false` |
| `mouse.setWindowGrab(window, true)` | Confine the pointer to the window | Pass `false` |
| `mouse.setWindowRect(window, rect)` | Confine the pointer to a window-relative rectangle | Pass `null` |
| `mouse.hide()` | Hide the cursor without requesting relative motion or capture | `mouse.show()` |
| `window.setKeyboardGrab(true)` | Request a keyboard grab; OS shortcuts may remain reserved | Pass `false` |

Capture does not provide unbounded motion. Hiding the pointer does not prevent it
from reaching another window. Avoid keyboard grabs unless the game really needs
them, and provide an obvious way to release them.

## Lock and release relative motion {#relative-motion}

Call these helpers from game hooks while `app` is valid:

```zig
pub fn lockMouse(app: *eggy.App) !void {
    try sdl.mouse.setWindowRelativeMode(app.window.window, true);
}

pub fn releaseMouse(app: *eggy.App) !void {
    const window = app.window.window;
    if (sdl.mouse.getWindowRelativeMode(window)) {
        try sdl.mouse.setWindowRelativeMode(window, false);
    }
}
```

For example, enter on a right-button press and leave on Escape:

```zig
if (app.input.mousePressed(.right)) try lockMouse(app);
if (app.input.pressed(.escape)) try releaseMouse(app);

if (sdl.mouse.getWindowRelativeMode(app.window.window)) {
    transform.rotation_deg[1] -= app.input.mouse_delta[0] * sensitivity_deg_per_point;
}
```

Relative mode itself manages cursor visibility; `hide()` is not required for it.
Read accumulated movement from `app.input.mouse_delta`, not absolute cursor positions.
Release the mode whenever the interaction ends, including when gameplay relinquishes
control. In editor Play, this acts on the whole OS window, including the editor
chrome outside the Scene panel.

## Visibility and drag capture

```zig
try sdl.mouse.hide();
std.debug.assert(!sdl.mouse.visible());
try sdl.mouse.show();
```

Visibility is SDL mouse state; it does not own a custom cursor. Use capture for an
outside-window drag, and pair every successful request with release when it finishes:

```zig
try sdl.mouse.capture(true);
// Continue the drag through normal input/event handling.
// When the drag ends:
try sdl.mouse.capture(false);
```

Capture requires a focused window and backend support. It does not make gameplay input
ignore UI ownership or guarantee delivery while the app is unfocused.

## Confine the pointer or grab the keyboard {#confinement-and-keyboard-grabs}

```zig
const window = app.window.window;
try sdl.mouse.setWindowGrab(window, true);
std.debug.assert(sdl.mouse.getWindowGrab(window));
// At the end of the interaction:
try sdl.mouse.setWindowGrab(window, false);
```

For a smaller area, use window-relative coordinates:

```zig
try sdl.mouse.setWindowRect(window, .{ .x = 20, .y = 20, .w = 640, .h = 360 });
const area = sdl.mouse.getWindowRect(window); // Null when no rectangle is configured.
std.log.debug("Confinement rectangle: {any}", .{area});
try sdl.mouse.setWindowRect(window, null);
```

Keyboard grabs are separate:

```zig
try window.setKeyboardGrab(true);
// Release before returning control to menus, editor tools, or another application.
try window.setKeyboardGrab(false);
```

## Change the title and read the window size {#window-operations}

Window methods use the same borrowed SDL window:

```zig
const window = app.window.window;
try window.setTitle("My Game - Paused");
const width_points, const height_points = try window.getSize();
std.log.info("Window size: {d}x{d} points", .{ width_points, height_points });
```

Logical window dimensions differ from physical framebuffer dimensions on high-DPI
displays. Eggy owns resize events and swapchain synchronization; do not create a second
presentation loop for the main window.

## Handle unsupported requests {#failures-and-reloads}

Availability depends on the OS and video backend. Unsupported requests return
`error.SdlError`, not successful no-ops. The dummy/headless driver cannot provide real
OS capture or confinement. Game-hook diagnostics include SDL's own error message;
for a locally handled failure, read it immediately:

```zig
sdl.mouse.capture(true) catch |err| {
    std.log.err("cannot capture the mouse: {s}", .{sdl.errors.get() orelse "no SDL detail"});
    return err;
};
```

Do not silently ignore failures or retry the same unsupported request every frame.

## Check release and reload behavior

Test with the OS and video backend you plan to support. For relative mode, check
that movement continues without reaching a screen edge and that ending the interaction
releases the mode. For capture, drag outside the focused window, then release it.
The visibility and grab examples include assertions that check the requested state.

Release the mouse modes/grabs your game enabled when gameplay relinquishes control.
Free custom cursors and unregister callbacks before unloading the library that owns
them. Never keep callback pointers from an old game library after a hot reload.

## Related contracts

See [error handling](../how-to/handle-errors.md) for runtime/editor failure behavior,
[input routing](../explanation/input-and-time.md) for UI ownership, and
[ownership and reload](../explanation/ownership-and-reload.md) for library lifetimes.
