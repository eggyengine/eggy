---
title: Graphics settings
---

Eggy lets you and your players choose how the game is drawn: graphics backend, graphics
card, window, vertical sync, frame rate, render scale, antialiasing, mipmapping and texture
filtering. There are three places to set them, and each is saved on its own.

| Where | Who | Saved in |
| --- | --- | --- |
| **File > Project Settings > Graphics** | You, as the game's shipped defaults | `eggy.zon`, under `.graphics` |
| **Edit > Preferences...**, Graphics section | You, for the editor's own Scene view | Your Eggy data folder |
| The in-game **Graphics** menu | Your players | The game's user-data folder |

A player's saved choices win over the shipped defaults. Nothing else touches them, so
changing your project's defaults never overwrites what a player picked.

## The options

Only choices this computer supports are listed.

- **Graphics API** and **Graphics card**: which backend and GPU draw the game. These, and
  vertical sync, take effect after the game restarts, and are labelled so.
- **Window mode** and **Window size**: windowed or borderless fullscreen, and the size the
  window opens at (desktop only).
- **Vertical sync**: waits for the screen to refresh to avoid tearing, at the cost of some
  delay. Low latency and Off trade smoothness for responsiveness. Needs a restart.
- **Frame rate limit**: frames per second up to 1000, where 0 is unlimited.
- **Render scale**: 0.25 to 2, the resolution the 3D scene is drawn at. Below 1 draws fewer
  pixels and runs faster; above 1 is crisper. The interface always stays at the window's
  native resolution.
- **Antialiasing**: Off, 2x, 4x or 8x MSAA (sharper, costs more), or FXAA (cheaper, softens
  textures a little). Only sample counts the graphics card supports are listed.
- **Mipmapping**: a chain of smaller copies of each texture for distant surfaces. Less
  shimmer for a little extra memory.
- **Texture filtering**: Nearest is blocky, Linear is smooth. Linear with mipmapping is
  trilinear.
- **Anisotropic filtering**: keeps textures sharp at a slant, up to what the graphics card
  reports. It needs Linear filtering, so choosing Nearest turns it off.

New projects start with automatic backend and card, 4x MSAA, linear filtering and mipmaps
on. A value that isn't valid is never silently changed: you get an error message saying
what to fix.

## Choose your game's defaults

Open **File > Project Settings** and use the **Graphics** cards. Changes are written to
`eggy.zon` as you make them and **Edit > Undo** takes them back. The editor's Scene view
and any exported game start from them. You can also write them by hand:

```zig
.graphics = .{
    .anti_aliasing = .msaa_8x,
    .texture_filter = .linear,
    .anisotropy = 8,
    .frame_limit = 120,
},
```

Settings you leave out keep their defaults.

## Change the editor's own settings

The **Graphics** section of **Edit > Preferences...** has the same options for the editor, kept in your Eggy
data folder and separate from every project. **Apply** saves and uses them, **Restore
defaults** loads the project's shipped values into the form, and **Revert** drops edits you
haven't applied. If a saved choice can't be used when the editor starts, a message says so.

## Let players choose

Every game has a Graphics menu. Players press **F10** to open it and **F10** or **Escape**
to close it. While it is open it takes the keyboard and mouse, and the game doesn't see
them. **Apply** saves the choices and uses them, **Restore defaults** loads your shipped
values, and **Cancel** closes the menu. Anything that needs a restart is labelled.

Change the key, or turn it off to open the menu from your own button, through
`app.graphics_settings_ui`:

```zig
pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
    // A button in your own pause menu.
    if (ui.buttonVariant("Graphics", .outline)) app.graphics_settings_ui.open();
}

// Somewhere that runs once, such as init: null turns the key off.
app.graphics_settings_ui.toggle_key = .func10;
```

`open`, `close`, `toggle` and `isOpen` are all there. Phones and tablets have no F10, so
give them a button.

## Change settings from code

For your own menu, use the same calls the Graphics menu does:

```zig
const result = try app.saveGraphicsSettings(settings); // validates, saves, applies
if (result == .restart_required) {
    // tell the player the backend, graphics card or vertical sync changes after a restart
}
```

`app.setGraphicsSettings` applies without saving. Both fail with an error for an unsupported
or out-of-range value, so show or log it. Changes apply at the start of the next frame, not
in the middle of drawing. `app.graphics.render_settings` holds what is in use,
`app.graphics_options.requested` the player's last choice, and `app.graphics_options.defaults` your shipped
values.

## Limits

- Backend, graphics card and vertical sync changes apply after a restart; everything else applies live.
- Metal is not offered.
- Borderless fullscreen is a borderless window, not exclusive fullscreen.
- Window mode, size and frame rate options are hidden where the platform can't use them. The
  Project Settings form always shows them, since it sets the shipped defaults.
- The editor opens the Graphics preferences from the menu; it has no F10 menu.
