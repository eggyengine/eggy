---
sidebar_position: 3
title: Give scripts your own commands
---

Scripts reach your game through console commands. Eggy has a few of its own (see
[The scripting API](./scripting-api.md#commands)); your game and its plugins can add more in
Zig, and then players can type them and scripts can call them with `run`.

## Declare a command

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

`command` is the position of the command in `console_commands`, counting from 0. A plugin
declares commands the same way, on its `Plugin` type.

Build and press **Play**. Now `help` lists `lives`, <kbd>Tab</kbd> completes it, and typing
`lives 9` sets it:

```
lives: 9
```

## Read what was typed

A `Call` holds the words typed after the command's name:

| `Call` | What it gives |
| --- | --- |
| `arg(i)` | The `i`th word after the name, counting from 0, or null if there isn't one. A word in quotes keeps its spaces. |
| `rest(i)` | The line from the `i`th word on, as it was typed. Use it for a value that has spaces in it, such as ZON. |
| `print(fmt, args)` | Writes a line of output to the console. |
| `arena` | Memory that's freed when the command returns. |

Return an error to fail. `lives many` fails at `parseInt`, and the console shows the
error, here `failed: InvalidCharacter`.

## Call it from a script

`run` runs any command and returns whether it worked, so a script can build on yours:

```buzz
// Give the player a life back, up to a limit.
fun extraLife(lives: int) > void {
    if (lives >= 9) {
        print("That's as many lives as you can have");
    } else if (run("lives {lives + 1}")) {
        print("One more life!");
    } else {
        print("Couldn't change the lives");
    }
}
```

`run` returns `false` when the command doesn't exist or returns an error. Whatever the
command prints with `call.print` shows in the console either way.

## Rules for names

- A command's name is one word.
- Names are unique. Two plugins can't declare the same name, and none can take one of
  Eggy's (`help`, `clear`, `run`, `entities`, `get`, `set`, `timescale`). Either is a
  compile error.
- A line runs a command when its first word, up to the first space, is the command's name.
  So `lives 9` runs the command, while `lives()` runs as Buzz and calls a function named
  `lives`, if a script declared one.

See [Console commands](../../reference/plugin-hooks.md#console-commands) in the plugin hooks
reference for opening and closing the console from code, and for changing its key.
