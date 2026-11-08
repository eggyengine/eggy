---
title: The dev console
sidebar_position: 5
description: Look into and change a running game with commands, and add commands of your own.
---

The dev console opens as a bar along the bottom of the game when you press <kbd>&#96;</kbd>, in editor
Play and in the built game. In the editor its prompt also sits under the **Console** panel. Each
line runs the command its first word names: one of Eggy's, or one your game or a plugin adds.
<kbd>Tab</kbd> completes commands, entity names and `Component.field` paths.

| Command | What it does |
| --- | --- |
| `help [command]` | Lists every command, or shows how to use one. |
| `clear` | Clears the console. |
| `entities [text]` | Lists the named entities, or those whose name contains `text`, with their ids (`#12`). |
| `get <entity> <Component.field>` | Shows a component's field as ZON. |
| `set <entity> <Component.field> <zon>` | Sets a component's field from ZON. |
| `timescale [scale]` | Shows or sets how fast game time passes. `1` is normal and `0` pauses. |
| `physics [debug [on\|off]]` | Shows the physics precision and whether colliders are drawn; `debug on` draws every collider and contact, `debug` alone flips it. |

An `<entity>` is its name, or `#` and its id. Quote a name that has spaces:

```
set Player Transform.position .{ 0, 5.5, 0 }
set "Main Camera" Camera.fov 70
```

`entities`, `get` and `set` look into the game's world, and say so when no game is loaded.

## Add your own commands

List the commands in `console_commands` and run them in `consoleCommand`. This game adds a
`lives` command that shows or sets how many lives are left:

```zig
const std = @import("std");
const eggy = @import("eggy");

pub const Game = struct {
    lives: u32 = 3,

    pub const console_commands = [_]eggy.dev_console.Command{
        .{ .name = "lives", .help = "Show or set the lives left", .usage = "[count]" },
    };

    pub fn consoleCommand(self: *Game, command: usize, app: *eggy.App, call: *eggy.dev_console.Call) !void {
        _ = app;
        switch (command) {
            0 => {
                if (call.arg(0)) |text| self.lives = try std.fmt.parseInt(u32, text, 10);
                call.print("lives: {d}", .{self.lives});
            },
            else => unreachable,
        }
    }
};
```

`command` is the command's position in `console_commands`, counting from 0. A plugin declares
commands the same way, on its `Plugin` type. Build and press **Play**: `help` lists `lives`,
<kbd>Tab</kbd> completes it, and `lives 9` sets it.

| `Call` | What it gives |
| --- | --- |
| `arg(i)` | The `i`th word after the name, counting from 0, or null if there isn't one. A word in quotes keeps its spaces. |
| `rest(i)` | The line from the `i`th word on, as it was typed, for a value with spaces in it such as ZON. |
| `print(fmt, args)` | Writes a line of output to the console. |
| `arena` | Memory that's freed when the command returns. |

Return an error to fail: `lives many` fails at `parseInt`, and the console shows
`failed: InvalidCharacter`.

A command's name is one word, and unique: two plugins can't declare the same one, and none can
take one of Eggy's. Either is a compile error.

## Open it from code, or turn it off

`app.dev_console` opens and closes the console (`open`, `close`, `toggle`), and its `toggle_key`
changes the key, or turns it off with `null`, so you can open it from your own button.

:::caution

The console can do anything the game can. To keep it out of the game you ship, turn off
**Dev console** in **File > Project Settings** (`.dev_console = false` in `eggy.zon`). The
<kbd>&#96;</kbd> key then does nothing in Play or the built game; the editor's Console panel keeps
its prompt.

:::
