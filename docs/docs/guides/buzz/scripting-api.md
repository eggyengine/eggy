---
sidebar_position: 2
title: The scripting API
---

This page lists what Buzz can reach from Eggy's dev console, and how the console runs what
you type and the scripts you load. [Your first Buzz script](./first-script.md) walks
through it step by step.

## How a line runs

The console reads the first word of each line:

1. If it names one of Eggy's commands (`help`, `clear`, `run`, `entities`, `get`, `set`,
   `timescale`), that command runs.
2. If it names a command your game or a plugin adds, that runs.
3. Otherwise the whole line runs as Buzz.

So `timescale 0.5` is a command, and `run("timescale 0.5")` is Buzz calling the same
command.

## The session

Every Buzz line, typed or loaded from a file, runs in one session that lasts until the game
quits. In the editor that's the editor itself, and the Console panel and the console over
Play share it.

- **Declarations stay.** A `var`, `final`, `fun` or `object` declared on one line can be
  used on any line after it.
- **A line that fails changes nothing.** If it has an error, what it declared is forgotten
  and the session is as it was before the line.
- **The last value shows.** A line that ends in an expression without a semicolon shows its
  value: `1 + 2` shows `3`.
- **Errors say where.** A typed line's error gives the column; a script's gives
  `path:line:column`.

## Natives

Eggy gives every session two functions:

| Function | What it does |
| --- | --- |
| `print(value: str) > void` | Shows `value` as a line of console output. |
| `run(command: str) > bool` | Runs a console command, as if typed. Returns `true` if it ran, and `false` if there's no such command or it failed. Whatever the command prints shows in the console. |

`print` takes a string only. Put other values in one with interpolation:
`print("lives: {lives}")`.

`run` runs commands, not Buzz, and not other scripts: `run("run other.buzz")` returns
`false`.

## Commands

These are the commands `run` can reach, as well as any [your game adds](./script-commands.md):

| Command | What it does |
| --- | --- |
| `help [command]` | Lists every command, or shows how to use one. |
| `clear` | Clears the console. |
| `run <path.buzz>` | Runs a script file (see below). |
| `entities [text]` | Lists the named entities, or those whose name contains `text`, with their ids (`#12`). |
| `get <entity> <Component.field>` | Shows a component's field as ZON. |
| `set <entity> <Component.field> <zon>` | Sets a component's field from ZON. |
| `timescale [scale]` | Shows or sets how fast game time passes. `1` is normal and `0` pauses. |

An `<entity>` is its name, or `#` and its id. `entities`, `get` and `set` look into the
game's world, and say so when there's no game loaded to look into.

From Buzz, a `{` inside a string starts interpolation, so write a ZON value's opening brace
as `\{`. Quote a name with spaces with `\"`:

```buzz
final height = 5.5;
run("set Player Transform.position .\{ 0, {height}, 0 }");
run("set \"Main Camera\" Camera.fov 70");
```

A script can't read a value back yet: `run("get Player Transform.position")` shows the value
in the console and returns `true`, but the script doesn't receive it.

## Script files

`run <path.buzz>` runs a whole file in the session, top to bottom:

```
run scripts/slowmo.buzz
```

- **Where paths start.** In the editor, from your project's folder. In a built game, from
  the folder the player started the game from. An absolute path works anywhere.
- **Completion.** After `run `, <kbd>Tab</kbd> completes the paths of the `.buzz` files
  there. It skips `zig-out`, `.zig-cache`, `.git`, `.eggy` and `node_modules`.
- **Running again replaces.** Running the same path again first removes what that script
  declared last time, so you can edit and rerun it. If the new version fails, the old
  declarations stay. Use the same spelling of the path each time: `scripts/a.buzz` and
  `./scripts/a.buzz` count as different scripts.
- **Size.** A script can be up to 4 MiB.

### Loading mods

Because a script's declarations stay, a script file makes a simple mod: it declares
functions, and players call them from the console. Ship a `mods` folder beside your game
and tell players to `run mods/<name>.buzz`. Keep in mind:

- **Mods aren't sandboxed.** A script can do anything the console can, which includes
  changing any component of any entity. Only run scripts you trust.
- **Players need the console.** If you turn the console off (see below), players can't load
  mods this way.

## The language

Buzz is statically typed and never converts between types for you:

- `1` is an `int` and `1.0` is a `double`. `2.5 * 2` is an error; write `2.5 * 2.0`.
- `final` declares a value that can't be reassigned, and `var` one that can.
- Lists and maps are read-only unless made with `mut`: `final coins = mut [ 1, 2 ];` can
  `append`.
- Functions are `fun name(a: int, b: int = 1) > int { ... }`, and a parameter with a
  default can be left out or passed by name: `add(2)`, `add(2, b: 5)`.

Most of the language works in the console, such as functions, objects, lists, maps, `if`,
`for` and `foreach`. Two things don't:

- **No imports.** `import` can't load other files or Buzz's standard library
  (`buzz:std`, `buzz:math` and the rest). Use `run` to load another file, and Eggy's
  `print` in place of `std\print`.
- **No arguments for scripts.** A script can't read command-line arguments. Declare a
  function and call it with arguments instead.

See [Buzz's documentation](https://buzz-lang.dev) for the full language.

## Turning the console off

In **File > Project Settings > Project**, turn off **Dev console** (or set
`.dev_console = false` in `eggy.zon`). Then <kbd>`</kbd> no longer opens the console, in
Play or the built game. The prompt in the editor's Console panel still works.

## Where Buzz runs

Buzz runs in desktop builds (Windows, macOS and Linux). On the web and Android, the
console runs commands only, and `run <path.buzz>` says scripts can't run there.
